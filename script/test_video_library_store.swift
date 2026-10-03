// test-sources: Features/Video/VideoLibraryStore.swift Features/Video/Remote/RemoteVideoSource.swift Features/Video/VideoMediaTypes.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func makeDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hoshi-video-library-\(UUID().uuidString)")
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func touch(_ url: URL, modified: Date = Date(), size: Int = 1) throws {
    let data = Data(repeating: 0x31, count: max(size, 0))
    FileManager.default.createFile(atPath: url.path, contents: data)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}

@main
private enum VideoLibraryStoreTests {
    static func main() throws {
        try testScanFiltersSortsAndDedupesMediaFiles()
        try testSuccessfulRescanRemovesStaleItems()
        try testFailedScanPreservesExistingItemsAndRecordsError()
        try testItemMetadataCollectionsSubtitleBindingAndMissingCleanup()
        try testRemovingCollectionKeepsVideoItemsAndFiles()
        try testSmartCollectionsPersistAndSurviveMissingCleanup()
        try testCatalogRoundTripAndSourceRemoval()
        try testLegacyCatalogDecodesWithEmptyV3Metadata()
        try testLegacyManualCollectionsDecodeWithDefaultKind()
        print("Video library store tests passed")
    }

    private static func testScanFiltersSortsAndDedupesMediaFiles() throws {
        let root = try makeDirectory("source")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let nested = root.appendingPathComponent("Season 1", isDirectory: true)
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

        let episode2 = nested.appendingPathComponent("Episode 2.mkv")
        let episode1 = root.appendingPathComponent("Episode 1.mp4")
        try touch(episode2, modified: Date(timeIntervalSince1970: 20), size: 20)
        try touch(episode1, modified: Date(timeIntervalSince1970: 10), size: 10)
        try touch(root.appendingPathComponent("notes.txt"))
        try touch(hidden.appendingPathComponent("Hidden Episode.mp4"))

        let fileURL = root.deletingLastPathComponent().appendingPathComponent("library.json")
        let store = VideoLibraryStore(fileURL: fileURL, fileManager: .default)
        let source = try store.addSource(folderURL: root)
        try store.scanSource(id: source.id)

        expect(store.catalog.sources.count == 1, "adding a folder should create one source")
        expect(store.catalog.items.map(\.title) == ["Episode 1", "Episode 2"], "scan should include supported media recursively and sort naturally")
        expect(store.catalog.items.map(\.fileSize) == [10, 20], "scan should record file sizes")
        expect(store.catalog.items.allSatisfy { $0.sourceID == source.id }, "items should keep their source id")
        expect(store.catalog.items.allSatisfy { !$0.path.contains(".hidden") }, "scan should skip hidden directories")

        let duplicate = try store.addSource(folderURL: root)
        try store.scanSource(id: duplicate.id)
        let uniquePaths = Set(store.catalog.items.map(\.path))
        expect(uniquePaths.count == store.catalog.items.count, "scan should de-dupe items by standardized path across sources")
    }

    private static func testSuccessfulRescanRemovesStaleItems() throws {
        let root = try makeDirectory("stale")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let episode = root.appendingPathComponent("Episode.mkv")
        try touch(episode)

        let store = VideoLibraryStore(
            fileURL: root.deletingLastPathComponent().appendingPathComponent("library.json"),
            fileManager: .default
        )
        let source = try store.addSource(folderURL: root)
        try store.scanSource(id: source.id)
        expect(store.catalog.items.count == 1, "initial scan should find the episode")

        try FileManager.default.removeItem(at: episode)
        try store.scanSource(id: source.id)
        expect(store.catalog.items.isEmpty, "successful rescan should remove stale items from that source")
    }

    private static func testFailedScanPreservesExistingItemsAndRecordsError() throws {
        let root = try makeDirectory("failure")
        let parent = root.deletingLastPathComponent()
        let episode = root.appendingPathComponent("Episode.mkv")
        try touch(episode)

        let store = VideoLibraryStore(
            fileURL: parent.appendingPathComponent("library.json"),
            fileManager: .default
        )
        let source = try store.addSource(folderURL: root)
        try store.scanSource(id: source.id)
        expect(store.catalog.items.count == 1, "initial scan should find the episode")

        try FileManager.default.removeItem(at: root)
        do {
            try store.scanSource(id: source.id)
            expect(false, "scan should throw when the whole source is unavailable")
        } catch {
            expect(store.catalog.items.count == 1, "failed whole-source scan should preserve existing items")
            expect(store.catalog.sources.first?.lastError?.isEmpty == false, "failed scan should record source error")
        }
        try? FileManager.default.removeItem(at: parent)
    }

