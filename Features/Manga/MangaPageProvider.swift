import AidokuRuntime
import Foundation
import ZIPFoundation

nonisolated struct MangaReadingChapter:
    Identifiable,
    Equatable,
    Hashable,
    Sendable
{
    let id: String
    let title: String
    let remoteIdentity: MangaRemoteIdentity?
    let wasReadAtOpen: Bool

    init(
        id: String,
        title: String,
        remoteIdentity: MangaRemoteIdentity? = nil,
        wasReadAtOpen: Bool = false
    ) {
        self.id = id
        self.title = title
        self.remoteIdentity = remoteIdentity
        self.wasReadAtOpen = wasReadAtOpen
    }
}

nonisolated enum MangaRemoteProvider: String, Codable, Sendable {
    case suwayomi
    case aidoku
}

nonisolated struct MangaRemoteIdentity:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let provider: MangaRemoteProvider
    let sourceID: String
    let mangaID: String
    let chapterID: String?

    var compositeID: String {
        [provider.rawValue, sourceID, mangaID, chapterID ?? ""]
            .joined(separator: "\u{1f}")
    }
}

nonisolated struct MangaPageReference:
    Identifiable,
    Equatable,
    Hashable,
    Sendable
{
    let id: String
    let index: Int
    let displayPath: String
    let ocrCacheIdentity: String
    let pageURL: String?
    let imageURL: String?
}

nonisolated enum MangaPagePayloadContent: Sendable {
    case image(data: Data, fileExtension: String)
    case text(String)
}

nonisolated struct MangaPagePayload: Sendable {
    let content: MangaPagePayloadContent
    let embeddedTextRegions: [MangaOCRTextRegion]?

    init(
        data: Data,
        fileExtension: String,
        embeddedTextRegions: [MangaOCRTextRegion]?
    ) {
        content = .image(data: data, fileExtension: fileExtension)
        self.embeddedTextRegions = embeddedTextRegions
    }

    init(text: String, embeddedTextRegions: [MangaOCRTextRegion]? = nil) {
        content = .text(text)
        self.embeddedTextRegions = embeddedTextRegions
    }

    var imageData: Data? {
        guard case .image(let data, _) = content else { return nil }
        return data
    }

    var fileExtension: String? {
        guard case .image(_, let fileExtension) = content else { return nil }
        return fileExtension
    }

    var text: String? {
        guard case .text(let text) = content else { return nil }
        return text
    }
}

nonisolated protocol MangaPageContentProvider: Sendable {
    func pages(
        for chapter: MangaReadingChapter
    ) async throws -> [MangaPageReference]
    func payload(for page: MangaPageReference) async throws
        -> MangaPagePayload
    func hasEmbeddedText(
        for chapter: MangaReadingChapter
    ) async throws -> Bool
    func prefetch(pages: [MangaPageReference]) async
    func cancelPendingRequests() async
}

nonisolated extension MangaPageContentProvider {
    func prefetch(pages: [MangaPageReference]) async {}
}

