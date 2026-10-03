//
//  SyncStorage.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

nonisolated struct SyncRecord: Codable, Equatable, Sendable {
    var generation: Int
    var deleted: Bool
    var files: SyncFiles = [:]
    /// When each local file last changed (milliseconds).
    var sources: [SyncFileType: Int64] = [:]
    var attached = false
    var pending = true
    var cleanup: Set<Int> = []
    /// Niratan: modification dates of the local files when last observed, so replaced files are
    /// noticed without hooking every writer.
    var observed: [SyncFileType: Int64] = [:]
    /// Niratan: fingerprint of the book's state files when it was last synced.
    var fingerprint: String?
    /// Niratan: the folder was created by sync for a book that only existed on Drive.
    var placeholder: Bool?
}

nonisolated struct SyncState: Codable {
    var books: [String: SyncRecord] = [:]
    var shelvesPending = false
    var shelvesFingerprint: String?
}

/// The open Reader as seen by the sync engine.
@MainActor
protocol SyncOpenReader: AnyObject {
    var syncFolder: String { get }
    var acceptsSyncedPosition: Bool { get }
    func prepareForExternalStatisticsMutation()
    func applySyncedState(bookmarkChanged: Bool)
    func closeForSyncedDeletion()
    func reloadSyncedSasayakiMatch()
}

/// Lets the sync engine coordinate with the single open Reader window.
@MainActor
enum SyncReaderBridge {
    static weak var model: (any SyncOpenReader)?

    static func model(for key: String) -> (any SyncOpenReader)? {
        guard let model, model.syncFolder.precomposedStringWithCanonicalMapping == key else { return nil }
        return model
    }
}

@MainActor
@Observable
final class SyncStorage {
    static let shared = SyncStorage()
    static let booksChangedNotification = Notification.Name("hoshiBooksChanged")
    static let archiveFolder = "statistics_archive"

    var state = SyncState()
    @ObservationIgnored var onChange: (() -> Void)?

    private init() {
        try? reload()
    }

    // MARK: - State file

    func reload() throws {
        state = BookStorage.load(SyncState.self, from: try storageURL()) ?? SyncState()
    }

    func save() throws {
        try JSONEncoder().encode(state).write(to: storageURL(), options: .atomic)
    }

    func saveChanges(booksChanged: Bool = true) throws {
        try save()
        if booksChanged {
            NotificationCenter.default.post(name: Self.booksChangedNotification, object: nil)
        }
        onChange?()
    }

    func markPending(_ key: String) throws {
        guard state.books[key] != nil else { return }
        if !state.books[key]!.pending {
            state.books[key]!.pending = true
            try save()
        }
        onChange?()
    }

    func resetSyncState() throws {
        state.books = try state.books.filter { try BookStorage.loadMetadata(root: Self.resolveBookDirectory(folder: $0.key)) != nil }
        for (key, var record) in state.books {
            let archived = BookStorage.loadMetadata(root: try Self.bookDirectory(folder: key)) == nil
            record.generation = archived ? 0 : 1
            record.deleted = archived
            record.files = [:]
            record.attached = false
            record.pending = true
            record.fingerprint = nil
            state.books[key] = record
        }
        state.shelvesPending = true
        state.shelvesFingerprint = nil
        try saveChanges()
    }

    // MARK: - Local change detection

    func prepareLibrary() throws {
        for root in try Self.bookDirectories() {
            try prepareBook(root: root)
        }
        try save()
    }

    func prepareBook(root: URL) throws {
        let key = Self.key(root.lastPathComponent)
        if state.books[key] != nil {
            return
        }
        let archived = root.deletingLastPathComponent().lastPathComponent == Self.archiveFolder
        var record = SyncRecord(generation: archived ? 0 : 1, deleted: archived)
        let now = Date.now.syncMilliseconds
        for fileType in SyncFileType.allCases {
            if let url = try sourceURL(key: key, fileType: fileType) {
                record.sources[fileType] = now
                record.observed[fileType] = Self.modificationDate(url)
            }
        }
        state.books[key] = record
    }

