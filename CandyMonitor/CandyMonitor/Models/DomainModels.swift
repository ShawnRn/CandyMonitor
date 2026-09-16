import Foundation
import SwiftData
import SwiftUI
import CryptoKit

// MARK: - Session Limits & Timeout Prompt

public struct ChargingSessionSettings: Codable, Equatable {
    public var enableMaxSessionDuration: Bool
    public var maxSessionDurationMinutes: Int
    public var enableTrickleTimeout: Bool
    public var tricklePowerThresholdW: Double
    public var trickleTimeoutMinutes: Int
    public var countdownSeconds: Int

    public static let `default` = ChargingSessionSettings(
        enableMaxSessionDuration: false,
        maxSessionDurationMinutes: 180,
        enableTrickleTimeout: true,
        tricklePowerThresholdW: 1.5,
        trickleTimeoutMinutes: 30,
        countdownSeconds: 60
    )

    private static let storageKey = "charging_session_settings_v1"

    public static func load() -> ChargingSessionSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(ChargingSessionSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: ChargingSessionSettings.storageKey)
        }
    }
}

public enum SessionTimeoutType: String, Codable, Equatable {
    case maxDuration
    case trickleTimeout
}

public struct SessionTimeoutPrompt: Identifiable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let portName: String
    public let type: SessionTimeoutType
    public let deadline: Date

    public init(id: UUID = UUID(), sessionID: UUID, portName: String, type: SessionTimeoutType, deadline: Date) {
        self.id = id
        self.sessionID = sessionID
        self.portName = portName
        self.type = type
        self.deadline = deadline
    }

    public var countdownRemaining: Int {
        max(0, Int(ceil(deadline.timeIntervalSinceNow)))
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case monitor
    case sessions
    case wirelessADB
    case control
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor: "实时监控"
        case .sessions: "充电记录"
        case .wirelessADB: "无线调试"
        case .control: "控制台"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .monitor: "bolt.horizontal.circle"
        case .sessions: "chart.xyaxis.line"
        case .wirelessADB: "antenna.radiowaves.left.and.right"
        case .control: "slider.horizontal.3"
        case .settings: "gearshape"
        }
    }
}

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .idle: "未连接"
        case .connecting: "连接中"
        case .connected: "已连接"
        case .failed(let msg): msg
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}

enum ChargingStrategy: Int, CaseIterable, Identifiable {
    case fast = 0
    case slow = 1
    case highPerformance = 7
    case ultraFastSinglePort = 8

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fast: "快速"
        case .slow: "均衡"
        case .highPerformance: "高性能"
        case .ultraFastSinglePort: "单口极速"
        }
    }

    var detail: String { "\(title) (\(rawValue))" }
}

enum TemperatureMode: Int, CaseIterable, Identifiable {
    case powerPriority = 0
    case temperaturePriority = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .powerPriority: "性能优先"
        case .temperaturePriority: "温度优先"
        }
    }

    var detail: String { "\(title) (\(rawValue))" }
}

enum CableCompensationGear: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case highPerformance
    case disabled

    var id: String { rawValue }
    static let visibleCases: [CableCompensationGear] = [.low, .medium, .high, .highPerformance]

    var title: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .highPerformance: "高性能"
        case .disabled: "关闭"
        }
    }

    var resistance: Int {
        switch self {
        case .low, .medium, .disabled: 0
        case .high, .highPerformance: 1
        }
    }

    var voltageOffset: Int {
        switch self {
        case .low, .disabled: 0
        case .medium, .high: 2
        case .highPerformance: 3
        }
    }
}

@Model
final class MirrorDevice {
    var id: UUID
    var name: String
    var keychainAccount: String
    var psn: String?
    var model: String?
    var productFamily: String?
    var overrideProductFamily: String?
    var maxPowerBudget: Int
    var createdAt: Date
    var lastSeenAt: Date?

    var effectiveProductFamily: String? {
        if let overrideProductFamily, !overrideProductFamily.isEmpty, overrideProductFamily != "auto" {
            return overrideProductFamily
        }
        return productFamily
    }