nonisolated struct MangaReadingSession: Sendable {
    typealias ProgressWriter = @Sendable (
        _ chapter: MangaReadingChapter,
        _ pageIndex: Int,
        _ pageCount: Int,
        _ completed: Bool
    ) async -> Void
    typealias CoverWriter = @Sendable (_ data: Data) async throws -> Void

    let profileID: String
    let documentID: String
    let title: String
    let chapters: [MangaReadingChapter]
    let initialChapterIndex: Int
    let initialPageIndex: Int
    let initialPages: [MangaPageReference]
    let modifiedAt: Date?
    let allowsCoverUpdates: Bool
    let suggestedLayout: MangaReaderLayout?
    let suggestedDirection: MangaReadingDirection?
    let progressWriter: ProgressWriter
    let coverWriter: CoverWriter

    static func local(
        item: MangaLibraryItem,
        source: MangaLibrarySource,
        profileID: String
    ) throws -> (
        session: MangaReadingSession,
        provider: LocalMangaPageContentProvider
    ) {
        let provider = try LocalMangaPageContentProvider(
            item: item,
            source: source
        )
        let chapter = MangaReadingChapter(
            id: item.id,
            title: item.displayTitle
        )
        let itemID = item.id
        return (
            MangaReadingSession(
                profileID: profileID,
                documentID: item.id,
                title: item.title,
                chapters: [chapter],
                initialChapterIndex: 0,
                initialPageIndex: item.currentPageIndex,
                initialPages: provider.pageReferences,
                modifiedAt: item.modifiedAt,
                allowsCoverUpdates: true,
                suggestedLayout: nil,
                suggestedDirection: nil,
                progressWriter: { _, pageIndex, _, _ in
                    await MangaLibraryStore.shared.updateProgress(
                        itemID: itemID,
                        pageIndex: pageIndex,
                        updatedAt: Date()
                    )
                },
                coverWriter: { data in
                    try await MangaLibraryStore.shared.setCover(
                        itemID: itemID,
                        imageData: data
                    )
                }
            ),
            provider
        )
    }

    static func suwayomi(
        manga: SuwayomiManga,
        chapters sourceChapters: [SuwayomiChapter],
        initialChapterID: Int? = nil,
        profileID: String,
        client: SuwayomiClient,
        pageProvider: SuwayomiMangaPageContentProvider
    ) async throws -> MangaReadingSession {
        guard !sourceChapters.isEmpty else {
            throw SuwayomiConnectorError.chapterUnavailable
        }
        let serverID = client.serverID
        let chapters = sourceChapters.map { chapter in
            MangaReadingChapter(
                id: SuwayomiIdentity.chapterID(
                    serverID: serverID,
                    remoteID: chapter.id
                ),
                title: chapter.name,
                remoteIdentity: MangaRemoteIdentity(
                    provider: .suwayomi,
                    sourceID: serverID,
                    mangaID: String(manga.id),
                    chapterID: String(chapter.id)
                ),
                wasReadAtOpen: chapter.read
            )
        }
        let lastReadIndex = sourceChapters.enumerated()
            .filter { $0.element.lastReadAt > 0 }
            .max { $0.element.lastReadAt < $1.element.lastReadAt }?
            .offset
        let firstUnreadIndex = sourceChapters.firstIndex { !$0.read }
        let selectedChapterIndex = initialChapterID.flatMap { chapterID in
            sourceChapters.firstIndex { $0.id == chapterID }
        }
        let initialChapterIndex =
            selectedChapterIndex ?? lastReadIndex ?? firstUnreadIndex ?? 0
        let initialChapter = chapters[initialChapterIndex]
        let initialPages = try await pageProvider.pages(
            for: initialChapter
        )
        let initialPageIndex = min(
            max(
                0,
                sourceChapters[initialChapterIndex].lastPageRead
            ),
            max(0, initialPages.count - 1)
        )
        return MangaReadingSession(
            profileID: profileID,
            documentID: SuwayomiIdentity.mangaID(
                serverID: serverID,
                remoteID: manga.id
            ),
            title: manga.title,
            chapters: chapters,
            initialChapterIndex: initialChapterIndex,
            initialPageIndex: initialPageIndex,
            initialPages: initialPages,
            modifiedAt: nil,
            allowsCoverUpdates: false,
            suggestedLayout: nil,
            suggestedDirection: nil,
            progressWriter: { chapter, pageIndex, _, completed in
                guard let chapterID = chapter.remoteIdentity?.chapterID,
                      let remoteID = Int(chapterID),
                      let remote = sourceChapters.first(where: { $0.id == remoteID }) else { return }
                try? await client.updateProgress(
                    chapter: remote,
                    pageIndex: pageIndex,
                    completed: completed
                )
            },
            coverWriter: { _ in
                throw SuwayomiConnectorError.mangaUnavailable
            }
        )
    }
}

nonisolated struct MangaRemoteReadingResult: Sendable {
    let session: MangaReadingSession
    let pageProvider: any MangaPageContentProvider
}

