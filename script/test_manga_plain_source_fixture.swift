// test-skip: manual fixture tool (needs an image folder and a CBZ/ZIP argument)
import Foundation

@main
private enum MangaPlainSourceFixtureTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fputs(
                "usage: test_manga_plain_source_fixture <image-folder> <cbz-or-zip>\n",
                stderr
            )
            exit(2)
        }

        let fileManager = FileManager.default
        let folderURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .standardizedFileURL
        let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])
            .standardizedFileURL
        let retainedOutputPath = ProcessInfo.processInfo.environment[
            "HOSHI_TEST_MANGA_FIXTURE_OUTPUT_DIRECTORY"
        ]
        let temporaryRoot = retainedOutputPath.flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        } ?? fileManager.temporaryDirectory.appendingPathComponent(
            "hoshi-manga-plain-source-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer {
            if retainedOutputPath == nil {
                try? fileManager.removeItem(at: temporaryRoot)
            }
        }

        let originalFolderData = try sourceData(in: folderURL, fileManager: fileManager)
        let originalArchiveData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        let store = MangaLibraryStore(
            fileURL: temporaryRoot.appendingPathComponent("catalog.json"),
            coverDirectory: temporaryRoot.appendingPathComponent("covers", isDirectory: true),
            fileManager: fileManager
        )

        let folderSource = try await store.addSource(url: folderURL)
        try await store.scanSource(id: folderSource.id)
        let archiveSource = try await store.addSource(url: archiveURL)
        try await store.scanSource(id: archiveSource.id)

        let catalog = await store.snapshot()
        let folderItem = try requireValue(
            catalog.items.first(where: { $0.sourceID == folderSource.id }),
            "the ordinary image folder should create one library item"
        )
        let archiveItem = try requireValue(
            catalog.items.first(where: { $0.sourceID == archiveSource.id }),
            "the ordinary archive should create one library item"
        )

        require(
            folderSource.kind == .imageFolder
                && folderItem.containerKind == .directory
                && folderItem.relativePath == ".",
            "the selected folder must remain one direct, non-recursive manga source"
        )
        require(
            archiveSource.kind == .archive
                && archiveItem.containerKind == .zipArchive
                && archiveItem.relativePath.isEmpty,
            "the metadata-free CBZ/ZIP must remain one ordinary archive manga"
        )

        let folderLoader = try MangaPageLoader(item: folderItem, source: folderSource)
        let archiveLoader = try MangaPageLoader(item: archiveItem, source: archiveSource)
        let expectedPageNames = ["001", "002", "010"]
        require(
            folderLoader.pages.map {
                URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent
            } == expectedPageNames,
            "the downloaded folder pages should use natural filename ordering"
        )
        require(
            archiveLoader.pages.map {
                URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent
            } == expectedPageNames,
            "the downloaded archive pages should use natural filename ordering"
        )
        for index in folderLoader.pages.indices {
            try require(
                try folderLoader.imageData(at: index).isEmpty == false,
                "every downloaded folder page should decode into readable data"
            )
        }
        for index in archiveLoader.pages.indices {
            try require(
                try archiveLoader.imageData(at: index).isEmpty == false,
                "every downloaded archive page should decode into readable data"
            )
        }
        require(
            folderItem.coverCachePath.map {
                fileManager.fileExists(atPath: $0)
            } == true
                && archiveItem.coverCachePath.map {
                    fileManager.fileExists(atPath: $0)
                } == true,
            "both ordinary source kinds should cache their first page as a cover"
        )
        try require(
            try sourceData(in: folderURL, fileManager: fileManager) == originalFolderData
                && Data(contentsOf: archiveURL, options: [.mappedIfSafe]) == originalArchiveData,
            "importing and reading must not modify downloaded source media"
        )

        print(
            "Plain manga fixture passed: folder \(folderItem.pageCount) pages, "
                + "archive \(archiveItem.pageCount) pages"
        )
        if retainedOutputPath != nil {
            print("Retained fixture catalog at \(temporaryRoot.path)")
        }
    }

    private static func sourceData(
        in folderURL: URL,
        fileManager: FileManager
    ) throws -> [String: Data] {
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try Dictionary(uniqueKeysWithValues: urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, MangaMediaTypes.isImage(url) else {
                return nil
            }
            return (
                url.lastPathComponent,
                try Data(contentsOf: url, options: [.mappedIfSafe])
            )
        })
    }

    private static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) rethrows {
        guard try condition() else {
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