    init(
        id: UUID = UUID(),
        name: String,
        keychainAccount: String,
        psn: String? = nil,
        model: String? = nil,
        productFamily: String? = nil,
        overrideProductFamily: String? = nil,
        maxPowerBudget: Int = 0,
        createdAt: Date = Date(),
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.keychainAccount = keychainAccount
        self.psn = psn
        self.model = model
        self.productFamily = productFamily
        self.overrideProductFamily = overrideProductFamily
        self.maxPowerBudget = maxPowerBudget
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

@Model
final class ChargingSession {
    var id: UUID
    var deviceID: UUID
    var deviceName: String
    var portIndex: Int
    var portName: String
    var customTitle: String?
    var connectedDeviceName: String?
    var startedAt: Date
    var endedAt: Date?
    var endReason: String?
    var sampleCount: Int
    var peakPowerW: Double
    var averagePowerW: Double
    var minVoltageMV: Int
    var maxVoltageMV: Int
    var protocolSummary: String
    var hasBatteryData: Bool
    var finalBatteryPercent: Double?
    var boundAndroidSerial: String?
    var maxBatteryTempC: Double?

    init(
        id: UUID = UUID(),
        deviceID: UUID,
        deviceName: String,
        portIndex: Int,
        portName: String,
        connectedDeviceName: String? = nil,
        startedAt: Date = Date(),
        boundAndroidSerial: String? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.portIndex = portIndex
        self.portName = portName
        self.customTitle = nil
        self.connectedDeviceName = connectedDeviceName
        self.startedAt = startedAt
        self.endedAt = nil
        self.endReason = nil
        self.sampleCount = 0
        self.peakPowerW = 0
        self.averagePowerW = 0
        self.minVoltageMV = 0
        self.maxVoltageMV = 0
        self.protocolSummary = ""
        self.hasBatteryData = false
        self.finalBatteryPercent = nil
        self.boundAndroidSerial = boundAndroidSerial
        self.maxBatteryTempC = nil
    }

    var isStandaloneBatterySession: Bool {
        portIndex == 0 || (boundAndroidSerial != nil && peakPowerW == 0 && hasBatteryData)
    }

    var isAppleSession: Bool {
        let text = "\(displayTitle) \(connectedDeviceName ?? "") \(deviceName)".lowercased()
        return text.contains("iphone") || text.contains("ipad") || text.contains("apple") || text.contains("macbook") || text.contains("ios")
    }

    var displayTitle: String {
        let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        if isStandaloneBatterySession {
            if let dev = connectedDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !dev.isEmpty {
                return "\(dev) · 电池监视"
            }
            return "Android 电池监视"
        }
        if let dev = connectedDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !dev.isEmpty {
            return "\(dev) · \(portName)"
        }
        return "\(deviceName) · \(portName)"
    }
}

@Model
final class PortSample {
    var id: UUID
    var sessionID: UUID?
    var deviceID: UUID
    var deviceName: String?
    var timestamp: Date
    var portIndex: Int
    var portName: String
    var connected: Bool?
    var protocolName: String
    var voltageMV: Int
    var currentMA: Int
    var powerW: Double
    var temperature: String?
    var sessionChargeMWh: Int?
    var batteryPercent: Double?
    var batteryVoltageMV: Int?
    var batteryTempC: Double?
    var event: String?

    init(
        id: UUID = UUID(),
        sessionID: UUID?,
        deviceID: UUID,
        deviceName: String? = nil,
        timestamp: Date = Date(),
        portIndex: Int,
        portName: String,
        connected: Bool? = nil,
        protocolName: String,
        voltageMV: Int,
        currentMA: Int,
        powerW: Double,
        temperature: String? = nil,
        sessionChargeMWh: Int? = nil,
        batteryPercent: Double? = nil,
        batteryVoltageMV: Int? = nil,
        batteryTempC: Double? = nil,
        event: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.timestamp = timestamp
        self.portIndex = portIndex
        self.portName = portName
        self.connected = connected
        self.protocolName = protocolName
        self.voltageMV = voltageMV
        self.currentMA = currentMA
        self.powerW = powerW
        self.temperature = temperature
        self.sessionChargeMWh = sessionChargeMWh
        self.batteryPercent = batteryPercent
        self.batteryVoltageMV = batteryVoltageMV
        self.batteryTempC = batteryTempC
        self.event = event
    }
}

@Model
final class ControlEvent {
    var id: UUID
    var deviceID: UUID
    var deviceName: String
    var timestamp: Date
    var action: String
    var detail: String
    var verified: Bool

    init(
        id: UUID = UUID(),
        deviceID: UUID,
        deviceName: String,
        timestamp: Date = Date(),
        action: String,
        detail: String,
        verified: Bool
    ) {
        self.id = id
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.timestamp = timestamp
        self.action = action
        self.detail = detail
        self.verified = verified
    }
}

struct MachinePort: Identifiable, Codable, Hashable, Sendable {
    let index: Int
    let name: String
    let connectorType: String
    let power: Int

    var id: Int { index }
    var displayName: String { name }

    enum CodingKeys: String, CodingKey {
        case index
        case name
        case connectorType = "connector_type"
        case power
    }
}

struct DeviceInfo: Codable, Sendable {
    let appVersion: String?
    let fpgaVersion: String?
    let model: String?
    let psn: String?
    let ssid: String?
    let rssi: Int?

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case fpgaVersion = "fpga_version"
        case model
        case psn
        case ssid
        case rssi
    }
}

struct MachineFacts: Codable, Sendable {
    let productFamily: String?
    let brandEN: String?
    let brandZH: String?
    let friendlyNameEN: String?
    let friendlyNameZH: String?
    let maxPowerBudget: Int
    let ports: [MachinePort]

    enum CodingKeys: String, CodingKey {
        case productFamily = "product_family"
        case brandEN = "brand_en"
        case brandZH = "brand_zh"
        case friendlyNameEN = "friendly_name_en"
        case friendlyNameZH = "friendly_name_zh"
        case maxPowerBudget = "max_power_budget"
        case ports
    }
}

struct PortDetailsEnvelope: Codable, Sendable {
    let ports: [PortDetail]
}

struct PortDetail: Codable, Identifiable, Hashable, Sendable {
    let connected: Bool
    let dieTemperature: String
    let enable: Bool?
    let fcProtocol: String
    let ioutMA: Int
    let port: Int
    let sessionChargeMWh: Int
    let vinMV: Int?
    let voutMV: Int
    let deviceNameEN: String?
    let deviceNameZH: String?

    var id: Int { port }

    enum CodingKeys: String, CodingKey {
        case connected
        case dieTemperature = "die_temperature"
        case enable
        case fcProtocol = "fc_protocol"
        case ioutMA = "iout_ma"
        case port
        case sessionChargeMWh = "session_charge_mwh"
        case vinMV = "vin_mv"
        case voutMV = "vout_mv"
        case deviceNameEN = "device_name_en"
        case deviceNameZH = "device_name_zh"
    }