nonisolated struct MangaRemoteReadingRequest:
    Identifiable,
    Sendable
{
    let id = UUID()
    let provider: MangaRemoteProvider
    let sourceID: String
    let mangaID: String
    let title: String
    let profileID: String
    private let loader: @Sendable () async throws -> MangaRemoteReadingResult

    init(
        provider: MangaRemoteProvider,
        sourceID: String,
        mangaID: String,
        title: String,
        profileID: String,
        loader: @escaping @Sendable () async throws -> MangaRemoteReadingResult
    ) {
        self.provider = provider
        self.sourceID = sourceID
        self.mangaID = mangaID
        self.title = title
        self.profileID = profileID
        self.loader = loader
    }

    func load() async throws -> MangaRemoteReadingResult { try await loader() }
}

nonisolated final class LocalMangaPageContentProvider:
    MangaPageContentProvider,
    @unchecked Sendable
{
    let pageReferences: [MangaPageReference]
    private let loader: MangaPageLoader

    init(item: MangaLibraryItem, source: MangaLibrarySource) throws {
        let loader = try MangaPageLoader(item: item, source: source)
        self.loader = loader
        pageReferences = loader.pages.enumerated().map { index, page in
            MangaPageReference(
                id: "\(item.id):\(index)",
                index: index,
                displayPath: page.path,
                ocrCacheIdentity: page.path,
                pageURL: nil,
                imageURL: nil
            )
        }
    }

    func pages(
        for chapter: MangaReadingChapter
    ) async throws -> [MangaPageReference] {
        pageReferences
    }

    func payload(
        for page: MangaPageReference
    ) async throws -> MangaPagePayload {
        guard loader.pages.indices.contains(page.index) else {
            throw MangaPageLoaderError.pageUnavailable
        }
        return MangaPagePayload(
            data: try loader.imageData(at: page.index),
            fileExtension: URL(
                fileURLWithPath: loader.pages[page.index].path
            ).pathExtension,
            embeddedTextRegions: try loader.mokuroRegions(at: page.index)
        )
    }

    func hasEmbeddedText(
        for chapter: MangaReadingChapter
    ) async throws -> Bool {
        try loader.hasMokuroMetadata()
    }

    func cancelPendingRequests() async {}
}

nonisolated struct UnavailableMangaPageContentProvider:
    MangaPageContentProvider
{
    func pages(
        for chapter: MangaReadingChapter
    ) async throws -> [MangaPageReference] {
        throw MangaPageLoaderError.sourceUnavailable
    }

    func payload(
        for page: MangaPageReference
    ) async throws -> MangaPagePayload {
        throw MangaPageLoaderError.pageUnavailable
    }

    func hasEmbeddedText(
        for chapter: MangaReadingChapter
    ) async throws -> Bool {
        false
    }

    func cancelPendingRequests() async {}
}

