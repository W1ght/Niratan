// test-sources: Core/ZLibraryClient.swift NativeMac/DevelopmentDataIsolation.swift
import Foundation

private final class ZLibraryMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

@main
struct ZLibraryClientContractTests {
    static func main() async throws {
        try testBaseURLValidation()
        try testSearchForm()
        try testFileSizeParsing()
        try await testRedirectServerError()
        try await testRetryRateLimitAndExactResults()
        try await testDownloadQuotaSchemas()
        try await testBookDetailsSchemas()
        try await testAccountBookCollections()
        try await testLoginSearchAndDownload()
        print("Z-Library client contract tests passed")
    }

    private static func testFileSizeParsing() throws {
        let rawBytes = try JSONDecoder().decode(
            ZLibraryBook.self,
            from: Data(#"{"id":"1","hash":"a","title":"Bytes","extension":"epub","filesize":"1,572,864"}"#.utf8)
        )
        expect(rawBytes.fileSizeBytes == 1_572_864, "raw byte sizes should parse")
        let humanReadable = try JSONDecoder().decode(
            ZLibraryBook.self,
            from: Data(#"{"id":"2","hash":"b","title":"Megabytes","extension":"epub","filesize":"1.5 MB"}"#.utf8)
        )
        expect(humanReadable.fileSizeBytes == 1_572_864, "human-readable file sizes should parse for sorting")
    }

    private static func testAccountBookCollections() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZLibraryMockProtocol.self]
        let session = URLSession(configuration: configuration)
        var responseIndex = 0
        ZLibraryMockProtocol.handler = { request in
            defer { responseIndex += 1 }
            let url = try require(request.url)
            expect(request.value(forHTTPHeaderField: "Cookie")?.contains("remix_userid=42") == true, "account book collections should use the authenticated session")
            let data: Data
            if responseIndex == 0 {
                expect(url.path == "/eapi/book/recently", "recent-books endpoint changed")
                data = Data(#"{"books":[{"id":"8","hash":"recent","title":"Recent","extension":"epub"}]}"#.utf8)
            } else {
                expect(url.path == "/eapi/user/book/downloaded", "download-history endpoint changed")
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                expect(items.first(where: { $0.name == "page" })?.value == "2", "download history page should be encoded")
                expect(items.first(where: { $0.name == "limit" })?.value == "20", "download history limit should be encoded")
                data = Data(#"{"books":[{"id":"9","hash":"history","title":"History","extension":"epub"}],"pagination":{"total_items":"21"}}"#.utf8)
            }
            return (
                try require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )),
                data
            )
        }
        let credentials = ZLibrarySession(
            baseOrigin: "https://collections.example",
            userID: "42",
            userKey: "secret"
        )
        let client = try ZLibraryClient(
            baseURL: URL(string: credentials.baseOrigin)!,
            credentials: credentials,
            session: session
        )
        let recent = try await client.recentlyAdded()
        expect(recent.books.map(\.id) == ["8"], "recent books should decode")
        let history = try await client.downloadHistory(page: 2)
        expect(history.books.map(\.id) == ["9"] && history.totalCount == 21, "download history should decode with pagination")
    }

