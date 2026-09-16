import Foundation
import Network
import os

public enum ADBError: LocalizedError, Sendable {
    case serverNotReachable(String)
    case protocolError(String)
    case commandFailed(String)
    case deviceNotFound(String)
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .serverNotReachable(let msg): "无法连接 ADB 服务 (127.0.0.1:5037): \(msg)"
        case .protocolError(let msg): "ADB 协议解析错误: \(msg)"
        case .commandFailed(let msg): "ADB 指令执行失败: \(msg)"
        case .deviceNotFound(let serial): "未找到指定的 Android 设备: \(serial)"
        case .timeout: "ADB 操作超时"
        case .cancelled: "ADB 操作已取消"
        }
    }
}

public struct ADBRawDevice: Sendable, Identifiable, Hashable {
    public let serial: String
    public let state: String
    public let product: String?
    public let model: String?
    public let device: String?
    public let transportId: String?

    public var id: String { serial }
    public var isOnline: Bool { state.lowercased() == "device" }
    public var isWireless: Bool { serial.contains(":") }

    public var ip: String? {
        guard isWireless else { return nil }
        return serial.components(separatedBy: ":").first
    }

    public var port: Int? {
        guard isWireless else { return nil }
        let parts = serial.components(separatedBy: ":")
        return parts.count > 1 ? Int(parts[1]) : nil
    }

    public var displayName: String {
        let cleanModel = (model ?? "").replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanModel.isEmpty {
            return cleanModel
        }
        return serial
    }
}

public struct ADBBatteryStatus: Sendable {
    public let level: Double
    public let voltageMV: Int
    public let temperatureC: Double
    public let status: Int // 2 = charging, 3 = discharging, 4 = not charging, 5 = full
    public let health: Int
    public let isPresent: Bool
    public let timestamp: Date

    public nonisolated init(
        level: Double,
        voltageMV: Int,
        temperatureC: Double,
        status: Int,
        health: Int,
        isPresent: Bool,
        timestamp: Date = Date()
    ) {
        self.level = level
        self.voltageMV = voltageMV
        self.temperatureC = temperatureC
        self.status = status
        self.health = health
        self.isPresent = isPresent
        self.timestamp = timestamp
    }

    public var statusText: String {
        switch status {
        case 2: return "充电中"
        case 3: return "放电中"
        case 4: return "未充电"
        case 5: return "已充满"
        default: return "未知状态"
        }
    }

    public var isCharging: Bool {
        status == 2
    }
}

private final class ContinuationGuard<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>, cleanup: (() -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let c = continuation {
            continuation = nil
            cleanup?()
            c.resume(with: result)
        }
    }
}

