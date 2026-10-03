//
//  Extensions.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import AppKit
import Foundation
import SwiftUI

enum AppPlatform {
    static let usesDesktopLayout = true
    static let topSafeArea: CGFloat = 0
    static let bottomSafeArea: CGFloat = 0
}

struct AppReleaseAsset: Equatable {
    var name: String
    var downloadURL: URL
}

struct AppRelease: Equatable {
    var version: String
    var tagName: String
    var pageURL: URL
    var assets: [AppReleaseAsset]

    func downloadableAssets() -> (dmg: AppReleaseAsset, checksum: AppReleaseAsset)? {
        let expectedDMGName = "Niratan-Mac-\(version).dmg"
        guard let dmg = assets.first(where: { $0.name == expectedDMGName }) else {
            return nil
        }

        let expectedChecksumName = expectedDMGName.replacingOccurrences(of: ".dmg", with: ".sha256")
        guard let checksum = assets.first(where: { $0.name == expectedChecksumName }) else {
            return nil
        }

        return (dmg, checksum)
    }
}

enum UpdateCheckAlert: Identifiable, Equatable {
    case available(AppRelease, currentVersion: String)
    case upToDate(currentVersion: String)
    case failed
    case downloadFailed

    var id: String {
        switch self {
        case .available(let release, let currentVersion):
            "available-\(release.tagName)-\(currentVersion)"
        case .upToDate(let currentVersion):
            "up-to-date-\(currentVersion)"
        case .failed:
            "failed"
        case .downloadFailed:
            "download-failed"
        }
    }
}

@MainActor
@Observable
final class UpdateChecker {
    private struct GitHubReleaseAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/W1ght/Niratan/releases/latest")!
    private static let autoCheckKey = "updateCheckerLastAutomaticCheck"
    private static let automaticChecksEnabledKey = "updateCheckerAutomaticChecksEnabled"
    private static let autoCheckInterval: TimeInterval = 24 * 60 * 60
    private static let autoCheckPollInterval: Duration = .seconds(60 * 60)

    /// Shared by the main window's background checks and Settings > About.
    static let shared = UpdateChecker()

    var automaticChecksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecksEnabled, forKey: Self.automaticChecksEnabledKey)
        }
    }
    var lastCheckedAt: Date?
    var lastCheckFailed = false
    var isChecking = false
    var isDownloading = false
    var downloadProgress: Double?
    var availableRelease: AppRelease?
    var alert: UpdateCheckAlert?

    var hasAvailableUpdate: Bool {
        availableRelease != nil
    }

    var isBusy: Bool {
        isChecking || isDownloading
    }

    var downloadStatusText: String {
        guard let downloadProgress else {
            return String(localized: "Downloading Update...")
        }

        return String(
            format: String(localized: "Downloading Update... %@"),
            "\(Int((downloadProgress * 100).rounded()))%"
        )
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    init() {
        let defaults = UserDefaults.standard
        automaticChecksEnabled = defaults.object(forKey: Self.automaticChecksEnabledKey) as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: Self.autoCheckKey) as? Date
    }

    /// Checks the latest GitHub release at launch and then at most once a day while the app keeps running.
    func runAutomaticChecks() async {
        try? await Task.sleep(for: .seconds(3))
        while !Task.isCancelled {
            if automaticChecksEnabled {
                await checkAutomaticallyIfNeeded()
            }
            try? await Task.sleep(for: Self.autoCheckPollInterval)
        }
    }

    func checkAutomaticallyIfNeeded() async {
        let defaults = UserDefaults.standard
        if let lastCheck = defaults.object(forKey: Self.autoCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < Self.autoCheckInterval {
            return
        }

        await check(manual: false)
    }

    func check(manual: Bool) async {
        guard !isBusy else {
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            let now = Date()
            lastCheckedAt = now
            lastCheckFailed = false
            UserDefaults.standard.set(now, forKey: Self.autoCheckKey)
            if Self.isVersion(release.version, newerThan: currentVersion) {
                let isNewRelease = availableRelease?.tagName != release.tagName
                availableRelease = release
                // Manual checks report inline in Settings; background checks announce each new release once.
                if !manual && isNewRelease {
                    alert = .available(release, currentVersion: currentVersion)
                }
            } else {
                availableRelease = nil
            }
        } catch {
            lastCheckFailed = true
        }
    }

    func downloadAndOpenAvailableUpdate() async {
        guard !isBusy, let release = availableRelease else {
            return
        }

        guard let assets = release.downloadableAssets() else {
            alert = .downloadFailed
            return
        }

        isDownloading = true
        downloadProgress = 0
        alert = nil
        defer {
            isDownloading = false
            downloadProgress = nil
        }

        do {
            let expectedChecksum = try await fetchExpectedChecksum(from: assets.checksum.downloadURL)
            let downloadedURL = try await UpdateDownloadTask.download(from: assets.dmg.downloadURL) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }
            let destinationURL = try moveDownloadedUpdate(downloadedURL, named: assets.dmg.name)
            let actualChecksum = try Self.SHA256(for: destinationURL)
            guard actualChecksum.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
                try? FileManager.default.removeItem(at: destinationURL)
                throw URLError(.dataNotAllowed)
            }

            guard NSWorkspace.shared.open(destinationURL) else {
                throw URLError(.cannotOpenFile)
            }
            NSApplication.shared.terminate(nil)
        } catch {
            alert = .downloadFailed
        }
    }

    private func fetchLatestRelease() async throws -> AppRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Niratan-Mac", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else {
            throw URLError(.cannotParseResponse)
        }

        return AppRelease(
            version: Self.normalizedVersion(release.tagName),
            tagName: release.tagName,
            pageURL: release.htmlURL,
            assets: release.assets.map {
                AppReleaseAsset(name: $0.name, downloadURL: $0.browserDownloadURL)
            }
        )
    }

    private func fetchExpectedChecksum(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Niratan-Mac", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let text = String(data: data, encoding: .utf8),
              let checksum = text.split(whereSeparator: { $0.isWhitespace }).first else {
            throw URLError(.badServerResponse)
        }

        return String(checksum)
    }

    private func moveDownloadedUpdate(_ downloadedURL: URL, named fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Niratan Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloadedURL, to: destination)
        return destination
    }

    private static func SHA256(for fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? fileHandle.close()
        }

        var hasher = CryptoKit.SHA256()
        while true {
            let data = try fileHandle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedVersion(_ version: String) -> String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = versionParts(candidate)
        let currentParts = versionParts(current)
        let count = max(candidateParts.count, currentParts.count)

        for index in 0..<count {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs {
                return lhs > rhs
            }
        }

        return false
    }

    private static func versionParts(_ version: String) -> [Int] {
        normalizedVersion(version)
            .split { !$0.isNumber }
            .compactMap { Int($0) }
    }
}

