import Foundation
import Observation

nonisolated enum OnlineSubtitleProvider: String, CaseIterable, Identifiable, Sendable {
    case ajatt = "AJATT"
    case jimaku = "Jimaku"
    case openSubtitles = "OpenSubtitles"
    var id: String { rawValue }
}

nonisolated enum OnlineSubtitleEntry: Identifiable, Sendable {
    case ajatt(AJATTEntry)
    case jimaku(JimakuEntry)
    case openSubtitles(OpenSubtitlesFile)
    var id: String {
        switch self {
        case .ajatt(let entry): "ajatt:\(entry.id)"
        case .jimaku(let entry): "jimaku:\(entry.id)"
        case .openSubtitles(let file): file.id
        }
    }
    var name: String {
        switch self {
        case .ajatt(let entry): entry.name
        case .jimaku(let entry): entry.name
        case .openSubtitles(let file): file.name
        }
    }

}

nonisolated enum OnlineSubtitleFile: Identifiable, Sendable {
    case ajatt(AJATTSubtitleFile)
    case jimaku(JimakuSubtitleFile)
    case openSubtitles(OpenSubtitlesFile)
    var id: String {
        switch self {
        case .ajatt(let file): "ajatt:\(file.id)"
        case .jimaku(let file): "jimaku:\(file.id)"
        case .openSubtitles(let file): file.id
        }
    }
    var name: String {
        switch self {
        case .ajatt(let file): file.name
        case .jimaku(let file): file.name
        case .openSubtitles(let file): file.name
        }
    }
}

nonisolated struct OnlineSubtitleSearchRequest: Sendable {
    let query: String
    let aliases: [String]
    let kind: JimakuSearchKind
    let language: String
    let episode: Int?
    let season: Int?
    let anilistID: Int?
}

@Observable @MainActor
final class OnlineSubtitleBrowserModel {
    typealias ProviderSearch = @Sendable (OnlineSubtitleProvider, OnlineSubtitleSearchRequest) async throws -> ([OnlineSubtitleEntry], Int, String)
    private let seriesSearch: @Sendable (String) async throws -> [SubtitleSeries]
    private let providerSearch: ProviderSearch
    private let candidateLoader: @Sendable ([OnlineSubtitleEntry], Int?) async throws -> [OnlineSubtitleCandidate]

    init(
        seriesSearch: @escaping @Sendable (String) async throws -> [SubtitleSeries] = { try await SubtitleSeriesClient.shared.search($0) },
        providerSearch: @escaping ProviderSearch = { try await OnlineSubtitleBrowserModel.fetch($0, request: $1) },
        candidateLoader: @escaping @Sendable ([OnlineSubtitleEntry], Int?) async throws -> [OnlineSubtitleCandidate] = {
            try await OnlineSubtitleBrowserModel.loadCandidates($0, episode: $1)
        }
    ) {
        self.seriesSearch = seriesSearch
        self.providerSearch = providerSearch
        self.candidateLoader = candidateLoader
    }

    var query = ""
    var episodeText = ""
    var kind: JimakuSearchKind = .anime
    var language = ""
    private(set) var series: [SubtitleSeries] = []
    private(set) var selectedSeriesID: Int?
    private(set) var candidates: [OnlineSubtitleProvider: [OnlineSubtitleCandidate]] = [:]
    private(set) var results: [OnlineSubtitleProvider: [OnlineSubtitleEntry]] = [:]
    private(set) var failures: [OnlineSubtitleProvider: String] = [:]
    private(set) var searching: Set<OnlineSubtitleProvider> = []
    private(set) var resolvingSeries = false
    private(set) var notice: String?
    private(set) var hasSearched = false
    private(set) var downloading = false
    private(set) var openSubtitlesPage = 0
    private(set) var openSubtitlesTotalPages = 0
    private var generation = 0
    private var work: Task<Void, Never>?
    private var fileWork: Task<Void, Never>?
    private var searchAliases: [String] = []
    private var searchKind: JimakuSearchKind = .anime
    private var searchLanguage = "ja"
    private var searchEpisode: Int?
    private var searchSeason: Int?
    private var openSubtitlesQuery = ""

    func prepare(_ suggestion: JimakuMediaSuggestion) {
        cancel()
        query = suggestion.query
        episodeText = suggestion.episode.map(String.init) ?? ""
        series = []
        selectedSeriesID = nil
        results = [:]
        candidates = [:]
        failures = [:]
        notice = nil
        hasSearched = false
    }

    func cancel() {
        generation &+= 1
        work?.cancel()
        fileWork?.cancel()
        searching = []
        resolvingSeries = false
        downloading = false
    }