    /// Notices books added, re-imported, edited or removed by any part of the app since the
    /// last sync, and marks them pending.
    func detectLocalChanges() throws {
        let now = Date.now.syncMilliseconds
        var changed = false
        let roots = try Self.bookDirectories()
        let shelves = BookStorage.loadShelves() ?? []

        for root in roots {
            let key = Self.key(root.lastPathComponent)
            let archived = root.deletingLastPathComponent().lastPathComponent == Self.archiveFolder
            if archived, BookStorage.loadMetadata(root: try Self.bookDirectory(folder: key)) != nil {
                continue
            }
            if state.books[key] == nil {
                try prepareBook(root: root)
                changed = true
            } else if !archived, state.books[key]!.deleted {
                try handleReimport(key: key, root: root)
                changed = true
            }

            var record = state.books[key]!
            for fileType in SyncFileType.allCases where !record.deleted || fileType == .cover {
                let url = try sourceURL(key: key, fileType: fileType)
                let observed = url.flatMap(Self.modificationDate)
                if observed != record.observed[fileType] {
                    record.observed[fileType] = observed
                    if url != nil || record.sources[fileType] != nil {
                        record.sources[fileType] = now
                    }
                }
            }
            let fingerprint = Self.fingerprint(root: root, shelves: shelves)
            if fingerprint != record.fingerprint {
                record.pending = true
            }
            if record != state.books[key] {
                state.books[key] = record
                changed = true
            }
        }

        // A book folder removed outside the sync flow is only forgotten locally. Deleting it
        // everywhere must be an explicit choice, so the remote copy returns as a placeholder.
        let present = Set(roots.map { Self.key($0.lastPathComponent) })
        for (key, record) in state.books where !present.contains(key) && !record.deleted {
            state.books[key] = nil
            changed = true
        }

        let shelvesFingerprint = Self.shelvesFingerprint()
        if shelvesFingerprint != state.shelvesFingerprint {
            state.shelvesPending = true
            changed = true
        }
        if changed {
            try save()
        }
    }

    func markSynced(_ key: String) {
        guard let root = try? Self.resolveBookDirectory(folder: key), state.books[key] != nil else { return }
        state.books[key]!.fingerprint = Self.fingerprint(root: root, shelves: BookStorage.loadShelves() ?? [])
    }

    func markShelvesSynced() {
        state.shelvesFingerprint = Self.shelvesFingerprint()
    }

    private func handleReimport(key: String, root: URL) throws {
        let oldRecord = state.books[key]!
        try restoreArchive(folder: key, into: root)
        var record = SyncRecord(
            generation: max(1, oldRecord.generation + 1),
            deleted: false,
            attached: oldRecord.attached || oldRecord.generation > 0,
            cleanup: oldRecord.cleanup.union([oldRecord.generation])
        )
        let now = Date.now.syncMilliseconds
        for fileType in SyncFileType.allCases {
            if let url = try sourceURL(key: key, fileType: fileType) {
                record.sources[fileType] = now
                record.observed[fileType] = Self.modificationDate(url)
            }
        }
        state.books[key] = record
        if var metadata = BookStorage.loadMetadata(root: root) {
            metadata.modified = now
            try BookStorage.save(metadata, inside: root, as: FileNames.metadata)
        }
    }

    // MARK: - Book state

    /// The local book as a sync document. Reconciles local edits into the book's ledger first.
    func loadBook(key: String, remote: SyncBook? = nil) throws -> SyncBook? {
        guard let record = state.books[key] else { return nil }
        let root = try Self.resolveBookDirectory(folder: key)
        guard let metadata = BookStorage.loadMetadata(root: root) else {
            guard let remote, record.deleted else { return nil }
            return SyncBook(
                generation: record.generation,
                deleted: true,
                metadata: remote.metadata,
                characterCount: remote.characterCount,
                files: record.files
            )
        }

        let now = Date.now.syncMilliseconds
        var ledger = SyncBookLedger.load(root: root)
        let original = ledger
        SyncStatisticsBridge.reconcile(
            ledger: &ledger,
            statistics: BookStorage.loadStatistics(root: root) ?? [],
            key: key,
            deviceID: SyncDevice.id,
            resetMinutes: Self.resetMinutes,
            now: now
        )
        reconcileMetadata(&ledger, metadata: metadata, now: now)
        if !record.deleted {
            SyncHighlightBridge.reconcile(ledger: &ledger, local: BookStorage.loadHighlights(root: root) ?? [], now: now)
            SyncShelfMembershipBridge.reconcile(
                ledger: &ledger,
                bookID: metadata.id,
                shelves: BookStorage.loadShelves() ?? [],
                now: now
            )
            reconcilePlayback(&ledger, root: root, now: now)
        }
        if ledger != original {
            try ledger.save(root: root)
        }

        var book = SyncBook(
            generation: record.generation,
            deleted: record.deleted,
            metadata: ledger.metadata ?? Timestamped(modified: 0, value: SyncMetadata(title: metadata.displayTitle)),
            characterCount: max(metadata.characterCount ?? 0, BookStorage.loadBookInfo(root: root)?.characterCount ?? 0),
            files: record.files
        )
        book.sessions = ledger.sessions
        if !record.deleted {
            if let bookmark = BookStorage.loadBookmark(root: root) {
                let modified = bookmark.lastModified
                    ?? Self.modificationDate(root.appendingPathComponent(FileNames.bookmark)).map { Date(syncMilliseconds: $0) }
                    ?? .distantPast
                book.bookmark = Timestamped(
                    modified: max(modified.syncMilliseconds, 0),
                    value: SyncBookmark(characterCount: bookmark.characterCount)
                )
            }
            book.audiobook = ledger.audiobook
            book.highlights = ledger.highlights ?? [:]
            book.shelves = ledger.shelves ?? [:]
        }
        return book
    }

