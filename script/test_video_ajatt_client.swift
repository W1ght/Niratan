// test-sources: Features/Video/Subtitles/AJATTSubtitleCatalogClient.swift Features/Video/Remote/BoundedURLSessionData.swift Features/Video/Remote/RemoteVideoSource.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift
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

private let catalogHTML = """
<!doctype html><html><head><meta charset="utf-8"></head><body><table class="entries_table index_table"><tbody>
<tr data-timestamp="1787963826" data-entry-type="anime_tv">
  <td class="entry_name"><a href="anime_tv/re.zero-kara-hajimeru-isekai-seikatsu-4th-season.html">Re:Zero kara Hajimeru Isekai Seikatsu 4th Season</a></td>
  <td class="entry_type">Anime TV</td>
  <td class="english_name">Re:ZERO -Starting Life in Another World- Season 4</td>
  <td class="japanese_name">Re:ゼロから始める異世界生活 4th season</td>
</tr>
<tr data-timestamp="1700000000" data-entry-type="anime_movie">
  <td class="entry_name"><a href="anime_movie/violet-evergarden.html">Violet Evergarden</a></td>
  <td class="entry_type">Anime movie</td>
  <td class="english_name">Violet Evergarden: The Movie</td>
  <td class="japanese_name">劇場版 ヴァイオレット・エヴァーガーデン</td>
</tr>
</tbody></table></body></html>
"""

private let entryHTML = """
<!doctype html><html><head><meta charset="utf-8"></head><body>
<section class="group_srt"><table><tr data-timestamp="1" data-file-size="1200"><td><input class="file-checkbox" data-download-url="https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/refs/heads/main/subtitles/anime_tv/ReZero/ReZero.S04E07.srt" data-filename="ReZero.S04E07.srt"></td></tr></table></section>
<section class="group_all"><table>
<tr data-timestamp="4" data-file-size="1200"><td><input class="file-checkbox" data-download-url="https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/refs/heads/main/subtitles/anime_tv/ReZero/ReZero.S04E07.srt" data-filename="ReZero.S04E07.srt"></td></tr>
<tr data-timestamp="3" data-file-size="10038147"><td><input class="file-checkbox" data-download-url="https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/refs/heads/main/subtitles/anime_tv/ReZero/ReZero.S04E07.ass" data-filename="ReZero.S04E07.ass"></td></tr>
<tr data-timestamp="2" data-file-size="900"><td><input class="file-checkbox" data-download-url="https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/refs/heads/main/subtitles/anime_tv/ReZero/ReZero.EP08.ssa" data-filename="ReZero.EP08.ssa"></td></tr>
<tr data-timestamp="1" data-file-size="800"><td><input class="file-checkbox" data-download-url="https://evil.example/ReZero.S04E07.srt" data-filename="untrusted.S04E07.srt"></td></tr>
<tr data-timestamp="1" data-file-size="11000000"><td><input class="file-checkbox" data-download-url="https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/refs/heads/main/subtitles/anime_tv/ReZero/oversized.S04E07.ass" data-filename="oversized.S04E07.ass"></td></tr>
</table></section></body></html>
"""

private let dramaCatalogHTML = """
<!doctype html><html><head><meta charset="utf-8"></head><body><table class="entries_table index_table"><tbody>
<tr data-timestamp="1700000001" data-entry-type="drama_tv">
  <td class="entry_name"><a href="drama_tv/hanzawa-naoki.html">Hanzawa Naoki</a></td>
  <td class="entry_type">Drama TV</td>
  <td class="english_name">Hanzawa Naoki</td>
  <td class="japanese_name">半沢直樹</td>
</tr>
</tbody></table></body></html>
"""

@main
private enum VideoAJATTClientTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = AJATTSubtitleCatalogClient(
            session: session,
            baseURL: URL(string: "https://subtitles.ajatt.test/")!
        )

        StubURLProtocol.reset(responses: [
            "/index.html": .init(
                statusCode: 200,
                data: data(catalogHTML),
                headers: ["Content-Type": "text/html; charset=utf-8"]
            ),
        ])
        let entries = try await client.searchEntries(query: "re zero", kind: .anime)
        expect(entries.count == 1, "search should match normalized punctuation and spaces")
        expect(entries.first?.japaneseName == "Re:ゼロから始める異世界生活 4th season", "Japanese metadata should be retained")
        expect(entries.first?.secondaryName == "Re:ゼロから始める異世界生活 4th season", "Japanese metadata should be preferred as secondary copy")
        expect(StubURLProtocol.requests().count == 1, "the catalog should load once")

        let cached = try await client.searchEntries(query: "Violet Evergarden", kind: .anime)
        expect(cached.first?.kind == .animeMovie, "a cached catalog should support subsequent local searches")
        expect(StubURLProtocol.requests().count == 1, "subsequent searches should reuse the bounded catalog cache")

        StubURLProtocol.reset(responses: [
            "/drama.html": .init(
                statusCode: 200,
                data: data(dramaCatalogHTML),
                headers: ["Content-Type": "text/html; charset=utf-8"]
            ),
        ])
        let dramaEntries = try await client.searchEntries(query: "半沢直樹", kind: .liveAction)
        expect(dramaEntries.first?.kind == .dramaTV, "live-action search should use the drama catalog and retain its type")
        expect(StubURLProtocol.requests().first?.url?.path == "/drama.html", "live-action search should load the drama catalog page")

        guard let entry = entries.first else {
            expect(false, "test entry should exist")
            return
        }
        StubURLProtocol.reset(responses: [
            "/anime_tv/re.zero-kara-hajimeru-isekai-seikatsu-4th-season.html": .init(
                statusCode: 200,
                data: data(entryHTML),
                headers: ["Content-Type": "text/html; charset=utf-8"]
            ),
        ])
        let episodeFiles = try await client.files(for: entry, episode: 7)
        expect(episodeFiles.count == 2, "episode filtering should keep SRT and large valid ASS without duplicate format-section rows")
        expect(Set(episodeFiles.map(\.format)) == Set([.srt, .ass]), "supported AJATT formats should map into the existing parser")
        expect(episodeFiles.contains { $0.size == 10_038_147 }, "valid mirror files near 10 MB should be retained")
        expect(!episodeFiles.contains { $0.downloadURL.host == "evil.example" }, "untrusted download hosts should be rejected")

        let allFiles = try await client.files(for: entry, episode: nil)
        expect(allFiles.count == 3, "unfiltered file browsing should include SRT, ASS, and SSA only once")
        expect(Set(allFiles.map(\.format)) == Set([.srt, .ass, .ssa]), "the all-formats section should retain SSA")

        print("Video AJATT client tests passed")
    }
}
