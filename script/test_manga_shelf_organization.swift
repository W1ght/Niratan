// test-sources: Features/Bookshelf/LibraryShelfSelection.swift Features/Manga/MangaLibraryStore.swift Features/Manga/MangaLibraryViewModel.swift Features/Manga/MangaPageLoader.swift Models/Manga.swift Features/Manga/MangaEPUBParser.swift Features/Manga/MangaMokuroParser.swift
// test-modules: ZIPFoundation
import Foundation
import ZIPFoundation

@main
private enum MangaShelfOrganizationTests {
    static func main() async throws {
        if let archivePath = ProcessInfo.processInfo.environment["HOSHI_TEST_MANGA_ARCHIVE"],
           !archivePath.isEmpty {
            try await testRealArchive(at: URL(fileURLWithPath: archivePath))
            return
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("hoshi-manga-shelf-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Example Manga", isDirectory: true)
        let catalogURL = root.appendingPathComponent("catalog.json")
        let coverDirectory = root.appendingPathComponent("covers", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII="
        )!
        try await testPlainImageSources(
            inside: root.appendingPathComponent("plain-imports", isDirectory: true),
            png: png,
            fileManager: fileManager
        )
        try png.write(to: sourceDirectory.appendingPathComponent("001.png"))
        try png.write(to: sourceDirectory.appendingPathComponent("002.png"))
        let metadata = """
        {
          "pages": [
            {"img_path":"001.png","img_width":1,"img_height":1,"blocks":[]},
            {"img_path":"002.png","img_width":1,"img_height":1,"blocks":[]}
          ]
        }
        """
        try Data(metadata.utf8).write(
            to: sourceDirectory.appendingPathComponent("mokuro.json")
        )

        let store = MangaLibraryStore(
            fileURL: catalogURL,
            coverDirectory: coverDirectory,
            fileManager: fileManager
        )
        let source = try await store.addSource(url: sourceDirectory)
        try await store.scanSource(id: source.id)
        var catalog = await store.snapshot()
        require(catalog.items.count == 1, "the fixture should import one manga")
        let item = catalog.items[0]

        try await store.setCover(itemID: item.id, imageData: png)
        catalog = await store.snapshot()
        let customCoverPath = try requireValue(
            catalog.items.first?.coverCachePath,
            "setting a manga cover should persist a cache path"
        )
        require(
            URL(fileURLWithPath: customCoverPath).lastPathComponent.hasPrefix("custom-"),
            "a user-selected manga cover should use a stable custom cache name"
        )
        require(
            fileManager.fileExists(atPath: customCoverPath),
            "setting a manga cover should write the app-owned cover cache"
        )
        try await store.scanSource(id: source.id)
        catalog = await store.snapshot()
        require(
            catalog.items.first?.coverCachePath == customCoverPath,
            "refreshing a manga source should retain the user-selected cover"
        )

        await store.createShelf(name: "Favorites")
        catalog = await store.snapshot()
        let shelf = try requireValue(catalog.shelves.first, "a shelf should be created")
        await store.moveItems([item.id], to: shelf.id)
        await store.renameItem(id: item.id, title: "Renamed Manga")
        let openedAt = Date(timeIntervalSince1970: 1_700_000_000)
        await store.recordOpened(itemID: item.id, now: openedAt)
        catalog = await store.snapshot()
        require(
            catalog.items.first?.lastReadAt == openedAt,
            "opening a manga should record it as recently read even on its first page"
        )
        await store.markRead(itemID: item.id)
        catalog = await store.snapshot()
        require(
            catalog.shelves.first?.itemIDs == [item.id],
            "moving a manga should persist shelf membership"
        )

        let explicitShelfID = UUID()
        await store.createShelf(name: "Later", id: explicitShelfID)
        await store.renameShelf(id: shelf.id, name: "  Best  ")
        await store.renameShelf(id: explicitShelfID, name: "best")
        catalog = await store.snapshot()
        require(
            catalog.shelves.map(\.id) == [shelf.id, explicitShelfID]
                && catalog.shelves.map(\.name) == ["Best", "Later"],
            "renaming a manga shelf should keep its id and position, trim the name, and reject duplicates"
        )
        require(
            catalog.shelves.first?.itemIDs == [item.id],
            "renaming a manga shelf should keep its items"
        )
        await store.deleteShelf(id: explicitShelfID)
        require(
            catalog.items.first?.displayTitle == "Renamed Manga",
            "renaming should persist a display title"
        )
        require(
            catalog.items.first?.progress == 1,
            "marking a manga read should move progress to the last page"
        )
        let newestProgressDate = Date().addingTimeInterval(120)
        let staleProgressDate = newestProgressDate.addingTimeInterval(-60)
        await store.updateProgress(
            itemID: item.id,
            pageIndex: 0,
            updatedAt: newestProgressDate
        )
        await store.updateProgress(
            itemID: item.id,
            pageIndex: 1,
            updatedAt: staleProgressDate
        )
        catalog = await store.snapshot()
        require(
            catalog.items.first?.currentPageIndex == 0,
            "an older asynchronous progress write must not overwrite the newest page"
        )

        await store.removeItemsFromLibrary([item.id])
        try await store.scanSource(id: source.id)
        catalog = await store.snapshot()
        require(
            catalog.hiddenItemIDs.contains(item.id),
            "refreshing a source must not restore an explicitly removed manga"
        )
        require(
            catalog.shelves.first?.itemIDs.isEmpty == true,
            "removing a manga should remove its shelf membership"
        )
        require(
            fileManager.fileExists(atPath: sourceDirectory.appendingPathComponent("001.png").path),
            "removing a manga from the library must not delete source media"
        )

        _ = try await store.addSource(url: sourceDirectory)
        try await store.scanSource(id: source.id)
        catalog = await store.snapshot()
        require(
            !catalog.hiddenItemIDs.contains(item.id),
            "explicitly importing the same source should restore removed manga"
        )
        require(
            catalog.items.first?.displayTitle == "Renamed Manga",
            "restoring a manga should retain its renamed title"
        )

        let reloadedStore = MangaLibraryStore(
            fileURL: catalogURL,
            coverDirectory: coverDirectory,
            fileManager: fileManager
        )
        let reloaded = await reloadedStore.snapshot()
        require(
            reloaded.items.first?.displayTitle == "Renamed Manga",
            "organization changes should survive a catalog reload"
        )
        require(
            reloaded.hiddenItemIDs.isEmpty,
            "the restored visibility should survive a catalog reload"
        )

        let externalCoverURL = root.appendingPathComponent("custom-user-source.jpg")
        try png.write(to: externalCoverURL)
        var catalogWithExternalCover = reloaded
        catalogWithExternalCover.items[0].coverCachePath = externalCoverURL.path
        let safetyCatalogURL = root.appendingPathComponent("safety-catalog.json")
        try JSONEncoder().encode(catalogWithExternalCover).write(
            to: safetyCatalogURL,
            options: .atomic
        )
        let safetyStore = MangaLibraryStore(
            fileURL: safetyCatalogURL,
            coverDirectory: coverDirectory,
            fileManager: fileManager
        )
        await safetyStore.removeSource(id: source.id)
        require(
            fileManager.fileExists(atPath: externalCoverURL.path),
            "removing a source must never delete a cover path outside Niratan's cover cache"
        )

        var catalogWithInvalidBookmark = reloaded
        catalogWithInvalidBookmark.sources[0].bookmark = Data([0])
        try JSONEncoder().encode(catalogWithInvalidBookmark).write(
            to: catalogURL,
            options: .atomic
        )
        let repairedStore = MangaLibraryStore(
            fileURL: catalogURL,
            coverDirectory: coverDirectory,
            fileManager: fileManager
        )
        let repairedSource = try await repairedStore.addSource(url: sourceDirectory)
        try await repairedStore.scanSource(id: repairedSource.id)
        let repaired = await repairedStore.snapshot()
        require(
            repaired.sources.first?.bookmark != Data([0]),
            "explicitly importing the same source should replace an invalid bookmark"
        )
        require(
            repaired.items.first?.displayTitle == "Renamed Manga",
            "repairing source access should preserve manga metadata and progress"
        )

        let preferencesName = "moe.shishamo.hoshi.tests.manga-shelf-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: preferencesName)!
        preferences.removePersistentDomain(forName: preferencesName)
        let viewModel = await MainActor.run {
            MangaLibraryViewModel(
                store: repairedStore,
                preferences: preferences
            )
        }
        let startsUnloaded = await MainActor.run { !viewModel.hasLoadedCatalog }
        require(
            startsUnloaded,
            "a new manga library model should distinguish loading from a confirmed empty catalog"
        )
        await MainActor.run {
            viewModel.load()
        }
        for _ in 0..<20 {
            let didLoad = await MainActor.run {
                !viewModel.visibleItems.isEmpty
            }
            if didLoad {
                break
            }
            await Task.yield()
        }
        let visibleSections = await MainActor.run {
            viewModel.sections().filter { !$0.items.isEmpty }
        }
        let finishedInitialLoad = await MainActor.run { viewModel.hasLoadedCatalog }
        require(
            finishedInitialLoad,
            "the manga library should publish completion after its first catalog snapshot"
        )
        require(
            visibleSections.contains(where: {
                $0.shelf == nil && $0.items.contains(where: { $0.id == item.id })
            }),
            "an imported manga should immediately produce a visible unshelved card section"
        )
        preferences.removePersistentDomain(forName: preferencesName)

        print("Manga shelf organization tests passed")
    }

    private static func testPlainImageSources(
        inside root: URL,
        png: Data,
        fileManager: FileManager
    ) async throws {
        let imageFolder = root.appendingPathComponent("Plain Folder", isDirectory: true)
        let emptyFolder = root.appendingPathComponent("Empty Folder", isDirectory: true)
        let archiveURL = root.appendingPathComponent("Plain Archive.cbz")
        try fileManager.createDirectory(at: imageFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        try png.write(to: imageFolder.appendingPathComponent("10.png"))
        try png.write(to: imageFolder.appendingPathComponent("2.png"))

        let archive = try Archive(url: archiveURL, accessMode: .create, pathEncoding: .utf8)
        try archive.addData(png, at: "pages/10.png")
        try archive.addData(png, at: "pages/2.png")
        try archive.addData(Data("resource fork".utf8), at: "__MACOSX/pages/._2.png")
        try archive.addData(Data("ignored".utf8), at: "notes.txt")

        let store = MangaLibraryStore(
            fileURL: root.appendingPathComponent("catalog.json"),
            coverDirectory: root.appendingPathComponent("covers", isDirectory: true),
            fileManager: fileManager
        )
        let folderSource = try await store.addSource(url: imageFolder)
        require(
            folderSource.kind == .imageFolder,
            "a directly selected ordinary image folder should use the non-recursive source kind"
        )
        try await store.scanSource(id: folderSource.id)

        let archiveSource = try await store.addSource(url: archiveURL)
        require(
            archiveSource.kind == .archive,
            "an ordinary CBZ should persist as an archive source without Mokuro metadata"
        )
        try await store.scanSource(id: archiveSource.id)

        let catalog = await store.snapshot()
        let folderItem = try requireValue(
            catalog.items.first(where: { $0.sourceID == folderSource.id }),
            "an ordinary image folder should create one manga"
        )
        let archiveItem = try requireValue(
            catalog.items.first(where: { $0.sourceID == archiveSource.id }),
            "an ordinary CBZ should create one manga"
        )
        require(
            folderItem.containerKind == .directory
                && folderItem.relativePath == "."
                && folderItem.pageCount == 2,
            "an ordinary image folder should index only its directly selected pages"
        )
        require(
            archiveItem.containerKind == .zipArchive
                && archiveItem.relativePath.isEmpty
                && archiveItem.pageCount == 2,
            "an ordinary CBZ should index image entries without requiring Mokuro"
        )
        require(
            archiveItem.coverCachePath.map {
                fileManager.fileExists(atPath: $0)
            } == true,
            "an ordinary CBZ should cache its first page as a cover"
        )

        let folderLoader = try MangaPageLoader(item: folderItem, source: folderSource)
        let archiveLoader = try MangaPageLoader(item: archiveItem, source: archiveSource)
        require(
            folderLoader.pages.map(\.path) == ["2.png", "10.png"],
            "ordinary image folders should use natural page ordering"
        )
        require(
            archiveLoader.pages.map(\.path) == ["pages/2.png", "pages/10.png"],
            "ordinary CBZ archives should use natural page ordering"
        )
        let firstArchivePage = try archiveLoader.imageData(at: 0)
        require(
            firstArchivePage == png,
            "ordinary CBZ pages should load through the shared bounded archive reader"
        )

        do {
            _ = try await store.addSource(url: emptyFolder)
            require(false, "an empty ordinary folder should not be imported")
        } catch MangaLibraryStoreError.noReadablePages {
            // Expected: invalid selections must not leave an empty source in the catalog.
        }
    }

    private static func testRealArchive(at archiveURL: URL) async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("hoshi-manga-archive-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let store = MangaLibraryStore(
            fileURL: root.appendingPathComponent("catalog.json"),
            coverDirectory: root.appendingPathComponent("covers", isDirectory: true),
            fileManager: fileManager
        )
        let source = try await store.addSource(url: archiveURL)
        try await store.scanSource(id: source.id)
        var catalog = await store.snapshot()
        require(catalog.sources.count == 1, "the selected archive should persist as one source")
        require(catalog.items.count == 2, "the selected archive should expose its two Mokuro volumes")
        require(
            catalog.items.allSatisfy { $0.pageCount > 0 },
            "every imported archive volume should have visible pages"
        )
        let openedItem = catalog.items[0]
        await store.recordOpened(itemID: openedItem.id)
        catalog = await store.snapshot()

        let preferencesName = "moe.shishamo.hoshi.tests.real-manga-archive-\(UUID().uuidString)"
        let viewModel = await MainActor.run {
            let preferences = UserDefaults(suiteName: preferencesName)!
            preferences.removePersistentDomain(forName: preferencesName)
            return MangaLibraryViewModel(store: store, preferences: preferences)
        }
        await MainActor.run {
            viewModel.load()
        }
        for _ in 0..<20 {
            if await MainActor.run(body: { viewModel.visibleItems.count == 2 }) {
                break
            }
            await Task.yield()
        }
        let visibleItems = await MainActor.run { viewModel.visibleItems }
        let visibleSections = await MainActor.run {
            viewModel.sections().filter { !$0.items.isEmpty }
        }
        require(visibleItems.count == 2, "both imported volumes should be visible to the library")
        require(
            visibleSections.contains(where: { $0.shelf == nil && $0.items.count == 2 }),
            "the imported volumes should appear immediately in Unshelved"
        )
        require(
            visibleSections.contains(where: {
                $0.isReading
                    && $0.items.map(\.id) == [openedItem.id]
            }),
            "an opened unfinished volume should also appear in Reading from its first page"
        )
        UserDefaults(suiteName: preferencesName)?
            .removePersistentDomain(forName: preferencesName)

        print(
            "Real manga archive import passed:",
            catalog.items.map { "\($0.displayTitle) (\($0.pageCount) pages)" }.joined(separator: ", ")
        )
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        return value
    }
}

private extension Archive {
    func addData(
        _ data: Data,
        at path: String,
        compressionMethod: CompressionMethod = .deflate
    ) throws {
        try addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compressionMethod
        ) { position, size in
            let start = Int(position)
            let end = Swift.min(start + size, data.count)
            return data.subdata(in: start..<end)
        }
    }
}
