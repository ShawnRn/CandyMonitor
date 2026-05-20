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

    init(_ device: MirrorDevice) {
        self.id = device.id
        self.name = device.name
        self.keychainAccount = device.keychainAccount
    }
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
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var activeSessions: [String: UUID] = [:]
    @ObservationIgnored private var knownProtocols: [UUID: Set<String>] = [:]
    @ObservationIgnored private let selectedDeviceDefaultsKey = "CandyMonitor.SelectedDeviceID"
    @ObservationIgnored private let logger = Logger(subsystem: "com.shawnrain.CandyMonitor", category: "MonitorStore")

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
            loadDevices()
            loadSessions()
        }
    }

    func loadDevices() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<MirrorDevice>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        devices = (try? modelContext.fetch(descriptor)) ?? []
        if selectedDeviceID == nil,
           let persistedID = UserDefaults.standard.string(forKey: selectedDeviceDefaultsKey).flatMap(UUID.init(uuidString:)),
           devices.contains(where: { $0.id == persistedID }) {
            selectedDeviceID = persistedID
        }
        if selectedDeviceID == nil || devices.contains(where: { $0.id == selectedDeviceID }) == false {
            selectedDeviceID = devices.first?.id
        }
        hydrateRecentSamplesForSelectedDevice()
        restartPollingIfNeeded()
    }

    func loadSessions() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ChargingSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        sessions = (try? modelContext.fetch(descriptor)) ?? []
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

    func addDevice(name: String, sseURLString: String) async throws {
        guard let url = URL(string: sseURLString), url.scheme?.hasPrefix("http") == true else {
            throw MonitorError.invalidURL
        }

        connectionState = .connecting
        let client = MCPClient(sseURL: url)
        let validation = try await client.validate()
        let account = UUID().uuidString
        try KeychainStore.saveMCPURL(sseURLString, account: account)

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
        selectedDeviceID = device.id
        UserDefaults.standard.set(device.id.uuidString, forKey: selectedDeviceDefaultsKey)
        selectedSection = .monitor
        livePorts = validation.facts.ports.map {
            PortViewState(port: $0, detail: nil, batteryPercent: nil, charging: false)
        }
        connectionState = .connected
        restartPollingIfNeeded()
    }

    func updateDevice(_ device: MirrorDevice, name: String, sseURLString: String) async throws {
        guard let url = URL(string: sseURLString), url.scheme?.hasPrefix("http") == true else {
            throw MonitorError.invalidURL
        }

        let client = MCPClient(sseURL: url)
        let validation = try await client.validate()
        try KeychainStore.saveMCPURL(sseURLString, account: device.keychainAccount)

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
        restartPollingIfNeeded()
    }

    func renameDevice(_ device: MirrorDevice, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false, device.name != trimmedName else { return }
        device.name = trimmedName
        try? modelContext?.save()
        loadDevices()
    }

    func mcpURL(for device: MirrorDevice) -> String {
        (try? KeychainStore.loadMCPURL(account: device.keychainAccount)) ?? ""
    }

    func deleteSelectedDevice() {
        guard let modelContext, let device = selectedDevice else { return }
        stopPolling()
        KeychainStore.deleteMCPURL(account: device.keychainAccount)
        let client = clients[device.id]
        Task {
            await client?.disconnect()
        }
        clients[device.id] = nil

        let deviceID = device.id
        deleteRows(ChargingSession.self) { $0.deviceID == deviceID }
        deleteRows(PortSample.self) { $0.deviceID == deviceID }
        deleteRows(ControlEvent.self) { $0.deviceID == deviceID }
        modelContext.delete(device)
        try? modelContext.save()

        devices.removeAll { $0.id == device.id }
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

    private func restoreActiveSessions() {
        activeSessions.removeAll()
        for session in sessions where session.endedAt == nil {
            activeSessions[sessionKey(deviceID: session.deviceID, port: session.portIndex)] = session.id
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
        let cutoff = Date().addingTimeInterval(-60 * 20)
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
                powerW: sample.powerW,
                voltageV: Double(sample.voltageMV) / 1000,
                currentA: Double(sample.currentMA) / 1000,
                temperatureScore: temperatureScore(sample.temperature)
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
        selectedSessionSamples = (try? modelContext.fetch(descriptor)) ?? []
    }

    func stopSession(_ session: ChargingSession, reason: String = "manual") {
        guard let session = fetchSession(id: session.id), session.endedAt == nil else { return }
        end(session, at: Date(), reason: reason)
        lowPowerSessionPrompt = nil
        try? modelContext?.save()
        loadSessions()
    }

    func deleteSession(_ session: ChargingSession) {
        guard let modelContext else { return }
        let sessionID = session.id
        let targetSession = fetchSession(id: sessionID) ?? session
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
        if selectedSession?.id == sessionID {
            selectedSession = sessions.first { $0.id != sessionID }
        }
        if lowPowerSessionPrompt?.id == sessionID {
            lowPowerSessionPrompt = nil
        }
        modelContext.delete(targetSession)
        logger.info("session_deleted port=\(targetSession.portIndex, privacy: .public)")
        try? modelContext.save()
        loadSessions()
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

    func refreshSelectedDeviceNow() async {
        guard let device = selectedDeviceSnapshot else { return }
        isRefreshingNow = true
        defer { isRefreshingNow = false }

        do {
            let client = try await client(for: device)
            try await refreshOnce(device: device, client: client)
        } catch {
            connectionState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
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
            try await refreshOnce(device: device, client: client)
        } catch {
            lastError = error.localizedDescription
            logControl(deviceID: device.id, deviceName: device.name, action: action, detail: "\(detail) - \(error.localizedDescription)", verified: false)
        }
    }

    private func restartPollingIfNeeded() {
        stopPolling()
        guard let selectedDevice = selectedDeviceSnapshot else {
            connectionState = .idle
            return
        }

        pollingTask = Task { [weak self] in
            await self?.pollingLoop(device: selectedDevice)
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollingLoop(device: DeviceSnapshot) async {
        connectionState = .connecting

        do {
            let client = try await client(for: device)
            while !Task.isCancelled, selectedDeviceID == device.id {
                try await refreshOnce(device: device, client: client)
                let seconds = isRealtimeRefreshEnabled ? 1.0 : 30.0
                try? await Task.sleep(for: .seconds(seconds))
            }
        } catch {
            if !Task.isCancelled {
                connectionState = .failed(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
    }

    private func refreshOnce(device: DeviceSnapshot, client: MCPClient) async throws {
        let facts = try await retry {
            try await client.machineFacts()
        }
        async let detailsTask = retry {
            try await client.portDetails()
        }
        async let chargingTask = retry {
            try await client.chargingStatus()
        }
        async let temperatureTask = retry {
            try await client.temperatureMode()
        }

        let details = try await detailsTask
        let charging = try await chargingTask
        let temperature = try await temperatureTask
        let pd = try? await client.pdStatus()

        guard selectedDeviceID == device.id else { return }

        let now = Date()
        let didUpdateDevice = updateDeviceMetadata(
            id: device.id,
            productFamily: facts.productFamily,
            maxPowerBudget: facts.maxPowerBudget,
            seenAt: now
        )
        temperatureModeLabel = temperature.modeName ?? "\(temperature.mode)"
        lastRefreshedAt = now

        let pdByPort = Dictionary(uniqueKeysWithValues: (pd?.ports ?? []).map { ($0.port, $0) })
        let detailsByPort = Dictionary(uniqueKeysWithValues: details.ports.map { ($0.port, $0) })
        livePorts = facts.ports.map { port in
            let detail = detailsByPort[port.index]
            return PortViewState(
                port: port,
                detail: detail,
                batteryPercent: pdByPort[port.index]?.batteryPercent,
                charging: charging.statusBitmask & (1 << (port.index - 1)) != 0
            )
        }

        let didRecordSamples = recordSamples(deviceID: device.id, deviceName: device.name, ports: livePorts, at: now)
        connectionState = .connected
        lastError = nil
        if didUpdateDevice || didRecordSamples {
            try? modelContext?.save()
            loadSessions()
        }
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

    private func recordSamples(deviceID: UUID, deviceName: String, ports: [PortViewState], at now: Date) -> Bool {
        guard let modelContext else { return false }
        var didMutateStore = false
        var observedKeys = Set<String>()
        var attachedKeys = Set<String>()

        for port in ports {
            let key = sessionKey(deviceID: deviceID, port: port.port.index)
            observedKeys.insert(key)
            if port.connected {
                attachedKeys.insert(key)
            }

            guard let detail = port.detail else { continue }

            recentSamples.append(ChartSamplePoint(
                timestamp: now,
                portIndex: port.port.index,
                portName: port.port.name,
                powerW: detail.powerW,
                voltageV: Double(detail.voutMV) / 1000,
                currentA: Double(detail.ioutMA) / 1000,
                temperatureScore: temperatureScore(detail.dieTemperature)
            ))

            let isAttached = port.connected
            let shouldRecord = isAttached || activeSessions[key] != nil
            guard shouldRecord else { continue }

            var event: String?
            let activeSessionID = activeSessions[key]
            var session = activeSessionID.flatMap { fetchSession(id: $0) }
            if activeSessionID != nil, session == nil {
                activeSessions.removeValue(forKey: key)
            }

            if session == nil, isAttached {
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
                knownProtocols[newSession.id] = []
                didMutateStore = true
                logger.info("session_started port=\(port.port.index, privacy: .public) power=\(detail.powerW, privacy: .public)")
            }

            if isAttached == false, let session {
                event = "device_disconnected"
                end(session, at: now, reason: "device_disconnected")
                didMutateStore = true
            }

            if let session, let battery = port.batteryPercent, battery >= 99 {
                event = "battery_full"
                session.finalBatteryPercent = battery
                end(session, at: now, reason: "battery_full")
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
            didMutateStore = true

            if let session {
                updateStats(session: session, with: sample)
                maybePromptLowPower(session: session)
            }
        }

        for (key, sessionID) in Array(activeSessions) where observedKeys.contains(key) && attachedKeys.contains(key) == false {
            guard let session = fetchSession(id: sessionID), session.deviceID == deviceID else {
                activeSessions.removeValue(forKey: key)
                continue
            }
            end(session, at: now, reason: "device_disconnected")
            didMutateStore = true
        }

        let cutoff = Date().addingTimeInterval(-60 * 20)
        recentSamples.removeAll { $0.timestamp < cutoff }
        return didMutateStore
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
        guard let modelContext else { return nil }
        var descriptor = FetchDescriptor<ChargingSession>(
            predicate: #Predicate { session in
                session.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func updateStats(session: ChargingSession, with sample: PortSample) {
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

    private func maybePromptLowPower(session: ChargingSession) {
        guard session.endedAt == nil,
              session.hasBatteryData == false,
              session.startedAt.timeIntervalSinceNow < -600,
              lowPowerSessionPrompt == nil else {
            return
        }

        guard let modelContext else { return }
        let id = session.id
        var descriptor = FetchDescriptor<PortSample>(
            predicate: #Predicate { sample in
                sample.sessionID == id
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 8

        guard let samples = try? modelContext.fetch(descriptor),
              samples.count >= 8,
              samples.allSatisfy({ $0.powerW < 2.0 }) else {
            return
        }
        lowPowerSessionPrompt = session
    }

    private func client(for device: DeviceSnapshot) async throws -> MCPClient {
        if let client = clients[device.id] {
            try await client.connect()
            return client
        }
        guard let urlString = try KeychainStore.loadMCPURL(account: device.keychainAccount),
              let url = URL(string: urlString) else {
            throw MonitorError.missingMCPURL
        }
        let client = MCPClient(sseURL: url)
        try await client.connect()
        clients[device.id] = client
        return client
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
