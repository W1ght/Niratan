import Foundation
import Observation

enum VideoLibraryDisplayMode: String, CaseIterable, Identifiable {
    case continueWatching
    case favorites
    case unwatched
    case finished
    case missing
    case recent
    case all
    case needsReview
    case series
    case folders
    case collections

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .continueWatching: "Continue Watching"
        case .favorites: "Favorites"
        case .unwatched: "Unwatched"
        case .finished: "Finished"
        case .missing: "Missing"
        case .recent: "Recent"
        case .all: "All Videos"
        case .needsReview: "Needs Review"
        case .series: "Series"
        case .folders: "Folders"
        case .collections: "Collections"
        }
    }

    var usesCollapsibleSections: Bool {
        switch self {
        case .series, .folders, .collections:
            return true
        case .continueWatching, .favorites, .unwatched, .finished, .missing, .recent, .all, .needsReview:
            return false
        }
    }
}

enum VideoLibrarySortOption: String, CaseIterable, Identifiable {
    case recentPlayback
    case title
    case modifiedDate
    case folder

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .recentPlayback: "Recent Playback"
        case .title: "File Name"
        case .modifiedDate: "Modified Date"
        case .folder: "Folder"
        }
    }
}

enum VideoLibraryLayoutMode: String, CaseIterable, Identifiable {
    case list
    case posters

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .list: "List"
        case .posters: "Posters"
        }
    }

    var systemImageName: String {
        switch self {
        case .list: "list.bullet"
        case .posters: "square.grid.2x2"
        }
    }
}

struct VideoLibraryRow: Identifiable, Equatable {
    var id: String { item.id }

    let item: VideoLibraryItem
    let sourceName: String
    let playbackState: VideoPlaybackState?
    let metadata: VideoLibraryItemMetadata
    let organization: VideoLibraryItemOrganization
    let subtitleCandidateURL: URL?
    let remoteThumbnailURL: URL?

    var displayTitle: String {
        metadata.displayTitle ?? item.title
    }

    var boundSubtitleURL: URL? {
        guard let path = metadata.boundSubtitlePath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }
}

struct VideoLibrarySection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [VideoLibraryRow]
    let collection: VideoLibraryCollection?

    init(
        id: String,
        title: String,
        rows: [VideoLibraryRow],
        collection: VideoLibraryCollection? = nil
    ) {
        self.id = id
        self.title = title
        self.rows = rows
        self.collection = collection
    }
}

struct VideoLibraryItemOrganization: Equatable {
    let seriesName: String
    let seasonName: String?
    let folderPath: String
}

struct VideoLibrarySourceSummary: Identifiable, Equatable {
    var id: UUID { source.id }

    let source: VideoLibrarySource
    let itemCount: Int
    let inProgressCount: Int
    let missingCount: Int
}

@Observable
@MainActor
final class VideoLibraryViewModel {
    var displayMode: VideoLibraryDisplayMode = .continueWatching
    var layoutMode: VideoLibraryLayoutMode = .list
    var sortOption: VideoLibrarySortOption = .title
    var searchText = ""
    var showUnfinishedOnly = false
    var selectedItemID: String?
    var selectedItemIDs: Set<String> = []
    var catalog: VideoLibraryCatalog
    var isScanning = false
    var shouldShowError = false
    var errorMessage = ""
    private(set) var playbackHistoryRevision = 0

    private let store: VideoLibraryStore
    private let historyStore: VideoPlaybackHistoryStore
    private let remoteResolver: RemoteVideoResolverRegistry
    private var openGeneration = 0
    private var playbackStatesByIdentity: [String: VideoPlaybackState] = [:]
    private var cachedPlaybackIdentityKeys: Set<String> = []

    init(
        store: VideoLibraryStore? = nil,
        historyStore: VideoPlaybackHistoryStore = VideoPlaybackHistoryStore(),
        remoteResolver: RemoteVideoResolverRegistry = RemoteVideoResolverRegistry()
    ) {
        let resolvedStore = store ?? .shared
        self.store = resolvedStore
        self.historyStore = historyStore
        self.remoteResolver = remoteResolver
        self.catalog = resolvedStore.catalog
        rebuildPlaybackHistoryCache()
    }

    var sources: [VideoLibrarySource] {
        catalog.sources
    }

    var hasSources: Bool {
        !catalog.sources.isEmpty || !catalog.remoteItems.isEmpty
    }

