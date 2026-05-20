import Foundation

enum CSVExporter {
    static func makeCSV(session: ChargingSession, samples: [PortSample]) -> String {
        var lines: [String] = []
        lines.append("Summary")
        lines.append(csvRow(["Device", session.deviceName]))
        lines.append(csvRow(["Port", session.portName]))
        lines.append(csvRow(["Connected Device", session.connectedDeviceName ?? ""]))
        lines.append(csvRow(["Started At", iso8601.string(from: session.startedAt)]))
        lines.append(csvRow(["Ended At", session.endedAt.map { iso8601.string(from: $0) } ?? ""]))
        lines.append(csvRow(["Duration Seconds", "\(Int((session.endedAt ?? Date()).timeIntervalSince(session.startedAt)))"]))
        lines.append(csvRow(["End Reason", session.endReason ?? ""]))
        lines.append(csvRow(["Samples", "\(session.sampleCount)"]))
        lines.append(csvRow(["Peak Power W", number(session.peakPowerW)]))
        lines.append(csvRow(["Average Power W", number(session.averagePowerW)]))
        lines.append(csvRow(["Min Voltage mV", "\(session.minVoltageMV)"]))
        lines.append(csvRow(["Max Voltage mV", "\(session.maxVoltageMV)"]))
        lines.append(csvRow(["Protocols", session.protocolSummary]))
        lines.append(csvRow(["Final Battery Percent", session.finalBatteryPercent.map(number) ?? ""]))
        lines.append("")
        lines.append(csvRow([
            "Timestamp",
            "Device",
            "Port",
            "Protocol",
            "Voltage (mV)",
            "Current (mA)",
            "Power (W)",
            "Temperature",
            "Connected",
            "Battery (%)",
            "Event"
        ]))

        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            lines.append(csvRow([
                iso8601.string(from: sample.timestamp),
                sample.deviceName,
                sample.portName,
                LocalizedTelemetry.protocolLabel(sample.protocolName),
                "\(sample.voltageMV)",
                "\(sample.currentMA)",
                number(sample.powerW),
                sample.temperature,
                sample.connected ? "true" : "false",
                sample.batteryPercent.map(number) ?? "",
                sample.event ?? ""
            ]))
        }

        return lines.joined(separator: "\n")
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func csvRow(_ values: [String]) -> String {
        values.map(escape).joined(separator: ",")
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