    var powerW: Double {
        Double(voutMV * ioutMA) / 1_000_000
    }

    var hasNegotiatedLoad: Bool {
        connected
    }
}

struct ChargingStatus: Codable, Sendable {
    let statusBitmask: Int

    enum CodingKeys: String, CodingKey {
        case statusBitmask = "status_bitmask"
    }
}

struct TemperatureModeResponse: Codable, Sendable {
    let mode: Int
    let modeName: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case modeName = "mode_name"
    }
}

struct PDStatusEnvelope: Codable, Sendable {
    let ports: [PDPortStatus]
}

struct PDPortStatus: Codable, Hashable, Sendable {
    let port: Int
    let batteryPercent: Double?
    let manufacturer: String?
    let modelName: String?
    let serialNumber: String?
    let batteryCapacityMWh: Double?
    let batteryLastFullChargeCapacityMWh: Double?
    let batteryPresentCapacityMWh: Double?
    let batteryHealthPercent: Double?
    let estimatedFullMinutes: Double?
    let remainingTimeText: String?
    let cycleCount: Int?

    nonisolated init(
        port: Int,
        batteryPercent: Double? = nil,
        manufacturer: String? = nil,
        modelName: String? = nil,
        serialNumber: String? = nil,
        batteryCapacityMWh: Double? = nil,
        batteryLastFullChargeCapacityMWh: Double? = nil,
        batteryPresentCapacityMWh: Double? = nil,
        batteryHealthPercent: Double? = nil,
        estimatedFullMinutes: Double? = nil,
        remainingTimeText: String? = nil,
        cycleCount: Int? = nil
    ) {
        self.port = port
        self.batteryPercent = Self.normalizedPercent(batteryPercent)
        self.manufacturer = manufacturer
        self.modelName = modelName
        self.serialNumber = serialNumber
        self.batteryCapacityMWh = batteryCapacityMWh
        self.batteryLastFullChargeCapacityMWh = batteryLastFullChargeCapacityMWh
        self.batteryPresentCapacityMWh = batteryPresentCapacityMWh
        self.batteryHealthPercent = Self.normalizedPercent(batteryHealthPercent)
        self.estimatedFullMinutes = estimatedFullMinutes
        self.remainingTimeText = remainingTimeText
        self.cycleCount = cycleCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let nestedContainers = ["battery", "device", "product", "pd"]
            .compactMap { try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .init($0)) }
        let containers = [container] + nestedContainers
        port = (try? container.decode(Int.self, forKey: .init("port"))) ?? 0
        var decodedPercent = Self.normalizedPercent(Self.decodeFirstDouble(in: containers, keys: [
            "battery_percent",
            "batteryPercent",
            "battery_level",
            "batteryLevel",
            "soc",
            "battery_soc",
            "state_of_charge",
            "relative_state_of_charge",
            "capacityPercent"
        ]))
        var decodedMfr = Self.decodeFirstString(in: containers, keys: [
            "device_brand_zh", "device_brand_en", "device_brand", "brand",
            "manufacturer", "vendor", "device_manufacturer", "device_vendor", "oem"
        ])
        if decodedMfr == nil {
            let vid = Self.decodeFirstInt(in: containers, keys: ["batteryVid", "battery_vid", "manufacturerVid", "manufacturer_vid"])
            if vid == 0x05AC || vid == 1452 {
                decodedMfr = "Apple"
            } else if let vid {
                decodedMfr = String(format: "0x%04X", vid)
            }
        }
        manufacturer = decodedMfr
        modelName = Self.decodeFirstString(in: containers, keys: [
            "device_name_zh", "device_name_en", "device_name",
            "model", "model_name", "device_model", "product_name", "name", "product"
        ])
        serialNumber = Self.decodeFirstString(in: containers, keys: [
            "serial", "serial_number", "device_serial", "sn"
        ])
        let rawDesignCapacity = Self.decodeFirstDouble(in: containers, keys: [
            "battery_capacity_mwh", "batteryCapacityMWh", "capacity_mwh", "design_capacity_mwh",
            "batteryDesignCapacity", "designCapacity", "battery_design_capacity",
            "nominal_capacity_mwh"
        ])
        let rawLastFullCapacity = Self.decodeFirstDouble(in: containers, keys: [
            "batteryLastFullChargeCapacity", "lastFullChargeCapacity", "current_max_capacity_mwh",
            "full_charge_capacity_mwh", "battery_full_charge_capacity_mwh", "battery_last_full_charge_capacity"
        ])
        let rawPresentCapacity = Self.decodeFirstDouble(in: containers, keys: [
            "batteryPresentCapacity", "presentCapacity", "current_capacity_mwh",
            "battery_present_capacity_mwh", "battery_present_capacity"
        ])

        batteryCapacityMWh = Self.normalizeCapacityMWh(rawDesignCapacity)
        batteryLastFullChargeCapacityMWh = Self.normalizeCapacityMWh(rawLastFullCapacity)
        batteryPresentCapacityMWh = Self.normalizeCapacityMWh(rawPresentCapacity)

        if decodedPercent == nil, let present = rawPresentCapacity, present > 0 {
            if let full = rawLastFullCapacity, full > 0 {
                decodedPercent = min(100.0, max(0.0, (present / full) * 100.0))
            } else if let design = rawDesignCapacity, design > 0 {
                decodedPercent = min(100.0, max(0.0, (present / design) * 100.0))
            }
        }
        batteryPercent = decodedPercent

