// test-sources: Features/Manga/SuwayomiClient.swift Models/Suwayomi.swift
import Foundation

private final class SuwayomiMockProtocol:
    URLProtocol,
    @unchecked Sendable
{
    static let lock = NSLock()
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let result = try Self.lock.withLock {
                try Self.handler?(request)
            }
            guard let result else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(
                self,
                didReceive: result.0,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(
                &buffer,
                maxLength: buffer.count
            )
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@main
private struct SuwayomiConnectorContractTests {
    static func main() async throws {
        try testURLNormalization()
        try await testRESTConnector()
        try await testUILogin()
        print("Suwayomi connector contract tests passed")
    }

    private static func testURLNormalization() throws {
        let root = try SuwayomiClient.normalizedServerURL(
            " HTTPS://reader.example.test/suwayomi/api/v1/ "
        )
        expect(
            root.absoluteString
                == "https://reader.example.test/suwayomi",
            "server URL normalization must retain reverse-proxy paths"
        )
        do {
            _ = try SuwayomiClient.normalizedServerURL(
                "file:///tmp/suwayomi"
            )
            fail("non-HTTP server URLs must be rejected")
        } catch SuwayomiConnectorError.unsupportedServerScheme {
            // Expected.
        }

        let canonicalBasic = SuwayomiServerConfiguration(
            serverURL: "https://reader.example.test/suwayomi/",
            authMode: .basic,
            username: " reader "
        )
        let equivalentBasic = SuwayomiServerConfiguration(
            serverURL: "HTTPS://reader.example.test/suwayomi/api/v1",
            authMode: .basic,
            username: "reader"
        )
        let canonicalBasicIdentity =
            try SuwayomiClient.credentialIdentity(for: canonicalBasic)
        let equivalentBasicIdentity =
            try SuwayomiClient.credentialIdentity(for: equivalentBasic)
        expect(
            canonicalBasicIdentity == equivalentBasicIdentity,
            "canonical-equivalent connections may retain their credential"
        )
        let otherServerIdentity =
            try SuwayomiClient.credentialIdentity(
                for: SuwayomiServerConfiguration(
                    serverURL: "https://other.example.test/suwayomi",
                    authMode: .basic,
                    username: "reader"
                )
            )
        expect(
            canonicalBasicIdentity != otherServerIdentity,
            "credentials must not carry across Suwayomi servers"
        )
        let bearerIdentity = try SuwayomiClient.credentialIdentity(
            for: SuwayomiServerConfiguration(
                serverURL: canonicalBasic.serverURL,
                authMode: .bearer,
                username: "reader"
            )
        )
        expect(
            canonicalBasicIdentity != bearerIdentity,
            "credentials must not carry across authentication modes"
        )
        let otherUserIdentity =
            try SuwayomiClient.credentialIdentity(
                for: SuwayomiServerConfiguration(
                    serverURL: canonicalBasic.serverURL,
                    authMode: .basic,
                    username: "another-reader"
                )
            )
        expect(
            canonicalBasicIdentity != otherUserIdentity,
            "user credentials must not carry across usernames"
        )
        let bearer = SuwayomiServerConfiguration(
            serverURL: canonicalBasic.serverURL,
            authMode: .bearer,
            username: "ignored"
        )
        let ignoredBearerIdentity =
            try SuwayomiClient.credentialIdentity(for: bearer)
        let otherIgnoredBearerIdentity =
            try SuwayomiClient.credentialIdentity(
                for: SuwayomiServerConfiguration(
                    serverURL: canonicalBasic.serverURL,
                    authMode: .bearer,
                    username: "also ignored"
                )
            )
        expect(
            ignoredBearerIdentity == otherIgnoredBearerIdentity,
            "irrelevant bearer usernames must not invalidate a token"
        )

        let legacyConfiguration = try JSONDecoder().decode(
            SuwayomiServerConfiguration.self,
            from: Data(
                #"""
                {
                  "serverURL":"https://reader.example.test",
                  "authMode":"basic",
                  "username":"reader"
                }
                """#.utf8
            )
        )
        expect(
            legacyConfiguration.credentialID == nil,
            "pre-slot Suwayomi configurations must remain decodable"
        )
        var slottedConfiguration = legacyConfiguration
        slottedConfiguration.credentialID = "credential-slot"
        let decodedSlottedConfiguration = try JSONDecoder().decode(
            SuwayomiServerConfiguration.self,
            from: JSONEncoder().encode(slottedConfiguration)
        )
        expect(
            decodedSlottedConfiguration.credentialID
                == "credential-slot",
            "credential slot references must round-trip with configuration"
        )
    }

    private static func testRESTConnector() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuwayomiMockProtocol.self]
        let session = URLSession(configuration: configuration)
        var progressBody: String?
        var sawBasicAuth = false
        var sawExtendedPageTimeout = false
        let sourceJSON = #"""
        [{
          "id":"1234","name":"Example","lang":"en",
          "iconUrl":"/api/v1/source/1234/icon",
          "supportsLatest":true,"isConfigurable":false,
          "isNsfw":false,"displayName":"Example (EN)",
          "baseUrl":"https://example.test"
        }]
        """#
        let mangaJSON = #"""
        {
          "id":7,"sourceId":"1234","url":"/series/7",
          "title":"Fixture Manga","thumbnailUrl":"/api/v1/manga/7/thumbnail",
          "thumbnailUrlLastFetched":0,"initialized":true,
          "artist":null,"author":"Author","description":"Description",
          "genre":["Action"],"status":"ONGOING","inLibrary":true,
          "inLibraryAt":1,"realUrl":"https://example.test/series/7",
          "lastReadAt":0,"chapterCount":1
        }
        """#
        let chapterJSON = #"""
        {
          "id":11,"url":"/chapter/1","name":"Chapter 1",
          "uploadDate":0,"chapterNumber":1.0,"scanlator":null,
          "mangaId":7,"read":false,"bookmarked":false,
          "lastPageRead":0,"lastReadAt":0,"index":1,
          "fetchedAt":0,"realUrl":null,"downloaded":false,
          "pageCount":2
        }
        """#

        SuwayomiMockProtocol.handler = { request in
            let url = try require(request.url)
            sawBasicAuth =
                request.value(forHTTPHeaderField: "Authorization")
                    == "Basic dXNlcjpwYXNz"
            let data: Data
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/proxy/api/v1/source/list"):
                data = Data(sourceJSON.utf8)
            case ("GET", "/proxy/api/v1/source/1234/popular/1"),
                 ("GET", "/proxy/api/v1/source/1234/latest/2"):
                data = Data(
                    #"{"mangaList":[\#(mangaJSON)],"hasNextPage":false}"#
                        .utf8
                )
            case ("GET", "/proxy/api/v1/source/1234/search"):
                let query = URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []
                expect(
                    query.first { $0.name == "searchTerm" }?.value
                        == "日本 語",
                    "search terms must be URL encoded"
                )
                expect(
                    query.first { $0.name == "pageNum" }?.value == "3",
                    "search pages must use Suwayomi's 1-based page number"
                )
                data = Data(
                    #"{"mangaList":[\#(mangaJSON)],"hasNextPage":true}"#
                        .utf8
                )
            case ("GET", "/proxy/api/v1/manga/7/full"):
                expect(
                    url.query == "onlineFetch=true",
                    "detail refresh must request onlineFetch"
                )
                data = Data(mangaJSON.utf8)
            case ("GET", "/proxy/api/v1/manga/7/chapters"):
                data = Data("[\(chapterJSON)]".utf8)
            case ("GET", "/proxy/api/v1/manga/7/chapter/1"):
                data = Data(chapterJSON.utf8)
            case ("GET", "/proxy/api/v1/category"):
                data = Data(
                    #"[{"id":0,"name":"Default","default":true}]"#
                        .utf8
                )
            case ("GET", "/proxy/api/v1/category/0"):
                data = Data("[\(mangaJSON)]".utf8)
            case ("GET", "/proxy/api/v1/manga/7/thumbnail"):
                data = Data([0xFF, 0xD8, 0xFF])
            case ("GET", "/proxy/api/v1/manga/7/chapter/1/page/0"):
                sawExtendedPageTimeout = request.timeoutInterval == 120
                data = Data([0x89, 0x50, 0x4E, 0x47])
            case ("GET", "/proxy/api/v1/manga/7/library"),
                 ("DELETE", "/proxy/api/v1/manga/7/library"):
                data = Data()
            case ("PATCH", "/proxy/api/v1/manga/7/chapter/1"):
                progressBody = SuwayomiMockProtocol.bodyData(
                    for: request
                ).flatMap {
                    String(data: $0, encoding: .utf8)
                }
                data = Data()
            default:
                fail(
                    "unexpected Suwayomi request: "
                        + "\(request.httpMethod ?? "GET") \(url.absoluteString)"
                )
            }
            return (
                try require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )
                ),
                data
            )
        }

        let client = try SuwayomiClient(
            configuration: SuwayomiServerConfiguration(
                serverURL: "http://server.test/proxy",
                authMode: .basic,
                username: "user"
            ),
            credentials: SuwayomiCredentials(secret: "pass"),
            session: session
        )
        let sources = try await client.sources()
        expect(sources.first?.id == "1234", "source list must decode")
        expect(sawBasicAuth, "Basic credentials must be sent")
        let popular = try await client.popular(
            sourceID: "1234",
            page: 0
        )
        expect(
            popular.mangaList.first?.title == "Fixture Manga",
            "popular browsing must clamp to page 1"
        )
        _ = try await client.latest(sourceID: "1234", page: 2)
        let search = try await client.search(
            sourceID: "1234",
            query: "日本 語",
            page: 3
        )
        expect(search.hasNextPage, "search pagination must decode")
        let manga = try await client.manga(id: 7, onlineFetch: true)
        expect(manga.mangaDescription == "Description", "details must decode")
        let chapters = try await client.chapters(
            mangaID: 7,
            onlineFetch: true
        )
        expect(chapters.first?.index == 1, "chapters must decode")
        let prepared = try await client.prepareChapter(
            mangaID: 7,
            sourceOrder: 1
        )
        expect(
            prepared.pageCount == 2,
            "chapter preparation must return its page count"
        )
        let library = try await client.library()
        expect(
            library.map(\.id) == [7],
            "category-backed Suwayomi library must de-duplicate manga"
        )
        let thumbnail = try await client.thumbnailData(mangaID: 7)
        expect(
            thumbnail.count == 3,
            "covers must use the authenticated server proxy"
        )
        let page = try await client.pageData(
            mangaID: 7,
            sourceOrder: 1,
            pageIndex: 0
        )
        expect(
            page.count == 4,
            "pages must use the authenticated server proxy"
        )
        expect(
            sawExtendedPageTimeout,
            "slow page images must receive the longer bounded timeout"
        )
        try await client.setLibrary(mangaID: 7, isInLibrary: true)
        try await client.setLibrary(mangaID: 7, isInLibrary: false)
        try await client.updateProgress(
            chapter: try require(chapters.first),
            pageIndex: 1,
            completed: true
        )
        let progressItems = progressBody?
            .split(separator: "&")
            .map(String.init) ?? []
        expect(
            Set(progressItems) == ["lastPageRead=1", "read=true"],
            "chapter progress must be sent as form data"
        )
        progressBody = nil
        try await client.updateProgress(
            chapter: try require(chapters.first),
            pageIndex: 0,
            completed: false
        )
        expect(
            progressBody == "lastPageRead=0",
            "ordinary progress must not mark an already-read chapter unread"
        )
    }

    private static func testUILogin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuwayomiMockProtocol.self]
        let session = URLSession(configuration: configuration)
        var loginCount = 0
        var protectedRequestCount = 0
        var sawRetriedPageTimeout = false
        SuwayomiMockProtocol.handler = { request in
            let url = try require(request.url)
            let data: Data
            let statusCode: Int
            if url.path == "/api/graphql" {
                loginCount += 1
                expect(
                    request.httpMethod == "POST",
                    "UI login must use GraphQL POST"
                )
                data = Data(
                    """
                    {"data":{"login":{"accessToken":"token\(loginCount)","refreshToken":"refresh"}}}
                    """.utf8
                )
                statusCode = 200
            } else {
                protectedRequestCount += 1
                expect(
                    request.value(
                        forHTTPHeaderField: "Authorization"
                    ) == "Bearer token\(loginCount)",
                    "UI login access token must authorize REST requests"
                )
                if protectedRequestCount == 1 {
                    data = Data()
                    statusCode = 401
                } else {
                    if url.path.hasSuffix("/page/0") {
                        sawRetriedPageTimeout =
                            request.timeoutInterval == 120
                        data = Data([0xFF, 0xD8, 0xFF])
                    } else {
                        data = Data("[]".utf8)
                    }
                    statusCode = 200
                }
            }
            return (
                try require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: statusCode,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )
                ),
                data
            )
        }
        let client = try SuwayomiClient(
            configuration: SuwayomiServerConfiguration(
                serverURL: "http://server.test",
                authMode: .uiLogin,
                username: "user"
            ),
            credentials: SuwayomiCredentials(secret: "pass"),
            session: session
        )
        let page = try await client.pageData(
            mangaID: 7,
            sourceOrder: 1,
            pageIndex: 0
        )
        expect(page.count == 3, "UI login retries must return page data")
        _ = try await client.sources()
        expect(
            loginCount == 2,
            "UI login must refresh once after an authenticated 401"
        )
        expect(
            sawRetriedPageTimeout,
            "UI login retries must preserve the page request timeout"
        )
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else { fail(message) }
}

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

private func require<Value>(_ value: Value?) throws -> Value {
    guard let value else { throw URLError(.badServerResponse) }
    return value
}