    func applyBook(key: String, book: SyncBook) throws {
        let oldRecord = state.books[key]
        let bookURL = try Self.bookDirectory(folder: key)
        let existing = BookStorage.loadMetadata(root: bookURL)
        let folder = existing?.folder ?? bookURL.lastPathComponent
        var booksChanged = existing != nil && (book.deleted || oldRecord?.generation != book.generation)
        let reader = SyncReaderBridge.model(for: key)

        if book.deleted, let existing {
            try archive(existing, root: bookURL)
            try BookStorage.delete(at: bookURL)
        }

        let root = try Self.bookDirectory(folder: folder, archived: book.deleted)
        let stored = book.deleted && book.sessions.values.allSatisfy { $0.value == nil }
        let oldMetadata = BookStorage.loadMetadata(root: root)
        var metadata = oldMetadata ?? BookMetadata(
            title: book.metadata.value.title,
            epub: nil,
            cover: nil,
            folder: folder,
            lastAccess: .distantPast,
            bookLanguage: book.metadata.value.language
        )
        let syncedTitle = book.metadata.value.title
        metadata.renamedTitle = metadata.title == syncedTitle ? nil : syncedTitle
        if let author = book.metadata.value.author {
            metadata.author = author
        }
        if metadata.bookLanguage == nil {
            metadata.bookLanguage = book.metadata.value.language
        }
        metadata.modified = book.metadata.modified
        if book.characterCount > 0 {
            metadata.characterCount = book.characterCount
        }
        if !book.deleted, let bookmark = book.bookmark {
            metadata.lastAccess = max(metadata.lastAccess, Date(syncMilliseconds: bookmark.modified))
        }
        if !stored, metadata != oldMetadata {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try BookStorage.save(metadata, inside: root, as: FileNames.metadata)
            booksChanged = true
        }

        var record = state.books[key] ?? SyncRecord(generation: book.generation, deleted: book.deleted)
        if oldMetadata == nil && !book.deleted {
            record.placeholder = true
        }
        record.generation = book.generation
        record.deleted = book.deleted
        record.files = book.files
        record.attached = true

        var ledger = SyncBookLedger.load(root: root)
        ledger.metadata = book.metadata
        ledger.sessions = book.sessions
        SyncStatisticsBridge.assignDays(&ledger, resetMinutes: Self.resetMinutes)
        if !stored {
            let statistics = BookStorage.loadStatistics(root: root) ?? []
            if let updated = SyncStatisticsBridge.applyingSessions(ledger, to: statistics, title: metadata.displayTitle) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try BookStorage.save(updated, inside: root, as: FileNames.statistics)
                ledger.appliedDaily = SyncStatisticsBridge.dailyTotals(updated)
                booksChanged = true
            } else {
                ledger.appliedDaily = SyncStatisticsBridge.dailyTotals(statistics)
            }
        }

