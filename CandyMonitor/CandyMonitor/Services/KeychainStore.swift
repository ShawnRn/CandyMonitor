import CryptoKit
import Foundation

enum KeychainStore {
    private static let directoryName = "CandyMonitor"
    private static let storeName = "mcp-vault"

    static func saveMCPURL(_ url: String, account: String) throws {
        let sealed = try seal(Data(url.utf8))
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try sealed.write(to: fileURL(for: account), options: [.atomic])
    }

    static func loadMCPURL(account: String) throws -> String? {
        for url in candidateFileURLs(for: account) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let sealed = try Data(contentsOf: url)
            let opened = try open(sealed)
            guard let urlString = String(data: opened, encoding: .utf8) else {
                throw CredentialStoreError.invalidData
            }
            if url != fileURL(for: account) {
                try? saveMCPURL(urlString, account: account)
            }
            return urlString
        }
        return nil
    }

    static func hasMCPURL(account: String) -> Bool {
        candidateFileURLs(for: account).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func deleteMCPURL(account: String) {
        for url in candidateFileURLs(for: account) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(storeName, isDirectory: true)
    }

    private static func fileURL(for account: String) -> URL {
        fileURL(for: account, in: storeDirectory)
    }

    private static func fileURL(for account: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data((account + decodedSalt).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).cmvault")
    }

    private static func candidateFileURLs(for account: String) -> [URL] {
        ([storeDirectory] + legacyStoreDirectories)
            .map { fileURL(for: account, in: $0) }
            .reduce(into: []) { urls, url in
                if urls.contains(url) == false {
                    urls.append(url)
                }
            }
    }

    private static var legacyStoreDirectories: [URL] {
        let homeSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(storeName, isDirectory: true)
        return [homeSupport]
    }

    private static func seal(_ data: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: symmetricKey)
        guard let combined = box.combined else {
            throw CredentialStoreError.sealFailed
        }
        let envelope = LocalSecretEnvelope(version: 1, blob: Data(combined.reversed()).base64EncodedString())
        return try JSONEncoder().encode(envelope)
    }

    private static func open(_ data: Data) throws -> Data {
        let envelope = try JSONDecoder().decode(LocalSecretEnvelope.self, from: data)
        guard envelope.version == 1,
              let reversedBlob = Data(base64Encoded: envelope.blob) else {
            throw CredentialStoreError.invalidData
        }
        let combined = Data(reversedBlob.reversed())
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: symmetricKey)
    }

    private static var symmetricKey: SymmetricKey {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.shawnrain.CandyMonitor"
        let host = Host.current().localizedName ?? "localhost"
        let material = [
            NSHomeDirectory(),
            NSUserName(),
            host,
            bundleID,
            decodedSalt
        ].joined(separator: "|")
        return SymmetricKey(data: SHA256.hash(data: Data(material.utf8)))
    }

    private static var decodedSalt: String {
        String(bytes: obfuscatedSalt.map { $0 ^ 0x5A }, encoding: .utf8) ?? "CandyMonitor.MCP.SSE.v1"
    }

    private static let obfuscatedSalt: [UInt8] = [
        0x19, 0x3b, 0x34, 0x3e, 0x23, 0x17, 0x35, 0x34, 0x33, 0x2e, 0x35, 0x28,
        0x74, 0x17, 0x19, 0x0a, 0x74, 0x09, 0x09, 0x1f, 0x74, 0x2c, 0x6b
    ]
}

private struct LocalSecretEnvelope: Codable {
    let version: Int
    let blob: String
}

enum CredentialStoreError: LocalizedError {
    case invalidData
    case sealFailed

    var errorDescription: String? {
        switch self {
        case .invalidData:
            "本地连接配置损坏，请重新填写 MCP 地址"
        case .sealFailed:
            "本地连接配置加密失败"
        }
    }
}
