//
//  FushiProgressCoordinator.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import OSLog

private let fushiSyncLogger = Logger(subsystem: "moe.shishamo.hoshi", category: "FushiInterconnect")

/// Where a progress sync was started from. It decides whether a conflict may
/// interrupt the user right away.
enum FushiSyncTrigger: Equatable {
    /// The Reader is opening the book; nothing has been read yet, so a conflict is
    /// asked about inside the Reader.
    case readerOpen
    /// Debounced export while reading. Never interrupts and never moves the
    /// position under the open Reader; conflicts wait for the book to close.
    case readerActivity
    /// The Reader closed; deferred conflicts surface on the bookshelf.
    case readerClose
    /// App launch sweep; conflicts surface on the bookshelf unless postponed.
    case launch
    /// The user asked for this sync, so a conflict is always shown, even one
    /// postponed earlier.
    case manual(presentOnBookshelf: Bool)
}

/// Both sides moved away from the last agreed position (or there is no agreed
/// position yet); the user picks which one to keep.
struct FushiProgressConflict: Identifiable, Equatable {
    let id: String
    let book: BookMetadata
    let bookKey: String
    let hostName: String
    let local: Bookmark
    let remote: FushiRemoteProgress
    /// The Fushi position in Niratan coordinates, when this copy of the book has
    /// the section.
    let remoteAsLocal: Bookmark?
    let totalCharacters: Int

    static func == (lhs: FushiProgressConflict, rhs: FushiProgressConflict) -> Bool {
        lhs.id == rhs.id
    }
}

enum FushiConflictChoice {
    case keepLocal
    case useFushi
}

enum FushiBookSyncOutcome: Equatable {
    case unavailable
    case notOnHost
    case unchanged
    case pulled
    case pushed
    case conflict(FushiProgressConflict)
    case failed(String)
}

struct FushiSyncAllReport: Equatable {
    var matched = 0
    var pulled = 0
    var pushed = 0
    var conflicts = 0
    var failed = 0
    var lastError: String?
}

/// Novel reading-progress sync with a paired Fushi host, with Fushi's conflict
/// rules: one-sided changes sync silently, divergent positions are never
/// overwritten silently, and prompts never interrupt reading.
@Observable
final class FushiProgressCoordinator {
    static let shared = FushiProgressCoordinator()

    /// Conflicts waiting for a decision, newest per book.
    private(set) var pendingConflicts: [FushiProgressConflict] = []
    /// Set when a conflict should be asked about on the bookshelf.
    var bookshelfPromptRequested = false
    private(set) var isSyncingAll = false
    private(set) var lastReport: FushiSyncAllReport?
    private(set) var lastError: String?

    /// Conflicts the user postponed this session; automatic syncs do not ask about
    /// the same versions again until they change or the app restarts.
    private var postponed: Set<String> = []
    /// The sync currently running per book. Syncs of one book run one after another
    /// so a Reader opening during the launch sweep still gets its own answer.
    private var inFlight: [UUID: Task<FushiBookSyncOutcome, Never>] = [:]
    private var remoteBooks: (hostKey: String, fetched: Date, keys: Set<String>)?
    private var sectionCache: [String: (modified: Date?, sections: FushiSectionTable)] = [:]
    private var didRunLaunchSync = false

    private let store = FushiInterconnectStore.shared
    private let baselines = FushiProgressBaselineStore.shared

    private init() {}

    var isAutoSyncActive: Bool {
        store.isPaired && store.autoSyncProgress
    }

    /// Books whose conflict an open Reader is asking about right now.
    private var readerPromptBookIDs: Set<UUID> = []

    /// Conflicts to show on the main window right now. A conflict an open Reader
    /// is already asking about is left to that Reader, so it is never asked twice.
    var bookshelfConflicts: [FushiProgressConflict] {
        pendingConflicts.filter { !postponed.contains($0.id) && !readerPromptBookIDs.contains($0.book.id) }
    }

    func beginReaderPrompt(for bookID: UUID) {
        readerPromptBookIDs.insert(bookID)
    }

    func endReaderPrompt(for bookID: UUID) {
        readerPromptBookIDs.remove(bookID)
    }

    func pendingConflict(for bookID: UUID) -> FushiProgressConflict? {
        pendingConflicts.first { $0.book.id == bookID }
    }

    // MARK: - Sync