    var selectedRow: VideoLibraryRow? {
        guard let selectedItemID else { return nil }
        return rows(for: allItems).first { $0.id == selectedItemID }
    }

    var sourceSummaries: [VideoLibrarySourceSummary] {
        _ = playbackHistoryRevision
        let rowsBySource = Dictionary(grouping: rows(for: allItems)) { $0.item.sourceID }
        return catalog.sources.map { source in
            let rows = rowsBySource[source.id] ?? []
            return VideoLibrarySourceSummary(
                source: source,
                itemCount: rows.count,
                inProgressCount: rows.filter { $0.playbackState?.isResumable == true }.count,
                missingCount: rows.filter { isMissing($0.item) }.count
            )
        }
    }

    var emptyTitleKey: String {
        if isFiltering {
            return "No Matching Videos"
        }
        switch displayMode {
        case .continueWatching:
            return "No Videos in Progress"
        case .favorites:
            return "No Favorite Videos"
        case .unwatched:
            return "No Unwatched Videos"
        case .finished:
            return "No Finished Videos"
        case .missing:
            return "No Missing Videos"
        case .recent:
            return "No Recent Videos"
        case .needsReview:
            return "No Videos Need Review"
        case .all, .series, .folders, .collections:
            return "No Videos"
        }
    }

    var emptyDescriptionKey: String {
        if isFiltering {
            return "Try a different search or filter."
        }
        switch displayMode {
        case .continueWatching:
            return "Partially watched videos will appear here."
        case .favorites:
            return "Favorite videos will appear here."
        case .unwatched:
            return "Videos without playback progress will appear here."
        case .finished:
            return "Videos marked watched will appear here."
        case .missing:
            return "Missing videos will appear here until their source is refreshed."
        case .recent:
            return "Played videos will appear here."
        case .needsReview:
            return "Videos outside manual and smart collections will appear here."
        case .all, .series, .folders, .collections:
            return "Refresh your folders or add another source."
        }
    }

    func load() {
        catalog = store.catalog
        rebuildPlaybackHistoryCache()
    }

    func refreshPlaybackHistory(
        changedIdentityPersistenceKey: String? = nil
    ) {
        if let changedIdentityPersistenceKey {
            guard cachedPlaybackIdentityKeys.contains(changedIdentityPersistenceKey),
                  let identity = allItems.lazy.map(\.mediaIdentity).first(where: {
                $0.persistenceKey == changedIdentityPersistenceKey
            }) else {
                return
            }
            let previousState = playbackStatesByIdentity[changedIdentityPersistenceKey]
            let updatedState = historyStore.playbackState(for: identity)
            guard previousState != updatedState else { return }
            if let updatedState {
                playbackStatesByIdentity[changedIdentityPersistenceKey] = updatedState
            } else {
                playbackStatesByIdentity.removeValue(
                    forKey: changedIdentityPersistenceKey
                )
            }
            playbackHistoryRevision &+= 1
        } else {
            let previousStates = playbackStatesByIdentity
            let previousKeys = cachedPlaybackIdentityKeys
            rebuildPlaybackHistoryCache()
            guard previousStates != playbackStatesByIdentity
                    || previousKeys != cachedPlaybackIdentityKeys else {
                return
            }
            playbackHistoryRevision &+= 1
        }
    }

