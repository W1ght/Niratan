import Foundation

/// `remoteID` of a media server item: "<account UUID>/<server item id>".
nonisolated struct MediaServerItemReference: Hashable, Sendable {
    let accountID: UUID
    let itemID: String

    init(accountID: UUID, itemID: String) {
        self.accountID = accountID
        self.itemID = itemID
    }

    init?(remoteID: String) {
        guard let slash = remoteID.firstIndex(of: "/"),
              let accountID = UUID(uuidString: String(remoteID[..<slash])) else {
            return nil
        }
        let itemID = String(remoteID[remoteID.index(after: slash)...])
        guard !itemID.isEmpty else { return nil }
        self.accountID = accountID
        self.itemID = itemID
    }

    var remoteID: String {
        "\(accountID.uuidString)/\(itemID)"
    }
}

/// Resolves media server items for the shared remote playback pipeline. Items
/// are addressed by identity, never by URL, so the Add Link sheet ignores it.
struct MediaServerRemoteVideoResolver: RemoteVideoResolving {
    let kind: MediaServerKind

    var provider: RemoteVideoProvider { kind.remoteProvider }

    static var all: [any RemoteVideoResolving] {
        MediaServerKind.allCases.map(MediaServerRemoteVideoResolver.init(kind:))
    }

    /// Hooks media servers into the remote pipeline. Called once at launch.
    @MainActor
    static func registerWithRemotePlayback() {
        RemoteVideoResolverRegistry.register(all)
        RemotePlaybackReporterCatalog.register { source in
            MediaServerPlaybackReporter(source: source)
        }
    }

    func canResolve(url: URL) -> Bool {
        false
    }

    func resolve(
        url: URL,
        preferredSubtitleLanguages: [String]
    ) async throws -> ResolvedRemoteVideoSource {
        throw RemoteVideoResolverError.unsupportedURL
    }

    func canResolve(identity: RemoteVideoIdentity) -> Bool {
        identity.providerID == provider.id
            && MediaServerItemReference(remoteID: identity.remoteID) != nil
    }

    func resolve(
        identity: RemoteVideoIdentity,
        preferredSubtitleLanguages: [String]
    ) async throws -> ResolvedRemoteVideoSource {
        guard let reference = MediaServerItemReference(remoteID: identity.remoteID) else {
            throw RemoteVideoResolverError.unsupportedURL
        }
        let client = try await MediaServerClientFactory.shared.client(accountID: reference.accountID)
        let playback = try await client.playback(itemID: reference.itemID)
        return Self.source(
            from: playback,
            client: client,
            preferredSubtitleLanguages: preferredSubtitleLanguages
        )
    }

    static func identity(
        for item: MediaServerItem,
        client: any MediaServerClient
    ) -> RemoteVideoIdentity {
        let account = client.account
        // Plex artwork needs the token in its URL; keep it out of the
        // persisted library catalog.
        let thumbnailURL = account.kind == .plex ? nil : (item.thumbnailURL ?? item.posterURL)
        return RemoteVideoIdentity(
            provider: account.kind.remoteProvider,
            remoteID: MediaServerItemReference(accountID: account.id, itemID: item.id).remoteID,
            originalURL: client.webURL(itemID: item.id),
            canonicalURL: nil,
            title: item.playbackTitle,
            thumbnailURL: thumbnailURL,
            duration: item.runtime
        )
    }

