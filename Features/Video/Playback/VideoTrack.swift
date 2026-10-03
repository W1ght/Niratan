import Foundation

// Track and subtitle-renderer value types shared by the engine, the player
// UI and tests. Kept free of app dependencies so they compile on their own.

nonisolated enum VideoTrackType: String, Codable, CaseIterable, Hashable, Sendable {
    case video
    case audio
    case subtitle
}

nonisolated struct VideoTrack: Identifiable, Equatable, Hashable, Sendable {
    let id: Int
    let type: VideoTrackType
    let title: String
    let language: String?
    let codec: String?
    let ffIndex: Int?
    let externalFilename: String?
    let isImage: Bool
    let isSelected: Bool

    var displayName: String {
        if let language, !language.isEmpty {
            return "\(title) · \(language)"
        }
        return title
    }
}

nonisolated struct VideoEmbeddedSubtitleCue: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

nonisolated enum VideoSubtitleRenderingMode: Equatable, Sendable {
    case overlayOnly
    case preparingASS
    case nativeOnly
    case splitASS(effectsURL: URL, logicalTrackID: Int?)

    var usesInteractiveOverlay: Bool {
        switch self {
        case .overlayOnly, .splitASS:
            true
        case .preparingASS, .nativeOnly:
            false
        }
    }

    var usesNativeRenderer: Bool {
        switch self {
        case .nativeOnly, .splitASS:
            true
        case .overlayOnly, .preparingASS:
            false
        }
    }
}

nonisolated enum VideoSubtitleRenderingPolicy {
    static func usesNativeRenderer(for track: VideoTrack) -> Bool {
        guard track.type == .subtitle else { return false }
        if track.isImage { return true }
        guard let codec = track.codec?.lowercased() else { return false }
        return codec == "ass" || codec == "ssa"
    }

    static func usesNativeRenderer(forSubtitleURL url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return fileExtension == "ass" || fileExtension == "ssa"
    }

    static func initialMode(for track: VideoTrack) -> VideoSubtitleRenderingMode {
        guard track.type == .subtitle else { return .overlayOnly }
        if track.isImage { return .nativeOnly }
        guard let codec = track.codec?.lowercased() else { return .overlayOnly }
        return codec == "ass" || codec == "ssa" ? .preparingASS : .overlayOnly
    }

    static func initialMode(forSubtitleURL url: URL) -> VideoSubtitleRenderingMode {
        usesNativeRenderer(forSubtitleURL: url) ? .preparingASS : .overlayOnly
    }
}

/// Chooses the embedded subtitle track to enable on a first open, when no
/// selection was remembered and no sidecar file matched: the learner's target
/// language (Japanese), preferring full dialogue over signs/songs/forced tracks
/// and text over image subtitles. Returns `nil` to leave subtitles off.
nonisolated enum VideoEmbeddedSubtitleDefault {
    static func preferredTrack(in tracks: [VideoTrack]) -> VideoTrack? {
        tracks
            .filter { $0.type == .subtitle && $0.externalFilename == nil && isJapanese($0) }
            .min { rank($0) < rank($1) }
    }

    static func isJapanese(_ track: VideoTrack) -> Bool {
        if let language = track.language?.lowercased(),
           ["ja", "jp", "jpn", "japanese"].contains(language) || language.hasPrefix("ja-") {
            return true
        }
        let title = track.title.lowercased()
        return title.contains("日本語") || title.contains("japanese")
    }

    private static func rank(_ track: VideoTrack) -> Int {
        let title = track.title.lowercased()
        let isPartial = ["sign", "song", "forced", "看板", "歌詞"].contains { title.contains($0) }
        return (isPartial ? 2 : 0) + (track.isImage ? 1 : 0)
    }
}

nonisolated enum VideoSubtitleTrackMatching {
    /// The mpv track that already represents the subtitle file named `fileName`,
    /// so the inspector lists that file once. `nil` while the file has no track
    /// yet (for example a catalog download still loading).
    static func trackID(forFileNamed fileName: String?, in tracks: [VideoTrack]) -> Int? {
        guard let fileName else { return nil }
        return tracks.first { track in
            guard track.type == .subtitle, let filename = track.externalFilename else { return false }
            return URL(fileURLWithPath: filename).lastPathComponent == fileName
        }?.id
    }
}
