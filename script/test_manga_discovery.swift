// test-sources: Features/Manga/MangaDiscoveryService.swift
import Foundation

private final class MangaDiscoveryMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let result = try Self.lock.withLock { try Self.handler?(request) }
            guard let result else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func response(
    for request: URLRequest,
    status: Int = 200,
    headers: [String: String] = ["Content-Type": "application/json"]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

@main
private enum MangaDiscoveryTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MangaDiscoveryMockProtocol.self]
        let session = URLSession(configuration: configuration)

        try await testAniList(session: session)
        try await testJikan(session: session)
        try await testTransportBounds(session: session)
        testIdentityAndMatching()
        print("Manga discovery tests passed")
    }

    private static func testAniList(session: URLSession) async throws {
        MangaDiscoveryMockProtocol.handler = { request in
            let json = #"""
            {"data":{"Page":{"pageInfo":{"hasNextPage":true},"media":[
              {"id":101,"idMal":42,"title":{"userPreferred":"星の漫画","romaji":"Hoshi no Manga","english":"Star Manga","native":"星の漫画"},"synonyms":["Hoshi Manga"],"coverImage":{"large":"https://img.example/42.jpg"},"description":"Summary","status":"RELEASING","format":"MANGA","averageScore":84,"chapters":12,"volumes":2,"genres":["Drama"],"tags":[],"siteUrl":"https://anilist.co/manga/101","isAdult":false,"staff":{"edges":[]}},
              {"id":102,"idMal":null,"title":{"userPreferred":"Hidden","romaji":null,"english":null,"native":null},"synonyms":[],"coverImage":null,"description":null,"status":null,"format":"MANGA","averageScore":null,"chapters":null,"volumes":null,"genres":[],"tags":[],"siteUrl":null,"isAdult":true,"staff":{"edges":[]}}
            ]}}}
            """#
            return (response(for: request), Data(json.utf8))
        }

        let provider = AniListMangaDiscoveryProvider(session: session)
        let safe = try await provider.search(query: "hoshi", page: 2, allowsAdult: false)
        expect(safe.entries.count == 1, "AniList must apply adult filtering defensively")
        expect(safe.hasNextPage, "AniList pagination must preserve hasNextPage")
        expect(safe.entries[0].identity.canonicalWorkID == "mal:42", "AniList idMal must canonicalize to the shared MAL identity")
        expect(safe.entries[0].englishTitle == "Star Manga", "AniList titles must decode into the unified work")

        let adult = try await provider.search(query: "hoshi", page: 1, allowsAdult: true)
        expect(adult.entries.count == 2, "AniList adult results must remain available when enabled")
        expect(adult.entries[1].identity.canonicalWorkID == "anilist:102", "AniList-only works need a stable provider identity")
    }

    private static func testJikan(session: URLSession) async throws {
        MangaDiscoveryMockProtocol.handler = { request in
            let json = #"""
            {"pagination":{"has_next_page":true},"data":[
              {"mal_id":42,"url":"https://myanimelist.net/manga/42","title":"Hoshi no Manga","title_english":"Star Manga","title_japanese":"星の漫画","title_synonyms":["Hoshi Manga"],"titles":[],"type":"Manga","chapters":12,"volumes":2,"status":"Publishing","score":8.4,"synopsis":"Summary","background":null,"authors":[{"name":"A. Author"}],"genres":[{"name":"Drama"}],"explicit_genres":[],"themes":[],"demographics":[]},
              {"mal_id":43,"url":"https://myanimelist.net/manga/43","title":"Words Only","title_english":null,"title_japanese":null,"title_synonyms":[],"titles":[],"type":"Light Novel","chapters":null,"volumes":1,"status":"Finished","score":7.0,"synopsis":null,"background":null,"authors":[],"genres":[],"explicit_genres":[],"themes":[],"demographics":[]},
              {"mal_id":44,"url":"https://myanimelist.net/manga/44","title":"Adult Manga","title_english":null,"title_japanese":null,"title_synonyms":[],"titles":[],"type":"Manhwa","chapters":1,"volumes":1,"status":"Finished","score":6.0,"synopsis":null,"background":null,"authors":[],"genres":[],"explicit_genres":[{"name":"Hentai"}],"themes":[],"demographics":[]}
            ]}
            """#
            return (response(for: request), Data(json.utf8))
        }

        let provider = JikanMangaDiscoveryProvider(
            session: session,
            throttle: MangaDiscoveryRequestThrottle(spacing: .zero)
        )
        let safe = try await provider.search(query: "star", page: 1, allowsAdult: false)
        expect(safe.entries.map(\.identity.canonicalWorkID) == ["mal:42"], "Jikan must exclude novels and adult entries")
        expect(safe.entries[0].score == 84, "Jikan ten-point scores must normalize to percent")
        expect(safe.hasNextPage, "Jikan pagination must preserve has_next_page")

        let adult = try await provider.search(query: "star", page: 1, allowsAdult: true)
        expect(adult.entries.map(\.identity.canonicalWorkID) == ["mal:42", "mal:44"], "Jikan must admit supported adult visual formats only when enabled")
    }

    private static func testTransportBounds(session: URLSession) async throws {
        MangaDiscoveryMockProtocol.handler = { request in
            (response(for: request, status: 429, headers: ["Retry-After": "7"]), Data())
        }
        let client = MangaDiscoveryHTTPClient(session: session)
        do {
            _ = try await client.data(for: URLRequest(url: URL(string: "https://api.example/rate")!))
            expect(false, "HTTP 429 must be rejected")
        } catch MangaDiscoveryError.rateLimited(let retryAfter) {
            expect(retryAfter == 7, "Retry-After seconds must be preserved")
        }

        do {
            _ = try await client.data(for: URLRequest(url: URL(string: "http://api.example/plain")!))
            expect(false, "non-HTTPS discovery requests must be rejected")
        } catch MangaDiscoveryError.invalidRequest {
        }

        MangaDiscoveryMockProtocol.handler = { request in
            (
                response(
                    for: request,
                    headers: ["Content-Length": String(MangaDiscoveryHTTPClient.maximumResponseBytes + 1)]
                ),
                Data("{}".utf8)
            )
        }
        do {
            _ = try await client.data(for: URLRequest(url: URL(string: "https://api.example/large")!))
            expect(false, "oversized declared responses must be rejected")
        } catch MangaDiscoveryError.responseTooLarge {
        }
    }

    private static func testIdentityAndMatching() {
        let exact = MangaDiscoveryTitleMatcher.automaticMatch(
            titles: ["ＤＡＮＤＡＤＡＮ！！"],
            candidates: [.init(id: "exact", title: "dandadan")]
        )
        expect(exact == "exact", "width, case, and punctuation normalization must permit exact matching")

        let ambiguous = MangaDiscoveryTitleMatcher.automaticMatch(
            titles: ["星"],
            candidates: [.init(id: "a", title: "星"), .init(id: "b", title: "星")]
        )
        expect(ambiguous == nil, "duplicate exact titles must remain a manual choice")

        let fuzzy = MangaDiscoveryTitleMatcher.automaticMatch(
            titles: ["Attack on Titan"],
            candidates: [
                .init(id: "best", title: "Attack on Titans"),
                .init(id: "other", title: "Attack Titan Junior"),
            ]
        )
        expect(fuzzy == "best", "a unique high-confidence long-title match should be automatic")

        let short = MangaDiscoveryTitleMatcher.automaticMatch(
            titles: ["星"],
            candidates: [.init(id: "short", title: "星々")]
        )
        expect(short == nil, "short titles must never use fuzzy automatic matching")
    }
}