    private static func testBookDetailsSchemas() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZLibraryMockProtocol.self]
        let session = URLSession(configuration: configuration)
        var responseIndex = 0
        ZLibraryMockProtocol.handler = { request in
            expect(request.url?.path == "/eapi/book/7/abc", "book details endpoint changed")
            expect(request.value(forHTTPHeaderField: "Cookie")?.contains("remix_userid=42") == true, "book details should use the authenticated session")
            defer { responseIndex += 1 }
            let data: Data
            switch responseIndex {
            case 0:
                data = Data(#"{"book":{"publisher":"Test Press","isbn":"9781234567890","pages":320,"series":"Studies","description":"<p>A detailed book.</p>","categories":["History","Culture"]}}"#.utf8)
            case 1:
                data = Data(#"{"publisher":"Root Press","categories":"Reference"}"#.utf8)
            default:
                data = Data(#"{"book":{"id":"7","hash":"abc","title":"Test","extension":"epub","cover":"https://covers.example/7.jpg"}}"#.utf8)
            }
            return (
                try require(HTTPURLResponse(
                    url: try require(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )),
                data
            )
        }
        let credentials = ZLibrarySession(
            baseOrigin: "https://details.example",
            userID: "42",
            userKey: "secret"
        )
        let client = try ZLibraryClient(
            baseURL: URL(string: credentials.baseOrigin)!,
            credentials: credentials,
            session: session
        )
        let book = try JSONDecoder().decode(
            ZLibraryBook.self,
            from: Data(#"{"id":"7","hash":"abc","title":"Test","extension":"epub"}"#.utf8)
        )
        let nested = try await client.bookDetails(for: book)
        expect(nested.publisher == "Test Press" && nested.pages == "320", "nested details should decode lossy metadata")
        expect(nested.description == "A detailed book.", "detail descriptions should remove HTML tags")
        expect(nested.categories == ["History", "Culture"], "detail categories should decode arrays")
        let root = try await client.bookDetails(for: book)
        expect(root.publisher == "Root Press" && root.categories == ["Reference"], "root detail payloads should decode")
        let refreshed = try await client.refreshedBook(for: book)
        expect(refreshed.coverURL?.absoluteString == "https://covers.example/7.jpg", "book details should refresh stale history cover URLs")
    }

    private static func testDownloadQuotaSchemas() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZLibraryMockProtocol.self]
        let session = URLSession(configuration: configuration)
        var responseIndex = 0
        ZLibraryMockProtocol.handler = { request in
            expect(request.url?.path == "/eapi/user/profile", "download quota endpoint changed")
            expect(request.value(forHTTPHeaderField: "Cookie")?.contains("remix_userid=42") == true, "download quota should use the authenticated session")
            defer { responseIndex += 1 }
            let data = responseIndex == 0
                ? Data(#"{"user":{"downloads_today":"3","downloads_limit":"10"}}"#.utf8)
                : Data(#"{"downloads_today_limit":20,"downloads_today_left":"14"}"#.utf8)
            return (
                try require(HTTPURLResponse(
                    url: try require(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )),
                data
            )
        }
        let credentials = ZLibrarySession(
            baseOrigin: "https://profile.example",
            userID: "42",
            userKey: "secret"
        )
        let client = try ZLibraryClient(
            baseURL: URL(string: credentials.baseOrigin)!,
            credentials: credentials,
            session: session
        )
        let legacyQuota = try await client.downloadQuota()
        expect(legacyQuota == ZLibraryDownloadQuota(dailyLimit: 10, usedToday: 3, remaining: 7), "legacy quota fields should decode")
        let currentQuota = try await client.downloadQuota()
        expect(currentQuota == ZLibraryDownloadQuota(dailyLimit: 20, usedToday: 6, remaining: 14), "current quota fields should decode")
    }

    private static func testBaseURLValidation() throws {
        let normalized = try ZLibraryClient.normalizedBaseURL(
            URL(string: "https://Z-Library.SK/some/path?query=1")!
        )
        expect(normalized.absoluteString == "https://z-library.sk", "base URL should normalize to its HTTPS origin")
        do {
            _ = try ZLibraryClient.normalizedBaseURL(URL(string: "http://z-library.sk")!)
            fail("HTTP base URL should be rejected")
        } catch ZLibraryClientError.insecureURL {
        }
    }

    private static func testSearchForm() throws {
        let request = ZLibrarySearchRequest(
            query: "星の王子さま",
            page: 2,
            limit: 20,
            yearFrom: 1940,
            yearTo: 1950,
            languages: ["japanese"],
            extensions: ["epub"],
            exact: true
        )
        let names = request.formItems.map(\.name)
        expect(names == ["message", "page", "limit", "yearFrom", "yearTo", "languages[]", "extensions[]", "e"], "search form fields changed")
        expect(request.formItems.first(where: { $0.name == "extensions[]" })?.value == "EPUB", "EPUB filter should be canonical")
    }

    private static func testRedirectServerError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZLibraryMockProtocol.self]
        let session = URLSession(configuration: configuration)
        ZLibraryMockProtocol.handler = { request in
            let response = try require(HTTPURLResponse(
                url: try require(request.url),
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html"]
            ))
            return (response, Data("redirect".utf8))
        }
        let client = try ZLibraryClient(baseURL: URL(string: "https://redirect.example")!, session: session)
        do {
            _ = try await client.login(email: "reader@example.com", password: "password")
            fail("redirecting servers should not be treated as credential failures")
        } catch ZLibraryClientError.serverUnavailable {
        }
    }

    private static func testRetryRateLimitAndExactResults() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZLibraryMockProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestCount = 0
        ZLibraryMockProtocol.handler = { request in
            requestCount += 1
            let url = try require(request.url)
            if requestCount < 3 {
                return (
                    try require(HTTPURLResponse(
                        url: url,
                        statusCode: 503,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )),
                    Data(#"{"error":{"message":"temporary"}}"#.utf8)
                )
            }
            return (
                try require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )),
                Data(#"{"exactMatch":{"books":[{"id":"1","hash":"a","title":"Exact","extension":"epub","cover":"http://insecure.example/cover.jpg"}]},"books":[{"id":"1","hash":"a","title":"Exact","extension":"epub"},{"id":"2","hash":"b","title":"Related","extension":"epub"}]}"#.utf8)
            )
        }
        let client = try ZLibraryClient(baseURL: URL(string: "https://retry.example")!, session: session)
        let page = try await client.search(ZLibrarySearchRequest(query: "Exact"))
        expect(requestCount == 3, "transient search failures should retry twice")
        expect(page.books.map(\.id) == ["1", "2"], "exact and regular results should merge without duplicates")
        expect(page.books.first?.coverURL == nil, "insecure cover URLs should be rejected")

        ZLibraryMockProtocol.handler = { request in
            (
                try require(HTTPURLResponse(
                    url: try require(request.url),
                    statusCode: 429,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )),
                Data()
            )
        }
        do {
            _ = try await client.search(ZLibrarySearchRequest(query: "Limited"))
            fail("rate limiting should have a dedicated error")
        } catch ZLibraryClientError.rateLimited {
        }
    }

    private static func testLoginSearchAndDownload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZLibraryMockProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestIndex = 0

        ZLibraryMockProtocol.handler = { request in
            defer { requestIndex += 1 }
            let url = try require(request.url)
            let response = try require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": requestIndex == 3 ? "application/epub+zip" : "application/json"]
            ))

            switch requestIndex {
            case 0:
                expect(url.path == "/eapi/user/login", "login endpoint changed")
                let body = String(data: bodyData(from: request), encoding: .utf8) ?? ""
                expect(body.contains("email=reader@example.com"), "login email should be form encoded")
                expect(body.contains("password=p@ss%26word"), "login password should be form encoded")
                return (response, Data(#"{"success":1,"user":{"id":42,"remix_userkey":"secret"}}"#.utf8))
            case 1:
                expect(url.path == "/eapi/book/search", "search endpoint changed")
                expect(request.value(forHTTPHeaderField: "Cookie")?.contains("remix_userid=42") == true, "authenticated search should send the session cookie")
                let body = String(data: bodyData(from: request), encoding: .utf8) ?? ""
                expect(body.contains("extensions%5B%5D=EPUB"), "search should request EPUB only")
                return (response, Data(#"{"books":[{"id":"7","hash":"abc","title":"Test Book","author":"Author","year":2024,"language":"english","extension":"epub","filesize":"1 MB","cover":"https://images.example/7.jpg","rating":5}],"pagination":{"total_items":"1"}}"#.utf8))
            case 2:
                expect(url.path == "/eapi/book/7/abc/file", "download-link endpoint changed")
                return (response, Data(#"{"file":{"downloadLink":"https://z-library.sk/files/7.epub"}}"#.utf8))
            case 3:
                expect(url.path == "/files/7.epub", "EPUB download URL changed")
                return (response, Data([0x50, 0x4B, 0x03, 0x04, 0x00]))
            default:
                throw URLError(.badServerResponse)
            }
        }

        let client = try ZLibraryClient(baseURL: URL(string: "https://z-library.sk")!, session: session)
        let credentials = try await client.login(email: "reader@example.com", password: "p@ss&word")
        expect(credentials.userID == "42", "numeric user IDs should decode losslessly")

        let page = try await client.search(ZLibrarySearchRequest(query: "Test", extensions: ["EPUB"]))
        expect(page.totalCount == 1, "string pagination totals should decode losslessly")
        let book = try require(page.books.first)
        expect(book.year == "2024" && book.rating == "5", "numeric metadata should decode losslessly")

        let downloaded = try await client.downloadEPUB(book)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        expect(downloaded.pathExtension == "epub", "downloaded book should have an EPUB extension")
        expect(FileManager.default.fileExists(atPath: downloaded.path), "downloaded EPUB should exist")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw URLError(.badServerResponse) }
        return value
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1024)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
