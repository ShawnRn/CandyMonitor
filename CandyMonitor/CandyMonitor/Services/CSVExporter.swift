import Foundation

enum CSVExporter {
    static func makeCSV(session: ChargingSession, samples: [PortSample]) -> String {
        var lines = [csvRow([
            "timestamp_utc",
            "elapsed_s",
            "power_w",
            "voltage_v",
            "current_a",
            "battery_percent",
            "battery_voltage_mv",
            "battery_temp_c",
            "voltage_mv",
            "current_ma",
            "temperature_state",
            "protocol",
            "connected",
            "event"
        ])]

        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            lines.append(csvRow([
                iso8601.string(from: sample.timestamp),
                number(sample.timestamp.timeIntervalSince(session.startedAt)),
                number(sample.powerW),
                String(format: "%.3f", Double(sample.voltageMV) / 1000.0),
                String(format: "%.3f", Double(sample.currentMA) / 1000.0),
                sample.batteryPercent.map { number($0) } ?? "",
                sample.batteryVoltageMV.map { "\($0)" } ?? "",
                sample.batteryTempC.map { String(format: "%.1f", $0) } ?? "",
                "\(sample.voltageMV)",
                "\(sample.currentMA)",
                sample.temperature ?? "",
                sample.protocolName,
                sample.connected == true ? "true" : "false",
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
        let analytics = ChargingSessionAnalytics.analyze(session: session, samples: samples)
        let metadata: [String: Any] = [
            "schema_version": 2,
            "device_name": session.deviceName,
            "port_name": session.portName,
            "connected_device_name": session.connectedDeviceName ?? NSNull(),
            "bound_android_serial": session.boundAndroidSerial ?? NSNull(),
            "started_at": iso8601.string(from: session.startedAt),
            "ended_at": session.endedAt.map { iso8601.string(from: $0) } ?? NSNull(),
            "duration_s": Int(duration.rounded()),
            "end_reason": session.endReason ?? NSNull(),
            "sample_count": samples.count,
            "peak_power_w": analytics.peakPowerW,
            "average_power_w": analytics.averagePowerW,
            "peak_duration_s": analytics.peakDurationS,
            "min_voltage_mv": session.minVoltageMV,
            "max_voltage_mv": session.maxVoltageMV,
            "protocol_summary": session.protocolSummary,
            "initial_battery_percent": analytics.initialBatteryPercent ?? NSNull(),
            "final_battery_percent": analytics.finalBatteryPercent ?? NSNull(),
            "max_battery_temp_c": analytics.maxBatteryTempC ?? NSNull(),
            "time_to_50_percent_s": analytics.timeTo50PercentS ?? NSNull(),
            "time_to_80_percent_s": analytics.timeTo80PercentS ?? NSNull(),
            "time_to_100_percent_s": analytics.timeTo100PercentS ?? NSNull(),
            "time_to_full_charge_s": analytics.timeToFullChargeS ?? NSNull(),
            "power_at_30_percent_w": analytics.powerAt30PercentW ?? NSNull(),
            "power_at_50_percent_w": analytics.powerAt50PercentW ?? NSNull(),
            "power_at_80_percent_w": analytics.powerAt80PercentW ?? NSNull(),
            "estimated_energy_wh": analytics.estimatedEnergyWh
        ]
        return try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    }

    static func makeAISummaryJSON(session: ChargingSession, samples: [PortSample]) throws -> Data {
        let analytics = ChargingSessionAnalytics.analyze(session: session, samples: samples)
        let powerDict: [String: Any] = [
            "peak_w": analytics.peakPowerW,
            "average_w": analytics.averagePowerW,
            "peak_duration_s": analytics.peakDurationS,
            "final_w": samples.last?.powerW ?? 0
        ]
        let batteryDict: [String: Any] = [
            "initial_percent": analytics.initialBatteryPercent ?? NSNull(),
            "final_percent": analytics.finalBatteryPercent ?? NSNull(),
            "max_temperature_c": analytics.maxBatteryTempC ?? NSNull(),
            "time_to_50_pct_s": analytics.timeTo50PercentS ?? NSNull(),
            "time_to_80_pct_s": analytics.timeTo80PercentS ?? NSNull(),
            "time_to_100_pct_s": analytics.timeTo100PercentS ?? NSNull(),
            "time_to_full_charge_s": analytics.timeToFullChargeS ?? NSNull(),
            "power_at_30_pct_w": analytics.powerAt30PercentW ?? NSNull(),
            "power_at_50_pct_w": analytics.powerAt50PercentW ?? NSNull(),
            "power_at_80_pct_w": analytics.powerAt80PercentW ?? NSNull()
        ]
        let voltageDict: [String: Any] = [
            "min": samples.map(\.voltageMV).min() ?? 0,
            "max": samples.map(\.voltageMV).max() ?? 0
        ]
        var eventsList: [[String: Any]] = []
        for sample in samples {
            if let event = sample.event, !event.isEmpty {
                eventsList.append([
                    "timestamp_utc": iso8601.string(from: sample.timestamp),
                    "elapsed_s": sample.timestamp.timeIntervalSince(session.startedAt),
                    "event": event
                ])
            }
        }
        let summary: [String: Any] = [
            "title": session.displayTitle,
            "device": session.deviceName,
            "port": session.portName,
            "connected_device": session.connectedDeviceName ?? "Unknown",
            "started_at": iso8601.string(from: session.startedAt),
            "ended_at": session.endedAt.map { iso8601.string(from: $0) } ?? NSNull(),
            "sample_count": samples.count,
            "power": powerDict,
            "battery": batteryDict,
            "voltage_mv": voltageDict,
            "estimated_energy_wh": analytics.estimatedEnergyWh,
            "events": eventsList
        ]
        return try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    }

    static func makeREADME(session: ChargingSession) -> String {
        """
        # CandyMonitor Charging Export

        Session: \(session.displayTitle)
        Device: \(session.deviceName)
        Port: \(session.portName)
        Connected Device: \(session.connectedDeviceName ?? "Unknown")

        Files:
        - samples.csv: unified telemetry table including port power, voltage, current and Android battery/temperature.
        - events.csv: notable session events when available.
        - metadata.json: device, time range, ChargerLAB summary statistics, and estimated energy.
        - ai_summary.json: compact structured summary for LLM analysis.
        - schema.json: field names and units for samples.csv.
        """
    }

    static func makeSchemaJSON() throws -> Data {
        let schema: [String: Any] = [
            "samples_csv": [
                "timestamp_utc": "ISO-8601 UTC timestamp",
                "elapsed_s": "seconds since session start",
                "power_w": "charging power in watts",
                "voltage_v": "port voltage in volts",
                "current_a": "port current in amperes",
                "battery_percent": "battery level (0-100)",
                "battery_voltage_mv": "battery cell voltage in millivolts",
                "battery_temp_c": "battery temperature in Celsius",
                "voltage_mv": "port voltage in millivolts",
                "current_ma": "port current in milliamps",
                "temperature_state": "port die temperature state",
                "protocol": "fast-charge protocol",
                "connected": "load connection status",
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