    private static func testItemMetadataCollectionsSubtitleBindingAndMissingCleanup() throws {
        let root = try makeDirectory("metadata")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let show = root.appendingPathComponent("Show A", isDirectory: true)
        try FileManager.default.createDirectory(at: show, withIntermediateDirectories: true)
        let episode = show.appendingPathComponent("Episode 01.mkv")
        let subtitle = show.appendingPathComponent("Episode 01.ja.srt")
        try touch(episode)
        try touch(subtitle)

        let fileURL = root.deletingLastPathComponent().appendingPathComponent("library.json")
        let store = VideoLibraryStore(fileURL: fileURL, fileManager: .default)
        let source = try store.addSource(folderURL: root)
        try store.scanSource(id: source.id)
        let item = store.catalog.items[0]

        store.setDisplayTitle("Custom Episode", for: item)
        store.setFavorite(true, for: item)
        store.setTags(["Anime", "Listening"], for: item)
        store.bindSubtitle(subtitle, for: item)
        let collection = store.createCollection(name: "Weekend", itemPaths: [item.path])

        let reloaded = VideoLibraryStore(fileURL: fileURL, fileManager: .default)
        let metadata = reloaded.metadata(forPath: item.path)
        expect(metadata.displayTitle == "Custom Episode", "display title should persist")
        expect(metadata.isFavorite, "favorite state should persist")
        expect(metadata.tags == ["Anime", "Listening"], "tags should persist sorted by user order without duplicates")
        expect(metadata.boundSubtitlePath == subtitle.standardizedFileURL.path, "bound subtitle path should persist")
        expect(reloaded.catalog.collections.map(\.name) == ["Weekend"], "custom collections should persist")
        expect(
            reloaded.catalog.collections.first?.itemPaths == [item.path],
            "custom collections should keep item paths"
        )

        try FileManager.default.removeItem(at: episode)
        let removedCount = reloaded.removeMissingItems(sourceID: source.id)
        expect(removedCount == 1, "missing cleanup should remove one stale item")
        expect(reloaded.catalog.items.isEmpty, "missing cleanup should remove stale items from catalog")
        expect(
            reloaded.metadata(forPath: item.path) == VideoLibraryItemMetadata(),
            "missing cleanup should remove metadata for stale items"
        )
        expect(
            reloaded.catalog.collections.first(where: { $0.id == collection.id })?.itemPaths.isEmpty == true,
            "missing cleanup should remove stale item paths from collections"
        )
    }

    private static func testRemovingCollectionKeepsVideoItemsAndFiles() throws {
        let root = try makeDirectory("remove-collection")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let episode = root.appendingPathComponent("Episode 01.mkv")
        try touch(episode)

        let fileURL = root.deletingLastPathComponent().appendingPathComponent("library.json")
        let store = VideoLibraryStore(fileURL: fileURL, fileManager: .default)
        let source = try store.addSource(folderURL: root)
        try store.scanSource(id: source.id)
        let item = store.catalog.items[0]

        store.setDisplayTitle("Keep Me", for: item)
        let collection = store.createCollection(name: "Weekend", itemPaths: [item.path])
        expect(
            store.metadata(forPath: item.path).collectionIDs == [collection.id],
            "created collection should add item membership metadata"
        )

        store.removeCollection(id: collection.id)

        expect(store.catalog.collections.isEmpty, "removing a collection should remove only collection metadata")
        expect(store.catalog.items.map(\.path) == [item.path], "removing a collection should keep catalog video items")
        expect(FileManager.default.fileExists(atPath: episode.path), "removing a collection should not delete video files")
        let metadata = store.metadata(forPath: item.path)
        expect(metadata.displayTitle == "Keep Me", "removing a collection should preserve unrelated item metadata")
        expect(metadata.collectionIDs.isEmpty, "removing a collection should clear only collection membership metadata")
    }

