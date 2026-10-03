// test-sources: Features/Video/Remote/RemoteVideoSource.swift Features/Video/Remote/RemoteVideoResolver.swift Features/Video/VideoLibraryStore.swift Features/Video/VideoLibraryViewModel.swift Features/Video/VideoPlaybackHistoryStore.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift Features/Video/VideoMediaTypes.swift Features/Video/Playback/PlaybackEngine.swift Features/Video/Playback/VideoTrack.swift
import Foundation

// PlaybackEngine references the Video-only shader preset, but this focused
// library harness intentionally does not compile the Anime4K UI/store.
nonisolated enum VideoShaderPreset {
    case off
}

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func touch(_ url: URL, modified: Date, size: Int = 1) throws {
    FileManager.default.createFile(
        atPath: url.path,
        contents: Data(repeating: 0x31, count: size)
    )
    try FileManager.default.setAttributes(
        [.modificationDate: modified],
        ofItemAtPath: url.path
    )
}

@main
private enum VideoLibraryViewModelTests {
    @MainActor
    static func main() async throws {
        try testContinueWatchingShowsOnlyResumableVideos()
        try testSearchMatchesTitleFolderSourceAndPath()
        try testSortOptionsOrderAllVideos()
        try testUnfinishedFilterUsesIncompletePlaybackState()
        try testSmartFiltersSplitUnwatchedFinishedAndMissingVideos()
        try testSourceSummariesCountItemsAndRefreshOneSource()
        try testV3OrganizationMetadataSubtitleAndCollections()
        try testFoldersViewUsesSourceRelativeParentFolders()
        try testSmartCollectionsMatchRulesAndPreviewRows()
        try testNeedsReviewExcludesManualAndSmartCollectionRows()
        try testV3SelectionBatchActionsAndMissingCleanup()
        try testPlaybackStateActionsUpdateRows()
        try testFilteredEmptyStateUsesSearchCopy()
        try testPlaybackHistoryRefreshAdvancesRevision()
        try testClearingSelectionClosesDetailsInspector()
        try testRemoteItemUsesDurableIdentityAndStaysOutOfMissing()
        try testLegacyRemoteCatalogMigratesWithoutEphemeralStreams()
        try await testOpeningRemoteVideoRefreshesResolvedStreams()
        try await testCaptionlessRemoteVideoRespectsResolutionCache()
        try await testStaleRemoteOpenCompletionIsIgnored()
        try await testOpenFromBeginningClearsProgressOnlyAfterSuccess()
        try testRemovingRemoteItemIsCatalogOnly()
        print("Video library view model tests passed")
    }

    @MainActor
    private static func makeViewModel() throws -> VideoLibraryViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-video-library-view-model-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Anime Source", isDirectory: true)
        let season1 = source.appendingPathComponent("Season 1", isDirectory: true)
        let season2 = source.appendingPathComponent("Season 2", isDirectory: true)
        try FileManager.default.createDirectory(at: season1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: season2, withIntermediateDirectories: true)

        try touch(
            season1.appendingPathComponent("Alpha.mp4"),
            modified: Date(timeIntervalSince1970: 10),
            size: 10
        )
        try touch(
            season2.appendingPathComponent("Beta.mkv"),
            modified: Date(timeIntervalSince1970: 30),
            size: 30
        )
        try touch(
            source.appendingPathComponent("Gamma.webm"),
            modified: Date(timeIntervalSince1970: 20),
            size: 20
        )

        let store = VideoLibraryStore(
            fileURL: root.appendingPathComponent("library.json"),
            fileManager: .default
        )
        let librarySource = try store.addSource(folderURL: source)
        try store.scanSource(id: librarySource.id)

        let suiteName = "moe.shishamo.hoshi.tests.video-library-view-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let history = VideoPlaybackHistoryStore(defaults: defaults)
        history.savePlaybackState(
            position: 20,
            duration: 100,
            updatedAt: Date(timeIntervalSince1970: 100),
            for: season1.appendingPathComponent("Alpha.mp4")
        )
        history.savePlaybackState(
            position: 50,
            duration: 100,
            updatedAt: Date(timeIntervalSince1970: 200),
            for: season2.appendingPathComponent("Beta.mkv")
        )