    func syncBook(_ book: BookMetadata, trigger: FushiSyncTrigger) async -> FushiBookSyncOutcome {
        guard let client = await store.makeClient(), let hostKey = store.baselineHostKey else {
            return .unavailable
        }
        let previous = inFlight[book.id]
        let task = Task {
            _ = await previous?.value
            return await runSync(book, trigger: trigger, client: client, hostKey: hostKey)
        }
        inFlight[book.id] = task
        let outcome = await task.value
        if inFlight[book.id] == task {
            inFlight[book.id] = nil
        }
        return outcome
    }

    private func runSync(
        _ book: BookMetadata,
        trigger: FushiSyncTrigger,
        client: FushiInterconnectClient,
        hostKey: String
    ) async -> FushiBookSyncOutcome {
        do {
            guard let bookKey = try await remoteBookKey(for: book, client: client, hostKey: hostKey, refresh: trigger.isManual) else {
                return .notOnHost
            }
            let context = try await loadContext(book: book, bookKey: bookKey, client: client, hostKey: hostKey)
            let action = FushiProgressResolver.resolve(
                local: context.local,
                remote: context.remote,
                remoteAsLocal: context.remoteAsLocal,
                localAsRemote: context.localAsRemote,
                base: context.base
            )
            lastError = nil
            return try await perform(action, context: context, client: client, trigger: trigger)
        } catch {
            let message = error.localizedDescription
            fushiSyncLogger.error("fushi.sync.failed book=\(book.folder, privacy: .public) error=\(message, privacy: .public)")
            if trigger.isManual {
                lastError = message
            }
            return .failed(message)
        }
    }

    /// Syncs every local novel the host also has.
    @discardableResult
    func syncAll(books: [BookMetadata], trigger: FushiSyncTrigger) async -> FushiSyncAllReport {
        guard store.isPaired, !isSyncingAll else { return lastReport ?? FushiSyncAllReport() }
        isSyncingAll = true
        defer { isSyncingAll = false }
        remoteBooks = nil

        var report = FushiSyncAllReport()
        for book in books {
            switch await syncBook(book, trigger: trigger) {
            case .unavailable, .notOnHost:
                continue
            case .unchanged:
                report.matched += 1
            case .pulled:
                report.matched += 1
                report.pulled += 1
            case .pushed:
                report.matched += 1
                report.pushed += 1
            case .conflict:
                report.matched += 1
                report.conflicts += 1
            case .failed(let message):
                report.failed += 1
                report.lastError = message
            }
        }
        lastReport = report
        if report.pulled > 0 {
            NotificationCenter.default.post(name: .readerWindowProgressDidChange, object: nil)
        }
        return report
    }

    /// One automatic sweep per launch, before the user opens anything. It runs in its
    /// own task: a bookshelf reload must not cancel the requests halfway.
    func syncAllOnLaunchIfNeeded(books: [BookMetadata]) {
        guard !didRunLaunchSync, isAutoSyncActive, !books.isEmpty else { return }
        didRunLaunchSync = true
        Task {
            await syncAll(books: books, trigger: .launch)
        }
    }

    // MARK: - Conflicts

    func resolve(_ conflict: FushiProgressConflict, choice: FushiConflictChoice) async throws {
        guard let client = await store.makeClient(), let hostKey = store.baselineHostKey else {
            throw FushiInterconnectError.unauthorized
        }
        let context = try await loadContext(book: conflict.book, bookKey: conflict.bookKey, client: client, hostKey: hostKey)
        switch choice {
        case .keepLocal:
            guard let local = context.local, let position = context.localAsRemote else {
                throw FushiInterconnectError.invalidResponse
            }
            try await push(local: local, position: position, context: context, client: client)
        case .useFushi:
            // Prefer what the host holds now; fall back to the position the user saw.
            let remote = context.remote.isEmpty ? conflict.remote : context.remote
            guard let bookmark = FushiProgressMapping.bookmark(for: remote, bookInfo: context.bookInfo, sections: context.sections) else {
                throw FushiInterconnectError.invalidResponse
            }
            try apply(bookmark: bookmark, remote: remote, context: context)
        }
        removeConflict(for: conflict.book.id)
        postponed.remove(conflict.id)
        NotificationCenter.default.post(name: .readerWindowProgressDidChange, object: conflict.book)
    }

    /// "Decide later": automatic syncs stop asking about these versions this session.
    func postpone(_ conflicts: [FushiProgressConflict]) {
        for conflict in conflicts {
            postponed.insert(conflict.id)
        }
    }

