//
//  GoogleDriveSyncManager+Files.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import EPUBKit
import ZIPFoundation

extension GoogleDriveSyncManager {
    func runFileSync() async throws -> Bool {
        let keys = store.state.books.keys.sorted()
        beginTransfers(keys)
        let listing = progress == nil ? DriveListing() : try await listFiles()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, key) in keys.enumerated() {
                if index >= 8 {
                    try await group.next()
                }
                group.addTask {
                    try await self.transferFiles(key, listing: listing)
                }
            }
            try await group.waitForAll()
        }
        try saveCache()
        return listing.published
    }

    private func transferFiles(_ key: String, listing: DriveListing) async throws {
        try Task.checkCancellation()
        guard store.state.books[key] != nil else { return }
        progress?.current.insert(key)
        try await recordBook(key, phase: .file) {
            try await syncFiles(key: key, listing: listing)
        }
        finishTransfer(key)
    }

    private func syncFiles(key: String, listing: DriveListing) async throws {
        var failure: Error?
        for fileType in SyncFileType.allCases {
            try Task.checkCancellation()
            do {
                try await uploadFile(key: key, fileType: fileType, listing: listing)
                if fileType != .epub {
                    try await downloadFile(key: key, fileType: fileType, listing: listing)
                }
            } catch {
                failure = failure ?? error
            }
        }

        do {
            try await cleanupFiles(key: key, listing: listing)
        } catch {
            failure = failure ?? error
        }
        if let failure {
            throw failure
        }
    }

    private func transferDirection(_ record: SyncRecord) -> Direction? {
        let fileTypes = SyncFileType.allCases.filter { !record.deleted || $0 == .cover }
        let upload = record.attached && fileTypes.contains { fileType in
            guard let source = record.sources[fileType] else { return false }
            return (record.files[fileType]?.modified ?? .min) < source
        }
        let download = fileTypes.contains { fileType in
            guard fileType != .epub, let published = record.files[fileType] else { return false }
            return (record.sources[fileType] ?? .min) < published.modified
        }
        switch (upload, download) {
        case (true, true):
            return .both
        case (true, false):
            return .upload
        case (false, true):
            return .download
        case (false, false):
            return nil
        }
    }

    private func beginTransfers(_ keys: [String]) {
        transfers = keys.compactMap { key in
            guard let record = store.state.books[key] else { return nil }
            return transferDirection(record).map {
                QueueItem(key: key, title: bookTitle(key, deleted: record.deleted), direction: $0)
            }
        }
        progress = transfers.isEmpty ? nil : Progress(done: 0, total: transfers.count)
    }

    private func finishTransfer(_ key: String) {
        progress?.current.remove(key)
        guard transfers.contains(where: { $0.key == key }) else { return }
        progress?.done += 1
        if bookErrors[BookErrorKey(key: key, phase: .file)] == nil {
            transfers.removeAll { $0.key == key }
        }
    }

    /// Downloads the EPUB of a book that only exists on Drive so it can be opened.
    func downloadBook(_ book: BookMetadata, onProgress: @MainActor @Sendable @escaping (Double) -> Void) async throws -> BookMetadata {
        let key = SyncStorage.key(book.folder)
        await sync(book: book)
        if unsupportedFormat {
            throw SyncFormatError.unsupportedVersion
        }
        if let errorMessage = errorMessage ?? bookErrors[BookErrorKey(key: key, phase: .state)]?.message {
            throw GoogleDriveError.apiError(errorMessage, statusCode: nil)
        }
        try Task.checkCancellation()

        let requestedSource = store.state.books[key].map {
            SyncCoordinateSource(generation: $0.generation, epub: $0.files[.epub])
        }
        let root = try BookStorage.getBooksDirectory().appendingPathComponent(book.folder)
        if store.state.books[key]?.deleted == true {
            throw GoogleDriveError.apiError(String(localized: "This book was deleted."), statusCode: nil)
        }
        if enabled, store.state.books[key]?.files[.epub]?.value != nil {
            try await downloadFile(key: key, fileType: .epub, listing: DriveListing(), onProgress: onProgress)
        }
        try Task.checkCancellation()
        guard let current = store.state.books[key], !current.deleted,
              SyncCoordinateSource(generation: current.generation, epub: current.files[.epub]) == requestedSource,
              !store.needsEPUBDownload(key: key) else { throw CancellationError() }

        let metadata = BookStorage.loadMetadata(root: root) ?? book
        guard let epub = metadata.epub else {
            throw GoogleDriveError.apiError(String(localized: "This book has not been uploaded yet."), statusCode: nil)
        }
        if BookStorage.loadBookInfo(root: root) == nil {
            try BookStorage.save(indexDownloadedEPUB(root.appendingPathComponent(epub)), inside: root, as: FileNames.bookinfo)
        }
        try store.applyPendingCoordinates(key: key)
        return metadata
    }

    /// Validate downloaded media before replacement, without removing an open
    /// Reader's extraction directory or changing any existing sidecar.
    private func indexDownloadedEPUB(_ epubURL: URL) throws -> BookInfo {
        let extraction = FileManager.default.temporaryDirectory
            .appendingPathComponent("niratan-downloaded-epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extraction) }
        try FileManager.default.unzipItem(at: epubURL, to: extraction)
        let document = try EPUBParser().parse(documentAt: extraction)
        let extractionPath = extraction.resolvingSymlinksInPath().path + "/"
        guard !document.spine.items.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        for item in document.spine.items {
            guard let manifest = document.manifest.items[item.idref] else { throw CocoaError(.fileReadCorruptFile) }
            let chapter = document.contentDirectory.appendingPathComponent(manifest.path)
            guard chapter.resolvingSymlinksInPath().path.hasPrefix(extractionPath),
                  (try? String(contentsOf: chapter, encoding: .utf8)) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let info = BookProcessor.process(document: document)
        for (index, item) in document.spine.items.enumerated() {
            guard let manifest = document.manifest.items[item.idref],
                  info.chapterInfo[manifest.path]?.spineIndex == index else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return info
    }

    private func uploadFile(key: String, fileType: SyncFileType, listing: DriveListing) async throws {
        guard let record = store.state.books[key] else { return }
        if !record.attached || (record.deleted && fileType != .cover) {
            return
        }
        guard let source = record.sources[fileType] else { return }
        if let published = record.files[fileType], published.modified >= source {
            return
        }

        guard let url = try store.sourceURL(key: key, fileType: fileType) else {
            store.state.books[key]!.files[fileType] = Timestamped(modified: source, value: nil)
            store.state.books[key]!.pending = true
            listing.published = true
            try store.saveChanges(booksChanged: false)
            return
        }

        let fileName = url.lastPathComponent.precomposedStringWithCanonicalMapping
        let name = fileType == .sasayaki ? "\(source)-\(fileName)" : fileName
        if !canPublish(key: key, fileType: fileType, source: source, generation: record.generation) {
            return
        }
        try await upload(listing, key: key, generation: record.generation, name: name, file: url)
        try Task.checkCancellation()
        if !canPublish(key: key, fileType: fileType, source: source, generation: record.generation) {
            return
        }

        if fileType == .sasayaki, let published = store.state.books[key]!.files[.sasayaki]?.value, published != name {
            store.state.books[key]!.cleanup.insert(record.generation)
        }
        store.state.books[key]!.files[fileType] = Timestamped(modified: source, value: name)
        store.state.books[key]!.pending = true
        listing.published = true
        try store.saveChanges(booksChanged: false)
    }

    private func canPublish(key: String, fileType: SyncFileType, source: Int64, generation: Int) -> Bool {
        guard let record = store.state.books[key] else { return false }
        return record.generation == generation && record.sources[fileType] == source
            && (!record.deleted || fileType == .cover)
            && (record.files[fileType]?.modified ?? .min) <= source
    }

    private func downloadFile(
        key: String,
        fileType: SyncFileType,
        listing: DriveListing,
        onProgress: @MainActor @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        guard let record = store.state.books[key] else { return }
        if record.deleted && fileType != .cover {
            return
        }
        guard let reference = record.files[fileType] else { return }
        if let source = record.sources[fileType], source >= reference.modified {
            guard fileType == .epub else { return }
            guard try store.sourceURL(key: key, fileType: .epub) == nil else { return }
        }

        let root = try SyncStorage.bookDirectory(folder: key, archived: record.deleted)
        guard let name = reference.value else {
            try applyDownloadedFile(key: key, fileType: fileType, path: nil, reference: reference)
            return
        }
        if record.deleted, SyncBookLedger.load(root: root).sessions.values.allSatisfy({ $0.value == nil }) {
            return
        }

        guard let file = try await findFile(listing, key: key, generation: record.generation, name: name) else {
            throw GoogleDriveError.apiError(String(localized: "\(name) is missing from Google Drive."), statusCode: 404)
        }
        let data = try await drive.download(file, onProgress: onProgress)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        try await Task.detached {
            try data.write(to: temporary)
        }.value
        try Task.checkCancellation()

        guard let current = store.state.books[key],
              current.generation == record.generation, current.deleted == record.deleted, current.files[fileType] == reference else {
            return
        }
        if let source = current.sources[fileType], source >= reference.modified {
            guard fileType == .epub else { return }
            guard try store.sourceURL(key: key, fileType: .epub) == nil else { return }
        }

        // A malformed download must leave the old EPUB, index and source
        // timestamp intact so reopening can retry the pending reference.
        let downloadedInfo = fileType == .epub ? try indexDownloadedEPUB(temporary) : nil
        try Task.checkCancellation()

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileName = fileType == .sasayaki ? FileNames.sasayakiMatch : name
        let destination = root.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        let relative = "Books/" + (record.deleted ? "\(SyncStorage.archiveFolder)/" : "") + root.lastPathComponent + "/" + fileName
        try applyDownloadedFile(key: key, fileType: fileType, path: relative, reference: reference)
        if let downloadedInfo {
            try BookStorage.save(downloadedInfo, inside: root, as: FileNames.bookinfo)
        }
    }

    private func applyDownloadedFile(key: String, fileType: SyncFileType, path: String?, reference: Timestamped<String?>) throws {
        guard let record = store.state.books[key] else { return }
        let root = try SyncStorage.bookDirectory(folder: key, archived: record.deleted)

        if fileType == .epub, path != nil, record.sources[.epub] != reference.modified {
            // The open model owns the old extracted document. Close that session
            // before rebuilding its index and applying positions from the new EPUB.
            SyncReaderBridge.model(for: key)?.closeForSyncedDeletion()
        }

        if let existing = BookStorage.loadMetadata(root: root), fileType != .sasayaki {
            let oldPath: URL? = fileType == .epub ? existing.epub.map { root.appendingPathComponent($0) } : existing.coverURL
            let appDirectory = try BookStorage.getAppDirectory()
            let newPath = path.map { appDirectory.appendingPathComponent($0) }
            if let oldPath, oldPath.standardizedFileURL != newPath?.standardizedFileURL {
                try BookStorage.delete(at: oldPath)
            }

            var metadata = existing
            if fileType == .epub {
                metadata.epub = path.map { URL(fileURLWithPath: $0).lastPathComponent }
            }
            if fileType == .cover {
                metadata.cover = path
            }
            try BookStorage.save(metadata, inside: root, as: FileNames.metadata)
        }
        if fileType == .sasayaki && path == nil {
            try BookStorage.delete(at: root.appendingPathComponent(FileNames.sasayakiMatch))
        }

        store.state.books[key]!.sources[fileType] = reference.modified
        store.state.books[key]!.observed[fileType] = try store.sourceURL(key: key, fileType: fileType).flatMap(SyncStorage.modificationDate)
        try store.save()
        if fileType != .sasayaki {
            NotificationCenter.default.post(name: SyncStorage.booksChangedNotification, object: nil)
        } else {
            SyncReaderBridge.model(for: key)?.reloadSyncedSasayakiMatch()
        }
    }

    private func cleanupFiles(key: String, listing: DriveListing) async throws {
        guard let cleanup = store.state.books[key]?.cleanup else { return }
        for generation in cleanup {
            if store.state.books[key]?.pending != false {
                return
            }

            let files = try await drive.children(parent: cache.stateFolder, name: key + ".json")
            let remote = try await readState(files, merge: SyncBook.merge)
            try mergeBook(key, remote: remote)

            guard let book = try store.loadBook(key: key, remote: remote) else {
                return
            }
            if book.needsUpload(remote: remote) {
                store.state.books[key]!.pending = true
                try store.saveChanges(booksChanged: false)
                return
            }

            let folder = try await folder(listing, key: key, generation: generation)
            var recent = false
            if let folder, generation < book.generation {
                try await GoogleDriveClient.shared.trashFile(fileId: folder)
                forgetFolder(listing, key: key, generation: generation)
                try Task.checkCancellation()
            } else if let folder {
                let files = try await drive.children(parent: folder)
                for file in files where !file.isFolder && file.name != book.files[.cover]?.value {
                    guard let current = store.state.books[key] else { return }
                    let stale = file.name.hasSuffix(FileNames.sasayakiMatch) && file.name != current.files[.sasayaki]?.value
                    if !current.deleted && !stale {
                        continue
                    }
                    // Another device may still be about to reference a file uploaded today.
                    if file.isRecent {
                        recent = true
                        continue
                    }
                    try await drive.trash(file)
                    try Task.checkCancellation()
                }
            }
            if recent {
                continue
            }
            store.state.books[key]?.cleanup.remove(generation)
            try store.save()
        }
    }
}
