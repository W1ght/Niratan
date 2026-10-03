import Foundation

struct VideoLibrarySource: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var path: String
    var bookmark: Data
    var lastScannedAt: Date?
    var lastError: String?

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        bookmark: Data,
        lastScannedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.lastScannedAt = lastScannedAt
        self.lastError = lastError
    }
}

nonisolated struct VideoLibraryItem: Codable, Equatable, Identifiable, Sendable {
    var id: String { mediaIdentity.persistenceKey }

    let path: String
    let sourceID: UUID
    let title: String
    let parentFolder: String
    let fileSize: Int64
    let modifiedAt: Date?
    let lastSeenAt: Date
    let mediaIdentity: VideoMediaIdentity

    init(
        path: String,
        sourceID: UUID,
        title: String,
        parentFolder: String,
        fileSize: Int64,
        modifiedAt: Date?,
        lastSeenAt: Date,
        mediaIdentity: VideoMediaIdentity? = nil
    ) {
        self.path = path
        self.sourceID = sourceID
        self.title = title
        self.parentFolder = parentFolder
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.lastSeenAt = lastSeenAt
        self.mediaIdentity = mediaIdentity ?? .localFile(path: path)
    }

    var localURL: URL? {
        mediaIdentity.localURL
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case sourceID
        case title
        case parentFolder
        case fileSize
        case modifiedAt
        case lastSeenAt
        case mediaIdentity
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        sourceID = try container.decode(UUID.self, forKey: .sourceID)
        title = try container.decode(String.self, forKey: .title)
        parentFolder = try container.decode(String.self, forKey: .parentFolder)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        mediaIdentity = try container.decodeIfPresent(
            VideoMediaIdentity.self,
            forKey: .mediaIdentity
        ) ?? .localFile(path: path)
    }
}

nonisolated enum VideoLibraryRemoteSource {
    static let id = UUID(uuidString: "00000000-0000-0000-0000-00000000A11D")!
}

nonisolated struct RemoteVideoLibraryItem: Codable, Equatable, Identifiable, Sendable {
    var id: String { identity.stableLibraryID }

    let identity: RemoteVideoIdentity
    var subtitleLanguage: String?
    var hasResolvedSubtitleMetadata: Bool
    let addedAt: Date
    var lastResolvedAt: Date

    var providerID: String { identity.providerID }
    var originalURL: URL { identity.originalURL }
    var thumbnailURL: URL? { identity.thumbnailURL }

    init(
        resolvedSource: ResolvedRemoteVideoSource,
        addedAt: Date? = nil
    ) {
        self.identity = resolvedSource.identity
        self.subtitleLanguage = resolvedSource.selectedSubtitleLanguage
        self.hasResolvedSubtitleMetadata = true
        self.addedAt = addedAt ?? resolvedSource.resolvedAt
        self.lastResolvedAt = resolvedSource.resolvedAt
    }

    var libraryItem: VideoLibraryItem {
        VideoLibraryItem(
            path: id,
            sourceID: VideoLibraryRemoteSource.id,
            title: identity.title,
            parentFolder: identity.isMediaServer
                ? identity.provider?.displayName ?? String(localized: "Media Server")
                : String(localized: "YouTube Video"),
            fileSize: 0,
            modifiedAt: lastResolvedAt,
            lastSeenAt: addedAt,
            mediaIdentity: identity.mediaIdentity
        )
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case subtitleLanguage
        case hasResolvedSubtitleMetadata
        case addedAt
        case lastResolvedAt
        case resolvedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(RemoteVideoIdentity.self, forKey: .identity)
        subtitleLanguage = try container.decodeIfPresent(String.self, forKey: .subtitleLanguage)
        hasResolvedSubtitleMetadata = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasResolvedSubtitleMetadata
        ) ?? (subtitleLanguage != nil)
        let legacyResolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt)
            ?? legacyResolvedAt
            ?? .distantPast
        lastResolvedAt = try container.decodeIfPresent(Date.self, forKey: .lastResolvedAt)
            ?? legacyResolvedAt
            ?? addedAt
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identity, forKey: .identity)
        try container.encodeIfPresent(subtitleLanguage, forKey: .subtitleLanguage)
        try container.encode(hasResolvedSubtitleMetadata, forKey: .hasResolvedSubtitleMetadata)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(lastResolvedAt, forKey: .lastResolvedAt)
    }
}

