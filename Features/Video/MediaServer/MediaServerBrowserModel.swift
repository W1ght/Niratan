import Foundation
import Observation

/// Browsing state for one signed-in server: home rows, a navigation stack of
/// libraries/folders/series, paged grids and search.
@Observable
@MainActor
final class MediaServerBrowserModel {
    enum Route: Hashable {
        case library(MediaServerLibrary)
        case folder(MediaServerItem)
        case series(MediaServerItem)

        var title: String {
            switch self {
            case .library(let library): library.name
            case .folder(let item), .series(let item): item.name
            }
        }
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Paged children of a library or folder.
    @Observable
    @MainActor
    final class Grid {
        let parentID: String
        var sort: MediaServerSort
        private(set) var items: [MediaServerItem] = []
        private(set) var totalCount = 0
        private(set) var state: LoadState = .idle
        private var nextStart = 0
        private var generation = 0

        init(parentID: String, sort: MediaServerSort) {
            self.parentID = parentID
            self.sort = sort
        }

        var hasMore: Bool { nextStart < totalCount }

        func reload(client: any MediaServerClient) async {
            generation &+= 1
            items = []
            totalCount = 0
            nextStart = 0
            await loadMore(client: client, isReload: true)
        }

        func loadMore(client: any MediaServerClient, isReload: Bool = false) async {
            guard isReload || (state != .loading && hasMore) else { return }
            let requestGeneration = generation
            state = .loading
            do {
                let page = try await client.items(
                    parentID: parentID,
                    sort: sort,
                    start: nextStart,
                    limit: MediaServerBrowserModel.pageSize
                )
                guard requestGeneration == generation else { return }
                let seen = Set(items.map(\.id))
                items += page.items.filter { !seen.contains($0.id) }
                totalCount = page.totalCount
                nextStart = page.nextStart
                state = .loaded
            } catch {
                guard requestGeneration == generation, !(error is CancellationError) else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Seasons and episodes of one series.
    @Observable
    @MainActor
    final class SeriesDetail {
        let series: MediaServerItem
        private(set) var detail: MediaServerItem?
        private(set) var seasons: [MediaServerItem] = []
        var selectedSeasonID: String?
        private(set) var episodes: [MediaServerItem] = []
        private(set) var state: LoadState = .idle
        private(set) var episodesState: LoadState = .idle
        private var episodeGeneration = 0

        init(series: MediaServerItem, initialSeasonID: String? = nil) {
            self.series = series
            selectedSeasonID = initialSeasonID
        }

        func load(client: any MediaServerClient) async {
            state = .loading
            do {
                async let detail = try? client.item(id: series.id)
                let seasons = try await client.seasons(seriesID: series.id)
                self.detail = await detail
                self.seasons = seasons
                if selectedSeasonID == nil || !seasons.contains(where: { $0.id == selectedSeasonID }) {
                    selectedSeasonID = seasons.first(where: { ($0.unplayedCount ?? 1) > 0 && ($0.seasonNumber ?? 1) > 0 })?.id
                        ?? seasons.first?.id
                }
                state = .loaded
                await loadEpisodes(client: client)
            } catch {
                guard !(error is CancellationError) else { return }
                state = .failed(error.localizedDescription)
            }
        }

        func loadEpisodes(client: any MediaServerClient) async {
            episodeGeneration &+= 1
            let generation = episodeGeneration
            episodesState = .loading
            do {
                let episodes = try await client.episodes(seriesID: series.id, seasonID: selectedSeasonID)
                guard generation == episodeGeneration else { return }
                self.episodes = episodes
                episodesState = .loaded
            } catch {
                guard generation == episodeGeneration, !(error is CancellationError) else { return }
                episodesState = .failed(error.localizedDescription)
            }
        }

        /// The episode "Play" should start: one in progress, else the first
        /// unwatched, else the first.
        var nextEpisode: MediaServerItem? {
            episodes.first { ($0.playbackPosition ?? 0) > 0 && !$0.isPlayed }
                ?? episodes.first { !$0.isPlayed }
                ?? episodes.first
        }
    }

    static let pageSize = 60
    static let rowLimit = 20

    let account: MediaServerAccount
    private(set) var client: (any MediaServerClient)?
    private(set) var state: LoadState = .idle
    private(set) var libraries: [MediaServerLibrary] = []
    private(set) var continueWatching: [MediaServerItem] = []
    private(set) var latestByLibrary: [String: [MediaServerItem]] = [:]
    var routes: [Route] = []
    var sort: MediaServerSort = .name
    // Caches handed to views lazily; not observed so creating one while a
    // view body runs does not invalidate it.
    @ObservationIgnored private var grids: [String: Grid] = [:]
    @ObservationIgnored private var seriesDetails: [String: SeriesDetail] = [:]

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }
    private(set) var searchResults: [MediaServerItem] = []
    private(set) var searchState: LoadState = .idle
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadingLatest: Set<String> = []

    init(account: MediaServerAccount) {
        self.account = account
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var title: String {
        routes.last?.title ?? account.displayName
    }

    // MARK: Loading

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        state = .loading
        do {
            let client = try await MediaServerClientFactory.shared.client(accountID: account.id)
            self.client = client
            // Views are the backbone; the other rows degrade to empty.
            let libraries = try await client.libraries()
            self.libraries = libraries
            continueWatching = (try? await client.continueWatching(limit: Self.rowLimit)) ?? []
            latestByLibrary = [:]
            loadingLatest = []
            state = .loaded
            for grid in grids.values {
                await grid.reload(client: client)
            }
            for detail in seriesDetails.values {
                await detail.load(client: client)
            }
        } catch {
            guard !(error is CancellationError) else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func refreshContinueWatching() async {
        guard let client else { return }
        if let items = try? await client.continueWatching(limit: Self.rowLimit) {
            continueWatching = items
        }
    }

    func loadLatest(for library: MediaServerLibrary) async {
        guard let client,
              latestByLibrary[library.id] == nil,
              !loadingLatest.contains(library.id) else { return }
        loadingLatest.insert(library.id)
        let items = (try? await client.latest(libraryID: library.id, limit: Self.rowLimit)) ?? []
        latestByLibrary[library.id] = items
    }

    // MARK: Navigation

    func open(_ library: MediaServerLibrary) {
        routes.append(.library(library))
    }

    func open(_ item: MediaServerItem) {
        switch item.kind {
        case .series:
            routes.append(.series(item))
        case .season:
            guard let seriesID = item.seriesID else {
                routes.append(.folder(item))
                return
            }
            let series = MediaServerItem(id: seriesID, kind: .series, name: item.seriesName ?? item.name)
            if seriesDetails[seriesID] == nil {
                seriesDetails[seriesID] = SeriesDetail(series: series, initialSeasonID: item.id)
            } else {
                seriesDetails[seriesID]?.selectedSeasonID = item.id
            }
            routes.append(.series(series))
        case .folder:
            routes.append(.folder(item))
        case .movie, .episode, .video:
            break
        }
    }

    func goBack() {
        _ = routes.popLast()
    }

    func goHome() {
        routes.removeAll()
    }

    func grid(for route: Route) -> Grid? {
        let parentID: String
        switch route {
        case .library(let library): parentID = library.id
        case .folder(let item): parentID = item.id
        case .series: return nil
        }
        if let grid = grids[parentID] {
            return grid
        }
        let grid = Grid(parentID: parentID, sort: sort)
        grids[parentID] = grid
        return grid
    }

    func seriesDetail(for series: MediaServerItem) -> SeriesDetail {
        if let detail = seriesDetails[series.id] {
            return detail
        }
        let detail = SeriesDetail(series: series)
        seriesDetails[series.id] = detail
        return detail
    }

    func setSort(_ sort: MediaServerSort, for grid: Grid) async {
        self.sort = sort
        grid.sort = sort
        guard let client else { return }
        await grid.reload(client: client)
    }

    // MARK: Playback helpers

    func playbackRequest(
        for item: MediaServerItem,
        startsFromBeginning: Bool = false
    ) -> RemoteVideoWindowOpenRequest? {
        guard let client, item.isPlayable else { return nil }
        return RemoteVideoWindowOpenRequest(
            identity: MediaServerRemoteVideoResolver.identity(for: item, client: client),
            preferredSubtitleLanguages: [],
            forceRefresh: true,
            startsFromBeginning: startsFromBeginning
        )
    }

    func setPlayed(_ played: Bool, item: MediaServerItem) async {
        guard let client else { return }
        do {
            try await client.setPlayed(played, itemID: item.id)
            await refreshContinueWatching()
            for detail in seriesDetails.values where detail.episodes.contains(where: { $0.id == item.id }) {
                await detail.loadEpisodes(client: client)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func webURL(for item: MediaServerItem) -> URL? {
        client?.webURL(itemID: item.id)
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            searchState = .idle
            return
        }
        searchState = .loading
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            do {
                let client: any MediaServerClient
                if let existing = self.client {
                    client = existing
                } else {
                    client = try await MediaServerClientFactory.shared.client(accountID: account.id)
                    self.client = client
                }
                let results = try await client.search(query, limit: 60)
                guard !Task.isCancelled else { return }
                searchResults = results
                searchState = .loaded
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                searchState = .failed(error.localizedDescription)
            }
        }
    }
}