        var bookmarkChanged = false
        if !book.deleted {
            if let change = book.bookmark, reader?.acceptsSyncedPosition ?? true {
                let bookmark = BookStorage.loadBookmark(root: root)
                if bookmark?.characterCount != change.value.characterCount
                    || (bookmark?.lastModified?.syncMilliseconds ?? .min) < change.modified {
                    let position = BookStorage.loadBookInfo(root: root)?.resolveCharacterPosition(change.value.characterCount)
                    let updated = Bookmark(
                        chapterIndex: position?.spineIndex ?? bookmark?.chapterIndex ?? 0,
                        progress: position?.progress ?? bookmark?.progress ?? 0,
                        characterCount: change.value.characterCount,
                        lastModified: Date(syncMilliseconds: change.modified)
                    )
                    bookmarkChanged = bookmark?.characterCount != change.value.characterCount
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try BookStorage.save(updated, inside: root, as: FileNames.bookmark)
                    booksChanged = booksChanged || bookmarkChanged
                }
            }

            ledger.highlights = book.highlights
            let localHighlights = BookStorage.loadHighlights(root: root) ?? []
            if !SyncHighlightBridge.sameContent(localHighlights, book.highlights) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try BookStorage.save(SyncHighlightBridge.highlights(from: book.highlights), inside: root, as: FileNames.highlights)
            }

            // While the Reader is open its player owns the playback file; the ledger keeps the
            // last applied value so the older local position is not re-stamped as newer.
            if let change = book.audiobook, reader == nil {
                ledger.audiobook = change
                var playback = BookStorage.loadSasayakiPlayback(root: root) ?? SasayakiPlaybackData(lastPosition: 0)
                let local = SyncPlayback(lastPosition: playback.lastPosition, delay: playback.delay, rate: Double(playback.rate))
                if !Self.samePlayback(local, change.value) {
                    playback.lastPosition = change.value.lastPosition
                    playback.delay = change.value.delay
                    playback.rate = Float(change.value.rate)
                    try BookStorage.save(playback, inside: root, as: FileNames.sasayakiPlayback)
                }
            }