        var decodedHealth = Self.normalizedPercent(Self.decodeFirstDouble(in: containers, keys: [
            "battery_health", "battery_health_percent", "health", "health_percent", "soh",
            "batteryHealth",
            "state_of_health"
        ]))
        if decodedHealth == nil, let full = rawLastFullCapacity, let design = rawDesignCapacity, design > 0, full > 0 {
            decodedHealth = min(100.0, max(0.0, (full / design) * 100.0))
        }
        batteryHealthPercent = decodedHealth

        var decodedFullMins = Self.decodeFirstDouble(in: containers, keys: [
            "estimated_full_minutes", "estimate_full_minutes", "time_to_full_minutes",
            "minutes_to_full", "time_to_full_min", "remaining_charge_minutes"
        ])
        var decodedRemainingTime = Self.decodeFirstString(in: containers, keys: [
            "remainingTimeStr", "remaining_time_str", "remainingTime", "timeToFullText"
        ])

        let batteryStatus = Self.decodeFirstInt(in: containers, keys: ["battery_status", "batteryStatus"])
        if decodedFullMins == nil, (batteryStatus == nil || batteryStatus == 0) {
            let v = Self.decodeFirstDouble(in: containers, keys: ["operating_voltage", "voltage", "operatingVoltage"])
            let c = Self.decodeFirstDouble(in: containers, keys: ["operating_current", "current", "operatingCurrent"])
            if let v, let c, v > 0, c > 0,
               let full = batteryLastFullChargeCapacityMWh ?? batteryCapacityMWh,
               let pres = batteryPresentCapacityMWh, full > pres {
                let volts = v > 1000 ? v / 1000.0 : (v > 100 ? v / 100.0 : v)
                let amps = c > 1000 ? c / 1000.0 : (c > 100 ? c / 100.0 : c)
                let powerW = max(1.0, volts * amps)
                let remWh = (full - pres) / 1000.0
                let hours = remWh / powerW
                decodedFullMins = min(600.0, max(1.0, hours * 60.0))
            }
        }
        if decodedRemainingTime == nil, let mins = decodedFullMins {
            let intMins = Int(round(mins))
            if intMins >= 60 {
                decodedRemainingTime = "\(intMins / 60)小时\(intMins % 60)分钟"
            } else {
                decodedRemainingTime = "\(intMins) 分钟"
            }
        }
        estimatedFullMinutes = decodedFullMins
        remainingTimeText = decodedRemainingTime

        cycleCount = Self.decodeFirstInt(in: containers, keys: [
            "cycle_count", "battery_cycle_count", "cycles"
        ])
    }

    private static func normalizeCapacityMWh(_ val: Double?) -> Double? {
        guard let val, val > 0 else { return nil }
        if val <= 1000 {
            return val * 100.0
        }
        return val
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(port, forKey: .init("port"))
        try container.encodeIfPresent(batteryPercent, forKey: .init("battery_percent"))
        try container.encodeIfPresent(manufacturer, forKey: .init("manufacturer"))
        try container.encodeIfPresent(modelName, forKey: .init("model"))
        try container.encodeIfPresent(serialNumber, forKey: .init("serial_number"))
        try container.encodeIfPresent(batteryCapacityMWh, forKey: .init("battery_capacity_mwh"))
        try container.encodeIfPresent(batteryLastFullChargeCapacityMWh, forKey: .init("battery_last_full_charge_capacity_mwh"))
        try container.encodeIfPresent(batteryPresentCapacityMWh, forKey: .init("battery_present_capacity_mwh"))
        try container.encodeIfPresent(batteryHealthPercent, forKey: .init("battery_health_percent"))
        try container.encodeIfPresent(estimatedFullMinutes, forKey: .init("estimated_full_minutes"))
        try container.encodeIfPresent(remainingTimeText, forKey: .init("remaining_time_text"))
        try container.encodeIfPresent(cycleCount, forKey: .init("cycle_count"))
    }

    nonisolated var hasUsefulPayload: Bool {
        batteryPercent != nil ||
            manufacturer != nil ||
            modelName != nil ||
            serialNumber != nil ||
            batteryCapacityMWh != nil ||
            batteryLastFullChargeCapacityMWh != nil ||
            batteryPresentCapacityMWh != nil ||
            batteryHealthPercent != nil ||
            estimatedFullMinutes != nil ||
            remainingTimeText != nil ||
            cycleCount != nil
    }

    nonisolated var hasNativeBatteryTelemetry: Bool {
        batteryPercent != nil ||
            batteryCapacityMWh != nil ||
            batteryPresentCapacityMWh != nil ||
            batteryLastFullChargeCapacityMWh != nil
    }

    nonisolated func merged(withFallback fallback: PDPortStatus?) -> PDPortStatus {
        guard let fallback else { return self }
        return PDPortStatus(
            port: port == 0 ? fallback.port : port,
            batteryPercent: batteryPercent ?? fallback.batteryPercent,
            manufacturer: manufacturer ?? fallback.manufacturer,
            modelName: modelName ?? fallback.modelName,
            serialNumber: serialNumber ?? fallback.serialNumber,
            batteryCapacityMWh: batteryCapacityMWh ?? fallback.batteryCapacityMWh,
            batteryLastFullChargeCapacityMWh: batteryLastFullChargeCapacityMWh ?? fallback.batteryLastFullChargeCapacityMWh,
            batteryPresentCapacityMWh: batteryPresentCapacityMWh ?? fallback.batteryPresentCapacityMWh,
            batteryHealthPercent: batteryHealthPercent ?? fallback.batteryHealthPercent,
            estimatedFullMinutes: estimatedFullMinutes ?? fallback.estimatedFullMinutes,
            remainingTimeText: remainingTimeText ?? fallback.remainingTimeText,
            cycleCount: cycleCount ?? fallback.cycleCount
        )
    }

    private static func decodeFirstString(
        in containers: [KeyedDecodingContainer<DynamicCodingKey>],
        keys: [String]
    ) -> String? {
        for container in containers {
            for key in keys {
                if let value = try? container.decode(String.self, forKey: .init(key)) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    private static func decodeFirstDouble(
        in containers: [KeyedDecodingContainer<DynamicCodingKey>],
        keys: [String]
    ) -> Double? {
        for container in containers {
            for key in keys {
                if let value = try? container.decode(Double.self, forKey: .init(key)) {
                    return value
                }
                if let value = try? container.decode(Int.self, forKey: .init(key)) {
                    return Double(value)
                }
                if let value = try? container.decode(String.self, forKey: .init(key)),
                   let number = Double(value.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) {
                    return number
                }
            }
        }
        return nil
    }

    private static func decodeFirstInt(
        in containers: [KeyedDecodingContainer<DynamicCodingKey>],
        keys: [String]
    ) -> Int? {
        for container in containers {
            for key in keys {
                if let value = try? container.decode(Int.self, forKey: .init(key)) {
                    return value
                }
                if let value = try? container.decode(Double.self, forKey: .init(key)) {
                    return Int(value)
                }
                if let value = try? container.decode(String.self, forKey: .init(key)),
                   let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return number
                }
            }
        }
        return nil
    }

    nonisolated private static func normalizedPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return value <= 1 ? value * 100 : value
    }
}

