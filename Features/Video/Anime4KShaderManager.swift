import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftUI

private nonisolated enum Anime4KShaderStoreError: LocalizedError, Sendable {
    case invalidResponse
    case invalidShader
    case downloadFailed
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .downloadFailed:
            String(localized: "Unable to download verified Anime4K shaders. Check your connection and try again.")
        case .invalidShader:
            String(localized: "The downloaded Anime4K shader failed verification.")
        case .storageUnavailable:
            String(localized: "Anime4K shaders could not be saved on this Mac.")
        }
    }
}

private nonisolated struct Anime4KShaderDefinition: Sendable {
    let repositoryPath: String
    let sha256: String
}

private nonisolated final class Anime4KShaderStore: @unchecked Sendable {
    static let releaseTag = "v4.0.1"
    static let maximumShaderBytes = 2 * 1_024 * 1_024

    private static let definitions: [String: Anime4KShaderDefinition] = [
        "Anime4K_Clamp_Highlights.glsl": .init(
            repositoryPath: "glsl/Restore/Anime4K_Clamp_Highlights.glsl",
            sha256: "A2A9BF7FBC1D75D09660CA2E701E4D7FB0CF5457B94DA47E1825032FA2B3671A"
        ),
        "Anime4K_Restore_CNN_M.glsl": .init(
            repositoryPath: "glsl/Restore/Anime4K_Restore_CNN_M.glsl",
            sha256: "67EA3ED26539E8DE3B7D307688535D2FF17E8D147E11DDA0247DA7770DBECF41"
        ),
        "Anime4K_Upscale_CNN_x2_M.glsl": .init(
            repositoryPath: "glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            sha256: "716E02098A68F0D648761F2B96B4DD139E1CB09B174BB369FCA3AA34328FFF7E"
        ),
        "Anime4K_AutoDownscalePre_x2.glsl": .init(
            repositoryPath: "glsl/Upscale/Anime4K_AutoDownscalePre_x2.glsl",
            sha256: "8C58291740146BD766A4D73F132775A797FE80F7D07919B5D767E27A5DC85656"
        ),
        "Anime4K_AutoDownscalePre_x4.glsl": .init(
            repositoryPath: "glsl/Upscale/Anime4K_AutoDownscalePre_x4.glsl",
            sha256: "5AF62D8CD844916DC1126613E13BAD3BEAB195787F93A71200B47C6EC78F2E41"
        ),
        "Anime4K_Upscale_CNN_x2_S.glsl": .init(
            repositoryPath: "glsl/Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
            sha256: "4C53EC2E287908F7EE7BCB266B0170421626D663576468B7D7DAFC62962649A4"
        ),
        "Anime4K_Restore_CNN_VL.glsl": .init(
            repositoryPath: "glsl/Restore/Anime4K_Restore_CNN_VL.glsl",
            sha256: "35036722733305CD4D4E57660B883BBE2569BA2914033C254327107D7B77E35E"
        ),
        "Anime4K_Upscale_CNN_x2_VL.glsl": .init(
            repositoryPath: "glsl/Upscale/Anime4K_Upscale_CNN_x2_VL.glsl",
            sha256: "5638FE31C37C151A3443FEA3451A3EF91AF073F4DBB9615F6C0D1E29DB11493D"
        ),
    ]

    private let fileManager: FileManager
    private let session: URLSession
    private let shaderDirectory: URL

    init(
        fileManager: FileManager = .default,
        session: URLSession? = nil,
        shaderDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration)
        }
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.shaderDirectory = shaderDirectory ?? applicationSupport
            .appendingPathComponent("VideoShaders", isDirectory: true)
            .appendingPathComponent("Anime4K", isDirectory: true)
            .appendingPathComponent(Self.releaseTag, isDirectory: true)
    }

    func installedShaderURLs(for preset: VideoShaderPreset) -> [URL] {
        guard preset != .off else { return [] }
        let urls = preset.shaderFileNames.map(destinationURL(for:))
        guard urls.count == preset.shaderFileNames.count else { return [] }
        for (fileName, url) in zip(preset.shaderFileNames, urls) {
            guard let definition = Self.definitions[fileName],
                  let data = try? Data(contentsOf: url),
                  Self.isValidShader(data, expectedSHA256: definition.sha256) else {
                return []
            }
        }
        return urls
    }

    func ensureAvailable(
        _ preset: VideoShaderPreset,
        progress: @escaping @Sendable (Int, Int, String) -> Void
    ) async throws {
        guard preset != .off else { return }
        do {
            try fileManager.createDirectory(
                at: shaderDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw Anime4KShaderStoreError.storageUnavailable
        }

        for (index, fileName) in preset.shaderFileNames.enumerated() {
            try Task.checkCancellation()
            guard let definition = Self.definitions[fileName] else {
                throw Anime4KShaderStoreError.invalidShader
            }
            let destination = destinationURL(for: fileName)
            if let installed = try? Data(contentsOf: destination),
               Self.isValidShader(installed, expectedSHA256: definition.sha256) {
                progress(index + 1, preset.shaderFileNames.count, fileName)
                continue
            }
            let data = try await download(definition)
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                throw Anime4KShaderStoreError.storageUnavailable
            }
            progress(index + 1, preset.shaderFileNames.count, fileName)
        }
    }

    private func download(_ definition: Anime4KShaderDefinition) async throws -> Data {
        var lastError: (any Error)?
        for url in Self.downloadURLs(repositoryPath: definition.repositoryPath) {
            do {
                var request = URLRequest(url: url)
                request.setValue("Niratan/Anime4K-Downloader", forHTTPHeaderField: "User-Agent")
                let (bytes, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      httpResponse.expectedContentLength < 0
                        || httpResponse.expectedContentLength <= Self.maximumShaderBytes else {
                    throw Anime4KShaderStoreError.invalidResponse
                }
                var data = Data()
                if httpResponse.expectedContentLength > 0 {
                    data.reserveCapacity(
                        min(Int(httpResponse.expectedContentLength), Self.maximumShaderBytes)
                    )
                }
                for try await byte in bytes {
                    guard data.count < Self.maximumShaderBytes else {
                        throw Anime4KShaderStoreError.invalidShader
                    }
                    data.append(byte)
                }
                guard Self.isValidShader(data, expectedSHA256: definition.sha256) else {
                    throw Anime4KShaderStoreError.invalidShader
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
            }
        }
        if let error = lastError as? Anime4KShaderStoreError {
            throw error
        }
        throw Anime4KShaderStoreError.downloadFailed
    }

    private func destinationURL(for fileName: String) -> URL {
        shaderDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func downloadURLs(repositoryPath: String) -> [URL] {
        [
            URL(string: "https://raw.githubusercontent.com/bloc97/Anime4K/\(releaseTag)/\(repositoryPath)"),
            URL(string: "https://cdn.jsdelivr.net/gh/bloc97/Anime4K@\(releaseTag)/\(repositoryPath)"),
            URL(string: "https://fastly.jsdelivr.net/gh/bloc97/Anime4K@\(releaseTag)/\(repositoryPath)"),
        ].compactMap { $0 }
    }

    private static func isValidShader(_ data: Data, expectedSHA256: String) -> Bool {
        guard !data.isEmpty,
              data.count <= maximumShaderBytes,
              let source = String(data: data, encoding: .utf8),
              source.contains("//!HOOK"),
              source.contains("//!BIND") else {
            return false
        }
        let actualSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined()
        return actualSHA256 == expectedSHA256
    }
}

@MainActor
@Observable
final class Anime4KShaderManager {
    static let shared = Anime4KShaderManager()

    private static let log = Logger(
        subsystem: "moe.shishamo.hoshi",
        category: "Anime4K"
    )

    private let store: Anime4KShaderStore
    private(set) var installedPresets: Set<VideoShaderPreset> = []
    private(set) var downloadingPreset: VideoShaderPreset?
    private(set) var completedFiles = 0
    private(set) var totalFiles = 0
    private(set) var currentFileName = ""
    private(set) var failedPreset: VideoShaderPreset?
    private(set) var errorMessage: String?

    private init(store: Anime4KShaderStore = Anime4KShaderStore()) {
        self.store = store
        refreshInstalledPresets()
    }

    func refreshInstalledPresets() {
        installedPresets = Set(
            VideoShaderPreset.allCases.filter {
                $0 == .off || !store.installedShaderURLs(for: $0).isEmpty
            }
        )
    }

    func isInstalled(_ preset: VideoShaderPreset) -> Bool {
        preset == .off || installedPresets.contains(preset)
    }

    func installedShaderURLs(for preset: VideoShaderPreset) -> [URL] {
        store.installedShaderURLs(for: preset)
    }

    func ensureAvailable(_ preset: VideoShaderPreset) async -> Bool {
        guard preset != .off else { return true }
        refreshInstalledPresets()
        if isInstalled(preset) { return true }
        guard downloadingPreset == nil else { return false }

        downloadingPreset = preset
        completedFiles = 0
        totalFiles = preset.shaderFileNames.count
        currentFileName = ""
        failedPreset = nil
        errorMessage = nil

        let store = store
        do {
            try await Task.detached(priority: .utility) {
                try await store.ensureAvailable(preset) { completed, total, fileName in
                    Task { @MainActor [weak self] in
                        guard self?.downloadingPreset == preset else { return }
                        self?.completedFiles = completed
                        self?.totalFiles = total
                        self?.currentFileName = fileName
                    }
                }
            }.value
            refreshInstalledPresets()
            downloadingPreset = nil
            return isInstalled(preset)
        } catch is CancellationError {
            downloadingPreset = nil
            return false
        } catch {
            Self.log.error("Anime4K download failed: \(error.localizedDescription, privacy: .public)")
            failedPreset = preset
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "Unable to prepare Anime4K shaders.")
            downloadingPreset = nil
            return false
        }
    }

    func statusText(for preset: VideoShaderPreset) -> String {
        if downloadingPreset == preset {
            if currentFileName.isEmpty {
                return String(localized: "Downloading verified Anime4K shaders…")
            }
            return String(
                format: String(localized: "Downloading %@ (%d/%d)"),
                currentFileName,
                completedFiles,
                totalFiles
            )
        }
        if failedPreset == preset, let errorMessage {
            return errorMessage
        }
        if preset == .off {
            return String(localized: "Anime4K is off.")
        }
        if isInstalled(preset) {
            return String(localized: "Verified Anime4K v4.0.1 shaders are ready.")
        }
        return String(localized: "This preset has not been downloaded yet.")
    }
}

struct VideoAnime4KPresetControl: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var manager = Anime4KShaderManager.shared
    @State private var requestedPreset: VideoShaderPreset?
    @State private var downloadTask: Task<Void, Never>?

    var minimumPickerWidth: CGFloat = 190
    var onActivate: ((VideoShaderPreset) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                NativeGlassMenuPicker(
                    selection: presetBinding,
                    values: VideoShaderPreset.allCases,
                    minWidth: minimumPickerWidth
                ) { preset in
                    Text(verbatim: preset.localizedTitle)
                }
                .disabled(manager.downloadingPreset != nil)

                if downloadTask != nil || manager.downloadingPreset != nil {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel("Downloading verified Anime4K shaders…")
                } else if selectedPreset != .off,
                          !manager.isInstalled(selectedPreset) {
                    Button {
                        downloadAndActivate(selectedPreset)
                    } label: {
                        Label("Download and Apply", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                }
            }

            Text(manager.statusText(for: selectedPreset))
                .font(.caption)
                .foregroundStyle(manager.failedPreset == selectedPreset ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)

        }
        .onAppear {
            manager.refreshInstalledPresets()
        }
    }

    private var selectedPreset: VideoShaderPreset {
        requestedPreset ?? userConfig.videoShaderPreset
    }

    private var presetBinding: Binding<VideoShaderPreset> {
        Binding(
            get: { selectedPreset },
            set: { preset in
                requestedPreset = preset
                if manager.isInstalled(preset) {
                    activate(preset)
                }
            }
        )
    }

    private func downloadAndActivate(_ preset: VideoShaderPreset) {
        guard downloadTask == nil else { return }
        requestedPreset = preset
        downloadTask = Task { @MainActor in
            let isAvailable = await manager.ensureAvailable(preset)
            guard !Task.isCancelled else {
                downloadTask = nil
                return
            }
            if isAvailable {
                activate(preset)
            }
            downloadTask = nil
        }
    }

    private func activate(_ preset: VideoShaderPreset) {
        requestedPreset = nil
        userConfig.videoShaderPreset = preset
        onActivate?(preset)
    }
}
