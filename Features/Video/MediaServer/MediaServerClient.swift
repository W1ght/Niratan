import Foundation

nonisolated protocol MediaServerClient: Sendable {
    var account: MediaServerAccount { get }

    func libraries() async throws -> [MediaServerLibrary]
    func items(
        parentID: String,
        sort: MediaServerSort,
        start: Int,
        limit: Int
    ) async throws -> MediaServerItemPage
    func continueWatching(limit: Int) async throws -> [MediaServerItem]
    func latest(libraryID: String, limit: Int) async throws -> [MediaServerItem]
    func seasons(seriesID: String) async throws -> [MediaServerItem]
    func episodes(seriesID: String, seasonID: String?) async throws -> [MediaServerItem]
    func search(_ query: String, limit: Int) async throws -> [MediaServerItem]
    func item(id: String) async throws -> MediaServerItem
    func playback(itemID: String) async throws -> MediaServerPlayback
    func report(
        _ event: MediaServerPlaybackEvent,
        session: MediaServerPlaybackSession,
        position: TimeInterval,
        isTranscoding: Bool
    ) async throws
    func setPlayed(_ played: Bool, itemID: String) async throws
    /// The item's page in the server's own web client. Never carries a token.
    func webURL(itemID: String) -> URL
}

/// One client per signed-in account, built lazily from the stored account and
/// its Keychain token.
actor MediaServerClientFactory {
    static let shared = MediaServerClientFactory()

    private var clients: [UUID: any MediaServerClient] = [:]
    private let credentials: MediaServerCredentialStore

    init(credentials: MediaServerCredentialStore = .shared) {
        self.credentials = credentials
    }

    func client(for account: MediaServerAccount) async throws -> any MediaServerClient {
        if let cached = clients[account.id], cached.account == account {
            return cached
        }
        guard let token = try await credentials.token(for: account.id) else {
            throw MediaServerError.missingCredentials
        }
        let client = Self.makeClient(account: account, token: token)
        clients[account.id] = client
        return client
    }

    func client(accountID: UUID) async throws -> any MediaServerClient {
        if let cached = clients[accountID] {
            return cached
        }
        guard let account = MediaServerAccountStore.loadAccount(id: accountID) else {
            throw MediaServerError.accountNotFound
        }
        return try await client(for: account)
    }

    func invalidate(accountID: UUID) {
        clients.removeValue(forKey: accountID)
    }

    static func makeClient(account: MediaServerAccount, token: String) -> any MediaServerClient {
        switch account.kind {
        case .jellyfin, .emby:
            JellyfinMediaServerClient(account: account, token: token)
        case .plex:
            PlexMediaServerClient(account: account, token: token)
        }
    }
}

nonisolated enum MediaServerHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static let clientName = "Niratan"

    static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Some public servers sit behind Cloudflare rules that reject library
    /// user agents, so every request names the app explicitly.
    static var userAgent: String {
        "\(clientName)/\(clientVersion) (Macintosh; macOS)"
    }

    static func newDeviceID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Sends the request and returns the body of a 2xx response.
    static func send(
        _ request: URLRequest,
        unauthorizedError: MediaServerError = .sessionExpired
    ) async throws -> Data {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw MediaServerError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MediaServerError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw unauthorizedError
        default:
            throw MediaServerError.httpStatus(http.statusCode)
        }
    }

    static func json(
        _ request: URLRequest,
        unauthorizedError: MediaServerError = .sessionExpired
    ) async throws -> Any {
        let data = try await send(request, unauthorizedError: unauthorizedError)
        // Some compatible servers answer unknown routes with an HTML SPA page.
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw MediaServerError.invalidResponse
        }
        return object
    }

    static func jsonObject(
        _ request: URLRequest,
        unauthorizedError: MediaServerError = .sessionExpired
    ) async throws -> [String: Any] {
        guard let object = try await json(request, unauthorizedError: unauthorizedError) as? [String: Any] else {
            throw MediaServerError.invalidResponse
        }
        return object
    }
}

/// Loose JSON accessors; servers disagree on number/string encodings.
nonisolated enum MediaServerJSON {
    static func string(_ object: [String: Any], _ key: String) -> String? {
        switch object[key] {
        case let value as String:
            value.isEmpty ? nil : value
        case let value as NSNumber:
            value.stringValue
        default:
            nil
        }
    }

    static func int(_ object: [String: Any], _ key: String) -> Int? {
        switch object[key] {
        case let value as NSNumber:
            value.intValue
        case let value as String:
            Int(value)
        default:
            nil
        }
    }

    static func int64(_ object: [String: Any], _ key: String) -> Int64? {
        switch object[key] {
        case let value as NSNumber:
            value.int64Value
        case let value as String:
            Int64(value)
        default:
            nil
        }
    }

    static func double(_ object: [String: Any], _ key: String) -> Double? {
        switch object[key] {
        case let value as NSNumber:
            value.doubleValue
        case let value as String:
            Double(value)
        default:
            nil
        }
    }

    static func bool(_ object: [String: Any], _ key: String) -> Bool? {
        switch object[key] {
        case let value as Bool:
            value
        case let value as NSNumber:
            value.boolValue
        case let value as String:
            ["true", "1"].contains(value.lowercased())
        default:
            nil
        }
    }

    static func objects(_ object: [String: Any], _ key: String) -> [[String: Any]] {
        object[key] as? [[String: Any]] ?? []
    }

    /// ISO 8601 with any number of fractional digits (.NET writes seven).
    static func date(_ object: [String: Any], _ key: String) -> Date? {
        guard var text = string(object, key) else { return nil }
        if let dot = text.firstIndex(of: ".") {
            let tail = text[dot...].drop(while: { $0 == "." || $0.isNumber })
            text = String(text[..<dot]) + tail
        }
        if !text.hasSuffix("Z"), !text.contains("+"), text.count == 19 {
            text += "Z"
        }
        return ISO8601DateFormatter().date(from: text)
    }

    /// "jpn" → "ja"; keeps unknown codes as-is.
    static func languageCode(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return ""
        }
        if raw == "chi" || raw == "zho" {
            return "zh"
        }
        if let code = Locale.Language(identifier: raw).languageCode?.identifier(.alpha2) {
            return code
        }
        return raw
    }
}

/// Client-side search gate shared by every server type: each whitespace token
/// must appear in the title or original title. Compatible servers match far
/// looser than they should (see Fushi `media_server_search_match.dart`).
nonisolated enum MediaServerSearchMatch {
    static func filter(_ items: [MediaServerItem], query: String) -> [MediaServerItem] {
        let normalizedQuery = normalize(query)
        let tokens = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return items }
        let matches = items.filter { item in
            let haystacks = [item.name, item.originalTitle].compactMap { $0 }.map(normalize)
            return tokens.allSatisfy { token in
                haystacks.contains { $0.contains(token) }
            }
        }
        return matches.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element, query: normalizedQuery)
            let right = rank(rhs.element, query: normalizedQuery)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private static func rank(_ item: MediaServerItem, query: String) -> Int {
        let titles = [item.name, item.originalTitle].compactMap { $0 }.map(normalize)
        if titles.contains(query) { return 0 }
        if titles.contains(where: { $0.hasPrefix(query) }) { return 1 }
        return 2
    }

    private static func normalize(_ text: String) -> String {
        (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
