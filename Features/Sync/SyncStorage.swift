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
    /// Remote ids in this state belong to one library, independently of the network cache.
    /// Missing in older Niratan files, so losing the cache cannot reuse their old file ids.
    var libraryName: String?
    var books: [String: SyncRecord] = [:]
    var shelvesPending = false
    var shelvesFingerprint: String?
}

/// The open Reader as seen by the sync engine.
@MainActor
protocol SyncOpenReader: AnyObject {
    var syncFolder: String { get }
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
            record.cleanup = []
            record.attached = false
            record.pending = true
            record.fingerprint = nil
            state.books[key] = record
        }
        state.libraryName = "Hoshi Reader"
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
                if fileType == .epub, record.attached, record.files[.epub]?.value != nil, url == nil {
                    // Published EPUBs can be fetched again. Losing this device's copy is
                    // cache eviction, not a newer edit that removes the cloud reference.
                    record.sources.removeValue(forKey: .epub)
                    record.observed.removeValue(forKey: .epub)
                    continue
                }
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
        if !record.deleted, root.deletingLastPathComponent().lastPathComponent != Self.archiveFolder {
            try restoreArchive(folder: metadata.folder, into: root)
        }

        let now = Date.now.syncMilliseconds
        var ledger = SyncBookLedger.load(root: root)
        let original = ledger
        let sessions = try canonicalSessions(root: root, ledger: &ledger, now: now)
        ledger.sessions = sessions
        reconcileMetadata(&ledger, metadata: metadata, now: now)
        if !record.deleted {
            let coordinates = try coordinateMap(root: root, metadata: metadata, record: record)
            migrateCoordinateLedger(&ledger, root: root, remote: remote)
            reconcileCoordinates(&ledger, root: root, record: record, coordinates: coordinates, now: now)
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
            characterCount: ledger.canonicalCharacterCount ?? 0,
            files: record.files
        )
        book.sessions = ledger.sessions
        if !record.deleted {
            book.bookmark = ledger.canonicalBookmark
            book.audiobook = ledger.audiobook
            book.highlights = ledger.highlights ?? [:]
            book.shelves = ledger.shelves ?? [:]
        }
        return book
    }

    // MARK: - Shared EPUB coordinates

    private func coordinateMap(root: URL, metadata: BookMetadata, record: SyncRecord) throws -> EPUBSyncCoordinates? {
        guard !record.deleted, let epub = metadata.epub, let info = BookStorage.loadBookInfo(root: root) else { return nil }
        // A newer published reference still points at the remote EPUB. The old local copy
        // cannot project its positions until download has recorded that reference as source.
        if let published = record.files[.epub], (record.sources[.epub] ?? .min) < published.modified { return nil }
        let url = root.appendingPathComponent(epub)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try? EPUBSyncCoordinates.load(
            epubURL: url, nativeInfo: info, generation: record.generation,
            epubReference: record.files[.epub]?.value
        )
    }

    private static func coordinateIdentity(_ coordinates: EPUBSyncCoordinates, record: SyncRecord) -> SyncCoordinateIdentity {
        SyncCoordinateIdentity(
            source: SyncCoordinateSource(generation: record.generation, epub: record.files[.epub]),
            content: coordinates.identity
        )
    }

    private static func bookmarkModified(_ bookmark: Bookmark, root: URL) -> Int64 {
        max(bookmark.lastModified?.syncMilliseconds
            ?? modificationDate(root.appendingPathComponent(FileNames.bookmark)) ?? 0, 0)
    }

    private static func highlightKeysByLocalID(_ keys: [String]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for key in keys {
            guard let localID = UUID(uuidString: key)?.uuidString else { continue }
            result[localID, default: []].insert(key)
        }
        return result
    }

    private func migrateCoordinateLedger(_ ledger: inout SyncBookLedger, root: URL, remote: SyncBook?) {
        guard ledger.coordinateVersion == nil else { return }
        if let bookmark = BookStorage.loadBookmark(root: root), let wire = remote?.bookmark,
           bookmark.characterCount == wire.value.characterCount,
           Self.bookmarkModified(bookmark, root: root) == wire.modified {
            // The old adapter copied this exact wire record into the native sidecar. Its
            // remote timestamp and raw coordinate prove its origin; do not convert twice.
            ledger.canonicalBookmark = wire
        }
        let local = Dictionary((BookStorage.loadHighlights(root: root) ?? []).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { _, last in last })
        var native = ledger.legacyNativeHighlights ?? [:]
        let keys = Self.highlightKeysByLocalID(Array((ledger.highlights ?? [:]).keys) + Array(native.keys))
        var canonical: [String: Timestamped<SyncHighlight?>] = [:]
        for (id, record) in ledger.highlights ?? [:] {
            if record.value == nil || remote?.highlights[id] == record {
                canonical[id] = record
            } else if let value = record.value, let localID = UUID(uuidString: id)?.uuidString,
                      keys[localID]?.count == 1, let highlight = local[localID],
                      value.character == highlight.character && value.offset == highlight.offset && value.text == highlight.text {
                native[id] = record
            } else {
                // There is no proof that this record came from the native sidecar.
                canonical[id] = record
            }
        }
        ledger.highlights = canonical
        ledger.legacyNativeHighlights = native.isEmpty ? nil : native
        ledger.coordinateVersion = 1
        if let remote { ledger.canonicalCharacterCount = remote.characterCount }
    }

    private func reconcileCoordinates(
        _ ledger: inout SyncBookLedger, root: URL, record: SyncRecord,
        coordinates: EPUBSyncCoordinates?, now: Int64
    ) {
        guard let coordinates else { return }
        let identity = Self.coordinateIdentity(coordinates, record: record)
        ledger.coordinateSource = identity.source
        ledger.canonicalCharacterCount = coordinates.canonicalTotal
        if let bookmark = BookStorage.loadBookmark(root: root) {
            let modified = Self.bookmarkModified(bookmark, root: root)
            if let receipt = ledger.bookmarkProjection, receipt.identity == identity,
               receipt.isUnchanged(bookmark, modified: modified) {
                // Reader geometry or a one-unit projection round trip must not restamp the
                // canonical record. Only its local projection receipt follows the sidecar.
                ledger.bookmarkProjection = SyncBookmarkProjection(identity: identity, bookmark: bookmark, modified: modified, canonicalBookmark: receipt.canonicalBookmark)
            } else if let receipt = ledger.bookmarkProjection, receipt.identity == identity,
                      let canonical = ledger.canonicalBookmark, receipt.canonicalBookmark == canonical,
                      modified >= receipt.modified,
                      coordinates.canonicalCharacter(forNativeBookmark: bookmark) == canonical.value.characterCount {
                // A real move can remain inside one coarser canonical unit. Reader then
                // retains its timestamp, but the native geometry receipt must still move.
                // Exact record association excludes a newer pending remote position.
                ledger.bookmarkProjection = SyncBookmarkProjection(identity: identity, bookmark: bookmark,
                                                                  modified: modified, canonicalBookmark: canonical)
            } else if ledger.canonicalBookmark == nil {
                if let raw = coordinates.canonicalCharacter(forNativeBookmark: bookmark) {
                    ledger.canonicalBookmark = Timestamped(modified: modified, value: SyncBookmark(characterCount: raw))
                    ledger.bookmarkProjection = SyncBookmarkProjection(identity: identity, bookmark: bookmark, modified: modified, canonicalBookmark: ledger.canonicalBookmark)
                }
            } else if let receipt = ledger.bookmarkProjection, receipt.identity == identity,
                      modified > max(receipt.modified, ledger.canonicalBookmark?.modified ?? 0),
                      let raw = coordinates.canonicalCharacter(forNativeBookmark: bookmark) {
                if ledger.canonicalBookmark?.value.characterCount != raw {
                    ledger.canonicalBookmark = Timestamped(modified: modified, value: SyncBookmark(characterCount: raw))
                }
                ledger.bookmarkProjection = SyncBookmarkProjection(identity: identity, bookmark: bookmark, modified: modified, canonicalBookmark: ledger.canonicalBookmark)
            } else if let canonical = ledger.canonicalBookmark,
                      modified == canonical.modified,
                      let expected = coordinates.nativeBookmark(forCanonical: canonical.value.characterCount, modified: canonical.modified),
                      SyncBookmarkProjection(identity: identity, bookmark: expected, modified: canonical.modified).samePosition(as: bookmark) {
                ledger.bookmarkProjection = SyncBookmarkProjection(identity: identity, bookmark: bookmark, modified: modified, canonicalBookmark: canonical)
            }
        }

        var canonical = ledger.highlights ?? [:]
        let previous = ledger.highlightProjection?.identity == identity ? ledger.highlightProjection?.native ?? [:] : [:]
        let keys = Self.highlightKeysByLocalID(Array(canonical.keys) + Array(previous.keys) + Array((ledger.legacyNativeHighlights ?? [:]).keys))
        let local = BookStorage.loadHighlights(root: root) ?? []
        let localIDs = Set(local.map(\.id.uuidString))
        var snapshot: [String: SyncHighlight] = [:]
        for highlight in local {
            let localID = highlight.id.uuidString
            let candidates = keys[localID] ?? []
            guard candidates.count <= 1 else { continue }
            // UUID decoding changes letter case. Preserve the sole original wire key;
            // multiple wire keys for one local UUID cannot safely be reconciled.
            let id = candidates.first ?? localID
            if let known = canonical[id], known.value == nil { continue }
            if let native = previous[id], SyncHighlightBridge.matches(native, highlight) {
                snapshot[id] = SyncHighlight(highlight)
                continue
            }
            if previous[id] == nil, let value = canonical[id]?.value,
               ledger.legacyNativeHighlights?[id] == nil {
                // No application receipt means the sidecar may still belong to an old
                // EPUB/reference. Establish a baseline only when this exact projection
                // already matches; otherwise wait for applyPendingCoordinates.
                if let projected = coordinates.projectCanonicalHighlight(value), SyncHighlightBridge.matches(projected, highlight) {
                    snapshot[id] = SyncHighlight(highlight)
                }
                continue
            }
            guard var exported = coordinates.exportNativeHighlight(highlight) else { continue }
            if let known = canonical[id], let value = known.value {
                exported.textFurigana = highlight.textFurigana ?? value.textFurigana
                if HighlightColor(rawValue: value.color) == nil && highlight.color == .yellow { exported.color = value.color }
                if !SyncHighlightBridge.matches(exported, value) {
                    canonical[id] = Timestamped(modified: max(now, known.modified + 1), value: exported)
                }
            } else {
                let legacy = ledger.legacyNativeHighlights?[id]
                var modified = legacy?.modified ?? highlight.createdAt.syncMilliseconds
                if let value = legacy?.value {
                    exported.textFurigana = highlight.textFurigana ?? value.textFurigana
                    if HighlightColor(rawValue: value.color) == nil && highlight.color == .yellow { exported.color = value.color }
                    if !SyncHighlightBridge.matches(value, highlight) { modified = max(now, modified + 1) }
                }
                canonical[id] = Timestamped(modified: modified, value: exported)
            }
            ledger.legacyNativeHighlights?.removeValue(forKey: id)
            snapshot[id] = SyncHighlight(highlight)
        }
        for id in previous.keys {
            guard let localID = UUID(uuidString: id)?.uuidString, keys[localID]?.count == 1,
                  !localIDs.contains(localID) else { continue }
            if canonical[id]?.value != nil { canonical[id] = Timestamped(modified: now, value: nil) }
        }
        ledger.highlights = canonical
        ledger.highlightProjection = SyncHighlightProjection(identity: identity, native: snapshot)
        if ledger.legacyNativeHighlights?.isEmpty == true { ledger.legacyNativeHighlights = nil }
    }

    @discardableResult
    private func applyCoordinateProjection(
        _ ledger: inout SyncBookLedger, root: URL, record: SyncRecord,
        coordinates: EPUBSyncCoordinates?
    ) throws -> Bool {
        guard let coordinates else { return false }
        let identity = Self.coordinateIdentity(coordinates, record: record)
        ledger.canonicalCharacterCount = coordinates.canonicalTotal
        var changed = false
        if let canonical = ledger.canonicalBookmark,
           let projected = coordinates.nativeBookmark(forCanonical: canonical.value.characterCount, modified: canonical.modified) {
            let local = BookStorage.loadBookmark(root: root)
            if let previous = ledger.bookmarkProjection, previous.identity == identity,
               previous.canonicalBookmark?.value == canonical.value, let local,
               previous.matches(local, modified: Self.bookmarkModified(local, root: root)) {
                // A local export can represent a point between two canonical units.
                // Reapplying that same record must not move the native Reader backwards.
                if previous.canonicalBookmark != canonical {
                    let updated = Bookmark(chapterIndex: local.chapterIndex, progress: local.progress,
                                           characterCount: local.characterCount, lastModified: Date(syncMilliseconds: canonical.modified))
                    try BookStorage.save(updated, inside: root, as: FileNames.bookmark)
                    ledger.bookmarkProjection = SyncBookmarkProjection(identity: identity, bookmark: updated,
                                                                      modified: canonical.modified, canonicalBookmark: canonical)
                }
            } else {
                let receipt = SyncBookmarkProjection(identity: identity, bookmark: projected, modified: canonical.modified, canonicalBookmark: canonical)
                changed = local.map { !receipt.samePosition(as: $0) } ?? true
                if changed || local.map({ Self.bookmarkModified($0, root: root) != canonical.modified }) == true {
                    try BookStorage.save(projected, inside: root, as: FileNames.bookmark)
                }
                ledger.bookmarkProjection = receipt
            }
        } else {
            ledger.bookmarkProjection = nil
        }

        let existing = BookStorage.loadHighlights(root: root) ?? []
        var snapshot: [String: SyncHighlight] = [:]
        let canonical = ledger.highlights ?? [:]
        let keys = Self.highlightKeysByLocalID(Array(canonical.keys) + Array((ledger.highlightProjection?.native ?? [:]).keys) + Array((ledger.legacyNativeHighlights ?? [:]).keys))
        let ambiguous = Set(keys.filter { $0.value.count > 1 }.map(\.key))
        let preserved = existing.filter { ambiguous.contains($0.id.uuidString) }
        var native = Dictionary(existing.filter { !ambiguous.contains($0.id.uuidString) }.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { _, last in last })
        for id in (ledger.highlightProjection?.native ?? [:]).keys {
            guard let localID = UUID(uuidString: id)?.uuidString, keys[localID]?.count == 1 else { continue }
            if canonical[id] == nil || canonical[id]?.value == nil { native[localID] = nil }
        }
        for (id, record) in canonical {
            guard let localID = UUID(uuidString: id)?.uuidString, keys[localID]?.count == 1 else { continue }
            guard let value = record.value else { native[localID] = nil; continue }
            guard let projected = coordinates.projectCanonicalHighlight(value), let highlight = projected.highlight(id: id) else { continue }
            native[localID] = highlight
            snapshot[id] = projected
        }
        let updated = (Array(native.values) + preserved).sorted { ($0.character, $0.createdAt, $0.id.uuidString) < ($1.character, $1.createdAt, $1.id.uuidString) }
        if updated != existing { try BookStorage.save(updated, inside: root, as: FileNames.highlights) }
        ledger.highlightProjection = SyncHighlightProjection(identity: identity, native: snapshot)
        return changed
    }

    /// Called after the exact downloaded EPUB has produced its native BookInfo, and before
    /// Reader restoration. Pending canonical positions never enter the native sidecars early.
    func applyPendingCoordinates(key: String) throws {
        guard let record = state.books[key], !record.deleted else { return }
        let root = try Self.resolveBookDirectory(folder: key)
        guard let metadata = BookStorage.loadMetadata(root: root) else { return }
        var ledger = SyncBookLedger.load(root: root)
        guard ledger.coordinateVersion == 1 else { return }
        let coordinates = try coordinateMap(root: root, metadata: metadata, record: record)
        guard coordinates != nil else { return }
        // Opening again before the next periodic sync must preserve a real native edit
        // made after the last application receipt.
        reconcileCoordinates(&ledger, root: root, record: record, coordinates: coordinates, now: Date.now.syncMilliseconds)
        let changed = try applyCoordinateProjection(&ledger, root: root, record: record, coordinates: coordinates)
        try ledger.save(root: root)
        SyncReaderBridge.model(for: key)?.applySyncedState(bookmarkChanged: changed)
        NotificationCenter.default.post(name: Self.booksChangedNotification, object: nil)
    }

    /// Reader retains this validated value for its session. A cached map alone does not
    /// prove that a newer remote generation/reference has reached the local EPUB.
    func sharedCoordinates(root: URL) -> EPUBSyncCoordinates? {
        guard SyncBookLedger.load(root: root).coordinateVersion == 1,
              let metadata = BookStorage.loadMetadata(root: root),
              let record = state.books[Self.key(root.lastPathComponent)] else { return nil }
        return try? coordinateMap(root: root, metadata: metadata, record: record)
    }

    /// A replaced reference may need downloading even when an older local EPUB exists.
    /// This query only inspects local state and never starts a transfer.
    func needsEPUBDownload(key: String) -> Bool {
        guard let record = state.books[key], record.attached, !record.deleted,
              let published = record.files[.epub], published.value != nil else { return false }
        if (record.sources[.epub] ?? .min) < published.modified { return true }
        guard let root = try? Self.resolveBookDirectory(folder: key),
              let epub = BookStorage.loadMetadata(root: root)?.epub else { return true }
        return !FileManager.default.fileExists(atPath: root.appendingPathComponent(epub).path(percentEncoded: false))
    }

    /// Shelf display uses one coordinate system for both numerator and denominator.
    /// A pending local EPUB without a map cannot safely combine its native raw position
    /// with the canonical total; remote-only placeholders can display their wire ratio.
    func sharedProgress(root: URL, bookmark: Bookmark?) -> Double? {
        let ledger = SyncBookLedger.load(root: root)
        guard let total = ledger.canonicalCharacterCount, total > 0 else { return nil }
        if let canonical = ledger.canonicalBookmark {
            if BookStorage.loadMetadata(root: root)?.epub == nil {
                return min(1, max(0, Double(canonical.value.characterCount) / Double(total)))
            }
        }
        guard let bookmark, let metadata = BookStorage.loadMetadata(root: root),
              let record = state.books[Self.key(root.lastPathComponent)],
              let coordinates = try? coordinateMap(root: root, metadata: metadata, record: record),
              coordinates.canonicalTotal > 0 else { return nil }
        if let canonical = ledger.canonicalBookmark {
            guard let receipt = ledger.bookmarkProjection,
                  receipt.identity == Self.coordinateIdentity(coordinates, record: record) else { return nil }
            let modified = Self.bookmarkModified(bookmark, root: root)
            if receipt.matches(bookmark, modified: modified), receipt.canonicalBookmark == canonical {
                return min(1, max(0, Double(canonical.value.characterCount) / Double(coordinates.canonicalTotal)))
            }
            guard modified > receipt.modified else { return nil }
        }
        guard let raw = coordinates.canonicalCharacter(forNativeBookmark: bookmark) else { return nil }
        return min(1, max(0, Double(raw) / Double(coordinates.canonicalTotal)))
    }

    private func canonicalSessions(root: URL, ledger: inout SyncBookLedger, now: Int64) throws -> ReadingSessionRecords {
        let local = StatisticsStorage.load(root: root, resetMinutes: Self.resetMinutes)
        if ledger.canonicalSessions != true, ledger.appliedDaily != nil {
            let migrated = SyncSessionMigration.canonicalRecords(
                local,
                ledger: &ledger,
                key: Self.key(root.lastPathComponent),
                deviceID: SyncDevice.id,
                resetMinutes: Self.resetMinutes,
                now: now
            )
            if migrated != local {
                try StatisticsStorage.save(migrated, root: root, resetMinutes: Self.resetMinutes)
            }
            ledger.canonicalSessions = true
            ledger.appliedDaily = nil
            ledger.sessionDays = [:]
            return migrated
        }
        ledger.canonicalSessions = true
        return local
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
        let stored = book.deleted && book.sessions.isEmpty
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
        if let info = BookStorage.loadBookInfo(root: root) {
            metadata.characterCount = info.characterCount
        } else if book.characterCount > 0 {
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
        ledger.canonicalSessions = true
        ledger.appliedDaily = nil
        ledger.sessionDays = [:]
        let source = SyncCoordinateSource(generation: book.generation, epub: book.files[.epub])
        if ledger.coordinateSource != source {
            ledger.bookmarkProjection = nil
            ledger.highlightProjection = nil
        }
        ledger.coordinateVersion = 1
        ledger.coordinateSource = source
        ledger.canonicalCharacterCount = book.characterCount
        ledger.canonicalBookmark = book.deleted ? nil : book.bookmark
        if !stored {
            let sessions = StatisticsStorage.load(root: root, resetMinutes: Self.resetMinutes)
            if book.sessions != sessions {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try StatisticsStorage.save(book.sessions, root: root, resetMinutes: Self.resetMinutes)
                booksChanged = true
            }
        }

        var bookmarkChanged = false
        if !book.deleted {
            ledger.highlights = book.highlights
            let coordinates = try coordinateMap(root: root, metadata: metadata, record: record)
            bookmarkChanged = try applyCoordinateProjection(&ledger, root: root, record: record, coordinates: coordinates)
            booksChanged = booksChanged || bookmarkChanged

            // Apply before notifying an open Reader so its player reloads the incoming position.
            // Keep the remote timestamp even when the local playback value already matches.
            if let change = book.audiobook {
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
        let stored = SyncBookLedger.load(root: archive).sessions.isEmpty
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
            ledger.canonicalBookmark = nil
            ledger.bookmarkProjection = nil
            ledger.highlightProjection = nil
            ledger.coordinateSource = nil
            ledger.legacyNativeHighlights = nil
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
            var ledger = SyncBookLedger.load(root: root)
            let sessions = try canonicalSessions(root: root, ledger: &ledger, now: Date.now.syncMilliseconds)
            // The ledger is a sync snapshot; unsynced activity and tombstones live in the session store.
            if !sessions.isEmpty {
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
        var archived = SyncBookLedger.load(root: destination)
        let localSessions = try canonicalSessions(root: root, ledger: &ledger, now: Date.now.syncMilliseconds)
        let archivedSessions = try canonicalSessions(root: destination, ledger: &archived, now: Date.now.syncMilliseconds)
        ledger.sessions = SyncBook.mergeRecords(localSessions, archivedSessions)
        ledger.canonicalSessions = true
        ledger.appliedDaily = nil
        ledger.sessionDays = [:]
        ledger.highlights = nil
        ledger.shelves = nil
        ledger.audiobook = nil
        ledger.canonicalBookmark = nil
        ledger.bookmarkProjection = nil
        ledger.highlightProjection = nil
        ledger.coordinateSource = nil
        ledger.legacyNativeHighlights = nil
        try ledger.save(root: destination)

        try StatisticsStorage.save(ledger.sessions, root: destination, resetMinutes: Self.resetMinutes)

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
        guard archive.standardizedFileURL != root.standardizedFileURL,
              FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)) else { return }
        var archived = SyncBookLedger.load(root: archive)
        var ledger = SyncBookLedger.load(root: root)
        let localSessions = try canonicalSessions(root: root, ledger: &ledger, now: Date.now.syncMilliseconds)
        let archivedSessions = try canonicalSessions(root: archive, ledger: &archived, now: Date.now.syncMilliseconds)
        ledger.sessions = SyncBook.mergeRecords(localSessions, archivedSessions)
        ledger.canonicalSessions = true
        ledger.appliedDaily = nil
        ledger.sessionDays = [:]
        try StatisticsStorage.save(ledger.sessions, root: root, resetMinutes: Self.resetMinutes)
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
            StatisticsStorage.sessionsFileName,
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
