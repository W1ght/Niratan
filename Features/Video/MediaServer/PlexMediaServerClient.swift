import Foundation

/// Plex Media Server client. The token may be empty for servers that allow
/// unauthenticated access from the local network.
nonisolated struct PlexMediaServerClient: MediaServerClient {
    let account: MediaServerAccount
    private let token: String

    init(account: MediaServerAccount, token: String) {
        self.account = account
        self.token = token
    }

    private static let sectionPrefix = "section/"
    private static let posterSize = (width: 400, height: 600)
    private static let thumbnailSize = (width: 720, height: 405)

    // MARK: Sign-in

    nonisolated struct ServerInfo: Sendable {
        let baseURL: URL
        let name: String
        let machineIdentifier: String?
    }

    nonisolated struct PlexAccount: Sendable {
        let token: String
        let username: String
    }

    nonisolated struct PIN: Sendable {
        let id: Int
        let code: String
        let clientIdentifier: String

        var authURL: URL {
            var components = URLComponents(string: "https://app.plex.tv/auth")!
            var fragment = URLComponents()
            fragment.queryItems = [
                URLQueryItem(name: "clientID", value: clientIdentifier),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "context[device][product]", value: MediaServerHTTP.clientName),
            ]
            components.fragment = "?" + (fragment.percentEncodedQuery ?? "")
            return components.url!
        }
    }

    static func probe(_ rawURL: String, token: String) async throws -> ServerInfo {
        guard let baseURL = MediaServerURLNormalizer.normalize(rawURL, defaultPort: 32400) else {
            throw MediaServerError.invalidServerURL
        }
        var request = URLRequest(url: baseURL)
        applyHeaders(to: &request, clientIdentifier: MediaServerHTTP.newDeviceID(), token: token)
        let root = try await MediaServerHTTP.jsonObject(request, unauthorizedError: .invalidCredentials)
        guard let container = root["MediaContainer"] as? [String: Any] else {
            throw MediaServerError.invalidResponse
        }
        return ServerInfo(
            baseURL: baseURL,
            name: MediaServerJSON.string(container, "friendlyName") ?? "",
            machineIdentifier: MediaServerJSON.string(container, "machineIdentifier")
        )
    }

    /// Server URL plus an optional `X-Plex-Token`.
    static func signIn(
        rawURL: String,
        token: String,
        username: String = ""
    ) async throws -> (account: MediaServerAccount, token: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = try await probe(rawURL, token: trimmedToken)
        let account = MediaServerAccount(
            id: UUID(),
            kind: .plex,
            serverURL: server.baseURL,
            serverName: server.name,
            serverID: server.machineIdentifier,
            username: username,
            userID: username.isEmpty ? (server.machineIdentifier ?? "") : username,
            deviceID: MediaServerHTTP.newDeviceID(),
            addedAt: Date()
        )
        return (account, trimmedToken)
    }

    /// plex.tv account sign-in, then the server is located among the
    /// account's resources so shared servers get their own access token.
    static func signIn(
        rawURL: String,
        username: String,
        password: String
    ) async throws -> (account: MediaServerAccount, token: String) {
        let clientIdentifier = MediaServerHTTP.newDeviceID()
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/users/signin")!)
        request.httpMethod = "POST"
        applyHeaders(to: &request, clientIdentifier: clientIdentifier, token: nil)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(MediaServerHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(formEncoded([
            ("login", username),
            ("password", password),
            ("rememberMe", "true"),
        ]).utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await MediaServerHTTP.session.data(for: request)
        } catch {
            throw MediaServerError.unreachable(error.localizedDescription)
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            // Code 1029 asks for a two-step verification code.
            let codes = MediaServerJSON.objects(object, "errors").compactMap { MediaServerJSON.int($0, "code") }
            if codes.contains(1029) {
                throw MediaServerError.twoFactorRequired
            }
            if [400, 401, 403, 422].contains(status) {
                throw MediaServerError.invalidCredentials
            }
            throw MediaServerError.httpStatus(status)
        }
        guard let token = MediaServerJSON.string(object, "authToken") else {
            throw MediaServerError.invalidResponse
        }
        let plexAccount = PlexAccount(
            token: token,
            username: MediaServerJSON.string(object, "username") ?? username
        )
        return try await connect(rawURL: rawURL, plexAccount: plexAccount, clientIdentifier: clientIdentifier)
    }

    private static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(name)=\(encoded)"
        }.joined(separator: "&")
    }

    static func requestPIN() async throws -> PIN {
        let clientIdentifier = MediaServerHTTP.newDeviceID()
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins?strong=true")!)
        request.httpMethod = "POST"
        applyHeaders(to: &request, clientIdentifier: clientIdentifier, token: nil)
        let response = try await MediaServerHTTP.jsonObject(request)
        guard let id = MediaServerJSON.int(response, "id"),
              let code = MediaServerJSON.string(response, "code") else {
            throw MediaServerError.invalidResponse
        }
        return PIN(id: id, code: code, clientIdentifier: clientIdentifier)
    }

    /// Polls the PIN until the user approves it in the browser.
    static func signIn(
        rawURL: String,
        pin: PIN,
        timeout: TimeInterval = 300
    ) async throws -> (account: MediaServerAccount, token: String) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!)
            applyHeaders(to: &request, clientIdentifier: pin.clientIdentifier, token: nil)
            let response = try await MediaServerHTTP.jsonObject(request)
            if let token = MediaServerJSON.string(response, "authToken") {
                let username = try? await plexUsername(token: token, clientIdentifier: pin.clientIdentifier)
                return try await connect(
                    rawURL: rawURL,
                    plexAccount: PlexAccount(token: token, username: username ?? ""),
                    clientIdentifier: pin.clientIdentifier
                )
            }
        }
        throw MediaServerError.signInTimedOut
    }

    private static func plexUsername(token: String, clientIdentifier: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/user")!)
        applyHeaders(to: &request, clientIdentifier: clientIdentifier, token: token)
        let user = try await MediaServerHTTP.jsonObject(request)
        return MediaServerJSON.string(user, "username") ?? MediaServerJSON.string(user, "title")
    }

    private static func connect(
        rawURL: String,
        plexAccount: PlexAccount,
        clientIdentifier: String
    ) async throws -> (account: MediaServerAccount, token: String) {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!)
        applyHeaders(to: &request, clientIdentifier: clientIdentifier, token: plexAccount.token)
        let resources = (try? await MediaServerHTTP.json(request) as? [[String: Any]]) ?? []
        let servers = resources.filter {
            (MediaServerJSON.string($0, "provides") ?? "").contains("server")
        }
        let enteredURL = MediaServerURLNormalizer.normalize(rawURL, defaultPort: 32400)
        let resource = servers.first { server in
            guard let enteredURL else { return false }
            return MediaServerJSON.objects(server, "connections").contains { connection in
                guard let uri = MediaServerJSON.string(connection, "uri").flatMap(URL.init(string:)) else {
                    return false
                }
                return uri.host() == enteredURL.host() && (uri.port ?? 32400) == (enteredURL.port ?? 32400)
            }
        } ?? servers.first
        let serverToken = resource.flatMap { MediaServerJSON.string($0, "accessToken") } ?? plexAccount.token

        var candidates: [String] = []
        if !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(rawURL)
        }
        if let resource {
            let connections = MediaServerJSON.objects(resource, "connections").sorted {
                let left = (MediaServerJSON.bool($0, "relay") == true ? 2 : 0) + (MediaServerJSON.bool($0, "local") == true ? 0 : 1)
                let right = (MediaServerJSON.bool($1, "relay") == true ? 2 : 0) + (MediaServerJSON.bool($1, "local") == true ? 0 : 1)
                return left < right
            }
            candidates += connections.compactMap { MediaServerJSON.string($0, "uri") }
        }
        guard !candidates.isEmpty else { throw MediaServerError.plexServerNotFound }
        var lastError: (any Error) = MediaServerError.plexServerNotFound
        for candidate in candidates {
            do {
                let server = try await probe(candidate, token: serverToken)
                let account = MediaServerAccount(
                    id: UUID(),
                    kind: .plex,
                    serverURL: server.baseURL,
                    serverName: server.name.isEmpty
                        ? (resource.flatMap { MediaServerJSON.string($0, "name") } ?? "")
                        : server.name,
                    serverID: server.machineIdentifier,
                    username: plexAccount.username,
                    userID: plexAccount.username.isEmpty ? (server.machineIdentifier ?? "") : plexAccount.username,
                    deviceID: clientIdentifier,
                    addedAt: Date()
                )
                return (account, serverToken)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Browsing

    func libraries() async throws -> [MediaServerLibrary] {
        let container = try await getContainer("library/sections")
        return MediaServerJSON.objects(container, "Directory").compactMap { directory in
            guard let key = MediaServerJSON.string(directory, "key") else { return nil }
            let kind: MediaServerLibrary.Kind
            switch MediaServerJSON.string(directory, "type") {
            case "movie": kind = .movies
            case "show": kind = .shows
            default: return nil
            }
            return MediaServerLibrary(
                id: Self.sectionPrefix + key,
                name: MediaServerJSON.string(directory, "title") ?? "",
                kind: kind,
                imageURL: nil
            )
        }
    }

    func items(
        parentID: String,
        sort: MediaServerSort,
        start: Int,
        limit: Int
    ) async throws -> MediaServerItemPage {
        let path: String
        var query = [
            "X-Plex-Container-Start": String(start),
            "X-Plex-Container-Size": String(limit),
        ]
        if parentID.hasPrefix(Self.sectionPrefix) {
            path = "library/sections/\(parentID.dropFirst(Self.sectionPrefix.count))/all"
            query["sort"] = switch sort {
            case .name: "titleSort:asc"
            case .dateAdded: "addedAt:desc"
            case .releaseDate: "originallyAvailableAt:desc"
            case .rating: "audienceRating:desc"
            }
        } else {
            path = "library/metadata/\(parentID)/children"
        }
        let container = try await getContainer(path, query: query)
        let rows = MediaServerJSON.objects(container, "Metadata")
        let total = MediaServerJSON.int(container, "totalSize") ?? (start + rows.count)
        return MediaServerItemPage(
            items: rows.compactMap(parseItem),
            totalCount: total,
            nextStart: rows.isEmpty ? total : start + rows.count
        )
    }

    func continueWatching(limit: Int) async throws -> [MediaServerItem] {
        let container = try await getContainer("library/onDeck", query: [
            "X-Plex-Container-Start": "0",
            "X-Plex-Container-Size": String(limit),
        ])
        return MediaServerJSON.objects(container, "Metadata").compactMap(parseItem).filter(\.isPlayable)
    }

    func latest(libraryID: String, limit: Int) async throws -> [MediaServerItem] {
        guard libraryID.hasPrefix(Self.sectionPrefix) else { return [] }
        let container = try await getContainer(
            "library/sections/\(libraryID.dropFirst(Self.sectionPrefix.count))/recentlyAdded",
            query: [
                "X-Plex-Container-Start": "0",
                "X-Plex-Container-Size": String(limit),
            ]
        )
        return MediaServerJSON.objects(container, "Metadata").compactMap(parseItem)
    }

    func seasons(seriesID: String) async throws -> [MediaServerItem] {
        let container = try await getContainer("library/metadata/\(seriesID)/children")
        return MediaServerJSON.objects(container, "Metadata").compactMap(parseItem).filter { $0.kind == .season }
    }

    func episodes(seriesID: String, seasonID: String?) async throws -> [MediaServerItem] {
        let path = seasonID.map { "library/metadata/\($0)/children" }
            ?? "library/metadata/\(seriesID)/allLeaves"
        let container = try await getContainer(path)
        return MediaServerJSON.objects(container, "Metadata").compactMap(parseItem).filter { $0.kind == .episode }
    }

    func search(_ query: String, limit: Int) async throws -> [MediaServerItem] {
        let container = try await getContainer("hubs/search", query: [
            "query": query,
            "limit": "50",
        ])
        let items = MediaServerJSON.objects(container, "Hub")
            .filter { ["movie", "show"].contains(MediaServerJSON.string($0, "type") ?? "") }
            .flatMap { MediaServerJSON.objects($0, "Metadata") }
            .compactMap(parseItem)
        return Array(MediaServerSearchMatch.filter(items, query: query).prefix(limit))
    }

    func item(id: String) async throws -> MediaServerItem {
        guard let item = try await metadata(id).flatMap(parseItem) else {
            throw MediaServerError.notPlayable
        }
        return item
    }

    // MARK: Playback

    func playback(itemID: String) async throws -> MediaServerPlayback {
        guard let metadata = try await metadata(itemID),
              let item = parseItem(metadata),
              item.isPlayable,
              let media = MediaServerJSON.objects(metadata, "Media").first,
              let part = MediaServerJSON.objects(media, "Part").first,
              let partKey = MediaServerJSON.string(part, "key"),
              let streamURL = url(partKey, query: tokenQuery) else {
            throw MediaServerError.notPlayable
        }
        let videoHeight = MediaServerJSON.int(media, "height")
        let subtitles = MediaServerJSON.objects(part, "Stream").compactMap(subtitle)
        let sessionID = MediaServerHTTP.newDeviceID()
        let transcodeOptions = MediaServerQualityPreset.all
            .filter { $0.height < (videoHeight ?? Int.max) }
            .compactMap { preset -> (preset: MediaServerQualityPreset, url: URL)? in
                transcodeURL(itemID: itemID, sessionID: sessionID, preset: preset).map { (preset, $0) }
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
                mediaSourceID: MediaServerJSON.string(media, "id"),
                playSessionID: sessionID,
                playMethod: "DirectPlay",
                duration: item.runtime
            ),
            transcodeOptions: transcodeOptions
        )
    }

    /// Plex only serves sidecar subtitle files (`key`); embedded tracks are
    /// left to mpv.
    private func subtitle(from stream: [String: Any]) -> MediaServerSubtitle? {
        guard MediaServerJSON.int(stream, "streamType") == 3,
              let id = MediaServerJSON.string(stream, "id"),
              let key = MediaServerJSON.string(stream, "key"),
              let subtitleURL = url(key, query: tokenQuery) else {
            return nil
        }
        let codec = (MediaServerJSON.string(stream, "codec") ?? MediaServerJSON.string(stream, "format") ?? "")
            .lowercased()
        let format: SubtitleFormat
        switch codec {
        case "srt", "subrip": format = .srt
        case "ass": format = .ass
        case "ssa": format = .ssa
        case "vtt", "webvtt": format = .webVTT
        default: return nil
        }
        let language = MediaServerJSON.string(stream, "languageTag")
            ?? MediaServerJSON.languageCode(MediaServerJSON.string(stream, "languageCode"))
        return MediaServerSubtitle(
            id: id,
            language: language,
            title: MediaServerJSON.string(stream, "displayTitle") ?? language,
            url: subtitleURL,
            format: format
        )
    }

    /// The universal transcoder only answers known client platforms.
    private func transcodeURL(itemID: String, sessionID: String, preset: MediaServerQualityPreset) -> URL? {
        var query = [
            "path": "/library/metadata/\(itemID)",
            "mediaIndex": "0",
            "partIndex": "0",
            "protocol": "hls",
            "fastSeek": "1",
            "directPlay": "0",
            "directStream": "1",
            "subtitleSize": "100",
            "audioBoost": "100",
            "location": "lan",
            "copyts": "1",
            "videoResolution": "\(preset.width)x\(preset.height)",
            "maxVideoBitrate": String(preset.bitrate / 1_000),
            "session": sessionID,
            "X-Plex-Platform": "Chrome",
            "X-Plex-Client-Identifier": account.deviceID,
            "X-Plex-Product": MediaServerHTTP.clientName,
        ]
        query.merge(tokenQuery) { _, new in new }
        return url("video/:/transcode/universal/start.m3u8", query: query)
    }

    // MARK: Progress

    func report(
        _ event: MediaServerPlaybackEvent,
        session: MediaServerPlaybackSession,
        position: TimeInterval,
        isTranscoding: Bool
    ) async throws {
        let state = switch event {
        case .started: "playing"
        case .progress(let isPaused): isPaused ? "paused" : "playing"
        case .stopped: "stopped"
        }
        var query = [
            "ratingKey": session.itemID,
            "key": "/library/metadata/\(session.itemID)",
            "state": state,
            "time": String(Int((max(position, 0) * 1_000).rounded())),
        ]
        if let duration = session.duration {
            query["duration"] = String(Int((duration * 1_000).rounded()))
        }
        var request = try request(":/timeline", query: query)
        if let playSessionID = session.playSessionID {
            request.setValue(playSessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
        }
        _ = try await MediaServerHTTP.send(request)
        if event == .stopped, isTranscoding, let playSessionID = session.playSessionID {
            _ = try? await MediaServerHTTP.send(try self.request(
                "video/:/transcode/universal/stop",
                query: ["session": playSessionID]
            ))
        }
    }

    func setPlayed(_ played: Bool, itemID: String) async throws {
        _ = try await MediaServerHTTP.send(try request(played ? ":/scrobble" : ":/unscrobble", query: [
            "identifier": "com.plexapp.plugins.library",
            "key": itemID,
        ]))
    }

    func webURL(itemID: String) -> URL {
        var components = URLComponents(string: "https://app.plex.tv/desktop/")!
        let key = "/library/metadata/\(itemID)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? itemID
        components.percentEncodedFragment = "!/server/\(account.serverID ?? "")/details?key=\(key)"
        return components.url ?? account.serverURL
    }

    // MARK: Parsing

    private func metadata(_ id: String) async throws -> [String: Any]? {
        MediaServerJSON.objects(try await getContainer("library/metadata/\(id)"), "Metadata").first
    }

    private func parseItem(_ object: [String: Any]) -> MediaServerItem? {
        guard let id = MediaServerJSON.string(object, "ratingKey"),
              let type = MediaServerJSON.string(object, "type") else {
            return nil
        }
        let kind: MediaServerItem.Kind
        switch type {
        case "movie": kind = .movie
        case "show": kind = .series
        case "season": kind = .season
        case "episode": kind = .episode
        case "clip": kind = .video
        case "collection": kind = .folder
        default: return nil
        }
        let leafCount = MediaServerJSON.int(object, "leafCount")
        let viewedLeafCount = MediaServerJSON.int(object, "viewedLeafCount")
        let isPlayed: Bool = if let leafCount, let viewedLeafCount {
            leafCount > 0 && viewedLeafCount >= leafCount
        } else {
            (MediaServerJSON.int(object, "viewCount") ?? 0) > 0
        }
        let thumb = MediaServerJSON.string(object, "thumb")
        let art = MediaServerJSON.string(object, "art")
        let posterPath: String?
        let thumbnailPath: String?
        switch kind {
        case .episode:
            posterPath = MediaServerJSON.string(object, "grandparentThumb") ?? MediaServerJSON.string(object, "parentThumb")
            thumbnailPath = thumb
        case .season:
            posterPath = thumb ?? MediaServerJSON.string(object, "parentThumb")
            thumbnailPath = art
        default:
            posterPath = thumb
            thumbnailPath = art
        }
        return MediaServerItem(
            id: id,
            kind: kind,
            name: MediaServerJSON.string(object, "title") ?? "",
            originalTitle: MediaServerJSON.string(object, "originalTitle"),
            overview: MediaServerJSON.string(object, "summary"),
            year: MediaServerJSON.int(object, "year"),
            seriesID: kind == .episode
                ? MediaServerJSON.string(object, "grandparentRatingKey")
                : (kind == .season ? MediaServerJSON.string(object, "parentRatingKey") : nil),
            seriesName: kind == .episode
                ? MediaServerJSON.string(object, "grandparentTitle")
                : (kind == .season ? MediaServerJSON.string(object, "parentTitle") : nil),
            seasonID: kind == .episode ? MediaServerJSON.string(object, "parentRatingKey") : nil,
            seasonNumber: kind == .season
                ? MediaServerJSON.int(object, "index")
                : (kind == .episode ? MediaServerJSON.int(object, "parentIndex") : nil),
            episodeNumber: kind == .episode ? MediaServerJSON.int(object, "index") : nil,
            runtime: MediaServerJSON.double(object, "duration").map { $0 / 1_000 },
            playbackPosition: MediaServerJSON.double(object, "viewOffset").map { $0 / 1_000 },
            lastPlayedAt: MediaServerJSON.double(object, "lastViewedAt").map { Date(timeIntervalSince1970: $0) },
            isPlayed: isPlayed,
            childCount: leafCount,
            unplayedCount: leafCount.map { $0 - (viewedLeafCount ?? 0) },
            posterURL: posterPath.flatMap { imageURL($0, size: Self.posterSize) },
            thumbnailURL: thumbnailPath.flatMap { imageURL($0, size: Self.thumbnailSize) }
        )
    }

    /// Plex images need the token, so these URLs stay in memory and are
    /// never written to the local video library catalog.
    private func imageURL(_ path: String, size: (width: Int, height: Int)) -> URL? {
        var query = [
            "width": String(size.width),
            "height": String(size.height),
            "minSize": "1",
            "upscale": "1",
            "url": path,
        ]
        query.merge(tokenQuery) { _, new in new }
        return url("photo/:/transcode", query: query)
    }

    // MARK: HTTP

    private var tokenQuery: [String: String] {
        token.isEmpty ? [:] : ["X-Plex-Token": token]
    }

    private static func applyHeaders(
        to request: inout URLRequest,
        clientIdentifier: String,
        token: String?
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(MediaServerHTTP.clientName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(MediaServerHTTP.clientVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("Mac", forHTTPHeaderField: "X-Plex-Device-Name")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
    }

    private func url(_ path: String, query: [String: String] = [:]) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            string: account.serverURL.absoluteString + "/" + trimmed
        ) else {
            return nil
        }
        var items = components.queryItems ?? []
        items += query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items.isEmpty ? nil : items
        // `URLComponents` leaves "/" and ":" unescaped inside query values,
        // which Plex accepts.
        return components.url
    }

    private func request(_ path: String, query: [String: String] = [:]) throws -> URLRequest {
        guard let url = url(path, query: query) else { throw MediaServerError.invalidServerURL }
        var request = URLRequest(url: url)
        Self.applyHeaders(to: &request, clientIdentifier: account.deviceID, token: token)
        return request
    }

    private func getContainer(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        let object = try await MediaServerHTTP.jsonObject(try request(path, query: query))
        guard let container = object["MediaContainer"] as? [String: Any] else {
            throw MediaServerError.invalidResponse
        }
        return container
    }
}
