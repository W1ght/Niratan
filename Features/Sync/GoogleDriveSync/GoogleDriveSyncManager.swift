//
//  GoogleDriveSyncManager.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network

/// Whole-library Google Drive sync with Hoshi Reader (the "Google Drive" provider).
///
/// Drive layout: `Hoshi Reader/state/<book>.json` holds one `SyncBook` per book,
/// `Hoshi Reader/state/.shelves.json` the shelf list, and `Hoshi Reader/books/<book>/<generation>/`
/// the EPUB, cover and Sasayaki match. Sync is last-edit-wins per field; statistics and
/// highlights merge by id and deletion wins. It polls every two minutes while the app is
/// active and 30 seconds after a local change.
@MainActor
@Observable
final class GoogleDriveSyncManager {
    enum Phase: Comparable {
        case state
        case file
    }

    enum Direction {
        case upload
        case download
        case both
    }

    struct QueueItem: Identifiable {
        var key: String
        var title: String
        var direction: Direction?
        var error: String?

        var id: String { key }
    }

    struct Progress {
        var done: Int
        var total: Int
        var current: Set<String> = []
    }

    struct BookErrorKey: Hashable {
        var key: String
        var phase: Phase
    }

    struct BookError {
        var title: String
        var message: String
    }

    static let shared = GoogleDriveSyncManager()
    static let pollInterval: Duration = .seconds(120)
    static let changeDelay: Duration = .seconds(30)

    var errorMessage: String?
    var lastSync: Date?
    @ObservationIgnored let store = SyncStorage.shared
    @ObservationIgnored let drive = GoogleDriveSyncHandler.shared
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored var cache = GoogleDriveSyncCache()
    @ObservationIgnored var remoteBooks: [String: (versions: [String: String], book: SyncBook)] = [:]

    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var fileTransferTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored var downloadTask: Task<Void, Never>?
    private var stopped = false
    /// Set while a backup restore rewrites the library; nothing may restart sync meanwhile.
    private var suspendedForRestore = false
    private(set) var isSyncing = false
    var unsupportedFormat = false
    var transfers: [QueueItem] = []
    var progress: Progress?
    var bookErrors: [BookErrorKey: BookError] = [:]

    var queue: [QueueItem] {
        var queue = transfers
        for (id, error) in bookErrors.sorted(by: { ($0.key.key, $0.key.phase) < ($1.key.key, $1.key.phase) }) {
            if let index = queue.firstIndex(where: { $0.key == id.key }) {
                queue[index].error = queue[index].error ?? error.message
            } else {
                queue.append(QueueItem(key: id.key, title: error.title, direction: nil, error: error.message))
            }
        }
        return queue
    }

