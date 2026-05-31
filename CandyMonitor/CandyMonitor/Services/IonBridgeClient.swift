import Darwin
import Foundation

actor IonBridgeDiscovery {
    private struct CacheEntry {
        let baseURL: URL
        let expiresAt: Date
    }

    private var cache: [UUID: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 300

    func snapshot(for deviceID: UUID, psn: String?) async -> IonBridgeSnapshot? {
        let now = Date()
        if let entry = cache[deviceID], entry.expiresAt > now,
           let snapshot = await IonBridgeClient(baseURL: entry.baseURL).snapshot(matchingPSN: psn) {
            return snapshot
        }

        var candidates: [URL] = []
        if let psn, psn.isEmpty == false {
            candidates.append(URL(string: "http://cp02-\(psn).local/")!)
        }

        for url in candidates {
            if let snapshot = await IonBridgeClient(baseURL: url).snapshot(matchingPSN: psn) {
                cache[deviceID] = CacheEntry(baseURL: snapshot.baseURL, expiresAt: now.addingTimeInterval(cacheTTL))
                return snapshot
            }
        }

        if let snapshot = await scanLAN(matchingPSN: psn) {
            cache[deviceID] = CacheEntry(baseURL: snapshot.baseURL, expiresAt: now.addingTimeInterval(cacheTTL))
            return snapshot
        }

        return nil
    }

    private func scanLAN(matchingPSN psn: String?) async -> IonBridgeSnapshot? {
        let prefixes = Self.localIPv4Prefixes()
        guard prefixes.isEmpty == false else { return nil }

        return await withTaskGroup(of: IonBridgeSnapshot?.self) { group in
            for prefix in prefixes {
                for host in 1...254 {
                    guard host != prefix.host else { continue }
                    let url = URL(string: "http://\(prefix.network).\(host)/")!
                    group.addTask {
                        await IonBridgeClient(baseURL: url, timeout: 0.45).snapshot(matchingPSN: psn)
                    }
                }
            }

            for await snapshot in group {
                if let snapshot {
                    group.cancelAll()
                    return snapshot
                }
            }
            return nil
        }
    }

    private static func localIPv4Prefixes() -> [(network: String, host: Int)] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var prefixes: [(network: String, host: Int)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else {
                continue
            }

            var address = interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil,
                  let ip = String(validatingUTF8: buffer) else {
                continue
            }
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { continue }
            prefixes.append(("\(parts[0]).\(parts[1]).\(parts[2])", parts[3]))
        }
        return Array(Set(prefixes.map { "\($0.network).\($0.host)" })).compactMap { value in
            let parts = value.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return nil }
            return ("\(parts[0]).\(parts[1]).\(parts[2])", parts[3])
        }
    }
}

struct IonBridgeSnapshot: Sendable {
    let baseURL: URL
    let info: IonBridgeInfo
    let metrics: IonBridgeMetrics

    var facts: MachineFacts {
        let ports = metrics.ports
            .sorted { $0.id < $1.id }
            .map { port in
                MachinePort(
                    index: port.id + 1,
                    name: port.id == 0 ? "A" : "C\(port.id)",
                    connectorType: port.portType,
                    power: port.powerBudget
                )
            }
        return MachineFacts(
            productFamily: info.productFamily,
            brandEN: "CANDYSIGN",
            brandZH: "小电拼",
            friendlyNameEN: info.deviceName,
            friendlyNameZH: info.deviceName,
            maxPowerBudget: max(metrics.ports.map(\.powerBudget).max() ?? 0, 160),
            ports: ports
        )
    }

    var details: PortDetailsEnvelope {
        PortDetailsEnvelope(ports: metrics.ports.map { port in
            PortDetail(
                connected: port.attached,
                dieTemperature: "normal",
                enable: port.active,
                fcProtocol: "\(port.fcProtocol)",
                ioutMA: port.current,
                port: port.id + 1,
                sessionChargeMWh: 0,
                vinMV: port.vinValue,
                voutMV: port.voltage,
                deviceNameEN: nil,
                deviceNameZH: nil
            )
        })
    }

