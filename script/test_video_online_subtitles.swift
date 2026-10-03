// test-sources: Features/Video/Subtitles/JimakuAPIClient.swift Features/Video/Subtitles/OnlineSubtitleBrowserModel.swift Features/Video/Subtitles/OnlineSubtitleGrouping.swift Features/Video/Subtitles/OnlineSubtitleClients.swift Features/Video/Remote/RemoteVideoSource.swift Models/Subtitle.swift Features/Video/Subtitles/AJATTSubtitleCatalogClient.swift Features/Video/Subtitles/JimakuCredentialStore.swift Features/Video/Remote/BoundedURLSessionData.swift Features/Video/Remote/YouTubeURLParser.swift NativeMac/DevelopmentDataIsolation.swift
import Foundation

private final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

private actor Gate {
    var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { continuations.append($0) } }
    func release() { continuations.forEach { $0.resume() }; continuations = [] }
    var count: Int { continuations.count }
}

@main struct Tests {
    @MainActor static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for model")
    }

    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let session = URLSession(configuration: configuration)
        let client = OpenSubtitlesClient(session: session)
        Stub.payload = Data(#"{"total_pages":2,"data":[{"attributes":{"language":"ja","release":"Test release","files":[{"file_id":123,"file_name":"test.ass"},{"file_id":123,"file_name":"duplicate.ass"}]}}]}"#.utf8)
        let response = try await client.search(query: "フリーレン", language: "zh", season: 2, episode: 3, apiKey: "fixture-key")
        expect(response.files.count == 1 && response.totalPages == 2, "Search must deduplicate files and retain pagination")
        let request = Stub.requests.last!
        let parameters = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        expect(parameters.contains(URLQueryItem(name: "languages", value: "zh-cn,zh-tw")), "Chinese languages must expand")
        expect(parameters.contains(URLQueryItem(name: "season_number", value: "2")), "Season must be sent")
        expect(parameters.contains(URLQueryItem(name: "episode_number", value: "3")), "Episode must be sent")
        expect(request.value(forHTTPHeaderField: "Api-Key") == "fixture-key", "Official API needs key header")
        expect(Stub.requests.allSatisfy { $0.httpMethod == "GET" }, "Search must never consume download quota")
        Stub.payload = Data(#"{"link":"https://www.opensubtitles.com/download/temporary"}"#.utf8)
        let option = try await client.downloadOption(for: response.files[0], apiKey: "fixture-key")
        expect(option.format == .srt && option.httpHeaders.isEmpty, "Download conversion must match parser; no credentials on temporary URL")
        expect(Stub.requests.last?.httpMethod == "POST", "Explicit download must POST")
        for url in ["http://www.opensubtitles.com/file", "https://opensubtitles.com.evil.test/file", "https://user:pass@www.opensubtitles.com/file", "https://localhost/file"] {
            expect(!OpenSubtitlesClient.validDownloadURL(URL(string: url)!), "Reject untrusted URL: \(url)")
        }
        Stub.payload = Data(#"{"link":"https://evil.test/subtitle.srt"}"#.utf8)
        do { _ = try await client.downloadOption(for: response.files[0], apiKey: "fixture-key"); fatalError("Unsafe URL accepted") }
        catch OnlineSubtitleError.invalidResponse {}
        for code in [401, 406, 429] {
            Stub.status = code
            do { _ = try await client.search(query: "test", language: "ja", season: nil, episode: nil, apiKey: "fixture-key"); fatalError("HTTP failure ignored") }
            catch OnlineSubtitleError.http(let value) { expect(value == code, "Preserve service failure code") }
        }
        Stub.status = 200
        Stub.payload = Data(#"{"data":{"Page":{"media":[{"id":154587,"title":{"romaji":"Sousou no Frieren","english":"Frieren: Beyond Journey's End","native":"葬送のフリーレン"},"synonyms":["葬送的芙莉莲","Sousou no Frieren"],"seasonYear":2023,"format":"TV"}]}}}"#.utf8)
        let matches = try await SubtitleSeriesClient(session: session).search("葬送的芙莉莲")
        expect(matches[0].aliases.count == 4 && matches[0].aliases.contains("Sousou no Frieren"), "Use canonical romaji and multilingual aliases, deduplicated")
        expect(Stub.requests.last?.value(forHTTPHeaderField: "Api-Key") == nil, "AniList must never receive provider key")

        let gate = Gate()
        let model = OnlineSubtitleBrowserModel(seriesSearch: { _ in matches }, providerSearch: { provider, request in
            expect(request.anilistID == 154587 && request.aliases.contains("Sousou no Frieren"), "All providers must receive resolved identity and aliases")
            if provider == .jimaku { throw OnlineSubtitleError.http(401) }
            if provider == .ajatt { await gate.wait() }
            return ([.openSubtitles(OpenSubtitlesFile(fileID: 1, name: request.query, language: "ja", release: nil))], 1, request.query)
        })
        model.query = "葬送的芙莉莲"
        model.search(providers: Set(OnlineSubtitleProvider.allCases))
        await waitUntil { model.results[.openSubtitles]?.count == 1 && model.failures[.jimaku] != nil }
        expect(model.searching.contains(.ajatt), "Results must appear before slower source finishes")
        model.prepare(JimakuMediaSuggestion(sourceIdentifier: "next", mediaTitle: "Next episode"))
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        expect(model.results.isEmpty && model.query == "Next episode", "Old search must not write into new media session")
        let fallback = OnlineSubtitleBrowserModel(seriesSearch: { _ in throw OnlineSubtitleError.http(429) }, providerSearch: { _, request in
            expect(request.aliases.isEmpty && request.anilistID == nil, "Unavailable AniList must use raw title")
            return ([], 0, request.query)
        })
        fallback.query = "test"
        fallback.search(providers: [.ajatt])
        await waitUntil { fallback.results[.ajatt] != nil }
        expect(fallback.notice != nil, "Surface alias lookup degradation")
        fallback.episodeText = "invalid"
        fallback.search(providers: [.ajatt])
        expect(fallback.searching.isEmpty, "Invalid episode must not start requests")
        func candidate(_ name: String, id: String = "show", provider: OnlineSubtitleProvider = .jimaku) -> OnlineSubtitleCandidate {
            let file = JimakuSubtitleFile(name: name, size: 100, lastModified: "", downloadURL: URL(string: "https://jimaku.cc/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)")!, format: .srt)
            return OnlineSubtitleCandidate(file: .jimaku(file), collectionID: id, collectionName: "Show")
        }
        let batch = [candidate("[Group] Show - 02.ja.srt"), candidate("[Group] Show - 01.ja.srt"),
                     candidate("[Group] Show - 01.en.srt"), candidate("[Other] Show - 01.ja.srt")]
        let groups = OnlineSubtitleGroup.build(batch + [batch[0]])
        expect(groups.count == 3, "Group episodes by language and release version, deduplicate identical source files")
        let japanese = OnlineSubtitleGroup.build(batch, language: "ja", version: "Group")
        expect(japanese.count == 1 && japanese[0].candidates.count == 2, "Language and version filters must work across results")
        expect(japanese[0].candidates[0].episode == 1, "Sort episode files numerically within a version")
        expect(OnlineSubtitleGroup.build(batch, filter: "Other").count == 1, "Filter filenames locally")
        expect(OnlineSubtitleGroup.build([batch[0], candidate(batch[0].name, id: "another-show")]).count == 1, "Deduplicate the same download across title matches")
        expect(candidate("[1080p] Show - 01.srt").version.isEmpty, "Resolution must not be treated as a release group")
        expect(candidate("[DEADBEEF] Show - 01.srt").version.isEmpty, "CRC must not be treated as a release group")
        expect(candidate("[EN] Show - 01.srt").language == "en", "Infer labeled catalog subtitle language")
        print("Online subtitle client and aggregation tests passed")
    }
}