    static func source(
        from playback: MediaServerPlayback,
        client: any MediaServerClient,
        preferredSubtitleLanguages: [String]
    ) -> ResolvedRemoteVideoSource {
        let headers = playback.httpHeaders
        let original = RemoteVideoStream(
            url: playback.streamURL,
            formatID: "original",
            height: playback.videoHeight,
            hasVideo: true,
            hasAudio: true,
            httpHeaders: headers
        )
        var qualityOptions: [RemoteVideoQualityOption] = []
        if !playback.transcodeOptions.isEmpty {
            let originalLabel = playback.videoHeight.map {
                String(localized: "Original (\(String($0))p)")
            } ?? String(localized: "Original")
            qualityOptions.append(RemoteVideoQualityOption(
                id: "original",
                height: playback.videoHeight ?? 0,
                playbackStream: original,
                audioStream: nil,
                label: originalLabel
            ))
            for option in playback.transcodeOptions {
                qualityOptions.append(RemoteVideoQualityOption(
                    id: "transcode-\(option.preset.height)",
                    height: option.preset.height,
                    playbackStream: RemoteVideoStream(
                        url: option.url,
                        formatID: "transcode-\(option.preset.height)",
                        height: option.preset.height,
                        hasVideo: true,
                        hasAudio: true,
                        httpHeaders: headers
                    ),
                    audioStream: nil,
                    label: option.preset.label
                ))
            }
        }
        let subtitleOptions = playback.subtitles.map { subtitle in
            RemoteVideoSubtitleOption(
                id: subtitle.id,
                language: subtitle.language,
                name: subtitle.title,
                url: subtitle.url,
                format: subtitle.format,
                isAutomatic: false,
                httpHeaders: headers,
                downloadTimeout: 240
            )
        }
        let resumeHint: RemoteVideoResumeHint? = {
            guard let position = playback.item.playbackPosition, position >= 2 else { return nil }
            return RemoteVideoResumeHint(
                position: position,
                updatedAt: playback.item.lastPlayedAt ?? .distantPast
            )
        }()
        let now = Date()
        let draft = ResolvedRemoteVideoSource(
            identity: identity(for: playback.item, client: client),
            playbackStream: original,
            audioStream: nil,
            miningStream: original,
            subtitleOptions: subtitleOptions,
            selectedSubtitleLanguage: nil,
            resolvedAt: now,
            expiresAt: nil
        )
        return ResolvedRemoteVideoSource(
            identity: draft.identity,
            playbackStream: original,
            audioStream: nil,
            miningStream: original,
            subtitleOptions: subtitleOptions,
            selectedSubtitleLanguage: draft.preferredSubtitle(
                preferredLanguages: preferredSubtitleLanguages
            )?.language,
            resolvedAt: now,
            // Re-resolve on every open so the server's resume point and a new
            // playback session are picked up.
            expiresAt: now.addingTimeInterval(30),
            qualityOptions: qualityOptions,
            providerContext: playback.session.providerContext,
            resumeHint: resumeHint
        )
    }
}

/// Reports start, periodic progress, pause/resume and stop to the server.
@MainActor
final class MediaServerPlaybackReporter: RemotePlaybackReporting {
    private static let progressInterval: TimeInterval = 10
    /// Fushi skips reports before five seconds so a mis-click does not
    /// overwrite the server's resume point.
    private static let minimumReportedPosition: TimeInterval = 5

    private let session: MediaServerPlaybackSession
    private let isTranscoding: Bool
    private var hasStarted = false
    private var hasStopped = false
    private var lastIsPlaying: Bool?
    private var lastProgressAt: Date?
    private var lastPosition: TimeInterval = 0
    private var reportQueue: Task<Void, Never>?

    init?(source: ResolvedRemoteVideoSource) {
        guard source.identity.isMediaServer,
              let session = MediaServerPlaybackSession(providerContext: source.providerContext) else {
            return nil
        }
        self.session = session
        let path = source.playbackStream.url.path.lowercased()
        isTranscoding = path.hasSuffix(".m3u8")
    }

    func playbackDidUpdate(position: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard !hasStopped else { return }
        lastPosition = position
        if !hasStarted {
            guard isPlaying else { return }
            hasStarted = true
            lastIsPlaying = true
            lastProgressAt = Date()
            send(.started, position: position)
            return
        }
        let now = Date()
        if isPlaying != lastIsPlaying {
            lastIsPlaying = isPlaying
            lastProgressAt = now
            send(.progress(isPaused: !isPlaying), position: position)
        } else if isPlaying,
                  now.timeIntervalSince(lastProgressAt ?? .distantPast) >= Self.progressInterval {
            lastProgressAt = now
            send(.progress(isPaused: false), position: position)
        }
    }

    func playbackDidStop(position: TimeInterval, duration: TimeInterval) {
        guard hasStarted, !hasStopped else { return }
        hasStopped = true
        let reported = position > 0 ? position : lastPosition
        send(.stopped, position: reported)
    }

    /// Reports are serialized so a stop never overtakes the last progress.
    private func send(_ event: MediaServerPlaybackEvent, position: TimeInterval) {
        if case .progress = event, position < Self.minimumReportedPosition {
            return
        }
        let session = session
        let isTranscoding = isTranscoding
        let previous = reportQueue
        reportQueue = Task {
            await previous?.value
            do {
                let client = try await MediaServerClientFactory.shared.client(accountID: session.accountID)
                try await client.report(
                    event,
                    session: session,
                    position: position,
                    isTranscoding: isTranscoding
                )
            } catch {
                // Progress reporting is best effort; local history still has it.
            }
        }
    }
}