    func isPostponed(_ conflict: FushiProgressConflict) -> Bool {
        postponed.contains(conflict.id)
    }

    func forgetHost() {
        pendingConflicts.removeAll()
        postponed.removeAll()
        readerPromptBookIDs.removeAll()
        bookshelfPromptRequested = false
        remoteBooks = nil
        lastReport = nil
        lastError = nil
    }

    // MARK: - Steps

    private struct Context {
        let book: BookMetadata
        let bookKey: String
        let hostKey: String
        let root: URL
        let bookInfo: BookInfo
        let sections: FushiSectionTable
        let local: Bookmark?
        let remote: FushiRemoteProgress
        let remoteAsLocal: Bookmark?
        let localAsRemote: (sectionIndex: Int, normCharOffset: Int)?
        let base: FushiProgressBaseline?
    }

    private func perform(
        _ action: FushiProgressAction,
        context: Context,
        client: FushiInterconnectClient,
        trigger: FushiSyncTrigger
    ) async throws -> FushiBookSyncOutcome {
        switch action {
        case .synced:
            if let local = context.local, !context.remote.isEmpty {
                baselines.setBaseline(FushiProgressBaseline(remote: context.remote, local: local), hostKey: context.hostKey, bookKey: context.bookKey)
            }
            removeConflict(for: context.book.id)
            return .unchanged
        case .pushLocal:
            guard let local = context.local, let position = context.localAsRemote else {
                return .unchanged
            }
            try await push(local: local, position: position, context: context, client: client)
            removeConflict(for: context.book.id)
            return .pushed
        case .applyRemote:
            // Moving the position under an open Reader would be overwritten by its
            // next save and would jump the page mid-sentence.
            guard trigger != .readerActivity else { return .unchanged }
            guard let bookmark = context.remoteAsLocal else {
                throw FushiInterconnectError.invalidResponse
            }
            try apply(bookmark: bookmark, remote: context.remote, context: context)
            removeConflict(for: context.book.id)
            return .pulled
        case .conflict:
            guard let local = context.local else { return .unchanged }
            let conflict = FushiProgressConflict(
                id: Self.conflictID(bookKey: context.bookKey, local: local, remote: context.remote),
                book: context.book,
                bookKey: context.bookKey,
                hostName: store.displayName,
                local: local,
                remote: context.remote,
                remoteAsLocal: context.remoteAsLocal,
                totalCharacters: context.bookInfo.characterCount
            )
            record(conflict, trigger: trigger)
            if trigger == .readerOpen && postponed.contains(conflict.id) {
                return .unchanged
            }
            fushiSyncLogger.notice("fushi.sync.conflict book=\(context.book.folder, privacy: .public)")
            return .conflict(conflict)
        }
    }

    private func record(_ conflict: FushiProgressConflict, trigger: FushiSyncTrigger) {
        removeConflict(for: conflict.book.id)
        pendingConflicts.append(conflict)
        switch trigger {
        case .readerOpen, .readerActivity:
            break
        case .readerClose, .launch:
            if !postponed.contains(conflict.id) {
                bookshelfPromptRequested = true
            }
        case .manual(let presentOnBookshelf):
            postponed.remove(conflict.id)
            if presentOnBookshelf {
                bookshelfPromptRequested = true
            }
        }
    }

    private func removeConflict(for bookID: UUID) {
        pendingConflicts.removeAll { $0.book.id == bookID }
        if pendingConflicts.isEmpty {
            bookshelfPromptRequested = false
        }
    }

    private func push(
        local: Bookmark,
        position: (sectionIndex: Int, normCharOffset: Int),
        context: Context,
        client: FushiInterconnectClient
    ) async throws {
        let progress = FushiRemoteProgress(
            sectionIndex: position.sectionIndex,
            normCharOffset: position.normCharOffset,
            charOffset: -1,
            updatedAtMs: FushiProgressResolver.pushTimestamp(local: local, remote: context.remote)
        )
        try await client.putProgress(progress, bookKey: context.bookKey)
        baselines.setBaseline(FushiProgressBaseline(remote: progress, local: local), hostKey: context.hostKey, bookKey: context.bookKey)
        fushiSyncLogger.notice("fushi.sync.push book=\(context.book.folder, privacy: .public) section=\(progress.sectionIndex, privacy: .public) norm=\(progress.normCharOffset, privacy: .public)")
    }

