import Foundation

nonisolated struct JimakuEntryFlags: Codable, Equatable, Sendable {
    let adult: Bool?
    let anime: Bool?
    let external: Bool?
    let movie: Bool?
    let unverified: Bool?
}

nonisolated struct JimakuEntry: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let englishName: String?
    let japaneseName: String?
    let anilistID: Int?
    let tmdbID: String?
    let flags: JimakuEntryFlags
    let lastModified: String

    var secondaryName: String? {
        for candidate in [japaneseName, englishName] {
            guard let candidate,
                  !candidate.isEmpty,
                  candidate.localizedCaseInsensitiveCompare(name) != .orderedSame else {
                continue
            }
            return candidate
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case englishName = "english_name"
        case japaneseName = "japanese_name"
        case anilistID = "anilist_id"
        case tmdbID = "tmdb_id"
        case flags
        case lastModified = "last_modified"
    }
}

nonisolated struct JimakuSubtitleFile: Equatable, Identifiable, Sendable {
    let name: String
    let size: Int64
    let lastModified: String
    let downloadURL: URL
    let format: SubtitleFormat

    var id: String { downloadURL.absoluteString }

    var remoteSubtitleOption: RemoteVideoSubtitleOption {
        RemoteVideoSubtitleOption(
            id: "jimaku:\(id)",
            language: "ja",
            name: name,
            url: downloadURL,
            format: format,
            isAutomatic: false,
            httpHeaders: [:]
        )
    }
}

nonisolated enum JimakuSearchKind: String, CaseIterable, Identifiable, Sendable {
    case anime
    case liveAction

    var id: String { rawValue }

    var isAnime: Bool {
        self == .anime
    }
}

nonisolated struct JimakuMediaSuggestion: Equatable, Sendable {
    let sourceIdentifier: String
    let query: String
    let episode: Int?

    init(sourceIdentifier: String, mediaTitle: String) {
        self.sourceIdentifier = sourceIdentifier
        let guess = JimakuMediaTitleParser.suggestion(from: mediaTitle)
        query = guess.query
        episode = guess.episode
    }
}

nonisolated enum JimakuMediaTitleParser {
    private static let episodePatterns = [
        #"(?i)(?:^|[\s._-])S\d{1,2}[\s._-]*E(\d{1,4})(?:v\d+)?\b"#,
        #"(?i)\b(?:EP|Episode)[\s._-]*(\d{1,4})(?:v\d+)?\b"#,
        #"\s+-\s+(\d{1,4})(?:v\d+)?(?=\s|\.|_|-|\[|\(|$)"#,
    ]

    static func suggestion(from mediaTitle: String) -> (query: String, episode: Int?) {
        let title = mediaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return ("", nil) }

        for pattern in episodePatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: title,
                      range: NSRange(title.startIndex..., in: title)
                  ),
                  match.numberOfRanges > 1,
                  let episodeRange = Range(match.range(at: 1), in: title),
                  let episode = Int(title[episodeRange]),
                  episode <= 9_999,
                  let matchRange = Range(match.range(at: 0), in: title) else {
                continue
            }
            let prefix = String(title[..<matchRange.lowerBound])
            let query = normalizedQuery(prefix)
            return (query.isEmpty ? normalizedQuery(title) : query, episode)
        }

        return (normalizedQuery(title), nil)
    }

    private static func normalizedQuery(_ value: String) -> String {
        var result = value
        if let expression = try? NSRegularExpression(
            pattern: #"^(?:\s*\[[^\]]+\]\s*)+"#
        ) {
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        result = result.replacingOccurrences(
            of: #"[._]+"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " -_\t\n"))
    }
}

nonisolated enum JimakuAPIError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidRequest
    case invalidResponse
    case invalidDownloadURL
    case authenticationFailed
    case rateLimited(retryAfter: TimeInterval?)
    case service(message: String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            String(localized: "Jimaku requires an API key.")
        case .invalidRequest:
            String(localized: "The Jimaku request is invalid.")
        case .invalidResponse:
            String(localized: "Jimaku returned an invalid response.")
        case .invalidDownloadURL:
            String(localized: "Jimaku returned an invalid download URL.")
        case .authenticationFailed:
            String(localized: "Jimaku rejected the API key.")
        case .rateLimited(let retryAfter):
            if let retryAfter {
                String.localizedStringWithFormat(
                    String(localized: "Jimaku is rate limiting requests. Try again in %lld seconds."),
                    Int64(ceil(retryAfter))
                )
            } else {
                String(localized: "Jimaku is rate limiting requests. Try again later.")
            }
        case .service(let message):
            message.isEmpty ? String(localized: "The Jimaku request failed.") : message
        case .httpStatus(let statusCode):
            String.localizedStringWithFormat(
                String(localized: "Jimaku returned HTTP %lld."),
                Int64(statusCode)
            )
        }
    }
}

