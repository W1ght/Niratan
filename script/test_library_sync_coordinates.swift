// test-sources: Features/Sync/EPUBSyncCoordinates.swift Util/ReaderCharacterNormalizer.swift Models/Book.swift Models/Highlight.swift Models/Sync.swift Models/Statistics.swift Models/Sasayaki.swift Core/StatisticsStorage.swift Features/Sync/SyncLedger.swift Features/Sync/SyncStorage.swift
// test-modules: EPUBKit AEXML ZIPFoundation SwiftSoup
import Foundation
import ZIPFoundation

enum FileNames {
    static let metadata = "metadata.json", bookmark = "bookmark.json", bookinfo = "bookinfo.json"
    static let shelves = "shelves.json", statistics = "statistics.json", highlights = "highlights.json"
    static let sasayakiMatch = "sasayaki_match.json", sasayakiPlayback = "sasayaki_playback.json"
}

@MainActor enum BookStorage {
    static var appDirectory = FileManager.default.temporaryDirectory
    static func getAppDirectory() throws -> URL { appDirectory }
    static func getBooksDirectory() throws -> URL { appDirectory.appendingPathComponent("Books") }
    static func save<T: Encodable>(_ value: T, inside root: URL, as name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func delete(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    static func loadMetadata(root: URL) -> BookMetadata? { load(BookMetadata.self, from: root.appendingPathComponent(FileNames.metadata)) }
    static func loadBookInfo(root: URL) -> BookInfo? { load(BookInfo.self, from: root.appendingPathComponent(FileNames.bookinfo)) }
    static func loadBookmark(root: URL) -> Bookmark? { load(Bookmark.self, from: root.appendingPathComponent(FileNames.bookmark)) }
    static func loadHighlights(root: URL) -> [Highlight]? { load([Highlight].self, from: root.appendingPathComponent(FileNames.highlights)) }
    static func loadStatistics(root: URL) -> [Statistics]? { load([Statistics].self, from: root.appendingPathComponent(FileNames.statistics)) }
    static func loadSasayakiPlayback(root: URL) -> SasayakiPlaybackData? { load(SasayakiPlaybackData.self, from: root.appendingPathComponent(FileNames.sasayakiPlayback)) }
    static func loadShelves() -> [BookShelf]? { load([BookShelf].self, from: try! getBooksDirectory().appendingPathComponent(FileNames.shelves)) }
    static func loadAllBooks() throws -> [BookMetadata] {
        (try? FileManager.default.contentsOfDirectory(at: getBooksDirectory(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.compactMap { loadMetadata(root: $0) } ?? []
    }
}
extension BookMetadata {
    @MainActor var coverURL: URL? { cover.map { BookStorage.appDirectory.appendingPathComponent($0) } }
}

@MainActor final class CoordinateReader: SyncOpenReader {
    let syncFolder: String
    var changed: [Bool] = []
    var beforeCallback: (() -> Void)?
    init(_ folder: String) { syncFolder = folder }
    func prepareForExternalStatisticsMutation() {}
    func applySyncedState(bookmarkChanged: Bool) { beforeCallback?(); changed.append(bookmarkChanged) }
    func closeForSyncedDeletion() {}
    func reloadSyncedSasayakiMatch() {}
}

@main private enum LibrarySyncCoordinatesTest {
    @MainActor static var checks = 0
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try value() else { fatalError("FAIL: \(message)") }
        checks += 1
    }
    static func markup(_ content: String) -> String { "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>ignored</title></head><body>\(content)</body></html>" }
    static func archive(_ contents: [String], root: URL, name: String) throws -> URL {
        let fm = FileManager.default, directory = root.appendingPathComponent(name)
        try fm.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: directory.appendingPathComponent("mimetype"))
        try Data("<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8).write(to: directory.appendingPathComponent("META-INF/container.xml"))
        let items = contents.indices.map { "<item id=\"c\($0)\" href=\"c\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let spine = contents.indices.map { "<itemref idref=\"c\($0)\"/>" }.joined()
        try Data("<package version=\"3.0\" unique-identifier=\"id\" xmlns=\"http://www.idpf.org/2007/opf\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">\(name)</dc:identifier><dc:title>\(name)</dc:title><dc:language>ja</dc:language></metadata><manifest>\(items)<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/></manifest><spine toc=\"ncx\">\(spine)</spine></package>".utf8).write(to: directory.appendingPathComponent("package.opf"))
        let points = contents.indices.map { "<navPoint id=\"c\($0)\" playOrder=\"\($0 + 1)\"><navLabel><text>Chapter</text></navLabel><content src=\"c\($0).xhtml\"/></navPoint>" }.joined()
        try Data("<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head/><docTitle><text>Fixture</text></docTitle><navMap>\(points)</navMap></ncx>".utf8).write(to: directory.appendingPathComponent("toc.ncx"))
        for (index, content) in contents.enumerated() { try Data(content.utf8).write(to: directory.appendingPathComponent("c\(index).xhtml")) }
        let url = root.appendingPathComponent(name + ".epub")
        try fm.zipItem(at: directory, to: url, shouldKeepParent: false)
        return url
    }
    static func info(_ contents: [String]) -> BookInfo {
        var total = 0, chapters: [String: BookInfo.ChapterInfo] = [:]
        for (index, content) in contents.enumerated() {
            let count = ReaderCharacterNormalizer.filteredText(from: content).count
            chapters["c\(index).xhtml"] = .init(spineIndex: index, currentTotal: total, chapterCount: count)
            total += count
        }
        return BookInfo(characterCount: total, chapterInfo: chapters)
    }

    @MainActor static func main() throws {
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent("niratan-storage-coordinates-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        defer { SyncReaderBridge.model = nil; try? fm.removeItem(at: base) }
        BookStorage.appDirectory = base.appendingPathComponent("library")
        let store = SyncStorage.shared
        try store.reload()
        let folder = "Entity and Korean", key = SyncStorage.key(folder), root = try SyncStorage.bookDirectory(folder: folder)
        let contents = [markup("AB&#65;CD"), markup("가나다")]
        let epub = try archive(contents, root: base, name: "exact")
        let nativeInfo = info(contents)
        require(nativeInfo.characterCount == 5, "native BookInfo remains unchanged")
        let highlightID = UUID().uuidString
        var high = SyncHighlight(Highlight(id: UUID(uuidString: highlightID)!, character: 6, offset: 2, text: "다", textFurigana: "<ruby>다</ruby>", color: .green, createdAt: Date(syncMilliseconds: 80)))
        high.color = "future-color"
        let historical: ReadingSessionRecords = ["unchanged-history": Timestamped(modified: 90, value: ReadingSession(startedAt: 1, endedAt: 10, charactersRead: 123, readingTime: 9))]
        var book = SyncBook(generation: 1, deleted: false, metadata: Timestamped(modified: 10, value: SyncMetadata(title: folder)), characterCount: 7, files: [.epub: Timestamped(modified: 50, value: "published.epub")])
        book.bookmark = Timestamped(modified: 100, value: SyncBookmark(characterCount: 5))
        book.highlights[highlightID] = Timestamped(modified: 80, value: high)
        book.sessions = historical
        try store.applyBook(key: key, book: book)
        require(BookStorage.loadBookmark(root: root) == nil && BookStorage.loadHighlights(root: root) == nil, "placeholder does not apply foreign raw coordinates")
        try require(try store.loadBook(key: key)?.bookmark == book.bookmark, "placeholder returns canonical raw and original timestamp")
        require(store.sharedProgress(root: root, bookmark: nil) == 5.0/7, "placeholder displays canonical ratio")
        require(store.needsEPUBDownload(key: key), "remote placeholder requests its existing published EPUB")

        var metadata = BookStorage.loadMetadata(root: root)!
        metadata.epub = "local.epub"
        try BookStorage.save(metadata, inside: root, as: FileNames.metadata)
        try fm.copyItem(at: epub, to: root.appendingPathComponent("local.epub"))
        try BookStorage.save(nativeInfo, inside: root, as: FileNames.bookinfo)
        store.state.books[key]!.sources[.epub] = 50
        try require(try EPUBSyncCoordinates.load(epubURL: root.appendingPathComponent("local.epub"), nativeInfo: nativeInfo, generation: 1, epubReference: "published.epub") != nil, "fixture produces a verified production map")
        let reader = CoordinateReader(folder)
        reader.beforeCallback = {
            require(BookStorage.loadBookmark(root: root)?.chapterIndex == 1, "Reader callback sees projected chapter already persisted")
            require(SyncBookLedger.load(root: root).bookmarkProjection != nil, "Reader callback sees projection receipt already persisted")
        }
        SyncReaderBridge.model = reader
        try store.applyPendingCoordinates(key: key)
        require(!store.needsEPUBDownload(key: key), "matching existing local EPUB does not request a redundant download")
        reader.beforeCallback = nil
        var native = BookStorage.loadBookmark(root: root)!
        require(native.characterCount == 5 && native.chapterIndex == 1 && abs(native.progress - 1.0/3) < 1e-12, "zero-native chapter retains spine and progress")
        require(native.lastModified?.syncMilliseconds == 100 && reader.changed == [true], "projection retains original timestamp and notifies Reader")
        require(BookStorage.loadHighlights(root: root)?.first?.character == 5 && BookStorage.loadHighlights(root: root)?.first?.textFurigana == high.textFurigana, "unique DOM anchor projects highlight and preserves furigana")
        try require(try store.loadBook(key: key)?.highlights[highlightID]?.value?.color == "future-color", "unknown wire color survives native fallback")
        require(store.sharedProgress(root: root, bookmark: native) == 5.0/7, "local display never mixes native raw with canonical total")
        try require(try store.loadBook(key: key)?.bookmark == book.bookmark, "untouched projection exports canonical raw instead of native raw")
        require(StatisticsStorage.load(root: root, resetMinutes: SyncStorage.resetMinutes) == historical, "historical session values and IDs remain unchanged")

        let rounded = Bookmark(chapterIndex: native.chapterIndex, progress: native.progress, characterCount: native.characterCount - 1, lastModified: native.lastModified)
        try BookStorage.save(rounded, inside: root, as: FileNames.bookmark)
        try require(try store.loadBook(key: key)?.bookmark == book.bookmark, "one-unit integer rounding with original stamp preserves wire raw")
        try BookStorage.save(native, inside: root, as: FileNames.bookmark)
        _ = try store.loadBook(key: key)

        native = Bookmark(chapterIndex: 1, progress: native.progress + 0.0000000001, characterCount: 5, lastModified: Date(syncMilliseconds: 200))
        try BookStorage.save(native, inside: root, as: FileNames.bookmark)
        try require(try store.loadBook(key: key)?.bookmark == book.bookmark, "projection rounding does not restamp canonical raw")
        native = Bookmark(chapterIndex: 1, progress: 2.0/3, characterCount: 5, lastModified: Date(syncMilliseconds: 300))
        try BookStorage.save(native, inside: root, as: FileNames.bookmark)
        require(store.sharedProgress(root: root, bookmark: native) == 6.0/7, "fresh zero-native edit uses chapter and progress")
        try store.applyPendingCoordinates(key: key)
        try require(try store.loadBook(key: key)?.bookmark == Timestamped(modified: 300, value: SyncBookmark(characterCount: 6)), "reopening preserves a local edit before periodic sync")

        native = Bookmark(chapterIndex: 0, progress: 0.6, characterCount: 3, lastModified: Date(syncMilliseconds: 400))
        try BookStorage.save(native, inside: root, as: FileNames.bookmark)
        require(store.sharedProgress(root: root, bookmark: native) == 2.0/7, "fresh native position is converted to canonical chapter units")
        try require(try store.loadBook(key: key)?.bookmark?.value.characterCount == 2, "local edit exports Hoshi raw rather than Mac raw")
        try store.applyPendingCoordinates(key: key)
        require(BookStorage.loadBookmark(root: root)?.characterCount == 3 && BookStorage.loadBookmark(root: root)?.progress == 0.6, "reapplying the same coarse canonical unit preserves native Reader geometry")
        let withinUnit = Bookmark(chapterIndex: 0, progress: 0.65, characterCount: 3, lastModified: Date(syncMilliseconds: 400))
        try BookStorage.save(withinUnit, inside: root, as: FileNames.bookmark)
        try store.applyPendingCoordinates(key: key)
        require(BookStorage.loadBookmark(root: root)?.progress == 0.65 && SyncBookLedger.load(root: root).bookmarkProjection?.progress == 0.65, "same-timestamp movement inside one canonical unit updates native geometry receipt")
        try require(try store.loadBook(key: key)?.bookmark == Timestamped(modified: 400, value: SyncBookmark(characterCount: 2)), "within-unit native movement keeps original wire coordinate and timestamp")
        var samePoint = try store.loadBook(key: key)!
        samePoint.bookmark?.modified = 450
        try store.applyBook(key: key, book: samePoint)
        require(BookStorage.loadBookmark(root: root)?.characterCount == 3 && BookStorage.loadBookmark(root: root)?.progress == 0.65 && BookStorage.loadBookmark(root: root)?.lastModified?.syncMilliseconds == 450, "same canonical point adopts newer remote timestamp without a native position jump")
        var newerPoint = samePoint
        newerPoint.bookmark = Timestamped(modified: 600, value: SyncBookmark(characterCount: 3))
        try store.applyBook(key: key, book: newerPoint)
        try BookStorage.save(withinUnit, inside: root, as: FileNames.bookmark)
        try store.applyPendingCoordinates(key: key)
        try require(try store.loadBook(key: key)?.bookmark == newerPoint.bookmark && BookStorage.loadBookmark(root: root)?.progress == 0.75, "older native movement cannot absorb or overwrite a newer canonical position")
        book.bookmark = Timestamped(modified: 700, value: SyncBookmark(characterCount: 7))
        book.characterCount = 999
        try store.applyBook(key: key, book: book)
        native = BookStorage.loadBookmark(root: root)!
        require(native.chapterIndex == 1 && native.progress == 1 && native.characterCount == 5, "EOF sentinel remains the exact end")
        try require(try store.loadBook(key: key)?.bookmark == book.bookmark && store.loadBook(key: key)?.characterCount == 7, "EOF and verified canonical total survive reload")
        require(BookStorage.loadMetadata(root: root)?.characterCount == 5, "local metadata retains native total independently")

        book.characterCount = 7
        book.files[.epub] = Timestamped(modified: 1000, value: "replacement.epub")
        book.bookmark = Timestamped(modified: 600, value: SyncBookmark(characterCount: 1))
        try store.applyBook(key: key, book: book)
        require(BookStorage.loadBookmark(root: root)?.progress == 1 && SyncBookLedger.load(root: root).bookmarkProjection == nil, "new reference invalidates receipt and does not project through old local EPUB")
        try require(try store.loadBook(key: key)?.bookmark == book.bookmark, "pending replacement retains canonical record without exporting old local bookmark")
        require(store.sharedProgress(root: root, bookmark: BookStorage.loadBookmark(root: root)) == nil, "pending local file cannot display a mixed coordinate ratio")
        require(store.sharedCoordinates(root: root) == nil, "Reader entry rejects cached map belonging to a pending replaced reference")
        require(store.needsEPUBDownload(key: key), "manual opening requests newer reference even when old EPUB exists")
        store.state.books[key]!.sources[.epub] = 1000
        try store.applyPendingCoordinates(key: key)
        require(!store.needsEPUBDownload(key: key), "applied downloaded reference no longer needs a transfer")
        require(BookStorage.loadBookmark(root: root)?.chapterIndex == 0 && BookStorage.loadBookmark(root: root)?.progress == 0.25, "matching downloaded reference applies pending position")
        require(SyncBookLedger.load(root: root).bookmarkProjection?.identity.source.epub == book.files[.epub], "receipt binds published reference")

        let unresolvedID = UUID().uuidString
        var unresolved = high
        unresolved.text = "not in this EPUB"
        book.highlights[unresolvedID] = Timestamped(modified: 700, value: unresolved)
        try store.applyBook(key: key, book: book)
        try require(try store.loadBook(key: key)?.highlights[unresolvedID] == book.highlights[unresolvedID], "missing DOM anchor remains canonical and cannot become a deletion")
        require(BookStorage.loadHighlights(root: root)?.contains { $0.id.uuidString == unresolvedID } == false, "missing DOM anchor is not guessed into native highlights")
        try BookStorage.save([Highlight](), inside: root, as: FileNames.highlights)
        let deleted = try store.loadBook(key: key)!
        require(deleted.highlights[highlightID]?.value == nil && deleted.highlights[highlightID] != nil, "local deletion only tombstones previously projected highlight")
        require(deleted.highlights[unresolvedID] == book.highlights[unresolvedID], "unprojected highlight survives another highlight's local deletion")

        let previousIdentity = SyncBookLedger.load(root: root).bookmarkProjection!.identity
        book.generation = 2
        book.bookmark = Timestamped(modified: 1001, value: SyncBookmark(characterCount: 2))
        try store.applyBook(key: key, book: book)
        require(SyncBookLedger.load(root: root).bookmarkProjection?.identity != previousIdentity && SyncBookLedger.load(root: root).bookmarkProjection?.identity.source.generation == 2, "new generation creates a new exact projection identity")
        try BookStorage.save(BookInfo(characterCount: 6, chapterInfo: nativeInfo.chapterInfo), inside: root, as: FileNames.bookinfo)
        book.bookmark = Timestamped(modified: 1100, value: SyncBookmark(characterCount: 3))
        let beforeStale = BookStorage.loadBookmark(root: root)!.characterCount
        try store.applyBook(key: key, book: book)
        require(store.sharedCoordinates(root: root) == nil && BookStorage.loadBookmark(root: root)?.characterCount == beforeStale, "stale native BookInfo cannot apply canonical raw through a guessed map")
        try require(try store.loadBook(key: key)?.bookmark == book.bookmark, "stale BookInfo preserves pending wire bookmark and timestamp")
        try BookStorage.save(nativeInfo, inside: root, as: FileNames.bookinfo)
        try store.applyPendingCoordinates(key: key)
        require(BookStorage.loadBookmark(root: root)?.characterCount == 3 && BookStorage.loadBookmark(root: root)?.lastModified?.syncMilliseconds == 1100, "rebuilt native info applies pending canonical bookmark")

        // Old builds could write wire raw directly into a native sidecar. The exact
        // remote raw+timestamp proves that origin and prevents a second conversion.
        let legacyFolder = "Legacy copied wire", legacyKey = SyncStorage.key(legacyFolder), legacyRoot = try SyncStorage.bookDirectory(folder: legacyFolder)
        try BookStorage.save(BookMetadata(title: legacyFolder, epub: "legacy.epub", cover: nil, folder: legacyFolder, lastAccess: .distantPast), inside: legacyRoot, as: FileNames.metadata)
        try fm.copyItem(at: epub, to: legacyRoot.appendingPathComponent("legacy.epub"))
        try BookStorage.save(nativeInfo, inside: legacyRoot, as: FileNames.bookinfo)
        try store.prepareBook(root: legacyRoot)
        var legacyRemote = SyncBook(generation: 1, deleted: false, metadata: book.metadata, characterCount: 7)
        legacyRemote.bookmark = Timestamped(modified: 1200, value: SyncBookmark(characterCount: 6))
        legacyRemote.highlights[highlightID] = Timestamped(modified: 80, value: high)
        var oldLedger = SyncBookLedger()
        oldLedger.highlights = legacyRemote.highlights
        try oldLedger.save(root: legacyRoot)
        try BookStorage.save(Bookmark(chapterIndex: 0, progress: 0.5, characterCount: 6, lastModified: Date(syncMilliseconds: 1200)), inside: legacyRoot, as: FileNames.bookmark)
        try BookStorage.save([high.highlight(id: highlightID)!], inside: legacyRoot, as: FileNames.highlights)
        try require(try store.loadBook(key: legacyKey, remote: legacyRemote)?.bookmark == legacyRemote.bookmark, "legacy copied wire is identified by exact remote record")
        try store.applyPendingCoordinates(key: legacyKey)
        require(BookStorage.loadBookmark(root: legacyRoot)?.characterCount == 5 && BookStorage.loadBookmark(root: legacyRoot)?.chapterIndex == 1, "legacy copied wire projects once into native chapter")
        try require(try store.loadBook(key: legacyKey)?.highlights[highlightID] == legacyRemote.highlights[highlightID], "legacy canonical highlight retains original wire record")

        let freshFolder = "Legacy native position", freshKey = SyncStorage.key(freshFolder), freshRoot = try SyncStorage.bookDirectory(folder: freshFolder)
        try BookStorage.save(BookMetadata(title: freshFolder, epub: "native.epub", cover: nil, folder: freshFolder, lastAccess: .distantPast), inside: freshRoot, as: FileNames.metadata)
        try fm.copyItem(at: epub, to: freshRoot.appendingPathComponent("native.epub"))
        try BookStorage.save(nativeInfo, inside: freshRoot, as: FileNames.bookinfo)
        try BookStorage.save(Bookmark(chapterIndex: 0, progress: 0.6, characterCount: 3, lastModified: Date(syncMilliseconds: 1300)), inside: freshRoot, as: FileNames.bookmark)
        let localHigh = Highlight(id: UUID(), character: 5, offset: 2, text: "다", color: .blue, createdAt: Date(syncMilliseconds: 1250))
        let recoloredHigh = Highlight(id: UUID(), character: 5, offset: 2, text: "다", color: .pink, createdAt: Date(syncMilliseconds: 1250))
        try BookStorage.save([localHigh, recoloredHigh], inside: freshRoot, as: FileNames.highlights)
        oldLedger = SyncBookLedger()
        oldLedger.highlights = [localHigh.id.uuidString: Timestamped(modified: 1250, value: SyncHighlight(localHigh))]
        var oldColor = SyncHighlight(recoloredHigh)
        oldColor.color = "green"
        oldColor.textFurigana = "historic furigana"
        oldLedger.highlights?[recoloredHigh.id.uuidString] = Timestamped(modified: 1250, value: oldColor)
        try oldLedger.save(root: freshRoot)
        try store.prepareBook(root: freshRoot)
        let fresh = try store.loadBook(key: freshKey)!
        require(fresh.bookmark == Timestamped(modified: 1300, value: SyncBookmark(characterCount: 2)), "legacy actual native position exports through exact map")
        require(fresh.highlights[localHigh.id.uuidString]?.value?.character == 6 && fresh.highlights[localHigh.id.uuidString]?.modified == 1250, "legacy native highlight migrates unique anchor without restamping")
        require(fresh.highlights[recoloredHigh.id.uuidString]?.value?.color == "pink" && fresh.highlights[recoloredHigh.id.uuidString]?.value?.textFurigana == "historic furigana" && (fresh.highlights[recoloredHigh.id.uuidString]?.modified ?? 0) > 1250, "legacy highlight migration keeps newer local color edit and historic furigana")

        let caseFolder = "Wire UUID letter case", caseKey = SyncStorage.key(caseFolder), caseRoot = try SyncStorage.bookDirectory(folder: caseFolder)
        try BookStorage.save(BookMetadata(title: caseFolder, epub: "case.epub", cover: nil, folder: caseFolder, lastAccess: .distantPast), inside: caseRoot, as: FileNames.metadata)
        try fm.copyItem(at: epub, to: caseRoot.appendingPathComponent("case.epub"))
        try BookStorage.save(nativeInfo, inside: caseRoot, as: FileNames.bookinfo)
        try store.prepareBook(root: caseRoot)
        let caseUUID = UUID(uuidString: "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6")!
        let lowerID = caseUUID.uuidString.lowercased(), upperID = caseUUID.uuidString
        let caseHigh = SyncHighlight(Highlight(id: caseUUID, character: 6, offset: 2, text: "다", textFurigana: "case furigana", color: .blue, createdAt: Date(syncMilliseconds: 80)))
        var caseBook = SyncBook(generation: 1, deleted: false, metadata: book.metadata, characterCount: 7)
        caseBook.highlights[lowerID] = Timestamped(modified: 80, value: caseHigh)
        try store.applyBook(key: caseKey, book: caseBook)
        require(BookStorage.loadHighlights(root: caseRoot)?.count == 1 && BookStorage.loadHighlights(root: caseRoot)?.first?.id == caseUUID, "lowercase wire UUID projects into one native highlight")
        try require(try store.loadBook(key: caseKey)?.highlights == caseBook.highlights, "lowercase wire key survives reload without a tombstone or uppercase duplicate")
        try store.applyBook(key: caseKey, book: caseBook)
        require(BookStorage.loadHighlights(root: caseRoot)?.count == 1, "repeated lowercase wire application does not duplicate native UUID")
        try require(try store.loadBook(key: caseKey)?.highlights.keys.sorted() == [lowerID], "repeated lowercase wire round trip preserves the original key")
        let originalCaseHigh = BookStorage.loadHighlights(root: caseRoot)!.first!
        let editedCaseHigh = Highlight(id: originalCaseHigh.id, character: originalCaseHigh.character,
                                       offset: originalCaseHigh.offset, text: originalCaseHigh.text,
                                       textFurigana: originalCaseHigh.textFurigana, color: .pink,
                                       createdAt: originalCaseHigh.createdAt)
        try BookStorage.save([editedCaseHigh], inside: caseRoot, as: FileNames.highlights)
        let editedCaseBook = try store.loadBook(key: caseKey)!
        require(editedCaseBook.highlights.keys.sorted() == [lowerID] && editedCaseBook.highlights[lowerID]?.value?.color == "pink" && editedCaseBook.highlights[lowerID]?.value?.textFurigana == "case furigana", "native color edit updates the sole original wire key")
        try BookStorage.save([Highlight](), inside: caseRoot, as: FileNames.highlights)
        let deletedCaseBook = try store.loadBook(key: caseKey)!
        require(deletedCaseBook.highlights.keys.sorted() == [lowerID] && deletedCaseBook.highlights[lowerID]?.value == nil, "real native deletion tombstones the original lowercase wire key only")

        var collisionHigh = caseHigh
        collisionHigh.color = "pink"
        caseBook.highlights = [lowerID: Timestamped(modified: 800, value: caseHigh), upperID: Timestamped(modified: 801, value: collisionHigh)]
        let preservedCaseHigh = Highlight(id: caseUUID, character: 5, offset: 2, text: "다", color: .green, createdAt: Date(syncMilliseconds: 80))
        try BookStorage.save([preservedCaseHigh], inside: caseRoot, as: FileNames.highlights)
        try store.applyBook(key: caseKey, book: caseBook)
        require(BookStorage.loadHighlights(root: caseRoot) == [preservedCaseHigh], "multiple wire keys for one UUID leave the existing native highlight unchanged")
        try require(try store.loadBook(key: caseKey)?.highlights == caseBook.highlights, "ambiguous UUID letter case preserves every original wire record without guessing a mapping")
        try BookStorage.save([Highlight](), inside: caseRoot, as: FileNames.highlights)
        try require(try store.loadBook(key: caseKey)?.highlights == caseBook.highlights, "missing native UUID cannot turn ambiguous wire records into deletions")

        let ambiguousFolder = "Ambiguous anchors", ambiguousKey = SyncStorage.key(ambiguousFolder), ambiguousRoot = try SyncStorage.bookDirectory(folder: ambiguousFolder)
        let ambiguousContents = [markup("&#65;"), markup("&#65;")]
        let ambiguousEpub = try archive(ambiguousContents, root: base, name: "ambiguous")
        try BookStorage.save(BookMetadata(title: ambiguousFolder, epub: "a.epub", cover: nil, folder: ambiguousFolder, lastAccess: .distantPast), inside: ambiguousRoot, as: FileNames.metadata)
        try fm.copyItem(at: ambiguousEpub, to: ambiguousRoot.appendingPathComponent("a.epub"))
        try BookStorage.save(info(ambiguousContents), inside: ambiguousRoot, as: FileNames.bookinfo)
        try store.prepareBook(root: ambiguousRoot)
        var ambiguous = SyncBook(generation: 1, deleted: false, metadata: book.metadata)
        let ambiguousID = UUID().uuidString
        ambiguous.highlights[ambiguousID] = Timestamped(modified: 900, value: SyncHighlight(Highlight(id: UUID(uuidString: ambiguousID)!, character: 0, offset: 0, text: "A", color: .blue, createdAt: Date(syncMilliseconds: 900))))
        try store.applyBook(key: ambiguousKey, book: ambiguous)
        try require(try store.loadBook(key: ambiguousKey)?.highlights == ambiguous.highlights, "ambiguous DOM anchor remains canonical through reload")
        require((BookStorage.loadHighlights(root: ambiguousRoot) ?? []).isEmpty, "ambiguous anchor is never applied to a guessed chapter")

        let oldJSON = Data("{\"sessions\":{},\"sessionDays\":{}}".utf8)
        try require(try JSONDecoder().decode(SyncBookLedger.self, from: oldJSON).coordinateVersion == nil, "legacy JSON decodes without coordinate fields")
        print("PASS library sync coordinates: \(checks) checks with real EPUB parsing and storage")
    }
}
