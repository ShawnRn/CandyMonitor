import Foundation
import SwiftData
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case monitor
    case sessions
    case control
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor: "实时监控"
        case .sessions: "充电记录"
        case .control: "控制台"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .monitor: "bolt.horizontal.circle"
        case .sessions: "chart.xyaxis.line"
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
        case .failed: "连接失败"
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
    var maxPowerBudget: Int
    var createdAt: Date
    var lastSeenAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        keychainAccount: String,
        psn: String? = nil,
        model: String? = nil,
        productFamily: String? = nil,
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

    init(
        id: UUID = UUID(),
        deviceID: UUID,
        deviceName: String,
        portIndex: Int,
        portName: String,
        connectedDeviceName: String? = nil,
        startedAt: Date = Date()
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
    }

    var displayTitle: String {
        let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "\(deviceName) · \(portName)" : title
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
        batteryPercent = Self.normalizedPercent(Self.decodeFirstDouble(in: containers, keys: [
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
        manufacturer = Self.decodeFirstString(in: containers, keys: [
            "manufacturer", "vendor", "brand", "device_manufacturer", "device_vendor", "oem"
        ])
        modelName = Self.decodeFirstString(in: containers, keys: [
            "model", "model_name", "device_model", "product_name", "name", "product"
        ])
        serialNumber = Self.decodeFirstString(in: containers, keys: [
            "serial", "serial_number", "device_serial", "sn"
        ])
        batteryCapacityMWh = Self.decodeFirstDouble(in: containers, keys: [
            "battery_capacity_mwh", "batteryCapacityMWh", "capacity_mwh", "design_capacity_mwh",
            "batteryDesignCapacity", "designCapacity", "battery_design_capacity",
            "nominal_capacity_mwh"
        ])
        batteryLastFullChargeCapacityMWh = Self.decodeFirstDouble(in: containers, keys: [
            "batteryLastFullChargeCapacity", "lastFullChargeCapacity", "current_max_capacity_mwh",
            "full_charge_capacity_mwh", "battery_full_charge_capacity_mwh"
        ])
        batteryPresentCapacityMWh = Self.decodeFirstDouble(in: containers, keys: [
            "batteryPresentCapacity", "presentCapacity", "current_capacity_mwh",
            "battery_present_capacity_mwh"
        ])
        batteryHealthPercent = Self.normalizedPercent(Self.decodeFirstDouble(in: containers, keys: [
            "battery_health", "battery_health_percent", "health", "health_percent", "soh",
            "batteryHealth",
            "state_of_health"
        ]))
        estimatedFullMinutes = Self.decodeFirstDouble(in: containers, keys: [
            "estimated_full_minutes", "estimate_full_minutes", "time_to_full_minutes",
            "minutes_to_full", "time_to_full_min", "remaining_charge_minutes"
        ])
        remainingTimeText = Self.decodeFirstString(in: containers, keys: [
            "remainingTimeStr", "remaining_time_str", "remainingTime", "timeToFullText"
        ])
        cycleCount = Self.decodeFirstInt(in: containers, keys: [
            "cycle_count", "battery_cycle_count", "cycles"
        ])
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

    var id: Int { port.index }

    var powerW: Double { detail?.powerW ?? 0 }
    var batteryPercent: Double? { pdStatus?.batteryPercent }
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
    let id = UUID()
    let timestamp: Date
    let portIndex: Int
    let portName: String
    let connected: Bool
    let powerW: Double
    let voltageV: Double
    let currentA: Double
    let temperatureScore: Double
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