private final class UpdateDownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Double) -> Void
    nonisolated(unsafe) private var continuation: CheckedContinuation<URL, Error>?
    nonisolated(unsafe) private var downloadedLocation: URL?
    nonisolated(unsafe) private var downloadError: Error?

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    static func download(
        from url: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let downloader = UpdateDownloadTask(progressHandler: progressHandler)
        return try await downloader.download(from: url)
    }

    private func download(from url: URL) async throws -> URL {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("Niratan-Mac", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Niratan Update Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stableLocation = directory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.removeItem(at: stableLocation)
            try FileManager.default.moveItem(at: location, to: stableLocation)
            downloadedLocation = stableLocation
        } catch {
            downloadError = error
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            continuation?.resume(throwing: error)
        } else if let downloadError {
            continuation?.resume(throwing: downloadError)
        } else if let downloadedLocation {
            continuation?.resume(returning: downloadedLocation)
        } else {
            continuation?.resume(throwing: URLError(.unknown))
        }
        continuation = nil
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            return
        }

        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

extension String {
    func filtered() -> String {
        ReaderCharacterNormalizer.filteredText(from: self)
    }
}

extension BookMetadata {
    var coverURL: URL? {
        guard let coverPath = self.cover else { return nil }
        if coverPath.hasPrefix("/") {
            return URL(fileURLWithPath: coverPath)
        }
        guard let appDir = try? BookStorage.getAppDirectory() else { return nil }
        return appDir.appendingPathComponent(coverPath)
    }
}

extension Data {
    var sha1: String {
        Insecure.SHA1.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

extension URL {
    mutating func excludeFromBackup() throws {
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try self.setResourceValues(resource)
    }
}

struct LoadingOverlay: View {
    let message: String

    init(_ message: String = "Loading...") {
        self.message = message
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            Group {
                if #available(iOS 26, macOS 26, *) {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(message)
                            .lineLimit(1)
                    }
                    .padding(24)
                    .glassEffect()
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(message)
                            .lineLimit(1)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(24)
        }
    }
}


extension View {
    @ViewBuilder
    func inlineNavigationTitleIfAvailable() -> some View {
        #if os(macOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    @ViewBuilder
    func conditionalGlassEffect() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(.regular.interactive())
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
        }
    }
}
