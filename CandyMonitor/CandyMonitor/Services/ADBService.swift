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
    var discoveredLANDevices: [DiscoveredADBDevice] = []
    var isDiscoveringLAN: Bool = false
    var portBindings: [Int: String] = [:] // PortIndex -> DeviceSerial
    var recentConnections: [ADBConnectionHistory] = []
    var isPolling: Bool = false
    var lastErrorMessage: String?
    var detectedADBPath: String?
    var detectedPlatformToolsVersion: String?
    var availableInstallations: [ADBInstallation] = []
    let updateChecker = ADBUpdateChecker.shared

    private var bonjourBrowser: ADBBonjourBrowser?

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
        startDiscovery()
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
        return devices.first { $0.serial == serial || $0.hardwareSerial == serial || ($0.ip != nil && $0.ip == serial) }
    }

    func boundPort(for deviceSerial: String) -> Int? {
        if let port = portBindings.first(where: { $0.value == deviceSerial })?.key {
            return port
        }
        if let dev = devices.first(where: { $0.serial == deviceSerial || $0.hardwareSerial == deviceSerial }),
           let hw = dev.hardwareSerial {
            return portBindings.first(where: { $0.value == hw })?.key
        }
        return nil
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
            serverState = .checking
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
            var didRunDirectly = false
            do {
                try process.run()
                process.waitUntilExit()
                didRunDirectly = (process.terminationStatus == 0)
            } catch {
                didRunDirectly = false
            }

            if !didRunDirectly {
                let tempDir = FileManager.default.temporaryDirectory
                let startScript = tempDir.appendingPathComponent("candymonitor_start_adb.command")
                let content = "#!/bin/bash\nkillall -9 adb 2>/dev/null || true\n\"\(adbPath)\" start-server 2>/dev/null || true\nexit 0\n"
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

    // MARK: - Bonjour / mDNS Discovery

    func startDiscovery() {
        guard bonjourBrowser == nil else { return }
        isDiscoveringLAN = true
        bonjourBrowser = ADBBonjourBrowser { [weak self] devices in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.discoveredLANDevices = devices
                self.enrichDevicesWithDiscoveredInfo()
            }
        }
        bonjourBrowser?.start()
    }

    func stopDiscovery() {
        bonjourBrowser?.stop()
        bonjourBrowser = nil
        isDiscoveringLAN = false
    }

    func refreshLANDevices() {
        stopDiscovery()
        startDiscovery()
    }

    private func enrichDevicesWithDiscoveredInfo() {
        var changed = false
        for i in 0..<devices.count {
            if devices[i].ip == nil || devices[i].port == nil {
                let devHW = devices[i].hardwareSerial
                if let match = discoveredLANDevices.first(where: {
                    devices[i].serial.contains($0.serial) ||
                    devices[i].serial.contains($0.serviceName) ||
                    (devHW != nil && !devHW!.isEmpty && $0.serial.contains(devHW!)) ||
                    (!devices[i].model.isEmpty && devices[i].model == $0.model)
                }) {
                    devices[i].ip = match.host
                    devices[i].port = match.port
                    if devices[i].model.isEmpty { devices[i].model = match.model }
                    if devices[i].hardwareSerial == nil && !match.serial.isEmpty {
                        devices[i].hardwareSerial = match.serial
                    }
                    changed = true
                }
            }
        }
        if changed {
            onDevicesRefreshed?(devices)
        }
    }

    // MARK: - Pairing & Connecting

    func pair(host: String, port: Int, code: String, debugPort: Int? = nil) async -> Result<String, Error> {
        do {
            let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await client.pair(host: cleanHost, port: port, pairingCode: code)
            
            // 如果提供了单独的调试端口或使用相同端口，自动连接
            let targetConnectPort = debugPort ?? port
            if let _ = try? await client.connect(host: cleanHost, port: targetConnectPort) {
                let displayName = discoveredLANDevices.first(where: { $0.host == cleanHost && $0.port == targetConnectPort })?.displayName
                addRecentConnection(host: cleanHost, port: targetConnectPort, displayName: displayName)
            }
            
            lastErrorMessage = nil
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
            let displayName = discoveredLANDevices.first(where: { $0.host == cleanHost && $0.port == port })?.displayName
            addRecentConnection(host: cleanHost, port: port, displayName: displayName)
            lastErrorMessage = nil
            await refreshOnce()
            return .success(result)
        } catch {
            let desc = error.localizedDescription
            if desc.contains("No route to host") {
                lastErrorMessage = "无法路由到 \(host):\(port) (No route to host)。请点击「重启守护进程」重置 ADB 路由缓存。"
            } else if desc.contains("Connection refused") {
                lastErrorMessage = "设备连接被拒绝 (\(host):\(port))。手机端无线调试端口可能已发生变动，请点击局域网发现的最新端口或重新开启无线调试。"
            } else {
                lastErrorMessage = desc
            }
            return .failure(error)
        }
    }

    func disconnect(serial: String) async -> Result<String, Error> {
        do {
            if serial.contains(":") {
                let parts = serial.components(separatedBy: ":")
                if parts.count == 2, let port = Int(parts[1]) {
                    _ = try await client.disconnect(host: parts[0], port: port)
                }
            } else if let dev = devices.first(where: { $0.serial == serial || $0.hardwareSerial == serial }),
                      let ip = dev.ip, let port = dev.port {
                _ = try await client.disconnect(host: ip, port: port)
            }
            devices.removeAll { $0.serial == serial || $0.hardwareSerial == serial }
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
            let lanDevices = self.discoveredLANDevices

            let queriedDevices: [ADBDevice] = await withTaskGroup(of: ADBDevice.self) { group in
                for raw in rawList {
                    group.addTask { [client, lanDevices, raw, existingDevices] in
                        var current = existingDevices.first(where: {
                            $0.serial == raw.serial ||
                            ($0.ip != nil && raw.ip != nil && $0.ip == raw.ip)
                        }) ?? ADBDevice(
                            serial: raw.serial,
                            isOnline: raw.isOnline,
                            isWireless: raw.isWireless,
                            ip: raw.ip,
                            port: raw.port
                        )

                        current.isOnline = raw.isOnline
                        current.isWireless = raw.isWireless
                        current.ip = raw.ip ?? current.ip
                        current.port = raw.port ?? current.port

                        // 尝试通过局域网自动发现补齐 IP 与端口（针对 mDNS TLS 设备）
                        if current.ip == nil || current.port == nil {
                            if let match = lanDevices.first(where: {
                                raw.serial.contains($0.serial) ||
                                raw.serial.contains($0.serviceName) ||
                                (raw.model != nil && raw.model == $0.model)
                            }) {
                                current.ip = match.host
                                current.port = match.port
                                if current.model.isEmpty { current.model = match.model }
                                if current.hardwareSerial == nil && !match.serial.isEmpty {
                                    current.hardwareSerial = match.serial
                                }
                            }
                        }

                        // 如果在线，尝试查询 ro.serialno / ro.boot.serialno
                        if current.isOnline {
                            if current.hardwareSerial == nil || current.hardwareSerial?.isEmpty == true {
                                if let hw = try? await client.getProperty(serial: raw.serial, key: "ro.serialno"), !hw.isEmpty, hw.lowercased() != "unknown" {
                                    current.hardwareSerial = hw
                                } else if let hwBoot = try? await client.getProperty(serial: raw.serial, key: "ro.boot.serialno"), !hwBoot.isEmpty, hwBoot.lowercased() != "unknown" {
                                    current.hardwareSerial = hwBoot
                                }
                            }

                            // 如果未获取到品牌和型号，尝试查询
                            if current.model.isEmpty || current.brand.isEmpty {
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
                            if let battery = try? await client.queryBattery(serial: raw.serial) {
                                current.batteryPercent = battery.level
                                current.batteryVoltageMV = battery.voltageMV
                                current.batteryTempC = battery.temperatureC
                                current.batteryStatus = battery.statusText
                                current.isCharging = battery.isCharging
                                current.lastSeenAt = battery.timestamp
                            }
                        }

                        // 若非无线设备且不含:，其 serial 本身就是 USB 硬件序列号
                        if current.hardwareSerial == nil && !raw.isWireless && !raw.serial.contains(":") {
                            current.hardwareSerial = raw.serial
                        }

                        return current
                    }
                }

                var results: [ADBDevice] = []
                for await device in group {
                    results.append(device)
                }
                return results
            }

            // 按物理设备去重与归并 (Deduplication into Physical Devices)
            var grouped: [[ADBDevice]] = []
            for dev in queriedDevices {
                var matchedIdx: Int? = nil
                for (idx, group) in grouped.enumerated() {
                    if group.contains(where: { item in
                        // 校验1: 相同且非空的硬件序列号
                        if let hw1 = dev.hardwareSerial, !hw1.isEmpty,
                           let hw2 = item.hardwareSerial, !hw2.isEmpty,
                           hw1.lowercased() == hw2.lowercased() {
                            return true
                        }
                        // 校验2: 相同且非空的 IP 地址
                        if let ip1 = dev.ip, !ip1.isEmpty,
                           let ip2 = item.ip, !ip2.isEmpty,
                           ip1 == ip2 {
                            return true
                        }
                        // 校验3: 序列号与硬件序列号互相关联
                        if let hw = item.hardwareSerial, !hw.isEmpty, dev.serial.contains(hw) {
                            return true
                        }
                        if let hw = dev.hardwareSerial, !hw.isEmpty, item.serial.contains(hw) {
                            return true
                        }
                        return false
                    }) {
                        matchedIdx = idx
                        break
                    }
                }

                if let idx = matchedIdx {
                    grouped[idx].append(dev)
                } else {
                    grouped.append([dev])
                }
            }

            let updatedDevices: [ADBDevice] = grouped.map { group in
                let primary = group.max(by: { a, b in
                    if a.isOnline != b.isOnline {
                        return !a.isOnline && b.isOnline
                    }
                    if (a.batteryPercent != nil) != (b.batteryPercent != nil) {
                        return a.batteryPercent == nil
                    }
                    if a.isMDNSWireless != b.isMDNSWireless {
                        return a.isMDNSWireless && !b.isMDNSWireless
                    }
                    return false
                }) ?? group[0]

                var merged = primary
                merged.hasUSBConnection = group.contains(where: { !$0.isWireless })
                merged.hasWirelessConnection = group.contains(where: { $0.isWireless })

                for item in group {
                    if merged.hardwareSerial == nil || merged.hardwareSerial?.isEmpty == true {
                        merged.hardwareSerial = item.hardwareSerial
                    }
                    if merged.brand.isEmpty { merged.brand = item.brand }
                    if merged.model.isEmpty { merged.model = item.model }
                    if merged.ip == nil { merged.ip = item.ip }
                    if merged.port == nil { merged.port = item.port }
                    if merged.batteryPercent == nil {
                        merged.batteryPercent = item.batteryPercent
                        merged.batteryVoltageMV = item.batteryVoltageMV
                        merged.batteryTempC = item.batteryTempC
                        merged.batteryStatus = item.batteryStatus
                        merged.isCharging = item.isCharging
                    }
                }

                return merged
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
            if d1.id != d2.id ||
               d1.serial != d2.serial ||
               d1.hardwareSerial != d2.hardwareSerial ||
               d1.isOnline != d2.isOnline ||
               d1.isWireless != d2.isWireless ||
               d1.hasUSBConnection != d2.hasUSBConnection ||
               d1.hasWirelessConnection != d2.hasWirelessConnection ||
               d1.ip != d2.ip ||
               d1.port != d2.port ||
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

// MARK: - Bonjour / mDNS Local Network Browser

final class ADBBonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let browserTLS = NetServiceBrowser()
    private let browserPlain = NetServiceBrowser()
    private var resolvingServices: [NetService] = []
    private var discoveredMap: [String: DiscoveredADBDevice] = [:]
    private let onUpdate: @Sendable ([DiscoveredADBDevice]) -> Void
    private let lock = NSLock()

    init(onUpdate: @escaping @Sendable ([DiscoveredADBDevice]) -> Void) {
        self.onUpdate = onUpdate
        super.init()
        browserTLS.delegate = self
        browserPlain.delegate = self
    }

    func start() {
        browserTLS.searchForServices(ofType: "_adb-tls-connect._tcp.", inDomain: "local.")
        browserPlain.searchForServices(ofType: "_adb._tcp.", inDomain: "local.")
    }

    func stop() {
        browserTLS.stop()
        browserPlain.stop()
        lock.lock()
        resolvingServices.forEach { $0.stop() }
        resolvingServices.removeAll()
        discoveredMap.removeAll()
        lock.unlock()
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        lock.lock()
        resolvingServices.append(service)
        lock.unlock()
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        lock.lock()
        resolvingServices.removeAll { $0 == service || $0.name == service.name }
        discoveredMap.removeValue(forKey: service.name)
        let currentList = Array(discoveredMap.values).sorted(by: { $0.displayName < $1.displayName })
        lock.unlock()
        onUpdate(currentList)
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ service: NetService) {
        let port = service.port
        guard port > 0 else { return }

        var ip: String?
        if let addresses = service.addresses {
            for addrData in addresses {
                if let parsedIP = parseIPv4(from: addrData) {
                    ip = parsedIP
                    break
                }
            }
        }
        guard let hostIP = ip, !hostIP.isEmpty else { return }

        var givenName = ""
        var model = ""
        var serial = ""

        if let txtData = service.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txtData)
            if let gnData = dict["given_name"], let gn = String(data: gnData, encoding: .utf8) {
                givenName = gn
            }
            if let nData = dict["name"], let n = String(data: nData, encoding: .utf8) {
                model = n
            }
            if let sData = dict["serial"], let s = String(data: sData, encoding: .utf8) {
                serial = s
            }
        }

        let dev = DiscoveredADBDevice(
            name: givenName,
            host: hostIP,
            port: port,
            model: model,
            serial: serial,
            serviceName: service.name,
            lastSeenAt: Date()
        )

        lock.lock()
        discoveredMap[service.name] = dev
        let currentList = Array(discoveredMap.values).sorted(by: { $0.displayName < $1.displayName })
        lock.unlock()

        onUpdate(currentList)
    }

    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        lock.lock()
        resolvingServices.removeAll { $0 == service }
        lock.unlock()
    }

    private func parseIPv4(from addressData: Data) -> String? {
        addressData.withUnsafeBytes { ptr -> String? in
            guard let base = ptr.baseAddress else { return nil }
            let sockaddr = base.bindMemory(to: sockaddr.self, capacity: 1)
            if sockaddr.pointee.sa_family == UInt8(AF_INET) {
                let sin = base.bindMemory(to: sockaddr_in.self, capacity: 1)
                var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sinAddr = sin.pointee.sin_addr
                if inet_ntop(AF_INET, &sinAddr, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: ipBuffer)
                }
            }
            return nil
        }
    }
}