    private func apply(bookmark: Bookmark, remote: FushiRemoteProgress, context: Context) throws {
        try BookStorage.save(bookmark, inside: context.root, as: FileNames.bookmark)
        baselines.setBaseline(FushiProgressBaseline(remote: remote, local: bookmark), hostKey: context.hostKey, bookKey: context.bookKey)
        fushiSyncLogger.notice("fushi.sync.pull book=\(context.book.folder, privacy: .public) chapter=\(bookmark.chapterIndex, privacy: .public) character=\(bookmark.characterCount, privacy: .public)")
    }

    private func loadContext(
        book: BookMetadata,
        bookKey: String,
        client: FushiInterconnectClient,
        hostKey: String
    ) async throws -> Context {
        let root = try BookStorage.getBooksDirectory().appendingPathComponent(book.folder)
        guard let bookInfo = BookStorage.loadBookInfo(root: root) else {
            throw FushiInterconnectError.invalidResponse
        }
        let sections = try await sectionTable(book: book, root: root)
        guard !sections.isEmpty else {
            throw FushiInterconnectError.invalidResponse
        }
        let remote = try await client.progress(bookKey: bookKey)
        let local = BookStorage.loadBookmark(root: root)
        return Context(
            book: book,
            bookKey: bookKey,
            hostKey: hostKey,
            root: root,
            bookInfo: bookInfo,
            sections: sections,
            local: local,
            remote: remote,
            remoteAsLocal: remote.isEmpty ? nil : FushiProgressMapping.bookmark(for: remote, bookInfo: bookInfo, sections: sections),
            localAsRemote: local.flatMap { FushiProgressMapping.remotePosition(for: $0, bookInfo: bookInfo, sections: sections) },
            base: baselines.baseline(hostKey: hostKey, bookKey: bookKey)
        )
    }

    private func remoteBookKey(
        for book: BookMetadata,
        client: FushiInterconnectClient,
        hostKey: String,
        refresh: Bool
    ) async throws -> String? {
        let candidates = [book.title, book.displayTitle].map(TtuSyncNaming.sanitize)
        func match(_ keys: Set<String>) -> String? {
            candidates.first { keys.contains($0) }
        }
        if !refresh,
           let cached = remoteBooks,
           cached.hostKey == hostKey,
           Date().timeIntervalSince(cached.fetched) < 300,
           let key = match(cached.keys) {
            return key
        }
        let keys = Set(try await client.books().filter(\.isNovel).map(\.key))
        remoteBooks = (hostKey, Date(), keys)
        return match(keys)
    }

    private func sectionTable(book: BookMetadata, root: URL) async throws -> FushiSectionTable {
        guard let epubURL = Self.epubURL(for: book, root: root) else {
            throw FushiEPUBSpineReaderError.missingPackage
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: epubURL.path(percentEncoded: false)))?[.modificationDate] as? Date
        if let cached = sectionCache[book.folder], cached.modified == modified {
            return cached.sections
        }
        let indices = try await Task.detached(priority: .utility) {
            try FushiEPUBSpineReader.sectionSpineIndices(epubURL: epubURL)
        }.value
        let table = FushiSectionTable(spineIndices: indices)
        sectionCache[book.folder] = (modified, table)
        return table
    }

    /// The stored EPUB, resolved the same way the Reader does.
    static func epubURL(for book: BookMetadata, root: URL) -> URL? {
        let fileManager = FileManager.default
        if let epub = book.epub ?? BookStorage.loadMetadata(root: root)?.epub {
            let url = root.appendingPathComponent(epub)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
        }
        let inferred = root.appendingPathComponent(root.lastPathComponent).appendingPathExtension("epub")
        if fileManager.fileExists(atPath: inferred.path(percentEncoded: false)) {
            return inferred
        }
        if let candidates = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
           let epub = candidates.first(where: { $0.pathExtension.lowercased() == "epub" }) {
            return epub
        }
        if fileManager.fileExists(atPath: root.appendingPathComponent("META-INF/container.xml").path(percentEncoded: false)) {
            return root
        }
        return nil
    }

    static func conflictID(bookKey: String, local: Bookmark, remote: FushiRemoteProgress) -> String {
        "\(bookKey)|\(local.chapterIndex):\(local.characterCount)|\(remote.sectionIndex):\(remote.normCharOffset):\(remote.updatedAtMs)"
    }
}

private extension FushiSyncTrigger {
    var isManual: Bool {
        if case .manual = self { return true }
        return false
    }
}