    private static func testCatalogRoundTripAndSourceRemoval() throws {
        let root = try makeDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try touch(root.appendingPathComponent("Movie.webm"))
        let fileURL = root.deletingLastPathComponent().appendingPathComponent("library.json")

        let store = VideoLibraryStore(fileURL: fileURL, fileManager: .default)
        let source = try store.addSource(folderURL: root)
        try store.scanSource(id: source.id)

        let reloaded = VideoLibraryStore(fileURL: fileURL, fileManager: .default)
        expect(reloaded.catalog.sources.map(\.path) == [root.standardizedFileURL.path], "catalog should persist sources")
        expect(reloaded.catalog.items.map(\.title) == ["Movie"], "catalog should persist scanned items")

        reloaded.removeSource(id: source.id)
        expect(reloaded.catalog.sources.isEmpty, "removing a source should remove source metadata")
        expect(reloaded.catalog.items.isEmpty, "removing a source should remove its items")
    }

    private static func testSmartCollectionsPersistAndSurviveMissingCleanup() throws {
        let root = try makeDirectory("smart")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let episode = root.appendingPathComponent("Frieren 01.mkv")
        try touch(episode)
        let fileURL = root.deletingLastPathComponent().appendingPathComponent("library.json")

        let store = VideoLibraryStore(fileURL: fileURL, fileManager: .default)
        let source = try store.addSource(folderURL: root)
        try store.scanSource(id: source.id)
        let smartRule = VideoLibrarySmartRule(
            field: .fileName,
            match: .contains,
            value: "Frieren"
        )
        let smartCollection = store.createSmartCollection(
            name: "Frieren",
            rules: [smartRule]
        )

        let reloaded = VideoLibraryStore(fileURL: fileURL, fileManager: .default)
        expect(
            reloaded.catalog.collections.first == smartCollection,
            "smart collection rules should persist exactly"
        )
        expect(
            reloaded.catalog.collections.first?.kind == .smart,
            "smart collection should persist its kind"
        )
        expect(
            reloaded.catalog.collections.first?.itemPaths == [],
            "smart collection should not persist matched item paths"
        )

        try FileManager.default.removeItem(at: episode)
        let removed = reloaded.removeMissingItems(sourceID: source.id)
        expect(removed == 1, "missing cleanup should remove the stale video item")
        expect(
            reloaded.catalog.collections.first?.smartRules == [smartRule],
            "missing cleanup should preserve smart collection rules"
        )
    }

    private static func testLegacyCatalogDecodesWithEmptyV3Metadata() throws {
        let sourceID = UUID()
        let legacyJSON = """
        {
          "sources" : [
            {
              "id" : "\(sourceID.uuidString)",
              "name" : "Legacy",
              "path" : "/tmp/Legacy",
              "bookmark" : ""
            }
          ],
          "items" : []
        }
        """
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-video-library-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try legacyJSON.data(using: .utf8)!.write(to: fileURL)

        let store = VideoLibraryStore(fileURL: fileURL, fileManager: .default)

        expect(store.catalog.itemMetadataByPath.isEmpty, "legacy catalogs should default item metadata to empty")
        expect(store.catalog.collections.isEmpty, "legacy catalogs should default collections to empty")
    }

    private static func testLegacyManualCollectionsDecodeWithDefaultKind() throws {
        let collectionID = UUID()
        let legacyJSON = """
        {
          "sources" : [],
          "items" : [],
          "itemMetadataByPath" : {},
          "collections" : [
            {
              "id" : "\(collectionID.uuidString)",
              "name" : "Weekend",
              "itemPaths" : [
                "/tmp/one.mkv"
              ]
            }
          ]
        }
        """
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-video-collection-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try legacyJSON.data(using: .utf8)!.write(to: fileURL)

        let store = VideoLibraryStore(fileURL: fileURL, fileManager: .default)

        expect(store.catalog.collections.first?.kind == .manual, "legacy collections should decode as manual")
        expect(store.catalog.collections.first?.smartRules == [], "legacy collections should decode with no smart rules")
        expect(
            store.catalog.collections.first?.itemPaths == ["/tmp/one.mkv"],
            "legacy collections should preserve item paths"
        )
    }
}
