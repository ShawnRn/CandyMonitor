import Foundation

struct DiagnosticLog {
    private let fileURL: URL
    private let formatter: ISO8601DateFormatter

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = baseURL
            .appendingPathComponent("CandyMonitor", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("candymonitor.log")
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    var path: String {
        fileURL.path
    }

    func record(_ event: String, metadata: [String: String] = [:]) {
        let fields = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.sanitize($0.value))" }
            .joined(separator: " ")
        let suffix = fields.isEmpty ? "" : " \(fields)"
        let line = "\(formatter.string(from: Date())) \(event)\(suffix)\n"

        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            try? data.write(to: fileURL, options: [.atomic])
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static func redactedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else {
            return sanitize(raw)
        }
        if components.queryItems?.isEmpty == false {
            components.queryItems = [URLQueryItem(name: "query", value: "<redacted>")]
        }
        if components.password != nil {
            components.password = "<redacted>"
        }
        return components.string ?? sanitize(raw)
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
