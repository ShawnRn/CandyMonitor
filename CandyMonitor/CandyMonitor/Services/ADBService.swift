import Foundation
import Observation
import os

enum ADBServerState: Equatable, Sendable {
    case unknown
    case checking
    case running(version: Int)
    case stopped(pathFound: String?)
    case notInstalled

    var isReady: Bool {
        if case .running = self { return true }
        return false
    }

    var statusDescription: String {
        switch self {
        case .unknown: "未检测"
        case .checking: "正在检测..."
        case .running(let ver): "运行中 (v\(ver))"
        case .stopped(let path): path != nil ? "服务未启动 (已找到 adb)" : "服务未启动"
        case .notInstalled: "未检测到 ADB 工具"
        }
    }
}

@Observable
@MainActor
final class ADBService {
    static let shared = ADBService()

    var serverState: ADBServerState = .unknown
    var devices: [ADBDevice] = []
    var portBindings: [Int: String] = [:] // PortIndex -> DeviceSerial
    var recentConnections: [ADBConnectionHistory] = []
    var isPolling: Bool = false
    var lastErrorMessage: String?
    var detectedADBPath: String?
    var customADBPath: String = "" {
        didSet {
            UserDefaults.standard.set(customADBPath, forKey: customADBPathKey)
        }
    }

    var onDevicesRefreshed: (@MainActor ([ADBDevice]) -> Void)?

    private let client = ADBClient()
    private var pollingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.shawnrain.CandyMonitor", category: "ADBService")

    private let portBindingsKey = "CandyMonitor.ADBPortBindings.v1"
    private let recentConnectionsKey = "CandyMonitor.ADBRecentConnections.v1"
    private let customADBPathKey = "CandyMonitor.ADBCustomPath.v1"

    init() {
        loadPersistedState()
        checkEnvironment()
    }

    // MARK: - State Persistence

    private func loadPersistedState() {
        customADBPath = UserDefaults.standard.string(forKey: customADBPathKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: portBindingsKey),
           let decoded = try? JSONDecoder().decode([Int: String].self, from: data) {
            portBindings = decoded
        }
        if let data = UserDefaults.standard.data(forKey: recentConnectionsKey),
           let decoded = try? JSONDecoder().decode([ADBConnectionHistory].self, from: data) {
            recentConnections = decoded
        }
    }

    private func savePortBindings() {
        if let data = try? JSONEncoder().encode(portBindings) {
            UserDefaults.standard.set(data, forKey: portBindingsKey)
        }
    }

    private func saveRecentConnections() {
        if let data = try? JSONEncoder().encode(recentConnections) {
            UserDefaults.standard.set(data, forKey: recentConnectionsKey)
        }
    }

