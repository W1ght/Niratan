import Foundation

nonisolated enum RemoteSubtitleLoaderError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case invalidResponse
    case untrustedDownloadURL
    case responseTooLarge
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            String(localized: "This remote subtitle format is not supported.")
        case .invalidResponse:
            String(localized: "The remote subtitle response is invalid.")
        case .untrustedDownloadURL:
            String(localized: "The remote subtitle download redirected to an untrusted server.")
        case .responseTooLarge:
            String(localized: "The remote subtitle file is too large.")
        case .httpStatus:
            String(localized: "Unable to download the remote subtitle.")
        }
    }
}

@MainActor
final class RemoteSubtitleLoader {
    private let session: URLSession
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    private var activeGeneration = 0
    private var activeTask: Task<(Data, URLResponse), any Error>?
    private var temporaryURLs: Set<URL> = []
    private(set) var installedURL: URL?

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-remote-subtitles", isDirectory: true)
    ) {
        self.session = session
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func load(
        option: RemoteVideoSubtitleOption,
        headers: [String: String] = [:],
        allowedDownloadHosts: Set<String>? = nil,
        maximumResponseSize: Int = 64 * 1_024 * 1_024,
        generation: Int
    ) async throws -> URL? {
        activeGeneration = generation
        activeTask?.cancel()

        let pathExtension = try subtitlePathExtension(for: option)
        if let allowedDownloadHosts,
           !Self.isTrustedDownloadURL(option.url, allowedHosts: allowedDownloadHosts) {
            throw RemoteSubtitleLoaderError.untrustedDownloadURL
        }
        var request = URLRequest(url: option.url)
        request.timeoutInterval = option.downloadTimeout ?? 30
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in option.httpHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let task = Task {
            try await BoundedURLSessionData.load(
                session: session,
                request: request,
                maximumSize: maximumResponseSize
            ) { response in
                guard let response = response as? HTTPURLResponse else {
                    throw RemoteSubtitleLoaderError.invalidResponse
                }
                if let allowedDownloadHosts,
                   !Self.isTrustedDownloadURL(response.url, allowedHosts: allowedDownloadHosts) {
                    throw RemoteSubtitleLoaderError.untrustedDownloadURL
                }
                guard (200...299).contains(response.statusCode) else {
                    throw RemoteSubtitleLoaderError.httpStatus(response.statusCode)
                }
            }
        }
        activeTask = task
        let payload: (Data, URLResponse)
        do {
            payload = try await task.value
        } catch {
            if generation != activeGeneration
                || Task.isCancelled
                || error is CancellationError
                || (error as? URLError)?.code == .cancelled {
                return nil
            }
            if error as? BoundedURLSessionDataError == .responseTooLarge {
                throw RemoteSubtitleLoaderError.responseTooLarge
            }
            throw error
        }
        guard generation == activeGeneration, !Task.isCancelled else { return nil }

        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = temporaryDirectory
            .appendingPathComponent("subtitle-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        try payload.0.write(to: outputURL, options: .atomic)
        temporaryURLs.insert(outputURL)
        guard generation == activeGeneration, !Task.isCancelled else {
            removeTemporaryFile(outputURL)
            return nil
        }

        if let installedURL, installedURL != outputURL {
            removeTemporaryFile(installedURL)
        }
        installedURL = outputURL
        if activeGeneration == generation {
            activeTask = nil
        }
        return outputURL
    }

    func cancelAndCleanup() {
        activeGeneration &+= 1
        activeTask?.cancel()
        activeTask = nil
        for url in temporaryURLs {
            try? fileManager.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        installedURL = nil
    }

    private func subtitlePathExtension(
        for option: RemoteVideoSubtitleOption
    ) throws -> String {
        switch option.format {
        case .webVTT:
            return "vtt"
        case .srt:
            return "srt"
        case .ass:
            return "ass"
        case .ssa:
            return "ssa"
        case .none:
            let pathExtension = option.url.pathExtension.lowercased()
            guard ["vtt", "srt", "ass", "ssa"].contains(pathExtension) else {
                throw RemoteSubtitleLoaderError.unsupportedFormat
            }
            return pathExtension
        case .embedded:
            throw RemoteSubtitleLoaderError.unsupportedFormat
        }
    }

    private func removeTemporaryFile(_ url: URL) {
        try? fileManager.removeItem(at: url)
        temporaryURLs.remove(url)
        if installedURL == url {
            installedURL = nil
        }
    }

    nonisolated private static func isTrustedDownloadURL(
        _ url: URL?,
        allowedHosts: Set<String>
    ) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased() else {
            return false
        }
        return allowedHosts.contains(host)
    }
}
