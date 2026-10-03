import Foundation

nonisolated enum RemoteVideoProvider: String, Codable, Hashable, Sendable {
    case youtube
    case jellyfin
    case emby
    case plex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .youtube: "YouTube"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .plex: "Plex"
        }
    }

    var isMediaServer: Bool {
        self != .youtube
    }
}

/// Server-side resume point; the player keeps whichever of it and the local
/// history entry was written last.
nonisolated struct RemoteVideoResumeHint: Equatable, Hashable, Sendable {
    let position: TimeInterval
    let updatedAt: Date
}

nonisolated enum VideoMediaIdentity: Codable, Equatable, Hashable, Sendable {
    case localFile(path: String)
    case remote(providerID: String, remoteID: String)

    var persistenceKey: String {
        switch self {
        case .localFile(let path):
            path
        case .remote(let providerID, let remoteID):
            "remote://\(providerID)/\(remoteID)"
        }
    }

    var localURL: URL? {
        guard case .localFile(let path) = self else { return nil }
        return URL(
            fileURLWithPath: path,
            isDirectory: false
        ).standardizedFileURL
    }
}

nonisolated struct RemoteVideoIdentity: Codable, Equatable, Hashable, Sendable {
    let providerID: String
    let remoteID: String
    let originalURL: URL
    let canonicalURL: URL?
    let title: String
    let thumbnailURL: URL?
    let duration: TimeInterval?

    init(
        providerID: String,
        remoteID: String,
        originalURL: URL,
        canonicalURL: URL?,
        title: String,
        thumbnailURL: URL?,
        duration: TimeInterval? = nil
    ) {
        self.providerID = providerID
        self.remoteID = remoteID
        self.originalURL = originalURL
        self.canonicalURL = canonicalURL
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.duration = duration
    }

    init(
        provider: RemoteVideoProvider,
        remoteID: String,
        originalURL: URL,
        canonicalURL: URL?,
        title: String,
        thumbnailURL: URL?,
        duration: TimeInterval? = nil
    ) {
        self.init(
            providerID: provider.id,
            remoteID: remoteID,
            originalURL: originalURL,
            canonicalURL: canonicalURL,
            title: title,
            thumbnailURL: thumbnailURL,
            duration: duration
        )
    }

    var provider: RemoteVideoProvider? {
        RemoteVideoProvider(rawValue: providerID)
    }

    var mediaIdentity: VideoMediaIdentity {
        .remote(providerID: providerID, remoteID: remoteID)
    }

    var stableLibraryID: String {
        mediaIdentity.persistenceKey
    }

    var isYouTube: Bool {
        YouTubeURLParser.isYouTubeURL(canonicalURL ?? originalURL)
    }

    var isMediaServer: Bool {
        provider?.isMediaServer == true
    }

    var supportsQualitySelection: Bool {
        isYouTube || isMediaServer
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case provider
        case remoteID
        case originalURL
        case canonicalURL
        case title
        case thumbnailURL
        case duration
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteID = try container.decode(String.self, forKey: .remoteID)
        originalURL = try container.decode(URL.self, forKey: .originalURL)
        canonicalURL = try container.decodeIfPresent(URL.self, forKey: .canonicalURL)
        title = try container.decode(String.self, forKey: .title)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)

        let decodedProviderID = try container.decodeIfPresent(String.self, forKey: .providerID)
            ?? container.decode(String.self, forKey: .provider)
        if decodedProviderID == "ytdlp",
           YouTubeURLParser.isYouTubeURL(canonicalURL ?? originalURL) {
            providerID = RemoteVideoProvider.youtube.id
        } else {
            providerID = decodedProviderID
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(remoteID, forKey: .remoteID)
        try container.encode(originalURL, forKey: .originalURL)
        try container.encodeIfPresent(canonicalURL, forKey: .canonicalURL)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try container.encodeIfPresent(duration, forKey: .duration)
    }
}

nonisolated struct RemoteVideoWindowOpenRequest: Equatable, Sendable {
    let identity: RemoteVideoIdentity
    let preferredSubtitleLanguages: [String]
    let forceRefresh: Bool
    let startsFromBeginning: Bool

    init(
        identity: RemoteVideoIdentity,
        preferredSubtitleLanguages: [String] = [],
        forceRefresh: Bool = false,
        startsFromBeginning: Bool = false
    ) {
        self.identity = identity
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
        self.forceRefresh = forceRefresh
        self.startsFromBeginning = startsFromBeginning
    }
}

nonisolated struct RemoteVideoStream: Equatable, Hashable, Sendable {
    let url: URL
    let formatID: String?
    let height: Int?
    let hasVideo: Bool
    let hasAudio: Bool
    let httpHeaders: [String: String]

    init(
        url: URL,
        formatID: String? = nil,
        height: Int? = nil,
        hasVideo: Bool,
        hasAudio: Bool,
        httpHeaders: [String: String] = [:]
    ) {
        self.url = url
        self.formatID = formatID
        self.height = height
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.httpHeaders = httpHeaders
    }
}

nonisolated struct RemoteVideoSubtitleSelectionIdentity: Codable, Equatable, Hashable, Sendable {
    let id: String
    let language: String
    let isAutomatic: Bool
}

