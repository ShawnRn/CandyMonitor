import Foundation

actor MCPClient {
    private let sseURL: URL
    private var endpointURL: URL?
    private var nextRequestID = 1
    private var streamTask: Task<Void, Never>?
    private var endpointContinuation: CheckedContinuation<URL, Error>?
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    init(sseURL: URL) {
        self.sseURL = sseURL
    }

    deinit {
        streamTask?.cancel()
        for continuation in pendingResponses.values {
            continuation.resume(throwing: MCPError.disconnected)
        }
        endpointContinuation?.resume(throwing: MCPError.disconnected)
    }

    func connect() async throws {
        if endpointURL != nil {
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
        streamTask = Task { [weak self] in
            do {
                for try await line in bytes.lines {
                    await self?.handleSSELine(line)
                }
                await self?.markDisconnected()
            } catch {
                await self?.failAll(error)
            }
        }

        _ = try await waitForEndpoint()
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
        streamTask?.cancel()
        streamTask = nil
        endpointURL = nil
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
              let text = content.first?["text"] as? String,
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidToolResponse(name)
        }
        return object
    }

    private func waitForEndpoint() async throws -> URL {
        if let endpointURL {
            return endpointURL
        }
        return try await withCheckedThrowingContinuation { continuation in
            endpointContinuation = continuation
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
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            Task { [weak self] in
                do {
                    try await self?.post(body, to: endpointURL)
                } catch {
                    await self?.resumeRequest(id: id, throwing: error)
                }
            }
        }
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
        endpointURL = nil
        failAll(MCPError.disconnected)
    }

    private func failAll(_ error: Error) {
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
        }
    }
}