/// 纯原生 Swift TCP ADB 客户端，通过 127.0.0.1:5037 与 ADB Server 通信
public actor ADBClient {
    private let host: String
    private let port: UInt16
    private let logger = Logger(subsystem: "com.shawnrain.CandyMonitor", category: "ADBClient")

    public init(host: String = "127.0.0.1", port: UInt16 = 5037) {
        self.host = host
        self.port = port
    }

    // MARK: - Server Info & Status

    public func checkServerVersion(timeout: TimeInterval = 2.0) async throws -> Int {
        let raw = try await executeHostCommand("host:version", timeout: timeout)
        guard let ver = Int(raw, radix: 16) else {
            throw ADBError.protocolError("无法解析 ADB 版本响应: \(raw)")
        }
        return ver
    }

    // MARK: - Device Listing

    public func listDevices(timeout: TimeInterval = 3.0) async throws -> [ADBRawDevice] {
        let raw = try await executeHostCommand("host:devices-l", timeout: timeout)
        return parseDevicesList(raw)
    }

    // MARK: - Wireless Pairing & Connecting

    /// 配对无线调试设备: host:pair:<password>:<host>:<port>
    public func pair(host: String, port: Int, pairingCode: String, timeout: TimeInterval = 8.0) async throws -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = "host:pair:\(cleanCode):\(cleanHost):\(port)"
        return try await executeHostCommand(cmd, timeout: timeout)
    }

    /// 连接无线调试设备: host:connect:<host>:<port>
    public func connect(host: String, port: Int, timeout: TimeInterval = 6.0) async throws -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = "host:connect:\(cleanHost):\(port)"
        return try await executeHostCommand(cmd, timeout: timeout)
    }

    /// 断开设备连接: host:disconnect:<host>:<port>
    public func disconnect(host: String, port: Int, timeout: TimeInterval = 4.0) async throws -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = "host:disconnect:\(cleanHost):\(port)"
        return try await executeHostCommand(cmd, timeout: timeout)
    }

    // MARK: - Device Commands

    /// 获取设备实时电池数据（解析 dumpsys battery）
    public func queryBattery(serial: String, timeout: TimeInterval = 2.5) async throws -> ADBBatteryStatus {
        let rawOutput = try await executeDeviceCommand(serial: serial, command: "exec:dumpsys battery", timeout: timeout)
        guard let status = parseBatteryOutput(rawOutput) else {
            return try await queryBatteryFallback(serial: serial, timeout: timeout)
        }
        return status
    }

    /// 获取系统属性（如 ro.product.model, ro.product.brand）
    public func getProperty(serial: String, key: String, timeout: TimeInterval = 2.0) async throws -> String {
        let res = try await executeDeviceCommand(serial: serial, command: "exec:getprop \(key)", timeout: timeout)
        return res.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 备用快速路径：读取 /sys/class/power_supply/battery/
    private func queryBatteryFallback(serial: String, timeout: TimeInterval) async throws -> ADBBatteryStatus {
        let capStr = try await executeDeviceCommand(serial: serial, command: "exec:cat /sys/class/power_supply/battery/capacity", timeout: timeout)
        let tempStr = try? await executeDeviceCommand(serial: serial, command: "exec:cat /sys/class/power_supply/battery/temp", timeout: timeout)
        let voltStr = try? await executeDeviceCommand(serial: serial, command: "exec:cat /sys/class/power_supply/battery/voltage_now", timeout: timeout)
        let statusStr = try? await executeDeviceCommand(serial: serial, command: "exec:cat /sys/class/power_supply/battery/status", timeout: timeout)

        guard let level = Double(capStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ADBError.protocolError("无法读取电池电量: \(capStr)")
        }

        var tempC = 25.0
        if let rawTemp = tempStr.flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            if rawTemp > 1000 {
                tempC = rawTemp / 1000.0
            } else if rawTemp > 100 {
                tempC = rawTemp / 10.0
            } else {
                tempC = rawTemp
            }
        }

        var voltMV = 4000
        if let rawVolt = voltStr.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            voltMV = rawVolt > 100_000 ? rawVolt / 1000 : rawVolt
        }

        var statusVal = 2
        if let s = statusStr?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            if s.contains("discharging") { statusVal = 3 }
            else if s.contains("not charging") { statusVal = 4 }
            else if s.contains("full") { statusVal = 5 }
        }

        return ADBBatteryStatus(
            level: level,
            voltageMV: voltMV,
            temperatureC: tempC,
            status: statusVal,
            health: 2,
            isPresent: true
        )
    }

    // MARK: - Low-level Protocol Communication

    /// 执行主机命令（如 host:version, host:devices-l, host:connect:..., host:pair:...）
    private func executeHostCommand(_ command: String, timeout: TimeInterval) async throws -> String {
        try await withTimeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { continuation in
                let nwHost = NWEndpoint.Host(self.host)
                guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                    continuation.resume(throwing: ADBError.serverNotReachable("无效的端口"))
                    return
                }

                let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
                let guardContinuation = ContinuationGuard(continuation)

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let payload = String(format: "%04x%@", command.utf8.count, command)
                        guard let data = payload.data(using: .utf8) else {
                            guardContinuation.resume(with: .failure(ADBError.protocolError("UTF8 编码错误")), cleanup: { connection.cancel() })
                            return
                        }
                        connection.send(content: data, completion: .contentProcessed { error in
                            if let error = error {
                                guardContinuation.resume(with: .failure(ADBError.serverNotReachable(error.localizedDescription)), cleanup: { connection.cancel() })
                                return
                            }
                            // 1. 读取 4 字节状态 (OKAY / FAIL)
                            Self.readExactBytes(connection: connection, count: 4) { statusResult in
                                switch statusResult {
                                case .failure(let err):
                                    guardContinuation.resume(with: .failure(err), cleanup: { connection.cancel() })
                                case .success(let statusData):
                                    let status = String(data: statusData, encoding: .utf8) ?? ""
                                    if status == "OKAY" {
                                        // 2. 成功，读取接下来的 4 字节长度
                                        Self.readExactBytes(connection: connection, count: 4) { lenResult in
                                            switch lenResult {
                                            case .failure:
                                                guardContinuation.resume(with: .success(""), cleanup: { connection.cancel() })
                                            case .success(let lenData):
                                                guard let lenHex = String(data: lenData, encoding: .utf8),
                                                      let length = Int(lenHex, radix: 16) else {
                                                    guardContinuation.resume(with: .success(""), cleanup: { connection.cancel() })
                                                    return
                                                }
                                                if length <= 0 {
                                                    guardContinuation.resume(with: .success(""), cleanup: { connection.cancel() })
                                                    return
                                                }
                                                // 3. 读取指定长度的内容
                                                Self.readExactBytes(connection: connection, count: length) { bodyResult in
                                                    switch bodyResult {
                                                    case .failure(let err):
                                                        guardContinuation.resume(with: .failure(err), cleanup: { connection.cancel() })
                                                    case .success(let bodyData):
                                                        let responseStr = String(data: bodyData, encoding: .utf8) ?? ""
                                                        guardContinuation.resume(with: .success(responseStr), cleanup: { connection.cancel() })
                                                    }
                                                }
                                            }
                                        }
                                    } else {
                                        // FAIL 状态，读取错误长度与错误信息
                                        Self.readExactBytes(connection: connection, count: 4) { errLenResult in
                                            switch errLenResult {
                                            case .failure:
                                                guardContinuation.resume(with: .failure(ADBError.commandFailed("未知错误 (\(status))")), cleanup: { connection.cancel() })
                                            case .success(let errLenData):
                                                guard let lenHex = String(data: errLenData, encoding: .utf8),
                                                      let length = Int(lenHex, radix: 16), length > 0 else {
                                                    guardContinuation.resume(with: .failure(ADBError.commandFailed("执行失败 (\(status))")), cleanup: { connection.cancel() })
                                                    return
                                                }
                                                Self.readExactBytes(connection: connection, count: length) { errBodyResult in
                                                    let msg = (try? errBodyResult.get()).flatMap { String(data: $0, encoding: .utf8) } ?? status
                                                    guardContinuation.resume(with: .failure(ADBError.commandFailed(msg)), cleanup: { connection.cancel() })
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        })
                    case .failed(let error):
                        guardContinuation.resume(with: .failure(ADBError.serverNotReachable(error.localizedDescription)), cleanup: { connection.cancel() })
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
                connection.start(queue: .global())
            }
        }
    }

    /// 执行设备端命令（host:transport:<serial> -> exec:<cmd> / shell:<cmd> -> 持续读取输出流至结束）
    private func executeDeviceCommand(serial: String, command: String, timeout: TimeInterval) async throws -> String {
        try await withTimeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { continuation in
                let nwHost = NWEndpoint.Host(self.host)
                guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                    continuation.resume(throwing: ADBError.serverNotReachable("无效的端口"))
                    return
                }

                let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
                let guardContinuation = ContinuationGuard(continuation)

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        // 1. 发送 host:transport:<serial>
                        let transportCmd = "host:transport:\(serial)"
                        let transportPayload = String(format: "%04x%@", transportCmd.utf8.count, transportCmd)
                        guard let tData = transportPayload.data(using: .utf8) else {
                            guardContinuation.resume(with: .failure(ADBError.protocolError("编码错误")), cleanup: { connection.cancel() })
                            return
                        }

                        connection.send(content: tData, completion: .contentProcessed { error in
                            if let error = error {
                                guardContinuation.resume(with: .failure(ADBError.serverNotReachable(error.localizedDescription)), cleanup: { connection.cancel() })
                                return
                            }

                            // 2. 读取 transport 应答 (OKAY / FAIL)
                            Self.readExactBytes(connection: connection, count: 4) { tResult in
                                switch tResult {
                                case .failure(let err):
                                    guardContinuation.resume(with: .failure(err), cleanup: { connection.cancel() })
                                case .success(let tStatusData):
                                    let tStatus = String(data: tStatusData, encoding: .utf8) ?? ""
                                    guard tStatus == "OKAY" else {
                                        guardContinuation.resume(with: .failure(ADBError.deviceNotFound(serial)), cleanup: { connection.cancel() })
                                        return
                                    }

                                    // 3. 发送具体命令（如 exec:dumpsys battery）
                                    let cmdPayload = String(format: "%04x%@", command.utf8.count, command)
                                    guard let cData = cmdPayload.data(using: .utf8) else {
                                        guardContinuation.resume(with: .failure(ADBError.protocolError("编码错误")), cleanup: { connection.cancel() })
                                        return
                                    }

                                    connection.send(content: cData, completion: .contentProcessed { error in
                                        if let error = error {
                                            guardContinuation.resume(with: .failure(ADBError.commandFailed(error.localizedDescription)), cleanup: { connection.cancel() })
                                            return
                                        }

                                        // 4. 读取命令初步应答
                                        Self.readExactBytes(connection: connection, count: 4) { cmdResult in
                                            switch cmdResult {
                                            case .failure(let err):
                                                guardContinuation.resume(with: .failure(err), cleanup: { connection.cancel() })
                                            case .success(let cmdStatusData):
                                                let cmdStatus = String(data: cmdStatusData, encoding: .utf8) ?? ""
                                                guard cmdStatus == "OKAY" else {
                                                    guardContinuation.resume(with: .failure(ADBError.commandFailed("命令执行被拒绝: \(cmdStatus)")), cleanup: { connection.cancel() })
                                                    return
                                                }

                                                // 5. 持续流式接收数据直至 EOF 或连接关闭
                                                Self.readStreamUntilComplete(connection: connection) { streamResult in
                                                    switch streamResult {
                                                    case .failure(let err):
                                                        guardContinuation.resume(with: .failure(err), cleanup: { connection.cancel() })
                                                    case .success(let fullData):
                                                        let output = String(data: fullData, encoding: .utf8) ?? ""
                                                        guardContinuation.resume(with: .success(output), cleanup: { connection.cancel() })
                                                    }
                                                }
                                            }
                                        }
                                    })
                                }
                            }
                        })
                    case .failed(let error):
                        guardContinuation.resume(with: .failure(ADBError.serverNotReachable(error.localizedDescription)), cleanup: { connection.cancel() })
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
                connection.start(queue: .global())
            }
        }
    }

    // MARK: - Helpers

    /// 准确读取指定字节数
    private static func readExactBytes(
        connection: NWConnection,
        count: Int,
        accumulated: Data = Data(),
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        let remaining = count - accumulated.count
        guard remaining > 0 else {
            completion(.success(accumulated))
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data, !data.isEmpty else {
                if isComplete {
                    completion(.success(accumulated))
                } else {
                    completion(.failure(ADBError.protocolError("连接过早关闭")))
                }
                return
            }

            var nextAccumulated = accumulated
            nextAccumulated.append(data)
            if nextAccumulated.count >= count {
                completion(.success(nextAccumulated.prefix(count)))
            } else {
                readExactBytes(connection: connection, count: count, accumulated: nextAccumulated, completion: completion)
            }
        }
    }

    /// 持续读取流式数据直至连接结束 (isComplete)
    private static func readStreamUntilComplete(
        connection: NWConnection,
        accumulated: Data = Data(),
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var current = accumulated
            if let data = data, !data.isEmpty {
                current.append(data)
            }

            if isComplete {
                completion(.success(current))
                return
            }

            if let error = error {
                // 如果已经有数据，且为正常连接重置/关闭，视作成功结束
                if !current.isEmpty {
                    completion(.success(current))
                } else {
                    completion(.failure(error))
                }
                return
            }

            readStreamUntilComplete(connection: connection, accumulated: current, completion: completion)
        }
    }

    /// 超时包装器
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ADBError.timeout
            }
            guard let result = try await group.next() else {
                throw ADBError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Parsers

    private func parseDevicesList(_ raw: String) -> [ADBRawDevice] {
        var list: [ADBRawDevice] = []
        let lines = raw.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            let serial = parts[0]
            let state = parts[1]

            var product: String?
            var model: String?
            var device: String?
            var transportId: String?

            for part in parts.dropFirst(2) {
                let kv = part.components(separatedBy: ":")
                guard kv.count == 2 else { continue }
                let k = kv[0]
                let v = kv[1]
                switch k {
                case "product": product = v
                case "model": model = v
                case "device": device = v
                case "transport_id": transportId = v
                default: break
                }
            }

            list.append(ADBRawDevice(
                serial: serial,
                state: state,
                product: product,
                model: model,
                device: device,
                transportId: transportId
            ))
        }
        return list
    }

    private func parseBatteryOutput(_ raw: String) -> ADBBatteryStatus? {
        guard !raw.isEmpty else { return nil }
        var level: Double?
        var scale: Double = 100.0
        var voltageMV: Int?
        var tempRaw: Double?
        var status = 1
        var health = 1
        var present = true

        let lines = raw.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "level":
                level = Double(val)
            case "scale":
                if let s = Double(val), s > 0 { scale = s }
            case "voltage":
                voltageMV = Int(val)
            case "temperature":
                tempRaw = Double(val)
            case "status":
                status = Int(val) ?? 1
            case "health":
                health = Int(val) ?? 1
            case "present":
                present = (val.lowercased() == "true")
            default:
                break
            }
        }

        guard let rawLevel = level else { return nil }
        let normalizedLevel = (rawLevel / scale) * 100.0

        let finalTemp: Double
        if let rawT = tempRaw {
            if rawT > 1000 {
                finalTemp = rawT / 1000.0
            } else if rawT > 100 {
                finalTemp = rawT / 10.0
            } else {
                finalTemp = rawT
            }
        } else {
            finalTemp = 25.0
        }

        return ADBBatteryStatus(
            level: normalizedLevel,
            voltageMV: voltageMV ?? 4000,
            temperatureC: finalTemp,
            status: status,
            health: health,
            isPresent: present
        )
    }
}
