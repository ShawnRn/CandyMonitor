//
//  ADBUpdateChecker.swift
//  CandyMonitor
//
//  Created by Shawn Rain on 2026/9/16.
//

import Foundation
import Observation
import AppKit

/// 远程 Homebrew Cask API 元数据结构体
public struct ADBRemoteCaskResponse: Codable, Sendable {
    public let token: String?
    public let version: String
    public let name: [String]?
    public let desc: String?
    public let homepage: String?
    public let url: String?
}

/// ADB 工具包更新检测状态
public enum ADBUpdateStatus: Sendable, Equatable {
    case idle
    case checking
    case upToDate(version: String)
    case updateAvailable(currentVersion: String?, latestVersion: String, releaseNotesURL: URL?, downloadURL: URL?)
    case failed(message: String)

    public var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

/// 管理 ADB (Android SDK Platform-Tools) 客户端版本检测与在线更新查询
@Observable
@MainActor
public final class ADBUpdateChecker {
    public static let shared = ADBUpdateChecker()

    public var status: ADBUpdateStatus = .idle
    public var latestVersion: String?
    public var latestReleaseNotesURL: URL?
    public var latestDownloadURL: URL?
    public var lastCheckedAt: Date?
    public var lastErrorMessage: String?

    /// 官方 Homebrew Cask 格式化元数据接口（由 GitHub Fastly 全球 CDN 托管，高可用且低延迟）
    private static let caskAPIURL = URL(string: "https://formulae.brew.sh/api/cask/android-platform-tools.json")!
    /// Google 官方 Platform-Tools 发行说明文档
    public static let officialReleaseNotesURL = URL(string: "https://developer.android.com/tools/releases/platform-tools")!
    /// Google 官方最新 Darwin 压缩包下载直链
    public static let officialDownloadDarwinURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    public init() {}

    /// 检查 ADB 版本更新
    /// - Parameters:
    ///   - installedVersion: 本地解析出的具体版本字符串（如 "37.0.0"）
    ///   - force: 是否忽略缓存强制刷新
    public func checkForUpdates(installedVersion: String?, force: Bool = false) async {
        // 若距上次检查不足 15 分钟且非强制，则直接使用缓存结果进行本地版本复核
        if !force, let last = lastCheckedAt, let latest = latestVersion, Date().timeIntervalSince(last) < 900 {
            evaluateStatus(installedVersion: installedVersion, latestVersion: latest)
            return
        }

        status = .checking
        lastErrorMessage = nil

        do {
            let info = try await fetchLatestReleaseInfo()
            self.latestVersion = info.version
            self.latestReleaseNotesURL = info.homepage.flatMap(URL.init) ?? Self.officialReleaseNotesURL
            self.latestDownloadURL = info.url.flatMap(URL.init) ?? Self.officialDownloadDarwinURL
            self.lastCheckedAt = Date()

            evaluateStatus(installedVersion: installedVersion, latestVersion: info.version)
        } catch {
            let errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.lastErrorMessage = errorMsg
            self.status = .failed(message: errorMsg)
        }
    }

    /// 自动生成并在系统终端中直接执行 ADB 升级脚本，无需用户手动复制粘贴
    @discardableResult
    public func runAutoUpgradeScript(onComplete: (@MainActor () -> Void)? = nil) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("candymonitor_upgrade_adb.command")

        let scriptContent = """
        #!/bin/bash
        clear
        echo "========================================================"
        echo "  CandyMonitor - 正在自动升级 Android Platform-Tools"
        echo "========================================================"
        echo ""

        # 检查 brew 路径
        BREW_BIN=""
        if command -v brew >/dev/null 2>&1; then
            BREW_BIN="brew"
        elif [ -f /opt/homebrew/bin/brew ]; then
            BREW_BIN="/opt/homebrew/bin/brew"
        elif [ -f /usr/local/bin/brew ]; then
            BREW_BIN="/usr/local/bin/brew"
        fi

        if [ -n "$BREW_BIN" ]; then
            echo "▶ 发现 Homebrew，正在执行一键升级..."
            $BREW_BIN upgrade android-platform-tools || $BREW_BIN install android-platform-tools
        else
            echo "❌ 未检测到 Homebrew，正在为您打开 Google 官方发布页面..."
            open "https://developer.android.com/tools/releases/platform-tools"
            echo "请下载解压后，在 CandyMonitor 中点击「浏览选择...」选取 adb 执行程序。"
            sleep 3
            exit 1
        fi

        echo ""
        echo "▶ 正在重启 ADB 守护进程以应用新版本..."
        if command -v adb >/dev/null 2>&1; then
            adb kill-server 2>/dev/null || true
            adb start-server 2>/dev/null || true
        elif [ -f /opt/homebrew/bin/adb ]; then
            /opt/homebrew/bin/adb kill-server 2>/dev/null || true
            /opt/homebrew/bin/adb start-server 2>/dev/null || true
        fi

        echo ""
        echo "========================================================"
        echo "  ✓ 升级已执行完毕！请返回 CandyMonitor 查看最新状态。"
        echo "========================================================"
        sleep 2
        exit 0
        """