        return VideoLibraryViewModel(store: store, historyStore: history)
    }

    @MainActor
    private static func makeOrganizedViewModel() throws -> VideoLibraryViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-video-library-organized-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Library", isDirectory: true)
        let showSeason1 = source
            .appendingPathComponent("Show A", isDirectory: true)
            .appendingPathComponent("Season 1", isDirectory: true)
        let showSeason2 = source
            .appendingPathComponent("Show A", isDirectory: true)
            .appendingPathComponent("Season 2", isDirectory: true)
        let movies = source.appendingPathComponent("Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: showSeason1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: showSeason2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)

        try touch(
            showSeason1.appendingPathComponent("Episode 01.mp4"),
            modified: Date(timeIntervalSince1970: 10),
            size: 10
        )
        try touch(
            showSeason2.appendingPathComponent("Episode 02.mkv"),
            modified: Date(timeIntervalSince1970: 20),
            size: 20
        )
        try touch(
            showSeason1.appendingPathComponent("Episode 01.ja.srt"),
            modified: Date(timeIntervalSince1970: 11),
            size: 1
        )
        try touch(
            movies.appendingPathComponent("Movie.webm"),
            modified: Date(timeIntervalSince1970: 30),
            size: 30
        )

        let store = VideoLibraryStore(
            fileURL: root.appendingPathComponent("library.json"),
            fileManager: .default
        )
        let librarySource = try store.addSource(folderURL: source)
        try store.scanSource(id: librarySource.id)

        let suiteName = "moe.shishamo.hoshi.tests.video-library-organized-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let history = VideoPlaybackHistoryStore(defaults: defaults)
        return VideoLibraryViewModel(store: store, historyStore: history)
    }

    @MainActor
    private static func titles(_ viewModel: VideoLibraryViewModel) -> [String] {
        viewModel.sections().flatMap(\.rows).map(\.displayTitle)
    }

    @MainActor
    private static func row(_ viewModel: VideoLibraryViewModel, title: String) -> VideoLibraryRow {
        guard let row = viewModel.sections().flatMap(\.rows).first(where: { $0.item.title == title }) else {
            fputs("FAIL: expected row titled \(title)\n", stderr)
            exit(1)
        }
        return row
    }

    @MainActor
    private static func item(_ viewModel: VideoLibraryViewModel, title: String) -> VideoLibraryItem {
        guard let item = viewModel.catalog.items.first(where: { $0.title == title }) else {
            fputs("FAIL: expected catalog item titled \(title)\n", stderr)
            exit(1)
        }
        return item
    }

    private static func remoteSource(
        title: String = "Remote Fixture",
        providerID: String = "youtube",
        remoteID: String = "remote-fixture",
        mediaURL: URL
    ) -> ResolvedRemoteVideoSource {
        ResolvedRemoteVideoSource(
            identity: RemoteVideoIdentity(
                providerID: providerID,
                remoteID: remoteID,
                originalURL: URL(string: "https://www.youtube.com/watch?v=\(remoteID)")!,
                canonicalURL: nil,
                title: title,
                thumbnailURL: nil
            ),
            playbackStream: RemoteVideoStream(
                url: mediaURL,
                formatID: "video",
                height: 720,
                hasVideo: true,
                hasAudio: false
            ),
            audioStream: RemoteVideoStream(
                url: URL(string: "https://cdn.example/\(remoteID)-audio.m4a")!,
                formatID: "audio",
                hasVideo: false,
                hasAudio: true
            ),
            miningStream: nil,
            subtitleOptions: [],
            selectedSubtitleLanguage: nil,
            resolvedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200)
        )
    }

    @MainActor
    private static func itemContaining(_ viewModel: VideoLibraryViewModel, title: String) -> VideoLibraryItem {
        guard let item = viewModel.catalog.items.first(where: { $0.title.contains(title) }) else {
            fputs("FAIL: expected catalog item containing \(title)\n", stderr)
            exit(1)
        }
        return item
    }

    @MainActor
    private static func testContinueWatchingShowsOnlyResumableVideos() throws {
        let viewModel = try makeViewModel()

        expect(viewModel.displayMode, .continueWatching, "video library should open on continue watching")
        expect(
            titles(viewModel),
            ["Beta", "Alpha"],
            "continue watching should show only resumable videos ordered by recent playback"
        )
    }

    @MainActor
    private static func testSearchMatchesTitleFolderSourceAndPath() throws {
        let viewModel = try makeViewModel()
        viewModel.displayMode = .all

        viewModel.searchText = "beta"
        expect(titles(viewModel), ["Beta"], "search should match video title")

        viewModel.searchText = "season 1"
        expect(titles(viewModel), ["Alpha"], "search should match parent folder")

        viewModel.searchText = "anime source"
        expect(
            titles(viewModel),
            ["Alpha", "Beta", "Gamma"],
            "search should match source name"
        )
    }

    @MainActor
    private static func testSortOptionsOrderAllVideos() throws {
        let viewModel = try makeViewModel()
        viewModel.displayMode = .all

        viewModel.sortOption = .title
        expect(titles(viewModel), ["Alpha", "Beta", "Gamma"], "title sort should be ascending")

        viewModel.sortOption = .modifiedDate
        expect(titles(viewModel), ["Beta", "Gamma", "Alpha"], "modified sort should be newest first")

        viewModel.sortOption = .folder
        expect(titles(viewModel), ["Gamma", "Alpha", "Beta"], "folder sort should group by folder name then title")

        viewModel.sortOption = .recentPlayback
        expect(titles(viewModel), ["Beta", "Alpha", "Gamma"], "recent playback sort should put played videos first")
    }

    @MainActor
    private static func testUnfinishedFilterUsesIncompletePlaybackState() throws {
        let viewModel = try makeViewModel()
        viewModel.displayMode = .all
        viewModel.showUnfinishedOnly = true

        expect(
            titles(viewModel),
            ["Alpha", "Beta"],
            "unfinished filter should show only videos with incomplete playback state"
        )
    }

    @MainActor
    private static func testSmartFiltersSplitUnwatchedFinishedAndMissingVideos() throws {
        let viewModel = try makeViewModel()

        viewModel.displayMode = .unwatched
        expect(titles(viewModel), ["Gamma"], "unwatched filter should show existing videos without playback state")

        viewModel.markWatched(item(viewModel, title: "Beta"))
        viewModel.displayMode = .finished
        expect(titles(viewModel), ["Beta"], "finished filter should show videos marked watched")

        try FileManager.default.removeItem(at: item(viewModel, title: "Gamma").localURL!)
        viewModel.displayMode = .missing
        expect(titles(viewModel), ["Gamma"], "missing filter should show catalog items whose files are gone")

        expect(viewModel.emptyTitleKey, "No Missing Videos", "missing view should have specific empty-state copy")
        expect(
            viewModel.emptyDescriptionKey,
            "Missing videos will appear here until their source is refreshed.",
            "missing view should explain stale items"
        )
    }

    @MainActor
    private static func testSourceSummariesCountItemsAndRefreshOneSource() throws {
        let viewModel = try makeViewModel()
        var summary = viewModel.sourceSummaries.first!

        expect(summary.itemCount, 3, "source summary should count all videos in the source")
        expect(summary.inProgressCount, 2, "source summary should count resumable videos")
        expect(summary.missingCount, 0, "source summary should start with no missing videos")

        try FileManager.default.removeItem(at: item(viewModel, title: "Gamma").localURL!)
        summary = viewModel.sourceSummaries.first!
        expect(summary.missingCount, 1, "source summary should count catalog items missing on disk")

        viewModel.refreshSource(id: summary.id)
        summary = viewModel.sourceSummaries.first!
        expect(summary.itemCount, 2, "single-source refresh should remove stale items after a successful scan")
        expect(summary.missingCount, 0, "single-source refresh should clear missing count after stale removal")
    }

    @MainActor
    private static func testV3OrganizationMetadataSubtitleAndCollections() throws {
        let viewModel = try makeOrganizedViewModel()
        let episode1 = itemContaining(viewModel, title: "Episode 01")
        let subtitleURL = episode1.localURL!
            .deletingPathExtension()
            .appendingPathExtension("ja.srt")

        viewModel.displayMode = .series
        expect(
            viewModel.sections().map(\.title),
            ["Movies", "Show A"],
            "series view should group videos by inferred source-relative series"
        )
        expect(
            viewModel.sections().filter { $0.title == "Show A" }.first?.rows.map(\.organization.seasonName),
            ["Season 1", "Season 2"],
            "series rows should expose inferred season names"
        )

        viewModel.setDisplayTitle("Pilot", for: episode1)
        viewModel.setFavorite(true, for: episode1)
        viewModel.setTags(["Anime", "Listening", "Anime"], for: episode1)
        viewModel.bindSubtitle(subtitleURL, for: episode1)
        let collection = viewModel.createCollection(name: "Weekend", items: [episode1])

        viewModel.displayMode = .favorites
        expect(titles(viewModel), ["Pilot"], "favorites view should show favorited videos with display titles")

        viewModel.displayMode = .all
        viewModel.searchText = "listening"
        expect(titles(viewModel), ["Pilot"], "search should match custom tags")
        viewModel.searchText = ""

        let pilotRow = row(viewModel, title: "Episode 01")
        expect(pilotRow.displayTitle, "Pilot", "row should expose custom display title")
        expect(pilotRow.metadata.tags, ["Anime", "Listening"], "row should expose normalized tags")
        expect(
            pilotRow.boundSubtitleURL,
            subtitleURL.standardizedFileURL,
            "row should expose manually bound subtitles"
        )
        expect(
            pilotRow.subtitleCandidateURL,
            subtitleURL.standardizedFileURL,
            "row should expose manually bound subtitle candidates without scanning folders"
        )
        expect(
            viewModel.subtitleURLForOpening(episode1),
            subtitleURL.standardizedFileURL,
            "opening a video with a bound subtitle should pass that subtitle to the player"
        )
        viewModel.bindSubtitle(nil, for: episode1)
        let unboundPilotRow = row(viewModel, title: "Episode 01")
        expect(
            unboundPilotRow.subtitleCandidateURL,
            nil,
            "row construction should not scan folders for same-name subtitle candidates"
        )

        viewModel.displayMode = .collections
        expect(viewModel.sections().map(\.title), ["Weekend"], "collections view should group custom collections")
        expect(titles(viewModel), ["Pilot"], "collections view should show collection videos")
        expect(collection.name, "Weekend", "collection creation should return the saved collection")

        viewModel.setCollectionMembership(false, collectionID: collection.id, for: episode1)
        expect(
            viewModel.sections().map(\.title),
            ["Weekend"],
            "removing all videos from a collection should leave the empty collection visible for deletion"
        )
        expect(
            viewModel.sections().map { $0.rows.count },
            [0],
            "empty collection sections should have no rows"
        )

        viewModel.setCollectionMembership(true, collectionID: collection.id, for: episode1)
        expect(titles(viewModel), ["Pilot"], "adding a video back to a collection should restore it")

        let episodePath = episode1.path
        viewModel.removeCollection(id: collection.id)
        expect(viewModel.catalog.collections, [], "removing a collection should delete the collection")
        expect(
            viewModel.catalog.items.contains(where: { $0.path == episodePath }),
            true,
            "removing a collection should keep the video in the library catalog"
        )
        expect(
            FileManager.default.fileExists(atPath: episodePath),
            true,
            "removing a collection should not delete the video file"
        )
        viewModel.displayMode = .all
        expect(
            row(viewModel, title: "Episode 01").metadata.collectionIDs,
            [],
            "removing a collection should clear item collection metadata"
        )
    }

    @MainActor
    private static func testFoldersViewUsesSourceRelativeParentFolders() throws {
        let viewModel = try makeOrganizedViewModel()

        viewModel.displayMode = .folders
        let sections = viewModel.sections()

        expect(
            sections.map(\.title),
            ["Movies", "Show A / Season 1", "Show A / Season 2"],
            "folders view should group videos by source-relative parent folders"
        )
        expect(
            sections.map { $0.rows.map(\.item.title) },
            [["Movie"], ["Episode 01"], ["Episode 02"]],
            "folders view should keep each nested folder collapsible as a separate section"
        )
    }

    @MainActor
    private static func testSmartCollectionsMatchRulesAndPreviewRows() throws {
        let viewModel = try makeOrganizedViewModel()
        let episode1 = itemContaining(viewModel, title: "Episode 01")
        let subtitleURL = episode1.localURL!
            .deletingPathExtension()
            .appendingPathExtension("ja.srt")
        viewModel.setTags(["Listening"], for: episode1)
        viewModel.bindSubtitle(subtitleURL, for: episode1)

        let previewRows = viewModel.smartCollectionPreviewRows(
            rules: [
                VideoLibrarySmartRule(field: .path, match: .contains, value: "Show A")
            ],
            limit: 1
        )
        expect(
            previewRows.map(\.item.title),
            ["Episode 01"],
            "smart collection preview should return sorted matching rows up to the limit"
        )

        _ = viewModel.createSmartCollection(
            name: "Tagged",
            rules: [
                VideoLibrarySmartRule(field: .tag, match: .contains, value: "listen")
            ]
        )
        _ = viewModel.createSmartCollection(
            name: "Subtitled",
            rules: [
                VideoLibrarySmartRule(field: .hasBoundSubtitle, match: .isTrue)
            ]
        )

        viewModel.displayMode = .collections
        let sections = viewModel.sections()
        expect(
            sections.map(\.title),
            ["Subtitled", "Tagged"],
            "collections view should show smart collections by name"
        )
        expect(
            sections.flatMap(\.rows).map(\.item.title),
            ["Episode 01", "Episode 01"],
            "smart collections should evaluate rules from row metadata"
        )
    }

    @MainActor
    private static func testNeedsReviewExcludesManualAndSmartCollectionRows() throws {
        let viewModel = try makeOrganizedViewModel()
        let movie = item(viewModel, title: "Movie")

        _ = viewModel.createCollection(name: "Movies", items: [movie])
        _ = viewModel.createSmartCollection(
            name: "Show A",
            rules: [
                VideoLibrarySmartRule(field: .path, match: .contains, value: "Show A")
            ]
        )

        viewModel.displayMode = .needsReview

        expect(
            titles(viewModel),
            [],
            "needs review should exclude rows already covered by manual or smart collections"
        )
    }

    @MainActor
    private static func testV3SelectionBatchActionsAndMissingCleanup() throws {
        let viewModel = try makeOrganizedViewModel()
        let episode1 = itemContaining(viewModel, title: "Episode 01")
        let episode2 = itemContaining(viewModel, title: "Episode 02")
        let movie = item(viewModel, title: "Movie")

        viewModel.select(item: episode1)
        expect(
            viewModel.selectedRow?.item.path,
            episode1.path,
            "selecting an item should expose its detail row"
        )

        viewModel.selectedItemIDs = Set([episode1.id, episode2.id])
        viewModel.markSelectedWatched()
        viewModel.displayMode = .finished
        expect(
            titles(viewModel),
            ["Episode 02", "Episode 01"],
            "batch mark watched should update selected videos"
        )

        viewModel.clearSelectedProgress()
        expect(
            titles(viewModel),
            [],
            "batch clear progress should remove selected videos from finished view"
        )

        try FileManager.default.removeItem(at: movie.localURL!)
        viewModel.displayMode = .missing
        expect(titles(viewModel), ["Movie"], "missing view should include deleted files before cleanup")
        let removed = viewModel.removeMissingItems()
        expect(removed, 1, "missing cleanup should report removed item count")
        expect(titles(viewModel), [], "missing cleanup should remove stale rows")
    }

    @MainActor
    private static func testPlaybackStateActionsUpdateRows() throws {
        let viewModel = try makeViewModel()

        viewModel.markWatched(row(viewModel, title: "Beta").item)
        expect(
            titles(viewModel),
            ["Alpha"],
            "mark watched should remove the video from continue watching"
        )

        viewModel.displayMode = .recent
        let watched = row(viewModel, title: "Beta")
        expect(watched.playbackState?.isFinished, true, "marked watched row should keep finished state")

        viewModel.clearProgress(watched.item)
        expect(
            titles(viewModel),
            ["Alpha"],
            "clear progress should remove the video from recent playback"
        )

        viewModel.displayMode = .continueWatching
        let alpha = row(viewModel, title: "Alpha")
        let url = viewModel.openFromBeginningURL(for: alpha.item)
        expect(url, alpha.item.localURL, "open from beginning should resolve the item URL")
        expect(
            titles(viewModel),
            [],
            "open from beginning should clear resume progress before opening"
        )
    }


    @MainActor
    private static func testFilteredEmptyStateUsesSearchCopy() throws {
        let viewModel = try makeViewModel()
        viewModel.displayMode = .all

        expect(viewModel.emptyTitleKey, "No Videos", "unfiltered all view should use the normal empty title")
        expect(
            viewModel.emptyDescriptionKey,
            "Refresh your folders or add another source.",
            "unfiltered all view should keep the normal empty description"
        )

        viewModel.searchText = "missing title"
        expect(
            viewModel.emptyTitleKey,
            "No Matching Videos",
            "filtered empty view should say no videos matched"
        )
        expect(
            viewModel.emptyDescriptionKey,
            "Try a different search or filter.",
            "filtered empty view should suggest changing filters"
        )
    }

    @MainActor
    private static func testPlaybackHistoryRefreshAdvancesRevision() throws {
        let viewModel = try makeViewModel()
        let revision = viewModel.playbackHistoryRevision

        viewModel.refreshPlaybackHistory()

        expect(
            viewModel.playbackHistoryRevision,
            revision,
            "an unchanged playback history refresh should not invalidate the library"
        )
    }

    @MainActor
    private static func testClearingSelectionClosesDetailsInspector() throws {
        let viewModel = try makeViewModel()
        let selectedItem = item(viewModel, title: "Alpha")

        viewModel.select(item: selectedItem)
        expect(viewModel.selectedItemID, selectedItem.id, "select should open video details")
        expect(viewModel.selectedItemIDs, Set([selectedItem.id]), "select should track the selected item")

        viewModel.clearSelection()
        expect(viewModel.selectedItemID, nil, "clearing selection should close video details")
        expect(viewModel.selectedItemIDs, [], "clearing selection should clear batch selection")
    }

    @MainActor
    private static func testRemoteItemUsesDurableIdentityAndStaysOutOfMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-video-library-remote-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("library.json")
        let store = VideoLibraryStore(fileURL: fileURL)
        let resolved = remoteSource(
            title: "Remote Identity Fixture",
            remoteID: "durable-id",
            mediaURL: URL(string: "https://cdn.example/googlevideo-signed.mp4?expire=123")!
        )
        let item = store.addRemoteItem(resolved).libraryItem
        let viewModel = VideoLibraryViewModel(store: store)

        expect(
            item.mediaIdentity,
            .remote(providerID: "youtube", remoteID: "durable-id"),
            "remote library rows should expose an explicit durable identity"
        )
        expect(item.localURL, nil, "remote library rows must not expose a local file URL")
        guard let immediateOpen = viewModel.remoteWindowOpenRequest(
            for: item,
            startsFromBeginning: true
        ) else {
            fputs("FAIL: remote library rows should create immediate window requests\n", stderr)
            exit(1)
        }
        expect(
            immediateOpen.identity,
            resolved.identity,
            "remote window requests should use durable identity instead of signed streams"
        )
        expect(
            immediateOpen.startsFromBeginning,
            true,
            "remote window requests should preserve play-from-beginning intent"
        )
        expect(
            immediateOpen.forceRefresh,
            false,
            "remote items with resolved subtitle metadata should allow resolver cache reuse"
        )

        viewModel.displayMode = .missing
        expect(
            !viewModel.sections().flatMap(\.rows).contains { $0.item.id == item.id },
            true,
            "remote rows should not be classified as missing local files"
        )
        viewModel.displayMode = .unwatched
        expect(
            viewModel.sections().flatMap(\.rows).contains { $0.item.id == item.id },
            true,
            "new remote rows should appear in Unwatched"
        )

        let savedJSON = try String(contentsOf: fileURL, encoding: .utf8)
        expect(
            !savedJSON.contains("googlevideo-signed.mp4"),
            true,
            "remote catalog must not persist signed playback stream URLs"
        )
        expect(
            !savedJSON.contains("httpHeaders"),
            true,
            "remote catalog must not persist ephemeral HTTP headers"
        )

        let futureProviderSource = remoteSource(
            title: "Future Provider Fixture",
            providerID: "future-provider",
            remoteID: "future-id",
            mediaURL: URL(string: "https://cdn.example/future.mp4")!
        )
        _ = store.addRemoteItem(futureProviderSource)
        let reloadedStore = VideoLibraryStore(fileURL: fileURL)
        expect(
            reloadedStore.catalog.remoteItems.first {
                $0.identity.remoteID == "future-id"
            }?.identity.providerID,
            "future-provider",
            "an unknown future provider should not make the catalog fail to decode"
        )
    }

    @MainActor
    private static func testLegacyRemoteCatalogMigratesWithoutEphemeralStreams() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-video-library-legacy-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("library.json")
        let legacyJSON = """
        {
          "sources": [],
          "items": [],
          "remoteItems": [
            {
              "identity": {
                "provider": "ytdlp",
                "remoteID": "legacy-id",
                "originalURL": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                "title": "Legacy Remote"
              },
              "providerID": "ytdlp",
              "originalURL": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
              "resolvedSource": {
                "playbackStream": {
                  "url": "https://cdn.example/legacy-signed.mp4"
                }
              },
              "resolvedAt": 100,
              "subtitleLanguage": "ja"
            }
          ],
          "itemMetadataByPath": {},
          "collections": []
        }
        """
        try Data(legacyJSON.utf8).write(to: fileURL)

        let store = VideoLibraryStore(fileURL: fileURL)
        expect(store.catalog.remoteItems.count, 1, "legacy remote item should decode")
        expect(
            store.catalog.remoteItems[0].hasResolvedSubtitleMetadata,
            true,
            "legacy rows with a remembered subtitle should not force a metadata refresh"
        )
        let item = store.catalog.remoteItems[0].libraryItem
        store.setFavorite(true, for: item)

        let migratedJSON = try String(contentsOf: fileURL, encoding: .utf8)
        expect(
            migratedJSON.contains("legacy-signed.mp4"),
            false,
            "saving a legacy remote catalog should discard ephemeral stream data"
        )
        expect(
            migratedJSON.contains("\"providerID\" : \"youtube\""),
            true,
            "legacy provider enum should migrate to a forward-compatible provider id"
        )
    }

    @MainActor
    private static func testOpeningRemoteVideoRefreshesResolvedStreams() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-video-library-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VideoLibraryStore(fileURL: root.appendingPathComponent("library.json"))
        let staleSource = remoteSource(
            mediaURL: URL(string: "https://cdn.example/stale.mp4")!
        )
        let freshSource = remoteSource(
            mediaURL: URL(string: "https://cdn.example/fresh.mp4")!
        )
        let remoteItem = store.addRemoteItem(staleSource)
        let viewModel = VideoLibraryViewModel(
            store: store,
            remoteResolver: RemoteVideoResolverRegistry(resolvers: [
                FixedRemoteVideoResolver(source: freshSource)
            ])
        )

        guard let playbackSource = await viewModel.openPlaybackSource(for: remoteItem.libraryItem) else {
            fputs("FAIL: expected refreshed remote playback source\n", stderr)
            exit(1)
        }
        guard case .remoteStream(let resolvedSource) = playbackSource else {
            fputs("FAIL: expected remote playback source\n", stderr)
            exit(1)
        }

        expect(
            resolvedSource.playbackStream.url,
            URL(string: "https://cdn.example/fresh.mp4")!,
            "remote library open should re-resolve the playback URL"
        )
        expect(
            viewModel.catalog.remoteItems.first?.identity,
            freshSource.identity,
            "remote library open should persist refreshed durable metadata"
        )
        let savedJSON = try String(
            contentsOf: root.appendingPathComponent("library.json"),
            encoding: .utf8
        )
        expect(
            savedJSON.contains("https://cdn.example/fresh.mp4"),
            false,
            "remote library open must not persist refreshed stream URLs"
        )
    }

    @MainActor
    private static func testCaptionlessRemoteVideoRespectsResolutionCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-video-library-captionless-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = VideoLibraryStore(fileURL: root.appendingPathComponent("library.json"))
        let source = ResolvedRemoteVideoSource(
            identity: RemoteVideoIdentity(
                providerID: "youtube",
                remoteID: "captionless-cache",
                originalURL: URL(string: "https://www.youtube.com/watch?v=captionless-cache")!,
                canonicalURL: nil,
                title: "Captionless Cache",
                thumbnailURL: nil
            ),
            playbackStream: RemoteVideoStream(
                url: URL(string: "https://cdn.example/captionless.mp4")!,
                formatID: "video",
                height: 720,
                hasVideo: true,
                hasAudio: true
            ),
            audioStream: nil,
            miningStream: nil,
            subtitleOptions: [],
            selectedSubtitleLanguage: nil,
            resolvedAt: Date(),
            expiresAt: Date().addingTimeInterval(300)
        )
        let item = store.addRemoteItem(source).libraryItem
        let counter = CountingRemoteResolverState()
        let viewModel = VideoLibraryViewModel(
            store: store,
            remoteResolver: RemoteVideoResolverRegistry(
                resolvers: [CountingRemoteVideoResolver(source: source, state: counter)],
                cache: RemoteVideoResolutionCache()
            )
        )

        expect(await viewModel.openPlaybackSource(for: item) != nil, true, "first remote open should resolve")
        expect(await viewModel.openPlaybackSource(for: item) != nil, true, "second remote open should reuse cache")
        expect(
            await counter.resolutionCount(),
            1,
            "captionless videos should honor the resolver cache instead of refreshing on every open"
        )
    }

    @MainActor
    private static func testStaleRemoteOpenCompletionIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-video-library-stale-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VideoLibraryStore(fileURL: root.appendingPathComponent("library.json"))
        let firstSaved = remoteSource(
            remoteID: "stale-open-first",
            mediaURL: URL(string: "https://cdn.example/first-old.mp4")!
        )
        let secondSaved = remoteSource(
            remoteID: "stale-open-second",
            mediaURL: URL(string: "https://cdn.example/second-old.mp4")!
        )
        let firstItem = store.addRemoteItem(firstSaved).libraryItem
        let secondItem = store.addRemoteItem(secondSaved).libraryItem
        let controlled = ControlledRemoteResolverStore()
        let viewModel = VideoLibraryViewModel(
            store: store,
            remoteResolver: RemoteVideoResolverRegistry(
                resolvers: [ControlledRemoteVideoResolver(store: controlled)],
                cache: RemoteVideoResolutionCache()
            )
        )

        let firstTask = Task {
            await viewModel.openPlaybackSource(for: firstItem)
        }
        await controlled.waitForPendingCount(1)
        let secondTask = Task {
            await viewModel.openPlaybackSource(for: secondItem)
        }
        await controlled.waitForPendingCount(2)

        let secondFresh = remoteSource(
            title: "Second Fresh",
            remoteID: "stale-open-second",
            mediaURL: URL(string: "https://cdn.example/second-fresh.mp4")!
        )
        await controlled.resume(remoteID: "stale-open-second", with: secondFresh)
        let secondResult = await secondTask.value
        let firstFresh = remoteSource(
            title: "First Stale Completion",
            remoteID: "stale-open-first",
            mediaURL: URL(string: "https://cdn.example/first-fresh.mp4")!
        )
        await controlled.resume(remoteID: "stale-open-first", with: firstFresh)
        let firstResult = await firstTask.value

        expect(firstResult == nil, true, "an older remote open completion should be ignored")
        guard case .remoteStream(let secondSource) = secondResult else {
            fputs("FAIL: newest remote open should succeed\n", stderr)
            exit(1)
        }
        expect(secondSource.identity.title, "Second Fresh", "newest remote result should win")
        expect(
            viewModel.catalog.remoteItems.first { $0.identity.remoteID == "stale-open-first" }?.identity.title,
            firstSaved.identity.title,
            "stale completion must not update durable catalog metadata"
        )
    }

    @MainActor
    private static func testOpenFromBeginningClearsProgressOnlyAfterSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-video-library-open-beginning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VideoLibraryStore(fileURL: root.appendingPathComponent("library.json"))
        let savedSource = remoteSource(
            remoteID: "open-beginning",
            mediaURL: URL(string: "https://cdn.example/open-beginning-old.mp4")!
        )
        let item = store.addRemoteItem(savedSource).libraryItem
        let suiteName = "moe.shishamo.hoshi.tests.open-beginning-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let history = VideoPlaybackHistoryStore(defaults: defaults)
        history.save(position: 55, duration: 120, for: item.mediaIdentity)

        let failingViewModel = VideoLibraryViewModel(
            store: store,
            historyStore: history,
            remoteResolver: RemoteVideoResolverRegistry(
                resolvers: [FailingRemoteVideoResolver()],
                cache: RemoteVideoResolutionCache()
            )
        )
        let failed = await failingViewModel.openFromBeginningPlaybackSource(for: item)
        expect(failed == nil, true, "failed open-from-beginning should not return a source")
        expect(
            history.position(for: item.mediaIdentity),
            55,
            "failed resolution must preserve remote playback progress"
        )

        let freshSource = remoteSource(
            remoteID: "open-beginning",
            mediaURL: URL(string: "https://cdn.example/open-beginning-fresh.mp4")!
        )
        let successfulViewModel = VideoLibraryViewModel(
            store: store,
            historyStore: history,
            remoteResolver: RemoteVideoResolverRegistry(
                resolvers: [FixedRemoteVideoResolver(source: freshSource)],
                cache: RemoteVideoResolutionCache()
            )
        )
        let succeeded = await successfulViewModel.openFromBeginningPlaybackSource(for: item)
        expect(succeeded != nil, true, "successful open-from-beginning should return a source")
        expect(
            history.position(for: item.mediaIdentity),
            nil,
            "progress should clear only after resolution succeeds"
        )
    }

    @MainActor
    private static func testRemovingRemoteItemIsCatalogOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-video-library-remove-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("must-not-delete.mp4")
        try Data("sentinel".utf8).write(to: sentinel)
        let store = VideoLibraryStore(fileURL: root.appendingPathComponent("library.json"))
        let source = remoteSource(
            remoteID: "remove-remote",
            mediaURL: URL(string: "https://cdn.example/remove-remote.mp4")!
        )
        let item = store.addRemoteItem(source).libraryItem
        store.setFavorite(true, for: item)
        _ = store.createCollection(name: "Remote Collection", itemPaths: [item.path])
        let viewModel = VideoLibraryViewModel(store: store)

        viewModel.removeRemoteItem(item)

        expect(viewModel.catalog.remoteItems.isEmpty, true, "remote removal should delete catalog metadata")
        expect(viewModel.catalog.itemMetadataByPath[item.path] == nil, true, "remote removal should delete row metadata")
        expect(viewModel.catalog.collections[0].itemPaths.isEmpty, true, "remote removal should delete collection references")
        expect(FileManager.default.fileExists(atPath: sentinel.path), true, "remote removal must not delete filesystem items")
    }
}

