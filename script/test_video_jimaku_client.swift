// test-sources: Features/Video/Subtitles/JimakuAPIClient.swift Features/Video/Remote/RemoteVideoSource.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift
import Foundation

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let data: Data
        let headers: [String: String]
    }

    private static let lock = NSLock()
    private static var responses: [String: Response] = [:]
    private static var capturedRequests: [URLRequest] = []

    static func reset(responses: [String: Response]) {
        lock.lock()
        self.responses = responses
        capturedRequests = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let response = request.url.flatMap { Self.responses[$0.path] }
        Self.lock.unlock()

        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func data(_ value: String) -> Data {
    Data(value.utf8)
}

@main
private enum VideoJimakuClientTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = JimakuAPIClient(
            session: session,
            baseURL: URL(string: "https://jimaku.test/api")!
        )

        StubURLProtocol.reset(responses: [
            "/api/entries/search": .init(
                statusCode: 200,
                data: data(
                    """
                    [{
                      "id": 299,
                      "name": "Violet Evergarden Movie",
                      "english_name": "Violet Evergarden: The Movie",
                      "japanese_name": "劇場版 ヴァイオレット・エヴァーガーデン",
                      "anilist_id": 109190,
                      "tmdb_id": null,
                      "flags": {"anime": true, "movie": true},
                      "last_modified": "2026-08-23T12:00:00Z"
                    }]
                    """
                ),
                headers: ["Content-Type": "application/json"]
            ),
        ])
        let entries = try await client.searchEntries(
            query: "Violet Evergarden",
            kind: .anime,
            apiKey: "secret-api-key"
        )
        expect(entries.count == 1, "search should decode Jimaku entries")
        expect(entries.first?.id == 299, "entry ID should be preserved")
        expect(entries.first?.secondaryName == "劇場版 ヴァイオレット・エヴァーガーデン", "Japanese title should be preferred as secondary copy")
        let searchRequest = StubURLProtocol.requests().first
        expect(searchRequest?.value(forHTTPHeaderField: "Authorization") == "secret-api-key", "API key should use Jimaku's raw Authorization header")
        let searchComponents = searchRequest?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        let searchItems = Dictionary(
            uniqueKeysWithValues: (searchComponents?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        expect(searchItems["query"] == "Violet Evergarden", "search query should be URL encoded")
        expect(searchItems["anime"] == "true", "anime search should explicitly scope the API")

        StubURLProtocol.reset(responses: [
            "/api/entries/299/files": .init(
                statusCode: 200,
                data: data(
                    """
                    [
                      {"name":"Movie.ja.srt","size":1200,"last_modified":"2026-08-20T00:00:00Z","url":"https://jimaku.test/files/movie.srt"},
                      {"name":"Movie.ja.ass","size":2400,"last_modified":"2026-08-21T00:00:00Z","url":"https://cdn.jimaku.test/files/movie.ass"},
                      {"name":"Movie.ja.ssa","size":2300,"last_modified":"2026-08-21T00:00:00Z","url":"/files/movie.ssa"},
                      {"name":"Movie.zip","size":3200,"last_modified":"2026-08-22T00:00:00Z","url":"https://jimaku.test/files/movie.zip"}
                    ]
                    """
                ),
                headers: ["Content-Type": "application/json"]
            ),
        ])
        let files = try await client.files(
            for: 299,
            episode: 3,
            apiKey: "secret-api-key"
        )
        expect(files.count == 3, "direct SRT/ASS/SSA should be retained while archives are filtered")
        expect(Set(files.map(\.format)) == Set([.srt, .ass, .ssa]), "supported formats should map into the existing subtitle parser")
        let filesRequest = StubURLProtocol.requests().first
        let filesComponents = filesRequest?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        expect(filesComponents?.queryItems?.first?.value == "3", "episode filter should be sent when available")
        expect(filesRequest?.value(forHTTPHeaderField: "Authorization") == "secret-api-key", "file listing should authenticate")

        StubURLProtocol.reset(responses: [
            "/api/entries/299/files": .init(
                statusCode: 200,
                data: data(
                    """
                    [{"name":"Movie.srt","size":10,"last_modified":"2026-08-20T00:00:00Z","url":"https://example.com/movie.srt"}]
                    """
                ),
                headers: ["Content-Type": "application/json"]
            ),
        ])
        do {
            _ = try await client.files(for: 299, episode: nil, apiKey: "secret-api-key")
            expect(false, "cross-domain download URLs should be rejected")
        } catch JimakuAPIError.invalidDownloadURL {
        }

        StubURLProtocol.reset(responses: [
            "/api/entries/search": .init(
                statusCode: 429,
                data: data(#"{"error":"slow down","code":429}"#),
                headers: [
                    "Content-Type": "application/json",
                    "x-ratelimit-reset-after": "2.5",
                ]
            ),
        ])
        do {
            _ = try await client.searchEntries(query: "test", kind: .liveAction, apiKey: "key")
            expect(false, "HTTP 429 should surface as rate limiting")
        } catch JimakuAPIError.rateLimited(let retryAfter) {
            expect(retryAfter == 2.5, "rate-limit reset delay should be preserved")
        }

        let seasonEpisode = JimakuMediaTitleParser.suggestion(
            from: "[SubsPlease] Sousou no Frieren S02E05 (1080p)"
        )
        expect(seasonEpisode.query == "Sousou no Frieren", "SxxExx filenames should produce a clean title")
        expect(seasonEpisode.episode == 5, "SxxExx filenames should infer the episode")

        let underscoredSeasonEpisode = JimakuMediaTitleParser.suggestion(
            from: "Jimaku_Test_S01E03"
        )
        expect(underscoredSeasonEpisode.query == "Jimaku Test", "underscore-separated SxxExx filenames should produce a clean title")
        expect(underscoredSeasonEpisode.episode == 3, "underscore-separated SxxExx filenames should infer the episode")

        let dashedEpisode = JimakuMediaTitleParser.suggestion(
            from: "[Group] Dungeon Meshi - 12 [1080p]"
        )
        expect(dashedEpisode.query == "Dungeon Meshi", "dash-number filenames should produce a clean title")
        expect(dashedEpisode.episode == 12, "dash-number filenames should infer the episode")

        print("Video Jimaku client tests passed")
    }
}