            ledger.shelves = book.shelves
            if var shelves = BookStorage.loadShelves(),
               SyncShelfMembershipBridge.apply(book.shelves, bookID: metadata.id, to: &shelves) {
                try BookStorage.save(shelves, inside: try BookStorage.getBooksDirectory(), as: FileNames.shelves)
                booksChanged = true
            }
        } else {
            for fileType in [SyncFileType.epub, .sasayaki] {
                record.sources.removeValue(forKey: fileType)
                record.observed.removeValue(forKey: fileType)
            }
            if oldRecord?.deleted != true || oldRecord?.generation != book.generation {
                record.sources.removeValue(forKey: .cover)
                record.observed.removeValue(forKey: .cover)
            }
        }

        if !stored {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try ledger.save(root: root)
        }

        state.books[key] = record
        try clearUnusedCover(key: key, sessions: book.sessions)
        if state.books[key] != oldRecord {
            try save()
        }
        if stored {
            try BookStorage.delete(at: root)
        }
        reader?.applySyncedState(bookmarkChanged: bookmarkChanged)
        if booksChanged {
            NotificationCenter.default.post(name: Self.booksChangedNotification, object: nil)
        }
    }

    private func reconcileMetadata(_ ledger: inout SyncBookLedger, metadata: BookMetadata, now: Int64) {
        // The language is only filled in where missing, so devices that detected different
        // languages keep their own without overwriting each other forever.
        let current = SyncMetadata(
            title: metadata.displayTitle,
            author: metadata.author ?? ledger.metadata?.value.author,
            language: ledger.metadata?.value.language ?? metadata.bookLanguage
        )
        guard let known = ledger.metadata else {
            ledger.metadata = Timestamped(modified: metadata.modified ?? 0, value: current)
            return
        }
        if known.value != current {
            ledger.metadata = Timestamped(modified: max(now, known.modified + 1), value: current)
        }
    }

    private func reconcilePlayback(_ ledger: inout SyncBookLedger, root: URL, now: Int64) {
        guard let playback = BookStorage.loadSasayakiPlayback(root: root) else { return }
        let current = SyncPlayback(lastPosition: playback.lastPosition, delay: playback.delay, rate: Double(playback.rate))
        guard let known = ledger.audiobook else {
            let modified = Self.modificationDate(root.appendingPathComponent(FileNames.sasayakiPlayback)) ?? 0
            ledger.audiobook = Timestamped(modified: modified, value: current)
            return
        }
        if !Self.samePlayback(known.value, current) {
            ledger.audiobook = Timestamped(modified: max(now, known.modified + 1), value: current)
        }
    }

    static func samePlayback(_ lhs: SyncPlayback, _ rhs: SyncPlayback) -> Bool {
        abs(lhs.lastPosition - rhs.lastPosition) < 0.001
            && abs(lhs.delay - rhs.delay) < 0.001
            && abs(lhs.rate - rhs.rate) < 0.0001
    }

    // MARK: - Library actions

    /// Removes only the EPUB on this device; the book stays in the library and on Drive.
    func deleteLocalBook(key: String) throws {
        let root = try Self.bookDirectory(folder: key)
        guard var metadata = BookStorage.loadMetadata(root: root), let epub = metadata.epub else { return }
        try BookStorage.delete(at: root.appendingPathComponent(epub))
        try BookStorage.delete(at: root.appendingPathComponent(FileNames.bookinfo))
        metadata.epub = nil
        try BookStorage.save(metadata, inside: root, as: FileNames.metadata)

        if state.books[key] != nil {
            state.books[key]!.sources.removeValue(forKey: .epub)
            state.books[key]!.observed.removeValue(forKey: .epub)
            try save()
        }
        NotificationCenter.default.post(name: Self.booksChangedNotification, object: nil)
    }

    /// Deletes the book on every device. Statistics are archived and keep syncing.
    func deleteBook(key: String, syncEnabled: Bool) throws {
        let root = try Self.bookDirectory(folder: key)
        guard let metadata = BookStorage.loadMetadata(root: root) else { return }
        try prepareBook(root: root)
        try archive(metadata, root: root)
        let archive = try Self.bookDirectory(folder: key, archived: true)
        let stored = SyncBookLedger.load(root: archive).sessions.values.allSatisfy { $0.value == nil }
            && (BookStorage.loadStatistics(root: archive) ?? []).allSatisfy { $0.charactersRead == 0 && $0.readingTime == 0 }

        var record = state.books[key]!
        if stored, !record.attached, !syncEnabled {
            state.books[key] = nil
            try save()
            try BookStorage.delete(at: archive)
            try BookStorage.delete(at: root)
            NotificationCenter.default.post(name: Self.booksChangedNotification, object: nil)
            return
        }
        record.deleted = true
        record.pending = true
        record.cleanup.insert(record.generation)
        record.files[.epub] = nil
        record.files[.sasayaki] = nil
        record.sources[.epub] = nil
        record.sources[.sasayaki] = nil
        record.observed = [:]
        state.books[key] = record

        try BookStorage.delete(at: root)
        if stored {
            try BookStorage.delete(at: archive)
        }
        try clearUnusedCover(key: key)
        try saveChanges()
    }

    func applyShelves(_ merged: SyncShelves) throws {
        let directory = try BookStorage.getBooksDirectory()
        let local = BookStorage.loadShelves() ?? []
        let books = (try? BookStorage.loadAllBooks()) ?? []
        // Memberships changed since each book's last sync are recorded first, so a book the
        // user just removed from a shelf is not put back from a stale ledger.
        let now = Date.now.syncMilliseconds
        var ledgers: [UUID: [String: Timestamped<Bool>]] = [:]
        for book in books {
            let root = directory.appendingPathComponent(book.folder)
            var ledger = SyncBookLedger.load(root: root)
            guard ledger.shelves != nil else { continue }
            let original = ledger
            SyncShelfMembershipBridge.reconcile(ledger: &ledger, bookID: book.id, shelves: local, now: now)
            if ledger != original {
                try ledger.save(root: root)
                if state.books[Self.key(book.folder)] != nil {
                    state.books[Self.key(book.folder)]!.pending = true
                }
            }
            ledgers[book.id] = ledger.shelves
        }
        let validIDs = Set(books.map(\.id))

        let names = merged.shelves
            .compactMap { name, record in record.value.map { (name: name, position: $0) } }
            .sorted { ($0.position, $0.name) < ($1.position, $1.name) }
            .map(\.name)
        let updated: [BookShelf] = names.map { name in
            let existing = local.first { SyncShelfLedger.key($0.name) == name }
            var ids = (existing?.bookIds ?? []).filter { validIDs.contains($0) }
            for book in books where !ids.contains(book.id) && ledgers[book.id]?[name]?.value == true {
                ids.append(book.id)
            }
            return BookShelf(name: existing?.name ?? name, bookIds: ids)
        }

        let current = local.map { ($0.name, $0.bookIds) }
        if updated.map({ ($0.name, $0.bookIds) }).elementsEqual(current, by: { $0.0 == $1.0 && $0.1 == $1.1 }) == false {
            try BookStorage.save(updated, inside: directory, as: FileNames.shelves)
            NotificationCenter.default.post(name: Self.booksChangedNotification, object: nil)
        }
        try SyncShelfLedger.save(merged)
    }

    func sourceURL(key: String, fileType: SyncFileType) throws -> URL? {
        let root = try Self.resolveBookDirectory(folder: key)
        let metadata = BookStorage.loadMetadata(root: root)
        let url: URL?
        switch fileType {
        case .epub:
            url = metadata?.epub.map { root.appendingPathComponent($0) }
        case .cover:
            url = metadata?.coverURL
        case .sasayaki:
            url = root.appendingPathComponent(FileNames.sasayakiMatch)
        }
        guard let url, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }

    func clearUnusedCover(key: String, sessions: [String: Timestamped<ReadingSession?>]? = nil) throws {
        guard var record = state.books[key], record.deleted else { return }
        let root = try Self.resolveBookDirectory(folder: key)
        let sessions = sessions ?? SyncBookLedger.load(root: root).sessions
        guard sessions.values.allSatisfy({ $0.value == nil }) else { return }

        if var metadata = BookStorage.loadMetadata(root: root), let cover = metadata.coverURL {
            try BookStorage.delete(at: cover)
            metadata.cover = nil
            try BookStorage.save(metadata, inside: root, as: FileNames.metadata)
        }
        let published = record.files[.cover]
        if published?.value == nil && (record.sources[.cover] ?? .min) <= (published?.modified ?? .min) {
            return
        }
        let modified = Date.now.syncMilliseconds
        record.files[.cover] = Timestamped(modified: modified, value: nil)
        record.sources[.cover] = modified
        record.observed[.cover] = nil
        record.cleanup.insert(record.generation)
        record.pending = true
        state.books[key] = record
    }

    /// Clears the local copy of a book whose generation was replaced remotely.
    func removeBookFiles(key: String) throws {
        let root = try Self.resolveBookDirectory(folder: key)
        if var metadata = BookStorage.loadMetadata(root: root) {
            if let epub = metadata.epub {
                try BookStorage.delete(at: root.appendingPathComponent(epub))
            }
            if let cover = metadata.coverURL {
                try BookStorage.delete(at: cover)
            }
            for name in [FileNames.bookinfo, FileNames.sasayakiMatch, FileNames.bookmark, FileNames.highlights] {
                try BookStorage.delete(at: root.appendingPathComponent(name))
            }
            if var playback = BookStorage.loadSasayakiPlayback(root: root) {
                playback.lastPosition = 0
                playback.delay = 0
                playback.rate = 1
                try BookStorage.save(playback, inside: root, as: FileNames.sasayakiPlayback)
            }
            var ledger = SyncBookLedger.load(root: root)
            ledger.highlights = [:]
            ledger.audiobook = nil
            try ledger.save(root: root)

            metadata.epub = nil
            metadata.cover = nil
            try BookStorage.save(metadata, inside: root, as: FileNames.metadata)
        }
        state.books[key]?.sources = [:]
        state.books[key]?.observed = [:]
    }

    /// Removes books that only existed remotely; used when the Drive connection changes. Only
    /// placeholders created by library sync are touched.
    func removePlaceholders() throws {
        for book in try BookStorage.loadAllBooks() where book.epub == nil {
            let key = Self.key(book.folder)
            guard state.books[key]?.placeholder == true else { continue }
            let root = try Self.bookDirectory(folder: book.folder)
            if SyncBookLedger.load(root: root).sessions.values.contains(where: { $0.value != nil }) {
                try archive(book, root: root)
            } else {
                state.books[key] = nil
            }
            try BookStorage.delete(at: root)
        }
        NotificationCenter.default.post(name: Self.booksChangedNotification, object: nil)
    }

    // MARK: - Statistics archive

    /// Keeps a deleted book's statistics, ledger and a cover so its reading history survives.
    func archive(_ book: BookMetadata, root: URL) throws {
        let destination = try Self.bookDirectory(folder: book.folder, archived: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var ledger = SyncBookLedger.load(root: root)
        let archived = SyncBookLedger.load(root: destination)
        ledger.sessions = SyncBook.mergeRecords(ledger.sessions, archived.sessions)
        ledger.sessionDays.merge(archived.sessionDays) { current, _ in current }
        ledger.highlights = nil
        ledger.shelves = nil
        ledger.audiobook = nil
        try ledger.save(root: destination)

        if let statistics = BookStorage.loadStatistics(root: root) {
            let merged = StatisticsEditor.deduplicated(statistics + (BookStorage.loadStatistics(root: destination) ?? []))
            try BookStorage.save(merged, inside: destination, as: FileNames.statistics)
        }

        var cover: String?
        if let source = book.coverURL, FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) {
            let name = "cover." + (source.pathExtension.isEmpty ? "jpg" : source.pathExtension)
            try BookStorage.delete(at: destination.appendingPathComponent(name))
            try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(name))
            cover = "Books/\(Self.archiveFolder)/\(book.folder)/\(name)"
        }
        var metadata = BookMetadata(
            id: book.id,
            title: book.title,
            epub: nil,
            cover: cover,
            folder: book.folder,
            lastAccess: book.lastAccess,
            bookLanguage: book.bookLanguage
        )
        metadata.renamedTitle = book.renamedTitle
        metadata.author = book.author
        metadata.modified = book.modified
        metadata.characterCount = book.characterCount ?? BookStorage.loadBookInfo(root: root)?.characterCount
        try BookStorage.save(metadata, inside: destination, as: FileNames.metadata)
    }

    /// Brings archived statistics back when a deleted book is imported again.
    private func restoreArchive(folder: String, into root: URL) throws {
        let archive = try Self.bookDirectory(folder: folder, archived: true)
        guard FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)) else { return }
        let archived = SyncBookLedger.load(root: archive)
        var ledger = SyncBookLedger.load(root: root)
        ledger.sessions = SyncBook.mergeRecords(ledger.sessions, archived.sessions)
        ledger.sessionDays.merge(archived.sessionDays) { current, _ in current }
        if let archivedStatistics = BookStorage.loadStatistics(root: archive) {
            let merged = StatisticsEditor.deduplicated((BookStorage.loadStatistics(root: root) ?? []) + archivedStatistics)
            try BookStorage.save(merged, inside: root, as: FileNames.statistics)
            ledger.appliedDaily = SyncStatisticsBridge.dailyTotals(merged)
        }
        try ledger.save(root: root)
        try FileManager.default.removeItem(at: archive)
    }

    // MARK: - Paths

    static func key(_ folder: String) -> String {
        folder.precomposedStringWithCanonicalMapping
    }

    static func bookDirectories() throws -> [URL] {
        let booksDirectory = try BookStorage.getBooksDirectory()
        return try [booksDirectory, booksDirectory.appendingPathComponent(archiveFolder)].flatMap { directory in
            guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [URL]() }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { BookStorage.loadMetadata(root: $0) != nil }
        }
    }

    static func bookDirectory(folder: String, archived: Bool = false) throws -> URL {
        try BookStorage.getBooksDirectory().appendingPathComponent((archived ? "\(archiveFolder)/" : "") + folder)
    }

    static func resolveBookDirectory(folder: String) throws -> URL {
        let bookURL = try bookDirectory(folder: folder)
        return BookStorage.loadMetadata(root: bookURL) != nil ? bookURL : try bookDirectory(folder: folder, archived: true)
    }

    static var resetMinutes: Int {
        StatisticsResetTimePreference.load(from: .standard)
    }

    static func modificationDate(_ url: URL) -> Int64? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date else {
            return nil
        }
        return date.syncMilliseconds
    }

    private static func fingerprint(root: URL, shelves: [BookShelf]) -> String {
        let files = [
            FileNames.metadata,
            FileNames.bookmark,
            FileNames.highlights,
            FileNames.statistics,
            FileNames.sasayakiPlayback,
            FileNames.sasayakiMatch,
        ]
        var parts = files.map { name in
            modificationDate(root.appendingPathComponent(name)).map(String.init) ?? "-"
        }
        if let metadata = BookStorage.loadMetadata(root: root) {
            parts.append(shelves.filter { $0.bookIds.contains(metadata.id) }.map { key($0.name) }.sorted().joined(separator: "\u{1F}"))
        }
        return parts.joined(separator: "|")
    }

    private static func shelvesFingerprint() -> String? {
        guard let url = try? BookStorage.getBooksDirectory().appendingPathComponent(FileNames.shelves) else { return nil }
        return modificationDate(url).map(String.init)
    }

    private func storageURL() throws -> URL {
        let booksDirectory = try BookStorage.getBooksDirectory()
        try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        return booksDirectory.appendingPathComponent(".sync.json")
    }
}