actor SuwayomiMangaPageContentProvider:
    MangaPageContentProvider
{
    private static let maximumPageCacheBytes: Int64 =
        1_024 * 1_024 * 1_024
    private static let maximumPageCacheFiles = 1_024

    private struct InFlightPageRequest {
        let id: UUID
        let task: Task<Data, Error>
    }

    private struct PageLocation: Sendable {
        let mangaID: Int
        let sourceOrder: Int
        let pageIndex: Int
    }

    private let client: SuwayomiClient
    private let serverID: String
    private let profileID: String
    private let chaptersByID: [String: SuwayomiChapter]
    private let memoryCache = NSCache<NSString, NSData>()
    private let cacheDirectory: URL
    private var generation = UUID()
    private var locations: [String: PageLocation] = [:]
    private var inFlightPageRequests: [String: InFlightPageRequest] = [:]

    init(
        client: SuwayomiClient,
        profileID: String,
        chapters: [SuwayomiChapter]
    ) async throws {
        self.client = client
        self.profileID = profileID
        chaptersByID = Dictionary(uniqueKeysWithValues: chapters.map {
            (
                SuwayomiIdentity.chapterID(
                    serverID: client.serverID,
                    remoteID: $0.id
                ),
                $0
            )
        })
        serverID = client.serverID
        memoryCache.totalCostLimit = 96 * 1_024 * 1_024
        cacheDirectory = try Self.makeCacheDirectory(
            profileID: profileID,
            serverID: serverID
        )
        Self.pruneCache(in: cacheDirectory, protecting: nil)
    }

    func pages(
        for chapter: MangaReadingChapter
    ) async throws -> [MangaPageReference] {
        guard let remote = chaptersByID[chapter.id] else {
            throw SuwayomiConnectorError.chapterUnavailable
        }
        let requestedGeneration = generation
        let prepared = try await client.prepareChapter(
            mangaID: remote.mangaId,
            sourceOrder: remote.index
        )
        guard requestedGeneration == generation else {
            throw CancellationError()
        }
        guard prepared.pageCount > 0 else {
            throw SuwayomiConnectorError.chapterUnavailable
        }
        return (0..<prepared.pageCount).map { index in
            let identity = SuwayomiIdentity.sha256(
                [
                    profileID,
                    serverID,
                    String(prepared.id),
                    String(prepared.fetchedAt),
                    String(prepared.pageCount),
                    String(index),
                ].joined(separator: "\u{1f}")
            )
            locations[identity] = PageLocation(
                mangaID: prepared.mangaId,
                sourceOrder: prepared.index,
                pageIndex: index
            )
            return MangaPageReference(
                id: identity,
                index: index,
                displayPath: String(
                    format: "suwayomi-%06d.jpg",
                    index
                ),
                ocrCacheIdentity: identity,
                pageURL: client.pageURL(
                    mangaID: prepared.mangaId,
                    sourceOrder: prepared.index,
                    pageIndex: index
                ).absoluteString,
                imageURL: nil
            )
        }
    }

    func payload(
        for page: MangaPageReference
    ) async throws -> MangaPagePayload {
        let requestedGeneration = generation
        let key = page.id as NSString
        if let cached = memoryCache.object(forKey: key) {
            return makePayload(
                data: cached as Data
            )
        }
        let diskURL = cacheDirectory.appendingPathComponent(page.id)
        if let values = try? diskURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let size = values.fileSize,
        size > 0,
        size <= SuwayomiConstants.maximumImageBytes,
        let data = try? Data(
            contentsOf: diskURL,
            options: [.mappedIfSafe]
        ) {
            memoryCache.setObject(
                data as NSData,
                forKey: key,
                cost: data.count
            )
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: diskURL.path
            )
            return makePayload(data: data)
        }
        guard let location = locations[page.id] else {
            throw SuwayomiConnectorError.chapterUnavailable
        }
        let request: InFlightPageRequest
        if let inFlight = inFlightPageRequests[page.id] {
            request = inFlight
        } else {
            let requestID = UUID()
            let task = Task {
                try await client.pageData(
                    mangaID: location.mangaID,
                    sourceOrder: location.sourceOrder,
                    pageIndex: location.pageIndex
                )
            }
            request = InFlightPageRequest(id: requestID, task: task)
            inFlightPageRequests[page.id] = request
        }

        let data: Data
        do {
            data = try await request.task.value
        } catch {
            removeInFlightRequest(pageID: page.id, requestID: request.id)
            throw error
        }
        removeInFlightRequest(pageID: page.id, requestID: request.id)
        try Task.checkCancellation()
        guard generation == requestedGeneration else {
            throw CancellationError()
        }
        guard data.count <= SuwayomiConstants.maximumImageBytes else {
            throw SuwayomiConnectorError.responseTooLarge
        }
        memoryCache.setObject(data as NSData, forKey: key, cost: data.count)
        if (try? data.write(to: diskURL, options: .atomic)) != nil {
            Self.pruneCache(
                in: cacheDirectory,
                protecting: diskURL
            )
        }
        return makePayload(data: data)
    }

    func hasEmbeddedText(
        for chapter: MangaReadingChapter
    ) async throws -> Bool {
        false
    }

    func cancelPendingRequests() async {
        generation = UUID()
        for request in inFlightPageRequests.values {
            request.task.cancel()
        }
        inFlightPageRequests.removeAll()
    }

    func prefetch(pages: [MangaPageReference]) async {
        await withTaskGroup(of: Void.self) { group in
            for page in pages.prefix(4) {
                group.addTask {
                    _ = try? await self.payload(for: page)
                }
            }
        }
    }

    private func makePayload(data: Data) -> MangaPagePayload {
        return MangaPagePayload(
            data: data,
            fileExtension: Self.detectedFileExtension(data),
            embeddedTextRegions: nil
        )
    }

    private func removeInFlightRequest(
        pageID: String,
        requestID: UUID
    ) {
        guard inFlightPageRequests[pageID]?.id == requestID else { return }
        inFlightPageRequests[pageID] = nil
    }

    private static func detectedFileExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "gif"
        }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46],
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        return "jpg"
    }

    private static func makeCacheDirectory(
        profileID: String,
        serverID: String
    ) throws -> URL {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        guard !profileID.isEmpty,
              profileID.unicodeScalars.allSatisfy(allowed.contains),
              profileID != ".",
              profileID != ".." else {
            throw ProfileRepositoryError.unsafeProfileID
        }
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SuwayomiConnectorError.serverUnavailable
        }
        let directory = applicationSupport
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileID, isDirectory: true)
            .appendingPathComponent("SuwayomiCache", isDirectory: true)
            .appendingPathComponent(serverID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func pruneCache(
        in directory: URL,
        protecting protectedURL: URL?
    ) {
        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .contentModificationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var entries: [(url: URL, size: Int64, modifiedAt: Date)] =
            urls.compactMap { url in
                guard let values = try? url.resourceValues(
                    forKeys: resourceKeys
                ),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let size = values.fileSize,
                size >= 0 else {
                    return nil
                }
                return (
                    url.standardizedFileURL,
                    Int64(size),
                    values.contentModificationDate ?? .distantPast
                )
            }
        entries.sort { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt < rhs.modifiedAt
            }
            return lhs.url.path < rhs.url.path
        }

        var totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        let protectedURL = protectedURL?.standardizedFileURL
        while entries.count > maximumPageCacheFiles
            || totalBytes > maximumPageCacheBytes {
            guard let removalIndex = entries.firstIndex(where: {
                $0.url != protectedURL
            }) else {
                return
            }
            let entry = entries.remove(at: removalIndex)
            do {
                try FileManager.default.removeItem(at: entry.url)
                totalBytes -= entry.size
            } catch {
                continue
            }
        }
    }
}

