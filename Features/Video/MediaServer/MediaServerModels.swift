import Foundation

/// Jellyfin and Emby share one MediaBrowser-style client; Plex has its own.
nonisolated enum MediaServerKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case jellyfin
    case emby
    case plex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .plex: "Plex"
        }
    }

    var systemImage: String {
        switch self {
        case .jellyfin, .emby: "server.rack"
        case .plex: "play.rectangle.on.rectangle"
        }
    }

    var remoteProvider: RemoteVideoProvider {
        switch self {
        case .jellyfin: .jellyfin
        case .emby: .emby
        case .plex: .plex
        }
    }

    init?(providerID: String) {
        self.init(rawValue: providerID)
    }
}

/// A signed-in server account. The access token is not part of this value; it
/// lives in `MediaServerCredentialStore` (Keychain) under `id`.
nonisolated struct MediaServerAccount: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: MediaServerKind
    var serverURL: URL
    var serverName: String
    /// Jellyfin/Emby `System/Info` Id or the Plex machine identifier.
    var serverID: String?
    var username: String
    /// Jellyfin/Emby user id. Plex keeps the plex.tv account name here.
    var userID: String
    /// Sent as the device/client identifier. Tokens are bound to it.
    var deviceID: String
    var addedAt: Date

    var displayName: String {
        serverName.isEmpty ? (serverURL.host() ?? serverURL.absoluteString) : serverName
    }

    var accountSummary: String {
        let host = serverURL.host() ?? serverURL.absoluteString
        return username.isEmpty ? host : "\(username) · \(host)"
    }
}

nonisolated struct MediaServerLibrary: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case movies
        case shows
        case mixed
    }

    let id: String
    let name: String
    let kind: Kind
    let imageURL: URL?
}

nonisolated struct MediaServerItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case movie
        case series
        case season
        case episode
        case video
        case folder
    }

    let id: String
    let kind: Kind
    let name: String
    var originalTitle: String? = nil
    var overview: String? = nil
    var year: Int? = nil
    var seriesID: String? = nil
    var seriesName: String? = nil
    var seasonID: String? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil
    var runtime: TimeInterval? = nil
    var playbackPosition: TimeInterval? = nil
    var lastPlayedAt: Date? = nil
    var isPlayed = false
    var childCount: Int? = nil
    var unplayedCount: Int? = nil
    /// Portrait artwork (movie/series poster, season poster).
    var posterURL: URL? = nil
    /// Landscape artwork (episode still, backdrop).
    var thumbnailURL: URL? = nil

    var isPlayable: Bool {
        switch kind {
        case .movie, .episode, .video: true
        case .series, .season, .folder: false
        }
    }

    var progress: Double? {
        guard let runtime, runtime > 0,
              let playbackPosition, playbackPosition > 0 else { return nil }
        return min(max(playbackPosition / runtime, 0), 1)
    }

    /// "S01E02", or `nil` outside a numbered season.
    var episodeCode: String? {
        guard kind == .episode, let episodeNumber else { return nil }
        if let seasonNumber {
            return String(format: "S%02dE%02d", seasonNumber, episodeNumber)
        }
        return String(format: "E%02d", episodeNumber)
    }

    /// Title used for the player window and the local video library.
    var playbackTitle: String {
        guard kind == .episode, let seriesName, !seriesName.isEmpty else { return name }
        if let episodeCode {
            return "\(seriesName) \(episodeCode) · \(name)"
        }
        return "\(seriesName) · \(name)"
    }
}

nonisolated struct MediaServerItemPage: Sendable {
    let items: [MediaServerItem]
    let totalCount: Int
    /// Next start offset, counted in rows the server returned rather than rows
    /// kept after filtering.
    let nextStart: Int

    var hasMore: Bool { nextStart < totalCount }
}

nonisolated enum MediaServerSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    case name
    case dateAdded
    case releaseDate
    case rating

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .name: "Name"
        case .dateAdded: "Date Added"
        case .releaseDate: "Release Date"
        case .rating: "Rating"
        }
    }
}

nonisolated struct MediaServerSubtitle: Hashable, Sendable {
    let id: String
    let language: String
    let title: String
    let url: URL
    let format: SubtitleFormat
}

/// Bandwidth tiers offered next to the original stream.
nonisolated struct MediaServerQualityPreset: Hashable, Sendable {
    let height: Int
    let width: Int
    let bitrate: Int

    static let all: [MediaServerQualityPreset] = [
        MediaServerQualityPreset(height: 1080, width: 1920, bitrate: 10_000_000),
        MediaServerQualityPreset(height: 720, width: 1280, bitrate: 4_000_000),
        MediaServerQualityPreset(height: 480, width: 854, bitrate: 1_500_000),
    ]

    var label: String {
        let megabits = Double(bitrate) / 1_000_000
        let rate = megabits.rounded() == megabits
            ? String(Int(megabits))
            : String(format: "%.1f", megabits)
        return "\(height)p · \(rate) Mbps"
    }
}