struct PortViewState: Identifiable, Hashable {
    let port: MachinePort
    var detail: PortDetail?
    var pdStatus: PDPortStatus?
    var charging: Bool
    var boundADBDevice: ADBDevice? = nil

    var id: Int { port.index }

    var isAppleDevice: Bool {
        if let model = pdStatus?.modelName?.lowercased() {
            if model.contains("iphone") || model.contains("ipad") || model.contains("macbook") || model.contains("apple") || model.contains("ios") {
                return true
            }
        }
        if let name = detail?.deviceNameZH?.lowercased() ?? detail?.deviceNameEN?.lowercased() {
            if name.contains("iphone") || name.contains("ipad") || name.contains("macbook") || name.contains("apple") || name.contains("ios") {
                return true
            }
        }
        return false
    }

    var hasNativePDBattery: Bool {
        pdStatus?.hasNativeBatteryTelemetry == true
    }

    var isNonAndroidDevice: Bool {
        if isAppleDevice { return true }
        let textToCheck = [
            pdStatus?.modelName,
            pdStatus?.manufacturer,
            detail?.deviceNameZH,
            detail?.deviceNameEN
        ].compactMap { $0?.lowercased() }.joined(separator: " ")
        
        let nonAndroidKeywords = [
            "rog", "ally", "asus", "steam", "deck", "valve", "switch", "nintendo",
            "lenovo", "thinkpad", "legion", "dell", "alienware", "hp", "omen",
            "surface", "microsoft", "razer", "blade", "gpd", "ayaneo", "onexplayer", "aokzoe"
        ]
        return nonAndroidKeywords.contains { textToCheck.contains($0) }
    }

    var canAutoBindADB: Bool {
        !isAppleDevice && !isNonAndroidDevice && !hasNativePDBattery
    }

    var powerW: Double { detail?.powerW ?? 0 }
    
    // 如果是 Apple 设备、非 Android 设备或已具备原生 PD 电池遥测的设备，优先使用原生 PD 电池数据
    var batteryPercent: Double? {
        if isAppleDevice || isNonAndroidDevice || hasNativePDBattery {
            return pdStatus?.batteryPercent ?? boundADBDevice?.batteryPercent
        }
        return boundADBDevice?.batteryPercent ?? pdStatus?.batteryPercent
    }
    
    var batteryTempC: Double? {
        if isAppleDevice || (isNonAndroidDevice && boundADBDevice == nil) { return nil }
        return boundADBDevice?.batteryTempC
    }
    
    var batteryVoltageMV: Int? {
        if isAppleDevice || (isNonAndroidDevice && boundADBDevice == nil) { return nil }
        return boundADBDevice?.batteryVoltageMV
    }
    var voltageText: String { "\(detail?.voutMV ?? 0) mV" }
    var currentText: String { "\(detail?.ioutMA ?? 0) mA" }
    var protocolName: String { detail?.fcProtocol ?? "Unknown" }
    var protocolLabel: String { LocalizedTelemetry.protocolLabel(protocolName) }
    var temperature: String { detail?.dieTemperature ?? "-" }
    var temperatureLabel: String { LocalizedTelemetry.temperatureLabel(temperature) }
    var portSwitchState: Bool? { detail?.enable }
    var chargeStateLabel: String {
        guard connected else { return "未接入" }
        return powerW > 0.5 ? "正在供电" : "已接入"
    }
    var connected: Bool { charging || detail?.connected == true }
}

