import Foundation
import Observation
import os
import AppKit

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

public struct ADBInstallation: Identifiable, Equatable, Sendable {
    public let path: String
    public let version: String?
    public var id: String { path }
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
    var detectedPlatformToolsVersion: String?
    var availableInstallations: [ADBInstallation] = []
    let updateChecker = ADBUpdateChecker.shared

    var latestAlternativeInstallation: ADBInstallation? {
        guard let currentVer = detectedPlatformToolsVersion else {
            return availableInstallations.first(where: { $0.path != detectedADBPath && $0.version != nil })
        }
        return availableInstallations.first { inst in
            inst.path != detectedADBPath &&
            inst.version != nil &&
            ADBUpdateChecker.compareSemver(inst.version!, currentVer) == .orderedDescending
        }
    }

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
    private let customADBBookmarkKey = "CandyMonitor.ADBCustomPathBookmark.v1"

    init() {
        loadPersistedState()
        checkEnvironment()
    }

    // MARK: - State Persistence

    private func loadPersistedState() {
        if let bookmarkData = UserDefaults.standard.data(forKey: customADBBookmarkKey) {
            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                _ = resolvedURL.startAccessingSecurityScopedResource()
                customADBPath = resolvedURL.path
            }
        }
        if customADBPath.isEmpty {
            customADBPath = UserDefaults.standard.string(forKey: customADBPathKey) ?? ""
        }
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
        if let path = detectedADBPath {
            detectedPlatformToolsVersion = ADBUpdateChecker.parseVersionFromProperties(at: path)
        }

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

            // 触发在线更新与版本对照检测
            await self.updateChecker.checkForUpdates(installedVersion: self.detectedPlatformToolsVersion)
        }
    }

    func setCustomADBExecutableURL(_ url: URL) {
        if let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmarkData, forKey: customADBBookmarkKey)
        }
        _ = url.startAccessingSecurityScopedResource()
        customADBPath = url.path
        detectedADBPath = url.path
        detectedPlatformToolsVersion = ADBUpdateChecker.parseVersionFromProperties(at: url.path)
        checkEnvironment()
    }

    func switchToInstallation(_ installation: ADBInstallation) {
        customADBPath = installation.path
        detectedADBPath = installation.path
        detectedPlatformToolsVersion = installation.version
        restartServer()
    }

    func killServer() async {
        try? await client.killServer(timeout: 2.0)
        self.serverState = .stopped(pathFound: self.detectedADBPath)
    }

    func restartServer() {
        Task {
            await killServer()
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.tryStartServer()
        }
    }

    func runOneClickUpgrade() {
        updateChecker.runAutoUpgradeScript { [weak self] in
            self?.checkEnvironment()
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
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                let tempDir = FileManager.default.temporaryDirectory
                let startScript = tempDir.appendingPathComponent("candymonitor_start_adb.command")
                let content = "#!/bin/bash\n\"\(adbPath)\" start-server 2>/dev/null || true\nexit 0\n"
                if (try? content.write(to: startScript, atomically: true, encoding: .utf8)) != nil {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: startScript.path)
                    _ = NSWorkspace.shared.open(startScript)
                }
            }

            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                self.checkEnvironment()
            }
        }
    }

    private static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    private func scanLocalADBExecutable() -> String? {
        let home = Self.realHomeDirectory()
        let candidates: [String] = [
            customADBPath,
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            home + "/android-sdk/platform-tools/adb",
            home + "/Library/Android/sdk/platform-tools/adb",
            NSHomeDirectory() + "/android-sdk/platform-tools/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/usr/bin/adb"
        ]

        let fm = FileManager.default
        var found: [ADBInstallation] = []
        var seenPaths = Set<String>()

        for path in candidates where !path.isEmpty && !seenPaths.contains(path) {
            seenPaths.insert(path)
            if fm.isExecutableFile(atPath: path) || fm.fileExists(atPath: path) {
                let ver = ADBUpdateChecker.parseVersionFromProperties(at: path)
                found.append(ADBInstallation(path: path, version: ver))
            }
        }

        self.availableInstallations = found

        // 如果用户显式配置了自定义路径且依然存在，优先保留用户选择
        if !customADBPath.isEmpty, let customMatch = found.first(where: { $0.path == customADBPath }) {
            return customMatch.path
        }

        // 否则按语义化版本从大到小排序，自动选出系统中最高版本的 ADB
        let sorted = found.sorted { a, b in
            guard let v1 = a.version else { return false }
            guard let v2 = b.version else { return true }
            return ADBUpdateChecker.compareSemver(v1, v2) == .orderedDescending
        }

        return sorted.first?.path
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
            let existingDevices = self.devices

            let updatedDevices: [ADBDevice] = await withTaskGroup(of: ADBDevice.self) { group in
                for raw in rawList {
                    group.addTask { [client] in
                        var current = existingDevices.first(where: { $0.serial == raw.serial }) ?? ADBDevice(
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

                        return current
                    }
                }

                var results: [ADBDevice] = []
                for await device in group {
                    results.append(device)
                }
                // 保持与 rawList 原始顺序一致
                let orderMap = Dictionary(uniqueKeysWithValues: rawList.enumerated().map { ($1.serial, $0) })
                results.sort { (orderMap[$0.serial] ?? 0) < (orderMap[$1.serial] ?? 0) }
                return results
            }

            // 差量防抖：若业务数据无变化，避免重新触发 @Observable 通知风暴
            let hasChanged = !areDevicesEqual(self.devices, updatedDevices)
            if hasChanged {
                self.devices = updatedDevices
            }
            self.onDevicesRefreshed?(updatedDevices)

            if case .stopped = self.serverState {
                self.serverState = .running(version: 41)
            }
        } catch {
            if case .running = self.serverState {
                self.serverState = .stopped(pathFound: self.detectedADBPath)
            }
        }
    }

    private func areDevicesEqual(_ a: [ADBDevice], _ b: [ADBDevice]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            let d1 = a[i]
            let d2 = b[i]
            if d1.serial != d2.serial ||
               d1.isOnline != d2.isOnline ||
               d1.isWireless != d2.isWireless ||
               d1.batteryPercent != d2.batteryPercent ||
               d1.batteryVoltageMV != d2.batteryVoltageMV ||
               d1.batteryTempC != d2.batteryTempC ||
               d1.batteryStatus != d2.batteryStatus ||
               d1.isCharging != d2.isCharging ||
               d1.model != d2.model ||
               d1.brand != d2.brand {
                return false
            }
        }
        return true
    }
}