    func addRecentConnection(host: String, port: Int, displayName: String?) {
        var list = recentConnections.filter { !($0.host == host && $0.port == port) }
        list.insert(ADBConnectionHistory(host: host, port: port, displayName: displayName, lastConnectedAt: Date()), at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        recentConnections = list
        saveRecentConnections()
    }

    func removeRecentConnection(host: String, port: Int) {
        recentConnections.removeAll { $0.host == host && $0.port == port }
        saveRecentConnections()
    }

    // MARK: - Port Binding

    func bindPort(_ portIndex: Int, to deviceSerial: String?) {
        if let deviceSerial, !deviceSerial.isEmpty {
            portBindings[portIndex] = deviceSerial
        } else {
            portBindings.removeValue(forKey: portIndex)
        }
        savePortBindings()
    }

    func boundDevice(for portIndex: Int) -> ADBDevice? {
        guard let serial = portBindings[portIndex] else { return nil }
        return devices.first { $0.serial == serial }
    }

    func boundPort(for deviceSerial: String) -> Int? {
        portBindings.first(where: { $0.value == deviceSerial })?.key
    }

    // MARK: - Environment & Server Detection

    func checkEnvironment() {
        serverState = .checking
        detectedADBPath = scanLocalADBExecutable()

        Task {
            do {
                let version = try await client.checkServerVersion()
                await MainActor.run {
                    self.serverState = .running(version: version)
                    self.startPolling()
                }
            } catch {
                await MainActor.run {
                    if let path = self.detectedADBPath {
                        self.serverState = .stopped(pathFound: path)
                    } else {
                        self.serverState = .notInstalled
                    }
                }
            }
        }
    }

    func tryStartServer() {
        guard let adbPath = detectedADBPath ?? (customADBPath.isEmpty ? nil : customADBPath) else {
            lastErrorMessage = "未找到 adb 执行程序，请先安装 android-platform-tools"
            return
        }

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["start-server"]
            try? process.run()
            process.waitUntilExit()

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                self.checkEnvironment()
            }
        }
    }

    private func scanLocalADBExecutable() -> String? {
        let candidates: [String] = [
            customADBPath,
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/android-sdk/platform-tools/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/usr/bin/adb"
        ]

        let fm = FileManager.default
        for path in candidates where !path.isEmpty {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Pairing & Connecting

    func pair(host: String, port: Int, code: String, debugPort: Int? = nil) async -> Result<String, Error> {
        do {
            let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await client.pair(host: cleanHost, port: port, pairingCode: code)
            
            // 如果提供了单独的调试端口或使用相同端口，自动连接
            let targetConnectPort = debugPort ?? port
            _ = try? await client.connect(host: cleanHost, port: targetConnectPort)
            
            addRecentConnection(host: cleanHost, port: targetConnectPort, displayName: nil)
            await refreshOnce()
            return .success(result)
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failure(error)
        }
    }

    func connect(host: String, port: Int) async -> Result<String, Error> {
        do {
            let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await client.connect(host: cleanHost, port: port)
            addRecentConnection(host: cleanHost, port: port, displayName: nil)
            await refreshOnce()
            return .success(result)
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failure(error)
        }
    }

    func disconnect(serial: String) async -> Result<String, Error> {
        do {
            let parts = serial.components(separatedBy: ":")
            if parts.count == 2, let port = Int(parts[1]) {
                _ = try await client.disconnect(host: parts[0], port: port)
            }
            devices.removeAll { $0.serial == serial }
            await refreshOnce()
            return .success("已断开")
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failure(error)
        }
    }

    // MARK: - Polling Loop (1Hz)

    func startPolling() {
        guard pollingTask == nil else { return }
        isPolling = true

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOnce()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    func refreshOnce() async {
        do {
            let rawList = try await client.listDevices()
            var updatedDevices: [ADBDevice] = []

            for raw in rawList {
                var current = devices.first(where: { $0.serial == raw.serial }) ?? ADBDevice(
                    serial: raw.serial,
                    isOnline: raw.isOnline,
                    isWireless: raw.isWireless,
                    ip: raw.ip,
                    port: raw.port
                )

                current.isOnline = raw.isOnline
                current.isWireless = raw.isWireless
                current.ip = raw.ip
                current.port = raw.port

                // 如果未获取到品牌和型号，尝试查询
                if current.isOnline && (current.model.isEmpty || current.brand.isEmpty) {
                    if let model = try? await client.getProperty(serial: raw.serial, key: "ro.product.model"), !model.isEmpty {
                        current.model = model
                    } else if let rawM = raw.model {
                        current.model = rawM
                    }
                    if let brand = try? await client.getProperty(serial: raw.serial, key: "ro.product.brand"), !brand.isEmpty {
                        current.brand = brand.capitalized
                    }
                }

                // 针对在线设备查询电池数据
                if current.isOnline {
                    if let battery = try? await client.queryBattery(serial: raw.serial) {
                        current.batteryPercent = battery.level
                        current.batteryVoltageMV = battery.voltageMV
                        current.batteryTempC = battery.temperatureC
                        current.batteryStatus = battery.statusText
                        current.isCharging = battery.isCharging
                        current.lastSeenAt = battery.timestamp
                    }
                }

                updatedDevices.append(current)
            }

            self.devices = updatedDevices
            self.onDevicesRefreshed?(updatedDevices)
            if case .stopped = self.serverState {
                self.serverState = .running(version: 41)
            }
        } catch {
            // 如果连接失败，标记状态
            if case .running = self.serverState {
                self.serverState = .stopped(pathFound: self.detectedADBPath)
            }
        }
    }
}