    /// Settings live in `UserConfig`, which persists them to the standard defaults.
    static var isSelectedProvider: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "enableSync")
            && SyncProvider(rawValue: defaults.string(forKey: "syncProvider") ?? "") == .gdrive
    }

    var enabled: Bool {
        Self.isSelectedProvider && GoogleDriveAuth.shared.isAuthenticated(for: .gdrive) && !stopped && !suspendedForRestore
    }

    func suspendForRestore() async {
        suspendedForRestore = true
        await stop()
    }

    func resumeAfterRestore() {
        suspendedForRestore = false
        start()
    }

    private init() {
        cache = (try? cacheURL()).flatMap { try? SyncFormat.decode(GoogleDriveSyncCache.self, from: Data(contentsOf: $0)) } ?? GoogleDriveSyncCache()
        store.onChange = { [weak self] in
            self?.schedule()
        }

        pathMonitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                let manager = GoogleDriveSyncManager.shared
                guard manager.pollTask != nil else { return }
                await manager.sync()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "GoogleDriveSyncManager.network"))
    }

    // MARK: - Lifecycle

    func start() {
        GoogleDriveClient.shared.resume()
        stopped = false
        pollTask?.cancel()
        pollTask = nil

        guard enabled else { return }
        pollTask = Task {
            await sync()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    return
                }
                await sync()
            }
        }
    }

    /// Starts polling when the app becomes active, unless it already runs.
    func resumeIfNeeded() {
        guard pollTask == nil else { return }
        start()
    }

    /// Stops polling after one final sync; used when the app resigns active.
    func pause() async {
        pollTask?.cancel()
        pollTask = nil
        await sync()
    }

    func stop() async {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        stateTask?.cancel()
        fileTransferTask?.cancel()
        downloadTask?.cancel()

        await GoogleDriveClient.shared.stop()
        await stateTask?.value
        await fileTransferTask?.value
        await downloadTask?.value

        stateTask = nil
        fileTransferTask = nil
        downloadTask = nil
        isSyncing = false
        transfers = []
        progress = nil
        bookErrors = [:]
    }

    /// Library state always belongs to one account, so signing out resets it for both providers.
    func signOut() async throws {
        await stop()
        try resetConnection()
        GoogleDriveAuth.shared.signOut()
        GoogleDriveHandler.clearCache()
    }

    func clearCache() async throws {
        await stop()
        try prepareSharedLibrary()
        // Keep the root so a replaced or trashed library folder is still detected.
        cache = GoogleDriveSyncCache(root: cache.root)
        remoteBooks = [:]
        try saveCache()
        start()
    }

    /// Forgets everything known about the remote library, e.g. after connecting another
    /// account. Remote-only placeholders are removed; local books are uploaded again.
    func resetConnection() throws {
        // Credentials may already belong to a new account. Forget remote IDs before any
        // fallible local work, and retain the reattachment flag until that work succeeds.
        cache = GoogleDriveSyncCache(requiresReattachment: true)
        remoteBooks = [:]
        unsupportedFormat = false
        errorMessage = nil
        lastSync = nil
        try saveCache()
        try store.prepareLibrary()
        try store.removePlaceholders()
        try store.resetSyncState()
        cache = GoogleDriveSyncCache()
        try saveCache()
    }

    /// Switching from the old Niratan library invalidates only its local remote references.
    /// The old cloud folder and all local books/sidecars remain available; local records are
    /// reconciled into the shared library with their original edit timestamps.
    func prepareSharedLibrary() throws {
        guard cache.libraryName != GoogleDriveSyncCache.sharedLibraryName
            || store.state.libraryName != GoogleDriveSyncCache.sharedLibraryName
            || cache.requiresReattachment == true else { return }
        try store.prepareLibrary()
        try store.resetSyncState()
        cache.selectSharedLibrary(force: true)
        remoteBooks = [:]
        try saveCache()
    }

    /// Requests a sync soon after a local change.
    func schedule() {
        guard enabled else { return }
        guard stateTask == nil, debounceTask == nil else { return }
        debounceTask = Task {
            try? await Task.sleep(for: Self.changeDelay)
            guard !Task.isCancelled else { return }
            debounceTask = nil
            await sync()
        }
    }

    // MARK: - Running

    func sync(book: BookMetadata? = nil) async {
        guard enabled else { return }
        let previous = stateTask
        if book == nil, let previous {
            await previous.value
            return
        }

        debounceTask?.cancel()
        debounceTask = nil
        let previousFileTransfers = book == nil ? nil : fileTransferTask
        if book != nil {
            previous?.cancel()
            previousFileTransfers?.cancel()
        }

        let task = Task {
            await previous?.value
            await previousFileTransfers?.value

            do {
                try await runSync(book: book)
            } catch {
                if !Task.isCancelled {
                    failRun(error)
                    fileTransferTask?.cancel()
                }
            }
        }

        stateTask = task
        updateSyncing()
        await task.value

        if !task.isCancelled {
            stateTask = nil
            updateSyncing()

            if book != nil || (errorMessage == nil
                && !bookErrors.keys.contains(where: { $0.phase == .state })
                && (store.state.books.values.contains(where: { $0.pending }) || store.state.shelvesPending)) {
                schedule()
            }
            if book == nil {
                startFileSync()
            }
        }
    }

    func startFileSync() {
        guard enabled, !unsupportedFormat, errorMessage == nil, stateTask == nil, fileTransferTask == nil,
              downloadTask == nil, !cache.bookFolder.isEmpty else { return }
        fileTransferTask = Task {
            defer {
                fileTransferTask = nil
                progress = nil
                updateSyncing()
            }
            do {
                if try await runFileSync(), !Task.isCancelled {
                    Task {
                        await sync()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    failRun(error)
                }
            }
        }
        updateSyncing()
    }

    private func updateSyncing() {
        isSyncing = stateTask != nil || fileTransferTask != nil
    }

    func recordBook(_ key: String, phase: Phase, _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            bookErrors[BookErrorKey(key: key, phase: phase)] = nil
        } catch {
            if Task.isCancelled || stopsRun(error) {
                throw error
            }
            let deleted = store.state.books[key]?.deleted ?? false
            bookErrors[BookErrorKey(key: key, phase: phase)] = BookError(title: bookTitle(key, deleted: deleted), message: error.localizedDescription)
        }
    }

    private func stopsRun(_ error: Error) -> Bool {
        if case GoogleDriveError.unavailable = error {
            return true
        }
        return error is SyncFormatError || error is CancellationError || error is GoogleDriveAuthError
            || (error as? URLError)?.code == .cancelled
    }

    private func failRun(_ error: Error) {
        errorMessage = error.localizedDescription
        if error is SyncFormatError {
            unsupportedFormat = true
        }
    }

    func bookTitle(_ key: String, deleted: Bool) -> String {
        (try? SyncStorage.bookDirectory(folder: key, archived: deleted)).flatMap { BookStorage.loadMetadata(root: $0) }?.displayTitle ?? key
    }

    private func cacheURL() throws -> URL {
        try BookStorage.getAppDirectory().appendingPathComponent("drive-sync.json")
    }

    func saveCache() throws {
        try SyncFormat.encode(cache).write(to: cacheURL(), options: .atomic)
    }
}
