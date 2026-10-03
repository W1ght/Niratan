import Foundation

/// Jellyfin and Emby speak the same MediaBrowser API. Differences are absorbed
/// the way Fushi does: both auth headers on every request, single-value
/// `IncludeItemTypes`, `Fields` named explicitly, and fallbacks for compatible
/// servers that lack optional endpoints.
nonisolated struct JellyfinMediaServerClient: MediaServerClient {
    let account: MediaServerAccount
    private let token: String

    init(account: MediaServerAccount, token: String) {
        self.account = account
        self.token = token
    }

    /// Jellyfin 10.11+ only accepts `ApiKey`; Emby and its compatible
    /// servers only `api_key`.
    private var tokenQueryName: String {
        account.kind == .jellyfin ? "ApiKey" : "api_key"
    }

    private static let listFields = "ChildCount,RecursiveItemCount,ProductionYear,OriginalTitle,PrimaryImageAspectRatio"
    private static let episodeFields = "Overview,ProductionYear"
    private static let posterWidth = 400
    private static let thumbnailWidth = 720

    // MARK: Sign-in

    nonisolated struct ServerInfo: Sendable {
        let baseURL: URL
        let kind: MediaServerKind
        let name: String
        let id: String?
    }

    /// `/System/Info/Public` needs no auth. Emby installs served under `/emby`
    /// are found by retrying with that prefix.
    static func probe(_ rawURL: String) async throws -> ServerInfo {
        guard let baseURL = MediaServerURLNormalizer.normalize(rawURL) else {
            throw MediaServerError.invalidServerURL
        }
        var candidates = [baseURL]
        if !baseURL.path.lowercased().hasSuffix("/emby") {
            candidates.append(baseURL.appendingPathComponent("emby"))
        }
        var firstError: (any Error)?
        for candidate in candidates {
            do {
                var request = URLRequest(url: candidate.appendingPathComponent("System/Info/Public"))
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let info = try await MediaServerHTTP.jsonObject(request)
                guard MediaServerJSON.string(info, "Id") != nil
                        || MediaServerJSON.string(info, "ServerName") != nil else {
                    throw MediaServerError.invalidResponse
                }
                let product = MediaServerJSON.string(info, "ProductName") ?? ""
                return ServerInfo(
                    baseURL: candidate,
                    kind: product.localizedCaseInsensitiveContains("jellyfin") ? .jellyfin : .emby,
                    name: MediaServerJSON.string(info, "ServerName") ?? "",
                    id: MediaServerJSON.string(info, "Id")
                )
            } catch {
                if case MediaServerError.unreachable = error {
                    throw error
                }
                firstError = firstError ?? error
            }
        }
        throw firstError ?? MediaServerError.invalidResponse
    }

    static func signIn(
        rawURL: String,
        username: String,
        password: String
    ) async throws -> (account: MediaServerAccount, token: String) {
        let server = try await probe(rawURL)
        let deviceID = MediaServerHTTP.newDeviceID()
        var request = URLRequest(url: server.baseURL.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        applyHeaders(to: &request, deviceID: deviceID, token: nil)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "Username": username,
            "Pw": password,
        ])
        let response = try await MediaServerHTTP.jsonObject(
            request,
            unauthorizedError: .invalidCredentials
        )
        guard let token = MediaServerJSON.string(response, "AccessToken"),
              let user = response["User"] as? [String: Any],
              let userID = MediaServerJSON.string(user, "Id") else {
            throw MediaServerError.invalidResponse
        }
        // Emby 4.9 only reports ServerName under User.
        let serverName = MediaServerJSON.string(response, "ServerName")
            ?? MediaServerJSON.string(user, "ServerName")
            ?? server.name
        let account = MediaServerAccount(
            id: UUID(),
            kind: server.kind,
            serverURL: server.baseURL,
            serverName: serverName,
            serverID: MediaServerJSON.string(response, "ServerId") ?? server.id,
            username: MediaServerJSON.string(user, "Name") ?? username,
            userID: userID,
            deviceID: deviceID,
            addedAt: Date()
        )
        return (account, token)
    }

    /// Signs in with an existing user access token.
    static func signIn(
        rawURL: String,
        accessToken: String
    ) async throws -> (account: MediaServerAccount, token: String) {
        let server = try await probe(rawURL)
        let deviceID = MediaServerHTTP.newDeviceID()
        var request = URLRequest(url: server.baseURL.appendingPathComponent("Users/Me"))
        applyHeaders(to: &request, deviceID: deviceID, token: accessToken)
        let user = try await MediaServerHTTP.jsonObject(request, unauthorizedError: .invalidCredentials)
        guard let userID = MediaServerJSON.string(user, "Id") else {
            throw MediaServerError.invalidResponse
        }
        let account = MediaServerAccount(
            id: UUID(),
            kind: server.kind,
            serverURL: server.baseURL,
            serverName: MediaServerJSON.string(user, "ServerName") ?? server.name,
            serverID: server.id,
            username: MediaServerJSON.string(user, "Name") ?? "",
            userID: userID,
            deviceID: deviceID,
            addedAt: Date()
        )
        return (account, accessToken)
    }

    // MARK: Browsing

    func libraries() async throws -> [MediaServerLibrary] {
        let response = try await getObject("Users/\(account.userID)/Views")
        let allowed: Set<String> = ["movies", "tvshows", "homevideos", "musicvideos", "mixed", "boxsets"]
        return MediaServerJSON.objects(response, "Items").compactMap { view in
            guard let id = MediaServerJSON.string(view, "Id") else { return nil }
            let collectionType = MediaServerJSON.string(view, "CollectionType")?.lowercased()
            if let collectionType, !allowed.contains(collectionType) {
                return nil
            }
            let kind: MediaServerLibrary.Kind = switch collectionType {
            case "movies": .movies
            case "tvshows": .shows
            default: .mixed
            }
            let hasImage = (view["ImageTags"] as? [String: Any])?["Primary"] != nil
            return MediaServerLibrary(
                id: id,
                name: MediaServerJSON.string(view, "Name") ?? "",
                kind: kind,
                imageURL: hasImage ? imageURL(itemID: id, type: "Primary", maxWidth: Self.thumbnailWidth) : nil
            )
        }
    }

    func items(
        parentID: String,
        sort: MediaServerSort,
        start: Int,
        limit: Int
    ) async throws -> MediaServerItemPage {
        let (sortBy, sortOrder) = switch sort {
        case .name: ("SortName", "Ascending")
        case .dateAdded: ("DateCreated,SortName", "Descending")
        case .releaseDate: ("PremiereDate,ProductionYear,SortName", "Descending")
        case .rating: ("CommunityRating,SortName", "Descending")
        }
        let response = try await getObject("Users/\(account.userID)/Items", query: [
            "ParentId": parentID,
            "StartIndex": String(start),
            "Limit": String(limit),
            "Fields": Self.listFields,
            "SortBy": sortBy,
            "SortOrder": sortOrder,
            "EnableImageTypes": "Primary,Backdrop,Thumb",
        ])
        let rows = MediaServerJSON.objects(response, "Items")
        let total = MediaServerJSON.int(response, "TotalRecordCount") ?? (start + rows.count)
        return MediaServerItemPage(
            items: rows.compactMap(parseItem),
            totalCount: total,
            nextStart: rows.isEmpty ? total : start + rows.count
        )
    }

    func continueWatching(limit: Int) async throws -> [MediaServerItem] {
        let resume = try await getObject("Users/\(account.userID)/Items/Resume", query: [
            "Limit": String(limit),
            "MediaTypes": "Video",
            "Fields": Self.listFields,
        ])
        var items = MediaServerJSON.objects(resume, "Items").compactMap(parseItem)
        // Next Up is optional on compatible servers.
        if let nextUp = try? await getObject("Shows/NextUp", query: [
            "UserId": account.userID,
            "Limit": String(limit),
            "Fields": Self.listFields,
        ]) {
            let seen = Set(items.map(\.id))
            items += MediaServerJSON.objects(nextUp, "Items").compactMap(parseItem)
                .filter { !seen.contains($0.id) }
        }
        return Array(items.filter(\.isPlayable).prefix(limit))
    }

    func latest(libraryID: String, limit: Int) async throws -> [MediaServerItem] {
        let response = try await get("Users/\(account.userID)/Items/Latest", query: [
            "ParentId": libraryID,
            "Limit": String(limit),
            "Fields": Self.listFields,
        ])
        // Bare array on Jellyfin/Emby, `{Items}` on some compatible servers.
        let rows = (response as? [[String: Any]])
            ?? (response as? [String: Any]).map { MediaServerJSON.objects($0, "Items") }
            ?? []
        return rows.compactMap(parseItem)
    }

    func seasons(seriesID: String) async throws -> [MediaServerItem] {
        if let response = try? await getObject("Shows/\(seriesID)/Seasons", query: [
            "UserId": account.userID,
            "Fields": "ChildCount",
        ]) {
            return MediaServerJSON.objects(response, "Items").compactMap(parseItem)
        }
        let response = try await getObject("Users/\(account.userID)/Items", query: [
            "ParentId": seriesID,
            "IncludeItemTypes": "Season",
            "Fields": "ChildCount",
            "SortBy": "SortName",
        ])
        return MediaServerJSON.objects(response, "Items").compactMap(parseItem)
    }

    func episodes(seriesID: String, seasonID: String?) async throws -> [MediaServerItem] {
        var query = [
            "UserId": account.userID,
            "Fields": Self.episodeFields,
        ]
        query["SeasonId"] = seasonID
        if let response = try? await getObject("Shows/\(seriesID)/Episodes", query: query) {
            return MediaServerJSON.objects(response, "Items").compactMap(parseItem)
        }
        let response = try await getObject("Users/\(account.userID)/Items", query: [
            "ParentId": seasonID ?? seriesID,
            "Recursive": "true",
            "IncludeItemTypes": "Episode",
            "Fields": Self.episodeFields,
        ])
        return MediaServerJSON.objects(response, "Items").compactMap(parseItem).sorted {
            ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
        }
    }

    func search(_ query: String, limit: Int) async throws -> [MediaServerItem] {
        var results: [MediaServerItem] = []
        // One type per request: some compatible servers return nothing for a
        // comma-separated IncludeItemTypes.
        for type in ["Series", "Movie"] {
            let response = try await getObject("Users/\(account.userID)/Items", query: [
                "SearchTerm": query,
                "IncludeItemTypes": type,
                "Recursive": "true",
                "Limit": "100",
                "Fields": "ProductionYear,OriginalTitle",
            ])
            results += MediaServerJSON.objects(response, "Items").compactMap(parseItem)
        }
        return Array(MediaServerSearchMatch.filter(results, query: query).prefix(limit))
    }

    func item(id: String) async throws -> MediaServerItem {
        guard let item = parseItem(try await getObject("Users/\(account.userID)/Items/\(id)")) else {
            throw MediaServerError.notPlayable
        }
        return item
    }

    // MARK: Playback

    func playback(itemID: String) async throws -> MediaServerPlayback {
        let detail = try await getObject("Users/\(account.userID)/Items/\(itemID)")
        guard let item = parseItem(detail), item.isPlayable else {
            throw MediaServerError.notPlayable
        }
        let detailSources = MediaServerJSON.objects(detail, "MediaSources")
        let preferredSourceID = detailSources.first.flatMap { MediaServerJSON.string($0, "Id") }

        var playSessionID: String?
        var source = detailSources.first
        var streamURL: URL?
        var playMethod = "DirectPlay"
        if let info = try? await playbackInfo(itemID: itemID, mediaSourceID: preferredSourceID),
           MediaServerJSON.string(info, "ErrorCode") == nil {
            playSessionID = MediaServerJSON.string(info, "PlaySessionId")
            let sources = MediaServerJSON.objects(info, "MediaSources")
            if let negotiated = sources.first(where: { MediaServerJSON.string($0, "Id") == preferredSourceID })
                ?? sources.first {
                source = negotiated
                let canDirect = MediaServerJSON.bool(negotiated, "SupportsDirectPlay") == true
                    || MediaServerJSON.bool(negotiated, "SupportsDirectStream") == true
                if !canDirect, let transcodingURL = MediaServerJSON.string(negotiated, "TranscodingUrl") {
                    streamURL = absoluteURL(transcodingURL)
                    playMethod = "Transcode"
                } else if MediaServerJSON.bool(negotiated, "SupportsDirectPlay") != true {
                    playMethod = "DirectStream"
                }
            }
        }
        // Emby 4.10 rejects session reports without a PlaySessionId; it
        // accepts a client-generated one, as Emby for Kodi does.
        let sessionID = playSessionID ?? MediaServerHTTP.newDeviceID()
        let mediaSourceID = source.flatMap { MediaServerJSON.string($0, "Id") } ?? itemID
        if streamURL == nil {
            streamURL = directStreamURL(itemID: itemID, mediaSourceID: mediaSourceID, playSessionID: sessionID)
        }
        guard let streamURL else { throw MediaServerError.notPlayable }

        let streams = source.map { MediaServerJSON.objects($0, "MediaStreams") } ?? []
        let videoHeight = streams.first { MediaServerJSON.string($0, "Type") == "Video" }
            .flatMap { MediaServerJSON.int($0, "Height") }
        let subtitles = streams.compactMap {
            subtitle(from: $0, itemID: itemID, mediaSourceID: mediaSourceID)
        }
        let duration = source.flatMap { MediaServerTicks.seconds(MediaServerJSON.int64($0, "RunTimeTicks")) }
            ?? item.runtime
        // Compatible servers such as UHD Media Server answer master.m3u8 with
        // the original file; only offer tiers the server says it can make.
        let supportsTranscoding = source.flatMap { MediaServerJSON.bool($0, "SupportsTranscoding") } ?? false
        let transcodeOptions = playMethod == "Transcode" || !supportsTranscoding ? [] : MediaServerQualityPreset.all
            .filter { $0.height < (videoHeight ?? Int.max) }
            .map { preset in
                (preset, transcodeURL(
                    itemID: itemID,
                    mediaSourceID: mediaSourceID,
                    playSessionID: sessionID,
                    preset: preset
                ))
            }
        return MediaServerPlayback(
            item: item,
            streamURL: streamURL,
            httpHeaders: ["User-Agent": MediaServerHTTP.userAgent],
            videoHeight: videoHeight,
            subtitles: subtitles,
            session: MediaServerPlaybackSession(
                accountID: account.id,
                itemID: itemID,
                mediaSourceID: mediaSourceID,
                playSessionID: sessionID,
                playMethod: playMethod,
                duration: duration
            ),
            transcodeOptions: transcodeOptions
        )
    }

    private func playbackInfo(itemID: String, mediaSourceID: String?) async throws -> [String: Any] {
        var body: [String: Any] = [
            "UserId": account.userID,
            "StartTimeTicks": 0,
            "AutoOpenLiveStream": true,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": true,
            "AllowAudioStreamCopy": true,
            "IsPlayback": true,
            "DeviceProfile": Self.deviceProfile,
        ]
        body["MediaSourceId"] = mediaSourceID
        return try await postObject(
            "Items/\(itemID)/PlaybackInfo",
            query: ["UserId": account.userID],
            body: body
        )
    }

    /// libmpv plays any container/codec, so direct play is unrestricted.
    private static var deviceProfile: [String: Any] {
        [
            "Name": MediaServerHTTP.clientName,
            "MaxStreamingBitrate": 120_000_000,
            "MaxStaticBitrate": 120_000_000,
            "MusicStreamingTranscodingBitrate": 192_000,
            "DirectPlayProfiles": [
                ["Type": "Video"],
                ["Type": "Audio"],
            ],
            "TranscodingProfiles": [
                [
                    "Type": "Video",
                    "Container": "ts",
                    "Protocol": "hls",
                    "VideoCodec": "h264",
                    "AudioCodec": "aac,mp3,ac3",
                    "Context": "Streaming",
                    "MaxAudioChannels": "6",
                    "MinSegments": 1,
                    "BreakOnNonKeyFrames": true,
                ],
            ],
            "SubtitleProfiles": ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"].map {
                ["Format": $0, "Method": "External"]
            } + ["pgssub", "pgs", "dvdsub"].map {
                ["Format": $0, "Method": "Encode"]
            },
            ]
    }

    private func directStreamURL(itemID: String, mediaSourceID: String, playSessionID: String) -> URL? {
        url("Videos/\(itemID)/stream", query: [
            "static": "true",
            "MediaSourceId": mediaSourceID,
            "PlaySessionId": playSessionID,
            "DeviceId": account.deviceID,
            tokenQueryName: token,
        ])
    }

    private func transcodeURL(
        itemID: String,
        mediaSourceID: String,
        playSessionID: String,
        preset: MediaServerQualityPreset
    ) -> URL {
        url("Videos/\(itemID)/master.m3u8", query: [
            "MediaSourceId": mediaSourceID,
            "PlaySessionId": playSessionID,
            "DeviceId": account.deviceID,
            tokenQueryName: token,
            "VideoCodec": "h264",
            "AudioCodec": "aac,mp3",
            "VideoBitrate": String(preset.bitrate - 192_000),
            "AudioBitrate": "192000",
            "MaxWidth": String(preset.width),
            "MaxHeight": String(preset.height),
            "TranscodingMaxAudioChannels": "2",
            "SegmentContainer": "ts",
            "MinSegments": "1",
            "BreakOnNonKeyFrames": "True",
        ]) ?? account.serverURL
    }

    private func subtitle(
        from stream: [String: Any],
        itemID: String,
        mediaSourceID: String
    ) -> MediaServerSubtitle? {
        guard MediaServerJSON.string(stream, "Type") == "Subtitle",
              MediaServerJSON.bool(stream, "IsTextSubtitleStream") == true,
              let index = MediaServerJSON.int(stream, "Index") else {
            return nil
        }
        // Compatible servers (e.g. UHD Media Server) report embedded tracks
        // they cannot extract; those stay with mpv's own track list.
        let isExternal = MediaServerJSON.bool(stream, "IsExternal") == true
        guard isExternal || MediaServerJSON.bool(stream, "SupportsExternalStream") != false else {
            return nil
        }
        let codec = MediaServerJSON.string(stream, "Codec")?.lowercased() ?? ""
        let (format, pathExtension): (SubtitleFormat, String) = switch codec {
        case "srt", "subrip": (.srt, "srt")
        case "ass": (.ass, "ass")
        case "ssa": (.ssa, "ssa")
        default: (.webVTT, "vtt")
        }
        let deliveryURL = MediaServerJSON.string(stream, "DeliveryUrl").flatMap { path -> URL? in
            guard path.contains("/Subtitles/") else { return nil }
            return absoluteURL(path)
        }
        guard let subtitleURL = deliveryURL ?? url(
            "Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(index)/Stream.\(pathExtension)",
            query: [tokenQueryName: token]
        ) else {
            return nil
        }
        let language = MediaServerJSON.languageCode(MediaServerJSON.string(stream, "Language"))
        let title = MediaServerJSON.string(stream, "DisplayTitle")
            ?? MediaServerJSON.string(stream, "Title")
            ?? language
        return MediaServerSubtitle(
            id: "\(mediaSourceID)-\(index)",
            language: language,
            title: title,
            url: subtitleURL,
            format: format
        )
    }

    // MARK: Progress

    func report(
        _ event: MediaServerPlaybackEvent,
        session: MediaServerPlaybackSession,
        position: TimeInterval,
        isTranscoding: Bool
    ) async throws {
        var body: [String: Any] = [
            "ItemId": session.itemID,
            "PositionTicks": MediaServerTicks.ticks(position),
            "PlayMethod": isTranscoding ? "Transcode" : session.playMethod,
            "CanSeek": true,
        ]
        body["MediaSourceId"] = session.mediaSourceID
        body["PlaySessionId"] = session.playSessionID
        let path: String
        switch event {
        case .started:
            path = "Sessions/Playing"
            body["IsPaused"] = false
            body["IsMuted"] = false
        case .progress(let isPaused):
            path = "Sessions/Playing/Progress"
            body["IsPaused"] = isPaused
            body["EventName"] = "timeupdate"
        case .stopped:
            path = "Sessions/Playing/Stopped"
        }
        _ = try await send("POST", path, body: body)
        if event == .stopped, isTranscoding, let playSessionID = session.playSessionID {
            _ = try? await send("DELETE", "Videos/ActiveEncodings", query: [
                "DeviceId": account.deviceID,
                "PlaySessionId": playSessionID,
            ])
        }
    }

    func setPlayed(_ played: Bool, itemID: String) async throws {
        _ = try await send(played ? "POST" : "DELETE", "Users/\(account.userID)/PlayedItems/\(itemID)")
    }

    func webURL(itemID: String) -> URL {
        let serverID = account.serverID.map { "&serverId=\($0)" } ?? ""
        let fragment = switch account.kind {
        case .jellyfin: "/details?id=\(itemID)\(serverID)"
        default: "!/item?id=\(itemID)\(serverID)"
        }
        var components = URLComponents(
            url: account.serverURL.appendingPathComponent("web/index.html"),
            resolvingAgainstBaseURL: false
        )
        components?.fragment = fragment
        return components?.url ?? account.serverURL
    }

    // MARK: Parsing

    private func parseItem(_ object: [String: Any]) -> MediaServerItem? {
        guard let id = MediaServerJSON.string(object, "Id"),
              let type = MediaServerJSON.string(object, "Type") else {
            return nil
        }
        let kind: MediaServerItem.Kind
        switch type {
        case "Movie": kind = .movie
        case "Video", "MusicVideo", "Trailer": kind = .video
        case "Series": kind = .series
        case "Season": kind = .season
        case "Episode": kind = .episode
        case "Folder", "BoxSet", "CollectionFolder", "UserView", "Playlist": kind = .folder
        default: return nil
        }
        let imageTags = object["ImageTags"] as? [String: Any] ?? [:]
        let backdropTags = object["BackdropImageTags"] as? [Any] ?? []
        let userData = object["UserData"] as? [String: Any] ?? [:]
        let seriesID = MediaServerJSON.string(object, "SeriesId")

        var posterURL: URL?
        var thumbnailURL: URL?
        if kind == .episode {
            if imageTags["Primary"] != nil {
                thumbnailURL = imageURL(itemID: id, type: "Primary", maxWidth: Self.thumbnailWidth)
            }
            if let seriesID, MediaServerJSON.string(object, "SeriesPrimaryImageTag") != nil {
                posterURL = imageURL(itemID: seriesID, type: "Primary", maxWidth: Self.posterWidth)
            }
        } else {
            if imageTags["Primary"] != nil {
                posterURL = imageURL(itemID: id, type: "Primary", maxWidth: Self.posterWidth)
            }
            if imageTags["Thumb"] != nil {
                thumbnailURL = imageURL(itemID: id, type: "Thumb", maxWidth: Self.thumbnailWidth)
            } else if !backdropTags.isEmpty {
                thumbnailURL = imageURL(itemID: id, type: "Backdrop/0", maxWidth: Self.thumbnailWidth)
            }
        }
        // Series report seasons in ChildCount; RecursiveItemCount is episodes.
        let childCount = kind == .series
            ? MediaServerJSON.int(object, "RecursiveItemCount") ?? MediaServerJSON.int(object, "ChildCount")
            : MediaServerJSON.int(object, "ChildCount")
        return MediaServerItem(
            id: id,
            kind: kind,
            name: MediaServerJSON.string(object, "Name") ?? "",
            originalTitle: MediaServerJSON.string(object, "OriginalTitle"),
            overview: MediaServerJSON.string(object, "Overview"),
            year: MediaServerJSON.int(object, "ProductionYear"),
            seriesID: seriesID,
            seriesName: MediaServerJSON.string(object, "SeriesName"),
            seasonID: MediaServerJSON.string(object, "SeasonId"),
            seasonNumber: kind == .season
                ? MediaServerJSON.int(object, "IndexNumber")
                : MediaServerJSON.int(object, "ParentIndexNumber"),
            episodeNumber: kind == .episode ? MediaServerJSON.int(object, "IndexNumber") : nil,
            runtime: MediaServerTicks.seconds(MediaServerJSON.int64(object, "RunTimeTicks")),
            playbackPosition: MediaServerTicks.seconds(MediaServerJSON.int64(userData, "PlaybackPositionTicks")),
            lastPlayedAt: MediaServerJSON.date(userData, "LastPlayedDate"),
            isPlayed: MediaServerJSON.bool(userData, "Played") ?? false,
            childCount: childCount,
            unplayedCount: MediaServerJSON.int(userData, "UnplayedItemCount"),
            posterURL: posterURL,
            thumbnailURL: thumbnailURL
        )
    }

    /// Image endpoints are anonymous on Jellyfin and Emby, so these URLs can
    /// be persisted without leaking the token.
    private func imageURL(itemID: String, type: String, maxWidth: Int) -> URL? {
        url("Items/\(itemID)/Images/\(type)", query: [
            "maxWidth": String(maxWidth),
            "quality": "90",
        ])
    }

    // MARK: HTTP

    private static func authorization(deviceID: String, token: String?) -> String {
        var fields = [
            "Client=\"\(MediaServerHTTP.clientName)\"",
            "Device=\"Mac\"",
            // Commas split fields; a DeviceId with one breaks session lookup.
            "DeviceId=\"\(deviceID.replacingOccurrences(of: ",", with: ""))\"",
            "Version=\"\(MediaServerHTTP.clientVersion)\"",
        ]
        if let token {
            fields.append("Token=\"\(token)\"")
        }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }

    /// Jellyfin 10.11+ reads only `Authorization`; Emby and its compatible
    /// servers only `X-Emby-Authorization`. Send both.
    private static func applyHeaders(to request: inout URLRequest, deviceID: String, token: String?) {
        let value = authorization(deviceID: deviceID, token: token)
        request.setValue(value, forHTTPHeaderField: "Authorization")
        request.setValue(value, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func url(_ path: String, query: [String: String] = [:]) -> URL? {
        var components = URLComponents(
            url: account.serverURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }
        return components?.url
    }

    private func absoluteURL(_ pathOrURL: String) -> URL? {
        if let url = URL(string: pathOrURL), url.scheme != nil {
            return url
        }
        // Emby serves its relative URLs both with and without the `/emby`
        // prefix, so appending to the configured base works for both.
        let path = pathOrURL.hasPrefix("/") ? pathOrURL : "/" + pathOrURL
        return URL(string: account.serverURL.absoluteString + path)
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:]) throws -> URLRequest {
        guard let url = url(path, query: query) else { throw MediaServerError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        Self.applyHeaders(to: &request, deviceID: account.deviceID, token: token)
        return request
    }

    private func get(_ path: String, query: [String: String] = [:]) async throws -> Any {
        try await MediaServerHTTP.json(try request("GET", path, query: query))
    }

    private func getObject(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        try await MediaServerHTTP.jsonObject(try request("GET", path, query: query))
    }

    private func postObject(
        _ path: String,
        query: [String: String] = [:],
        body: [String: Any]
    ) async throws -> [String: Any] {
        var request = try request("POST", path, query: query)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await MediaServerHTTP.jsonObject(request)
    }

    private func send(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> Data {
        var request = try request(method, path, query: query)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await MediaServerHTTP.send(request)
    }
}
