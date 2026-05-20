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
    var deviceName: String
    var timestamp: Date
    var portIndex: Int
    var portName: String
    var connected: Bool
    var protocolName: String
    var voltageMV: Int
    var currentMA: Int
    var powerW: Double
    var temperature: String
    var sessionChargeMWh: Int
    var batteryPercent: Double?
    var event: String?

    init(
        id: UUID = UUID(),
        sessionID: UUID?,
        deviceID: UUID,
        deviceName: String,
        timestamp: Date = Date(),
        portIndex: Int,
        portName: String,
        connected: Bool,
        protocolName: String,
        voltageMV: Int,
        currentMA: Int,
        powerW: Double,
        temperature: String,
        sessionChargeMWh: Int,
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        port = (try? container.decode(Int.self, forKey: .init("port"))) ?? 0
        let candidateKeys = [
            "battery_percent",
            "batteryPercent",
            "battery_level",
            "batteryLevel",
            "soc",
            "battery_soc"
        ]
        var percent: Double?
        for key in candidateKeys where percent == nil {
            if let value = try? container.decode(Double.self, forKey: .init(key)) {
                percent = value
            } else if let value = try? container.decode(Int.self, forKey: .init(key)) {
                percent = Double(value)
            }
        }
        batteryPercent = percent
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(port, forKey: .init("port"))
        try container.encodeIfPresent(batteryPercent, forKey: .init("battery_percent"))
    }
}

struct PortViewState: Identifiable, Hashable {
    let port: MachinePort
    var detail: PortDetail?
    var batteryPercent: Double?
    var charging: Bool

    var id: Int { port.index }

    var powerW: Double { detail?.powerW ?? 0 }
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

        if lowercased == "unknown(21)" ||
            lowercased == "unknown 21" ||
            lowercased == "protocol 21" ||
            lowercased == "21" ||
            lowercased.contains("xiaomi") ||
            lowercased.contains("hypercharge") ||
            lowercased.contains("mi turbo") ||
            lowercased.contains("澎湃秒充") {
            return "小米澎湃秒充"
        }

        switch lowercased {
        case "unknown":
            return "未知协议"
        case "not charging", "not_charging", "idle":
            return "未充电"
        case "pd programmable power supply", "programmable power supply", "pps":
            return "PD 可编程电源"
        case "pd fixed supply":
            return "PD 固定电压"
        case "pd fixed high voltage":
            return "PD 固定高压"
        case "qc", "quick charge":
            return "QC 快充"
        default:
            return normalized
                .replacingOccurrences(of: "Programmable Power Supply", with: "可编程电源")
                .replacingOccurrences(of: "Fixed Supply", with: "固定电压")
                .replacingOccurrences(of: "Not Charging", with: "未充电")
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
