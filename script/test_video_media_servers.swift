// test-sources: Features/Video/MediaServer/MediaServerModels.swift Features/Video/MediaServer/MediaServerClient.swift Features/Video/MediaServer/JellyfinMediaServerClient.swift Features/Video/MediaServer/PlexMediaServerClient.swift Features/Video/MediaServer/MediaServerAccountStore.swift Features/Video/MediaServer/MediaServerRemoteVideoResolver.swift Features/Video/Remote/RemoteVideoSource.swift Features/Video/Remote/RemoteVideoResolver.swift Features/Video/Remote/RemotePlaybackSession.swift Features/Video/Remote/YouTubeURLParser.swift Features/Video/Playback/PlaybackEngine.swift Features/Video/Playback/VideoTrack.swift Features/Video/Playback/VideoShaderPreset.swift Features/Video/Subtitles/SubtitleCueStore.swift Features/Video/VideoInspectorState.swift Features/Video/VideoPlaylist.swift Models/Subtitle.swift NativeMac/DevelopmentDataIsolation.swift
import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private struct StubClient: MediaServerClient {
    let account: MediaServerAccount

    func libraries() async throws -> [MediaServerLibrary] { [] }
    func items(parentID: String, sort: MediaServerSort, start: Int, limit: Int) async throws -> MediaServerItemPage {
        MediaServerItemPage(items: [], totalCount: 0, nextStart: 0)
    }
    func continueWatching(limit: Int) async throws -> [MediaServerItem] { [] }
    func latest(libraryID: String, limit: Int) async throws -> [MediaServerItem] { [] }
    func seasons(seriesID: String) async throws -> [MediaServerItem] { [] }
    func episodes(seriesID: String, seasonID: String?) async throws -> [MediaServerItem] { [] }
    func search(_ query: String, limit: Int) async throws -> [MediaServerItem] { [] }
    func item(id: String) async throws -> MediaServerItem { throw MediaServerError.notPlayable }
    func playback(itemID: String) async throws -> MediaServerPlayback { throw MediaServerError.notPlayable }
    func report(_ event: MediaServerPlaybackEvent, session: MediaServerPlaybackSession, position: TimeInterval, isTranscoding: Bool) async throws {}
    func setPlayed(_ played: Bool, itemID: String) async throws {}
    func webURL(itemID: String) -> URL { URL(string: "https://media.example/web/index.html#!/item?id=\(itemID)")! }
}

@main
private enum VideoMediaServerTests {
    @MainActor
    static func main() throws {
        testURLNormalization()
        testReferencesAndSessions()
        testJSONHelpers()
        testSearchMatch()
        testItemPresentation()
        testResolvedSource()
        testProviderRouting()
        print("PASS")
    }

    static func testURLNormalization() {
        expect(
            MediaServerURLNormalizer.normalize("192.168.1.10:8096")?.absoluteString,
            "http://192.168.1.10:8096",
            "bare host:port should default to http"
        )
        expect(
            MediaServerURLNormalizer.normalize("HTTPS://emby.example.com/emby/")?.absoluteString,
            "https://emby.example.com/emby",
            "scheme should be lowercased and trailing slashes trimmed"
        )
        expect(
            MediaServerURLNormalizer.normalize("http：//192。168。1。10：8096")?.absoluteString,
            "http://192.168.1.10:8096",
            "full-width punctuation from Chinese input methods should be folded"
        )
        expect(
            MediaServerURLNormalizer.normalize("192.168.1.10", defaultPort: 32400)?.absoluteString,
            "http://192.168.1.10:32400",
            "Plex addresses default to port 32400"
        )
        expect(
            MediaServerURLNormalizer.normalize("https://plex.example.com", defaultPort: 32400)?.absoluteString,
            "https://plex.example.com",
            "https addresses keep their implicit port"
        )
        expect(MediaServerURLNormalizer.normalize("ftp://example.com"), nil, "non-http schemes are rejected")
        expect(MediaServerURLNormalizer.normalize("  "), nil, "empty addresses are rejected")
    }