struct VideoLibraryItemMetadata: Codable, Equatable {
    var displayTitle: String?
    var isFavorite: Bool
    var tags: [String]
    var collectionIDs: [UUID]
    var boundSubtitlePath: String?

    init(
        displayTitle: String? = nil,
        isFavorite: Bool = false,
        tags: [String] = [],
        collectionIDs: [UUID] = [],
        boundSubtitlePath: String? = nil
    ) {
        self.displayTitle = displayTitle
        self.isFavorite = isFavorite
        self.tags = tags
        self.collectionIDs = collectionIDs
        self.boundSubtitlePath = boundSubtitlePath
    }
}

enum VideoLibraryCollectionKind: String, Codable, Equatable {
    case manual
    case smart
}

enum VideoLibrarySmartRuleField: String, Codable, CaseIterable, Equatable {
    case fileName
    case parentFolder
    case path
    case tag
    case hasBoundSubtitle
    case playbackState
}

enum VideoLibrarySmartRuleMatch: String, Codable, CaseIterable, Equatable {
    case contains
    case equals
    case isTrue
}

struct VideoLibrarySmartRule: Codable, Equatable, Identifiable {
    let id: UUID
    var field: VideoLibrarySmartRuleField
    var match: VideoLibrarySmartRuleMatch
    var value: String

    init(
        id: UUID = UUID(),
        field: VideoLibrarySmartRuleField,
        match: VideoLibrarySmartRuleMatch,
        value: String = ""
    ) {
        self.id = id
        self.field = field
        self.match = match
        self.value = value
    }
}

struct VideoLibraryCollection: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var kind: VideoLibraryCollectionKind
    var itemPaths: [String]
    var smartRules: [VideoLibrarySmartRule]

    init(
        id: UUID = UUID(),
        name: String,
        kind: VideoLibraryCollectionKind = .manual,
        itemPaths: [String] = [],
        smartRules: [VideoLibrarySmartRule] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.itemPaths = itemPaths
        self.smartRules = smartRules
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case itemPaths
        case smartRules
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(VideoLibraryCollectionKind.self, forKey: .kind) ?? .manual
        itemPaths = try container.decodeIfPresent([String].self, forKey: .itemPaths) ?? []
        smartRules = try container.decodeIfPresent([VideoLibrarySmartRule].self, forKey: .smartRules) ?? []
    }
}

struct VideoLibraryCatalog: Codable, Equatable {
    var sources: [VideoLibrarySource]
    var items: [VideoLibraryItem]
    var remoteItems: [RemoteVideoLibraryItem]
    var itemMetadataByPath: [String: VideoLibraryItemMetadata]
    var collections: [VideoLibraryCollection]

    static let empty = VideoLibraryCatalog(
        sources: [],
        items: [],
        remoteItems: [],
        itemMetadataByPath: [:],
        collections: []
    )

    init(
        sources: [VideoLibrarySource],
        items: [VideoLibraryItem],
        remoteItems: [RemoteVideoLibraryItem] = [],
        itemMetadataByPath: [String: VideoLibraryItemMetadata] = [:],
        collections: [VideoLibraryCollection] = []
    ) {
        self.sources = sources
        self.items = items
        self.remoteItems = remoteItems
        self.itemMetadataByPath = itemMetadataByPath
        self.collections = collections
    }

    private enum CodingKeys: String, CodingKey {
        case sources
        case items
        case remoteItems
        case itemMetadataByPath
        case collections
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decode([VideoLibrarySource].self, forKey: .sources)
        items = try container.decode([VideoLibraryItem].self, forKey: .items)
        remoteItems = try container.decodeIfPresent(
            [RemoteVideoLibraryItem].self,
            forKey: .remoteItems
        ) ?? []
        itemMetadataByPath = try container.decodeIfPresent(
            [String: VideoLibraryItemMetadata].self,
            forKey: .itemMetadataByPath
        ) ?? [:]
        collections = try container.decodeIfPresent(
            [VideoLibraryCollection].self,
            forKey: .collections
        ) ?? []
    }
}

enum VideoLibraryStoreError: LocalizedError {
    case sourceNotFound
    case sourceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            String(localized: "Video folder not found.")
        case .sourceUnavailable(let path):
            "\(String(localized: "Video folder is no longer available.")) \(path)"
        }
    }
}

