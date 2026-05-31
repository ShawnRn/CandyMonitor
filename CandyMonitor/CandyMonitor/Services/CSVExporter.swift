import Foundation

enum CSVExporter {
    static func makeCSV(session: ChargingSession, samples: [PortSample]) -> String {
        var lines = [csvRow([
            "timestamp_utc",
            "elapsed_s",
            "voltage_mv",
            "current_ma",
            "power_w",
            "temperature_state",
            "protocol",
            "connected",
            "battery_percent",
            "event"
        ])]

        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            lines.append(csvRow([
                iso8601.string(from: sample.timestamp),
                number(sample.timestamp.timeIntervalSince(session.startedAt)),
                "\(sample.voltageMV)",
                "\(sample.currentMA)",
                number(sample.powerW),
                sample.temperature ?? "",
                sample.protocolName,
                sample.connected == true ? "true" : "false",
                sample.batteryPercent.map { number($0) } ?? "",
                sample.event ?? ""
            ]))
        }

        return lines.joined(separator: "\n")
    }

    static func makeEventsCSV(session: ChargingSession, samples: [PortSample]) -> String {
        var lines = [csvRow(["timestamp_utc", "elapsed_s", "event", "protocol", "power_w"])]
        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) where sample.event?.isEmpty == false {
            lines.append(csvRow([
                iso8601.string(from: sample.timestamp),
                number(sample.timestamp.timeIntervalSince(session.startedAt)),
                sample.event ?? "",
                sample.protocolName,
                number(sample.powerW)
            ]))
        }
        return lines.joined(separator: "\n")
    }

    static func makeMetadataJSON(session: ChargingSession, samples: [PortSample]) throws -> Data {
        let duration = (session.endedAt ?? samples.last?.timestamp ?? Date()).timeIntervalSince(session.startedAt)
        let metadata: [String: Any] = [
            "schema_version": 1,
            "device_name": session.deviceName,
            "port_name": session.portName,
            "connected_device_name": session.connectedDeviceName ?? NSNull(),
            "started_at": iso8601.string(from: session.startedAt),
            "ended_at": session.endedAt.map { iso8601.string(from: $0) } ?? NSNull(),
            "duration_s": Int(duration.rounded()),
            "end_reason": session.endReason ?? NSNull(),
            "sample_count": samples.count,
            "peak_power_w": session.peakPowerW,
            "average_power_w": session.averagePowerW,
            "min_voltage_mv": session.minVoltageMV,
            "max_voltage_mv": session.maxVoltageMV,
            "protocol_summary": session.protocolSummary,
            "final_battery_percent": session.finalBatteryPercent ?? NSNull(),
            "estimated_energy_wh": estimatedEnergyWh(samples: samples)
        ]
        return try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    }

    static func makeAISummaryJSON(session: ChargingSession, samples: [PortSample]) throws -> Data {
        let powerValues = samples.map(\.powerW)
        let peakPower = powerValues.max() ?? 0
        let summary: [String: Any] = [
            "title": session.displayTitle,
            "device": session.deviceName,
            "port": session.portName,
            "started_at": iso8601.string(from: session.startedAt),
            "ended_at": session.endedAt.map { iso8601.string(from: $0) } ?? NSNull(),
            "sample_count": samples.count,
            "power": [
                "peak_w": peakPower,
                "average_w": samples.isEmpty ? 0 : powerValues.reduce(0, +) / Double(samples.count),
                "final_w": samples.last?.powerW ?? 0
            ],
            "voltage_mv": [
                "min": samples.map(\.voltageMV).min() ?? 0,
                "max": samples.map(\.voltageMV).max() ?? 0
            ],
            "estimated_energy_wh": estimatedEnergyWh(samples: samples),
            "events": samples.compactMap { sample -> [String: Any]? in
                guard let event = sample.event, event.isEmpty == false else { return nil }
                return [
                    "timestamp_utc": iso8601.string(from: sample.timestamp),
                    "elapsed_s": sample.timestamp.timeIntervalSince(session.startedAt),
                    "event": event
                ]
            }
        ]
        return try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    }

    static func makeREADME(session: ChargingSession) -> String {
        """
        # CandyMonitor Charging Export

        Session: \(session.displayTitle)
        Device: \(session.deviceName)
        Port: \(session.portName)

        Files:
        - samples.csv: pure sample table, first row is the header.
        - events.csv: notable session events when available.
        - metadata.json: device, time range, summary statistics, and estimated energy.
        - ai_summary.json: compact structured summary for LLM analysis.
        - schema.json: field names and units for samples.csv.
        """
    }

    static func makeSchemaJSON() throws -> Data {
        let schema: [String: Any] = [
            "samples_csv": [
                "timestamp_utc": "ISO-8601 UTC timestamp",
                "elapsed_s": "seconds since session start",
                "voltage_mv": "millivolts",
                "current_ma": "milliamps",
                "power_w": "watts",
                "temperature_state": "device temperature state string",
                "protocol": "raw fast-charge protocol",
                "connected": "true when load is detected",
                "battery_percent": "0-100 when available",
                "event": "optional event label"
            ]
        ]
        return try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
    }

    static func estimatedEnergyWh(samples: [PortSample]) -> Double {
        let ordered = samples.sorted(by: { $0.timestamp < $1.timestamp })
        guard ordered.count > 1 else { return 0 }

        var wattSeconds = 0.0
        for pair in zip(ordered, ordered.dropFirst()) {
            let dt = max(0, min(pair.1.timestamp.timeIntervalSince(pair.0.timestamp), 10))
            wattSeconds += ((pair.0.powerW + pair.1.powerW) / 2) * dt
        }
        return wattSeconds / 3600
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
        values.map { escape($0) }.joined(separator: ",")
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
