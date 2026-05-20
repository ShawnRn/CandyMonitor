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
        let url = fileURL(for: account)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let sealed = try Data(contentsOf: url)
        let opened = try open(sealed)
        return String(data: opened, encoding: .utf8)
    }

    static func deleteMCPURL(account: String) {
        try? FileManager.default.removeItem(at: fileURL(for: account))
    }

    private static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(storeName, isDirectory: true)
    }

    private static func fileURL(for account: String) -> URL {
        let digest = SHA256.hash(data: Data((account + decodedSalt).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return storeDirectory.appendingPathComponent("\(name).cmvault")
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