struct ChartSamplePoint: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let portIndex: Int
    let portName: String
    let connected: Bool
    let powerW: Double
    let voltageV: Double
    let currentA: Double
    let temperatureScore: Double
    let batteryPercent: Double?
    let batteryTempC: Double?

    init(
        timestamp: Date,
        portIndex: Int,
        portName: String,
        connected: Bool,
        powerW: Double,
        voltageV: Double,
        currentA: Double,
        temperatureScore: Double,
        batteryPercent: Double? = nil,
        batteryTempC: Double? = nil
    ) {
        self.timestamp = timestamp
        self.portIndex = portIndex
        self.portName = portName
        self.connected = connected
        self.powerW = powerW
        self.voltageV = voltageV
        self.currentA = currentA
        self.temperatureScore = temperatureScore
        self.batteryPercent = batteryPercent
        self.batteryTempC = batteryTempC

        var bytes = [UInt8](repeating: 0, count: 16)
        
        // Port Index (4 bytes)
        bytes[0] = UInt8((portIndex >> 24) & 0xFF)
        bytes[1] = UInt8((portIndex >> 16) & 0xFF)
        bytes[2] = UInt8((portIndex >> 8) & 0xFF)
        bytes[3] = UInt8(portIndex & 0xFF)
        
        // Timestamp bits (8 bytes)
        let timeBits = timestamp.timeIntervalSince1970.bitPattern
        bytes[4] = UInt8((timeBits >> 56) & 0xFF)
        bytes[5] = UInt8((timeBits >> 48) & 0xFF)
        bytes[6] = UInt8((timeBits >> 40) & 0xFF)
        bytes[7] = UInt8((timeBits >> 32) & 0xFF)
        bytes[8] = UInt8((timeBits >> 24) & 0xFF)
        bytes[9] = UInt8((timeBits >> 16) & 0xFF)
        bytes[10] = UInt8((timeBits >> 8) & 0xFF)
        bytes[11] = UInt8(timeBits & 0xFF)
        
        bytes[12] = 0xCA
        bytes[13] = 0x4D
        bytes[14] = 0x59
        bytes[15] = 0x01
        
        self.id = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct DeviceValidationResult {
    let info: DeviceInfo
    let facts: MachineFacts
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

enum LocalizedTelemetry {
    static func protocolLabel(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "未知协议" }
        let lowercased = normalized.lowercased()

        if let numericProtocol = Int(normalized), let label = miniProgramFastChargeProtocolLabel(for: numericProtocol) {
            return label
        }

        if lowercased == "unknown(21)" ||
            lowercased == "unknown 21" ||
            lowercased == "protocol 21" ||
            lowercased.contains("xiaomi") ||
            lowercased.contains("hypercharge") ||
            lowercased.contains("mi turbo") ||
            lowercased.contains("澎湃秒充") {
            return "小米澎湃秒充"
        }

        switch lowercased {
        case "unknown":
            return "未知协议"
        case "not charging", "not_charging", "idle", "fc_not_charging":
            return "NOT_CHARGING"
        case "none", "fc_none":
            return "NONE"
        case "fc_qc2":
            return "QC2"
        case "fc_qc3":
            return "QC3"
        case "fc_qc3p", "fc_qc3_plus":
            return "QC3P"
        case "fc_sfcp":
            return "SFCP"
        case "fc_afc":
            return "AFC"
        case "fc_fcp":
            return "FCP"
        case "fc_scp":
            return "SCP"
        case "fc_vooc1p0":
            return "VOOC1P0"
        case "fc_vooc4p0":
            return "VOOC4P0"
        case "fc_svooc2p0":
            return "SVOOC2P0"
        case "fc_tfcp":
            return "TFCP"
        case "fc_ufcs":
            return "UFCS"
        case "fc_pe1":
            return "PE1"
        case "fc_pe2":
            return "PE2"
        case "fc_pd_fix5v", "pd fixed 5v", "pd 固定电压", "pd 固定电压档":
            return "PD_FIX5V"
        case "fc_pd_fixhv", "pd fixed high voltage", "pd fixed hv", "pd 固定高压":
            return "PD_FIXHV"
        case "fc_pd_spr_avs":
            return "PD_SPR_AVS"
        case "fc_pd_pps", "pd programmable power supply", "programmable power supply", "pps":
            return "PD_PPS"
        case "fc_pd_epr_hv":
            return "PD_EPR_HV"
        case "fc_pd_avs":
            return "PD_AVS"
        case "fc_pd_mi_pps", "pd_mi_pps":
            return "小米澎湃秒充"
        default:
            return normalized.hasPrefix("FC_") ? String(normalized.dropFirst(3)) : normalized
        }
    }

    private static func miniProgramFastChargeProtocolLabel(for value: Int) -> String? {
        switch value {
        case 0: return "NONE"
        case 1: return "QC2"
        case 2: return "QC3"
        case 3: return "QC3P"
        case 4: return "SFCP"
        case 5: return "AFC"
        case 6: return "FCP"
        case 7: return "SCP"
        case 8: return "VOOC1P0"
        case 9: return "VOOC4P0"
        case 10: return "SVOOC2P0"
        case 11: return "TFCP"
        case 12: return "UFCS"
        case 13: return "PE1"
        case 14: return "PE2"
        case 15: return "PD_FIX5V"
        case 16: return "PD_FIXHV"
        case 17: return "PD_SPR_AVS"
        case 18: return "PD_PPS"
        case 19: return "PD_EPR_HV"
        case 20: return "PD_AVS"
        case 21: return "小米澎湃秒充"
        case 255: return "NOT_CHARGING"
        default: return nil
        }
    }

    static func temperatureLabel(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cool":
            return "清爽"
        case "moderate":
            return "正常"
        case "warm":
            return "偏热"
        case "hot":
            return "高温"
        case "", "-":
            return "未知"
        default:
            return raw
        }
    }

    static func temperatureModeLabel(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "power_priority", "power priority":
            return "性能优先"
        case "temperature_priority", "temperature priority":
            return "温度优先"
        default:
            return temperatureLabel(raw)
        }
    }

    static func portName(_ index: Int) -> String {
        switch index {
        case 1: return "A"
        case 2: return "C1"
        case 3: return "C2"
        case 4: return "C3"
        case 5: return "C4"
        default: return "\(index)"
        }
    }
}

