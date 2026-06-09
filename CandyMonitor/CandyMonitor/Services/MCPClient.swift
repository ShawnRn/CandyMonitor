import Foundation

actor MCPClient {
    private let sseURL: URL
    private var endpointURL: URL?
    private var nextRequestID = 1
    private var streamTask: Task<Void, Never>?
    private var endpointContinuation: CheckedContinuation<URL, Error>?
    private var endpointWaitGeneration = 0
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var streamAlive = false
    private let requestTimeout: TimeInterval = 15

    init(sseURL: URL) {
        self.sseURL = sseURL
    }

    var isConnected: Bool {
        endpointURL != nil && streamAlive && streamTask?.isCancelled == false
    }

    deinit {
        streamTask?.cancel()
        for continuation in pendingResponses.values {
            continuation.resume(throwing: MCPError.disconnected)
        }
        endpointContinuation?.resume(throwing: MCPError.disconnected)
    }

    func connect() async throws {
        // If the stream died silently, reset so we reconnect
        if endpointURL != nil && !streamAlive {
            disconnect()
        }
        if endpointURL != nil && streamAlive {
            return
        }

        var sseRequest = URLRequest(url: sseURL)
        sseRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        sseRequest.timeoutInterval = 15

        let (bytes, response) = try await URLSession.shared.bytes(for: sseRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw MCPError.invalidHTTPResponse
        }

        streamTask?.cancel()
        streamAlive = true
        streamTask = Task { [weak self] in
            do {
                for try await line in bytes.lines {
                    await self?.handleSSELine(line)
                }
                await self?.markDisconnected()
            } catch {
                await self?.markDisconnected()
            }
        }

        _ = try await waitForEndpoint(timeout: 8)
        _ = try await request(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": [
                "name": "CandyMonitor",
                "version": "1.0"
            ]
        ])
        try await sendNotification(method: "notifications/initialized", params: [:])
    }

    func disconnect() {
        streamAlive = false
        streamTask?.cancel()
        streamTask = nil
        endpointURL = nil
        endpointWaitGeneration += 1
        failAll(MCPError.disconnected)
    }

    func validate() async throws -> DeviceValidationResult {
        try await connect()
        async let info: DeviceInfo = callTool("get_device_info")
        async let facts: MachineFacts = callTool("get_machine_facts")
        return try await DeviceValidationResult(info: info, facts: facts)
    }

    func deviceInfo() async throws -> DeviceInfo {
        try await callTool("get_device_info")
    }

    func machineFacts() async throws -> MachineFacts {
        try await callTool("get_machine_facts")
    }

    func portDetails() async throws -> PortDetailsEnvelope {
        try await callTool("get_port_details")
    }

    func chargingStatus() async throws -> ChargingStatus {
        try await callTool("get_charging_status")
    }

    func pdStatus() async throws -> PDStatusEnvelope {
        try await callTool("get_port_pd_status")
    }

    func temperatureMode() async throws -> TemperatureModeResponse {
        try await callTool("get_temperature_mode")
    }

    func portStats(port: Int) async throws -> [String: Any] {
        try await callToolObject("get_port_stats", arguments: ["port": port])
    }

    func setChargingStrategy(_ strategy: ChargingStrategy) async throws {
        _ = try await callToolObject("set_charging_strategy", arguments: ["strategy": strategy.rawValue])
    }

    func setTemperatureMode(_ mode: TemperatureMode) async throws {
        _ = try await callToolObject("set_temperature_mode", arguments: ["mode": mode.rawValue])
    }

    func turnOnPort(_ port: Int) async throws {
        _ = try await callToolObject("turn_on_port", arguments: ["ports": [port]])
    }

    func turnOffPort(_ port: Int) async throws {
        _ = try await callToolObject("turn_off_port", arguments: ["ports": [port]])
    }

    func setPowerAllocation(_ watts: [Int]) async throws {
        _ = try await callToolObject("set_port_power_allocation", arguments: ["power_allocation": watts])
    }

    func setCableCompensation(port: Int, gear: CableCompensationGear) async throws {
        if gear == .disabled {
            _ = try await callToolObject("set_cable_compensation", arguments: [
                "ports": [port],
                "disable": true,
                "resistance": 0,
                "voltage_offset": 0
            ])
        } else {
            _ = try await callToolObject("set_cable_compensation", arguments: [
                "ports": [port],
                "resistance": gear.resistance,
                "voltage_offset": gear.voltageOffset
            ])
        }
    }

    func iotGatewayJWT(psn: String?) async throws -> String? {
        let arguments = psn.map { ["psn": $0] } ?? [:]
        let toolNames = [
            "get_iot_gateway_jwt",
            "get_iotgw_jwt",
            "get_ws_jwt",
            "get_device_jwt"
        ]

        for toolName in toolNames {
            do {
                let object = try await callToolObject(toolName, arguments: arguments)
                if let token = Self.extractToken(from: object) {
                    return token
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func callTool<T: Decodable>(_ name: String, arguments: [String: Any] = [:]) async throws -> T {
        let object = try await callToolObject(name, arguments: arguments)
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func callToolObject(_ name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        try await connect()
        let response = try await request(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])
        guard let result = response["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw MCPError.invalidToolResponse(name)
        }
        
        guard let data = text.data(using: .utf8) else {
            throw MCPError.invalidToolResponse(name)
        }
        
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPError.invalidToolResponse(name)
            }
            return object
        } catch {
            NSLog("MCPClient JSON parse failed for tool %@. Content text: %@. Error: %@", name, text, error.localizedDescription)
            throw error
        }
    }

    private static func extractToken(from object: [String: Any]) -> String? {
        for key in ["token", "jwt", "iot_jwt", "iotJwt", "iot_gateway_jwt", "iotGatewayJWT"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false { return trimmed }
            }
        }
        for value in object.values {
            if let nested = value as? [String: Any],
               let token = extractToken(from: nested) {
                return token
            }
        }
        return nil
    }

    private func waitForEndpoint(timeout seconds: TimeInterval) async throws -> URL {
        if let endpointURL {
            return endpointURL
        }
        endpointWaitGeneration += 1
        let generation = endpointWaitGeneration
        return try await withCheckedThrowingContinuation { continuation in
            endpointContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await self?.failEndpointWaitIfNeeded(generation: generation)
            }
        }
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let endpointURL else {
            throw MCPError.missingEndpoint
        }

        let id = nextRequestID
        nextRequestID += 1

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let timeout = requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            Task { [weak self] in
                do {
                    try await self?.post(body, to: endpointURL)
                } catch {
                    await self?.resumeRequest(id: id, throwing: error)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.timeoutRequest(id: id)
            }
        }
    }

    private func timeoutRequest(id: Int) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else { return }
        continuation.resume(throwing: MCPError.requestTimeout)
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        guard let endpointURL else {
            throw MCPError.missingEndpoint
        }
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        try await post(body, to: endpointURL)
    }

    private func post(_ body: [String: Any], to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw MCPError.invalidHTTPResponse
        }
    }

    private func resumeRequest(id: Int, throwing error: Error) {
        pendingResponses.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func handleSSELine(_ line: String) {
        guard line.hasPrefix("data: ") else { return }
        let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }

        if payload.hasPrefix("/") {
            let resolved = resolveEndpoint(payload)
            endpointURL = resolved
            endpointWaitGeneration += 1
            endpointContinuation?.resume(returning: resolved)
            endpointContinuation = nil
            return
        }

        guard let data = payload.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let id = message["id"] as? Int,
           let continuation = pendingResponses.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any],
               let text = error["message"] as? String {
                continuation.resume(throwing: MCPError.rpc(text))
            } else {
                continuation.resume(returning: message)
            }
        }
    }

    private func resolveEndpoint(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = sseURL.scheme
        components.host = sseURL.host
        components.port = sseURL.port

        if let questionIndex = path.firstIndex(of: "?") {
            components.path = String(path[..<questionIndex])
            components.query = String(path[path.index(after: questionIndex)...])
        } else {
            components.path = path
        }

        return components.url ?? sseURL
    }

    private func markDisconnected() {
        streamAlive = false
        endpointURL = nil
        endpointWaitGeneration += 1
        failAll(MCPError.disconnected)
    }

    private func failEndpointWaitIfNeeded(generation: Int) {
        guard generation == endpointWaitGeneration else { return }
        guard endpointURL == nil else { return }
        endpointContinuation?.resume(throwing: MCPError.missingEndpoint)
        endpointContinuation = nil
        streamTask?.cancel()
        streamTask = nil
    }

    private func failAll(_ error: Error) {
        endpointWaitGeneration += 1
        for continuation in pendingResponses.values {
            continuation.resume(throwing: error)
        }
        pendingResponses.removeAll()
        endpointContinuation?.resume(throwing: error)
        endpointContinuation = nil
    }
}