        do {
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            let attributes = [FileAttributeKey.posixPermissions: 0o755]
            try FileManager.default.setAttributes(attributes, ofItemAtPath: scriptURL.path)

            let success = NSWorkspace.shared.open(scriptURL)
            if success {
                // 安排在 6 秒和 12 秒后各尝试刷新一次状态
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    onComplete?()
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    onComplete?()
                }
            }
            return success
        } catch {
            lastErrorMessage = "生成升级脚本失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 联网拉取最新发布信息
    private func fetchLatestReleaseInfo() async throws -> ADBRemoteCaskResponse {
        var request = URLRequest(url: Self.caskAPIURL)
        request.timeoutInterval = 10.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(ADBRemoteCaskResponse.self, from: data)
    }

    /// 评估本地版本与云端版本的对比关系
    public func evaluateStatus(installedVersion: String?, latestVersion: String) {
        guard let installed = cleanVersionString(installedVersion) else {
            // 本地具体版本号未知，显示发现新版本供用户参考更新
            self.status = .updateAvailable(
                currentVersion: nil,
                latestVersion: latestVersion,
                releaseNotesURL: latestReleaseNotesURL ?? Self.officialReleaseNotesURL,
                downloadURL: latestDownloadURL ?? Self.officialDownloadDarwinURL
            )
            return
        }

        let comparison = Self.compareSemver(installed, latestVersion)
        if comparison == .orderedAscending {
            // installed < latest
            self.status = .updateAvailable(
                currentVersion: installed,
                latestVersion: latestVersion,
                releaseNotesURL: latestReleaseNotesURL ?? Self.officialReleaseNotesURL,
                downloadURL: latestDownloadURL ?? Self.officialDownloadDarwinURL
            )
        } else {
            // installed >= latest
            self.status = .upToDate(version: installed)
        }
    }

    /// 清理并规范化版本字符串（如去除 "v" 前缀、去除尾部构建号等）
    private func cleanVersionString(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        var cleaned = raw
        if cleaned.lowercased().hasPrefix("v") {
            cleaned.removeFirst()
        }
        if let hyphenIndex = cleaned.firstIndex(of: "-") {
            cleaned = String(cleaned[..<hyphenIndex])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 三段语义化版本比对（SemVer）
    public static func compareSemver(_ v1: String, _ v2: String) -> ComparisonResult {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }

        let maxCount = max(parts1.count, parts2.count)
        for i in 0..<maxCount {
            let num1 = i < parts1.count ? parts1[i] : 0
            let num2 = i < parts2.count ? parts2[i] : 0
            if num1 < num2 {
                return .orderedAscending
            } else if num1 > num2 {
                return .orderedDescending
            }
        }
        return .orderedSame
    }

    /// 尝试从本地 platform-tools 目录中读取 source.properties 获得精确版本（如 Pkg.Revision=37.0.0）
    public static func parseVersionFromProperties(at executablePath: String) -> String? {
        let execURL = URL(fileURLWithPath: executablePath)
        let dirURL = execURL.deletingLastPathComponent()

        // 候选属性文件路径（同级目录、或者标准 platform-tools 目录下）
        let candidates = [
            dirURL.appendingPathComponent("source.properties"),
            dirURL.deletingLastPathComponent().appendingPathComponent("source.properties")
        ]

        let fm = FileManager.default
        for fileURL in candidates {
            if fm.fileExists(atPath: fileURL.path) {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    if let version = extractRevision(from: content) {
                        return version
                    }
                }
            }
        }

        // 尝试解析 Caskroom 软链接路径（如 /opt/homebrew/Caskroom/android-platform-tools/37.0.1/...）
        let resolvedPath = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        if resolvedPath != executablePath {
            let resolvedDir = URL(fileURLWithPath: resolvedPath).deletingLastPathComponent()
            let resolvedProps = resolvedDir.appendingPathComponent("source.properties")
            if fm.fileExists(atPath: resolvedProps.path),
               let content = try? String(contentsOf: resolvedProps, encoding: .utf8),
               let version = extractRevision(from: content) {
                return version
            }

            // 从路径组件正则匹配（如 /37.0.1/）
            let components = resolvedPath.split(separator: "/")
            for comp in components {
                if comp.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
                    return String(comp)
                }
            }
        }

        return nil
    }

    private static func extractRevision(from content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Pkg.Revision") {
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
}