// MARK: - Wireless ADB Models

struct ADBDevice: Identifiable, Hashable, Sendable {
    let serial: String
    var brand: String
    var model: String
    var isOnline: Bool
    var isWireless: Bool
    var ip: String?
    var port: Int?
    var batteryPercent: Double?
    var batteryVoltageMV: Int?
    var batteryTempC: Double?
    var batteryStatus: String?
    var isCharging: Bool
    var lastSeenAt: Date

    var id: String { serial }

    var virtualDeviceID: UUID {
        Self.virtualDeviceID(for: serial)
    }

    static func virtualDeviceID(for serial: String) -> UUID {
        let clean = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = Insecure.MD5.hash(data: Data("ADBDevice:\(clean)".utf8))
        var bytes = [UInt8](digest)
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    init(
        serial: String,
        brand: String = "",
        model: String = "",
        isOnline: Bool = true,
        isWireless: Bool = false,
        ip: String? = nil,
        port: Int? = nil,
        batteryPercent: Double? = nil,
        batteryVoltageMV: Int? = nil,
        batteryTempC: Double? = nil,
        batteryStatus: String? = nil,
        isCharging: Bool = false,
        lastSeenAt: Date = Date()
    ) {
        self.serial = serial
        self.brand = brand
        self.model = model
        self.isOnline = isOnline
        self.isWireless = isWireless
        self.ip = ip
        self.port = port
        self.batteryPercent = batteryPercent
        self.batteryVoltageMV = batteryVoltageMV
        self.batteryTempC = batteryTempC
        self.batteryStatus = batteryStatus
        self.isCharging = isCharging
        self.lastSeenAt = lastSeenAt
    }

    var displayName: String {
        let cleanModel = model.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBrand = brand.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanModel.isEmpty {
            if !cleanBrand.isEmpty && !cleanModel.lowercased().contains(cleanBrand.lowercased()) {
                return "\(cleanBrand) \(cleanModel)"
            }
            return cleanModel
        }
        return serial
    }

    var isMDNSWireless: Bool {
        serial.contains("._tcp") || serial.contains("._adb")
    }

    var shortAddress: String {
        if isWireless {
            if let ip, let port {
                return "\(ip):\(port)"
            }
            if isMDNSWireless {
                return "Wi-Fi (mDNS TLS)"
            }
            return "Wi-Fi 无线"
        }
        return "USB 有线"
    }
}

struct ADBConnectionHistory: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(host):\(port)" }
    let host: String
    let port: Int
    var displayName: String?
    var lastConnectedAt: Date

    init(host: String, port: Int, displayName: String? = nil, lastConnectedAt: Date = Date()) {
        self.host = host
        self.port = port
        self.displayName = displayName
        self.lastConnectedAt = lastConnectedAt
    }
}

// MARK: - Charging Session Analytics (ChargerLAB Style)

struct ChargingSessionAnalytics: Sendable, Equatable {
    let peakPowerW: Double
    let averagePowerW: Double
    let peakDurationS: Double
    let maxBatteryTempC: Double?
    let minBatteryTempC: Double?
    let initialBatteryPercent: Double?
    let finalBatteryPercent: Double?
    let timeTo50PercentS: Double?
    let timeTo80PercentS: Double?
    let timeTo100PercentS: Double?
    let timeToFullChargeS: Double?
    let isTrickleCharging: Bool
    let powerAt30PercentW: Double?
    let powerAt50PercentW: Double?
    let powerAt80PercentW: Double?
    let estimatedEnergyWh: Double
    let sampleCount: Int

    var tempRiseC: Double? {
        guard let max = maxBatteryTempC, let min = minBatteryTempC else { return nil }
        return max - min
    }