enum MCPError: LocalizedError {
    case invalidHTTPResponse
    case missingEndpoint
    case invalidToolResponse(String)
    case rpc(String)
    case disconnected
    case requestTimeout

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            "MCP 服务器响应异常"
        case .missingEndpoint:
            "MCP SSE 尚未返回 message endpoint"
        case .invalidToolResponse(let name):
            "MCP 工具 \(name) 返回格式无法解析"
        case .rpc(let message):
            message
        case .disconnected:
            "MCP 连接已断开"
        case .requestTimeout:
            "MCP 请求超时"
        }
    }
}

actor CandyIOTPDStatusClient {
    private let jwt: String
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var latestByPort: [Int: PDPortStatus] = [:]

    init(jwt: String) {
        self.jwt = jwt
    }

    deinit {
        receiveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    func latestStatuses() async -> [Int: PDPortStatus] {
        connectIfNeeded()
        return latestByPort
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        latestByPort.removeAll()
    }

    private func connectIfNeeded() {
        guard task == nil, let url = Self.webSocketURL(jwt: jwt) else { return }
        let webSocketTask = URLSession.shared.webSocketTask(with: url)
        task = webSocketTask
        webSocketTask.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(webSocketTask)
        }
    }

    private func receiveLoop(_ webSocketTask: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await webSocketTask.receive()
                await handle(message)
            } catch {
                disconnect()
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .data(let data):
            handleJSONData(data)
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return }
            handleJSONData(data)
        @unknown default:
            return
        }
    }

    private func handleJSONData(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let service = Self.numberValue(object["service"]).map(Int.init),
              service == 130,
              let payload = object["payload"] as? [String: Any] else {
            return
        }

        if let status = Self.numberValue(payload["status"]), Int(status) != 0 {
            return
        }

        let streamObject = payload["stream_port_pd_status"]
            ?? payload["streamPowerDeliveryStatus"]
            ?? payload["powerDeliveryStatus"]
        guard let stream = streamObject as? [String: Any] else { return }
        guard let rawPort = Self.numberValue(stream["port"] ?? stream["portId"]).map(Int.init) else { return }
        let pdPayload = (stream["pd_status"] as? [String: Any])
            ?? (stream["pdStatus"] as? [String: Any])
            ?? stream
        let appPort = normalizePort(rawPort)
        let status = Self.status(from: pdPayload, appPort: appPort)
        guard status.hasUsefulPayload else { return }
        latestByPort[appPort] = status
    }

    private static func status(from payload: [String: Any], appPort: Int) -> PDPortStatus {
        let manufacturer = stringValue(payload, keys: [
            "manufacturer", "vendor", "brand", "deviceManufacturer", "device_vendor"
        ]) ?? manufacturerName(from: payload)
        return PDPortStatus(
            port: appPort,
            batteryPercent: doubleValue(payload, keys: [
                "capacityPercent", "capacity_percent", "batteryPercent", "battery_percent", "soc"
            ]),
            manufacturer: manufacturer,
            modelName: stringValue(payload, keys: [
                "model", "modelName", "model_name", "productName", "product_name"
            ]),
            serialNumber: stringValue(payload, keys: ["serial", "serialNumber", "serial_number", "sn"]),
            batteryCapacityMWh: capacityValue(payload, keys: [
                "batteryDesignCapacity", "battery_design_capacity", "batteryCapacityMWh", "battery_capacity_mwh"
            ]),
            batteryLastFullChargeCapacityMWh: capacityValue(payload, keys: [
                "batteryLastFullChargeCapacity", "battery_last_full_charge_capacity",
                "batteryLastFullChargeCapacityMWh", "battery_last_full_charge_capacity_mwh"
            ]),
            batteryPresentCapacityMWh: capacityValue(payload, keys: [
                "batteryPresentCapacity", "battery_present_capacity",
                "batteryPresentCapacityMWh", "battery_present_capacity_mwh"
            ]),
            batteryHealthPercent: doubleValue(payload, keys: [
                "batteryHealth", "battery_health", "batteryHealthPercent", "battery_health_percent", "soh"
            ]),
            estimatedFullMinutes: doubleValue(payload, keys: [
                "estimatedFullMinutes", "estimated_full_minutes", "timeToFullMinutes", "time_to_full_minutes"
            ]),
            remainingTimeText: stringValue(payload, keys: [
                "remainingTimeStr", "remaining_time_str", "remainingTime", "remaining_time"
            ]),
            cycleCount: intValue(payload, keys: ["cycleCount", "cycle_count", "cycles"])
        )
    }

    private static func webSocketURL(jwt: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "iot-gateway.minapp.com"
        components.path = "/ws/cp-02/v2/stats/"
        components.queryItems = [URLQueryItem(name: "t", value: jwt)]
        return components.url
    }

    private func normalizePort(_ rawPort: Int) -> Int {
        if (0...4).contains(rawPort) {
            return rawPort + 1
        }
        return rawPort
    }

    private static func capacityValue(_ payload: [String: Any], keys: [String]) -> Double? {
        guard let value = doubleValue(payload, keys: keys), value > 0, value < 65535 else { return nil }
        return value
    }

    private static func doubleValue(_ payload: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = numberValue(payload[key]) {
                return value
            }
        }
        return nil
    }

    private static func intValue(_ payload: [String: Any], keys: [String]) -> Int? {
        doubleValue(payload, keys: keys).map(Int.init)
    }

    private static func stringValue(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false { return trimmed }
            }
        }
        return nil
    }

    private static func manufacturerName(from payload: [String: Any]) -> String? {
        let vendorIDs = [
            intValue(payload, keys: ["batteryVid", "battery_vid"]),
            intValue(payload, keys: ["manufacturerVid", "manufacturer_vid"])
        ]
        return vendorIDs.contains(0x05AC) ? "Apple" : nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
            if trimmed.lowercased().hasPrefix("0x") {
                return Double(Int(trimmed.dropFirst(2), radix: 16) ?? 0)
            }
            return Double(trimmed)
        }
        return nil
    }
}