actor AidokuMangaPageContentProvider: MangaPageContentProvider {
    private struct InFlightPage {
        let id: UUID
        let task: Task<MangaPagePayload, Error>
    }

    private static let maximumPageCacheBytes = AidokuLimits.maximumCacheBytes
    private static let maximumPageCacheFiles = AidokuLimits.maximumCacheEntries
    // Increment when native Aidoku page processing changes so incorrectly processed images are
    // never reused from an older build.
    private static let pageProcessingRevision = 2

    private let sourceID: String
    private let sourceVersion: Int
    private let manga: AidokuManga
    private let chaptersByID: [String: AidokuChapter]
    private let runtime: AidokuSourceRuntime
    private let usesSystemProxy: Bool
    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, NSData>()
    private var generation = UUID()
    private var pageByID: [String: AidokuPage] = [:]
    private var inFlight: [String: InFlightPage] = [:]

    init(
        sourceID: String,
        sourceVersion: Int,
        manga: AidokuManga,
        chapters: [AidokuChapter],
        runtime: AidokuSourceRuntime,
        usesSystemProxy: Bool
    ) throws {
        self.sourceID = sourceID
        self.sourceVersion = sourceVersion
        self.manga = manga
        self.chaptersByID = chapters.reduce(into: [:]) { result, chapter in
            if result[chapter.key] == nil {
                result[chapter.key] = chapter
            }
        }
        self.runtime = runtime
        self.usesSystemProxy = usesSystemProxy
        memoryCache.totalCostLimit = 96 * 1_024 * 1_024
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { throw AidokuRuntimeError.sourceUnavailable }
        cacheDirectory = applicationSupport
            .appendingPathComponent("Niratan", isDirectory: true)
            .appendingPathComponent("Aidoku", isDirectory: true)
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
            .appendingPathComponent(String(sourceVersion), isDirectory: true)
            .appendingPathComponent("processed-v\(Self.pageProcessingRevision)", isDirectory: true)
            .appendingPathComponent(SuwayomiIdentity.sha256(manga.key), isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        Self.pruneCache(in: cacheDirectory)
    }

    func pages(for chapter: MangaReadingChapter) async throws -> [MangaPageReference] {
        guard let chapterKey = chapter.remoteIdentity?.chapterID,
              let aidokuChapter = chaptersByID[chapterKey] else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        let requestGeneration = generation
        let pages = try await runtime.pages(manga: manga, chapter: aidokuChapter)
        guard requestGeneration == generation else { throw CancellationError() }
        let chapterHash = SuwayomiIdentity.sha256(chapterKey)
        return pages.enumerated().map { index, page in
            let identity = SuwayomiIdentity.sha256(
                [sourceID, String(sourceVersion), manga.key, chapterKey, String(index)]
                    .joined(separator: "\u{1f}")
            )
            pageByID[identity] = page
            let pageURL: String?
            switch page.content {
            case .url(let url, _), .zip(let url, _): pageURL = url
            case .text, .image: pageURL = nil
            }
            return MangaPageReference(
                id: identity,
                index: index,
                displayPath: "aidoku-\(chapterHash)-\(String(format: "%06d", index)).page",
                ocrCacheIdentity: identity,
                pageURL: pageURL,
                imageURL: page.thumbnailURL
            )
        }
    }

    func payload(for page: MangaPageReference) async throws -> MangaPagePayload {
        guard let aidokuPage = pageByID[page.id] else { throw AidokuRuntimeError.sourceUnavailable }
        if case .text(let text) = aidokuPage.content { return MangaPagePayload(text: text) }
        let key = page.id as NSString
        if let data = memoryCache.object(forKey: key) as Data? {
            return MangaPagePayload(data: data, fileExtension: detectedFileExtension(data), embeddedTextRegions: nil)
        }
        let diskURL = cacheDirectory.appendingPathComponent(page.id)
        if let values = try? diskURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile == true, values.isSymbolicLink != true,
           let size = values.fileSize, size > 0, size <= AidokuLimits.maximumImageBytes,
           let data = try? Data(contentsOf: diskURL, options: [.mappedIfSafe]) {
            memoryCache.setObject(data as NSData, forKey: key, cost: data.count)
            return MangaPagePayload(data: data, fileExtension: detectedFileExtension(data), embeddedTextRegions: nil)
        }
        let requestGeneration = generation
        if let current = inFlight[page.id] {
            let payload = try await current.task.value
            guard requestGeneration == generation else { throw CancellationError() }
            try Task.checkCancellation()
            return payload
        }
        let taskID = UUID()
        let task = Task<MangaPagePayload, Error> {
            let data = try await self.loadImage(page: aidokuPage)
            try Task.checkCancellation()
            guard data.count <= AidokuLimits.maximumImageBytes else { throw AidokuRuntimeError.responseTooLarge }
            return MangaPagePayload(data: data, fileExtension: self.detectedFileExtension(data), embeddedTextRegions: nil)
        }
        inFlight[page.id] = InFlightPage(id: taskID, task: task)
        do {
            let payload = try await task.value
            guard requestGeneration == generation,
                  inFlight[page.id]?.id == taskID,
                  let data = payload.imageData else { throw CancellationError() }
            inFlight[page.id] = nil
            memoryCache.setObject(data as NSData, forKey: key, cost: data.count)
            if (try? data.write(to: diskURL, options: .atomic)) != nil {
                Self.pruneCache(in: cacheDirectory)
            }
            try Task.checkCancellation()
            return payload
        } catch {
            if inFlight[page.id]?.id == taskID {
                inFlight[page.id] = nil
            }
            throw error
        }
    }

    func hasEmbeddedText(for chapter: MangaReadingChapter) async throws -> Bool { false }

    func prefetch(pages: [MangaPageReference]) async {
        await withTaskGroup(of: Void.self) { group in
            for page in pages.prefix(4) { group.addTask { _ = try? await self.payload(for: page) } }
        }
    }

    func cancelPendingRequests() async {
        generation = UUID()
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
    }

    private func loadImage(page: AidokuPage) async throws -> Data {
        switch page.content {
        case .image(let data): return data
        case .url(let value, let context):
            let imageRequest = try await runtime.imageRequest(url: value, context: context)
            var request = URLRequest(url: imageRequest.url)
            imageRequest.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.timeoutInterval = 120
            let (data, response) = try await AidokuHTTPClient.data(
                for: request,
                maximumBytes: AidokuLimits.maximumImageBytes,
                usesSystemProxy: usesSystemProxy
            )
            guard data.count <= AidokuLimits.maximumImageBytes,
                  (200..<300).contains(response.statusCode),
                  let scheme = response.url?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { throw AidokuRuntimeError.responseTooLarge }
            let responseHeaders = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                result[String(describing: pair.key)] = String(describing: pair.value)
            }
            return try await runtime.processPageImage(
                data,
                statusCode: response.statusCode,
                responseHeaders: responseHeaders,
                request: imageRequest,
                context: context
            )
        case .zip(let value, let path):
            let imageRequest = try await runtime.imageRequest(url: value, context: [:])
            guard ["http", "https"].contains(imageRequest.url.scheme?.lowercased() ?? "") else {
                throw AidokuRuntimeError.unsupportedURL
            }
            var request = URLRequest(url: imageRequest.url)
            request.timeoutInterval = 120
            imageRequest.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await AidokuHTTPClient.data(
                for: request,
                maximumBytes: AidokuLimits.maximumArchiveBytes,
                usesSystemProxy: usesSystemProxy
            )
            let archive: Archive
            do {
                archive = try Archive(data: data, accessMode: .read)
            } catch {
                throw AidokuRuntimeError.invalidArchive
            }
            guard data.count <= AidokuLimits.maximumArchiveBytes,
                  (200..<300).contains(response.statusCode),
                  let entry = archive[path], entry.type == .file,
                  entry.uncompressedSize <= UInt64(AidokuLimits.maximumImageBytes) else { throw AidokuRuntimeError.invalidArchive }
            var output = Data()
            _ = try archive.extract(entry) { chunk in
                guard output.count <= AidokuLimits.maximumImageBytes - chunk.count else { throw AidokuRuntimeError.responseTooLarge }
                output.append(chunk)
            }
            return output
        case .text: throw AidokuRuntimeError.sourceUnavailable
        }
    }

    private func detectedFileExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if bytes.count >= 12, Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46], Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return "jpg"
    }

    private static func pruneCache(in directory: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        var files: [(URL, Int64, Date)] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        var bytes = files.reduce(Int64(0)) { $0 + $1.1 }
        var count = files.count
        for file in files.sorted(by: { $0.2 < $1.2 }) where bytes > maximumPageCacheBytes || count > maximumPageCacheFiles {
            if (try? FileManager.default.removeItem(at: file.0)) != nil { bytes -= file.1; count -= 1 }
        }
    }
}