    func search(providers: Set<OnlineSubtitleProvider>, selectedSeries: SubtitleSeries? = nil) {
        cancel()
        guard !providers.isEmpty else { return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 300 else {
            notice = String(localized: "Enter a title to search subtitles.")
            return
        }
        guard let episode = Self.number(episodeText) else {
            notice = String(localized: "Enter an episode number from 0 to 9999.")
            return
        }
        let current = generation
        let season: Int? = nil
        searchKind = kind
        searchLanguage = language
        searchEpisode = episode
        searchSeason = season
        results = [:]
        candidates = [:]
        failures = [:]
        notice = nil
        hasSearched = true
        openSubtitlesPage = 0
        openSubtitlesTotalPages = 0
        if selectedSeries == nil { series = []; selectedSeriesID = nil }
        work = Task {
            guard current == generation, !Task.isCancelled else { return }
            var selection = selectedSeries
            if kind == .anime && selection == nil {
                resolvingSeries = true
                do {
                    let matches = try await seriesSearch(query)
                    guard current == generation, !Task.isCancelled else { return }
                    series = matches
                    selection = matches.first
                } catch {
                    guard current == generation, !Task.isCancelled else { return }
                    notice = String(localized: "Title matching is temporarily unavailable. Searching with the entered title.")
                }
                resolvingSeries = false
            }
            selectedSeriesID = selection?.id
            searchAliases = selection?.aliases ?? []
            searching = providers
            // Each source completes independently; an unavailable source cannot discard other results.
            await withTaskGroup(of: (OnlineSubtitleProvider, [OnlineSubtitleEntry], String?, Int, String, [OnlineSubtitleCandidate]).self) { group in
                for provider in providers {
                    let aliases = searchAliases
                    let kind = searchKind
                    let language = searchLanguage
                    let anilistID = selection?.id
                    let fetch = providerSearch
                    let loadCandidates = candidateLoader
                    group.addTask {
                        do {
                            let result = try await fetch(provider, OnlineSubtitleSearchRequest(query: query, aliases: aliases, kind: kind,
                                                              language: language, episode: episode, season: season, anilistID: anilistID))
                            let candidates = try await loadCandidates(result.0, episode)
                            return (provider, result.0, nil, result.1, result.2, candidates)
                        } catch OnlineSubtitleError.missingKey {
                            return (provider, [], nil, 0, query, [])
                        } catch {
                            return (provider, [], error.localizedDescription, 0, query, [])
                        }
                    }
                }
                for await (provider, entries, error, pages, resolvedQuery, files) in group {
                    guard current == generation, !Task.isCancelled else { continue }
                    results[provider] = entries
                    candidates[provider] = files
                    failures[provider] = error
                    searching.remove(provider)
                    if provider == .openSubtitles {
                        openSubtitlesPage = 1
                        openSubtitlesTotalPages = pages
                        openSubtitlesQuery = resolvedQuery
                    }
                }
            }
        }
    }

    func download(_ file: OpenSubtitlesFile, completion: @escaping @MainActor (RemoteVideoSubtitleOption) -> Void) {
        guard !downloading else { return }
        downloading = true
        notice = nil
        let current = generation
        fileWork = Task {
            guard current == generation, !Task.isCancelled else { return }
            do {
                let key = try await Self.key(for: .openSubtitles)
                guard current == generation, !Task.isCancelled else { return }
                let option = try await OpenSubtitlesClient.shared.downloadOption(for: file, apiKey: key)
                guard current == generation, !Task.isCancelled else { return }
                downloading = false
                completion(option)
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                downloading = false
                notice = error.localizedDescription
            }
        }
    }

    func loadMore() {
        guard !searching.contains(.openSubtitles), openSubtitlesPage < openSubtitlesTotalPages else { return }
        searching.insert(.openSubtitles)
        failures[.openSubtitles] = nil
        let current = generation
        work = Task {
            guard current == generation, !Task.isCancelled else { return }
            do {
                let key = try await Self.key(for: .openSubtitles)
                let response = try await OpenSubtitlesClient.shared.search(query: openSubtitlesQuery, language: searchLanguage,
                    season: searchSeason, episode: searchEpisode, apiKey: key, page: openSubtitlesPage + 1)
                guard current == generation, !Task.isCancelled else { return }
                var existing = results[.openSubtitles] ?? []
                let ids = Set(existing.map(\.id))
                existing += response.files.map(OnlineSubtitleEntry.openSubtitles).filter { !ids.contains($0.id) }
                results[.openSubtitles] = existing
                candidates[.openSubtitles] = existing.compactMap {
                    guard case .openSubtitles(let file) = $0 else { return nil }
                    return OnlineSubtitleCandidate(file: .openSubtitles(file), collectionID: file.release ?? file.name, collectionName: file.release ?? file.name)
                }
                openSubtitlesPage += 1
                openSubtitlesTotalPages = response.totalPages
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                failures[.openSubtitles] = error.localizedDescription
            }
            searching.remove(.openSubtitles)
        }
    }

    nonisolated static func loadCandidates(_ entries: [OnlineSubtitleEntry], episode: Int?) async throws -> [OnlineSubtitleCandidate] {
        var candidates: [OnlineSubtitleCandidate] = []
        var failure: (any Error)?
        for entry in entries.prefix(entries.contains { if case .openSubtitles = $0 { return true }; return false } ? entries.count : 5) {
            try Task.checkCancellation()
            do {
                let files: [OnlineSubtitleFile]
                switch entry {
                case .ajatt(let entry):
                    files = try await AJATTSubtitleCatalogClient.shared.files(for: entry, episode: episode).map(OnlineSubtitleFile.ajatt)
                case .jimaku(let entry):
                    let key = try await key(for: .jimaku)
                    files = try await JimakuAPIClient.shared.files(for: entry.id, episode: episode, apiKey: key).map(OnlineSubtitleFile.jimaku)
                case .openSubtitles(let file): files = [.openSubtitles(file)]
                }
                candidates += files.map {
                    OnlineSubtitleCandidate(file: $0, collectionID: { if case .openSubtitles(let file) = entry { return file.release ?? file.name }; return entry.id }(), collectionName: entry.name)
                }
            } catch { failure = error }
        }
        if candidates.isEmpty, let failure { throw failure }
        return candidates
    }

    nonisolated private static func normalizedTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    nonisolated private static func number(_ value: String) -> Int?? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .some(nil) }
        guard let number = Int(value), (0...9_999).contains(number) else { return nil }
        return .some(number)
    }

    nonisolated private static func key(for provider: OnlineSubtitleProvider) async throws -> String {
        let store = provider == .jimaku ? JimakuCredentialStore.shared : JimakuCredentialStore.openSubtitles
        guard let key = try await store.apiKey() else { throw OnlineSubtitleError.missingKey }
        return key
    }

    nonisolated static func fetch(_ provider: OnlineSubtitleProvider, request: OnlineSubtitleSearchRequest) async throws -> ([OnlineSubtitleEntry], Int, String) {
        let (query, aliases, kind, language, episode, season, anilistID) =
            (request.query, request.aliases, request.kind, request.language, request.episode, request.season, request.anilistID)
        var seen = Set<String>()
        let queries = ([query] + aliases).filter { seen.insert($0.lowercased()).inserted }
        switch provider {
        case .ajatt:
            var entries: [AJATTEntry] = []
            var ids = Set<String>()
            for candidate in queries {
                try Task.checkCancellation()
                let matches = try await AJATTSubtitleCatalogClient.shared.searchEntries(query: candidate, kind: kind == .anime ? .anime : .liveAction)
                entries += matches.filter { ids.insert($0.id).inserted }
            }
            let needles = Set((aliases.isEmpty ? [query] : aliases).map(Self.normalizedTitle))
            let exact = entries.filter { entry in
                [entry.name, entry.englishName, entry.japaneseName].compactMap { $0 }
                    .contains { needles.contains(Self.normalizedTitle($0)) }
            }
            return (Array((exact.isEmpty ? entries : exact).prefix(5)).map(OnlineSubtitleEntry.ajatt), 0, query)
        case .jimaku:
            let key = try await key(for: provider)
            if let anilistID {
                let matches = try await JimakuAPIClient.shared.searchEntries(query: query, kind: kind, apiKey: key, anilistID: anilistID)
                if !matches.isEmpty { return (matches.map(OnlineSubtitleEntry.jimaku), 0, query) }
            }
            for candidate in queries.prefix(4) {
                try Task.checkCancellation()
                let matches = try await JimakuAPIClient.shared.searchEntries(query: candidate, kind: kind, apiKey: key)
                if !matches.isEmpty { return (matches.map(OnlineSubtitleEntry.jimaku), 0, candidate) }
            }
            return ([], 0, query)
        case .openSubtitles:
            let key = try await key(for: provider)
            for candidate in queries.prefix(4) {
                try Task.checkCancellation()
                let result = try await OpenSubtitlesClient.shared.search(query: candidate, language: language, season: season, episode: episode, apiKey: key)
                if !result.files.isEmpty { return (result.files.map(OnlineSubtitleEntry.openSubtitles), result.totalPages, candidate) }
            }
            return ([], 0, query)
        }
    }
}
