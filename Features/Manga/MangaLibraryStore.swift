import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum MangaLibraryStoreError: LocalizedError {
    case sourceNotFound
    case sourceUnavailable(String)
    case unsupportedSource
    case noReadablePages
    case invalidCoverImage

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            String(localized: "Manga source not found.")
        case .sourceUnavailable(let path):
            "\(String(localized: "Manga source is no longer available.")) \(path)"
        case .unsupportedSource:
            String(localized: "Choose a folder, CBZ, ZIP, or EPUB file.")
        case .noReadablePages:
            String(localized: "The selected folder or archive does not contain readable manga pages.")
        case .invalidCoverImage:
            String(localized: "The selected manga page could not be used as a cover.")
        }
    }
}

actor MangaLibraryStore {
    static let shared = MangaLibraryStore()
    static let didChangeNotification = Notification.Name("MangaLibraryDidChange")

    private var catalog: MangaLibraryCatalog
    private let fileURL: URL
    private let coverDirectory: URL
    private let fileManager: FileManager

    init(
        fileURL: URL? = nil,
        coverDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultCatalogURL(fileManager: fileManager)
        self.coverDirectory = coverDirectory ?? Self.defaultCoverDirectory(fileManager: fileManager)
        catalog = Self.loadCatalog(from: self.fileURL)
    }

    func snapshot() -> MangaLibraryCatalog {
        catalog
    }

    func splitMergedMokuroSourcesIfNeeded() {
        let sourceIDs = catalog.sources.compactMap { source -> UUID? in
            let hasLegacyMergedItem: Bool
            switch source.kind {
            case .archive:
                guard MangaMediaTypes.containerKind(
                    for: URL(fileURLWithPath: source.path)
                ) == .zipArchive,
                      catalog.items.contains(where: {
                          $0.sourceID == source.id && $0.relativePath.isEmpty
                      }),
                      let root = try? resolveSourceURL(source) else {
                    return nil
                }
                let accessing = root.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        root.stopAccessingSecurityScopedResource()
                    }
                }
                hasLegacyMergedItem =
                    (try? MangaPageLoader.mokuroArchiveBooks(at: root).isEmpty) == false
            case .mokuroFolder:
                hasLegacyMergedItem = catalog.items.contains {
                    $0.sourceID == source.id && $0.relativePath == "."
                }
            case .folder, .imageFolder:
                hasLegacyMergedItem = false
            }
            return hasLegacyMergedItem ? source.id : nil
        }
        for sourceID in sourceIDs {
            try? scanSource(id: sourceID)
        }
    }

    @discardableResult
    func addSource(url: URL) throws -> MangaLibrarySource {
        let standardized = url.standardizedFileURL
        let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let kind: MangaLibrarySourceKind
        if values.isDirectory == true {
            let directPages = try MangaPageLoader.inspectPages(
                at: standardized,
                kind: .directory
            )
            if !directPages.isEmpty {
                kind = MangaPageLoader.hasMokuroMetadata(
                    at: standardized,
                    kind: .directory
                ) ? .mokuroFolder : .imageFolder
            } else if try !MangaPageLoader.mokuroDirectoryURLs(at: standardized).isEmpty {
                kind = .mokuroFolder
            } else {
                throw MangaLibraryStoreError.noReadablePages
            }
        } else if values.isRegularFile == true, MangaMediaTypes.isArchive(standardized) {
            kind = .archive
        } else {
            throw MangaLibraryStoreError.unsupportedSource
        }

        let accessing = standardized.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                standardized.stopAccessingSecurityScopedResource()
            }
        }
        if kind == .archive,
           MangaMediaTypes.containerKind(for: standardized) == .zipArchive {
            let containsMokuroBooks =
                (try? MangaPageLoader.mokuroArchiveBooks(at: standardized).isEmpty) == false
            if !containsMokuroBooks {
                guard let pages = try? MangaPageLoader.inspectPages(
                    at: standardized,
                    kind: .zipArchive
                ), !pages.isEmpty else {
                    throw MangaLibraryStoreError.noReadablePages
                }
            }
        }
        let bookmark = try standardized.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        if let existingIndex = catalog.sources.firstIndex(where: {
            $0.path == standardized.path
        }) {
            let existingID = catalog.sources[existingIndex].id
            catalog.sources[existingIndex].name =
                standardized.deletingPathExtension().lastPathComponent
            catalog.sources[existingIndex].path = standardized.path
            catalog.sources[existingIndex].bookmark = bookmark
            catalog.sources[existingIndex].kind = kind
            catalog.sources[existingIndex].lastError = nil
            let restoredIDs = Set(
                catalog.items
                    .filter { $0.sourceID == existingID }
                    .map(\.id)
            )
            catalog.hiddenItemIDs.subtract(restoredIDs)
            normalizeOrganization()
            saveAndNotify()
            return catalog.sources[existingIndex]
        }

        let source = MangaLibrarySource(
            name: standardized.deletingPathExtension().lastPathComponent,
            path: standardized.path,
            bookmark: bookmark,
            kind: kind
        )
        catalog.sources.append(source)
        sortCatalog()
        save()
        return source
    }

    func removeSource(id: UUID) {
        let removedItemIDs = Set(
            catalog.items
                .filter { $0.sourceID == id }
                .map(\.id)
        )
        let removedCoverPaths = catalog.items
            .filter { $0.sourceID == id }
            .compactMap(\.coverCachePath)
        catalog.sources.removeAll { $0.id == id }
        catalog.items.removeAll { $0.sourceID == id }
        catalog.hiddenItemIDs.subtract(removedItemIDs)
        for index in catalog.shelves.indices {
            catalog.shelves[index].itemIDs.removeAll { removedItemIDs.contains($0) }
        }
        catalog.manualItemOrder.removeAll { removedItemIDs.contains($0) }
        for path in removedCoverPaths {
            guard let coverURL = managedCoverURL(for: path) else { continue }
            try? fileManager.removeItem(at: coverURL)
        }
        normalizeOrganization()
        saveAndNotify()
    }

    func scanAllSources() throws {
        var firstError: Error?
        for source in catalog.sources {
            do {
                try scanSource(id: source.id)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    func scanSource(id: UUID, now: Date = Date()) throws {
        guard let sourceIndex = catalog.sources.firstIndex(where: { $0.id == id }) else {
            throw MangaLibraryStoreError.sourceNotFound
        }
        let source = catalog.sources[sourceIndex]
        do {
            let root = try resolveSourceURL(source)
            let accessing = root.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    root.stopAccessingSecurityScopedResource()
                }
            }
            guard fileManager.fileExists(atPath: root.path) else {
                throw MangaLibraryStoreError.sourceUnavailable(root.path)
            }
            let previousItems = Dictionary(
                uniqueKeysWithValues: catalog.items
                    .filter { $0.sourceID == source.id }
                    .map { ($0.id, $0) }
            )
            let scannedItems = try scanItems(
                source: source,
                root: root,
                previousItems: previousItems,
                now: now
            )
            catalog.items.removeAll { $0.sourceID == source.id }
            catalog.items.append(contentsOf: scannedItems)
            catalog.sources[sourceIndex].path = root.path
            catalog.sources[sourceIndex].name = root.deletingPathExtension().lastPathComponent
            catalog.sources[sourceIndex].lastScannedAt = now
            catalog.sources[sourceIndex].lastError = nil
            sortCatalog()
            normalizeOrganization()
            saveAndNotify()
        } catch {
            catalog.sources[sourceIndex].lastError = error.localizedDescription
            saveAndNotify()
            throw error
        }
    }

    func updateProgress(
        itemID: String,
        pageIndex: Int,
        updatedAt: Date = Date()
    ) {
        guard let index = catalog.items.firstIndex(where: { $0.id == itemID }) else { return }
        if let lastReadAt = catalog.items[index].lastReadAt,
           lastReadAt > updatedAt {
            return
        }
        let clamped = min(max(0, pageIndex), max(0, catalog.items[index].pageCount - 1))
        guard catalog.items[index].currentPageIndex != clamped else { return }
        catalog.items[index].currentPageIndex = clamped
        catalog.items[index].lastReadAt = updatedAt
        saveAndNotify()
    }

    func recordOpened(itemID: String, now: Date = Date()) {
        guard let index = catalog.items.firstIndex(where: { $0.id == itemID }) else { return }
        catalog.items[index].lastReadAt = now
        saveAndNotify()
    }

    func setCover(itemID: String, imageData: Data) throws {
        guard let index = catalog.items.firstIndex(where: { $0.id == itemID }) else {
            throw MangaLibraryStoreError.sourceNotFound
        }
        let destination = coverDirectory.appendingPathComponent(
            "custom-\(Self.fnv1a64(itemID)).jpg"
        )
        guard try writeCover(imageData: imageData, to: destination) else {
            throw MangaLibraryStoreError.invalidCoverImage
        }
        catalog.items[index].coverCachePath = destination.path
        saveAndNotify()
    }

    func createShelf(name: String, id: UUID = UUID()) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !catalog.shelves.contains(where: {
                  $0.id == id || $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
              }) else {
            return
        }
        catalog.shelves.append(MangaShelf(id: id, name: trimmed))
        saveAndNotify()
    }

    func renameShelf(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = catalog.shelves.firstIndex(where: { $0.id == id }),
              !catalog.shelves.contains(where: {
                  $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
              }) else {
            return
        }
        catalog.shelves[index].name = trimmed
        saveAndNotify()
    }

    func deleteShelf(id: UUID) {
        guard let index = catalog.shelves.firstIndex(where: { $0.id == id }) else { return }
        let releasedIDs = catalog.shelves[index].itemIDs
        catalog.shelves.remove(at: index)
        appendMissingIDs(releasedIDs, to: &catalog.manualItemOrder)
        normalizeOrganization()
        saveAndNotify()
    }

    func moveShelves(from source: IndexSet, to destination: Int) {
        catalog.shelves.move(fromOffsets: source, toOffset: destination)
        saveAndNotify()
    }

    func moveItems(_ itemIDs: Set<String>, to shelfID: UUID?) {
        guard !itemIDs.isEmpty else { return }
        for index in catalog.shelves.indices {
            catalog.shelves[index].itemIDs.removeAll { itemIDs.contains($0) }
        }
        catalog.manualItemOrder.removeAll { itemIDs.contains($0) }
        if let shelfID,
           let index = catalog.shelves.firstIndex(where: { $0.id == shelfID }) {
            appendMissingIDs(
                catalog.items.map(\.id).filter { itemIDs.contains($0) },
                to: &catalog.shelves[index].itemIDs
            )
        } else {
            appendMissingIDs(
                catalog.items.map(\.id).filter { itemIDs.contains($0) },
                to: &catalog.manualItemOrder
            )
        }
        normalizeOrganization()
        saveAndNotify()
    }

    func reorderItem(
        _ sourceID: String,
        shelfID: UUID?,
        before targetID: String
    ) {
        if let shelfID,
           let index = catalog.shelves.firstIndex(where: { $0.id == shelfID }) {
            reorder(&catalog.shelves[index].itemIDs, sourceID: sourceID, targetID: targetID)
        } else {
            reorder(&catalog.manualItemOrder, sourceID: sourceID, targetID: targetID)
        }
        saveAndNotify()
    }

    func renameItem(id: String, title: String) {
        guard let index = catalog.items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        catalog.items[index].renamedTitle = trimmed.isEmpty ? nil : trimmed
        saveAndNotify()
    }

    func markRead(itemID: String) {
        guard let index = catalog.items.firstIndex(where: { $0.id == itemID }) else { return }
        catalog.items[index].currentPageIndex = max(0, catalog.items[index].pageCount - 1)
        catalog.items[index].lastReadAt = Date()
        saveAndNotify()
    }

    func removeItemsFromLibrary(_ itemIDs: Set<String>) {
        let existingIDs = Set(catalog.items.map(\.id))
        let removedIDs = itemIDs.intersection(existingIDs)
        guard !removedIDs.isEmpty else { return }
        catalog.hiddenItemIDs.formUnion(removedIDs)
        for index in catalog.shelves.indices {
            catalog.shelves[index].itemIDs.removeAll { removedIDs.contains($0) }
        }
        catalog.manualItemOrder.removeAll { removedIDs.contains($0) }
        normalizeOrganization()
        saveAndNotify()
    }

    private func scanItems(
        source: MangaLibrarySource,
        root: URL,
        previousItems: [String: MangaLibraryItem],
        now: Date
    ) throws -> [MangaLibraryItem] {
        switch source.kind {
        case .archive:
            guard let kind = MangaMediaTypes.containerKind(for: root) else {
                throw MangaLibraryStoreError.unsupportedSource
            }
            if kind == .zipArchive {
                let books = try MangaPageLoader.mokuroArchiveBooks(at: root)
                if !books.isEmpty {
                    let legacyPrevious = previousItems["\(source.id.uuidString)|"]
                    var previousFallbacks: [String: MangaLibraryItem] = [:]
                    if books.count == 1, let legacyPrevious {
                        previousFallbacks[books[0].metadataPath] = legacyPrevious
                    } else if let legacyPrevious {
                        let mergedPages = try MangaPageLoader.inspectPages(
                            at: root,
                            kind: .zipArchive
                        )
                        if mergedPages.indices.contains(legacyPrevious.currentPageIndex) {
                            let currentPath = mergedPages[legacyPrevious.currentPageIndex].path
                            if let book = books.first(where: {
                                $0.imagePaths.contains(currentPath)
                            }), let pageIndex = book.imagePaths.firstIndex(of: currentPath) {
                                var migratedPrevious = legacyPrevious
                                migratedPrevious.currentPageIndex = pageIndex
                                previousFallbacks[book.metadataPath] = migratedPrevious
                            }
                        }
                    }
                    return try books.compactMap { book in
                        let pages = book.imagePaths.enumerated().map {
                            MangaPageDescriptor(index: $0.offset, path: $0.element)
                        }
                        return try makeItem(
                            source: source,
                            root: root,
                            itemURL: root,
                            relativePath: book.metadataPath,
                            kind: kind,
                            previousItems: previousItems,
                            now: now,
                            preinspectedPages: pages,
                            titleOverride: book.title,
                            previousFallback: previousFallbacks[book.metadataPath]
                        )
                    }
                }
            }
            return try makeItem(
                source: source,
                root: root,
                itemURL: root,
                relativePath: "",
                kind: kind,
                previousItems: previousItems,
                now: now
            ).map { [$0] } ?? []
        case .mokuroFolder:
            let candidates = try MangaPageLoader.mokuroDirectoryURLs(at: root)
            guard !candidates.isEmpty else {
                throw MangaLibraryStoreError.noReadablePages
            }
            let legacyPrevious = previousItems["\(source.id.uuidString)|."]
            return try candidates.compactMap { candidate in
                try makeItem(
                    source: source,
                    root: root,
                    itemURL: candidate,
                    relativePath: Self.relativePath(of: candidate, from: root),
                    kind: .directory,
                    previousItems: previousItems,
                    now: now,
                    previousFallback: candidates.count == 1 ? legacyPrevious : nil
                )
            }
        case .imageFolder:
            return try makeItem(
                source: source,
                root: root,
                itemURL: root,
                relativePath: ".",
                kind: .directory,
                previousItems: previousItems,
                now: now
            ).map { [$0] } ?? []
        case .folder:
            var candidates: [(url: URL, relativePath: String, kind: MangaContainerKind)] = []
            if try containsImages(in: root) {
                candidates.append((root, ".", .directory))
            }

            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isRegularFileKey, .isHiddenKey,
                .isPackageKey, .contentModificationDateKey,
            ]
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw MangaLibraryStoreError.sourceUnavailable(root.path)
            }
            for case let candidate as URL in enumerator {
                try Task.checkCancellation()
                let values = try candidate.resourceValues(forKeys: keys)
                if values.isHidden == true || values.isPackage == true {
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let relativePath = Self.relativePath(of: candidate, from: root)
                if values.isRegularFile == true,
                   let kind = MangaMediaTypes.containerKind(for: candidate) {
                    candidates.append((candidate, relativePath, kind))
                } else if values.isDirectory == true, try containsImages(in: candidate) {
                    candidates.append((candidate, relativePath, .directory))
                    enumerator.skipDescendants()
                }
            }

            return try candidates.compactMap { candidate in
                try Task.checkCancellation()
                return try makeItem(
                    source: source,
                    root: root,
                    itemURL: candidate.url,
                    relativePath: candidate.relativePath,
                    kind: candidate.kind,
                    previousItems: previousItems,
                    now: now
                )
            }
        }
    }

    private func makeItem(
        source: MangaLibrarySource,
        root: URL,
        itemURL: URL,
        relativePath: String,
        kind: MangaContainerKind,
        previousItems: [String: MangaLibraryItem],
        now: Date,
        preinspectedPages: [MangaPageDescriptor]? = nil,
        titleOverride: String? = nil,
        previousFallback: MangaLibraryItem? = nil
    ) throws -> MangaLibraryItem? {
        let pages = try preinspectedPages ?? MangaPageLoader.inspectPages(
            at: itemURL,
            kind: kind
        )
        guard !pages.isEmpty else { return nil }
        let id = "\(source.id.uuidString)|\(relativePath)"
        let previous = previousItems[id] ?? previousFallback
        let modifiedAt = try? itemURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        let previousCustomCoverPath = previous?.coverCachePath.flatMap { path -> String? in
            guard let url = managedCoverURL(for: path) else { return nil }
            guard url.lastPathComponent.hasPrefix("custom-"),
                  fileManager.fileExists(atPath: url.path) else {
                return nil
            }
            return url.path
        }
        let archiveMetadataPath = kind == .zipArchive && !relativePath.isEmpty
            ? relativePath
            : nil
        let coverCachePath = try previousCustomCoverPath ?? cacheCover(
            itemID: id,
            modifiedAt: modifiedAt,
            itemURL: itemURL,
            kind: kind,
            firstPagePath: pages.first?.path,
            archiveMetadataPath: archiveMetadataPath
        )?.path
        let rawTitle = titleOverride ?? (
            relativePath == "." || relativePath.isEmpty
                ? root.deletingPathExtension().lastPathComponent
                : itemURL.deletingPathExtension().lastPathComponent
        )
        return MangaLibraryItem(
            id: id,
            sourceID: source.id,
            relativePath: relativePath,
            title: rawTitle,
            renamedTitle: previous?.renamedTitle,
            containerKind: kind,
            pageCount: pages.count,
            modifiedAt: modifiedAt,
            coverCachePath: coverCachePath,
            currentPageIndex: min(
                previous?.currentPageIndex ?? 0,
                max(0, pages.count - 1)
            ),
            lastReadAt: previous?.lastReadAt
        )
    }

    private func containsImages(in directory: URL) throws -> Bool {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).contains { candidate in
            let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true && MangaMediaTypes.isImage(candidate)
        }
    }

    private func cacheCover(
        itemID: String,
        modifiedAt: Date?,
        itemURL: URL,
        kind: MangaContainerKind,
        firstPagePath: String? = nil,
        archiveMetadataPath: String? = nil
    ) throws -> URL? {
        let key = Self.fnv1a64("\(itemID)|\(modifiedAt?.timeIntervalSince1970 ?? 0)")
        let destination = coverDirectory.appendingPathComponent("\(key).jpg")
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }
        guard let data = try MangaPageLoader.coverData(
            at: itemURL,
            kind: kind,
            firstPagePath: firstPagePath,
            archiveMetadataPath: archiveMetadataPath
        ),
              try writeCover(imageData: data, to: destination) else {
            return nil
        }
        return destination
    }

    private func writeCover(imageData: Data, to destination: URL) throws -> Bool {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                ] as CFDictionary
              ) else {
            return false
        }
        try fileManager.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
        guard let destinationWriter = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return false
        }
        CGImageDestinationAddImage(
            destinationWriter,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        return CGImageDestinationFinalize(destinationWriter)
    }

    private func resolveSourceURL(_ source: MangaLibrarySource) throws -> URL {
        var isStale = false
        return try URL(
            resolvingBookmarkData: source.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL
    }

    private func managedCoverURL(for path: String) -> URL? {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let root = coverDirectory.standardizedFileURL
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return candidate
    }

    private func sortCatalog() {
        catalog.sources.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        catalog.items.sort {
            let title = $0.title.localizedStandardCompare($1.title)
            return title == .orderedSame
                ? $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                : title == .orderedAscending
        }
    }

    private func normalizeOrganization() {
        let allIDs = Set(catalog.items.map(\.id))
        catalog.hiddenItemIDs.formIntersection(allIDs)
        let visibleIDs = allIDs.subtracting(catalog.hiddenItemIDs)
        var assignedIDs = Set<String>()

        for index in catalog.shelves.indices {
            let normalized = normalizedOrder(
                catalog.shelves[index].itemIDs,
                validIDs: visibleIDs.subtracting(assignedIDs)
            )
            catalog.shelves[index].itemIDs = normalized
            assignedIDs.formUnion(normalized)
        }

        let unshelvedIDs = visibleIDs.subtracting(assignedIDs)
        catalog.manualItemOrder = normalizedOrder(
            catalog.manualItemOrder,
            validIDs: unshelvedIDs,
            fallbackIDs: catalog.items.map(\.id)
        )
    }

    private func normalizedOrder(
        _ order: [String],
        validIDs: Set<String>,
        fallbackIDs: [String] = []
    ) -> [String] {
        var seen = Set<String>()
        var result = order.filter { validIDs.contains($0) && seen.insert($0).inserted }
        appendMissingIDs(fallbackIDs.filter { validIDs.contains($0) }, to: &result)
        return result
    }

    private func appendMissingIDs(_ ids: [String], to order: inout [String]) {
        var seen = Set(order)
        order.append(contentsOf: ids.filter { seen.insert($0).inserted })
    }

    private func reorder(
        _ order: inout [String],
        sourceID: String,
        targetID: String
    ) {
        guard let sourceIndex = order.firstIndex(of: sourceID),
              let targetIndex = order.firstIndex(of: targetID),
              sourceIndex != targetIndex else {
            return
        }
        let destination = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        order.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destination)
    }

    private func saveAndNotify() {
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func save() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(catalog).write(to: fileURL, options: .atomic)
        } catch {
            // The manga library is a rebuildable index. Reading must remain available.
        }
    }

    private static func loadCatalog(from url: URL) -> MangaLibraryCatalog {
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(MangaLibraryCatalog.self, from: data) else {
            return .empty
        }
        return catalog
    }

    private static func defaultCatalogURL(fileManager: FileManager) -> URL {
        if let override = ProcessInfo.processInfo.environment["HOSHI_MANGA_LIBRARY_CATALOG_URL"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return directory.appendingPathComponent("manga_library.json")
    }

    private static func defaultCoverDirectory(fileManager: FileManager) -> URL {
        let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return directory.appendingPathComponent("MangaCovers", isDirectory: true)
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        return url.standardizedFileURL.pathComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")
    }

    private static func fnv1a64(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