nonisolated extension MangaReadingSession {
    static func aidoku(
        source: AidokuInstalledSourceRecord,
        manga: AidokuManga,
        initialChapterKey: String?,
        profileID: String,
        runtime: AidokuSourceRuntime,
        progress: [AidokuChapterProgress],
        usesSystemProxy: Bool
    ) async throws -> MangaRemoteReadingResult {
        let loadedManga: AidokuManga
        if manga.chapters?.isEmpty == false {
            loadedManga = manga
        } else {
            loadedManga = try await runtime.mangaDetails(manga, chapters: true)
        }
        guard let loadedChapters = loadedManga.chapters else { throw AidokuRuntimeError.sourceUnavailable }
        var seenChapterKeys = Set<String>()
        let aidokuChapters = loadedChapters.filter {
            !$0.locked
                && !$0.key.isEmpty
                && seenChapterKeys.insert($0.key).inserted
        }
        guard !aidokuChapters.isEmpty else {
            throw AidokuRuntimeError.runtimeFailure(String(localized: "This manga has no readable chapters."))
        }
        let chapters = aidokuChapters.map { chapter in
            MangaReadingChapter(
                id: ["aidoku", source.sourceID, loadedManga.key, chapter.key].joined(separator: "\u{1f}"),
                title: chapter.title ?? chapter.chapterNumber.map { String(localized: "Chapter \($0.formatted())") } ?? chapter.key,
                remoteIdentity: MangaRemoteIdentity(provider: .aidoku, sourceID: source.sourceID, mangaID: loadedManga.key, chapterID: chapter.key),
                wasReadAtOpen: progress.first(where: {
                    $0.sourceID == source.sourceID
                        && $0.mangaKey == loadedManga.key
                        && $0.chapterKey == chapter.key
                })?.completed == true
            )
        }
        let selectedIndex = initialChapterKey.flatMap { key in aidokuChapters.firstIndex(where: { $0.key == key }) }
            ?? progress.filter { $0.sourceID == source.sourceID && $0.mangaKey == loadedManga.key }.max(by: { $0.updatedAt < $1.updatedAt }).flatMap { item in aidokuChapters.firstIndex(where: { $0.key == item.chapterKey }) }
            ?? 0
        let provider = try AidokuMangaPageContentProvider(
            sourceID: source.sourceID,
            sourceVersion: source.version,
            manga: loadedManga,
            chapters: aidokuChapters,
            runtime: runtime,
            usesSystemProxy: usesSystemProxy
        )
        let initialPages = try await provider.pages(for: chapters[selectedIndex])
        let storedProgress = progress.first { $0.sourceID == source.sourceID && $0.mangaKey == loadedManga.key && $0.chapterKey == aidokuChapters[selectedIndex].key }
        let session = MangaReadingSession(
            profileID: profileID,
            documentID: ["aidoku", source.sourceID, loadedManga.key].joined(separator: "\u{1f}"),
            title: loadedManga.title,
            chapters: chapters,
            initialChapterIndex: selectedIndex,
            initialPageIndex: min(max(0, storedProgress?.pageIndex ?? 0), max(0, initialPages.count - 1)),
            initialPages: initialPages,
            modifiedAt: nil,
            allowsCoverUpdates: false,
            suggestedLayout: loadedManga.viewer == .webtoon || loadedManga.viewer == .vertical ? .continuous : nil,
            suggestedDirection: loadedManga.viewer == .leftToRight ? .leftToRight : loadedManga.viewer == .rightToLeft ? .rightToLeft : nil,
            progressWriter: { chapter, pageIndex, pageCount, completed in
                guard let chapterKey = chapter.remoteIdentity?.chapterID else { return }
                try? await AidokuGlobalStore.shared.updateProgress(AidokuChapterProgress(sourceID: source.sourceID, mangaKey: loadedManga.key, chapterKey: chapterKey, pageIndex: pageIndex, pageCount: pageCount, completed: completed, updatedAt: Date()))
            },
            coverWriter: { _ in throw AidokuRuntimeError.sourceUnavailable }
        )
        return MangaRemoteReadingResult(session: session, pageProvider: provider)
    }
}