    var chargingStatus: ChargingStatus {
        let bitmask = metrics.ports.reduce(0) { result, port in
            guard port.attached && port.current > 0 && port.voltage > 0 else { return result }
            return result | (1 << port.id)
        }
        return ChargingStatus(statusBitmask: bitmask)
    }

    var temperatureMode: TemperatureModeResponse {
        TemperatureModeResponse(mode: 0, modeName: "未同步")
    }

    var pdStatus: PDStatusEnvelope? {
        nil
    }
}

struct IonBridgeInfo: Decodable, Sendable {
    let psn: String?
    let bleMac: String?
    let wifiMac: String?
    let deviceModel: String?
    let deviceName: String?
    let productFamily: String?
    let esp32Version: String?
    let mcuVersion: String?
    let fpgaVersion: String?
    let mdnsHostname: String?

    enum CodingKeys: String, CodingKey {
        case psn
        case bleMac = "ble_mac"
        case wifiMac = "wifi_mac"
        case deviceModel = "device_model"
        case deviceName = "device_name"
        case productFamily = "product_family"
        case esp32Version = "esp32_version"
        case mcuVersion = "mcu_version"
        case fpgaVersion = "fpga_version"
        case mdnsHostname = "mdns_hostname"
    }
}

struct IonBridgeMetrics: Decodable, Sendable {
    let ports: [IonBridgePort]
    let system: IonBridgeSystem?
    let wifi: IonBridgeWiFi?
}

struct IonBridgePort: Decodable, Sendable {
    let id: Int
    let active: Bool
    let state: String
    let portType: String
    let attached: Bool
    let chargingDurationSeconds: Int
    let fcProtocol: Int
    let current: Int
    let voltage: Int
    let vinValue: Int?
    let sessionID: Int?
    let sessionCharge: Int
    let powerBudget: Int

    enum CodingKeys: String, CodingKey {
        case id
        case active
        case state
        case portType = "port_type"
        case attached
        case chargingDurationSeconds = "charging_duration_seconds"
        case fcProtocol = "fc_protocol"
        case current
        case voltage
        case vinValue = "vin_value"
        case sessionID = "session_id"
        case sessionCharge = "session_charge"
        case powerBudget = "power_budget"
    }
}

struct IonBridgeSystem: Decodable, Sendable {
    let chip: String?
    let appVersion: String?
    let freeHeap: Int?

    enum CodingKeys: String, CodingKey {
        case chip
        case appVersion = "app_version"
        case freeHeap = "free_heap"
    }
}

struct IonBridgeWiFi: Decodable, Sendable {
    let ssid: String?
    let bssid: String?
    let channel: Int?
    let rssi: Int?
}

struct IonBridgeClient: Sendable {
    let baseURL: URL
    var timeout: TimeInterval = 1.2

    func snapshot(matchingPSN expectedPSN: String?) async -> IonBridgeSnapshot? {
        guard let info = await info(),
              expectedPSN == nil || info.psn == expectedPSN,
              let metrics = await metrics() else {
            return nil
        }
        return IonBridgeSnapshot(baseURL: baseURL, info: info, metrics: metrics)
    }

    private func info() async -> IonBridgeInfo? {
        guard let data = await data(path: "/"),
              let html = String(data: data, encoding: .utf8),
              html.contains("IonBridge"),
              let json = extractScriptJSON(named: "INFOZ", from: html),
              let jsonData = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(IonBridgeInfo.self, from: jsonData)
    }

    private func metrics() async -> IonBridgeMetrics? {
        guard let data = await data(path: "/metrics.json") else { return nil }
        return try? JSONDecoder().decode(IonBridgeMetrics.self, from: data)
    }

    private func data(path: String) async -> Data? {
        guard let url = URL(string: path, relativeTo: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func extractScriptJSON(named name: String, from html: String) -> String? {
        let marker = "window.__\(name)="
        guard let start = html.range(of: marker)?.upperBound else { return nil }
        let remainder = html[start...]
        guard let end = remainder.firstIndex(of: ";") else { return nil }
        return String(remainder[..<end])
    }
}
