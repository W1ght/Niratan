// test-sources: Models/Sync.swift Models/Statistics.swift Models/Highlight.swift Models/Book.swift Models/Sasayaki.swift Core/StatisticsStorage.swift Features/Sync/SyncLedger.swift Features/Sync/SyncStorage.swift
import Foundation

// File-backed stand-ins for the app's storage layer. Each simulated device gets its own
// library directory; nothing touches the real Application Support folder.
enum FileNames {
    static let metadata = "metadata.json"
    static let bookmark = "bookmark.json"
    static let bookinfo = "bookinfo.json"
    static let shelves = "shelves.json"
    static let statistics = "statistics.json"
    static let sasayakiMatch = "sasayaki_match.json"
    static let sasayakiPlayback = "sasayaki_playback.json"
    static let highlights = "highlights.json"
}

@MainActor
enum BookStorage {
    static var appDirectory = FileManager.default.temporaryDirectory

    static func getAppDirectory() throws -> URL { appDirectory }
    static func getBooksDirectory() throws -> URL { appDirectory.appendingPathComponent("Books") }

    static func save<T: Encodable>(_ object: T, inside directory: URL, as fileName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(object).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func delete(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func loadMetadata(root: URL) -> BookMetadata? { load(BookMetadata.self, from: root.appendingPathComponent(FileNames.metadata)) }
    static func loadBookmark(root: URL) -> Bookmark? { load(Bookmark.self, from: root.appendingPathComponent(FileNames.bookmark)) }
    static func loadBookInfo(root: URL) -> BookInfo? { load(BookInfo.self, from: root.appendingPathComponent(FileNames.bookinfo)) }
    static func loadStatistics(root: URL) -> [Statistics]? { load([Statistics].self, from: root.appendingPathComponent(FileNames.statistics)) }
    static func loadHighlights(root: URL) -> [Highlight]? { load([Highlight].self, from: root.appendingPathComponent(FileNames.highlights)) }
    static func loadSasayakiPlayback(root: URL) -> SasayakiPlaybackData? {
        load(SasayakiPlaybackData.self, from: root.appendingPathComponent(FileNames.sasayakiPlayback))
    }
    static func loadShelves() -> [BookShelf]? { load([BookShelf].self, from: try! getBooksDirectory().appendingPathComponent(FileNames.shelves)) }

    static func loadAllBooks() throws -> [BookMetadata] {
        let directory = try getBooksDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return contents.compactMap { loadMetadata(root: $0) }
    }
}

extension BookMetadata {
    @MainActor
    var coverURL: URL? {
        guard let cover else { return nil }
        return BookStorage.appDirectory.appendingPathComponent(cover)
    }
}

// Identity-coordinate stand-in keeps this storage/session suite independent of EPUB
// packages. test_library_sync_coordinates uses real ZIP/EPUB parsing and differing bases.
struct EPUBSyncCoordinates {
    let identity: String
    let canonicalTotal: Int
    let nativeTotal: Int
    let info: BookInfo
    @MainActor static func load(epubURL: URL, nativeInfo: BookInfo, generation: Int, epubReference: String?) throws -> Self? {
        guard FileManager.default.fileExists(atPath: epubURL.path) else { return nil }
        return Self(identity: "fixture-\(generation)-\(epubReference ?? "local")", canonicalTotal: nativeInfo.characterCount, nativeTotal: nativeInfo.characterCount, info: nativeInfo)
    }
    func nativeBookmark(forCanonical character: Int, modified: Int64) -> Bookmark? {
        guard character >= 0, character <= canonicalTotal else { return nil }
        return Bookmark(chapterIndex: 0, progress: canonicalTotal == 0 ? 0 : Double(character) / Double(canonicalTotal), characterCount: character, lastModified: Date(syncMilliseconds: modified))
    }
    func canonicalCharacter(forNativeBookmark bookmark: Bookmark) -> Int? { bookmark.characterCount }
    func projectCanonicalHighlight(_ value: SyncHighlight) -> SyncHighlight? { value }
    func exportNativeHighlight(_ value: Highlight) -> SyncHighlight? { SyncHighlight(value) }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@MainActor
final class OpenReaderStub: SyncOpenReader {
    let syncFolder: String
    var bookmarkChanges: [Bool] = []
    var onApplySyncedState: ((Bool) -> Void)?
    init(folder: String) { syncFolder = folder }
    func prepareForExternalStatisticsMutation() {}
    func applySyncedState(bookmarkChanged: Bool) {
        bookmarkChanges.append(bookmarkChanged)
        onApplySyncedState?(bookmarkChanged)
    }
    func closeForSyncedDeletion() {}
    func reloadSyncedSasayakiMatch() {}
}

@main
struct LibrarySyncStorageTest {
    static let folder = "猫の本"
    static let day = "2026-09-01"

    @MainActor
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("niratan-sync-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let mac = base.appendingPathComponent("mac")
        let other = base.appendingPathComponent("other")
        let deviceKey = "googleDriveSyncDeviceID"
        let previousDevice = UserDefaults.standard.string(forKey: deviceKey)
        defer {
            if let previousDevice {
                UserDefaults.standard.set(previousDevice, forKey: deviceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: deviceKey)
            }
        }

        let store = SyncStorage.shared
        func use(_ device: URL, id: String) throws {
            BookStorage.appDirectory = device
            UserDefaults.standard.set(id, forKey: deviceKey)
            try FileManager.default.createDirectory(at: try BookStorage.getBooksDirectory(), withIntermediateDirectories: true)
            try store.reload()
        }
        func merge(_ remote: SyncBook?) throws -> SyncBook {
            let key = SyncStorage.key(folder)
            try store.detectLocalChanges()
            guard let remote, let record = store.state.books[key] else {
                let merged = try remote ?? store.loadBook(key: key)!
                try store.applyBook(key: key, book: merged)
                return try store.loadBook(key: key, remote: merged)!
            }
            // Mirrors GoogleDriveSyncManager.mergeBook.
            var local = try store.loadBook(key: key, remote: remote)!
            if !record.attached && !record.deleted && !remote.deleted {
                local.generation = remote.generation
            }
            let merged = SyncBook.merge(local, remote)
            try store.applyBook(key: key, book: merged)
            return try store.loadBook(key: key, remote: merged)!
        }

        // Mac: an imported book with history, a highlight, a bookmark and a shelf.
        try use(mac, id: "MAC")
        let macRoot = try BookStorage.getBooksDirectory().appendingPathComponent(folder)
        let bookID = UUID()
        try BookStorage.save(
            BookMetadata(id: bookID, title: folder, epub: "book.epub", cover: "Books/\(folder)/cover.jpg", folder: folder, lastAccess: Date(), bookLanguage: "ja"),
            inside: macRoot,
            as: FileNames.metadata
        )
        try Data("epub".utf8).write(to: macRoot.appendingPathComponent("book.epub"))
        try BookStorage.save(BookInfo(characterCount: 10000, chapterInfo: ["chapter": .init(spineIndex: 0, currentTotal: 0, chapterCount: 10000)]), inside: macRoot, as: FileNames.bookinfo)
        try Data("jpg".utf8).write(to: macRoot.appendingPathComponent("cover.jpg"))
        try BookStorage.save(
            StatisticsEditor.updating(dateKey: day, title: folder, charactersRead: 1200, readingTime: 900, modifiedAt: 5, in: []),
            inside: macRoot,
            as: FileNames.statistics
        )
        let highlightID = UUID()
        try BookStorage.save(
            [Highlight(id: highlightID, character: 10, offset: 0, text: "猫", color: .green, createdAt: Date())],
            inside: macRoot,
            as: FileNames.highlights
        )
        try BookStorage.save(Bookmark(chapterIndex: 0, progress: 0.4321, characterCount: 4321, lastModified: Date()), inside: macRoot, as: FileNames.bookmark)
        try BookStorage.save([BookShelf(name: "小説", bookIds: [bookID])], inside: try BookStorage.getBooksDirectory(), as: FileNames.shelves)

        try store.detectLocalChanges()
        let key = SyncStorage.key(folder)
        require(store.state.books[key]?.pending == true, "a new local book is pending")
        require(store.state.books[key]?.sources[.epub] != nil && store.state.books[key]?.sources[.cover] != nil, "local files are queued for upload")
        var remote = try merge(nil)
        require(remote.sessions.values.compactMap(\.value).reduce(0) { $0 + $1.charactersRead } == 1200, "history becomes sessions")
        require(remote.highlights[highlightID.uuidString]?.value != nil, "highlights are part of the document")
        require(remote.shelves["小説"]?.value == true, "shelf membership is part of the document")
        require(remote.bookmark?.value.characterCount == 4321, "the bookmark is part of the document")
        require(remote.metadata.value.language == "ja", "the content language travels with the book")
        store.markSynced(key)
        store.state.books[key]?.pending = false
        try store.detectLocalChanges()
        require(store.state.books[key]?.pending == false, "an untouched synced book is not pending")

        let shelves = SyncShelfLedger.reconcile(local: BookStorage.loadShelves() ?? [], ledger: SyncShelfLedger.load(), now: 10)
        try store.applyShelves(shelves)

        // Other Mac: the book arrives as a placeholder with its state; the shelf follows.
        try use(other, id: "OTHER")
        remote = try merge(remote)
        let otherRoot = try BookStorage.getBooksDirectory().appendingPathComponent(folder)
        let placeholder = BookStorage.loadMetadata(root: otherRoot)
        require(placeholder != nil && placeholder?.epub == nil, "a remote-only book becomes a placeholder")
        require(placeholder?.bookLanguage == "ja", "the placeholder keeps the content language")
        require(BookStorage.loadStatistics(root: otherRoot)?.first?.charactersRead == 1200, "statistics arrive with the book")
        require(SyncBookLedger.load(root: otherRoot).highlights?[highlightID.uuidString]?.value != nil && BookStorage.loadHighlights(root: otherRoot) == nil, "placeholder highlights remain canonical until an exact EPUB map exists")
        require(SyncBookLedger.load(root: otherRoot).canonicalBookmark?.value.characterCount == 4321 && BookStorage.loadBookmark(root: otherRoot) == nil, "a placeholder keeps wire progress without treating it as a native position")
        try store.applyShelves(SyncShelves.merge(shelves, SyncShelfLedger.reconcile(local: [], ledger: SyncShelfLedger.load(), now: 11)))
        require(BookStorage.loadShelves()?.first?.bookIds == [placeholder!.id], "the shelf is recreated with the placeholder in it")
        var downloaded = placeholder!
        downloaded.epub = "book.epub"
        try BookStorage.save(downloaded, inside: otherRoot, as: FileNames.metadata)
        try Data("epub".utf8).write(to: otherRoot.appendingPathComponent("book.epub"))
        try BookStorage.save(BookInfo(characterCount: 10000, chapterInfo: ["chapter": .init(spineIndex: 0, currentTotal: 0, chapterCount: 10000)]), inside: otherRoot, as: FileNames.bookinfo)
        try store.applyPendingCoordinates(key: key)
        require(BookStorage.loadBookmark(root: otherRoot)?.characterCount == 4321 && BookStorage.loadHighlights(root: otherRoot)?.map(\.id) == [highlightID], "downloaded EPUB applies pending bookmark and highlights")

        // Reading on the other Mac flows back.
        var otherStats = BookStorage.loadStatistics(root: otherRoot) ?? []
        otherStats = StatisticsEditor.updating(dateKey: day, title: folder, charactersRead: 1500, readingTime: 1000, modifiedAt: 20, in: otherStats)
        try BookStorage.save(otherStats, inside: otherRoot, as: FileNames.statistics)
        remote = try merge(remote)

        try use(mac, id: "MAC")
        remote = try merge(remote)
        require(BookStorage.loadStatistics(root: macRoot)?.first?.charactersRead == 1500, "reading elsewhere updates this Mac's statistics")

        // Delete everywhere: statistics are archived, the book folder goes away on both Macs.
        try store.deleteBook(key: key, syncEnabled: true)
        require(BookStorage.loadMetadata(root: macRoot) == nil, "the deleted book leaves the library")
        let macArchive = try SyncStorage.bookDirectory(folder: folder, archived: true)
        require(BookStorage.loadStatistics(root: macArchive)?.first?.charactersRead == 1500, "statistics of a deleted book are archived")
        remote = try merge(remote)
        require(remote.deleted && remote.highlights.isEmpty, "the document records the deletion")

        try use(other, id: "OTHER")
        remote = try merge(remote)
        require(BookStorage.loadMetadata(root: otherRoot) == nil, "the other Mac removes the deleted book")
        let otherArchive = try SyncStorage.bookDirectory(folder: folder, archived: true)
        require(BookStorage.loadStatistics(root: otherArchive) != nil, "the other Mac archives its statistics")

        // Importing the book again starts a new generation and restores its history.
        try use(mac, id: "MAC")
        try BookStorage.save(
            BookMetadata(title: folder, epub: "book.epub", cover: nil, folder: folder, lastAccess: Date()),
            inside: macRoot,
            as: FileNames.metadata
        )
        try Data("epub".utf8).write(to: macRoot.appendingPathComponent("book.epub"))
        try store.detectLocalChanges()
        require(store.state.books[key]?.deleted == false && store.state.books[key]?.generation == 2, "a re-import bumps the generation")
        require(BookStorage.loadStatistics(root: macRoot)?.first?.charactersRead == 1500, "a re-import restores archived statistics")
        remote = try merge(remote)
        require(!remote.deleted && remote.generation == 2, "the new generation replaces the deleted one")

        // A newer remotely deleted generation applies to an unattached local book too;
        // local reading history survives in the archive.
        try use(other, id: "OTHER")
        var tombstone = remote
        tombstone.generation = 3
        tombstone.delete()
        let freshRoot = try BookStorage.getBooksDirectory().appendingPathComponent(folder)
        try? BookStorage.delete(at: try SyncStorage.bookDirectory(folder: folder, archived: true))
        store.state.books[key] = nil
        try store.save()
        try BookStorage.save(BookMetadata(title: folder, epub: "own.epub", cover: nil, folder: folder, lastAccess: Date()), inside: freshRoot, as: FileNames.metadata)
        try Data("own".utf8).write(to: freshRoot.appendingPathComponent("own.epub"))
        try StatisticsStorage.save(["unattached-session": Timestamped(modified: 50, value: ReadingSession(startedAt: 0, endedAt: 1000, charactersRead: 25, readingTime: 1))], root: freshRoot, resetMinutes: 0)
        let survived = try merge(tombstone)
        require(BookStorage.loadMetadata(root: freshRoot) == nil, "a newer remote deletion removes the local library copy")
        require(survived.deleted && survived.generation == 3, "an unattached copy follows the upstream deletion generation")
        require(survived.sessions["unattached-session"]?.value?.charactersRead == 25, "an unattached copy's reading history is archived and still syncs")

        // A folder that disappears outside the sync flow is forgotten, not deleted everywhere.
        try use(mac, id: "MAC")
        try BookStorage.delete(at: macRoot)
        try store.detectLocalChanges()
        require(store.state.books[key] == nil, "a vanished book is only forgotten locally")

        // True reading-session ids and start/end times travel unchanged through the
        // whole-library provider, including individual edits and deletion markers.
        let nativeFolder = "Native sessions"
        let nativeKey = SyncStorage.key(nativeFolder)
        let nativeRoot = try BookStorage.getBooksDirectory().appendingPathComponent(nativeFolder)
        try BookStorage.save(BookMetadata(title: nativeFolder, epub: "native.epub", cover: nil, folder: nativeFolder, lastAccess: .distantPast), inside: nativeRoot, as: FileNames.metadata)
        try Data("native".utf8).write(to: nativeRoot.appendingPathComponent("native.epub"))
        try BookStorage.save(BookInfo(characterCount: 10000, chapterInfo: ["chapter": .init(spineIndex: 0, currentTotal: 0, chapterCount: 10000)]), inside: nativeRoot, as: FileNames.bookinfo)
        let sessionA = UUID().uuidString
        let sessionB = UUID().uuidString
        let startedAt = Int64(Date(timeIntervalSince1970: 1_788_307_200).syncMilliseconds)
        let nativeRecords: ReadingSessionRecords = [
            sessionA: Timestamped(modified: 100, value: ReadingSession(startedAt: startedAt, endedAt: startedAt + 60_000, charactersRead: 200, readingTime: 60)),
            sessionB: Timestamped(modified: 200, value: ReadingSession(startedAt: startedAt + 3_600_000, endedAt: startedAt + 3_720_000, charactersRead: 300, readingTime: 120))
        ]
        try StatisticsStorage.save(nativeRecords, root: nativeRoot, resetMinutes: SyncStorage.resetMinutes)
        let originalBookmark = Bookmark(chapterIndex: 0, progress: 0.1, characterCount: 1350, lastModified: Date(syncMilliseconds: 250))
        try BookStorage.save(originalBookmark, inside: nativeRoot, as: FileNames.bookmark)
        try store.detectLocalChanges()
        let nativeBook = try store.loadBook(key: nativeKey)!
        require(nativeBook.sessions == nativeRecords, "whole-library upload preserves each native session exactly")
        store.state.books[nativeKey]?.cleanup = [3, 4]
        store.state.books[nativeKey]?.files[.epub] = Timestamped(modified: 1, value: "OLD-ROOT-FILE")
        store.state.books[nativeKey]?.attached = true
        try store.resetSyncState()
        require(store.state.books[nativeKey]?.cleanup.isEmpty == true && store.state.books[nativeKey]?.files.isEmpty == true && store.state.books[nativeKey]?.attached == false, "joining a new root forgets only old file and cleanup addresses")
        require(StatisticsStorage.load(root: nativeRoot, resetMinutes: SyncStorage.resetMinutes) == nativeRecords, "joining a new root preserves canonical history")
        let resetBookmark = BookStorage.loadBookmark(root: nativeRoot)
        require(resetBookmark?.characterCount == originalBookmark.characterCount && resetBookmark?.lastModified == originalBookmark.lastModified && store.state.libraryName == "Hoshi Reader", "joining a new root preserves reading position and records the state namespace")

        // An open Reader must reload only after the remote playback has reached disk.
        // Its local audio bookmark identifies the user's media and must survive sync.
        let audioIdentity = Data("local audio bookmark".utf8)
        var originalPlayback = SasayakiPlaybackData(lastPosition: 12)
        originalPlayback.delay = 0.75
        originalPlayback.rate = 0.8
        originalPlayback.audioBookmark = audioIdentity
        try BookStorage.save(originalPlayback, inside: nativeRoot, as: FileNames.sasayakiPlayback)
        let originalMetadata = BookStorage.loadMetadata(root: nativeRoot)!
        var incomingPlayback = Timestamped(modified: Int64(600), value: SyncPlayback(lastPosition: 42, delay: 0.2, rate: 1.25))
        let reader = OpenReaderStub(folder: nativeFolder)
        reader.onApplySyncedState = { _ in
            guard let persisted = BookStorage.loadSasayakiPlayback(root: nativeRoot) else {
                require(false, "the open Reader callback sees a persisted playback sidecar")
                return
            }
            let value = SyncPlayback(lastPosition: persisted.lastPosition, delay: persisted.delay, rate: Double(persisted.rate))
            require(SyncStorage.samePlayback(value, incomingPlayback.value), "incoming playback is persisted before the open Reader reload callback")
            require(persisted.audioBookmark == audioIdentity, "incoming playback preserves the local audio media bookmark")
            require(SyncBookLedger.load(root: nativeRoot).audiobook == incomingPlayback, "the open Reader callback sees the original remote playback timestamp")
            let metadata = BookStorage.loadMetadata(root: nativeRoot)
            require(metadata?.id == originalMetadata.id && metadata?.epub == originalMetadata.epub, "playback sync preserves the local book and media identity")
        }
        SyncReaderBridge.model = reader
        var changedBook = nativeBook
        changedBook.bookmark = Timestamped(modified: 500, value: SyncBookmark(characterCount: 5760))
        changedBook.audiobook = incomingPlayback
        changedBook.sessions = ReadingSessionLog.editing(id: sessionA, charactersRead: 150, readingTime: 50, in: nativeRecords, now: Date(syncMilliseconds: 300))
        changedBook.sessions = ReadingSessionLog.deleting(ids: [sessionB], from: changedBook.sessions, now: Date(syncMilliseconds: 400))
        try store.applyBook(key: nativeKey, book: changedBook)
        require(BookStorage.loadBookmark(root: nativeRoot)?.characterCount == 5760 && reader.bookmarkChanges == [true], "a remote bookmark updates both the disk and an already-open Reader")
        require(StatisticsStorage.load(root: nativeRoot, resetMinutes: SyncStorage.resetMinutes) == changedBook.sessions, "individual remote edits and tombstones reach the session source of truth")
        let changedBookReloaded = try store.loadBook(key: nativeKey)!
        require(changedBookReloaded.sessions == changedBook.sessions, "loading again cannot synthesize a daily replacement session")
        require(changedBookReloaded.audiobook == incomingPlayback, "loading an open Reader's remote playback cannot restamp it as local activity")
        try store.detectLocalChanges()
        let playbackAfterDetection = try store.loadBook(key: nativeKey)!
        require(playbackAfterDetection.audiobook == incomingPlayback, "detecting local changes preserves the incoming playback timestamp")

        // A matching value can still carry a newer remote timestamp. Keep that timestamp
        // so repeated sync cannot turn an unchanged playback into a conflicting local edit.
        incomingPlayback.modified = 700
        changedBook.audiobook = incomingPlayback
        try store.applyBook(key: nativeKey, book: changedBook)
        require(reader.bookmarkChanges == [true, false], "an unchanged bookmark still allows the open Reader to reload synced playback")
        try store.detectLocalChanges()
        let matchingPlaybackReloaded = try store.loadBook(key: nativeKey)!
        require(matchingPlaybackReloaded.audiobook == incomingPlayback, "matching local playback adopts and retains the newer remote timestamp")
        SyncReaderBridge.model = nil

        // Existing daily-adapter ledgers migrate once using their shared historic ids;
        // native ids that carried imported daily aggregates cannot be counted again.
        var legacyLedger = SyncBookLedger.load(root: nativeRoot)
        legacyLedger.canonicalSessions = nil
        legacyLedger.appliedDaily = SyncStatisticsBridge.dailyTotals(BookStorage.loadStatistics(root: nativeRoot) ?? [])
        legacyLedger.sessions = ["old-daily-aggregate": Timestamped(modified: 10, value: ReadingSession(startedAt: startedAt, endedAt: startedAt + 50_000, charactersRead: 150, readingTime: 50))]
        try legacyLedger.save(root: nativeRoot)
        let migratedBook = try store.loadBook(key: nativeKey)!
        require(migratedBook.sessions[sessionA]?.value == nil, "migration retires native ids representing already shared daily totals")
        require(migratedBook.sessions["old-daily-aggregate"] == legacyLedger.sessions["old-daily-aggregate"], "migration preserves shared historical ids and their original modification times")
        require(ReadingSessionLog.total(migratedBook.sessions) == ReadingSessionLog.total(changedBook.sessions), "migration preserves all accumulated characters and time")
        let loadedAgain = try store.loadBook(key: nativeKey)!
        require(loadedAgain.sessions == migratedBook.sessions, "canonical migration is idempotent")

        // A backup/reset can leave both a live copy and an archive for one folder. Their
        // independent sessions must all survive a newer remote deletion.
        let coexistFolder = "Archive coexist"
        let coexistKey = SyncStorage.key(coexistFolder)
        let coexistRoot = try SyncStorage.bookDirectory(folder: coexistFolder)
        let coexistArchive = try SyncStorage.bookDirectory(folder: coexistFolder, archived: true)
        let coexistMetadata = BookMetadata(title: coexistFolder, epub: nil, cover: nil, folder: coexistFolder, lastAccess: .distantPast)
        try BookStorage.save(coexistMetadata, inside: coexistRoot, as: FileNames.metadata)
        try BookStorage.save(coexistMetadata, inside: coexistArchive, as: FileNames.metadata)
        let liveSessions: ReadingSessionRecords = ["live-history": Timestamped(modified: 1, value: ReadingSession(startedAt: 0, endedAt: 1000, charactersRead: 10, readingTime: 1))]
        let archivedSessions: ReadingSessionRecords = ["archived-history": Timestamped(modified: 2, value: ReadingSession(startedAt: 0, endedAt: 2000, charactersRead: 20, readingTime: 2))]
        try StatisticsStorage.save(liveSessions, root: coexistRoot, resetMinutes: SyncStorage.resetMinutes)
        try StatisticsStorage.save(archivedSessions, root: coexistArchive, resetMinutes: SyncStorage.resetMinutes)
        try store.prepareBook(root: coexistRoot)
        let coexistLocal = try store.loadBook(key: coexistKey)!
        require(coexistLocal.sessions["archived-history"] == archivedSessions["archived-history"], "a live book includes its existing archive before cloud merge")
        var coexistRemote = coexistLocal
        coexistRemote.generation += 1
        coexistRemote.delete()
        coexistRemote.sessions["remote-history"] = Timestamped(modified: 3, value: ReadingSession(startedAt: 0, endedAt: 3000, charactersRead: 30, readingTime: 3))
        try store.applyBook(key: coexistKey, book: SyncBook.merge(coexistLocal, coexistRemote))
        let finalArchive = StatisticsStorage.load(root: coexistArchive, resetMinutes: SyncStorage.resetMinutes)
        require(finalArchive["live-history"] == liveSessions["live-history"] && finalArchive["archived-history"] == archivedSessions["archived-history"] && finalArchive["remote-history"]?.value?.charactersRead == 30, "deletion preserves live, pre-existing archive and remote session histories")

        // A downloaded remote book can become a placeholder again when its local EPUB is
        // removed. Reading or editing after the last sync is newer than the empty ledger
        // snapshot; changing connections must archive that canonical history before removal.
        try use(base.appendingPathComponent("reconnect"), id: "RECONNECT")
        let connectionHistories: [(folder: String, records: ReadingSessionRecords)] = [
            ("Unsynced placeholder history", ["unsynced-history": Timestamped(modified: 700, value: ReadingSession(startedAt: 0, endedAt: 5000, charactersRead: 25, readingTime: 5))]),
            ("Placeholder deletion markers", ["removed-history": Timestamped(modified: 800, value: nil)])
        ]
        for fixture in connectionHistories {
            let root = try SyncStorage.bookDirectory(folder: fixture.folder)
            try BookStorage.save(BookMetadata(title: fixture.folder, epub: nil, cover: nil, folder: fixture.folder, lastAccess: .distantPast), inside: root, as: FileNames.metadata)
            var ledger = SyncBookLedger()
            ledger.canonicalSessions = true
            try ledger.save(root: root)
            try StatisticsStorage.save(fixture.records, root: root, resetMinutes: SyncStorage.resetMinutes)
            var record = SyncRecord(generation: 1, deleted: false, attached: true)
            record.placeholder = true
            store.state.books[SyncStorage.key(fixture.folder)] = record
        }
        try store.save()
        try store.removePlaceholders()
        for fixture in connectionHistories {
            let root = try SyncStorage.bookDirectory(folder: fixture.folder)
            let archive = try SyncStorage.bookDirectory(folder: fixture.folder, archived: true)
            require(BookStorage.loadMetadata(root: root) == nil, "changing connections removes the remote-only placeholder from the library")
            require(StatisticsStorage.load(root: archive, resetMinutes: SyncStorage.resetMinutes) == fixture.records, "changing connections archives unsynced canonical history and deletion markers despite an empty sync snapshot")
        }
        try store.resetSyncState()
        for fixture in connectionHistories {
            let record = store.state.books[SyncStorage.key(fixture.folder)]
            require(record?.deleted == true && record?.generation == 0 && record?.attached == false, "connection reset retains archived history without publishing an old deletion generation")
        }

        // The first sync to a new library may have no remote document. A tombstone-only
        // archive must still produce a document, or a later offline peer can revive history.
        let deletionFixture = connectionHistories[1]
        let deletionKey = SyncStorage.key(deletionFixture.folder)
        let beforeDeletedApply = try store.loadBook(key: deletionKey)!
        try store.applyBook(key: deletionKey, book: beforeDeletedApply)
        let afterDeletedApply = try store.loadBook(key: deletionKey)
        require(afterDeletedApply?.sessions == deletionFixture.records, "applying a deleted book retains tombstones as a publishable sync document")
        var staleOfflineBook = SyncBook(generation: 1, deleted: false, metadata: beforeDeletedApply.metadata)
        staleOfflineBook.sessions["removed-history"] = Timestamped(modified: 900, value: ReadingSession(startedAt: 0, endedAt: 10_000, charactersRead: 100, readingTime: 10))
        let staleMerged = SyncBook.merge(afterDeletedApply!, staleOfflineBook)
        require(staleMerged.sessions["removed-history"]?.value == nil && staleMerged.sessions["removed-history"] != nil, "a newer offline generation cannot revive a deleted session after reconnect")

        // Deleting a local book with no live statistics must retain its deletion markers too,
        // even when it has never attached to Drive and whole-library sync is disabled.
        let localDeletedFolder = "Local book with deletion markers"
        let localDeletedKey = SyncStorage.key(localDeletedFolder)
        let localDeletedRoot = try SyncStorage.bookDirectory(folder: localDeletedFolder)
        try BookStorage.save(BookMetadata(title: localDeletedFolder, epub: nil, cover: nil, folder: localDeletedFolder, lastAccess: .distantPast), inside: localDeletedRoot, as: FileNames.metadata)
        let localDeletionRecords: ReadingSessionRecords = ["locally-deleted-history": Timestamped(modified: 1000, value: nil)]
        try StatisticsStorage.save(localDeletionRecords, root: localDeletedRoot, resetMinutes: SyncStorage.resetMinutes)
        try store.deleteBook(key: localDeletedKey, syncEnabled: false)
        let localDeletedArchive = try SyncStorage.bookDirectory(folder: localDeletedFolder, archived: true)
        require(StatisticsStorage.load(root: localDeletedArchive, resetMinutes: SyncStorage.resetMinutes) == localDeletionRecords && store.state.books[localDeletedKey] != nil, "local deletion archives session tombstones instead of treating them as empty history")

        // A physically lost local EPUB is a cache miss when a published copy exists.
        // Detecting that loss must never queue an upload that erases its cloud reference.
        let evictionFolder = "Published EPUB cache eviction", evictionKey = SyncStorage.key(evictionFolder)
        let evictionRoot = try SyncStorage.bookDirectory(folder: evictionFolder)
        let evictionURL = evictionRoot.appendingPathComponent("local.epub")
        let evictionData = Data("published EPUB fixture".utf8)
        try BookStorage.save(BookMetadata(title: evictionFolder, epub: "local.epub", cover: nil, folder: evictionFolder, lastAccess: .distantPast), inside: evictionRoot, as: FileNames.metadata)
        try evictionData.write(to: evictionURL)
        try BookStorage.save(BookInfo(characterCount: 1000, chapterInfo: ["chapter": .init(spineIndex: 0, currentTotal: 0, chapterCount: 1000)]), inside: evictionRoot, as: FileNames.bookinfo)
        try store.prepareBook(root: evictionRoot)
        let publishedEPUB = Timestamped<String?>(modified: 200, value: "published.epub")
        var evictionBook = SyncBook(generation: 2, deleted: false, metadata: Timestamped(modified: 50, value: SyncMetadata(title: evictionFolder)), characterCount: 1000, files: [.epub: publishedEPUB])
        evictionBook.bookmark = Timestamped(modified: 300, value: SyncBookmark(characterCount: 432))
        evictionBook.sessions["eviction-history"] = Timestamped(modified: 250, value: ReadingSession(startedAt: 0, endedAt: 1000, charactersRead: 12, readingTime: 1))
        let evictionHighID = UUID().uuidString
        evictionBook.highlights[evictionHighID] = Timestamped(modified: 250, value: SyncHighlight(Highlight(id: UUID(uuidString: evictionHighID)!, character: 10, offset: 0, text: "猫", color: .green, createdAt: Date(syncMilliseconds: 250))))
        try store.applyBook(key: evictionKey, book: evictionBook)
        store.state.books[evictionKey]!.sources[.epub] = publishedEPUB.modified
        store.state.books[evictionKey]!.observed[.epub] = SyncStorage.modificationDate(evictionURL)
        try store.save()
        try FileManager.default.removeItem(at: evictionURL)
        try store.detectLocalChanges()
        let evicted = store.state.books[evictionKey]!
        require(evicted.sources[.epub] == nil && evicted.observed[.epub] == nil, "physical EPUB loss clears local publication markers instead of restamping deletion")
        require(evicted.files[.epub] == publishedEPUB && evicted.attached && !evicted.deleted && evicted.generation == 2, "cache eviction preserves the exact published reference and book generation")
        require(store.needsEPUBDownload(key: evictionKey), "a lost published EPUB remains eligible for re-download")
        let evictionWire = try store.loadBook(key: evictionKey)!
        require(evictionWire.files[.epub] == publishedEPUB && evictionWire.bookmark == evictionBook.bookmark && evictionWire.sessions == evictionBook.sessions && evictionWire.highlights == evictionBook.highlights, "cache eviction retains canonical progress, highlight records and history on the wire")
        try store.detectLocalChanges()
        require(store.state.books[evictionKey] == evicted, "repeated cache-miss detection does not create a new source edit")
        try store.reload()
        require(store.state.books[evictionKey]?.sources[.epub] == nil && store.state.books[evictionKey]?.files[.epub] == publishedEPUB, "cache-eviction markers remain correct after state reload")

        // The eviction exception must not invent a publication for a first import.
        let unpublishedFolder = "Unpublished missing EPUB", unpublishedKey = SyncStorage.key(unpublishedFolder)
        let unpublishedRoot = try SyncStorage.bookDirectory(folder: unpublishedFolder)
        let unpublishedURL = unpublishedRoot.appendingPathComponent("unpublished.epub")
        try BookStorage.save(BookMetadata(title: unpublishedFolder, epub: "unpublished.epub", cover: nil, folder: unpublishedFolder, lastAccess: .distantPast), inside: unpublishedRoot, as: FileNames.metadata)
        try evictionData.write(to: unpublishedURL)
        try store.prepareBook(root: unpublishedRoot)
        try FileManager.default.removeItem(at: unpublishedURL)
        try store.detectLocalChanges()
        let unpublishedWire = try store.loadBook(key: unpublishedKey)!
        require(store.state.books[unpublishedKey]?.attached == false && unpublishedWire.files[.epub] == nil && !store.needsEPUBDownload(key: unpublishedKey), "a missing first import cannot fabricate cloud media or a download reference")

        // Explicit local removal still preserves the published copy; deletion everywhere
        // still writes its normal book tombstone and archives canonical history.
        try evictionData.write(to: evictionURL)
        store.state.books[evictionKey]!.sources[.epub] = publishedEPUB.modified
        store.state.books[evictionKey]!.observed[.epub] = SyncStorage.modificationDate(evictionURL)
        try store.deleteLocalBook(key: evictionKey)
        try store.detectLocalChanges()
        require(BookStorage.loadMetadata(root: evictionRoot)?.epub == nil && store.state.books[evictionKey]?.files[.epub] == publishedEPUB && store.state.books[evictionKey]?.sources[.epub] == nil && store.needsEPUBDownload(key: evictionKey), "explicit local deletion remains a downloadable cache removal")
        try store.deleteBook(key: evictionKey, syncEnabled: true)
        try store.detectLocalChanges()
        let deletedEvictionWire = try store.loadBook(key: evictionKey)!
        require(deletedEvictionWire.deleted && deletedEvictionWire.files[.epub] == nil && deletedEvictionWire.sessions == evictionBook.sessions, "explicit deletion everywhere retains its tombstone and archived history")

        print("PASS: library sync storage")
    }
}