final class VideoLibraryStore {
    @MainActor static let shared = VideoLibraryStore()
    nonisolated static let remoteSourceID = VideoLibraryRemoteSource.id
    nonisolated static let remoteItemDidResolveNotification = Notification.Name(
        "VideoLibraryStore.remoteItemDidResolve"
    )

    private(set) var catalog: VideoLibraryCatalog

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.fileManager = fileManager
        self.catalog = Self.loadCatalog(from: self.fileURL)
    }

    @discardableResult
    func addSource(folderURL: URL) throws -> VideoLibrarySource {
        let standardized = folderURL.standardizedFileURL
        if let existing = catalog.sources.first(where: { $0.path == standardized.path }) {
            return existing
        }

        let accessing = standardized.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                standardized.stopAccessingSecurityScopedResource()
            }
        }

        let bookmark = try standardized.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let source = VideoLibrarySource(
            name: standardized.lastPathComponent,
            path: standardized.path,
            bookmark: bookmark
        )
        catalog.sources.append(source)
        catalog.sources.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        save()
        return source
    }

    func removeSource(id: UUID) {
        let removedPaths = Set(catalog.items.filter { $0.sourceID == id }.map(\.path))
        catalog.sources.removeAll { $0.id == id }
        catalog.items.removeAll { $0.sourceID == id }
        removeMetadataAndCollectionReferences(for: removedPaths)
        save()
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
        guard let index = catalog.sources.firstIndex(where: { $0.id == id }) else {
            throw VideoLibraryStoreError.sourceNotFound
        }

        let source = catalog.sources[index]
        do {
            let root = try resolveSourceURL(source)
            let scannedItems = try scanItems(source: source, root: root, now: now)
            let scannedPaths = Set(scannedItems.map(\.path))
            let oldSourcePaths = Set(catalog.items.filter { $0.sourceID == source.id }.map(\.path))
            catalog.items.removeAll {
                $0.sourceID == source.id || scannedPaths.contains($0.path)
            }
            catalog.items.append(contentsOf: scannedItems)
            catalog.items.sort(by: Self.itemSort)
            removeMetadataAndCollectionReferences(for: oldSourcePaths.subtracting(scannedPaths))
            catalog.sources[index].path = root.standardizedFileURL.path
            catalog.sources[index].name = root.lastPathComponent
            catalog.sources[index].lastScannedAt = now
            catalog.sources[index].lastError = nil
            save()
        } catch {
            catalog.sources[index].lastError = error.localizedDescription
            save()
            throw error
        }
    }

    func resolvedURL(for item: VideoLibraryItem) -> URL? {
        item.localURL
    }

    func metadata(for item: VideoLibraryItem) -> VideoLibraryItemMetadata {
        metadata(forPath: item.path)
    }

    func remoteItem(for item: VideoLibraryItem) -> RemoteVideoLibraryItem? {
        catalog.remoteItems.first { $0.id == item.path }
    }

    @discardableResult
    func addRemoteItem(_ resolvedSource: ResolvedRemoteVideoSource) -> RemoteVideoLibraryItem {
        let existing = catalog.remoteItems.first {
            $0.id == resolvedSource.identity.stableLibraryID
        }
        let remoteItem = RemoteVideoLibraryItem(
            resolvedSource: resolvedSource,
            addedAt: existing?.addedAt
        )
        if let index = catalog.remoteItems.firstIndex(where: { $0.id == remoteItem.id }) {
            catalog.remoteItems[index] = remoteItem
        } else {
            catalog.remoteItems.append(remoteItem)
        }
        catalog.remoteItems.sort {
            $0.identity.title.localizedStandardCompare($1.identity.title) == .orderedAscending
        }
        save()
        NotificationCenter.default.post(
            name: Self.remoteItemDidResolveNotification,
            object: nil
        )
        return remoteItem
    }

    @discardableResult
    func removeRemoteItem(id: String) -> Bool {
        guard catalog.remoteItems.contains(where: { $0.id == id }) else { return false }
        catalog.remoteItems.removeAll { $0.id == id }
        removeMetadataAndCollectionReferences(for: [id])
        save()
        return true
    }

    func metadata(forPath path: String) -> VideoLibraryItemMetadata {
        catalog.itemMetadataByPath[path] ?? VideoLibraryItemMetadata()
    }

    func setDisplayTitle(_ title: String?, for item: VideoLibraryItem) {
        updateMetadata(for: item) { metadata in
            let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            metadata.displayTitle = cleaned?.isEmpty == true ? nil : cleaned
        }
    }

    func setFavorite(_ isFavorite: Bool, for item: VideoLibraryItem) {
        updateMetadata(for: item) { metadata in
            metadata.isFavorite = isFavorite
        }
    }

    func setTags(_ tags: [String], for item: VideoLibraryItem) {
        updateMetadata(for: item) { metadata in
            metadata.tags = Self.normalizedTags(tags)
        }
    }

    func bindSubtitle(_ subtitleURL: URL?, for item: VideoLibraryItem) {
        updateMetadata(for: item) { metadata in
            metadata.boundSubtitlePath = subtitleURL?.standardizedFileURL.path
        }
    }

    @discardableResult
    func createCollection(
        name: String,
        itemPaths: [String]
    ) -> VideoLibraryCollection {
        let collection = VideoLibraryCollection(
            name: Self.collectionName(from: name),
            kind: .manual,
            itemPaths: Self.uniqueExistingPaths(itemPaths, existing: existingItemPaths)
        )
        catalog.collections.append(collection)
        catalog.collections.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for path in collection.itemPaths {
            var metadata = metadata(forPath: path)
            if !metadata.collectionIDs.contains(collection.id) {
                metadata.collectionIDs.append(collection.id)
                catalog.itemMetadataByPath[path] = metadata
            }
        }
        save()
        return collection
    }

    @discardableResult
    func createSmartCollection(
        name: String,
        rules: [VideoLibrarySmartRule]
    ) -> VideoLibraryCollection {
        let collection = VideoLibraryCollection(
            name: Self.collectionName(from: name),
            kind: .smart,
            itemPaths: [],
            smartRules: Self.normalizedSmartRules(rules)
        )
        catalog.collections.append(collection)
        catalog.collections.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        save()
        return collection
    }

    func updateCollection(
        id: UUID,
        name: String,
        itemPaths: [String]
    ) {
        guard let index = catalog.collections.firstIndex(where: { $0.id == id }) else { return }
        let paths = Self.uniqueExistingPaths(itemPaths, existing: existingItemPaths)
        catalog.collections[index].name = Self.collectionName(from: name)
        catalog.collections[index].kind = .manual
        catalog.collections[index].itemPaths = paths
        catalog.collections[index].smartRules = []
        normalizeCollectionMembership()
        save()
    }

    func updateSmartCollection(
        id: UUID,
        name: String,
        rules: [VideoLibrarySmartRule]
    ) {
        guard let index = catalog.collections.firstIndex(where: { $0.id == id }) else { return }
        catalog.collections[index].name = Self.collectionName(from: name)
        catalog.collections[index].kind = .smart
        catalog.collections[index].itemPaths = []
        catalog.collections[index].smartRules = Self.normalizedSmartRules(rules)
        normalizeCollectionMembership()
        save()
    }

    func removeCollection(id: UUID) {
        catalog.collections.removeAll { $0.id == id }
        for path in Array(catalog.itemMetadataByPath.keys) {
            catalog.itemMetadataByPath[path]?.collectionIDs.removeAll { $0 == id }
            if catalog.itemMetadataByPath[path]?.isEmpty == true {
                catalog.itemMetadataByPath.removeValue(forKey: path)
            }
        }
        save()
    }

    @discardableResult
    func removeMissingItems(sourceID: UUID? = nil) -> Int {
        let missingPaths = Set(
            catalog.items
                .filter { item in
                    if let sourceID, item.sourceID != sourceID {
                        return false
                    }
                    return !fileManager.fileExists(atPath: item.path)
                }
                .map(\.path)
        )
        guard !missingPaths.isEmpty else { return 0 }
        catalog.items.removeAll { missingPaths.contains($0.path) }
        removeMetadataAndCollectionReferences(for: missingPaths)
        save()
        return missingPaths.count
    }

    private var existingItemPaths: Set<String> {
        Set(catalog.items.map(\.path)).union(catalog.remoteItems.map(\.id))
    }

    private func scanItems(
        source: VideoLibrarySource,
        root: URL,
        now: Date
    ) throws -> [VideoLibraryItem] {
        guard fileManager.fileExists(atPath: root.path) else {
            throw VideoLibraryStoreError.sourceUnavailable(root.path)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw VideoLibraryStoreError.sourceUnavailable(root.path)
        }

        var itemsByPath: [String: VideoLibraryItem] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: keys)
            if values.isHidden == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  VideoMediaTypes.isMediaFile(fileURL) else {
                continue
            }

            let standardized = fileURL.standardizedFileURL
            itemsByPath[standardized.path] = VideoLibraryItem(
                path: standardized.path,
                sourceID: source.id,
                title: Self.displayTitle(for: standardized),
                parentFolder: standardized.deletingLastPathComponent().lastPathComponent,
                fileSize: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate,
                lastSeenAt: now
            )
        }

        return itemsByPath.values.sorted(by: Self.itemSort)
    }

    private func resolveSourceURL(_ source: VideoLibrarySource) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: source.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL
        let accessing = url.startAccessingSecurityScopedResource()
        if !accessing, !fileManager.fileExists(atPath: url.path) {
            throw VideoLibraryStoreError.sourceUnavailable(source.path)
        }
        if accessing {
            url.stopAccessingSecurityScopedResource()
        }
        return url
    }

    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(catalog).write(to: fileURL, options: .atomic)
        } catch {
            // The video library is a convenience index; scan/open should not crash on save failures.
        }
    }

    private func updateMetadata(
        for item: VideoLibraryItem,
        mutate: (inout VideoLibraryItemMetadata) -> Void
    ) {
        var metadata = metadata(for: item)
        mutate(&metadata)
        catalog.itemMetadataByPath[item.path] = metadata.isEmpty ? nil : metadata
        save()
    }

    private func removeMetadataAndCollectionReferences(for paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for path in paths {
            catalog.itemMetadataByPath.removeValue(forKey: path)
        }
        for index in catalog.collections.indices {
            catalog.collections[index].itemPaths.removeAll { paths.contains($0) }
        }
        normalizeCollectionMembership()
    }

    private func normalizeCollectionMembership() {
        let collectionIDsByPath = Dictionary(
            grouping: catalog.collections.flatMap { collection in
                collection.itemPaths.map { path in (path, collection.id) }
            },
            by: \.0
        ).mapValues { pairs in pairs.map(\.1) }
        let existingPaths = existingItemPaths
        for path in Array(catalog.itemMetadataByPath.keys) {
            guard existingPaths.contains(path) else {
                catalog.itemMetadataByPath.removeValue(forKey: path)
                continue
            }
            catalog.itemMetadataByPath[path]?.collectionIDs = collectionIDsByPath[path] ?? []
            if catalog.itemMetadataByPath[path]?.isEmpty == true {
                catalog.itemMetadataByPath.removeValue(forKey: path)
            }
        }
        for (path, collectionIDs) in collectionIDsByPath where existingPaths.contains(path) {
            var metadata = metadata(forPath: path)
            metadata.collectionIDs = collectionIDs
            catalog.itemMetadataByPath[path] = metadata
        }
    }

    private static func loadCatalog(from fileURL: URL) -> VideoLibraryCatalog {
        guard let data = try? Data(contentsOf: fileURL),
              let catalog = try? JSONDecoder().decode(VideoLibraryCatalog.self, from: data) else {
            return .empty
        }
        return catalog
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        if let override = ProcessInfo.processInfo.environment["HOSHI_VIDEO_LIBRARY_CATALOG_URL"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: false).standardizedFileURL
        }
        let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return directory.appendingPathComponent("video_library.json")
    }

    private static func displayTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(cleaned)
        }
        return result
    }

    private static func collectionName(from name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? String(localized: "Untitled Collection") : cleaned
    }

    private static func normalizedSmartRules(_ rules: [VideoLibrarySmartRule]) -> [VideoLibrarySmartRule] {
        rules.map { rule in
            VideoLibrarySmartRule(
                id: rule.id,
                field: rule.field,
                match: rule.match,
                value: rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func uniqueExistingPaths(_ paths: [String], existing: Set<String>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths where existing.contains(path) && !seen.contains(path) {
            seen.insert(path)
            result.append(path)
        }
        return result
    }

    private static func itemSort(_ lhs: VideoLibraryItem, _ rhs: VideoLibraryItem) -> Bool {
        let titleCompare = lhs.title.localizedStandardCompare(rhs.title)
        if titleCompare != .orderedSame {
            return titleCompare == .orderedAscending
        }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}

private extension VideoLibraryItemMetadata {
    var isEmpty: Bool {
        displayTitle == nil
            && !isFavorite
            && tags.isEmpty
            && collectionIDs.isEmpty
            && boundSubtitlePath == nil
    }
}