/// Everything the resolver needs to hand one item to the player.
nonisolated struct MediaServerPlayback: Sendable {
    let item: MediaServerItem
    let streamURL: URL
    let httpHeaders: [String: String]
    let videoHeight: Int?
    let subtitles: [MediaServerSubtitle]
    let session: MediaServerPlaybackSession
    /// Transcoded alternatives, highest first.
    let transcodeOptions: [(preset: MediaServerQualityPreset, url: URL)]
}

/// Server-side playback session ids, carried through
/// `ResolvedRemoteVideoSource.providerContext` to the progress reporter.
nonisolated struct MediaServerPlaybackSession: Hashable, Sendable {
    let accountID: UUID
    let itemID: String
    var mediaSourceID: String?
    var playSessionID: String?
    var playMethod: String
    var duration: TimeInterval?

    private enum Key {
        static let accountID = "mediaServer.accountID"
        static let itemID = "mediaServer.itemID"
        static let mediaSourceID = "mediaServer.mediaSourceID"
        static let playSessionID = "mediaServer.playSessionID"
        static let playMethod = "mediaServer.playMethod"
        static let duration = "mediaServer.duration"
    }

    var providerContext: [String: String] {
        var context = [
            Key.accountID: accountID.uuidString,
            Key.itemID: itemID,
            Key.playMethod: playMethod,
        ]
        context[Key.mediaSourceID] = mediaSourceID
        context[Key.playSessionID] = playSessionID
        context[Key.duration] = duration.map { String($0) }
        return context
    }

    init(
        accountID: UUID,
        itemID: String,
        mediaSourceID: String?,
        playSessionID: String?,
        playMethod: String,
        duration: TimeInterval?
    ) {
        self.accountID = accountID
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.playMethod = playMethod
        self.duration = duration
    }

    init?(providerContext: [String: String]) {
        guard let rawAccountID = providerContext[Key.accountID],
              let accountID = UUID(uuidString: rawAccountID),
              let itemID = providerContext[Key.itemID] else {
            return nil
        }
        self.init(
            accountID: accountID,
            itemID: itemID,
            mediaSourceID: providerContext[Key.mediaSourceID],
            playSessionID: providerContext[Key.playSessionID],
            playMethod: providerContext[Key.playMethod] ?? "DirectPlay",
            duration: providerContext[Key.duration].flatMap(TimeInterval.init)
        )
    }
}

nonisolated enum MediaServerPlaybackEvent: Hashable, Sendable {
    case started
    case progress(isPaused: Bool)
    case stopped
}

nonisolated enum MediaServerError: LocalizedError, Equatable, Sendable {
    case invalidServerURL
    case unreachable(String)
    case invalidCredentials
    case twoFactorRequired
    case sessionExpired
    case missingCredentials
    case accountNotFound
    case httpStatus(Int)
    case invalidResponse
    case notPlayable
    case plexServerNotFound
    case signInCancelled
    case signInTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            String(localized: "Enter a valid server address, such as http://192.168.1.10:8096.")
        case .unreachable(let reason):
            String(localized: "Unable to reach the server: \(reason)")
        case .invalidCredentials:
            String(localized: "The username or password is incorrect.")
        case .twoFactorRequired:
            String(localized: "This Plex account uses two-step verification. Sign in with the browser instead.")
        case .sessionExpired:
            String(localized: "The server rejected the saved sign-in. Sign in to this server again.")
        case .missingCredentials:
            String(localized: "The sign-in for this server is missing. Sign in to this server again.")
        case .accountNotFound:
            String(localized: "This media server is no longer signed in.")
        case .httpStatus(let status):
            String(localized: "The server returned HTTP \(status).")
        case .invalidResponse:
            String(localized: "The server returned an unexpected response.")
        case .notPlayable:
            String(localized: "This item has no playable video.")
        case .plexServerNotFound:
            String(localized: "No Plex Media Server was found for this account.")
        case .signInCancelled:
            String(localized: "Sign-in was cancelled.")
        case .signInTimedOut:
            String(localized: "Sign-in timed out. Try again.")
        }
    }
}

nonisolated enum MediaServerTicks {
    /// Jellyfin/Emby tick = 100 ns.
    static let perSecond: Double = 10_000_000

    static func seconds(_ ticks: Int64?) -> TimeInterval? {
        guard let ticks, ticks > 0 else { return nil }
        return Double(ticks) / perSecond
    }

    static func ticks(_ seconds: TimeInterval) -> Int64 {
        Int64((max(seconds, 0) * perSecond).rounded())
    }
}

nonisolated enum MediaServerURLNormalizer {
    /// Accepts "host:port", full-width punctuation and trailing slashes;
    /// defaults to http for bare hosts like Fushi does.
    static func normalize(_ raw: String, defaultPort: Int? = nil) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        text = text.replacingOccurrences(of: "。", with: ".")
        guard !text.isEmpty else { return nil }
        if text.range(of: "://") == nil {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        components.scheme = scheme
        if components.port == nil, let defaultPort, scheme == "http" {
            components.port = defaultPort
        }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
