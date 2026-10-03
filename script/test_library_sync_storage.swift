// test-sources: Models/Sync.swift Models/Statistics.swift Models/Highlight.swift Models/Book.swift Models/Sasayaki.swift Features/Sync/SyncLedger.swift Features/Sync/SyncStorage.swift
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

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
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
            guard let remote, var record = store.state.books[key] else {
                let merged = try remote ?? store.loadBook(key: key)!
                try store.applyBook(key: key, book: merged)
                return try store.loadBook(key: key, remote: merged)!
            }
            // Mirrors GoogleDriveSyncManager.mergeBook.
            if remote.deleted && !record.attached && !record.deleted && remote.generation >= record.generation {
                record.generation = remote.generation + 1
                store.state.books[key] = record
            }
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
        try BookStorage.save(Bookmark(chapterIndex: 2, progress: 0.5, characterCount: 4321, lastModified: Date()), inside: macRoot, as: FileNames.bookmark)
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
        require(BookStorage.loadHighlights(root: otherRoot)?.map(\.id) == [highlightID], "highlights arrive with the book")
        require(BookStorage.loadBookmark(root: otherRoot)?.characterCount == 4321, "the reading position arrives")
        try store.applyShelves(SyncShelves.merge(shelves, SyncShelfLedger.reconcile(local: [], ledger: SyncShelfLedger.load(), now: 11)))
        require(BookStorage.loadShelves()?.first?.bookIds == [placeholder!.id], "the shelf is recreated with the placeholder in it")

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

        // A never-synced local book with the same folder as a remotely deleted one survives
        // and continues as a newer generation.
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
        let survived = try merge(tombstone)
        require(FileManager.default.fileExists(atPath: freshRoot.appendingPathComponent("own.epub").path), "an unsynced local EPUB is never deleted by an old deletion marker")
        require(!survived.deleted && survived.generation == 4, "the local book continues as a new generation: \(survived.generation)")

        // A folder that disappears outside the sync flow is forgotten, not deleted everywhere.
        try use(mac, id: "MAC")
        try BookStorage.delete(at: macRoot)
        try store.detectLocalChanges()
        require(store.state.books[key] == nil, "a vanished book is only forgotten locally")

        print("PASS: library sync storage")
    }
}
