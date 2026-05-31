import AppKit
import Foundation
import Observation
import os
import SwiftData
import UniformTypeIdentifiers

private struct DeviceSnapshot: Sendable {
    let id: UUID
    let name: String
    let keychainAccount: String
    let psn: String?

    init(_ device: MirrorDevice) {
        self.id = device.id
        self.name = device.name
        self.keychainAccount = device.keychainAccount
        self.psn = device.psn
    }
}

private struct SampleStats {
    let powerW: Double
    let voltageMV: Int
    let protocolName: String
    let batteryPercent: Double?
}

private struct RecordingResult {
    var didMutateStore = false
    var didChangeSessions = false
}

@Observable
@MainActor
final class MonitorStore {
    var devices: [MirrorDevice] = []
    var selectedDeviceID: UUID?
    var selectedSection: AppSection = .monitor
    var connectionState: ConnectionState = .idle
    var lastError: String?
    var livePorts: [PortViewState] = []
    var recentSamples: [ChartSamplePoint] = []
    var sessions: [ChargingSession] = []
    var selectedSession: ChargingSession?
    var selectedSessionSamples: [PortSample] = []
    var portStatsByPort: [Int: [String: String]] = [:]
    var lowPowerSessionPrompt: ChargingSession?
    var temperatureModeLabel = "-"
    var lastRefreshedAt: Date?
    var isRefreshingNow = false
    var isShowingAddDevice = false
    var isRealtimeRefreshEnabled = true {
        didSet {
            restartPollingIfNeeded()
        }
    }

    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var clients: [UUID: MCPClient] = [:]
    @ObservationIgnored private var pdStreamClients: [UUID: CandyIOTPDStatusClient] = [:]
    @ObservationIgnored private var iotJWTFetchAttempted: Set<UUID> = []
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var activeSessions: [String: UUID] = [:]
    @ObservationIgnored private var trickleStoppedKeys = Set<String>()
    @ObservationIgnored private var disconnectDebounce: [String: Int] = [:]
    @ObservationIgnored private var knownProtocols: [UUID: Set<String>] = [:]
    @ObservationIgnored private var cachedFacts: [UUID: MachineFacts] = [:]
    @ObservationIgnored private var factsRefreshedAt: [UUID: Date] = [:]
    @ObservationIgnored private var lastStoreSaveAt = Date.distantPast
    @ObservationIgnored private var lastDiagnosticRefreshLogAt = Date.distantPast
    
    // EMA smooth cache to prevent main-thread computation bottlenecks
    @ObservationIgnored private var emaPowerW: [String: Double] = [:]
    @ObservationIgnored private var emaVoltageV: [String: Double] = [:]
    @ObservationIgnored private var emaCurrentA: [String: Double] = [:]
    @ObservationIgnored private var emaTemperatureScore: [String: Double] = [:]
    @ObservationIgnored private var emaLastConnected: [String: Bool] = [:]
    
    // Status caching to prevent serial / network bottleneck
    @ObservationIgnored private var cachedChargingStatus: [UUID: ChargingStatus] = [:]
    @ObservationIgnored private var cachedTemperatureMode: [UUID: TemperatureModeResponse] = [:]
    @ObservationIgnored private var cachedPDStatus: [UUID: PDStatusEnvelope] = [:]
    @ObservationIgnored private var lastChargingRefreshedAt: [UUID: Date] = [:]
    @ObservationIgnored private var lastTemperatureRefreshedAt: [UUID: Date] = [:]
    @ObservationIgnored private var lastPDRefreshedAt: [UUID: Date] = [:]
    @ObservationIgnored private let ionBridgeDiscovery = IonBridgeDiscovery()
    
    // App Nap prevention activity token
    @ObservationIgnored private var activityToken: NSObjectProtocol?
    @ObservationIgnored private let selectedDeviceDefaultsKey = "CandyMonitor.SelectedDeviceID"
    @ObservationIgnored private let logger = Logger(subsystem: "com.shawnrain.CandyMonitor", category: "MonitorStore")
    @ObservationIgnored private let diagnosticLog = DiagnosticLog()
    @ObservationIgnored private let recentSampleWindow: TimeInterval = 10
    @ObservationIgnored private let recordingPowerThresholdW = 0.5
    @ObservationIgnored private let factsRefreshInterval: TimeInterval = 60
    @ObservationIgnored private let sampleSaveInterval: TimeInterval = 5
    @ObservationIgnored private let selectedSessionChartSampleLimit = 900
    @ObservationIgnored private let reconnectDelay: TimeInterval = 3
    @ObservationIgnored private let disconnectDebounceThreshold = 1