actor JimakuAPIClient {
    static let shared = JimakuAPIClient(session: makeLiveSession())

    private static let maximumResponseSize = 2 * 1_024 * 1_024

    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession,
        baseURL: URL = URL(string: "https://jimaku.cc/api")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func searchEntries(
        query: String,
        kind: JimakuSearchKind,
        apiKey: String,
        anilistID: Int? = nil
    ) async throws -> [JimakuEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 300 else {
            throw JimakuAPIError.invalidRequest
        }
        let url = try endpoint(
            path: "entries/search",
            queryItems: [
                anilistID.map { URLQueryItem(name: "anilist_id", value: String($0)) }
                    ?? URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "anime", value: kind.isAnime ? "true" : "false"),
            ]
        )
        let data = try await responseData(url: url, apiKey: apiKey)
        do {
            return try JSONDecoder().decode([JimakuEntry].self, from: data)
        } catch {
            throw JimakuAPIError.invalidResponse
        }
    }

    func files(
        for entryID: Int64,
        episode: Int?,
        apiKey: String
    ) async throws -> [JimakuSubtitleFile] {
        guard entryID >= 0,
              episode.map({ (0...9_999).contains($0) }) ?? true else {
            throw JimakuAPIError.invalidRequest
        }
        let queryItems = episode.map {
            [URLQueryItem(name: "episode", value: String($0))]
        } ?? []
        let url = try endpoint(
            path: "entries/\(entryID)/files",
            queryItems: queryItems
        )
        let data = try await responseData(url: url, apiKey: apiKey)
        let decoded: [FileResponse]
        do {
            decoded = try JSONDecoder().decode([FileResponse].self, from: data)
        } catch {
            throw JimakuAPIError.invalidResponse
        }

        return try decoded.compactMap { file in
            guard let format = Self.subtitleFormat(for: file.name) else {
                return nil
            }
            guard file.size >= 0,
                  let downloadURL = resolvedDownloadURL(file.url) else {
                throw JimakuAPIError.invalidDownloadURL
            }
            return JimakuSubtitleFile(
                name: file.name,
                size: file.size,
                lastModified: file.lastModified,
                downloadURL: downloadURL,
                format: format
            )
        }
        .sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func endpoint(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let url = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw JimakuAPIError.invalidRequest
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let endpointURL = components.url else {
            throw JimakuAPIError.invalidRequest
        }
        return endpointURL
    }

    private func responseData(url: URL, apiKey: String) async throws -> Data {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw JimakuAPIError.missingAPIKey
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maximumResponseSize,
              let response = response as? HTTPURLResponse else {
            throw JimakuAPIError.invalidResponse
        }
        switch response.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw JimakuAPIError.authenticationFailed
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "x-ratelimit-reset-after")
                .flatMap(TimeInterval.init)
            throw JimakuAPIError.rateLimited(retryAfter: retryAfter)
        default:
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw JimakuAPIError.service(message: apiError.error)
            }
            throw JimakuAPIError.httpStatus(response.statusCode)
        }
    }

    private func resolvedDownloadURL(_ value: String) -> URL? {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              let baseHost = baseURL.host?.lowercased(),
              host == baseHost || host.hasSuffix(".\(baseHost)") else {
            return nil
        }
        return url
    }

    private static func subtitleFormat(for fileName: String) -> SubtitleFormat? {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "srt": .srt
        case "vtt": .webVTT
        case "ass": .ass
        case "ssa": .ssa
        default: nil
        }
    }

    private static func makeLiveSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private struct FileResponse: Decodable {
        let name: String
        let size: Int64
        let lastModified: String
        let url: String

        private enum CodingKeys: String, CodingKey {
            case name
            case size
            case lastModified = "last_modified"
            case url
        }
    }

    private struct APIErrorResponse: Decodable {
        let error: String
    }
}