    static func testReferencesAndSessions() {
        let accountID = UUID()
        let reference = MediaServerItemReference(accountID: accountID, itemID: "e01KX3B83DP5")
        expect(
            MediaServerItemReference(remoteID: reference.remoteID),
            reference,
            "item references should round-trip through remoteID"
        )
        expect(MediaServerItemReference(remoteID: "not-a-uuid/1"), nil, "remoteID needs an account UUID")
        expect(MediaServerItemReference(remoteID: "\(accountID.uuidString)/"), nil, "remoteID needs an item id")

        let session = MediaServerPlaybackSession(
            accountID: accountID,
            itemID: "9",
            mediaSourceID: "mediasource_9",
            playSessionID: "abc",
            playMethod: "DirectStream",
            duration: 1435
        )
        expect(
            MediaServerPlaybackSession(providerContext: session.providerContext),
            session,
            "playback sessions should survive ResolvedRemoteVideoSource.providerContext"
        )
        expect(
            MediaServerPlaybackSession(providerContext: [:]),
            nil,
            "sources without media server context must not create a reporter session"
        )
        expect(MediaServerTicks.ticks(1.5), 15_000_000, "seconds convert to 100 ns ticks")
        expect(MediaServerTicks.seconds(600_230_000), 60.023, "ticks convert to seconds")
        expect(MediaServerTicks.seconds(0), nil, "zero ticks mean no position")
    }

    static func testJSONHelpers() {
        let object: [String: Any] = [
            "Date": "2026-10-02T21:02:29.1234567Z",
            "Number": "42",
            "Flag": NSNumber(value: true),
        ]
        expect(
            MediaServerJSON.date(object, "Date"),
            Date(timeIntervalSince1970: 1_790_974_949),
            ".NET dates with seven fractional digits should parse"
        )
        expect(MediaServerJSON.int(object, "Number"), 42, "numeric strings should parse")
        expect(MediaServerJSON.bool(object, "Flag"), true, "NSNumber booleans should parse")
        expect(MediaServerJSON.languageCode("jpn"), "ja", "ISO 639-2 Japanese maps to ja")
        expect(MediaServerJSON.languageCode("chi"), "zh", "bibliographic Chinese maps to zh")
        expect(MediaServerJSON.languageCode("eng"), "en", "ISO 639-2 English maps to en")
        expect(MediaServerJSON.languageCode(nil), "", "missing languages stay empty")
    }

    static func testSearchMatch() {
        let items = [
            MediaServerItem(id: "1", kind: .series, name: "怪形"),
            MediaServerItem(id: "2", kind: .series, name: "怪奇物语", originalTitle: "Stranger Things"),
            MediaServerItem(id: "3", kind: .movie, name: "怪奇物语：第五季幕后"),
            MediaServerItem(id: "4", kind: .series, name: "Ｓｔｒａｎｇｅｒ Ｓｔｏｒｉｅｓ"),
        ]
        expect(
            MediaServerSearchMatch.filter(items, query: "怪奇物语").map(\.id),
            ["2", "3"],
            "fuzzy server results without every query token should be dropped, exact first"
        )
        expect(
            MediaServerSearchMatch.filter(items, query: "stranger things").map(\.id),
            ["2"],
            "original titles should match case-insensitively"
        )
        expect(
            MediaServerSearchMatch.filter(items, query: "stranger").map(\.id),
            ["2", "4"],
            "full-width titles should match half-width queries"
        )
    }

    static func testItemPresentation() {
        let episode = MediaServerItem(
            id: "e1",
            kind: .episode,
            name: "欢迎来到成田家",
            seriesName: "我家的弟弟们真是让您费心了",
            seasonNumber: 1,
            episodeNumber: 3,
            runtime: 1_435,
            playbackPosition: 717.5
        )
        expect(episode.episodeCode, "S01E03", "episode codes are zero padded")
        expect(
            episode.playbackTitle,
            "我家的弟弟们真是让您费心了 S01E03 · 欢迎来到成田家",
            "episode playback titles carry the series and code"
        )
        expect(episode.progress, 0.5, "progress uses the server resume point")
        expect(MediaServerItem(id: "m", kind: .movie, name: "Movie").playbackTitle, "Movie", "movies keep their name")
        expect(MediaServerItem(id: "s", kind: .series, name: "Show").isPlayable, false, "series are containers")
        expect(MediaServerQualityPreset.all.map(\.label), ["1080p · 10 Mbps", "720p · 4 Mbps", "480p · 1.5 Mbps"], "quality labels")
    }

