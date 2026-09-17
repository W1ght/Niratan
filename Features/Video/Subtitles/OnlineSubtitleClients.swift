import Foundation

/// API requests never follow redirects with credentials attached.
nonisolated final class SubtitleAPIRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: SubtitleAPIRedirectPolicy(), delegateQueue: nil)
    }
}

nonisolated enum OnlineSubtitleError: LocalizedError, Sendable {
    case invalidResponse
    case http(Int)
    case missingKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse: String(localized: "The subtitle service returned an invalid response.")
        case .missingKey: String(localized: "Configure an API key for this subtitle source.")
        case .http(401), .http(403): String(localized: "The subtitle service rejected the credentials.")
        case .http(406): String(localized: "The subtitle download quota is exhausted.")
        case .http(429): String(localized: "The subtitle service is rate limiting requests. Try again later.")
        case .http(let code): String.localizedStringWithFormat(String(localized: "The subtitle service returned HTTP %lld."), Int64(code))
        }
    }
}

nonisolated struct SubtitleSeries: Decodable, Equatable, Identifiable, Sendable {
    struct Title: Decodable, Equatable, Sendable {
        let romaji: String?
        let english: String?
        let native: String?
    }
    let id: Int
    let title: Title
    let synonyms: [String]?
    let seasonYear: Int?
    let format: String?
    var name: String { title.romaji ?? title.native ?? title.english ?? String(id) }
    var aliases: [String] {
        var seen = Set<String>()
        return ([title.native, title.romaji, title.english].compactMap { $0 } + (synonyms ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 300 && seen.insert($0.lowercased()).inserted }
    }
}

actor SubtitleSeriesClient {
    static let shared = SubtitleSeriesClient()
    private let session: URLSession
    init(session: URLSession = SubtitleAPIRedirectPolicy.session()) { self.session = session }

    func search(_ query: String) async throws -> [SubtitleSeries] {
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": "query($search: String!) { Page(page: 1, perPage: 8) { media(search: $search, type: ANIME, sort: SEARCH_MATCH) { id title { romaji english native } synonyms seasonYear format } } }",
            "variables": ["search": query],
        ])
        let (data, _) = try await BoundedURLSessionData.load(session: session, request: request, maximumSize: 512 * 1_024) { response in
            guard let response = response as? HTTPURLResponse else { throw OnlineSubtitleError.invalidResponse }
            guard response.statusCode == 200 else { throw OnlineSubtitleError.http(response.statusCode) }
        }
        struct Envelope: Decodable {
            struct Payload: Decodable {
                struct Page: Decodable { let media: [SubtitleSeries] }
                let Page: Page
            }
            let data: Payload
        }
        return try JSONDecoder().decode(Envelope.self, from: data).data.Page.media
    }
}

nonisolated struct OpenSubtitlesFile: Equatable, Identifiable, Sendable {
    let fileID: Int
    let name: String
    let language: String
    let release: String?
    var id: String { "opensubtitles:\(fileID)" }
}

actor OpenSubtitlesClient {
    static let shared = OpenSubtitlesClient()
    private let session: URLSession
    init(session: URLSession = SubtitleAPIRedirectPolicy.session()) { self.session = session }

    func search(query: String, language: String, season: Int?, episode: Int?, apiKey: String, page: Int = 1) async throws -> (files: [OpenSubtitlesFile], totalPages: Int) {
        var parameters = ["query": query, "page": String(page)]
        if !language.isEmpty { parameters["languages"] = Self.languages(language) }
        if let season { parameters["season_number"] = String(season) }
        if let episode { parameters["episode_number"] = String(episode) }
        let data = try await request(path: "subtitles", parameters: parameters, apiKey: apiKey)
        struct Response: Decodable {
            struct Entry: Decodable {
                struct Attributes: Decodable {
                    struct File: Decodable { let file_id: Int; let file_name: String }
                    let language: String
                    let release: String?
                    let files: [File]
                }
                let attributes: Attributes
            }
            let data: [Entry]
            let total_pages: Int
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var seen = Set<Int>()
        let files = response.data.flatMap { entry in
            entry.attributes.files.compactMap { file -> OpenSubtitlesFile? in
                guard file.file_id > 0, !file.file_name.isEmpty, seen.insert(file.file_id).inserted else { return nil }
                return OpenSubtitlesFile(fileID: file.file_id, name: file.file_name, language: entry.attributes.language, release: entry.attributes.release)
            }
        }
        return (files, response.total_pages)
    }

    /// Only called after the user selects a file: this endpoint consumes download quota.
    func downloadOption(for file: OpenSubtitlesFile, apiKey: String) async throws -> RemoteVideoSubtitleOption {
        let data = try await request(path: "download", apiKey: apiKey, body: ["file_id": file.fileID, "sub_format": "srt"])
        struct Response: Decodable { let link: String }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let url = URL(string: response.link), Self.validDownloadURL(url) else {
            throw OnlineSubtitleError.invalidResponse
        }
        return RemoteVideoSubtitleOption(id: file.id, language: file.language, name: file.name,
                                         url: url, format: .srt, isAutomatic: false, httpHeaders: [:])
    }

    nonisolated static func languages(_ language: String) -> String {
        switch language.lowercased() {
        case "zh": "zh-cn,zh-tw"
        case "pt": "pt-br,pt-pt"
        default: language.lowercased()
        }
    }

    nonisolated static func validDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "opensubtitles.com" || host.hasSuffix(".opensubtitles.com")
            || host == "opensubtitles.org" || host.hasSuffix(".opensubtitles.org")
    }

    private func request(path: String, parameters: [String: String] = [:], apiKey: String, body: [String: Any]? = nil) async throws -> Data {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OnlineSubtitleError.missingKey }
        var components = URLComponents(string: "https://api.opensubtitles.com/api/v1/\(path)")!
        if !parameters.isEmpty {
            components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Niratan v1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await BoundedURLSessionData.load(session: session, request: request, maximumSize: 2 * 1_024 * 1_024) { response in
            guard let response = response as? HTTPURLResponse else { throw OnlineSubtitleError.invalidResponse }
            guard (200...299).contains(response.statusCode) else { throw OnlineSubtitleError.http(response.statusCode) }
        }
        return data
    }
}