    func addFolders(_ result: Result<[URL], any Error>) {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            isScanning = true
            defer { isScanning = false }

            for url in urls {
                let source = try store.addSource(folderURL: url)
                try store.scanSource(id: source.id)
            }
            catalog = store.catalog
        } catch {
            catalog = store.catalog
            showError(error.localizedDescription)
        }
    }

    @discardableResult
    func addRemoteItem(_ resolvedSource: ResolvedRemoteVideoSource) -> VideoLibraryItem {
        let item = store.addRemoteItem(resolvedSource).libraryItem
        catalog = store.catalog
        displayMode = .all
        select(item: item)
        return item
    }

    func refreshAllSources() {
        guard !catalog.sources.isEmpty else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            try store.scanAllSources()
            catalog = store.catalog
        } catch {
            catalog = store.catalog
            showError(error.localizedDescription)
        }
    }

    func refreshSource(id: UUID) {
        isScanning = true
        defer { isScanning = false }
        do {
            try store.scanSource(id: id)
            catalog = store.catalog
        } catch {
            catalog = store.catalog
            showError(error.localizedDescription)
        }
    }

    func removeSource(id: UUID) {
        store.removeSource(id: id)
        catalog = store.catalog
        let itemIDs = Set(allItems.map(\.id))
        selectedItemIDs = selectedItemIDs.intersection(itemIDs)
        if let selectedItemID, !allItems.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = nil
        }
    }

    func removeRemoteItem(_ item: VideoLibraryItem) {
        guard store.removeRemoteItem(id: item.id) else { return }
        catalog = store.catalog
        selectedItemIDs.remove(item.id)
        if selectedItemID == item.id {
            selectedItemID = nil
        }
    }

    func select(item: VideoLibraryItem) {
        selectedItemID = item.id
        selectedItemIDs = [item.id]
    }

    func clearSelection() {
        selectedItemID = nil
        selectedItemIDs = []
    }

    func openURL(for item: VideoLibraryItem) -> URL? {
        guard store.remoteItem(for: item) == nil else {
            return nil
        }
        guard let url = store.resolvedURL(for: item) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            refreshSourceAfterMissingItem(item)
            showError(String(localized: "The saved video file is no longer available."))
            return nil
        }
        return url
    }

    func openPlaybackSource(for item: VideoLibraryItem) async -> VideoPlaybackSource? {
        openGeneration &+= 1
        let generation = openGeneration
        if let remoteItem = store.remoteItem(for: item) {
            do {
                let resolvedSource = try await remoteResolver.resolve(
                    identity: remoteItem.identity,
                    preferredSubtitleLanguages: remoteItem.subtitleLanguage.map { [$0] } ?? [],
                    forceRefresh: !remoteItem.hasResolvedSubtitleMetadata
                )
                guard generation == openGeneration, !Task.isCancelled else { return nil }
                store.addRemoteItem(resolvedSource)
                catalog = store.catalog
                return .remoteStream(resolvedSource)
            } catch {
                guard generation == openGeneration,
                      !Task.isCancelled,
                      !(error is CancellationError),
                      !Self.isCancellation(error) else {
                    return nil
                }
                showError(error.localizedDescription)
                return nil
            }
        }
        guard generation == openGeneration, !Task.isCancelled else { return nil }
        return openURL(for: item).map(VideoPlaybackSource.localFile)
    }

    func remoteWindowOpenRequest(
        for item: VideoLibraryItem,
        startsFromBeginning: Bool
    ) -> RemoteVideoWindowOpenRequest? {
        guard let remoteItem = store.remoteItem(for: item) else { return nil }
        return RemoteVideoWindowOpenRequest(
            identity: remoteItem.identity,
            preferredSubtitleLanguages: remoteItem.subtitleLanguage.map { [$0] } ?? [],
            forceRefresh: !remoteItem.hasResolvedSubtitleMetadata,
            startsFromBeginning: startsFromBeginning
        )
    }

    func cancelPendingOpen() {
        openGeneration &+= 1
    }

    func subtitleURLForOpening(_ item: VideoLibraryItem) -> URL? {
        guard let path = store.metadata(for: item).boundSubtitlePath else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func openFromBeginningURL(for item: VideoLibraryItem) -> URL? {
        guard let url = openURL(for: item) else { return nil }
        historyStore.clearProgress(for: item.mediaIdentity)
        refreshPlaybackHistory()
        return url
    }

    func openFromBeginningPlaybackSource(for item: VideoLibraryItem) async -> VideoPlaybackSource? {
        guard let source = await openPlaybackSource(for: item) else { return nil }
        historyStore.clearProgress(for: item.mediaIdentity)
        refreshPlaybackHistory()
        return source
    }

    private nonisolated static func isCancellation(_ error: any Error) -> Bool {
        guard let resolverError = error as? RemoteVideoResolverError else { return false }
        if case .cancelled = resolverError { return true }
        return false
    }

    func markWatched(_ item: VideoLibraryItem) {
        let duration = historyStore.playbackState(for: item.mediaIdentity)?.duration
        historyStore.markWatched(duration: duration, for: item.mediaIdentity)
        refreshPlaybackHistory()
    }

    func clearProgress(_ item: VideoLibraryItem) {
        historyStore.clearProgress(for: item.mediaIdentity)
        refreshPlaybackHistory()
    }

    func setDisplayTitle(_ title: String?, for item: VideoLibraryItem) {
        store.setDisplayTitle(title, for: item)
        catalog = store.catalog
    }

    func setFavorite(_ isFavorite: Bool, for item: VideoLibraryItem) {
        store.setFavorite(isFavorite, for: item)
        catalog = store.catalog
    }

    func setTags(_ tags: [String], for item: VideoLibraryItem) {
        store.setTags(tags, for: item)
        catalog = store.catalog
    }

    func bindSubtitle(_ subtitleURL: URL?, for item: VideoLibraryItem) {
        store.bindSubtitle(subtitleURL, for: item)
        catalog = store.catalog
    }

    @discardableResult
    func createCollection(
        name: String,
        items: [VideoLibraryItem]
    ) -> VideoLibraryCollection {
        let collection = store.createCollection(name: name, itemPaths: items.map(\.path))
        catalog = store.catalog
        return collection
    }

    @discardableResult
    func createSmartCollection(
        name: String,
        rules: [VideoLibrarySmartRule]
    ) -> VideoLibraryCollection {
        let collection = store.createSmartCollection(name: name, rules: rules)
        catalog = store.catalog
        return collection
    }

    func updateSmartCollection(
        id: UUID,
        name: String,
        rules: [VideoLibrarySmartRule]
    ) {
        store.updateSmartCollection(id: id, name: name, rules: rules)
        catalog = store.catalog
    }

    func smartCollectionPreviewRows(
        rules: [VideoLibrarySmartRule],
        limit: Int = 8
    ) -> [VideoLibraryRow] {
        rows(for: allItems)
            .sorted(by: sortRows)
            .filter { row in smartRules(rules, match: row) }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    func setCollectionMembership(
        _ isIncluded: Bool,
        collectionID: UUID,
        for item: VideoLibraryItem
    ) {
        guard let collection = catalog.collections.first(where: { $0.id == collectionID }) else {
            return
        }
        guard collection.kind == .manual else { return }
        var itemPaths = collection.itemPaths
        if isIncluded {
            if !itemPaths.contains(item.path) {
                itemPaths.append(item.path)
            }
        } else {
            itemPaths.removeAll { $0 == item.path }
        }
        store.updateCollection(id: collectionID, name: collection.name, itemPaths: itemPaths)
        catalog = store.catalog
    }

    func removeCollection(id: UUID) {
        store.removeCollection(id: id)
        catalog = store.catalog
    }

    func markSelectedWatched() {
        for item in selectedItems {
            markWatched(item)
        }
    }

    func clearSelectedProgress() {
        for item in selectedItems {
            clearProgress(item)
        }
    }

    @discardableResult
    func removeMissingItems(sourceID: UUID? = nil) -> Int {
        let removed = store.removeMissingItems(sourceID: sourceID)
        catalog = store.catalog
        let itemIDs = Set(allItems.map(\.id))
        selectedItemIDs = selectedItemIDs.intersection(itemIDs)
        if let selectedItemID, !itemIDs.contains(selectedItemID) {
            self.selectedItemID = nil
        }
        return removed
    }

    func sections() -> [VideoLibrarySection] {
        _ = playbackHistoryRevision
        let rows = queriedRows()
        switch displayMode {
        case .continueWatching:
            let continueRows = rows
                .filter { $0.playbackState?.isResumable == true }
                .sorted(by: recentPlaybackSort)
            return continueRows.isEmpty
                ? []
                : [VideoLibrarySection(id: "continue", title: String(localized: "Continue Watching"), rows: continueRows)]
        case .favorites:
            let favoriteRows = rows
                .filter { $0.metadata.isFavorite }
            return favoriteRows.isEmpty
                ? []
                : [VideoLibrarySection(id: "favorites", title: String(localized: "Favorites"), rows: favoriteRows)]
        case .unwatched:
            let unwatchedRows = rows
                .filter { $0.playbackState == nil && !isMissing($0.item) }
            return unwatchedRows.isEmpty
                ? []
                : [VideoLibrarySection(id: "unwatched", title: String(localized: "Unwatched"), rows: unwatchedRows)]
        case .finished:
            let finishedRows = rows
                .filter { $0.playbackState?.isFinished == true }
                .sorted(by: recentPlaybackSort)
            return finishedRows.isEmpty
                ? []
                : [VideoLibrarySection(id: "finished", title: String(localized: "Finished"), rows: finishedRows)]
        case .missing:
            let missingRows = rows
                .filter { isMissing($0.item) }
            return missingRows.isEmpty
                ? []
                : [VideoLibrarySection(id: "missing", title: String(localized: "Missing"), rows: missingRows)]
        case .recent:
            let recentRows = rows
                .filter { $0.playbackState != nil }
                .sorted(by: recentPlaybackSort)
            return recentRows.isEmpty
                ? []
                : [VideoLibrarySection(id: "recent", title: String(localized: "Recent"), rows: recentRows)]
        case .all:
            return rows.isEmpty
                ? []
                : [VideoLibrarySection(id: "all", title: String(localized: "All Videos"), rows: rows)]
        case .needsReview:
            let reviewRows = rows.filter { !isCoveredByCollection($0) }
            return reviewRows.isEmpty
                ? []
                : [VideoLibrarySection(id: "needs-review", title: String(localized: "Needs Review"), rows: reviewRows)]
        case .series:
            return groupedSections(
                rows: rows,
                idPrefix: "series",
                title: { $0.organization.seriesName },
                sort: seriesSort
            )
        case .folders:
            return groupedSections(
                rows: rows,
                idPrefix: "folder",
                title: { $0.organization.folderPath },
                sort: sortRows
            )
        case .collections:
            let rowsByPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.item.path, $0) })
            return catalog.collections.map { collection in
                let collectionRows: [VideoLibraryRow]
                switch collection.kind {
                case .manual:
                    collectionRows = collection.itemPaths.compactMap { rowsByPath[$0] }
                case .smart:
                    collectionRows = rows.filter { smartRules(collection.smartRules, match: $0) }
                }
                return VideoLibrarySection(
                    id: "collection-\(collection.id.uuidString)",
                    title: collection.name,
                    rows: collectionRows.sorted(by: sortRows),
                    collection: collection
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    /// Badge counts for the mode column, ignoring the search field. Grouped
    /// modes count their groups; Needs Review is left out because it runs
    /// every smart rule against every video.
    func modeCounts() -> [VideoLibraryDisplayMode: Int] {
        _ = playbackHistoryRevision
        var counts: [VideoLibraryDisplayMode: Int] = [:]
        var seriesNames = Set<String>()
        var folderPaths = Set<String>()
        for row in rows(for: allItems) {
            let state = row.playbackState
            let isMissing = isMissing(row.item)
            counts[.all, default: 0] += 1
            if state?.isResumable == true {
                counts[.continueWatching, default: 0] += 1
            }
            if state == nil && !isMissing {
                counts[.unwatched, default: 0] += 1
            }
            if state?.isFinished == true {
                counts[.finished, default: 0] += 1
            }
            if state != nil {
                counts[.recent, default: 0] += 1
            }
            if isMissing {
                counts[.missing, default: 0] += 1
            }
            if row.metadata.isFavorite {
                counts[.favorites, default: 0] += 1
            }
            seriesNames.insert(row.organization.seriesName)
            folderPaths.insert(row.organization.folderPath)
        }
        counts[.series] = seriesNames.count
        counts[.folders] = folderPaths.count
        counts[.collections] = catalog.collections.count
        return counts
    }

    private func isCoveredByCollection(_ row: VideoLibraryRow) -> Bool {
        catalog.collections.contains { collection in
            switch collection.kind {
            case .manual:
                return collection.itemPaths.contains(row.item.path)
            case .smart:
                return smartRules(collection.smartRules, match: row)
            }
        }
    }

    private func smartRules(
        _ rules: [VideoLibrarySmartRule],
        match row: VideoLibraryRow
    ) -> Bool {
        guard !rules.isEmpty else { return false }
        return rules.allSatisfy { rule in
            smartRule(rule, matches: row)
        }
    }

    private func smartRule(
        _ rule: VideoLibrarySmartRule,
        matches row: VideoLibraryRow
    ) -> Bool {
        switch rule.field {
        case .fileName:
            return matchesText(rule, values: [row.displayTitle, row.item.title])
        case .parentFolder:
            return matchesText(rule, values: [row.item.parentFolder, row.organization.folderPath])
        case .path:
            return matchesText(rule, values: [row.item.path])
        case .tag:
            return matchesText(rule, values: row.metadata.tags)
        case .hasBoundSubtitle:
            return matchesBool(rule, value: row.metadata.boundSubtitlePath != nil)
        case .playbackState:
            return matchesText(rule, values: playbackStateTokens(for: row))
        }
    }

    private func matchesText(
        _ rule: VideoLibrarySmartRule,
        values: [String]
    ) -> Bool {
        let needle = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        switch rule.match {
        case .contains:
            return values.contains { value in
                value.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        case .equals:
            return values.contains { value in
                value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    == needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            }
        case .isTrue:
            return false
        }
    }

    private func matchesBool(
        _ rule: VideoLibrarySmartRule,
        value: Bool
    ) -> Bool {
        switch rule.match {
        case .isTrue:
            return value
        case .equals:
            let expected = rule.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value == ["true", "yes", "1"].contains(expected)
        case .contains:
            return false
        }
    }

    private func playbackStateTokens(for row: VideoLibraryRow) -> [String] {
        guard let state = row.playbackState else {
            return ["unwatched"]
        }
        if state.isFinished {
            return ["finished", "watched", "played"]
        }
        if state.isResumable {
            return ["inProgress", "in progress", "resumable", "started"]
        }
        return ["played"]
    }

    private func queriedRows() -> [VideoLibraryRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows(for: allItems)
            .filter { row in
                guard !query.isEmpty else { return true }
                return row.matches(query)
            }
            .filter { row in
                guard showUnfinishedOnly else { return true }
                guard let state = row.playbackState else { return false }
                return state.isResumable
            }
            .sorted(by: sortRows)
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || showUnfinishedOnly
    }

    private var selectedItems: [VideoLibraryItem] {
        allItems.filter { selectedItemIDs.contains($0.id) }
    }

    private var allItems: [VideoLibraryItem] {
        catalog.items + catalog.remoteItems.map(\.libraryItem)
    }

    private func rows(for items: [VideoLibraryItem]) -> [VideoLibraryRow] {
        synchronizePlaybackHistoryCache(for: items)
        let sourcesByID = Dictionary(uniqueKeysWithValues: catalog.sources.map { ($0.id, $0) })
        return items.map { item in
            let source = sourcesByID[item.sourceID]
            let metadata = store.metadata(for: item)
            let remoteItem = store.remoteItem(for: item)
            return VideoLibraryRow(
                item: item,
                sourceName: remoteItem?.identity.provider?.displayName
                    ?? source?.name
                    ?? item.parentFolder,
                playbackState: playbackStatesByIdentity[item.mediaIdentity.persistenceKey],
                metadata: metadata,
                organization: remoteItem == nil
                    ? organization(for: item, source: source)
                    : VideoLibraryItemOrganization(
                        seriesName: String(localized: "YouTube Video"),
                        seasonName: nil,
                        folderPath: String(localized: "YouTube Video")
                    ),
                subtitleCandidateURL: remoteItem == nil
                    ? subtitleCandidateURL(for: item, metadata: metadata)
                    : nil,
                remoteThumbnailURL: remoteItem?.thumbnailURL
            )
        }
    }

    private func rebuildPlaybackHistoryCache() {
        synchronizePlaybackHistoryCache(for: allItems, force: true)
    }

    private func synchronizePlaybackHistoryCache(
        for items: [VideoLibraryItem],
        force: Bool = false
    ) {
        let identities = items.map(\.mediaIdentity)
        let identityKeys = Set(identities.map(\.persistenceKey))
        guard force || identityKeys != cachedPlaybackIdentityKeys else { return }
        playbackStatesByIdentity = historyStore.playbackStates(for: identities)
        cachedPlaybackIdentityKeys = identityKeys
    }

    private func sortRows(_ lhs: VideoLibraryRow, _ rhs: VideoLibraryRow) -> Bool {
        switch sortOption {
        case .recentPlayback:
            return recentPlaybackSort(lhs, rhs)
        case .title:
            return titleSort(lhs, rhs)
        case .modifiedDate:
            let lhsDate = lhs.item.modifiedAt ?? .distantPast
            let rhsDate = rhs.item.modifiedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return titleSort(lhs, rhs)
        case .folder:
            let folderCompare = lhs.item.parentFolder.localizedStandardCompare(rhs.item.parentFolder)
            if folderCompare != .orderedSame {
                return folderCompare == .orderedAscending
            }
            return titleSort(lhs, rhs)
        }
    }

    private func recentPlaybackSort(_ lhs: VideoLibraryRow, _ rhs: VideoLibraryRow) -> Bool {
        let lhsDate = lhs.playbackState?.updatedAt ?? .distantPast
        let rhsDate = rhs.playbackState?.updatedAt ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return titleSort(lhs, rhs)
    }

    private func titleSort(_ lhs: VideoLibraryRow, _ rhs: VideoLibraryRow) -> Bool {
        let titleCompare = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
        if titleCompare != .orderedSame {
            return titleCompare == .orderedAscending
        }
        return lhs.item.path.localizedStandardCompare(rhs.item.path) == .orderedAscending
    }

    private func seriesSort(_ lhs: VideoLibraryRow, _ rhs: VideoLibraryRow) -> Bool {
        let lhsSeason = lhs.organization.seasonName ?? ""
        let rhsSeason = rhs.organization.seasonName ?? ""
        let seasonCompare = lhsSeason.localizedStandardCompare(rhsSeason)
        if seasonCompare != .orderedSame {
            return seasonCompare == .orderedAscending
        }
        return titleSort(lhs, rhs)
    }

    private func groupedSections(
        rows: [VideoLibraryRow],
        idPrefix: String,
        title: (VideoLibraryRow) -> String,
        sort: (VideoLibraryRow, VideoLibraryRow) -> Bool
    ) -> [VideoLibrarySection] {
        Dictionary(grouping: rows, by: title)
            .map { name, rows in
                VideoLibrarySection(
                    id: "\(idPrefix)-\(name)",
                    title: name,
                    rows: rows.sorted(by: sort)
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func organization(
        for item: VideoLibraryItem,
        source: VideoLibrarySource?
    ) -> VideoLibraryItemOrganization {
        guard let source else {
            return VideoLibraryItemOrganization(
                seriesName: item.parentFolder,
                seasonName: nil,
                folderPath: item.parentFolder
            )
        }
        guard let localURL = item.localURL else {
            return VideoLibraryItemOrganization(
                seriesName: item.parentFolder,
                seasonName: nil,
                folderPath: item.parentFolder
            )
        }
        let sourceURL = URL(
            fileURLWithPath: source.path,
            isDirectory: true
        ).standardizedFileURL
        let parentURL = localURL.deletingLastPathComponent().standardizedFileURL
        let sourceComponents = sourceURL.pathComponents
        let parentComponents = parentURL.pathComponents
        let relativeComponents = Array(parentComponents.dropFirst(sourceComponents.count))
        let folderPath = relativeComponents.isEmpty
            ? source.name
            : relativeComponents.joined(separator: " / ")
        guard let first = relativeComponents.first else {
            return VideoLibraryItemOrganization(
                seriesName: source.name,
                seasonName: nil,
                folderPath: folderPath
            )
        }
        if relativeComponents.count >= 2 {
            return VideoLibraryItemOrganization(
                seriesName: first,
                seasonName: relativeComponents[1],
                folderPath: folderPath
            )
        }
        if Self.looksLikeSeason(first) {
            return VideoLibraryItemOrganization(
                seriesName: source.name,
                seasonName: first,
                folderPath: folderPath
            )
        }
        return VideoLibraryItemOrganization(
            seriesName: first,
            seasonName: nil,
            folderPath: folderPath
        )
    }

    private func subtitleCandidateURL(
        for item: VideoLibraryItem,
        metadata: VideoLibraryItemMetadata
    ) -> URL? {
        if let boundPath = metadata.boundSubtitlePath {
            return URL(fileURLWithPath: boundPath, isDirectory: false).standardizedFileURL
        }
        return nil
    }

    private func refreshSourceAfterMissingItem(_ item: VideoLibraryItem) {
        do {
            try store.scanSource(id: item.sourceID)
            catalog = store.catalog
        } catch {
            catalog = store.catalog
        }
    }

    private func isMissing(_ item: VideoLibraryItem) -> Bool {
        guard let localURL = item.localURL else { return false }
        return !FileManager.default.fileExists(atPath: localURL.path)
    }

    private func showError(_ message: String) {
        errorMessage = message
        shouldShowError = true
    }

    private static func looksLikeSeason(_ component: String) -> Bool {
        component.range(
            of: #"(?i)\b(season|saison|temporada|s)\s*\d+\b"#,
            options: .regularExpression
        ) != nil
    }
}

private extension VideoLibraryRow {
    func matches(_ query: String) -> Bool {
        let fields = [
            displayTitle,
            item.title,
            item.parentFolder,
            sourceName,
            organization.seriesName,
            organization.seasonName ?? "",
            organization.folderPath,
            metadata.tags.joined(separator: " "),
            metadata.boundSubtitlePath ?? "",
            item.path,
        ]
        return fields.contains { field in
            field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