    @MainActor
    static func testResolvedSource() {
        let account = MediaServerAccount(
            id: UUID(),
            kind: .emby,
            serverURL: URL(string: "https://media.example")!,
            serverName: "UHD",
            serverID: "UHD",
            username: "user",
            userID: "u1",
            deviceID: "device",
            addedAt: Date()
        )
        let client = StubClient(account: account)
        let lastPlayed = Date(timeIntervalSince1970: 1_790_000_000)
        let item = MediaServerItem(
            id: "e01",
            kind: .episode,
            name: "第 1 集",
            seriesName: "Show",
            seasonNumber: 1,
            episodeNumber: 1,
            runtime: 1_435,
            playbackPosition: 600,
            lastPlayedAt: lastPlayed,
            thumbnailURL: URL(string: "https://media.example/Items/e01/Images/Primary?maxWidth=720")
        )
        let session = MediaServerPlaybackSession(
            accountID: account.id,
            itemID: item.id,
            mediaSourceID: "ms",
            playSessionID: "ps",
            playMethod: "DirectPlay",
            duration: 1_435
        )
        let playback = MediaServerPlayback(
            item: item,
            streamURL: URL(string: "https://media.example/Videos/e01/stream?static=true&api_key=secret")!,
            httpHeaders: ["User-Agent": "Niratan"],
            videoHeight: 1_080,
            subtitles: [
                MediaServerSubtitle(id: "ms-2", language: "zh", title: "中文", url: URL(string: "https://media.example/zh.srt")!, format: .srt),
                MediaServerSubtitle(id: "ms-3", language: "ja", title: "日本語", url: URL(string: "https://media.example/ja.srt")!, format: .srt),
            ],
            session: session,
            transcodeOptions: [
                (MediaServerQualityPreset.all[1], URL(string: "https://media.example/master.m3u8?h=720")!),
            ]
        )
        let source = MediaServerRemoteVideoResolver.source(
            from: playback,
            client: client,
            preferredSubtitleLanguages: []
        )
        expect(source.identity.providerID, "emby", "identity carries the server kind")
        expect(source.identity.isMediaServer, true, "media server identities are recognised")
        expect(source.identity.supportsQualitySelection, true, "media servers offer quality selection")
        expect(source.identity.title, "Show S01E01 · 第 1 集", "identity title")
        expect(source.identity.originalURL.absoluteString.contains("secret"), false, "persisted identity must not carry the token")
        expect(source.identity.thumbnailURL, item.thumbnailURL, "Jellyfin/Emby artwork is anonymous and can be persisted")
        expect(source.qualityOptions.map(\.id), ["original", "transcode-720"], "original stream comes first")
        expect(source.qualityOptions.first?.label, "Original (1080p)", "original label names its height")
        expect(source.selectingQuality(id: "transcode-720")?.playbackStream.url.absoluteString, "https://media.example/master.m3u8?h=720", "quality switch")
        expect(source.selectingQuality(id: "transcode-720")?.providerContext, source.providerContext, "quality switch keeps the session")
        expect(source.selectedSubtitleLanguage, "ja", "Japanese subtitles are preferred")
        expect(source.subtitleOptions.first?.downloadTimeout, 240, "server-side subtitle extraction gets a long timeout")
        expect(source.resumeHint, RemoteVideoResumeHint(position: 600, updatedAt: lastPlayed), "server resume point")
        expect(MediaServerPlaybackSession(providerContext: source.providerContext), session, "session context")

        var plexAccount = account
        plexAccount.kind = .plex
        let plexIdentity = MediaServerRemoteVideoResolver.identity(for: item, client: StubClient(account: plexAccount))
        expect(plexIdentity.thumbnailURL, nil, "Plex artwork needs the token and must not be persisted")
        expect(plexIdentity.providerID, "plex", "Plex identity")
    }

    @MainActor
    static func testProviderRouting() {
        let resolver = MediaServerRemoteVideoResolver(kind: .jellyfin)
        let identity = RemoteVideoIdentity(
            provider: .jellyfin,
            remoteID: MediaServerItemReference(accountID: UUID(), itemID: "abc").remoteID,
            originalURL: URL(string: "http://nas:8096/web/index.html#/details?id=abc")!,
            canonicalURL: nil,
            title: "Episode",
            thumbnailURL: nil
        )
        expect(resolver.canResolve(identity: identity), true, "media server resolver claims its identities")
        expect(resolver.canResolve(url: identity.originalURL), false, "media server items are never resolved from a pasted URL")
        expect(MediaServerRemoteVideoResolver(kind: .emby).canResolve(identity: identity), false, "kinds do not cross")
        let youtube = RemoteVideoIdentity(
            provider: .youtube,
            remoteID: "yrL6Qny0E5M",
            originalURL: URL(string: "https://www.youtube.com/watch?v=yrL6Qny0E5M")!,
            canonicalURL: nil,
            title: "Video",
            thumbnailURL: nil
        )
        expect(resolver.canResolve(identity: youtube), false, "YouTube identities stay with YouTube")
        expect(youtube.isMediaServer, false, "YouTube is not a media server")
        expect(RemoteVideoProvider(rawValue: "emby")?.displayName, "Emby", "provider raw values")

        let encoded = try? JSONEncoder().encode(identity)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(RemoteVideoIdentity.self, from: $0) }
        expect(decoded, identity, "media server identities persist in the library catalog")
    }
}