nonisolated struct RemoteVideoSubtitleOption: Equatable, Hashable, Sendable {
    let id: String
    let language: String
    let name: String
    let url: URL
    let format: SubtitleFormat?
    let isAutomatic: Bool
    let httpHeaders: [String: String]
    /// Media servers extract embedded tracks on first request, which can take
    /// far longer than a static file download.
    var downloadTimeout: TimeInterval? = nil

    var selectionIdentity: RemoteVideoSubtitleSelectionIdentity {
        RemoteVideoSubtitleSelectionIdentity(
            id: id,
            language: language,
            isAutomatic: isAutomatic
        )
    }
}

nonisolated struct RemoteVideoQualityOption: Equatable, Hashable, Sendable {
    let id: String
    let height: Int
    let playbackStream: RemoteVideoStream
    let audioStream: RemoteVideoStream?
    /// Shown instead of "<height>p" when set.
    var label: String? = nil
}

nonisolated struct ResolvedRemoteVideoSource: Equatable, Hashable, Sendable {
    let identity: RemoteVideoIdentity
    let playbackStream: RemoteVideoStream
    let audioStream: RemoteVideoStream?
    let muxedFallbackStream: RemoteVideoStream?
    let miningStream: RemoteVideoStream?
    let subtitleOptions: [RemoteVideoSubtitleOption]
    let selectedSubtitleLanguage: String?
    let resolvedAt: Date
    let expiresAt: Date?
    let qualityOptions: [RemoteVideoQualityOption]
    /// Provider-owned values the player hands back unchanged, such as a media
    /// server's playback session ids.
    let providerContext: [String: String]
    let resumeHint: RemoteVideoResumeHint?

    init(
        identity: RemoteVideoIdentity,
        playbackStream: RemoteVideoStream,
        audioStream: RemoteVideoStream?,
        muxedFallbackStream: RemoteVideoStream? = nil,
        miningStream: RemoteVideoStream?,
        subtitleOptions: [RemoteVideoSubtitleOption],
        selectedSubtitleLanguage: String?,
        resolvedAt: Date,
        expiresAt: Date?,
        qualityOptions: [RemoteVideoQualityOption] = [],
        providerContext: [String: String] = [:],
        resumeHint: RemoteVideoResumeHint? = nil
    ) {
        self.identity = identity
        self.playbackStream = playbackStream
        self.audioStream = audioStream
        self.muxedFallbackStream = muxedFallbackStream
        self.miningStream = miningStream
        self.subtitleOptions = subtitleOptions
        self.selectedSubtitleLanguage = selectedSubtitleLanguage
        self.resolvedAt = resolvedAt
        self.expiresAt = expiresAt
        self.qualityOptions = qualityOptions
        self.providerContext = providerContext
        self.resumeHint = resumeHint
    }

    var httpHeaders: [String: String] {
        playbackStream.httpHeaders
    }

    func preferredSubtitle(
        preferredLanguages: [String] = [],
        fallbackLanguages: [String] = ["ja", "en"]
    ) -> RemoteVideoSubtitleOption? {
        let normalizedPreferences = (preferredLanguages + fallbackLanguages)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        for language in normalizedPreferences {
            let matches = subtitleOptions.filter {
                $0.language.lowercased() == language
                    || $0.language.lowercased().hasPrefix("\(language)-")
            }
            if let match = matches.first(where: { !$0.isAutomatic })
                ?? matches.first {
                return match
            }
        }
        return subtitleOptions.first(where: { !$0.isAutomatic })
            ?? subtitleOptions.first
    }

    func subtitleOption(
        matching identity: RemoteVideoSubtitleSelectionIdentity
    ) -> RemoteVideoSubtitleOption? {
        if let exactIDMatch = subtitleOptions.first(where: { $0.id == identity.id }) {
            return exactIDMatch
        }
        let normalizedLanguage = identity.language.lowercased()
        let languageMatches = subtitleOptions.filter {
            $0.language.lowercased() == normalizedLanguage
        }
        return languageMatches.first(where: { $0.isAutomatic == identity.isAutomatic })
            ?? languageMatches.first(where: { !$0.isAutomatic })
            ?? languageMatches.first
    }

    func preferredSubtitle(language: String) -> RemoteVideoSubtitleOption? {
        let normalizedLanguage = language.lowercased()
        let languageMatches = subtitleOptions.filter {
            $0.language.lowercased() == normalizedLanguage
        }
        return languageMatches.first(where: { !$0.isAutomatic })
            ?? languageMatches.first
    }

    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    func selectingQuality(id: String) -> ResolvedRemoteVideoSource? {
        guard let option = qualityOptions.first(where: { $0.id == id }) else {
            return nil
        }
        return applyingQuality(option)
    }

    func selectingQuality(height: Int) -> ResolvedRemoteVideoSource? {
        guard let option = qualityOptions.first(where: { $0.height == height }) else {
            return nil
        }
        return applyingQuality(option)
    }

    private func applyingQuality(
        _ option: RemoteVideoQualityOption
    ) -> ResolvedRemoteVideoSource {
        ResolvedRemoteVideoSource(
            identity: identity,
            playbackStream: option.playbackStream,
            audioStream: option.audioStream,
            muxedFallbackStream: muxedFallbackStream,
            miningStream: miningStream,
            subtitleOptions: subtitleOptions,
            selectedSubtitleLanguage: selectedSubtitleLanguage,
            resolvedAt: resolvedAt,
            expiresAt: expiresAt,
            qualityOptions: qualityOptions,
            providerContext: providerContext,
            resumeHint: resumeHint
        )
    }
}