    var selectedDevice: MirrorDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID }
    }

    private var selectedDeviceSnapshot: DeviceSnapshot? {
        selectedDevice.map(DeviceSnapshot.init)
    }

    var hasDevices: Bool {
        !devices.isEmpty
    }

    var totalPowerW: Double {
        livePorts.reduce(0) { $0 + $1.powerW }
    }

    var activeChargingSessions: [ChargingSession] {
        sessions
            .filter { $0.endedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func configure(modelContext: ModelContext) {
        if self.modelContext == nil {
            self.modelContext = modelContext
            diagnosticLog.record("store_configured", metadata: ["log": diagnosticLog.path])
            loadDevices()
            loadSessions()
        }
    }

    func reloadPersistedState() {
        guard modelContext != nil else { return }
        loadDevices(restartPolling: false)
        loadSessions()
    }

    func loadDevices(restartPolling: Bool = true) {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<MirrorDevice>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        do {
            devices = try modelContext.fetch(descriptor)
        } catch {
            logger.error("device_fetch_failed \(error.localizedDescription, privacy: .public)")
            diagnosticLog.record("device_fetch_failed", metadata: ["error": error.localizedDescription])
            devices = []
        }
        if devices.isEmpty {
            restoreDevicesFromRegistryIfNeeded()
        } else {
            DeviceRegistry.save(devices)
        }
        if selectedDeviceID == nil,
           let persistedID = UserDefaults.standard.string(forKey: selectedDeviceDefaultsKey).flatMap(UUID.init(uuidString:)),
           devices.contains(where: { $0.id == persistedID }) {
            selectedDeviceID = persistedID
        }
        if selectedDeviceID == nil || devices.contains(where: { $0.id == selectedDeviceID }) == false {
            selectedDeviceID = devices.first?.id
        }
        hydrateRecentSamplesForSelectedDevice()
        diagnosticLog.record("devices_loaded", metadata: [
            "count": "\(devices.count)",
            "selected": selectedDeviceID?.uuidString ?? "-"
        ])
        if restartPolling {
            restartPollingIfNeeded()
        }
    }

    func loadSessions() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ChargingSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        var fetchedSessions = (try? modelContext.fetch(descriptor)) ?? []
        if mergeDuplicateActiveSessions(in: fetchedSessions, at: Date()) {
            try? modelContext.save()
            fetchedSessions = (try? modelContext.fetch(descriptor)) ?? []
        }
        sessions = fetchedSessions
        if let selectedSession {
            self.selectedSession = sessions.first { $0.id == selectedSession.id } ?? sessions.first
        } else {
            selectedSession = sessions.first
        }
        if let lowPowerSessionPrompt {
            self.lowPowerSessionPrompt = sessions.first { $0.id == lowPowerSessionPrompt.id }
        }
        restoreActiveSessions()
        loadSelectedSessionSamples()
    }

    func selectDevice(_ device: MirrorDevice) {
        guard selectedDeviceID != device.id else { return }
        selectedDeviceID = device.id
        UserDefaults.standard.set(device.id.uuidString, forKey: selectedDeviceDefaultsKey)
        livePorts = []
        hydrateRecentSamples(for: device)
        lowPowerSessionPrompt = nil
        connectionState = .idle
        restartPollingIfNeeded()
    }

    func ensureMonitoringActive(reason: String) {
        guard modelContext != nil else { return }
        if selectedDeviceSnapshot == nil {
            loadDevices()
            return
        }

        // If a polling task is actively running, don't kill it.
        // Only restart if the task is gone/cancelled, or if we're truly stale
        // (meaning we *had* a refresh but it stopped updating).
        let taskAlive = pollingTask != nil && pollingTask?.isCancelled == false
        let isStale: Bool
        if let lastRefreshedAt {
            isStale = Date().timeIntervalSince(lastRefreshedAt) > (isRealtimeRefreshEnabled ? 12 : 75)
        } else {
            // Never refreshed yet — only restart if the task isn't running
            isStale = !taskAlive
        }

        if !taskAlive || isStale {
            diagnosticLog.record("polling_watchdog_restart", metadata: [
                "reason": reason,
                "stale": "\(isStale)",
                "task_alive": "\(taskAlive)",
                "last_refresh": lastRefreshedAt?.ISO8601Format() ?? "-"
            ])
            restartPollingIfNeeded()
        }
    }

    func addDevice(name: String, sseURLString: String, iotJWTString: String = "") async throws {
        guard let url = URL(string: sseURLString), url.scheme?.hasPrefix("http") == true else {
            throw MonitorError.invalidURL
        }

        connectionState = .connecting
        let client = MCPClient(sseURL: url)
        let validation = try await client.validate()
        let account = UUID().uuidString
        try KeychainStore.saveMCPURL(sseURLString, account: account)
        let providedJWT = sanitizedIOTGatewayJWT(iotJWTString)
        let fetchedJWT = providedJWT == nil ? (try? await client.iotGatewayJWT(psn: validation.info.psn)) : nil
        if let jwt = providedJWT ?? fetchedJWT {
            try KeychainStore.saveIOTGatewayJWT(jwt, account: account)
        }

        let device = MirrorDevice(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "小电拼 Mirror" : name,
            keychainAccount: account,
            psn: validation.info.psn,
            model: validation.info.model,
            productFamily: validation.facts.productFamily,
            maxPowerBudget: validation.facts.maxPowerBudget,
            lastSeenAt: Date()
        )

        guard let modelContext else {
            throw MonitorError.storeUnavailable
        }
        modelContext.insert(device)
        try modelContext.save()
        clients[device.id] = client
        loadDevices()
        DeviceRegistry.save(devices)
        selectedDeviceID = device.id
        UserDefaults.standard.set(device.id.uuidString, forKey: selectedDeviceDefaultsKey)
        selectedSection = .monitor
        livePorts = validation.facts.ports.map {
            PortViewState(port: $0, detail: nil, pdStatus: nil, charging: false)
        }
        connectionState = .connected
        restartPollingIfNeeded()
    }

    func updateDevice(_ device: MirrorDevice, name: String, sseURLString: String, iotJWTString: String) async throws {
        guard let url = URL(string: sseURLString), url.scheme?.hasPrefix("http") == true else {
            throw MonitorError.invalidURL
        }

        let client = MCPClient(sseURL: url)
        let validation = try await client.validate()
        try KeychainStore.saveMCPURL(sseURLString, account: device.keychainAccount)
        if let jwt = sanitizedIOTGatewayJWT(iotJWTString) {
            try KeychainStore.saveIOTGatewayJWT(jwt, account: device.keychainAccount)
        } else {
            KeychainStore.deleteIOTGatewayJWT(account: device.keychainAccount)
        }
        if let streamClient = pdStreamClients.removeValue(forKey: device.id) {
            Task { await streamClient.disconnect() }
        }
        iotJWTFetchAttempted.remove(device.id)

        device.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? device.name : name
        device.psn = validation.info.psn
        device.model = validation.info.model
        device.productFamily = validation.facts.productFamily
        device.maxPowerBudget = validation.facts.maxPowerBudget
        device.lastSeenAt = Date()
        UserDefaults.standard.set(device.id.uuidString, forKey: selectedDeviceDefaultsKey)

        try modelContext?.save()
        clients[device.id] = client
        loadDevices()
        DeviceRegistry.save(devices)
        restartPollingIfNeeded()
    }

    func renameDevice(_ device: MirrorDevice, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false, device.name != trimmedName else { return }
        device.name = trimmedName
        try? modelContext?.save()
        loadDevices()
        DeviceRegistry.save(devices)
    }

    func mcpURL(for device: MirrorDevice) -> String {
        (try? KeychainStore.loadMCPURL(account: device.keychainAccount)) ?? ""
    }

    func iotGatewayJWT(for device: MirrorDevice) -> String {
        (try? KeychainStore.loadIOTGatewayJWT(account: device.keychainAccount)) ?? ""
    }

    func deleteSelectedDevice() {
        guard let modelContext, let device = selectedDevice else { return }
        stopPolling()
        KeychainStore.deleteMCPURL(account: device.keychainAccount)
        KeychainStore.deleteIOTGatewayJWT(account: device.keychainAccount)
        let client = clients[device.id]
        let streamClient = pdStreamClients[device.id]
        Task {
            await client?.disconnect()
            await streamClient?.disconnect()
        }
        clients[device.id] = nil
        pdStreamClients[device.id] = nil
        iotJWTFetchAttempted.remove(device.id)

        let deviceID = device.id
        deleteRows(ChargingSession.self) { $0.deviceID == deviceID }
        deleteRows(PortSample.self) { $0.deviceID == deviceID }
        deleteRows(ControlEvent.self) { $0.deviceID == deviceID }
        modelContext.delete(device)
        try? modelContext.save()

        devices.removeAll { $0.id == device.id }
        DeviceRegistry.save(devices)
        selectedDeviceID = devices.first?.id
        if let selectedDeviceID {
            UserDefaults.standard.set(selectedDeviceID.uuidString, forKey: selectedDeviceDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedDeviceDefaultsKey)
        }
        livePorts = []
        recentSamples = []
        loadSessions()
        restartPollingIfNeeded()
    }

    private func restoreDevicesFromRegistryIfNeeded() {
        guard let modelContext else { return }
        let records = DeviceRegistry.load()
            .filter { KeychainStore.hasMCPURL(account: $0.keychainAccount) }
        guard records.isEmpty == false else { return }

        let restoredDevices = records.map { record in
            MirrorDevice(
                id: record.id,
                name: record.name,
                keychainAccount: record.keychainAccount,
                psn: record.psn,
                model: record.model,
                productFamily: record.productFamily,
                maxPowerBudget: record.maxPowerBudget,
                createdAt: record.createdAt,
                lastSeenAt: record.lastSeenAt
            )
        }
        for device in restoredDevices {
            modelContext.insert(device)
        }
        do {
            try modelContext.save()
            devices = restoredDevices.sorted { $0.createdAt < $1.createdAt }
            logger.info("devices_restored_from_registry count=\(restoredDevices.count, privacy: .public)")
        } catch {
            logger.error("device_registry_restore_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restoreActiveSessions() {
        activeSessions.removeAll()
        let activeByKey = Dictionary(grouping: sessions.filter { $0.endedAt == nil }) {
            sessionKey(deviceID: $0.deviceID, port: $0.portIndex)
        }
        for (key, activeGroup) in activeByKey {
            guard let canonical = canonicalActiveSession(from: activeGroup) else { continue }
            activeSessions[key] = canonical.id
        }
        for session in activeByKey.values.flatMap({ $0 }) {
            if session.protocolSummary.isEmpty == false {
                knownProtocols[session.id] = Set(session.protocolSummary.components(separatedBy: " / "))
            }
        }
    }

    private func hydrateRecentSamplesForSelectedDevice() {
        guard let selectedDevice else {
            recentSamples = []
            return
        }
        hydrateRecentSamples(for: selectedDevice)
    }

    private func hydrateRecentSamples(for device: MirrorDevice) {
        guard let modelContext else {
            recentSamples = []
            return
        }
        let deviceID = device.id
        let cutoff = Date().addingTimeInterval(-recentSampleWindow)
        let descriptor = FetchDescriptor<PortSample>(
            predicate: #Predicate { sample in
                sample.deviceID == deviceID && sample.timestamp >= cutoff
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let samples = (try? modelContext.fetch(descriptor)) ?? []
        recentSamples = samples.map { sample in
            ChartSamplePoint(
                timestamp: sample.timestamp,
                portIndex: sample.portIndex,
                portName: sample.portName,
                connected: sample.connected == true,
                powerW: sample.powerW,
                voltageV: Double(sample.voltageMV) / 1000,
                currentA: Double(sample.currentMA) / 1000,
                temperatureScore: temperatureScore(sample.temperature ?? "")
            )
        }
    }

    func selectSession(_ session: ChargingSession) {
        selectedSession = session
        loadSelectedSessionSamples()
    }

    func loadSelectedSessionSamples() {
        guard let modelContext, let selectedSession else {
            selectedSessionSamples = []
            return
        }
        let id = selectedSession.id
        let descriptor = FetchDescriptor<PortSample>(
            predicate: #Predicate { sample in
                sample.sessionID == id
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        selectedSessionSamples = downsampleSessionSamples((try? modelContext.fetch(descriptor)) ?? [])
    }

    func stopSession(_ session: ChargingSession, reason: String = "manual") {
        guard let session = fetchSession(id: session.id), session.endedAt == nil else { return }
        end(session, at: Date(), reason: reason)
        lowPowerSessionPrompt = nil
        try? modelContext?.save()
        loadSessions()
    }

    func deleteSession(_ session: ChargingSession) {
        deleteSessions(ids: [session.id])
    }

    func deleteSessions(ids: Set<UUID>) {
        guard let modelContext, ids.isEmpty == false else { return }
        var deletedIDs = Set<UUID>()

        for sessionID in ids {
            guard let targetSession = fetchSession(id: sessionID) else { continue }
            let descriptor = FetchDescriptor<PortSample>(
                predicate: #Predicate { sample in
                    sample.sessionID == sessionID
                }
            )
            let samples = (try? modelContext.fetch(descriptor)) ?? []
            for sample in samples {
                modelContext.delete(sample)
            }

            activeSessions.removeValue(forKey: sessionKey(deviceID: targetSession.deviceID, port: targetSession.portIndex))
            knownProtocols[sessionID] = nil
            if lowPowerSessionPrompt?.id == sessionID {
                lowPowerSessionPrompt = nil
            }
            modelContext.delete(targetSession)
            deletedIDs.insert(sessionID)
        }

        if let selected = selectedSession, deletedIDs.contains(selected.id) {
            selectedSession = nil
            selectedSessionSamples = []
        }

        logger.info("sessions_deleted count=\(deletedIDs.count, privacy: .public)")
        try? modelContext.save()
        loadSessions()
        if selectedSession == nil {
            selectedSession = sessions.first
            loadSelectedSessionSamples()
        }
    }

    func renameSession(_ session: ChargingSession, title: String) {
        guard let session = fetchSession(id: session.id) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        try? modelContext?.save()
        loadSessions()
    }

    func exportSelectedSessionCSV() {
        guard let session = selectedSession else { return }
        exportSessionCSV(session)
    }

    func exportSelectedSessionZIP() {
        guard let session = selectedSession else { return }
        exportSessionZIP(session)
    }

    func exportSelectedSessionShareImage() {
        guard let session = selectedSession else { return }
        exportSessionShareImage(session)
    }

    func activeSession(for portIndex: Int) -> ChargingSession? {
        activeChargingSessions.first { $0.portIndex == portIndex }
    }

    func exportSessionCSV(_ session: ChargingSession) {
        let samples = samples(for: session)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(session.displayTitle)-full-charge.csv"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            let csv = CSVExporter.makeCSV(session: session, samples: samples)
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func exportSessionZIP(_ session: ChargingSession) {
        let samples = samples(for: session)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "zip")!]
        panel.nameFieldStringValue = "\(session.displayTitle)-full-charge.zip"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CandyMonitorExport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            try CSVExporter.makeREADME(session: session).write(to: tempRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try CSVExporter.makeCSV(session: session, samples: samples).write(to: tempRoot.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)
            try CSVExporter.makeEventsCSV(session: session, samples: samples).write(to: tempRoot.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)
            try CSVExporter.makeMetadataJSON(session: session, samples: samples).write(to: tempRoot.appendingPathComponent("metadata.json"), options: .atomic)
            try CSVExporter.makeAISummaryJSON(session: session, samples: samples).write(to: tempRoot.appendingPathComponent("ai_summary.json"), options: .atomic)
            try CSVExporter.makeSchemaJSON().write(to: tempRoot.appendingPathComponent("schema.json"), options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try zipDirectory(tempRoot, destination: url)
        } catch {
            logger.error("session_zip_export_failed \(error.localizedDescription, privacy: .public)")
        }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func exportSessionShareImage(_ session: ChargingSession) {
        let samples = samples(for: session)
        guard let png = SessionShareImageRenderer.pngData(session: session, samples: samples) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(session.displayTitle)-share.png"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url, options: .atomic)
        }
    }

    func previewSamples(for session: ChargingSession, limit: Int = 180) -> [PortSample] {
        let allSamples = samples(for: session)
        guard allSamples.count > limit else { return allSamples }
        let stride = Double(allSamples.count - 1) / Double(max(limit - 1, 1))
        return (0..<limit).map { index in
            allSamples[Int((Double(index) * stride).rounded())]
        }
    }

    private func zipDirectory(_ source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.lastPathComponent, destination.path]
        process.currentDirectoryURL = source.deletingLastPathComponent()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func refreshSelectedDeviceNow() async {
        guard let device = selectedDeviceSnapshot else { return }
        isRefreshingNow = true
        defer { isRefreshingNow = false }

        do {
            try await refreshWithReconnect(device: device, reason: "manual_refresh")
        } catch {
            connectionState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            diagnosticLog.record("manual_refresh_failed", metadata: [
                "device": device.id.uuidString,
                "error": error.localizedDescription
            ])
        }
    }

    func refreshPortStats(port: Int) async {
        guard let device = selectedDeviceSnapshot else { return }
        do {
            let client = try await client(for: device)
            let stats = try await client.portStats(port: port)
            portStatsByPort[port] = flattenStats(stats)
        } catch {
            logger.error("port_stats_failed port=\(port, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }

    private func samples(for session: ChargingSession) -> [PortSample] {
        guard let modelContext else { return [] }
        let id = session.id
        let descriptor = FetchDescriptor<PortSample>(
            predicate: #Predicate { sample in
                sample.sessionID == id
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func applyStrategy(_ strategy: ChargingStrategy) async {
        await runControl(action: "充电策略", detail: strategy.detail) { client in
            try await client.setChargingStrategy(strategy)
            _ = try await client.chargingStatus()
        }
    }

    func applyTemperatureMode(_ mode: TemperatureMode) async {
        await runControl(action: "温控模式", detail: mode.detail) { [self] client in
            try await client.setTemperatureMode(mode)
            let response = try await client.temperatureMode()
            temperatureModeLabel = response.modeName ?? mode.detail
        }
    }

    func setPort(_ port: Int, enabled: Bool) async {
        await runControl(action: enabled ? "开启端口" : "关闭端口", detail: LocalizedTelemetry.portName(port)) { client in
            if enabled {
                try await client.turnOnPort(port)
            } else {
                try await client.turnOffPort(port)
            }
            _ = try await client.chargingStatus()
        }
    }

    func applyPowerAllocation(_ watts: [Int]) async {
        await runControl(action: "功率分配", detail: watts.map(String.init).joined(separator: " / ")) { client in
            try await client.setPowerAllocation(watts)
            _ = try await client.portDetails()
        }
    }

    func applyCableCompensation(port: Int, gear: CableCompensationGear) async {
        await runControl(action: "线补档位", detail: "\(LocalizedTelemetry.portName(port)) \(gear.title)") { client in
            try await client.setCableCompensation(port: port, gear: gear)
        }
    }

    private func runControl(action: String, detail: String, operation: @escaping (MCPClient) async throws -> Void) async {
        guard let selectedDevice else { return }
        let device = DeviceSnapshot(selectedDevice)
        do {
            let client = try await client(for: device)
            try await operation(client)
            logControl(deviceID: device.id, deviceName: device.name, action: action, detail: detail, verified: true)
            
            // Invalidate status caches to force a fresh fetch immediately
            cachedChargingStatus.removeValue(forKey: device.id)
            cachedTemperatureMode.removeValue(forKey: device.id)
            cachedPDStatus.removeValue(forKey: device.id)
            lastChargingRefreshedAt.removeValue(forKey: device.id)
            lastTemperatureRefreshedAt.removeValue(forKey: device.id)
            lastPDRefreshedAt.removeValue(forKey: device.id)
            
            try await refreshWithReconnect(device: device, reason: "control_refresh")
        } catch {
            lastError = error.localizedDescription
            diagnosticLog.record("control_failed", metadata: [
                "action": action,
                "device": device.id.uuidString,
                "error": error.localizedDescription
            ])
            logControl(deviceID: device.id, deviceName: device.name, action: action, detail: "\(detail) - \(error.localizedDescription)", verified: false)
        }
    }

    private func restartPollingIfNeeded() {
        stopPolling()
        guard let selectedDevice = selectedDeviceSnapshot else {
            connectionState = .idle
            diagnosticLog.record("polling_stopped_no_device")
            releaseActivityToken()
            return
        }

        diagnosticLog.record("polling_restarted", metadata: [
            "device": selectedDevice.id.uuidString,
            "name": selectedDevice.name
        ])
        
        acquireActivityToken()
        
        pollingTask = Task { [weak self] in
            await self?.pollingLoop(device: selectedDevice)
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        releaseActivityToken()
    }

    private func acquireActivityToken() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "CandyMonitor Background Polling"
        )
        diagnosticLog.record("activity_token_acquired")
    }

    private func releaseActivityToken() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
            diagnosticLog.record("activity_token_released")
        }
    }

    private func pollingLoop(device: DeviceSnapshot) async {
        connectionState = .connecting
        var backoff = reconnectDelay

        while !Task.isCancelled, selectedDeviceID == device.id {
            do {
                try await refreshWithReconnect(device: device, reason: "polling")
                backoff = reconnectDelay // reset on success
                let seconds = isRealtimeRefreshEnabled ? 1.0 : 30.0
                try? await Task.sleep(for: .seconds(seconds))
            } catch {
                guard !Task.isCancelled else { return }
                connectionState = .failed(error.localizedDescription)
                lastError = error.localizedDescription
                diagnosticLog.record("polling_refresh_failed", metadata: [
                    "device": device.id.uuidString,
                    "error": error.localizedDescription,
                    "backoff": String(format: "%.0f", backoff)
                ])
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func refreshWithReconnect(device: DeviceSnapshot, reason: String) async throws {
        do {
            let client = try await client(for: device)
            try await refreshOnce(device: device, client: client)
        } catch {
            diagnosticLog.record("refresh_attempt_failed_reconnecting", metadata: [
                "device": device.id.uuidString,
                "reason": reason,
                "error": error.localizedDescription
            ])
            await resetClient(for: device, reason: reason)
            let freshClient = try await client(for: device)
            try await refreshOnce(device: device, client: freshClient)
            diagnosticLog.record("refresh_recovered_after_reconnect", metadata: [
                "device": device.id.uuidString,
                "reason": reason
            ])
        }
    }

    private func refreshOnce(device: DeviceSnapshot, client: MCPClient) async throws {
        let now = Date()
        if let local = await ionBridgeDiscovery.snapshot(for: device.id, psn: device.psn) {
            applyRefreshSnapshot(
                device: device,
                facts: local.facts,
                details: local.details,
                charging: local.chargingStatus,
                temperature: local.temperatureMode,
                pd: local.pdStatus,
                wsPDByPort: [:],
                at: now,
                source: "ionbridge"
            )
            return
        }

        let facts = try await machineFacts(for: device, client: client, at: now)
        
        // 1. Port details are always queried every second
        let details = try await retry {
            try await client.portDetails()
        }
        
        // 2. Charging status: cached with 5 seconds expiration
        let charging: ChargingStatus
        if let cached = cachedChargingStatus[device.id],
           let refreshedAt = lastChargingRefreshedAt[device.id],
           now.timeIntervalSince(refreshedAt) < 5 {
            charging = cached
        } else {
            charging = try await retry {
                try await client.chargingStatus()
            }
            cachedChargingStatus[device.id] = charging
            lastChargingRefreshedAt[device.id] = now
        }
        
        // 3. Temperature mode: cached with 30 seconds expiration
        let temperature: TemperatureModeResponse
        if let cached = cachedTemperatureMode[device.id],
           let refreshedAt = lastTemperatureRefreshedAt[device.id],
           now.timeIntervalSince(refreshedAt) < 30 {
            temperature = cached
        } else {
            temperature = try await retry {
                try await client.temperatureMode()
            }
            cachedTemperatureMode[device.id] = temperature
            lastTemperatureRefreshedAt[device.id] = now
        }
        
        // 4. PD Status: cached with 10 seconds expiration (only queries MCP fallback if cached version is old)
        let pd: PDStatusEnvelope?
        if let cached = cachedPDStatus[device.id],
           let refreshedAt = lastPDRefreshedAt[device.id],
           now.timeIntervalSince(refreshedAt) < 10 {
            pd = cached
        } else {
            pd = try? await client.pdStatus()
            if let pd {
                cachedPDStatus[device.id] = pd
                lastPDRefreshedAt[device.id] = now
            }
        }

        let wsPDByPort = await pdStatusFromIOTStream(device: device, client: client)
        applyRefreshSnapshot(
            device: device,
            facts: facts,
            details: details,
            charging: charging,
            temperature: temperature,
            pd: pd,
            wsPDByPort: wsPDByPort,
            at: now,
            source: "mcp"
        )
    }

    private func applyRefreshSnapshot(
        device: DeviceSnapshot,
        facts: MachineFacts,
        details: PortDetailsEnvelope,
        charging: ChargingStatus,
        temperature: TemperatureModeResponse,
        pd: PDStatusEnvelope?,
        wsPDByPort: [Int: PDPortStatus],
        at now: Date,
        source: String
    ) {
        guard selectedDeviceID == device.id else { return }

        let didUpdateDevice = updateDeviceMetadata(
            id: device.id,
            productFamily: facts.productFamily,
            maxPowerBudget: facts.maxPowerBudget,
            seenAt: now
        )
        temperatureModeLabel = temperature.modeName ?? "\(temperature.mode)"
        lastRefreshedAt = now

        let mcpPDByPort = Dictionary(uniqueKeysWithValues: (pd?.ports ?? []).map { ($0.port, $0) })
        let detailsByPort = Dictionary(uniqueKeysWithValues: details.ports.map { ($0.port, $0) })
        livePorts = facts.ports.map { port in
            let detail = detailsByPort[port.index]
            let fallbackPD = mcpPDByPort[port.index]
            let pdStatus = wsPDByPort[port.index]?.merged(withFallback: fallbackPD) ?? fallbackPD
            return PortViewState(
                port: port,
                detail: detail,
                pdStatus: pdStatus,
                charging: charging.statusBitmask & (1 << (port.index - 1)) != 0
            )
        }

        let recordingResult = recordSamples(deviceID: device.id, deviceName: device.name, ports: livePorts, at: now)
        connectionState = .connected
        lastError = nil
        if now.timeIntervalSince(lastDiagnosticRefreshLogAt) >= 30 {
            lastDiagnosticRefreshLogAt = now
            diagnosticLog.record("refresh_success", metadata: [
                "device": device.id.uuidString,
                "power": String(format: "%.1f", totalPowerW),
                "ports": "\(livePorts.count)",
                "source": source
            ])
        }
        if didUpdateDevice || recordingResult.didMutateStore {
            saveStoreIfNeeded(force: didUpdateDevice || recordingResult.didChangeSessions, at: now)
        }
    }

    private func machineFacts(for device: DeviceSnapshot, client: MCPClient, at now: Date) async throws -> MachineFacts {
        if let facts = cachedFacts[device.id],
           let refreshedAt = factsRefreshedAt[device.id],
           now.timeIntervalSince(refreshedAt) < factsRefreshInterval {
            return facts
        }

        let facts = try await retry {
            try await client.machineFacts()
        }
        cachedFacts[device.id] = facts
        factsRefreshedAt[device.id] = now
        return facts
    }

    private func pdStatusFromIOTStream(device: DeviceSnapshot, client: MCPClient) async -> [Int: PDPortStatus] {
        var jwt = sanitizedIOTGatewayJWT((try? KeychainStore.loadIOTGatewayJWT(account: device.keychainAccount)) ?? "")
        if jwt == nil, iotJWTFetchAttempted.contains(device.id) == false {
            iotJWTFetchAttempted.insert(device.id)
            if let fetchedJWT = try? await client.iotGatewayJWT(psn: device.psn),
               let sanitized = sanitizedIOTGatewayJWT(fetchedJWT) {
                try? KeychainStore.saveIOTGatewayJWT(sanitized, account: device.keychainAccount)
                jwt = sanitized
            }
        }

        guard let jwt else { return [:] }
        if let streamClient = pdStreamClients[device.id] {
            return await streamClient.latestStatuses()
        }

        let streamClient = CandyIOTPDStatusClient(jwt: jwt)
        pdStreamClients[device.id] = streamClient
        return await streamClient.latestStatuses()
    }

    private func sanitizedIOTGatewayJWT(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func saveStoreIfNeeded(force: Bool = false, at now: Date = Date()) {
        guard force || now.timeIntervalSince(lastStoreSaveAt) >= sampleSaveInterval else { return }
        try? modelContext?.save()
        lastStoreSaveAt = now
    }

    private func updateDeviceMetadata(
        id: UUID,
        productFamily: String?,
        maxPowerBudget: Int,
        seenAt: Date
    ) -> Bool {
        guard let device = devices.first(where: { $0.id == id }) else { return false }
        var didChange = false

        if let productFamily, device.productFamily != productFamily {
            device.productFamily = productFamily
            didChange = true
        }
        if device.maxPowerBudget != maxPowerBudget {
            device.maxPowerBudget = maxPowerBudget
            didChange = true
        }
        if device.lastSeenAt.map({ seenAt.timeIntervalSince($0) >= 30 }) ?? true {
            device.lastSeenAt = seenAt
            didChange = true
        }

        return didChange
    }

    private func recordSamples(deviceID: UUID, deviceName: String, ports: [PortViewState], at now: Date) -> RecordingResult {
        guard let modelContext else { return RecordingResult() }
        var result = RecordingResult()
        var observedKeys = Set<String>()
        var attachedKeys = Set<String>()

        for port in ports {
            let key = sessionKey(deviceID: deviceID, port: port.port.index)
            observedKeys.insert(key)
            if port.connected {
                attachedKeys.insert(key)
            } else {
                trickleStoppedKeys.remove(key)
            }

            guard let detail = port.detail else { continue }

            let alpha = 0.25
            let rawPower = detail.powerW
            let rawVoltage = Double(detail.voutMV) / 1000
            let rawCurrent = Double(detail.ioutMA) / 1000
            let rawTemp = temperatureScore(detail.dieTemperature)

            let lastPower = emaPowerW[key] ?? rawPower
            let lastVoltage = emaVoltageV[key] ?? rawVoltage
            let lastCurrent = emaCurrentA[key] ?? rawCurrent
            let lastTemp = emaTemperatureScore[key] ?? rawTemp
            let lastConn = emaLastConnected[key] ?? port.connected

            let powerDiff = abs(rawPower - lastPower)
            let voltDiff = abs(rawVoltage - lastVoltage)

            let smoothedPower: Double
            let smoothedVoltage: Double
            let smoothedCurrent: Double
            let smoothedTemp: Double

            if powerDiff > 2.0 || voltDiff > 1.0 || port.connected != lastConn {
                smoothedPower = rawPower
                smoothedVoltage = rawVoltage
                smoothedCurrent = rawCurrent
                smoothedTemp = rawTemp
            } else {
                smoothedPower = lastPower + alpha * (rawPower - lastPower)
                smoothedVoltage = lastVoltage + alpha * (rawVoltage - lastVoltage)
                smoothedCurrent = lastCurrent + alpha * (rawCurrent - lastCurrent)
                smoothedTemp = lastTemp + alpha * (rawTemp - lastTemp)
            }

            emaPowerW[key] = smoothedPower
            emaVoltageV[key] = smoothedVoltage
            emaCurrentA[key] = smoothedCurrent
            emaTemperatureScore[key] = smoothedTemp
            emaLastConnected[key] = port.connected

            recentSamples.append(ChartSamplePoint(
                timestamp: now,
                portIndex: port.port.index,
                portName: port.port.name,
                connected: port.connected,
                powerW: smoothedPower,
                voltageV: smoothedVoltage,
                currentA: smoothedCurrent,
                temperatureScore: smoothedTemp
            ))

            let isAttached = port.connected
            let hasOutputPower = detail.powerW >= recordingPowerThresholdW
            let isTrickleStopped = trickleStoppedKeys.contains(key)
            let shouldPersistSample = activeSessions[key] != nil || (hasOutputPower && !isTrickleStopped)
            guard shouldPersistSample else { continue }

            var event: String?
            let activeSessionID = activeSessions[key]
            var session = activeSessionID.flatMap { fetchSession(id: $0) }
            if activeSessionID != nil, session == nil {
                activeSessions.removeValue(forKey: key)
            }
            let storeActiveSessions = fetchActiveSessions(deviceID: deviceID, port: port.port.index)
            if let canonical = canonicalActiveSession(from: storeActiveSessions) {
                if storeActiveSessions.count > 1 {
                    mergeDuplicateActiveSessions(storeActiveSessions, keeping: canonical, at: now)
                    result.didMutateStore = true
                    result.didChangeSessions = true
                }
                activeSessions[key] = canonical.id
                session = canonical
            }

            var justCreated = false
            if session == nil, hasOutputPower, !isTrickleStopped {
                let newSession = ChargingSession(
                    deviceID: deviceID,
                    deviceName: deviceName,
                    portIndex: port.port.index,
                    portName: port.port.name,
                    connectedDeviceName: detail.deviceNameZH ?? detail.deviceNameEN,
                    startedAt: now
                )
                modelContext.insert(newSession)
                activeSessions[key] = newSession.id
                session = newSession
                event = "session_started"
                justCreated = true
                knownProtocols[newSession.id] = []
                sessions.insert(newSession, at: 0)
                if selectedSession == nil {
                    selectedSession = newSession
                }
                result.didMutateStore = true
                result.didChangeSessions = true
                disconnectDebounce.removeValue(forKey: key)
                selectedSession = newSession
                selectedSessionSamples = []
                logger.info("session_started port=\(port.port.index, privacy: .public) power=\(detail.powerW, privacy: .public)")
                diagnosticLog.record("session_started", metadata: [
                    "port": "\(port.port.index)",
                    "power": String(format: "%.1f", detail.powerW),
                    "connected": "\(isAttached)",
                    "session": newSession.id.uuidString
                ])
            }

            // Debounced disconnect: require N consecutive disconnected readings
            // to end a session, preventing transient signal flickers.
            // Never end a session that was just created this cycle.
            if isAttached, session != nil {
                disconnectDebounce.removeValue(forKey: key)
            } else if isAttached == false, let session, !justCreated {
                let count = (disconnectDebounce[key] ?? 0) + 1
                disconnectDebounce[key] = count
                if count >= disconnectDebounceThreshold {
                    event = "device_disconnected"
                    end(session, at: now, reason: "device_disconnected")
                    disconnectDebounce.removeValue(forKey: key)
                    result.didMutateStore = true
                    result.didChangeSessions = true
                    diagnosticLog.record("session_ended", metadata: [
                        "port": "\(port.port.index)",
                        "reason": "device_disconnected",
                        "session": session.id.uuidString
                    ])
                } else {
                    diagnosticLog.record("session_debounce", metadata: [
                        "port": "\(port.port.index)",
                        "count": "\(count)",
                        "threshold": "\(disconnectDebounceThreshold)",
                        "connected": "\(isAttached)",
                        "power": String(format: "%.1f", detail.powerW)
                    ])
                }
            }

            // Check if full/charged (Either via direct battery percentage OR low-power trickle detection)
            if let activeSession = session, activeSession.endedAt == nil {
                var shouldStopForTrickle = false
                
                if let battery = port.batteryPercent, battery >= 99 {
                    shouldStopForTrickle = true
                    event = "battery_full"
                    activeSession.finalBatteryPercent = battery
                    end(activeSession, at: now, reason: "battery_full")
                } else {
                    // Smart Trickle Charge / Auto-Stop check:
                    // Retrieve up to 150 most recent samples of this session, check if average power is below 1.5W for at least 3 minutes.
                    let sessionID = activeSession.id
                    var descriptor = FetchDescriptor<PortSample>(
                        predicate: #Predicate { sample in
                            sample.sessionID == sessionID
                        },
                        sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                    )
                    descriptor.fetchLimit = 150
                    
                    if let recentSamples = try? modelContext.fetch(descriptor), recentSamples.count >= 80 {
                        if let newest = recentSamples.first, let oldest = recentSamples.last {
                            let timeSpan = newest.timestamp.timeIntervalSince(oldest.timestamp)
                            if timeSpan >= 180 { // 3 minutes
                                let avgPower = recentSamples.map { $0.powerW }.reduce(0, +) / Double(recentSamples.count)
                                if avgPower < 1.5 {
                                    shouldStopForTrickle = true
                                    event = "battery_full"
                                    activeSession.finalBatteryPercent = 100
                                    activeSession.hasBatteryData = true
                                    end(activeSession, at: now, reason: "trickle_charge")
                                }
                            }
                        }
                    }
                }
                
                if shouldStopForTrickle {
                    trickleStoppedKeys.insert(key)
                    result.didChangeSessions = true
                    diagnosticLog.record("session_ended", metadata: [
                        "port": "\(port.port.index)",
                        "reason": event == "battery_full" && port.batteryPercent == nil ? "trickle_charge" : "battery_full",
                        "session": activeSession.id.uuidString
                    ])
                }
            }

            let stats = SampleStats(
                powerW: detail.powerW,
                voltageMV: detail.voutMV,
                protocolName: detail.fcProtocol,
                batteryPercent: port.batteryPercent
            )
            if let session {
                updateStats(session: session, with: stats)
            }

            let sample = PortSample(
                sessionID: session?.id,
                deviceID: deviceID,
                deviceName: deviceName,
                timestamp: now,
                portIndex: port.port.index,
                portName: port.port.name,
                connected: isAttached,
                protocolName: detail.fcProtocol,
                voltageMV: detail.voutMV,
                currentMA: detail.ioutMA,
                powerW: detail.powerW,
                temperature: detail.dieTemperature,
                sessionChargeMWh: detail.sessionChargeMWh,
                batteryPercent: port.batteryPercent,
                event: event
            )
            modelContext.insert(sample)
            if sample.sessionID == selectedSession?.id {
                selectedSessionSamples.append(sample)
                if selectedSessionSamples.count > selectedSessionChartSampleLimit * 3 {
                    selectedSessionSamples = downsampleSessionSamples(selectedSessionSamples)
                }
            }
            result.didMutateStore = true
        }

        for (key, sessionID) in Array(activeSessions) where observedKeys.contains(key) && attachedKeys.contains(key) == false {
            guard let session = fetchSession(id: sessionID), session.deviceID == deviceID else {
                activeSessions.removeValue(forKey: key)
                continue
            }
            let count = (disconnectDebounce[key] ?? 0) + 1
            disconnectDebounce[key] = count
            if count >= disconnectDebounceThreshold {
                end(session, at: now, reason: "device_disconnected")
                disconnectDebounce.removeValue(forKey: key)
                result.didMutateStore = true
                result.didChangeSessions = true
                diagnosticLog.record("session_ended", metadata: [
                    "port": key,
                    "reason": "device_disconnected_sweep",
                    "session": session.id.uuidString
                ])
            }
        }

        if result.didChangeSessions {
            sessions.sort { $0.startedAt > $1.startedAt }
        }
        let cutoff = Date().addingTimeInterval(-recentSampleWindow)
        recentSamples.removeAll { $0.timestamp < cutoff }
        return result
    }

    private func end(_ session: ChargingSession, at date: Date, reason: String) {
        guard session.endedAt == nil else { return }
        session.endedAt = date
        session.endReason = reason
        activeSessions.removeValue(forKey: sessionKey(deviceID: session.deviceID, port: session.portIndex))
        if lowPowerSessionPrompt?.id == session.id {
            lowPowerSessionPrompt = nil
        }
        logger.info("session_ended port=\(session.portIndex, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func fetchSession(id: UUID) -> ChargingSession? {
        // Use in-memory array instead of SwiftData #Predicate fetch,
        // because #Predicate may not return recently-inserted unsaved objects.
        return sessions.first { $0.id == id }
    }

    private func fetchActiveSessions(deviceID: UUID, port: Int) -> [ChargingSession] {
        // Use in-memory array instead of SwiftData #Predicate fetch,
        // because #Predicate may not return recently-inserted unsaved objects.
        return sessions.filter { $0.deviceID == deviceID && $0.portIndex == port && $0.endedAt == nil }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func mergeDuplicateActiveSessions(in candidateSessions: [ChargingSession], at now: Date) -> Bool {
        let activeGroups = Dictionary(grouping: candidateSessions.filter { $0.endedAt == nil }) {
            sessionKey(deviceID: $0.deviceID, port: $0.portIndex)
        }
        var didMerge = false
        for activeGroup in activeGroups.values where activeGroup.count > 1 {
            guard let canonical = canonicalActiveSession(from: activeGroup) else { continue }
            mergeDuplicateActiveSessions(activeGroup, keeping: canonical, at: now)
            didMerge = true
        }
        return didMerge
    }

    private func mergeDuplicateActiveSessions(_ activeGroup: [ChargingSession], keeping canonical: ChargingSession, at now: Date) {
        guard let modelContext else { return }
        let ordered = activeGroup.sorted { $0.startedAt < $1.startedAt }
        guard let newest = ordered.last else { return }

        for session in ordered.dropLast() {
            if sampleCount(for: session) == 0 {
                if let selectedSession, selectedSession.id == session.id {
                    self.selectedSession = newest
                }
                if let lowPowerSessionPrompt, lowPowerSessionPrompt.id == session.id {
                    self.lowPowerSessionPrompt = newest
                }
                knownProtocols[session.id] = nil
                modelContext.delete(session)
                sessions.removeAll { $0.id == session.id }
            } else {
                let endDate = min(lastSampleDate(for: session) ?? newest.startedAt, newest.startedAt)
                end(session, at: endDate, reason: "superseded_by_new_session")
                recomputeStats(for: session)
            }
        }

        recomputeStats(for: newest)
        if sessions.contains(where: { $0.id == newest.id }) == false {
            sessions.insert(newest, at: 0)
        }
        activeSessions[sessionKey(deviceID: newest.deviceID, port: newest.portIndex)] = newest.id
        logger.warning(
            "duplicate_active_sessions_healed port=\(newest.portIndex, privacy: .public) count=\(ordered.count, privacy: .public) at=\(now, privacy: .public)"
        )
    }

    private func canonicalActiveSession(from sessions: [ChargingSession]) -> ChargingSession? {
        sessions.max { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.startedAt < rhs.startedAt
        }
    }

    private func sampleCount(for session: ChargingSession) -> Int {
        guard let modelContext else { return 0 }
        let sessionID = session.id
        let descriptor = FetchDescriptor<PortSample>(
            predicate: #Predicate { sample in
                sample.sessionID == sessionID
            }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).count
    }

    private func lastSampleDate(for session: ChargingSession) -> Date? {
        guard let modelContext else { return nil }
        let sessionID = session.id
        var descriptor = FetchDescriptor<PortSample>(
            predicate: #Predicate { sample in
                sample.sessionID == sessionID
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.timestamp
    }

    private func migrateSamples(from sourceSessionID: UUID, to targetSessionID: UUID) {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<PortSample>(
            predicate: #Predicate { sample in
                sample.sessionID == sourceSessionID
            }
        )
        let samples = (try? modelContext.fetch(descriptor)) ?? []
        for sample in samples {
            sample.sessionID = targetSessionID
        }
    }

    private func recomputeStats(for session: ChargingSession) {
        guard let modelContext else { return }
        let sessionID = session.id
        let descriptor = FetchDescriptor<PortSample>(
            predicate: #Predicate { sample in
                sample.sessionID == sessionID
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let samples = (try? modelContext.fetch(descriptor)) ?? []
        session.sampleCount = 0
        session.peakPowerW = 0
        session.averagePowerW = 0
        session.minVoltageMV = 0
        session.maxVoltageMV = 0
        session.protocolSummary = ""
        session.hasBatteryData = false
        session.finalBatteryPercent = nil
        knownProtocols[session.id] = []

        for sample in samples {
            updateStats(
                session: session,
                with: SampleStats(
                    powerW: sample.powerW,
                    voltageMV: sample.voltageMV,
                    protocolName: sample.protocolName,
                    batteryPercent: sample.batteryPercent
                )
            )
        }
        if selectedSession?.id == session.id {
            selectedSessionSamples = downsampleSessionSamples(samples)
        }
    }

    private func downsampleSessionSamples(_ samples: [PortSample]) -> [PortSample] {
        guard samples.count > selectedSessionChartSampleLimit else { return samples }

        let bucketSize = Int(ceil(Double(samples.count) / Double(selectedSessionChartSampleLimit)))
        var reduced: [PortSample] = []
        reduced.reserveCapacity(selectedSessionChartSampleLimit * 3)

        for bucketStart in stride(from: 0, to: samples.count, by: bucketSize) {
            let bucketEnd = min(bucketStart + bucketSize, samples.count)
            let slice = samples[bucketStart..<bucketEnd]
            guard let first = slice.first else { continue }

            var peak = first
            var peakPower = first.powerW
            for sample in slice where sample.powerW > peakPower {
                peak = sample
                peakPower = sample.powerW
            }

            let last = slice.last ?? first
            reduced.append(first)
            if peak.id != first.id && peak.id != last.id {
                reduced.append(peak)
            }
            if last.id != first.id && last.id != peak.id {
                reduced.append(last)
            }
        }

        return reduced
    }

    private func updateStats(session: ChargingSession, with sample: SampleStats) {
        session.sampleCount += 1
        session.peakPowerW = max(session.peakPowerW, sample.powerW)
        if session.sampleCount == 1 {
            session.averagePowerW = sample.powerW
            session.minVoltageMV = sample.voltageMV
            session.maxVoltageMV = sample.voltageMV
        } else {
            let oldTotal = session.averagePowerW * Double(session.sampleCount - 1)
            session.averagePowerW = (oldTotal + sample.powerW) / Double(session.sampleCount)
            session.minVoltageMV = min(session.minVoltageMV, sample.voltageMV)
            session.maxVoltageMV = max(session.maxVoltageMV, sample.voltageMV)
        }
        let protocolLabel = LocalizedTelemetry.protocolLabel(sample.protocolName)
        if protocolLabel != "未充电" {
            knownProtocols[session.id, default: []].insert(protocolLabel)
            session.protocolSummary = knownProtocols[session.id, default: []].sorted().joined(separator: " / ")
        }
        if let battery = sample.batteryPercent {
            session.hasBatteryData = true
            session.finalBatteryPercent = battery
        }
    }

    private func client(for device: DeviceSnapshot) async throws -> MCPClient {
        if let client = clients[device.id] {
            // If the stream died silently, throw away the dead client
            let alive = await client.isConnected
            if alive {
                try await client.connect()
                return client
            } else {
                await resetClient(for: device, reason: "stale_stream_detected")
            }
        }
        guard let urlString = try KeychainStore.loadMCPURL(account: device.keychainAccount),
              let url = URL(string: urlString) else {
            diagnosticLog.record("client_missing_mcp_url", metadata: ["device": device.id.uuidString])
            throw MonitorError.missingMCPURL
        }
        diagnosticLog.record("client_connecting", metadata: [
            "device": device.id.uuidString,
            "url": DiagnosticLog.redactedURL(urlString)
        ])
        let client = MCPClient(sseURL: url)
        do {
            try await client.connect()
            clients[device.id] = client
            diagnosticLog.record("client_connected", metadata: ["device": device.id.uuidString])
            return client
        } catch {
            diagnosticLog.record("client_connect_failed", metadata: [
                "device": device.id.uuidString,
                "error": error.localizedDescription
            ])
            throw error
        }
    }

    private func resetClient(for device: DeviceSnapshot, reason: String) async {
        if let client = clients.removeValue(forKey: device.id) {
            await client.disconnect()
            diagnosticLog.record("client_reset", metadata: [
                "device": device.id.uuidString,
                "reason": reason
            ])
        }
        cachedFacts.removeValue(forKey: device.id)
        factsRefreshedAt.removeValue(forKey: device.id)
        
        cachedChargingStatus.removeValue(forKey: device.id)
        cachedTemperatureMode.removeValue(forKey: device.id)
        cachedPDStatus.removeValue(forKey: device.id)
        lastChargingRefreshedAt.removeValue(forKey: device.id)
        lastTemperatureRefreshedAt.removeValue(forKey: device.id)
        lastPDRefreshedAt.removeValue(forKey: device.id)
        
        if let streamClient = pdStreamClients.removeValue(forKey: device.id) {
            await streamClient.disconnect()
        }
    }

    private func logControl(deviceID: UUID, deviceName: String, action: String, detail: String, verified: Bool) {
        guard let modelContext else { return }
        modelContext.insert(ControlEvent(
            deviceID: deviceID,
            deviceName: deviceName,
            action: action,
            detail: detail,
            verified: verified
        ))
        try? modelContext.save()
    }

    private func flattenStats(_ value: Any, prefix: String = "") -> [String: String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [:]) { result, entry in
                let key = prefix.isEmpty ? entry.key : "\(prefix).\(entry.key)"
                result.merge(flattenStats(entry.value, prefix: key)) { current, _ in current }
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().reduce(into: [:]) { result, entry in
                let key = "\(prefix)[\(entry.offset)]"
                result.merge(flattenStats(entry.element, prefix: key)) { current, _ in current }
            }
        }
        if let number = value as? NSNumber {
            return [prefix: number.stringValue]
        }
        if let string = value as? String {
            return [prefix: string]
        }
        if value is NSNull || prefix.isEmpty {
            return [:]
        }
        return [prefix: "\(value)"]
    }

    private func deleteRows<T: PersistentModel>(_ type: T.Type, matching predicate: (T) -> Bool) {
        guard let modelContext else { return }
        let rows = (try? modelContext.fetch(FetchDescriptor<T>())) ?? []
        rows.filter(predicate).forEach { modelContext.delete($0) }
    }

    private func retry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            return try await operation()
        }
    }

    private func sessionKey(deviceID: UUID, port: Int) -> String {
        "\(deviceID.uuidString)-\(port)"
    }

    private func temperatureScore(_ text: String) -> Double {
        switch text.lowercased() {
        case "cool": 1
        case "moderate": 2
        case "warm": 3
        default: 0
        }
    }
}

@MainActor
private enum DeviceRegistry {
    static func save(_ devices: [MirrorDevice]) {
        let records = devices.map(DeviceRegistryRecord.init)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Logger(subsystem: "com.shawnrain.CandyMonitor", category: "DeviceRegistry")
                .error("device_registry_save_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    static func load() -> [DeviceRegistryRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([DeviceRegistryRecord].self, from: data)
        } catch {
            Logger(subsystem: "com.shawnrain.CandyMonitor", category: "DeviceRegistry")
                .error("device_registry_load_failed \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CandyMonitor", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("devices.json")
    }
}

private struct DeviceRegistryRecord: Codable {
    let id: UUID
    let name: String
    let keychainAccount: String
    let psn: String?
    let model: String?
    let productFamily: String?
    let maxPowerBudget: Int
    let createdAt: Date
    let lastSeenAt: Date?

    init(_ device: MirrorDevice) {
        self.id = device.id
        self.name = device.name
        self.keychainAccount = device.keychainAccount
        self.psn = device.psn
        self.model = device.model
        self.productFamily = device.productFamily
        self.maxPowerBudget = device.maxPowerBudget
        self.createdAt = device.createdAt
        self.lastSeenAt = device.lastSeenAt
    }
}

enum MonitorError: LocalizedError {
    case invalidURL
    case storeUnavailable
    case missingMCPURL

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "请输入有效的 HTTPS MCP SSE 地址"
        case .storeUnavailable:
            "本地数据库还没有准备好"
        case .missingMCPURL:
            "找不到这台设备的 MCP 地址"
        }
    }
}