    static func analyze(session: ChargingSession, samples: [PortSample]) -> ChargingSessionAnalytics {
        let sortedSamples = samples.sorted(by: { $0.timestamp < $1.timestamp })
        let powerValues = sortedSamples.map(\.powerW)
        let peakPower = powerValues.max() ?? session.peakPowerW
        let avgPower = powerValues.isEmpty ? session.averagePowerW : powerValues.reduce(0, +) / Double(powerValues.count)

        // Peak duration: total time where power >= 90% of peak (and peak > 1.0W)
        var peakDuration: Double = 0
        if peakPower > 1.0 && sortedSamples.count > 1 {
            let threshold = peakPower * 0.90
            for i in 0..<(sortedSamples.count - 1) {
                let s1 = sortedSamples[i]
                let s2 = sortedSamples[i + 1]
                if s1.powerW >= threshold {
                    let dt = min(max(0, s2.timestamp.timeIntervalSince(s1.timestamp)), 10.0)
                    peakDuration += dt
                }
            }
        }

        let batteryTemps = sortedSamples.compactMap(\.batteryTempC)
        let maxTemp = batteryTemps.max()
        let minTemp = batteryTemps.min()

        let batterySamples = sortedSamples.filter { $0.batteryPercent != nil }
        let initialBat = batterySamples.first?.batteryPercent
        let finalBat = batterySamples.last?.batteryPercent ?? session.finalBatteryPercent

        // Time to 50%, 80%, 100% (UI)
        var t50: Double?
        var t80: Double?
        var t100: Double?
        var sample100: PortSample?

        if let initB = initialBat {
            if initB < 50, let s50 = batterySamples.first(where: { ($0.batteryPercent ?? 0) >= 50 }) {
                t50 = s50.timestamp.timeIntervalSince(session.startedAt)
            }
            if initB < 80, let s80 = batterySamples.first(where: { ($0.batteryPercent ?? 0) >= 80 }) {
                t80 = s80.timestamp.timeIntervalSince(session.startedAt)
            }
            if initB < 99.5, let s100 = batterySamples.first(where: { ($0.batteryPercent ?? 0) >= 99.5 }) {
                t100 = s100.timestamp.timeIntervalSince(session.startedAt)
                sample100 = s100
            }
        }

        // Time to Actual Full Charge (Trickle Finished)
        var tFull: Double?
        var isTrickle = false

        let reachedFullBattery = (sample100 != nil) || (initialBat != nil && initialBat! >= 99.5) || (finalBat != nil && finalBat! >= 99.5)
        let isTrickleEndedReason = session.endReason == "trickle_charge" || session.endReason == "battery_full"

        if reachedFullBattery || isTrickleEndedReason {
            let baselineTime = sample100?.timestamp ?? session.startedAt
            let samplesAfter100 = sortedSamples.filter { $0.timestamp >= baselineTime }

            // 1. 优先检查显式充满事件
            if let fullEventSample = samplesAfter100.first(where: {
                $0.event == "battery_full" || $0.protocolName == "已充满" || $0.protocolName.contains("充满")
            }) {
                tFull = max(fullEventSample.timestamp.timeIntervalSince(session.startedAt), t100 ?? 0)
            } else {
                // 2. 检查功率截止（Trickle Cut-off）：功率降至 <= 0.8W 且后续保持低功率
                let cutoffThresholdW = 0.8
                var cutoffSample: PortSample?

                for (idx, sample) in samplesAfter100.enumerated() {
                    if sample.powerW <= cutoffThresholdW {
                        let subsequent = samplesAfter100[idx...]
                        let maxSubsequentPower = subsequent.map(\.powerW).max() ?? 0
                        if maxSubsequentPower <= 2.0 {
                            cutoffSample = sample
                            break
                        }
                    }
                }

                if let cutoff = cutoffSample {
                    tFull = max(cutoff.timestamp.timeIntervalSince(session.startedAt), t100 ?? 0)
                } else if let endedAt = session.endedAt {
                    if isTrickleEndedReason {
                        tFull = max(endedAt.timeIntervalSince(session.startedAt), t100 ?? 0)
                    } else if let lastSample = sortedSamples.last, lastSample.powerW <= 2.0 {
                        tFull = max(lastSample.timestamp.timeIntervalSince(session.startedAt), t100 ?? 0)
                    }
                } else if reachedFullBattery {
                    isTrickle = true
                }
            }
        }

        // Power at 30%, 50%, 80%
        func nearestPower(targetPercent: Double) -> Double? {
            guard !batterySamples.isEmpty else { return nil }
            if let initB = initialBat, initB > targetPercent + 1.0 {
                return nil
            }
            let nearest = batterySamples.min(by: {
                abs(($0.batteryPercent ?? 0) - targetPercent) < abs(($1.batteryPercent ?? 0) - targetPercent)
            })
            if let nearest, abs((nearest.batteryPercent ?? 0) - targetPercent) <= 5.0 {
                return nearest.powerW
            }
            return nil
        }

        let p30 = nearestPower(targetPercent: 30)
        let p50 = nearestPower(targetPercent: 50)
        let p80 = nearestPower(targetPercent: 80)

        // Estimated Energy
        var energyWh = 0.0
        if sortedSamples.count > 1 {
            for i in 0..<(sortedSamples.count - 1) {
                let s1 = sortedSamples[i]
                let s2 = sortedSamples[i + 1]
                let dt = min(max(0, s2.timestamp.timeIntervalSince(s1.timestamp)), 10.0)
                energyWh += ((s1.powerW + s2.powerW) / 2.0) * dt
            }
            energyWh /= 3600.0
        }

        return ChargingSessionAnalytics(
            peakPowerW: peakPower,
            averagePowerW: avgPower,
            peakDurationS: peakDuration,
            maxBatteryTempC: maxTemp,
            minBatteryTempC: minTemp,
            initialBatteryPercent: initialBat,
            finalBatteryPercent: finalBat,
            timeTo50PercentS: t50,
            timeTo80PercentS: t80,
            timeTo100PercentS: t100,
            timeToFullChargeS: tFull,
            isTrickleCharging: isTrickle,
            powerAt30PercentW: p30,
            powerAt50PercentW: p50,
            powerAt80PercentW: p80,
            estimatedEnergyWh: energyWh,
            sampleCount: sortedSamples.count
        )
    }
}