private struct FixedRemoteVideoResolver: RemoteVideoResolving {
    let source: ResolvedRemoteVideoSource
    var provider: RemoteVideoProvider { .youtube }

    func canResolve(url: URL) -> Bool {
        true
    }

    func resolve(
        url: URL,
        preferredSubtitleLanguages: [String]
    ) async throws -> ResolvedRemoteVideoSource {
        source
    }
}

private actor CountingRemoteResolverState {
    private var count = 0

    func recordResolution() {
        count += 1
    }

    func resolutionCount() -> Int {
        count
    }
}

private struct CountingRemoteVideoResolver: RemoteVideoResolving {
    let source: ResolvedRemoteVideoSource
    let state: CountingRemoteResolverState
    var provider: RemoteVideoProvider { .youtube }

    func canResolve(url: URL) -> Bool { true }

    func resolve(
        url: URL,
        preferredSubtitleLanguages: [String]
    ) async throws -> ResolvedRemoteVideoSource {
        await state.recordResolution()
        return source
    }
}

private actor ControlledRemoteResolverStore {
    private var continuations: [String: CheckedContinuation<ResolvedRemoteVideoSource, Never>] = [:]

    func resolve(url: URL) async -> ResolvedRemoteVideoSource {
        let remoteID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value
            ?? url.lastPathComponent
        return await withCheckedContinuation { continuation in
            continuations[remoteID] = continuation
        }
    }

    func waitForPendingCount(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func resume(remoteID: String, with source: ResolvedRemoteVideoSource) {
        continuations.removeValue(forKey: remoteID)?.resume(returning: source)
    }
}

private struct ControlledRemoteVideoResolver: RemoteVideoResolving {
    let store: ControlledRemoteResolverStore
    var provider: RemoteVideoProvider { .youtube }

    func canResolve(url: URL) -> Bool { true }

    func resolve(
        url: URL,
        preferredSubtitleLanguages: [String]
    ) async throws -> ResolvedRemoteVideoSource {
        await store.resolve(url: url)
    }
}

private struct FailingRemoteVideoResolver: RemoteVideoResolving {
    var provider: RemoteVideoProvider { .youtube }

    func canResolve(url: URL) -> Bool { true }

    func resolve(
        url: URL,
        preferredSubtitleLanguages: [String]
    ) async throws -> ResolvedRemoteVideoSource {
        throw RemoteVideoResolverError.noPlayableStream
    }
}
