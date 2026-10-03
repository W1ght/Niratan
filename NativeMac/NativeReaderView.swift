import AppKit
import EPUBKit
import OSLog
import SwiftUI
import WebKit
import CHoshiDicts

private let readerPersistenceLogger = Logger(subsystem: "moe.shishamo.hoshi", category: "ReaderPersistence")
private let readerStatisticsLogger = Logger(subsystem: "moe.shishamo.hoshi", category: "ReaderStatistics")

enum NativeReaderNavigationDirection: Equatable {
    case forward
    case backward
}

enum ReaderDisplayMode {
    case novel
    case lyrics
}

struct NativeReaderPageNavigation: Equatable {
    let id = UUID()
    let direction: NativeReaderNavigationDirection
}

@MainActor
private enum NativeReaderNavigationConsumptionRegistry {
    private static var consumedIDs: [UUID] = []

    static func consume(_ id: UUID) -> Bool {
        guard !consumedIDs.contains(id) else { return false }
        consumedIDs.append(id)
        if consumedIDs.count > 128 {
            consumedIDs.removeFirst(consumedIDs.count - 128)
        }
        return true
    }
}

private struct NativeReaderPosition {
    let index: Int
    let progress: Double
}

@MainActor
private enum NativeReaderLifecycleRegistry {
    private static var activeModelIDsByRequestID: [UUID: UUID] = [:]

    static func markActive(requestID: UUID, modelID: UUID) {
        activeModelIDsByRequestID[requestID] = modelID
    }

    static func isActive(requestID: UUID, modelID: UUID) -> Bool {
        activeModelIDsByRequestID[requestID] == modelID
    }

    static func clear(requestID: UUID, modelID: UUID) {
        if activeModelIDsByRequestID[requestID] == modelID {
            activeModelIDsByRequestID.removeValue(forKey: requestID)
        }
    }
}

private enum NativeReaderSheet: Identifiable, Equatable {
    case appearance
    case goTo
    case gallery
    case statistics
    case sasayaki

    var id: Self { self }
}

struct NativeReaderLoader: View {
    @Environment(UserConfig.self) private var userConfig
    let book: BookMetadata
    let model: NativeReaderModel
    let requestID: UUID
    let isActive: Bool
    var onFocusModeChanged: (Bool) -> Void
    var onClose: () -> Void

    init(
        book: BookMetadata,
        model: NativeReaderModel,
        requestID: UUID,
        isActive: Bool = true,
        onFocusModeChanged: @escaping (Bool) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.book = book
        self.model = model
        self.requestID = requestID
        self.isActive = isActive
        self.onFocusModeChanged = onFocusModeChanged
        self.onClose = onClose
    }

    var body: some View {
        Group {
            if model.document != nil {
                NativeReaderView(
                    model: model,
                    requestID: requestID,
                    isActive: isActive,
                    onFocusModeChanged: onFocusModeChanged,
                    onClose: onClose
                )
            } else if model.isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .frame(minWidth: ReaderWindowGeometry.minimumSize.width, minHeight: ReaderWindowGeometry.minimumSize.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        readerPersistenceLogger.notice(
                            "reader.loader.loading book=\(model.book.folder, privacy: .public)"
                        )
                    }
            } else {
                ContentUnavailableView {
                    Label("Unable to Open Book", systemImage: "book.pages")
                } description: {
                    Text("The EPUB file could not be loaded from local storage.")
                } actions: {
                    Button("Close") {
                        onClose()
                    }
                }
                .frame(minWidth: ReaderWindowGeometry.minimumSize.width, minHeight: ReaderWindowGeometry.minimumSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    readerPersistenceLogger.error(
                        "reader.loader.failed book=\(model.book.folder, privacy: .public)"
                    )
                }
            }
        }
        .task {
            model.configure(userConfig: userConfig)
            model.loadBook()
        }
        .onChange(of: userConfig.statisticsResetTime) { _, resetTime in
            model.updateStatisticsResetTime(resetTime)
        }
    }
}

@Observable
@MainActor
final class NativeReaderModel: SyncOpenReader {
    let instanceID = UUID()
    let book: BookMetadata
    let bridge = WebViewBridge()
    var document: EPUBDocument?
    var rootURL: URL?
    var bookInfo = BookInfo(characterCount: 0, chapterInfo: [:])
    var index = 0
    var progress: Double = 0
    var isLoading = true
    var isGalleryIndexing = false
    var popups: [NativeReaderPopup] = []
    var popup: NativeReaderPopup? { popups.last }
    var imageURL: URL?
    var highlights: [Highlight] = []
    var highlightRevision = 0
    /// Until the open-time library sync finishes, a newer remote position may still move the
    /// reader; afterwards the local position is never changed under the user.
    private(set) var acceptsSyncedPosition = true
    var loadRevision = 0
    var pendingFragment: String?
    var isTracking = false
    var isPaused = false
    var lastTimestamp: Date = .now
    var lastCount = 0
    private var sessionID = UUID().uuidString
    private(set) var currentSession = ReadingSession.starting(at: .now)
    private var statisticsHistory: ReadingSessionRecords = [:]
    private var historyDayTotals: [String: ReadingTotal] = [:]
    private var historyTotal = ReadingTotal()
    private(set) var pageIndex = ReaderPageIndex(spinePageStarts: [], spineStartCharacters: [])
    private var currentSpinePage: (url: URL, page: Int)?
    private var lastSavedSessionModified: Int64 = 0
    var sasayakiPlayer: SasayakiPlayer?
    var wasPaused = false

    private var isReaderWindowActive = false
    private var isStatisticsSheetActive = false
    private var isReaderContentCovered = false
    private var enableStatistics = false
    private var statisticsAutostartMode: StatisticsAutostartMode = .off
    private var statisticsResetTime = 0
    private var autoSyncEnabled = false
    private var syncBookData = false
    private var syncStats = false
    private var statsSyncMode: StatisticsSyncMode = .merge
    private var syncAudioBook = false
    private var fushiAutoSyncEnabled = false
    /// A Fushi progress conflict found while opening the book, asked about before
    /// reading starts. While it is shown here the main window does not ask again.
    var fushiConflict: FushiProgressConflict? {
        didSet {
            if let oldValue, oldValue.book.id != fushiConflict?.book.id {
                FushiProgressCoordinator.shared.endReaderPrompt(for: oldValue.book.id)
            }
            if let fushiConflict {
                FushiProgressCoordinator.shared.beginReaderPrompt(for: fushiConflict.book.id)
            }
        }
    }
    private var pendingAutoExport = false
    private var didPrepareForReaderLifecycleClose = false
    private var didSyncOnOpen = false
    private var debounceTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var statisticsTimerTask: Task<Void, Never>?
    private var chapterIndexTask: Task<Void, Never>?
    private var chapterIndexGeneration: UUID?
    private var galleryIndexTask: Task<Void, Never>?
    private var galleryIndexGeneration: UUID?
    private var galleryURLCacheTask: Task<Void, Never>?
    private var galleryURLCacheGeneration: UUID?
    private var galleryImageURLCache: [String: URL] = [:]
    private var backHistory: [NativeReaderPosition] = []
    private var forwardHistory: [NativeReaderPosition] = []

    private var isStatisticsContextActive: Bool {
        isStatisticsSheetActive || (isReaderWindowActive && !isReaderContentCovered)
    }

    private var currentPosition: NativeReaderPosition {
        NativeReaderPosition(index: index, progress: progress)
    }

    var sessionStatistics: ReadingTotal {
        currentSession.total
    }

    var todaysStatistics: ReadingTotal {
        let today = StatisticsDayBoundary.dateKey(for: .now, resetMinutes: statisticsResetTime)
        var total = historyDayTotals[today] ?? ReadingTotal()
        if ReadingSessionLog.dateKey(for: currentSession, resetMinutes: statisticsResetTime) == today {
            total.add(currentSession)
        }
        return total
    }

    var allTimeStatistics: ReadingTotal {
        var total = historyTotal
        total.add(currentSession)
        return total
    }

    var backTarget: Int? {
        backHistory.last.flatMap(characterProgress)
    }

    var forwardTarget: Int? {
        forwardHistory.last.flatMap(characterProgress)
    }

    init(book: BookMetadata) {
        self.book = book
    }

    func configure(userConfig: UserConfig) {
        enableStatistics = userConfig.enableStatistics
        statisticsAutostartMode = userConfig.statisticsAutostartMode
        statisticsResetTime = StatisticsDayBoundary.normalizedResetMinutes(
            userConfig.statisticsResetTime
        )
        autoSyncEnabled = userConfig.enableSync && userConfig.enableAutoSync && userConfig.syncProvider == .ttu
        syncBookData = userConfig.enableSync && userConfig.syncUploadBooks
        syncStats = userConfig.enableSync && userConfig.statisticsEnableSync
        statsSyncMode = userConfig.statisticsSyncMode
        syncAudioBook = userConfig.enableSasayaki && userConfig.sasayakiEnableSync
        fushiAutoSyncEnabled = FushiProgressCoordinator.shared.isAutoSyncActive
    }

    func updateStatisticsResetTime(_ resetTime: Int) {
        let normalized = StatisticsDayBoundary.normalizedResetMinutes(resetTime)
        guard normalized != statisticsResetTime else { return }

        if enableStatistics, document != nil {
            if isTracking, !isPaused {
                updateStats()
            }
            saveStats()
        }

        statisticsResetTime = normalized

        if enableStatistics, document != nil {
            regroupStatisticsHistory()
            resetTrackingBaseline()
        }
    }

    func loadBook() {
        guard document == nil else {
            return
        }

        guard let root = rootDirectory,
              let epubURL else {
            isLoading = false
            return
        }

        guard let doc = try? BookStorage.loadEpub(epubURL) else {
            isLoading = false
            return
        }

        CSSSanitizer.sanitizeDirectory(doc.contentDirectory)
        document = doc
        rootURL = root
        if let storedBookInfo = BookStorage.loadBookInfo(root: root) {
            bookInfo = storedBookInfo
            let fragmentSources = BookProcessor.fragmentOffsetSources(
                document: doc,
                chapterInfo: storedBookInfo.chapterInfo
            )
            if !fragmentSources.isEmpty {
                startChapterIndexBackfill(sources: fragmentSources, root: root)
            }
            if storedBookInfo.images == nil || storedBookInfo.imagePositions == nil {
                startGalleryIndexBackfill(
                    document: doc,
                    root: root,
                    chapterInfo: storedBookInfo.chapterInfo
                )
            } else {
                startGalleryImageURLCacheRefresh(
                    paths: storedBookInfo.images ?? [],
                    contentDirectory: doc.contentDirectory
                )
            }
        } else {
            bookInfo = BookInfo(characterCount: 0, chapterInfo: [:])
        }
        highlights = BookStorage.loadHighlights(root: root) ?? []
        setupSasayakiPlayer(rootURL: root)
        loadStatistics()

        if let bookmark = BookStorage.loadBookmark(root: root) {
            index = min(max(bookmark.chapterIndex, 0), max(doc.spine.items.count - 1, 0))
            progress = bookmark.progress
        }
        loadCurrentChapterState()

        if statisticsAutostartMode == .on {
            startTracking()
        }

        // Opening the Reader can overlap the one-time language metadata backfill.
        // Merge the latest sidecar before updating last access so an older in-memory book
        // cannot erase fields written by that migration.
        var bookCopy = BookStorage.loadMetadata(root: root) ?? book
        bookCopy.lastAccess = Date()
        try? BookStorage.save(bookCopy, inside: root, as: FileNames.metadata)
    }

    private func startChapterIndexBackfill(
        sources: [ReaderChapterIndex.FragmentOffsetSource],
        root: URL
    ) {
        chapterIndexTask?.cancel()
        let generation = UUID()
        chapterIndexGeneration = generation
        chapterIndexTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                ReaderChapterIndex.fragmentOffsets(
                    sources: sources,
                    shouldCancel: { Task.isCancelled }
                )
            }
            let offsetsByChapterPath = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  let self,
                  self.chapterIndexGeneration == generation,
                  let offsetsByChapterPath else {
                return
            }

            let latestBookInfo = BookStorage.loadBookInfo(root: root) ?? self.bookInfo
            var sourceByChapterPath: [String: ReaderChapterIndex.FragmentOffsetSource] = [:]
            for source in sources {
                sourceByChapterPath[source.chapterPath] = source
            }
            let compatibleOffsets = offsetsByChapterPath.filter { path, _ in
                guard let source = sourceByChapterPath[path],
                      let latestChapter = latestBookInfo.chapterInfo[path] else {
                    return false
                }
                return latestChapter.currentTotal == source.expectedChapterStart
                    && latestChapter.chapterCount == source.expectedChapterCount
            }
            guard !compatibleOffsets.isEmpty else {
                self.chapterIndexGeneration = nil
                self.chapterIndexTask = nil
                return
            }
            let indexedBookInfo = latestBookInfo.mergingMissingFragmentOffsets(compatibleOffsets)
            self.bookInfo = indexedBookInfo
            self.chapterIndexGeneration = nil
            self.chapterIndexTask = nil
            try? BookStorage.save(indexedBookInfo, inside: root, as: FileNames.bookinfo)
        }
    }

    private func startGalleryIndexBackfill(
        document: EPUBDocument,
        root: URL,
        chapterInfo: [String: BookInfo.ChapterInfo]
    ) {
        galleryIndexTask?.cancel()
        let sources = BookProcessor.imageIndexSources(
            document: document,
            chapterInfo: chapterInfo
        )
        let generation = UUID()
        let contentDirectory = document.contentDirectory
        galleryIndexGeneration = generation
        isGalleryIndexing = true

        galleryIndexTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                BookProcessor.imageIndex(sources: sources)
            }
            let imageIndex = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  let self,
                  self.galleryIndexGeneration == generation,
                  let imageIndex else {
                return
            }

            let latestBookInfo = BookStorage.loadBookInfo(root: root) ?? self.bookInfo
            let indexedBookInfo: BookInfo
            if latestBookInfo.images != nil, latestBookInfo.imagePositions != nil {
                indexedBookInfo = latestBookInfo
            } else {
                indexedBookInfo = BookInfo(
                    characterCount: latestBookInfo.characterCount,
                    chapterInfo: latestBookInfo.chapterInfo,
                    images: imageIndex.paths,
                    imagePositions: imageIndex.positions
                )
            }
            self.bookInfo = indexedBookInfo
            self.galleryIndexGeneration = nil
            self.galleryIndexTask = nil
            try? BookStorage.save(indexedBookInfo, inside: root, as: FileNames.bookinfo)
            self.startGalleryImageURLCacheRefresh(
                paths: indexedBookInfo.images ?? [],
                contentDirectory: contentDirectory
            )
        }
    }

    private func startGalleryImageURLCacheRefresh(
        paths: [String],
        contentDirectory: URL
    ) {
        galleryURLCacheTask?.cancel()
        galleryImageURLCache = [:]
        guard !paths.isEmpty else {
            galleryURLCacheGeneration = nil
            galleryURLCacheTask = nil
            isGalleryIndexing = false
            return
        }

        let generation = UUID()
        galleryURLCacheGeneration = generation
        isGalleryIndexing = true
        galleryURLCacheTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                ReaderImageGalleryIndex.resolvedStoredImageURLs(
                    for: paths,
                    contentDirectory: contentDirectory,
                    shouldCancel: { Task.isCancelled }
                )
            }
            let resolvedURLs = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  let self,
                  self.galleryURLCacheGeneration == generation,
                  let resolvedURLs else {
                return
            }
            self.galleryImageURLCache = resolvedURLs
            self.galleryURLCacheGeneration = nil
            self.galleryURLCacheTask = nil
            self.isGalleryIndexing = false
        }
    }

    func syncOnOpenIfNeeded() async {
        guard !didSyncOnOpen else { return }
        didSyncOnOpen = true
        let librarySync = GoogleDriveSyncManager.shared
        if librarySync.enabled {
            await librarySync.sync(book: book)
            acceptsSyncedPosition = false
            loadCurrentChapterState()
            resetTrackingBaseline()
            // Fushi interconnect is independent of the selected Google Drive provider.
            guard fushiAutoSyncEnabled else { return }
        }
        acceptsSyncedPosition = false
        guard autoSyncEnabled || fushiAutoSyncEnabled else {
            resetTrackingBaseline()
            return
        }
        var shouldReloadBookmark = false
        if autoSyncEnabled {
            let result = try? await SyncManager.shared.syncBook(
                book: book,
                direction: nil,
                syncBookData: syncBookData,
                syncStats: syncStats,
                statsSyncMode: statsSyncMode,
                syncAudioBook: syncAudioBook,
                importOnly: true
            )
            if case .imported = result {
                shouldReloadBookmark = true
            }
        }
        if fushiAutoSyncEnabled {
            switch await FushiProgressCoordinator.shared.syncBook(book, trigger: .readerOpen) {
            case .pulled:
                shouldReloadBookmark = true
            case .conflict(let conflict):
                fushiConflict = conflict
            default:
                break
            }
        }
        if shouldReloadBookmark {
            reloadBookmark()
        }
        loadCurrentChapterState()
        resetTrackingBaseline()
    }

    /// Moves the open book to the position chosen in a Fushi conflict.
    func applyResolvedFushiProgress(_ choice: FushiConflictChoice) {
        fushiConflict = nil
        guard choice == .useFushi else { return }
        reloadBookmark()
        loadCurrentChapterState()
        resetTrackingBaseline()
    }

    var title: String {
        document?.title ?? book.displayTitle
    }

    var currentChapterURL: URL? {
        guard let document,
              document.spine.items.indices.contains(index),
              let item = document.manifest.items[document.spine.items[index].idref] else {
            return nil
        }
        return document.contentDirectory.appendingPathComponent(item.path)
    }

    var readerReadAccessURL: URL? {
        document?.contentDirectory ?? rootURL
    }

    var coverURL: URL? {
        guard let rootURL else { return nil }
        return BookStorage.loadMetadata(root: rootURL)?.coverURL
    }

    var imageURLs: [URL] {
        (bookInfo.images ?? []).compactMap { galleryImageURLCache[$0] }
    }

    var galleryImages: [ReaderGalleryImage] {
        let currentCharacter = currentCharacter
        let chapterLabels = galleryChapterLabels
        return (bookInfo.images ?? []).compactMap { path in
            guard let url = galleryImageURLCache[path] else { return nil }
            let position = bookInfo.imagePositions?[path]
            let isRead = position.map { $0 <= currentCharacter } ?? true
            var spine = position.flatMap { bookInfo.resolveCharacterPosition($0)?.spineIndex } ?? -1
            while spine > 0, chapterLabels[spine] == nil {
                spine -= 1
            }
            return ReaderGalleryImage(
                url: url,
                isRead: isRead,
                chapterIndex: spine,
                chapterTitle: chapterLabels[spine] ?? ""
            )
        }
    }

    /// First TOC label for each spine item, used to group gallery images.
    private var galleryChapterLabels: [Int: String] {
        guard let document else { return [:] }
        var labels: [Int: String] = [:]
        for row in ChapterListViewModel(document: document, bookInfo: bookInfo, currentCharacter: 0).rows
        where !row.label.isEmpty && labels[row.spineIndex] == nil {
            labels[row.spineIndex] = row.label
        }
        return labels
    }

    var currentCharacter: Int {
        guard let document,
              document.spine.items.indices.contains(index),
              let item = document.manifest.items[document.spine.items[index].idref],
              let chapterInfo = bookInfo.chapterInfo[item.path] else {
            return 0
        }
        return chapterInfo.currentTotal + Int(Double(chapterInfo.chapterCount) * progress)
    }

    var currentTOCChapterRange: ReaderChapterIndex.ChapterRange {
        let tableOfContentsItems = document.map {
            BookProcessor.tableOfContentsItemPaths(in: $0.tableOfContents)
        } ?? []
        let starts = ReaderChapterIndex.chapterStarts(
            tableOfContentsItems: tableOfContentsItems,
            bookInfo: bookInfo
        )
        return ReaderChapterIndex.chapterRange(
            containing: currentCharacter,
            chapterStarts: starts,
            bookCharacterCount: bookInfo.characterCount
        )
    }

    var currentChapterCharactersRemaining: Int {
        currentTOCChapterRange.remaining(at: currentCharacter)
    }

    /// TOC chapter for progress display. At the very end of a spine item the
    /// character offset equals the next item's start, so look up the last character.
    var currentProgressChapterRange: ReaderChapterIndex.ChapterRange {
        let tableOfContentsItems = document.map {
            BookProcessor.tableOfContentsItemPaths(in: $0.tableOfContents)
        } ?? []
        let starts = ReaderChapterIndex.chapterStarts(
            tableOfContentsItems: tableOfContentsItems,
            bookInfo: bookInfo
        )
        let spineEnd = chapterRange?.end ?? 0
        let lookup = spineEnd > 0 ? min(currentCharacter, spineEnd - 1) : currentCharacter
        return ReaderChapterIndex.chapterRange(
            containing: lookup,
            chapterStarts: starts,
            bookCharacterCount: bookInfo.characterCount
        )
    }

    var spineURLs: [URL] {
        guard let document else { return [] }
        return document.spine.items.compactMap { item in
            document.manifest.items[item.idref].map { document.contentDirectory.appendingPathComponent($0.path) }
        }
    }

    func updatePages(_ spinePageStarts: [[Int]]) {
        guard let document else { return }
        let spineStarts = document.spine.items.map { item in
            document.manifest.items[item.idref].flatMap { bookInfo.chapterInfo[$0.path]?.currentTotal } ?? 0
        }
        pageIndex = ReaderPageIndex(spinePageStarts: spinePageStarts, spineStartCharacters: spineStarts)
    }

    func updateCurrentPage(url: URL, page: Int) {
        currentSpinePage = (Self.urlWithoutFragment(url).standardizedFileURL, page)
    }

    var pageProgress: ReaderPageIndex.Progress? {
        guard !pageIndex.isEmpty else { return nil }
        let page: Int?
        if let currentSpinePage,
           let chapterURL = currentChapterURL,
           currentSpinePage.url == chapterURL.standardizedFileURL {
            page = pageIndex.page(spineIndex: index, localPage: currentSpinePage.page)
        } else if progress <= 0 {
            page = pageIndex.page(spineIndex: index, localPage: 0)
        } else {
            page = pageIndex.page(at: currentCharacter, spineIndex: index)
        }
        guard let page else { return nil }
        let chapter = currentProgressChapterRange
        return pageIndex.progress(
            page: page,
            chapterStart: chapter.start,
            chapterCount: chapter.count,
            bookCharacterCount: bookInfo.characterCount
        )
    }

    private var chapterRange: (start: Int, end: Int)? {
        guard let document,
              document.spine.items.indices.contains(index),
              let item = document.manifest.items[document.spine.items[index].idref],
              let chapterInfo = bookInfo.chapterInfo[item.path] else {
            return nil
        }
        return (chapterInfo.currentTotal, chapterInfo.currentTotal + chapterInfo.chapterCount)
    }

    func chapterHighlightsJSON() -> String? {
        guard let range = chapterRange else { return nil }
        let list = highlights.filter { $0.character >= range.start && $0.character < range.end }
        guard !list.isEmpty,
              let data = try? JSONEncoder().encode(list) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func updateProgress(_ newProgress: Double) {
        progress = min(max(newProgress, 0), 1)
    }

    func saveBookmark(_ newProgress: Double) {
        persistBookmark(newProgress)
        flushStats()
    }

    private func persistBookmark(_ newProgress: Double) {
        guard let rootURL else { return }
        updateProgress(newProgress)
        bridge.updateProgress(progress)
        let bookmark = Bookmark(
            chapterIndex: index,
            progress: progress,
            characterCount: currentCharacter,
            lastModified: Date()
        )
        let url = rootURL.appendingPathComponent(FileNames.bookmark)
        readerPersistenceLogger.notice(
            "reader.bookmark.save.start book=\(self.book.folder, privacy: .public) path=\(url.path, privacy: .public) chapter=\(self.index, privacy: .public) progress=\(self.progress, privacy: .public) character=\(self.currentCharacter, privacy: .public)"
        )
        do {
            try BookStorage.save(bookmark, inside: rootURL, as: FileNames.bookmark)
            readerPersistenceLogger.notice(
                "reader.bookmark.save.success book=\(self.book.folder, privacy: .public) path=\(url.path, privacy: .public) chapter=\(bookmark.chapterIndex, privacy: .public) progress=\(bookmark.progress, privacy: .public) character=\(bookmark.characterCount, privacy: .public)"
            )
        } catch {
            readerPersistenceLogger.error(
                "reader.bookmark.save.failure book=\(self.book.folder, privacy: .public) path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        scheduleAutoExport()
    }

    private func establishProgrammaticDestination(_ progress: Double) {
        readerPersistenceLogger.notice(
            "reader.programmaticDestination book=\(self.book.folder, privacy: .public) chapter=\(self.index, privacy: .public) progress=\(progress, privacy: .public)"
        )
        persistBookmark(progress)
        resetTrackingBaseline()
    }

    func syncProgressAfterProgrammaticJump(_ progress: Double) {
        readerPersistenceLogger.notice(
            "reader.internalJump.progress book=\(self.book.folder, privacy: .public) chapter=\(self.index, privacy: .public) progress=\(progress, privacy: .public)"
        )
        establishProgrammaticDestination(progress)
    }

    func syncBookmarkToSasayakiCue(_ cue: SasayakiMatch) {
        readerPersistenceLogger.notice(
            "reader.sasayakiCueBookmark.sync.request book=\(self.book.folder, privacy: .public) currentChapter=\(self.index, privacy: .public) cue=\(cue.id, privacy: .public) cueChapter=\(cue.chapterIndex, privacy: .public) cueStart=\(cue.start, privacy: .public) cueLength=\(cue.length, privacy: .public)"
        )
        guard let document,
              document.spine.items.indices.contains(cue.chapterIndex),
              let item = document.manifest.items[document.spine.items[cue.chapterIndex].idref],
              let chapterInfo = bookInfo.chapterInfo[item.path] else {
            readerPersistenceLogger.error(
                "reader.sasayakiCueBookmark.sync.failure book=\(self.book.folder, privacy: .public) cue=\(cue.id, privacy: .public) cueChapter=\(cue.chapterIndex, privacy: .public)"
            )
            return
        }

        let cueProgress = cue.readerProgress(chapterCharacterCount: chapterInfo.chapterCount)
        readerPersistenceLogger.notice(
            "reader.sasayakiCueBookmark.sync book=\(self.book.folder, privacy: .public) currentChapter=\(self.index, privacy: .public) targetChapter=\(cue.chapterIndex, privacy: .public) progress=\(cueProgress, privacy: .public) chapterCount=\(chapterInfo.chapterCount, privacy: .public)"
        )
        guard cue.chapterIndex != index else {
            establishProgrammaticDestination(cueProgress)
            return
        }

        flushStats()
        sasayakiPlayer?.prepareTransition()
        index = cue.chapterIndex
        progress = cueProgress
        pendingFragment = nil
        loadRevision += 1
        establishProgrammaticDestination(cueProgress)
        isLoading = true
        popups.removeAll()
        loadCurrentChapterState()
    }

    func syncBookmarkToCurrentLyricsCue() {
        guard let cue = sasayakiPlayer?.currentCue else { return }
        syncBookmarkToSasayakiCue(cue)
    }

    func handleLyricsCueDidAdvance(from previousCue: SasayakiMatch?, to cue: SasayakiMatch) {
        guard previousCue?.id != cue.id else { return }
        let isNaturalPlaybackAdvance = previousCue != nil && sasayakiPlayer?.isPlaying == true

        if !isNaturalPlaybackAdvance {
            applyLyricsCuePosition(cue, persistBookmark: true)
            resetLyricsStatisticsBaseline()
            return
        }

        if !isTracking {
            startTracking()
        }
        applyLyricsCuePosition(cue, persistBookmark: true)
        guard enableStatistics, isTracking, !isPaused else { return }
        updateStats()
        saveStats()
    }

    func resetLyricsStatisticsBaseline() {
        if let cue = sasayakiPlayer?.currentCue {
            applyLyricsCuePosition(cue, persistBookmark: true)
        }
        resetTrackingBaseline()
    }

    func resetLyricsStatisticsBaseline(to cue: SasayakiMatch) {
        applyLyricsCuePosition(cue, persistBookmark: true)
        resetTrackingBaseline()
    }

    func handleLyricsSelection(
        text: String,
        offset: Int,
        rect: CGRect,
        cue: SasayakiMatch,
        userConfig: UserConfig,
        isVertical: Bool? = nil
    ) -> Int? {
        let miningContext = MiningContextSelection.timedSentences(
            from: sasayakiPlayer?.matchData?.matches ?? [],
            currentID: cue.id,
            targetUTF16Location: offset,
            id: \.id,
            text: \.text,
            mediaRange: { cue in
                MiningContextMediaRange(start: cue.startTime, end: cue.endTime)
            }
        ) ?? MiningContextSelection.text(
            cue.text,
            targetUTF16Location: offset,
            mediaRange: MiningContextMediaRange(start: cue.startTime, end: cue.endTime)
        )
        let selection = SelectionData(
            text: text,
            sentence: cue.text,
            rect: rect,
            normalizedOffset: cue.start + offset,
            miningContext: miningContext
        )
        return handleSelection(
            selection,
            userConfig: userConfig,
            replacingExistingPopups: true,
            isVertical: false,
            isFullWidth: false
        )
    }

    func handleRestoreCompleted() {
        if sasayakiPlayer?.hasAudio != true {
            sasayakiPlayer?.restoreAudio()
        }
        isLoading = false
        pendingFragment = nil
        sasayakiPlayer?.handleRestoreCompleted(currentIndex: index)
    }

    func importSasayakiAudio(from url: URL) throws {
        try sasayakiPlayer?.importAudio(from: url)
    }

    func startTracking() {
        guard enableStatistics else { return }
        guard !isTracking else {
            startStatisticsTimerIfNeeded()
            return
        }
        if !currentSession.hasActivity {
            currentSession = .starting(at: .now)
        }
        isTracking = true
        isPaused = !isStatisticsContextActive
        resetTrackingBaseline()
        startStatisticsTimerIfNeeded()
        readerStatisticsLogger.notice(
            "reader.statistics.start book=\(self.book.folder, privacy: .public) mode=\(self.statisticsAutostartMode.rawValue, privacy: .public) chapter=\(self.index, privacy: .public) progress=\(self.progress, privacy: .public) current=\(self.currentCharacter, privacy: .public)"
        )
    }

    func stopTracking() {
        guard isTracking else { return }
        flushStats()
        isTracking = false
        isPaused = false
        stopStatisticsTimer()
    }

    func updateReaderWindowActivity(_ isActive: Bool) {
        isReaderWindowActive = isActive
        reconcileStatisticsFocus()
    }

    func updateStatisticsSheetActivity(_ isActive: Bool) {
        isStatisticsSheetActive = isActive
        reconcileStatisticsFocus()
    }

    func updateReaderContentCovered(_ isCovered: Bool) {
        isReaderContentCovered = isCovered
        reconcileStatisticsFocus()
    }

    private func reconcileStatisticsFocus() {
        if isStatisticsContextActive {
            guard isTracking, isPaused else { return }
            resetTrackingBaseline()
            isPaused = false
            return
        }

        guard isTracking, !isPaused else { return }
        flushStats()
        isPaused = true
    }

    func toggleStatisticsTracking() {
        if isTracking {
            stopTracking()
        } else {
            startTracking()
        }
    }

    func startTrackingOnPageTurnIfNeeded() {
        if statisticsAutostartMode == .pageturn && !isTracking {
            startTracking()
        }
    }

    func handleManualNavigation() {
        readerStatisticsLogger.notice(
            "reader.statistics.pageTurn book=\(self.book.folder, privacy: .public) mode=\(self.statisticsAutostartMode.rawValue, privacy: .public) tracking=\(self.isTracking, privacy: .public) chapter=\(self.index, privacy: .public) progress=\(self.progress, privacy: .public) current=\(self.currentCharacter, privacy: .public)"
        )
        startTrackingOnPageTurnIfNeeded()
        forwardHistory.removeAll()
    }

    func updateStats() {
        guard enableStatistics else { return }
        let currentCharacter = currentCharacter
        let now = Date.now
        // A session belongs to the reporting day it started on. A Mac Reader can stay open
        // across the reset time, so close the old session and continue in a new one.
        if currentSession.hasActivity,
           ReadingSessionLog.dateKey(for: currentSession, resetMinutes: statisticsResetTime)
            != StatisticsDayBoundary.dateKey(for: now, resetMinutes: statisticsResetTime) {
            saveStats()
            sessionID = UUID().uuidString
            lastSavedSessionModified = 0
            currentSession = .starting(at: now)
            regroupStatisticsHistory()
        }

        let timeDiff = now.timeIntervalSince(lastTimestamp)
        let charDiff = currentCharacter - lastCount
        let finalCharDiff = max(charDiff, -currentSession.charactersRead)
        guard timeDiff > 0 else { return }
        readerStatisticsLogger.notice(
            "reader.statistics.update book=\(self.book.folder, privacy: .public) timeDiff=\(timeDiff, privacy: .public) current=\(currentCharacter, privacy: .public) last=\(self.lastCount, privacy: .public) charDiff=\(charDiff, privacy: .public) finalCharDiff=\(finalCharDiff, privacy: .public) chapter=\(self.index, privacy: .public) progress=\(self.progress, privacy: .public)"
        )
        if currentCharacter == 0, bookInfo.characterCount > 0 {
            let diagnostic = currentChapterStatisticsDiagnostic()
            readerStatisticsLogger.notice(
                "reader.statistics.zeroCharacterPosition book=\(self.book.folder, privacy: .public) chapter=\(self.index, privacy: .public) progress=\(self.progress, privacy: .public) total=\(self.bookInfo.characterCount, privacy: .public) path=\(diagnostic.path, privacy: .public) chapterCurrentTotal=\(diagnostic.currentTotal, privacy: .public) chapterCount=\(diagnostic.chapterCount, privacy: .public)"
            )
        }

        currentSession.track(characters: finalCharDiff, time: timeDiff, until: now)

        lastTimestamp = now
        lastCount = currentCharacter
    }

    func resetTrackingBaseline() {
        lastTimestamp = .now
        lastCount = currentCharacter
        readerStatisticsLogger.notice(
            "reader.statistics.baseline book=\(self.book.folder, privacy: .public) chapter=\(self.index, privacy: .public) progress=\(self.progress, privacy: .public) current=\(self.lastCount, privacy: .public)"
        )
    }

    func flushStats() {
        guard enableStatistics, isTracking, !isPaused else { return }
        readerStatisticsLogger.notice(
            "reader.statistics.flush book=\(self.book.folder, privacy: .public) chapter=\(self.index, privacy: .public) progress=\(self.progress, privacy: .public) current=\(self.currentCharacter, privacy: .public)"
        )
        updateStats()
        saveStats()
    }

    func prepareForExternalStatisticsMutation() {
        guard enableStatistics else { return }
        if isTracking, !isPaused {
            updateStats()
        }
        saveStats()
    }

    func reloadStatisticsAfterExternalMutation() {
        guard enableStatistics else { return }
        loadStatistics()
        resetTrackingBaseline()
    }

    /// Library sync applied remote statistics or highlights to this book's files. The reading
    /// position is left alone while the book is open.
    func applySyncedState(bookmarkChanged: Bool) {
        if bookmarkChanged && acceptsSyncedPosition {
            reloadBookmark()
        }
        reloadStatisticsAfterExternalMutation()
        guard let rootURL else { return }
        let stored = BookStorage.loadHighlights(root: rootURL) ?? []
        if stored != highlights {
            highlights = stored
            highlightRevision += 1
            loadRevision += 1
            isLoading = true
        }
    }

    /// The book was deleted on another device: keep this session's statistics, then close.
    func closeForSyncedDeletion() {
        prepareForReaderLifecycleClose()
        ReaderWindowPresenter.shared.closeWindow()
    }

    func reloadSyncedSasayakiMatch() {
        guard let rootURL, let match = BookStorage.loadSasayakiMatch(root: rootURL) else { return }
        sasayakiPlayer?.updateMatchData(match)
    }

    var syncFolder: String {
        book.folder
    }

    private func startStatisticsTimerIfNeeded() {
        guard statisticsTimerTask == nil else { return }
        statisticsTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, self.isTracking else { return }
                if !self.isPaused {
                    self.updateStats()
                }
            }
        }
    }

    private func stopStatisticsTimer() {
        statisticsTimerTask?.cancel()
        statisticsTimerTask = nil
    }

    func prepareForReaderLifecycleClose() {
        guard !didPrepareForReaderLifecycleClose else {
            readerPersistenceLogger.notice(
                "reader.prepareForClose.skip book=\(self.book.folder, privacy: .public)"
            )
            return
        }
        readerPersistenceLogger.notice(
            "reader.prepareForClose.start book=\(self.book.folder, privacy: .public) chapter=\(self.index, privacy: .public) progress=\(self.progress, privacy: .public) popups=\(self.popups.count, privacy: .public)"
        )
        didPrepareForReaderLifecycleClose = true
        chapterIndexGeneration = nil
        chapterIndexTask?.cancel()
        chapterIndexTask = nil
        galleryIndexGeneration = nil
        galleryIndexTask?.cancel()
        galleryIndexTask = nil
        galleryURLCacheGeneration = nil
        galleryURLCacheTask?.cancel()
        galleryURLCacheTask = nil
        galleryImageURLCache = [:]
        isGalleryIndexing = false
        flushStats()
        stopStatisticsTimer()
        sasayakiPlayer?.teardown()
    }

    func nextChapter() -> Bool {
        guard let document, index < document.spine.items.count - 1 else {
            return false
        }
        sasayakiPlayer?.prepareTransition()
        index += 1
        progress = 0
        pendingFragment = nil
        loadRevision += 1
        persistBookmark(0)
        flushStats()
        isLoading = true
        popups.removeAll()
        loadCurrentChapterState()
        return true
    }

    func previousChapter() -> Bool {
        guard index > 0 else {
            return false
        }
        sasayakiPlayer?.prepareTransition()
        index -= 1
        progress = 1
        pendingFragment = nil
        loadRevision += 1
        persistBookmark(1)
        flushStats()
        isLoading = true
        popups.removeAll()
        loadCurrentChapterState()
        return true
    }

    func jumpToCharacter(_ characterCount: Int) {
        guard let result = bookInfo.resolveCharacterPosition(characterCount) else { return }
        recordPosition()
        flushStats()
        sasayakiPlayer?.prepareTransition()
        index = result.spineIndex
        progress = result.progress
        pendingFragment = nil
        loadRevision += 1
        establishProgrammaticDestination(result.progress)
        isLoading = true
        popups.removeAll()
        loadCurrentChapterState()
    }

    func jumpToChapter(index: Int, fragment: String? = nil) {
        guard let document,
              document.spine.items.indices.contains(index) else {
            return
        }
        recordPosition()
        flushStats()
        sasayakiPlayer?.prepareTransition()
        self.index = index
        progress = 0
        pendingFragment = fragment
        loadRevision += 1
        establishProgrammaticDestination(0)
        isLoading = true
        popups.removeAll()
        loadCurrentChapterState()
    }

    func navigateBackwards() {
        guard let target = backHistory.popLast() else { return }
        forwardHistory.append(currentPosition)
        restorePosition(target)
    }

    func navigateForwards() {
        guard let target = forwardHistory.popLast() else { return }
        backHistory.append(currentPosition)
        restorePosition(target)
    }

    func removeHighlight(_ highlight: Highlight) {
        guard let rootURL else { return }
        highlights.removeAll { $0.id == highlight.id }
        try? BookStorage.save(highlights, inside: rootURL, as: FileNames.highlights)
        GoogleDriveSyncManager.shared.schedule()
        highlightRevision += 1
        loadRevision += 1
        isLoading = true
    }

    func addHighlight(_ color: HighlightColor, _ creation: HighlightData) {
        guard let range = chapterRange, let rootURL else { return }
        highlights.append(Highlight(
            id: creation.id,
            character: range.start + creation.start,
            offset: creation.offset,
            text: creation.text,
            color: color,
            createdAt: Date()
        ))
        try? BookStorage.save(highlights, inside: rootURL, as: FileNames.highlights)
        GoogleDriveSyncManager.shared.schedule()
    }

    func handleSelection(
        _ selection: SelectionData,
        userConfig: UserConfig,
        replacingExistingPopups: Bool = false,
        isVertical: Bool? = nil,
        isFullWidth: Bool? = nil
    ) -> Int? {
        if replacingExistingPopups {
            popups.removeAll()
        }

        let lookupResults = LookupEngine.shared.lookup(
            selection.text,
            maxResults: userConfig.maxResults,
            scanLength: userConfig.scanLength
        )
        guard let firstResult = lookupResults.first else {
            return nil
        }

        var dictionaryStyles: [String: String] = [:]
        for style in LookupEngine.shared.getStyles() {
            dictionaryStyles[
                String(decoding: style.dict_name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            ] = String(decoding: style.styles.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let cue = selection.normalizedOffset.flatMap { offset in
            sasayakiPlayer?.hasAudio == true ? sasayakiPlayer?.findCue(chapterIndex: index, offset: offset) : nil
        }
        let matchedText = String(decoding: firstResult.matched.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var resolvedSelection = selection
        let matchedCharacterCount = resolvedSelection.applyLookupMatch(matchedText)
        let popup = NativeReaderPopup(
            selection: resolvedSelection,
            lookupResults: lookupResults,
            dictionaryStyles: dictionaryStyles,
            isVertical: isVertical ?? userConfig.verticalWriting,
            isFullWidth: isFullWidth ?? userConfig.popupFullWidth,
            sasayakiCue: cue
        )
        popups.append(popup)

        if !lookupResults.isEmpty, sasayakiPlayer?.isPlaying == true {
            if userConfig.sasayakiAutoPause {
                sasayakiPlayer?.togglePlayback()
                wasPaused = true
            } else {
                wasPaused = false
            }
        }
        return matchedCharacterCount
    }

    func closePopup(resumePausedPlayback: Bool = true) {
        guard !popups.isEmpty else { return }
        let popupIds = Set(popups.map(\.id))
        withAnimation(.default.speed(2.4)) {
            popups = popups.map {
                var popup = $0
                popup.isVisible = false
                return popup
            }
        } completion: {
            self.popups.removeAll { popupIds.contains($0.id) }
        }
        bridge.send(.clearSelection)
        if resumePausedPlayback, wasPaused, sasayakiPlayer?.isPlaying == false {
            sasayakiPlayer?.togglePlayback()
        }
        wasPaused = false
    }

    func closeChildPopups(parent index: Int) {
        let popupIds = Set(popups.dropFirst(index + 1).map(\.id))
        guard !popupIds.isEmpty else { return }
        withAnimation(.default.speed(2.4)) {
            popups = popups.map {
                var popup = $0
                if popupIds.contains(popup.id) {
                    popup.isVisible = false
                }
                return popup
            }
        } completion: {
            self.popups.removeAll { popupIds.contains($0.id) }
        }
    }

    func dismissPopup(id: UUID, resumePausedPlayback: Bool = true) {
        guard let index = popups.firstIndex(where: { $0.id == id }),
              popups.indices.contains(index) else {
            return
        }

        if index == 0 {
            closePopup(resumePausedPlayback: resumePausedPlayback)
        } else if popups.indices.contains(index - 1) {
            popups[index - 1].clearSelection.toggle()
            closeChildPopups(parent: index - 1)
        }
    }

    func setPopupVisibility(id: UUID, isVisible: Bool) {
        guard let index = popups.firstIndex(where: { $0.id == id }) else {
            return
        }
        if isVisible {
            popups[index].isVisible = true
        } else {
            dismissPopup(id: id)
        }
    }

    func jumpToLink(_ url: URL) -> Bool {
        guard let document else { return false }
        let normalizedTarget = Self.urlWithoutFragment(url).standardizedFileURL
        let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
        for (spineIndex, spineItem) in document.spine.items.enumerated() {
            guard let item = document.manifest.items[spineItem.idref] else { continue }
            let spineURL = document.contentDirectory.appendingPathComponent(item.path).standardizedFileURL
            if spineURL == normalizedTarget {
                recordPosition()
                flushStats()
                popups.removeAll()
                if spineIndex == index {
                    if let fragment {
                        bridge.send(.jumpToFragment(fragment))
                    } else {
                        bridge.send(.restoreProgress(0))
                    }
                    return true
                }
                sasayakiPlayer?.prepareTransition()
                index = spineIndex
                progress = 0
                pendingFragment = fragment
                loadRevision += 1
                establishProgrammaticDestination(0)
                isLoading = true
                loadCurrentChapterState()
                return true
            }
        }
        return false
    }

    private func recordPosition() {
        backHistory.append(currentPosition)
        forwardHistory.removeAll()
    }

    private func restorePosition(_ position: NativeReaderPosition) {
        guard let document,
              document.spine.items.indices.contains(position.index) else {
            return
        }
        flushStats()
        sasayakiPlayer?.prepareTransition()
        index = position.index
        progress = min(max(position.progress, 0), 1)
        pendingFragment = nil
        loadRevision += 1
        establishProgrammaticDestination(progress)
        isLoading = true
        popups.removeAll()
        loadCurrentChapterState()
    }

    private func characterProgress(for position: NativeReaderPosition) -> Int? {
        guard let document,
              document.spine.items.indices.contains(position.index),
              let item = document.manifest.items[document.spine.items[position.index].idref],
              let chapterInfo = bookInfo.chapterInfo[item.path] else {
            return nil
        }
        return chapterInfo.currentTotal + Int(Double(chapterInfo.chapterCount) * position.progress)
    }

    private var rootDirectory: URL? {
        guard let booksFolder = try? BookStorage.getBooksDirectory() else {
            return nil
        }
        return booksFolder.appendingPathComponent(book.folder)
    }

    private var epubURL: URL? {
        guard let root = rootDirectory else { return nil }
        if let epub = book.epub ?? BookStorage.loadMetadata(root: root)?.epub {
            let url = root.appendingPathComponent(epub)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
        }

        let inferred = root.appendingPathComponent(root.lastPathComponent).appendingPathExtension("epub")
        if FileManager.default.fileExists(atPath: inferred.path(percentEncoded: false)) {
            return inferred
        }

        if let candidates = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ),
           let epub = candidates.first(where: { $0.pathExtension.lowercased() == "epub" }) {
            return epub
        }

        let mimetype = root.appendingPathComponent("mimetype")
        if FileManager.default.fileExists(atPath: mimetype.path(percentEncoded: false)) {
            return root
        }

        return nil
    }

    private func reloadBookmark() {
        guard let rootURL else { return }
        if let bookmark = BookStorage.loadBookmark(root: rootURL) {
            index = bookmark.chapterIndex
            progress = bookmark.progress
        }
        loadStatistics()
        if syncAudioBook {
            sasayakiPlayer?.reloadPlayback()
        }
    }

    private func setupSasayakiPlayer(rootURL: URL) {
        sasayakiPlayer = SasayakiPlayer(
            rootURL: rootURL,
            bridge: bridge,
            loadChapter: { [weak self] chapterIndex in
                self?.loadChapterForSasayaki(index: chapterIndex)
            },
            getCurrentIndex: { [weak self] in
                self?.index ?? 0
            },
            onPlayback: { [weak self] in
                guard self?.syncAudioBook == true else { return }
                self?.scheduleAutoExport()
            }
        )
    }

    private func sasayakiCueProgress(for chapterIndex: Int) -> Double? {
        guard let cue = sasayakiPlayer?.pendingCue,
              cue.chapterIndex == chapterIndex,
              let document,
              document.spine.items.indices.contains(chapterIndex),
              let item = document.manifest.items[document.spine.items[chapterIndex].idref],
              let chapterInfo = bookInfo.chapterInfo[item.path] else {
            return nil
        }
        return cue.readerProgress(chapterCharacterCount: chapterInfo.chapterCount)
    }

    private func applyLyricsCuePosition(_ cue: SasayakiMatch, persistBookmark shouldPersistBookmark: Bool) {
        guard let document,
              document.spine.items.indices.contains(cue.chapterIndex),
              let item = document.manifest.items[document.spine.items[cue.chapterIndex].idref],
              let chapterInfo = bookInfo.chapterInfo[item.path] else {
            return
        }

        let changedChapter = cue.chapterIndex != index
        let cueProgress = cue.readerProgress(chapterCharacterCount: chapterInfo.chapterCount)
        if changedChapter {
            index = cue.chapterIndex
            pendingFragment = nil
            loadRevision += 1
            isLoading = true
            popups.removeAll()
        }

        if shouldPersistBookmark {
            persistBookmark(cueProgress)
        } else {
            updateProgress(cueProgress)
            bridge.updateProgress(progress)
        }

        if changedChapter {
            loadCurrentChapterState()
        }
    }

    private func loadChapterForSasayaki(index: Int) {
        guard let document,
              document.spine.items.indices.contains(index) else {
            return
        }
        let progress = sasayakiCueProgress(for: index) ?? 0
        startTrackingOnPageTurnIfNeeded()
        flushStats()
        sasayakiPlayer?.prepareTransition()
        self.index = index
        self.progress = progress
        pendingFragment = nil
        loadRevision += 1
        establishProgrammaticDestination(progress)
        isLoading = true
        popups.removeAll()
        loadCurrentChapterState()
    }

    private func loadCurrentChapterState() {
        guard let url = currentChapterURL else { return }
        bridge.updateState(
            url: url,
            progress: progress,
            sasayakiCues: sasayakiPlayer?.hasMatch == true ? sasayakiPlayer?.cues(for: index) : nil,
            highlights: chapterHighlightsJSON()
        )
    }

    private func scheduleAutoExport() {
        GoogleDriveSyncManager.shared.schedule()
        guard autoSyncEnabled || fushiAutoSyncEnabled else { return }
        pendingAutoExport = true
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            await MainActor.run {
                self?.debounceTask = nil
            }
            await self?.runAutoExport(direction: .exportToTtu, fushiTrigger: .readerActivity)
        }
    }

    func flushAutoSync() async {
        debounceTask?.cancel()
        debounceTask = nil
        // Closing the Reader with the question still open counts as "decide later".
        if let fushiConflict {
            FushiProgressCoordinator.shared.postpone([fushiConflict])
            self.fushiConflict = nil
        }
        let didExport = await runAutoExport(direction: .exportToTtu, fushiTrigger: .readerClose)
        // A conflict deferred while reading still needs its prompt after the book
        // closes, even when nothing changed since the last export.
        if !didExport,
           fushiAutoSyncEnabled,
           FushiProgressCoordinator.shared.pendingConflict(for: book.id) != nil {
            _ = await FushiProgressCoordinator.shared.syncBook(book, trigger: .readerClose)
        }
    }

    @discardableResult
    private func runAutoExport(direction: SyncDirection?, fushiTrigger: FushiSyncTrigger) async -> Bool {
        if let exportTask {
            await exportTask.value
        }

        guard pendingAutoExport else { return false }
        pendingAutoExport = false

        let task = Task { [weak self] in
            guard let self else { return }
            if autoSyncEnabled {
                _ = try? await SyncManager.shared.syncBook(
                    book: book,
                    direction: direction,
                    syncBookData: syncBookData,
                    syncStats: syncStats,
                    statsSyncMode: statsSyncMode,
                    syncAudioBook: syncAudioBook
                )
            }
            if fushiAutoSyncEnabled {
                _ = await FushiProgressCoordinator.shared.syncBook(book, trigger: fushiTrigger)
            }
        }
        exportTask = task
        await task.value
        exportTask = nil
        return true
    }

    private func loadStatistics() {
        guard enableStatistics, let root = rootURL ?? rootDirectory else { return }
        applyStatisticsHistory(StatisticsStorage.load(root: root, resetMinutes: statisticsResetTime))
    }

    /// Mirrors upstream: the open session is never part of the history, and an
    /// external deletion of it (Statistics editor, sync replace) starts a fresh one.
    /// An external edit made after this model last saved replaces the live values.
    private func applyStatisticsHistory(_ records: ReadingSessionRecords) {
        if let record = records[sessionID] {
            if let session = record.value {
                if record.modified > lastSavedSessionModified, session != currentSession {
                    currentSession = session
                    lastSavedSessionModified = record.modified
                }
            } else {
                sessionID = UUID().uuidString
                lastSavedSessionModified = 0
                currentSession = .starting(at: .now)
            }
        }
        statisticsHistory = records
        regroupStatisticsHistory()
    }

    private func regroupStatisticsHistory() {
        let saved = statisticsHistory.filter { $0.key != sessionID }
        historyDayTotals = Dictionary(
            uniqueKeysWithValues: ReadingSessionLog.days(saved, resetMinutes: statisticsResetTime).map {
                ($0.dateKey, $0.total)
            }
        )
        historyTotal = ReadingSessionLog.total(saved)
    }

    private func saveStats() {
        guard let rootURL else { return }
        let persistedBookmark = BookStorage.loadBookmark(root: rootURL).map {
            ReaderStatisticsBookmarkSnapshot(
                chapterIndex: $0.chapterIndex,
                characterCount: $0.characterCount
            )
        }
        guard ReaderStatisticsPersistencePolicy.shouldPersist(
            modelChapterIndex: index,
            modelCharacter: currentCharacter,
            persistedBookmark: persistedBookmark
        ) else {
            readerStatisticsLogger.notice(
                "reader.statistics.save.skippedStaleModel book=\(self.book.folder, privacy: .public) model=\(self.instanceID.uuidString, privacy: .public) chapter=\(self.index, privacy: .public) current=\(self.currentCharacter, privacy: .public) persistedChapter=\(persistedBookmark?.chapterIndex ?? -1, privacy: .public) persistedCharacter=\(persistedBookmark?.characterCount ?? -1, privacy: .public)"
            )
            return
        }
        var records = StatisticsStorage.load(root: rootURL, resetMinutes: statisticsResetTime)
        applyStatisticsHistory(records)
        guard currentSession.hasActivity, records[sessionID]?.value != currentSession else { return }
        let modified = max(StatisticsClock.milliseconds(.now), lastSavedSessionModified + 1)
        records[sessionID] = Timestamped(modified: modified, value: currentSession)
        readerStatisticsLogger.notice(
            "reader.statistics.save.start book=\(self.book.folder, privacy: .public) session=\(self.sessionID, privacy: .public) characters=\(self.currentSession.charactersRead, privacy: .public) readingTime=\(self.currentSession.readingTime, privacy: .public)"
        )
        do {
            try StatisticsStorage.save(records, root: rootURL, resetMinutes: statisticsResetTime)
            statisticsHistory = records
            lastSavedSessionModified = modified
            readerStatisticsLogger.notice(
                "reader.statistics.save.success book=\(self.book.folder, privacy: .public) session=\(self.sessionID, privacy: .public)"
            )
        } catch {
            readerStatisticsLogger.error(
                "reader.statistics.save.failure book=\(self.book.folder, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func currentChapterStatisticsDiagnostic() -> (path: String, currentTotal: Int, chapterCount: Int) {
        guard let document,
              document.spine.items.indices.contains(index),
              let item = document.manifest.items[document.spine.items[index].idref] else {
            return ("missing-spine-item", -1, -1)
        }
        guard let chapterInfo = bookInfo.chapterInfo[item.path] else {
            return (item.path, -1, -1)
        }
        return (item.path, chapterInfo.currentTotal, chapterInfo.chapterCount)
    }

    private static func urlWithoutFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }
}

struct NativeReaderPopup: Identifiable {
    let id = UUID()
    let selection: SelectionData
    let lookupResults: [LookupResult]
    let dictionaryStyles: [String: String]
    let isVertical: Bool
    let isFullWidth: Bool
    var sasayakiCue: SasayakiMatch?
    var isVisible = true
    var clearSelection = false
}

struct NativeReaderView: View {
    @Environment(UserConfig.self) private var userConfig
    @Environment(ShortcutManager.self) private var shortcutManager
    @Environment(\.colorScheme) private var systemColorScheme
    let model: NativeReaderModel
    let requestID: UUID
    let isActive: Bool
    var onFocusModeChanged: (Bool) -> Void = { _ in }
    var onClose: () -> Void
    @State private var focusMode = false
    @State private var pageNavigation: NativeReaderPageNavigation?
    @State private var activeSheet: NativeReaderSheet?
    @State private var shortcutRegistrationIDs: [UUID] = []
    @State private var suppressReaderLifecycleCloseOnDisappear = false
    @State private var displayMode: ReaderDisplayMode = .novel
    @State private var readerContentSize = CGSize(width: 1_200, height: 720)
    @State private var profileRepository = ProfileRepository.shared

    private var sepiaInverted: Bool {
        userConfig.usesDarkSepia(in: systemColorScheme)
    }

    private var readerBackgroundColor: Color {
        if sepiaInverted {
            return Color(red: 0.094, green: 0.082, blue: 0.047)
        }
        if userConfig.theme == .sepia || (userConfig.theme == .system && userConfig.systemLightSepia && systemColorScheme == .light) {
            return Color(red: 0.949, green: 0.886, blue: 0.788)
        }
        return userConfig.theme == .custom ? userConfig.customBackgroundColor : Color(nsColor: .windowBackgroundColor)
    }

    private var readerTextColor: String? {
        if sepiaInverted {
            return "#F2E2C9"
        }
        if userConfig.theme == .sepia || (userConfig.theme == .system && userConfig.systemLightSepia && systemColorScheme == .light) {
            return "#332A1B"
        }
        return userConfig.theme == .custom ? nsColorHex(userConfig.customTextColor) : nil
    }

    private var readerBackgroundHex: String {
        // Resolve dynamic system colors against the Reader's own appearance,
        // not whatever drawing appearance is current while SwiftUI updates.
        let appearance = NSAppearance(named: effectiveReaderColorScheme == .dark ? .darkAqua : .aqua)
        var hex = ""
        (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            hex = nsColorHex(readerBackgroundColor)
        }
        return hex
    }

    private var readerPreferredColorScheme: ColorScheme? {
        userConfig.preferredColorScheme ?? NativeSystemAppearance.shared.colorScheme
    }

    private var effectiveReaderColorScheme: ColorScheme {
        readerPreferredColorScheme ?? systemColorScheme
    }

    private var sasayakiTextColor: String {
        effectiveReaderColorScheme == .dark ? nsColorHex(userConfig.sasayakiDarkTextColor) : nsColorHex(userConfig.sasayakiTextColor)
    }

    private var sasayakiBackgroundColor: String {
        effectiveReaderColorScheme == .dark ? nsColorHex(userConfig.sasayakiDarkBackgroundColor) : nsColorHex(userConfig.sasayakiBackgroundColor)
    }

    private var showsPageCount: Bool {
        userConfig.readerProgressCount == .pages && !userConfig.continuousMode
    }

    /// Layout inputs that change where pages break; nil when pages are not shown.
    private func pageLayoutKey(readerSize: CGSize) -> String? {
        guard showsPageCount, userConfig.readerShowProgress || userConfig.readerShowChapterProgress else { return nil }
        return [
            "pages-v1",
            "\(userConfig.verticalWriting)",
            "\(userConfig.readerTwoColumnHorizontalPages)",
            "\(userConfig.paragraphMode)",
            "\(userConfig.fontSize)",
            userConfig.selectedFont,
            "\(userConfig.readerFuriganaMode == .hidden)",
            "\(userConfig.horizontalPadding)",
            "\(userConfig.verticalPadding)",
            "\(userConfig.avoidPageBreak)",
            "\(userConfig.justifyText)",
            "\(userConfig.blurImages)",
            "\(userConfig.layoutAdvanced)",
            "\(userConfig.lineHeight)",
            "\(userConfig.characterSpacing)",
            "\(userConfig.paragraphSpacing)",
            "\(Int(readerSize.width))",
            "\(Int(readerSize.height))",
        ].joined(separator: "-")
    }

    private var progressString: String {
        var lines: [String] = []
        let pages = showsPageCount ? model.pageProgress : nil
        if userConfig.readerShowProgress {
            let line = progressLine(
                current: model.currentCharacter,
                total: model.bookInfo.characterCount,
                pages: pages.map { ($0.page, $0.total) }
            )
            if !line.isEmpty {
                lines.append(line)
            }
        }
        if userConfig.readerShowChapterProgress {
            let chapter = model.currentProgressChapterRange
            let line = progressLine(
                current: chapter.character(at: model.currentCharacter),
                total: chapter.count,
                pages: pages.map { ($0.chapterPage, $0.chapterTotal) }
            )
            if !line.isEmpty {
                lines.append("(\(line))")
            }
        }
        return lines.joined(separator: userConfig.readerShowProgressTop ? " " : "\n")
    }

    private func progressLine(current: Int, total: Int, pages: (current: Int, total: Int)?) -> String {
        var parts: [String] = []
        if showsPageCount {
            parts.append(pages.map { String(localized: "\($0.current) of \($0.total)") } ?? "…")
        } else if userConfig.readerProgressCount != .off {
            let language = profileRepository.activeProfile.language
            parts.append("\(language.displayCount(forRawCharacters: current)) / \(language.displayCount(forRawCharacters: total))")
        }
        if userConfig.readerShowPercentage {
            let percent = total > 0 ? Double(current) / Double(total) * 100 : 0
            parts.append(String(format: "%.2f%%", percent))
        }
        return parts.joined(separator: " ")
    }

    private var statisticsString: String {
        guard userConfig.enableStatistics else { return "" }
        let contentLanguage = profileRepository.activeProfile.language
        var result: [String] = []
        if userConfig.readerShowReadingSpeed {
            let speed = contentLanguage.displayCount(forRawCharacters: model.sessionStatistics.readingSpeed)
            result.append("\(speed.formatted(.number.grouping(.never))) / h")
        }
        if userConfig.readerShowReadingTime {
            result.append(Duration.seconds(model.sessionStatistics.readingTime).formatted(.time(pattern: .hourMinute)))
        }
        return result.joined(separator: " ")
    }

    private func historyTargetString(_ target: Int) -> String {
        let contentLanguage = profileRepository.activeProfile.language
        return contentLanguage.displayCount(forRawCharacters: target).formatted(.number.grouping(.never))
    }

    private var canShowLyricsMode: Bool {
        userConfig.enableSasayaki
            && model.sasayakiPlayer?.hasAudio == true
            && model.sasayakiPlayer?.hasMatch == true
    }

    private func navigateBackward() {
        pageNavigation = NativeReaderPageNavigation(direction: .backward)
    }

    private func navigateForward() {
        pageNavigation = NativeReaderPageNavigation(direction: .forward)
    }

    private func enterLyricsMode() {
        guard canShowLyricsMode else { return }
        model.resetLyricsStatisticsBaseline()
        withAnimation(.smooth(duration: 0.22)) {
            displayMode = .lyrics
        }
    }

    private func exitLyricsMode() {
        model.syncBookmarkToCurrentLyricsCue()
        withAnimation(.smooth(duration: 0.22)) {
            displayMode = .novel
        }
    }

    private func toggleLyricsMode() {
        if displayMode == .lyrics {
            exitLyricsMode()
        } else {
            enterLyricsMode()
        }
    }

    private func setFocusMode(_ enabled: Bool) {
        withAnimation(.default.speed(2)) {
            focusMode = enabled
        }
    }

    private func toggleFocusMode() {
        setFocusMode(!focusMode)
    }

    private func toggleSasayakiPlayback() {
        guard userConfig.enableSasayaki,
              model.sasayakiPlayer?.hasAudio == true else {
            return
        }
        model.wasPaused = false
        model.sasayakiPlayer?.togglePlayback()
    }

    private func playPreviousSasayakiCue() {
        guard userConfig.enableSasayaki,
              model.sasayakiPlayer?.hasAudio == true else {
            return
        }
        model.sasayakiPlayer?.prevCue()
    }

    private func playNextSasayakiCue() {
        guard userConfig.enableSasayaki,
              model.sasayakiPlayer?.hasAudio == true else {
            return
        }
        model.sasayakiPlayer?.nextCue()
    }

    private func replaySasayakiCue() {
        guard userConfig.enableSasayaki,
              model.sasayakiPlayer?.hasAudio == true,
              let cue = model.popup?.sasayakiCue else {
            return
        }

        Task { @MainActor in
            await WordAudioPlayer.shared.stop()
            model.sasayakiPlayer?.playCue(from: cue, stop: true)
        }
    }

    private func jumpToSasayakiCue() {
        guard userConfig.enableSasayaki,
              model.sasayakiPlayer?.hasAudio == true,
              let cue = model.popup?.sasayakiCue else {
            return
        }

        Task { @MainActor in
            NativeReaderLifecycleRegistry.markActive(requestID: requestID, modelID: model.instanceID)
            await WordAudioPlayer.shared.stop()
            readerPersistenceLogger.notice(
                "reader.sasayakiJumpShortcut book=\(model.book.folder, privacy: .public) cue=\(cue.id, privacy: .public) cueChapter=\(cue.chapterIndex, privacy: .public)"
            )
            model.syncBookmarkToSasayakiCue(cue)
            model.sasayakiPlayer?.playCue(from: cue, stop: false)
            model.closePopup(resumePausedPlayback: false)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let readerSize = CGSize(
                width: max(geometry.size.width.rounded(), 1),
                height: max(geometry.size.height.rounded(), 1)
            )
            let readerIdentity = [
                "\(model.index)",
                profileRepository.activeProfile.id,
                profileRepository.activeProfile.language.rawValue,
                "\(userConfig.scanNonJapaneseText)",
                "\(userConfig.scanLength)",
                "\(userConfig.desktopLookupHoverDelayMs)",
                "\(userConfig.continuousMode)",
                "\(userConfig.verticalWriting)",
                "\(userConfig.readerTwoColumnHorizontalPages)",
                "\(userConfig.paragraphMode)",
                "\(userConfig.fontSize)",
                userConfig.selectedFont,
                userConfig.readerFuriganaMode.rawValue,
                "\(userConfig.horizontalPadding)",
                "\(userConfig.verticalPadding)",
                "\(userConfig.avoidPageBreak)",
                "\(userConfig.justifyText)",
                "\(userConfig.blurImages)",
                "\(userConfig.layoutAdvanced)",
                "\(userConfig.lineHeight)",
                "\(userConfig.characterSpacing)",
                "\(userConfig.paragraphSpacing)",
                "\(model.highlightRevision)",
                "\(model.loadRevision)",
                "\(Int(readerSize.width))",
                "\(Int(readerSize.height))",
            ].joined(separator: "-")

            ZStack {
                if let chapterURL = model.currentChapterURL,
                   let readAccessURL = model.readerReadAccessURL {
                    NativeReaderWebView(
                        chapterURL: chapterURL,
                        readAccessURL: readAccessURL,
                        reloadID: readerIdentity,
                        progress: model.progress,
                        bridge: model.bridge,
                        bridgeCommandCount: model.bridge.pendingCommands.count,
                        userConfig: userConfig,
                        shortcutManager: shortcutManager,
                        viewSize: readerSize,
                        textColor: readerTextColor,
                        backgroundColor: readerBackgroundHex,
                        sasayakiTextColor: sasayakiTextColor,
                        sasayakiBackgroundColor: sasayakiBackgroundColor,
                        contentLanguageID: profileRepository.activeProfile.language.rawValue,
                        highlightsJSON: model.chapterHighlightsJSON(),
                        fragment: model.pendingFragment,
                        pageNavigation: pageNavigation,
                        pageLayoutKey: pageLayoutKey(readerSize: readerSize),
                        spineURLs: model.spineURLs,
                        pageCacheDirectory: model.rootURL,
                        onPagesChanged: model.updatePages,
                        onPageChanged: model.updateCurrentPage,
                        onNavigationHandled: { navigationID in
                            if pageNavigation?.id == navigationID {
                                pageNavigation = nil
                            }
                        },
                        onPageTurn: {
                            model.handleManualNavigation()
                        },
                        onNextChapter: model.nextChapter,
                        onPreviousChapter: model.previousChapter,
                        onProgressChanged: model.updateProgress,
                        onSaveBookmark: model.saveBookmark,
                        onInternalLink: model.jumpToLink,
                        onInternalJump: model.syncProgressAfterProgrammaticJump,
                        onTextSelected: { selection in
                            model.handleSelection(selection, userConfig: userConfig, replacingExistingPopups: true)
                        },
                        onHighlightCreated: model.addHighlight,
                        onTapOutside: {
                            if model.popup == nil {
                                toggleFocusMode()
                            } else {
                                model.closePopup()
                            }
                        },
                        onRestoreCompleted: {
                            model.handleRestoreCompleted()
                        },
                        onImageTapped: { url in
                            model.imageURL = url
                        }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(displayMode == .novel)
                }

                if displayMode == .lyrics, let player = model.sasayakiPlayer {
                    ReaderLyricsModeView(
                        player: player,
                        title: model.title,
                        coverURL: model.coverURL,
                        scanLength: userConfig.scanLength,
                        hoverLookupDelayMs: userConfig.desktopLookupHoverDelayMs,
                        isLookupPopupVisible: model.popup != nil,
                        contentLanguage: profileRepository.activeProfile.language,
                        currentCharacter: model.currentCharacter,
                        bookCharacterCount: model.bookInfo.characterCount,
                        showStatisticsMetrics: userConfig.enableStatistics,
                        showStatisticsButton: userConfig.enableStatistics,
                        isStatisticsTracking: model.isTracking,
                        sessionStatistics: model.sessionStatistics,
                        onToggleStatisticsTracking: {
                            model.toggleStatisticsTracking()
                        },
                        onExit: exitLyricsMode,
                        onCueAdvanced: { previous, cue in
                            model.handleLyricsCueDidAdvance(from: previous, to: cue)
                        },
                        onManualSeek: { cue in
                            model.resetLyricsStatisticsBaseline(to: cue)
                        },
                        onManualBaselineReset: {
                            model.resetLyricsStatisticsBaseline()
                        },
                        onTapOutside: {
                            if model.popup != nil {
                                model.closePopup()
                            }
                        },
                        onSelection: { cue, text, offset, rect, isVertical in
                            model.handleLyricsSelection(
                                text: text,
                                offset: offset,
                                rect: rect,
                                cue: cue,
                                userConfig: userConfig,
                                isVertical: isVertical
                            )
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 1.01)))
                    .ignoresSafeArea(.container, edges: .top)
                    .zIndex(50)
                }

                popupLayer(screenSize: geometry.size)

                if displayMode == .novel && model.isLoading {
                    ProgressView()
                        .controlSize(.regular)
                }
            }
            .onChange(of: readerSize, initial: true) { _, newSize in
                readerContentSize = newSize
            }
        }
        .background(readerBackgroundColor.ignoresSafeArea())
        .overlay {
            // Clicking the page closes an open side panel; it sits below the
            // bottom-right buttons so they keep toggling panels.
            if isSidePanelOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        activeSheet = nil
                    }
            }
        }
        .overlay {
            if displayMode == .novel {
                nativeReaderEdgeEffects
            }
        }
        .overlay(alignment: .top) {
            if displayMode == .novel {
                nativeTopInfoOverlay
            }
        }
        .overlay(alignment: .bottom) {
            nativeBottomControls
                .ignoresSafeArea(edges: .bottom)
                .opacity(displayMode == .novel ? 1 : 0)
                .allowsHitTesting(displayMode == .novel)
        }
        .overlay {
            if let url = model.imageURL {
                NativeFullscreenImageView(url: url, backgroundColor: readerBackgroundColor) {
                    model.imageURL = nil
                }
            }
        }
        .background {
            Color.clear
        }
        .onAppear {
            NativeReaderLifecycleRegistry.markActive(requestID: requestID, modelID: model.instanceID)
            onFocusModeChanged(focusMode)
        }
        .onChange(of: profileRepository.index.globalActiveProfileId) { _, _ in
            // Lookup results, dictionary media and Anki state belong to the
            // Profile that produced them. The WebView reload below preserves
            // progress; discard any popup stack from the previous Profile.
            model.closePopup()
        }
        .onChange(of: isActive, initial: true) { _, isActive in
            updateKeyboardShortcutRegistration(isActive: isActive)
            model.updateReaderWindowActivity(isActive)
        }
        .onChange(of: activeSheet, initial: true) { _, _ in
            updateReaderContentCoverage()
        }
        .onChange(of: model.imageURL, initial: true) { _, _ in
            updateReaderContentCoverage()
        }
        .onChange(of: canShowLyricsMode) { _, canShow in
            if !canShow && displayMode == .lyrics {
                exitLyricsMode()
            }
        }
        .onChange(of: focusMode, initial: true) { _, focusMode in
            onFocusModeChanged(focusMode)
        }
        .task {
            await model.syncOnOpenIfNeeded()
        }
        .sheet(item: Binding(
            get: { model.fushiConflict },
            set: { model.fushiConflict = $0 }
        )) { conflict in
            FushiConflictResolutionView(
                conflicts: [conflict],
                onResolved: { _, choice in
                    model.applyResolvedFushiProgress(choice)
                },
                onDismiss: {
                    model.fushiConflict = nil
                }
            )
        }
        .onDisappear {
            readerPersistenceLogger.notice(
                "reader.lifecycle.onDisappear book=\(model.book.folder, privacy: .public)"
            )
            NativeReaderLifecycleRegistry.clear(requestID: requestID, modelID: model.instanceID)
            unregisterKeyboardShortcuts()
            onFocusModeChanged(false)
            guard !suppressReaderLifecycleCloseOnDisappear else {
                readerPersistenceLogger.notice(
                    "reader.lifecycle.onDisappear.suppressed book=\(model.book.folder, privacy: .public) requestID=\(requestID.uuidString, privacy: .public)"
                )
                return
            }
            model.prepareForReaderLifecycleClose()
            NotificationCenter.default.post(name: .readerWindowProgressDidChange, object: model.book)
            Task {
                await model.flushAutoSync()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerWindowWillClose)) { notification in
            let closeRequestID = notification.userInfo?[ReaderWindowCoordinator.closeRequestIDUserInfoKey] as? UUID
            guard closeRequestID == requestID else {
                suppressReaderLifecycleCloseOnDisappear = true
                readerPersistenceLogger.notice(
                    "reader.lifecycle.windowWillClose.ignored book=\(model.book.folder, privacy: .public) requestID=\(requestID.uuidString, privacy: .public) closeRequestID=\(closeRequestID?.uuidString ?? "nil", privacy: .public)"
                )
                return
            }
            guard NativeReaderLifecycleRegistry.isActive(requestID: requestID, modelID: model.instanceID) else {
                suppressReaderLifecycleCloseOnDisappear = true
                readerPersistenceLogger.notice(
                    "reader.lifecycle.windowWillClose.ignoredInactive book=\(model.book.folder, privacy: .public) requestID=\(requestID.uuidString, privacy: .public) modelID=\(model.instanceID.uuidString, privacy: .public)"
                )
                return
            }
            readerPersistenceLogger.notice(
                "reader.lifecycle.windowWillClose.received book=\(model.book.folder, privacy: .public) requestID=\(requestID.uuidString, privacy: .public)"
            )
            model.prepareForReaderLifecycleClose()
            NotificationCenter.default.post(name: .readerWindowProgressDidChange, object: model.book)
            Task {
                await model.flushAutoSync()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            readerPersistenceLogger.notice(
                "reader.lifecycle.willTerminate book=\(model.book.folder, privacy: .public)"
            )
            model.prepareForReaderLifecycleClose()
        }
        .overlay(alignment: .leading) {
            if activeSheet == .goTo, displayMode == .novel, let document = model.document {
                NativeReaderSidePanel(edge: .leading, onClose: { activeSheet = nil }) {
                    ReaderGoToView(
                        displayTitle: model.book.displayTitle,
                        document: document,
                        bookInfo: model.bookInfo,
                        currentCharacter: model.currentCharacter,
                        contentLanguage: profileRepository.activeProfile.language,
                        coverURL: model.coverURL,
                        highlights: model.highlights,
                        onChapterJump: { spineIndex, fragment in
                            model.jumpToChapter(index: spineIndex, fragment: fragment)
                            activeSheet = nil
                        },
                        onCharacterJump: { character in
                            model.jumpToCharacter(character)
                            activeSheet = nil
                        },
                        onSearchResultJump: { result in
                            model.jumpToCharacter(result.character)
                            activeSheet = nil
                        },
                        onHighlightJump: { highlight in
                            model.jumpToCharacter(highlight.character)
                            activeSheet = nil
                        },
                        onHighlightDelete: { highlight in
                            model.removeHighlight(highlight)
                        },
                        onDismiss: {
                            activeSheet = nil
                        }
                    )
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .overlay(alignment: .trailing) {
            if displayMode == .novel, activeSheet == .appearance || activeSheet == .statistics || activeSheet == .sasayaki {
                NativeReaderSidePanel(edge: .trailing, onClose: { activeSheet = nil }) {
                    if activeSheet == .appearance {
                        VStack(spacing: 0) {
                            NativeReaderInspectorHeader(title: "Appearance", onClose: {
                                activeSheet = nil
                            })
                            NativeSettingsDetailView(section: .appearance, userConfig: userConfig)
                                .environment(\.nativeSettingsPresentation, .inspector)
                        }
                    } else if activeSheet == .sasayaki {
                        if let player = model.sasayakiPlayer {
                            SasayakiSheet(
                                player: player,
                                bookTitle: model.title,
                                bookCoverURL: model.coverURL,
                                onImportAudio: model.importSasayakiAudio,
                                onDismiss: {
                                    activeSheet = nil
                                }
                            )
                        }
                    } else {
                        NativeReaderStatisticsSheet(
                            model: model,
                            contentLanguage: profileRepository.activeProfile.language,
                            onClose: {
                                activeSheet = nil
                            }
                        )
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.22), value: activeSheet)
        .modifier(NativeReaderEscapeDismissal(isActive: activeSheet != nil) {
            activeSheet = nil
        })
        .overlay {
            if activeSheet == .gallery {
                GalleryView(
                    images: model.galleryImages,
                    isLoading: model.isGalleryIndexing,
                    backgroundColor: readerBackgroundColor,
                    onDismiss: {
                        activeSheet = nil
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(200)
            }
        }
        .preferredColorScheme(readerPreferredColorScheme)
    }

    private var isSidePanelOpen: Bool {
        switch activeSheet {
        case .goTo, .appearance, .statistics, .sasayaki: displayMode == .novel
        case .gallery, nil: false
        }
    }

    private func toggleSidePanel(_ sheet: NativeReaderSheet) {
        activeSheet = activeSheet == sheet ? nil : sheet
    }

    private func updateReaderContentCoverage() {
        let nonStatisticsSheetIsOpen = activeSheet != nil && activeSheet != .statistics
        model.updateReaderContentCovered(nonStatisticsSheetIsOpen || model.imageURL != nil)
    }

    @ViewBuilder
    private func popupLayer(screenSize: CGSize) -> some View {
        ForEach(model.popups) { popup in
            let popupId = popup.id
            PopupView(
                userConfig: userConfig,
                isVisible: Binding(
                    get: {
                        model.popups.first(where: { $0.id == popupId })?.isVisible ?? false
                    },
                    set: { visible in
                        model.setPopupVisibility(id: popupId, isVisible: visible)
                    }
                ),
                selectionData: popup.selection,
                lookupResults: popup.lookupResults,
                dictionaryStyles: popup.dictionaryStyles,
                screenSize: screenSize,
                isVertical: popup.isVertical,
                isFullWidth: popup.isFullWidth,
                coverURL: model.coverURL,
                documentTitle: model.title,
                profileID: profileRepository.activeProfile.id,
                clearSelection: popup.clearSelection,
                onTextSelected: { selection in
                    if let index = model.popups.firstIndex(where: { $0.id == popupId }) {
                        model.closeChildPopups(parent: index)
                    }
                    return model.handleSelection(
                        selection,
                        userConfig: userConfig,
                        isVertical: false,
                        isFullWidth: false
                    )
                },
                onTapOutside: {
                    if let index = model.popups.firstIndex(where: { $0.id == popupId }) {
                        model.closeChildPopups(parent: index)
                    }
                },
                onSwipeDismiss: {
                    model.dismissPopup(id: popupId)
                },
                onSasayakiJumpDismiss: {
                    if let cue = popup.sasayakiCue {
                        model.syncBookmarkToSasayakiCue(cue)
                    }
                    model.dismissPopup(id: popupId, resumePausedPlayback: false)
                },
                onPause: {
                    model.wasPaused = false
                },
                sasayakiCue: popup.sasayakiCue,
                sasayakiPlayer: model.sasayakiPlayer,
                wasPaused: model.wasPaused
            )
            .id(popup.id)
            .zIndex(Double(100 + (model.popups.firstIndex(where: { $0.id == popupId }) ?? 0)))
        }
    }

    /// Mirrors upstream's iOS 26 top/bottom scroll edge effects under the
    /// reader bars: shown with the bars, hidden in focus mode and while an
    /// image is open. Drawn over the web view only, so layout never changes.
    @ViewBuilder
    private var nativeReaderEdgeEffects: some View {
        if !focusMode && model.imageURL == nil {
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: readerBackgroundColor, location: 0),
                        .init(color: readerBackgroundColor.opacity(0.92), location: 0.55),
                        .init(color: readerBackgroundColor.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 76)
                Spacer(minLength: 0)
                LinearGradient(
                    stops: [
                        .init(color: readerBackgroundColor.opacity(0), location: 0),
                        .init(color: readerBackgroundColor.opacity(0.92), location: 0.45),
                        .init(color: readerBackgroundColor, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 76)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var readerInfoPrimaryStyle: AnyShapeStyle {
        userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor) : AnyShapeStyle(.primary)
    }

    private var readerInfoSecondaryStyle: AnyShapeStyle {
        userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor) : AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private var nativeTopInfoOverlay: some View {
        if !focusMode {
            let showTitle = userConfig.readerShowTitle
            let showProgress = userConfig.readerShowProgressTop && !progressString.isEmpty

            if showTitle || showProgress {
                VStack(alignment: .center, spacing: 2) {
                    if showTitle {
                        Text(model.title)
                            .font(.headline)
                            .foregroundStyle(readerInfoPrimaryStyle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if showProgress {
                        Text(progressString)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(readerInfoSecondaryStyle)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 96)
                .padding(.top, 10)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var nativeBottomInfoOverlay: some View {
        if !focusMode {
            let showStatistics = !statisticsString.isEmpty
            let showProgress = !userConfig.readerShowProgressTop && !progressString.isEmpty

            if showStatistics || showProgress {
                VStack(alignment: .center, spacing: 2) {
                    if showStatistics {
                        Text(statisticsString)
                    }
                    if showProgress {
                        Text(progressString)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(readerInfoSecondaryStyle)
                .multilineTextAlignment(.center)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var nativeBottomControls: some View {
        if !focusMode {
            ZStack {
                nativeBottomInfoOverlay

                HStack {
                    HStack(spacing: 8) {
                        if let target = model.backTarget {
                            Button {
                                model.navigateBackwards()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                    Text(historyTargetString(target))
                                }
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                            }
                            .buttonStyle(.plain)
                            .nativeReaderGlassCapsuleControl()
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if let target = model.forwardTarget {
                            Button {
                                model.navigateForwards()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(historyTargetString(target))
                                    Image(systemName: "arrow.uturn.right.circle")
                                }
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                            }
                            .buttonStyle(.plain)
                            .nativeReaderGlassCapsuleControl()
                        }

                        if userConfig.enableStatistics && userConfig.readerShowStatisticsToggle {
                            NativeReaderGlassIconButton(systemName: model.isTracking ? "timer" : "chart.xyaxis.line", fontSize: 16) {
                                model.toggleStatisticsTracking()
                            }
                        }

                        if userConfig.enableSasayaki && userConfig.readerShowSasayakiToggle && model.sasayakiPlayer?.hasAudio == true {
                            NativeReaderGlassIconButton(
                                systemName: model.sasayakiPlayer?.isPlaying == true || model.wasPaused ? "pause.fill" : "waveform",
                                fontSize: 16
                            ) {
                                toggleSasayakiPlayback()
                            }
                        }

                        if canShowLyricsMode {
                            NativeReaderGlassIconButton(systemName: "music.note.list", fontSize: 16) {
                                enterLyricsMode()
                            }
                            .help(Text("Open Lyrics Mode"))
                        }

                        NativeReaderGlassIconButton(systemName: "list.bullet", fontSize: 16) {
                            toggleSidePanel(.goTo)
                        }
                        .help(Text("Go to"))
                        .accessibilityLabel(Text("Go to"))

                        NativeReaderGlassIconButton(systemName: "paintpalette", fontSize: 16) {
                            toggleSidePanel(.appearance)
                        }
                        .help(Text("Appearance"))
                        .accessibilityLabel(Text("Appearance"))

                        if userConfig.enableStatistics {
                            NativeReaderGlassIconButton(systemName: "chart.bar.xaxis", fontSize: 16) {
                                toggleSidePanel(.statistics)
                            }
                            .help(Text("Statistics"))
                            .accessibilityLabel(Text("Statistics"))
                        }

                        NativeReaderGlassIconButton(systemName: "photo.on.rectangle", fontSize: 16) {
                            activeSheet = .gallery
                        }
                        .help(Text("Gallery"))
                        .accessibilityLabel(Text("Gallery"))

                        if userConfig.enableSasayaki && model.sasayakiPlayer != nil {
                            NativeReaderGlassIconButton(systemName: "headphones", fontSize: 16) {
                                activeSheet = .sasayaki
                            }
                            .help(Text("Sasayaki"))
                            .accessibilityLabel(Text("Sasayaki"))
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 18)
        }
    }

    private var readerShortcutHandlers: [String: ShortcutHandler] {
        [
            ReaderShortcutActions.previousPage.id: handleReaderPreviousPageShortcut,
            ReaderShortcutActions.nextPage.id: handleReaderNextPageShortcut,
            ReaderShortcutActions.close.id: handleReaderCloseShortcut,
            ReaderShortcutActions.toggleFocusMode.id: handleReaderToggleFocusModeShortcut,
            ReaderShortcutActions.toggleStatistics.id: handleReaderToggleStatisticsShortcut,
            ReaderShortcutActions.toggleLyricsMode.id: handleReaderToggleLyricsModeShortcut
        ]
    }

    private var sasayakiShortcutHandlers: [String: ShortcutHandler] {
        [
            SasayakiShortcutActions.previousCue.id: handleSasayakiPreviousCueShortcut,
            SasayakiShortcutActions.playPause.id: handleSasayakiPlayPauseShortcut,
            SasayakiShortcutActions.nextCue.id: handleSasayakiNextCueShortcut,
            SasayakiShortcutActions.replayCue.id: handleSasayakiReplayCueShortcut,
            SasayakiShortcutActions.jumpCue.id: handleSasayakiJumpCueShortcut
        ]
    }

    private func handleReaderPreviousPageShortcut() -> Bool {
        guard activeSheet == nil, model.imageURL == nil else { return false }
        guard displayMode == .novel else { return false }
        navigateBackward()
        return true
    }

    private func handleReaderNextPageShortcut() -> Bool {
        guard activeSheet == nil, model.imageURL == nil else { return false }
        guard displayMode == .novel else { return false }
        navigateForward()
        return true
    }

    private func handleReaderCloseShortcut() -> Bool {
        guard activeSheet == nil else { return false }
        if displayMode == .lyrics {
            exitLyricsMode()
            return true
        }
        if model.imageURL != nil {
            model.imageURL = nil
        } else {
            onClose()
        }
        return true
    }

    private func handleReaderToggleFocusModeShortcut() -> Bool {
        guard activeSheet == nil else { return false }
        toggleFocusMode()
        return true
    }

    private func handleReaderToggleStatisticsShortcut() -> Bool {
        guard activeSheet == nil, model.imageURL == nil else { return false }
        model.toggleStatisticsTracking()
        return true
    }

    private func handleReaderToggleLyricsModeShortcut() -> Bool {
        guard activeSheet == nil, model.imageURL == nil, canShowLyricsMode else { return false }
        toggleLyricsMode()
        return true
    }

    private func handleSasayakiPreviousCueShortcut() -> Bool {
        guard canHandleSasayakiShortcut else { return false }
        playPreviousSasayakiCue()
        return true
    }

    private func handleSasayakiPlayPauseShortcut() -> Bool {
        guard canHandleSasayakiShortcut else { return false }
        toggleSasayakiPlayback()
        return true
    }

    private func handleSasayakiNextCueShortcut() -> Bool {
        guard canHandleSasayakiShortcut else { return false }
        playNextSasayakiCue()
        return true
    }

    private func handleSasayakiReplayCueShortcut() -> Bool {
        guard canHandleSasayakiShortcut, model.popup?.sasayakiCue != nil else {
            return false
        }
        replaySasayakiCue()
        return true
    }

    private func handleSasayakiJumpCueShortcut() -> Bool {
        guard canHandleSasayakiShortcut, model.popup?.sasayakiCue != nil else {
            return false
        }
        jumpToSasayakiCue()
        return true
    }

    private func registerKeyboardShortcuts() {
        guard shortcutRegistrationIDs.isEmpty else { return }

        shortcutRegistrationIDs = [
            shortcutManager.register(
                scope: .popup,
                handlers: [
                    PopupShortcutActions.dismiss.id: {
                        guard let popup = model.popups.last else { return false }
                        model.dismissPopup(id: popup.id)
                        return true
                    }
                ]
            ),
            shortcutManager.register(
                scope: .reader,
                handlers: readerShortcutHandlers
            ),
            shortcutManager.register(
                scope: .sasayaki,
                handlers: sasayakiShortcutHandlers
            )
        ]
    }

    private func updateKeyboardShortcutRegistration(isActive: Bool) {
        if isActive {
            registerKeyboardShortcuts()
        } else {
            unregisterKeyboardShortcuts()
        }
    }

    private var canHandleSasayakiShortcut: Bool {
        (activeSheet == nil || activeSheet == .sasayaki)
            && userConfig.enableSasayaki
            && model.sasayakiPlayer?.hasAudio == true
    }

    private func unregisterKeyboardShortcuts() {
        shortcutRegistrationIDs.forEach(shortcutManager.unregister)
        shortcutRegistrationIDs.removeAll()
    }
}

private struct ReaderLyricsModeView: View {
    let player: SasayakiPlayer
    let title: String
    let coverURL: URL?
    let scanLength: Int
    let hoverLookupDelayMs: Int
    let isLookupPopupVisible: Bool
    let contentLanguage: ContentLanguageProfile
    let currentCharacter: Int
    let bookCharacterCount: Int
    let showStatisticsMetrics: Bool
    let showStatisticsButton: Bool
    let isStatisticsTracking: Bool
    let sessionStatistics: ReadingTotal
    var onToggleStatisticsTracking: () -> Void
    var onExit: () -> Void
    var onCueAdvanced: (SasayakiMatch?, SasayakiMatch) -> Void
    var onManualSeek: (SasayakiMatch) -> Void
    var onManualBaselineReset: () -> Void
    var onTapOutside: () -> Void
    var onSelection: (SasayakiMatch, String, Int, CGRect, Bool?) -> Int?

    @State private var lastReportedCue: SasayakiMatch?
    @State private var pendingManualCueID: String?
    @State private var suppressNextCueAdvance = false
    @State private var coverImage: NSImage?
    @State private var heldLyricsCue: SasayakiMatch?
    @State private var isVerticalLyricsMode = false
    @State private var isLyricsMaskEnabled = false
    @State private var hoveredLyricsCueID: String?
    /// Apple Music style follow state: scrolling the full cue list by hand
    /// detaches it from playback until the user returns or the delay elapses.
    @State private var isFollowingPlayback = true
    @State private var followResumeTask: Task<Void, Never>?
    @State private var lyricsScrollRequest = ReaderLyricsScrollRequest()
    @State private var animatesNextFollowScroll = false
    @State private var scrubbingTime: Double?
    @State private var isHoveringScrubber = false

    private let lyricsScrollAnchor = UnitPoint(x: 0.5, y: ReaderLyricsVisualSpec.selectedLineAnchorY)
    private let verticalLyricsScrollAnchor = UnitPoint(x: 0.5, y: 0.5)

    private var activeLyricsCue: SasayakiMatch? {
        player.currentCue ?? heldLyricsCue
    }

    private var lyricsCues: [SasayakiMatch] {
        player.matchData?.matches ?? []
    }

    private var activeLyricsIndex: Int? {
        activeLyricsCue.flatMap(lyricsCueIndex(of:))
    }

    var body: some View {
        GeometryReader { geometry in
            let layoutMetrics = ReaderLyricsLayoutMetrics(size: geometry.size)
            let topSafeArea = geometry.safeAreaInsets.top
            let backgroundHeight = geometry.size.height + topSafeArea
            let contentWidth = max(geometry.size.width - layoutMetrics.chromeHorizontalPadding * 2, 1)
            let contentHeight = max(geometry.size.height - layoutMetrics.headerTopPadding * 2, 1)

            ZStack {
                lyricsBackground
                    .frame(width: geometry.size.width, height: backgroundHeight)
                    .offset(y: -topSafeArea)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTapOutside()
                    }

                lyricsContent(metrics: layoutMetrics)
                    .frame(width: contentWidth, height: contentHeight)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .zIndex(2)

                lyricsCloseButton
                    .padding(.top, layoutMetrics.headerTopPadding)
                    .padding(.trailing, layoutMetrics.chromeHorizontalPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(4)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .coordinateSpace(name: "reader-lyrics")
        .onAppear {
            loadCoverImage()
            updateHeldLyricsCueForPlaybackPosition()
            handleCurrentCueChange(player.currentCue)
        }
        .onDisappear {
            followResumeTask?.cancel()
            followResumeTask = nil
        }
        .onChange(of: coverURL) { _, _ in
            loadCoverImage()
        }
        .onChange(of: player.currentCue?.id) { _, _ in
            updateHeldLyricsCue(player.currentCue)
            handleCurrentCueChange(player.currentCue)
        }
        .onChange(of: player.currentTime) { _, _ in
            updateHeldLyricsCueForPlaybackPosition()
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if isPlaying, !isFollowingPlayback {
                scheduleFollowResume()
            }
        }
    }

    @ViewBuilder
    private var lyricsBackground: some View {
        ZStack {
            Color.black
            if let image = coverImage {
                GeometryReader { proxy in
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width * 1.25, height: proxy.size.height * 1.25)
                            .blur(radius: 72)
                            .saturation(1.6)
                            .opacity(0.6)
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width * 0.9, height: proxy.size.height * 0.9)
                            .rotationEffect(.degrees(180))
                            .offset(x: proxy.size.width * 0.24, y: proxy.size.height * 0.2)
                            .blur(radius: 96)
                            .saturation(1.5)
                            .opacity(0.38)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .drawingGroup()
            }
            LinearGradient(
                colors: [
                    Color.black.opacity(0.2),
                    Color.black.opacity(0.46),
                    Color.black.opacity(0.74)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var lyricsCloseButton: some View {
        LyricsPlayerIconButton(systemName: "xmark", diameter: 38, fontSize: 18) {
            onExit()
        }
        .foregroundStyle(.white.opacity(0.74))
        .help(Text("Exit Lyrics Mode"))
    }

    private func lyricsContent(metrics: ReaderLyricsLayoutMetrics) -> some View {
        GeometryReader { geometry in
            let availableWidth = max(geometry.size.width, 1)
            let availableHeight = max(geometry.size.height, 1)
            let panelWidth = playerPanelWidth(metrics: metrics, availableWidth: availableWidth)
            let spacing = playerLyricsSpacing(metrics: metrics, availableWidth: availableWidth)
            let lyricsWidth = lyricsColumnWidth(
                metrics: metrics,
                availableWidth: availableWidth,
                panelWidth: panelWidth,
                spacing: spacing
            )
            let lyricsHeight = availableHeight

            HStack(alignment: .center, spacing: spacing) {
                playerPanel(metrics: metrics, availableHeight: availableHeight, panelWidth: panelWidth)
                    .frame(width: panelWidth, height: availableHeight, alignment: .center)

                lyricsStack(
                    metrics: metrics,
                    availableWidth: lyricsWidth,
                    availableHeight: lyricsHeight
                )
                    .frame(width: lyricsWidth, height: lyricsHeight, alignment: .center)
                    .overlay(alignment: .bottom) {
                        followPlaybackButton
                    }
            }
            .frame(width: availableWidth, height: availableHeight, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func lyricsStack(
        metrics: ReaderLyricsLayoutMetrics,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        if isVerticalLyricsMode {
            verticalLyricsStack(
                metrics: metrics,
                availableWidth: availableWidth,
                availableHeight: availableHeight
            )
        } else {
            horizontalLyricsStack(metrics: metrics, availableWidth: availableWidth, availableHeight: availableHeight)
        }
    }

    /// Every matched cue stays in one lazily rendered list, so the reader can
    /// scroll back and forth through the whole book like synced song lyrics.
    private func horizontalLyricsStack(
        metrics: ReaderLyricsLayoutMetrics,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let cues = lyricsCues
        let activeIndex = activeLyricsIndex
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: ReaderLyricsVisualSpec.listRowSpacing) {
                    ForEach(cues.indices, id: \.self) { index in
                        lyricsLine(
                            cues[index],
                            index: index,
                            activeIndex: activeIndex,
                            metrics: metrics,
                            availableWidth: availableWidth
                        )
                            .id(index)
                    }
                }
                .padding(.top, availableHeight * ReaderLyricsVisualSpec.selectedLineAnchorY)
                .padding(.bottom, availableHeight * (1 - ReaderLyricsVisualSpec.selectedLineAnchorY))
            }
            .scrollIndicators(.never)
            .mask(lyricsEdgeFade(axis: .vertical))
            .overlay {
                if cues.isEmpty {
                    emptyLyricsState(metrics: metrics)
                }
            }
            .onScrollPhaseChange { _, phase in
                handleLyricsScrollPhase(phase)
            }
            .onAppear { scrollLyrics(with: proxy, animated: false) }
            .onChange(of: lyricsScrollRequest) { _, request in
                scrollLyrics(with: proxy, animated: request.animated)
            }
            .onChange(of: activeIndex) { previousIndex, index in
                followActiveCue(from: previousIndex, to: index)
            }
            .onChange(of: availableWidth) { _, _ in
                scrollLyrics(with: proxy, animated: false)
            }
            .onChange(of: availableHeight) { _, _ in
                scrollLyrics(with: proxy, animated: false)
            }
        }
    }

    /// Vertical writing keeps the same full cue list, laid out as columns that
    /// read right to left and scroll horizontally.
    private func verticalLyricsStack(
        metrics: ReaderLyricsLayoutMetrics,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let cues = lyricsCues
        let activeIndex = activeLyricsIndex
        let columnHeight = max(availableHeight - ReaderLyricsVisualSpec.listRowVerticalPadding * 2, 1)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .center, spacing: verticalLyricsColumnSpacing(metrics: metrics)) {
                    ForEach(cues.indices.reversed(), id: \.self) { index in
                        verticalLyricsLine(
                            cues[index],
                            index: index,
                            activeIndex: activeIndex,
                            metrics: metrics,
                            availableHeight: columnHeight
                        )
                            .id(index)
                    }
                }
                .padding(.horizontal, availableWidth / 2)
                .frame(height: availableHeight)
            }
            .scrollIndicators(.never)
            .mask(lyricsEdgeFade(axis: .horizontal))
            .overlay {
                if cues.isEmpty {
                    emptyLyricsState(metrics: metrics)
                }
            }
            .onScrollPhaseChange { _, phase in
                handleLyricsScrollPhase(phase)
            }
            .onAppear { scrollLyrics(with: proxy, animated: false) }
            .onChange(of: lyricsScrollRequest) { _, request in
                scrollLyrics(with: proxy, animated: request.animated)
            }
            .onChange(of: activeIndex) { previousIndex, index in
                followActiveCue(from: previousIndex, to: index)
            }
            .onChange(of: availableWidth) { _, _ in
                scrollLyrics(with: proxy, animated: false)
            }
            .onChange(of: availableHeight) { _, _ in
                scrollLyrics(with: proxy, animated: false)
            }
        }
    }

    /// Lines fade out toward the list edges instead of being cut off.
    private func lyricsEdgeFade(axis: Axis) -> some View {
        let fade = ReaderLyricsVisualSpec.listEdgeFadeFraction
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: fade),
                .init(color: .black, location: 1 - fade),
                .init(color: .clear, location: 1)
            ],
            startPoint: axis == .vertical ? .top : .leading,
            endPoint: axis == .vertical ? .bottom : .trailing
        )
    }

    private func emptyLyricsState(metrics: ReaderLyricsLayoutMetrics) -> some View {
        Text("No lyrics match")
            .font(.system(size: metrics.emptyStateFontSize, weight: .bold))
            .foregroundStyle(.white.opacity(0.64))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func verticalLyricsColumnSpacing(metrics: ReaderLyricsLayoutMetrics) -> CGFloat {
        min(max(metrics.lineSpacing * 0.4, 6), 12)
    }

    private func verticalLyricsFontSize(
        for cue: SasayakiMatch,
        metrics: ReaderLyricsLayoutMetrics,
        availableHeight: CGFloat
    ) -> CGFloat {
        ReaderLyricsVerticalTextLayout.fittedFontSize(
            text: cue.text,
            baseFontSize: metrics.lyricsListFontSize,
            availableHeight: availableHeight,
            availableWidth: nil,
            minimumFontSize: ReaderLyricsVisualSpec.minimumContextFittedFontSize
        )
    }

    private func verticalLyricsLineWidth(
        for cue: SasayakiMatch,
        metrics: ReaderLyricsLayoutMetrics,
        availableHeight: CGFloat
    ) -> CGFloat {
        let fontSize = verticalLyricsFontSize(for: cue, metrics: metrics, availableHeight: availableHeight)
        return max(
            ReaderLyricsVerticalTextLayout.contentWidth(
                glyphCount: ReaderLyricsVerticalTextLayout.glyphs(from: cue.text).count,
                fontSize: fontSize,
                availableHeight: availableHeight,
                columnWidth: ReaderLyricsVerticalTextLayout.columnWidth(fontSize: fontSize),
                columnSpacing: ReaderLyricsVerticalTextLayout.columnSpacing(fontSize: fontSize)
            ),
            ReaderLyricsVerticalTextLayout.columnWidth(fontSize: fontSize)
        )
    }

    private func verticalLyricsLine(
        _ cue: SasayakiMatch,
        index: Int,
        activeIndex: Int?,
        metrics: ReaderLyricsLayoutMetrics,
        availableHeight: CGFloat
    ) -> some View {
        let isFocused = cue.id == activeLyricsCue?.id
        let isHovered = hoveredLyricsCueID == cue.id
        let fontSize = verticalLyricsFontSize(for: cue, metrics: metrics, availableHeight: availableHeight)
        let lineWidth = verticalLyricsLineWidth(for: cue, metrics: metrics, availableHeight: availableHeight)
        let isMasked = isLyricsMaskVisible(for: cue)
        return ReaderLyricsVerticalSelectableTextView(
            text: cue.text,
            scanLength: scanLength,
            fontSize: fontSize,
            weight: .bold,
            textColor: .white.opacity(0.98),
            lookupHighlightColor: .white.opacity(0.18),
            lookupHighlightTextColor: .white,
            hoverLookupDelayMs: hoverLookupDelayMs,
            isLookupPopupVisible: isLookupPopupVisible
        ) { text, offset, selectionRect in
            return onSelection(cue, text, offset, selectionRect, false)
        }
        .frame(width: lineWidth, height: availableHeight)
        .opacity(isMasked ? 0 : 1)
        .overlay {
            if isMasked {
                maskedVerticalLyricsText(cue, fontSize: fontSize, isFocused: isFocused, availableHeight: availableHeight)
            }
        }
        .padding(.horizontal, ReaderLyricsVisualSpec.listRowVerticalPadding)
        .padding(.vertical, ReaderLyricsVisualSpec.listRowVerticalPadding)
        .background {
            lyricsLineHoverBackground(isHighlighted: isHovered && !isFocused)
            if !isFocused {
                contextLyricsLineTapTarget(for: cue)
            }
        }
        .scaleEffect(isFocused ? 1 : ReaderLyricsVisualSpec.listDeselectedLineScale, anchor: .top)
        .opacity(lyricsLineOpacity(index: index, activeIndex: activeIndex, isFocused: isFocused, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hovering in
            updateLyricsMaskHover(hovering, cue: cue)
        }
        .animation(.smooth(duration: 0.12), value: isMasked)
        .animation(.smooth(duration: 0.18), value: isHovered)
        .animation(.smooth(duration: 0.3), value: isFollowingPlayback)
        .animation(ReaderLyricsVisualSpec.highlightAnimation(highlighted: isFocused), value: isFocused)
    }

    private func lyricsLine(
        _ cue: SasayakiMatch,
        index: Int,
        activeIndex: Int?,
        metrics: ReaderLyricsLayoutMetrics,
        availableWidth: CGFloat
    ) -> some View {
        let isFocused = cue.id == activeLyricsCue?.id
        let isHovered = hoveredLyricsCueID == cue.id
        let isRightToLeft = ReaderLyricsTextDirection.isRightToLeft(cue.text)
        let fontSize = metrics.lyricsListFontSize
        let textWidth = horizontalLyricsTextWidth(availableWidth: availableWidth)
        let isMasked = isLyricsMaskVisible(for: cue)
        return ReaderLyricsSelectableTextView(
            text: cue.text,
            scanLength: scanLength,
            fontSize: fontSize,
            layoutWidth: textWidth,
            weight: .bold,
            textColor: .white.opacity(0.98),
            upcomingTextColor: .white.opacity(isFocused ? 0.4 : 0.98),
            // A paused current line stays fully lit; the sweep only runs during playback.
            progressFraction: isFocused && player.isPlaying ? lineProgress(for: cue) : 1,
            progressRatePerSecond: isFocused ? progressRate(for: cue) : 0,
            isProgressAnimating: isFocused && player.isPlaying && cue.id == player.currentCue?.id,
            lookupHighlightColor: .white.opacity(0.18),
            lookupHighlightTextColor: .white,
            hoverLookupDelayMs: hoverLookupDelayMs,
            isLookupPopupVisible: isLookupPopupVisible
        ) { text, offset, selectionRect in
            return onSelection(cue, text, offset, selectionRect, false)
        }
        .frame(width: textWidth, height: horizontalLyricsRowHeight(cue, metrics: metrics, availableWidth: availableWidth))
        .opacity(isMasked ? 0 : 1)
        .overlay {
            if isMasked {
                maskedHorizontalLyricsText(cue, fontSize: fontSize, isFocused: isFocused, isRightToLeft: isRightToLeft)
            }
        }
        .padding(.horizontal, ReaderLyricsVisualSpec.listRowHorizontalPadding)
        .padding(.vertical, ReaderLyricsVisualSpec.listRowVerticalPadding)
        .frame(width: availableWidth, alignment: isRightToLeft ? .trailing : .leading)
        .background {
            lyricsLineHoverBackground(isHighlighted: isHovered && !isFocused)
            if !isFocused {
                contextLyricsLineTapTarget(for: cue)
            }
        }
        .scaleEffect(
            isFocused ? 1 : ReaderLyricsVisualSpec.listDeselectedLineScale,
            anchor: isRightToLeft ? .trailing : .leading
        )
        .opacity(lyricsLineOpacity(index: index, activeIndex: activeIndex, isFocused: isFocused, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hovering in
            updateLyricsMaskHover(hovering, cue: cue)
        }
        .animation(.smooth(duration: 0.12), value: isMasked)
        .animation(.smooth(duration: 0.18), value: isHovered)
        .animation(.smooth(duration: 0.3), value: isFollowingPlayback)
        .animation(ReaderLyricsVisualSpec.highlightAnimation(highlighted: isFocused), value: isFocused)
    }

    private func contextLyricsLineTapTarget(for cue: SasayakiMatch) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                pendingManualCueID = cue.id
                onManualSeek(cue)
                player.seekToCue(cue, startPlayback: true)
                followResumeTask?.cancel()
                followResumeTask = nil
                animatesNextFollowScroll = true
                isFollowingPlayback = true
            }
    }

    private func lyricsLineHoverBackground(isHighlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: ReaderLyricsVisualSpec.listRowHoverCornerRadius, style: .continuous)
            .fill(.white.opacity(isHighlighted ? 0.08 : 0))
    }

    private func lyricsLineOpacity(index: Int, activeIndex: Int?, isFocused: Bool, isHovered: Bool) -> Double {
        if isFocused {
            return 1
        }
        let restingOpacity: Double
        if isFollowingPlayback, let activeIndex {
            let opacities = ReaderLyricsVisualSpec.contextLineOpacities
            let distance = min(max(abs(index - activeIndex), 1), opacities.count)
            restingOpacity = opacities[distance - 1]
        } else {
            restingOpacity = ReaderLyricsVisualSpec.browsingLineOpacity
        }
        return isHovered ? max(restingOpacity, ReaderLyricsVisualSpec.hoveredLineOpacity) : restingOpacity
    }

    private func horizontalLyricsTextWidth(availableWidth: CGFloat) -> CGFloat {
        max(availableWidth - ReaderLyricsVisualSpec.listRowHorizontalPadding * 2, 1)
    }

    private func horizontalLyricsRowHeight(
        _ cue: SasayakiMatch,
        metrics: ReaderLyricsLayoutMetrics,
        availableWidth: CGFloat
    ) -> CGFloat {
        ReaderLyricsHorizontalTextLayout.measuredHeight(text: cue.text, fontSize: metrics.lyricsListFontSize,
                                                       weight: .bold,
                                                       width: horizontalLyricsTextWidth(availableWidth: availableWidth))
    }

    @ViewBuilder
    private var followPlaybackButton: some View {
        if !isFollowingPlayback, activeLyricsIndex != nil {
            Button {
                resumeFollowingPlayback()
            } label: {
                Label("Back to Current Line", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.92))
            .glassEffect(.regular.interactive(), in: Capsule())
            .environment(\.colorScheme, .dark)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func playerPanel(
        metrics: ReaderLyricsLayoutMetrics,
        availableHeight: CGFloat,
        panelWidth: CGFloat
    ) -> some View {
        let panelSpacing = playerPanelSpacing(metrics: metrics, availableHeight: availableHeight)
        let metadataHeight = playerMetadataHeight(availableHeight: availableHeight)
        return VStack(alignment: .leading, spacing: panelSpacing) {
            lyricsArtwork(metrics: metrics, availableHeight: availableHeight, panelWidth: panelWidth)
                .frame(maxWidth: .infinity, alignment: .center)

            lyricsPlayerMetadata
                .frame(height: metadataHeight, alignment: .bottomLeading)
                .clipped()

            lyricsScrubber
                .frame(height: ReaderLyricsVisualSpec.scrubberHeight)

            HStack(spacing: playerControlSpacing(metrics: metrics, availableWidth: panelWidth)) {
                LyricsPlayerIconButton(systemName: "backward.end.fill", diameter: 48, fontSize: 28) {
                    suppressNextCueAdvance = true
                    onManualBaselineReset()
                    player.prevCue()
                }
                .help(Text("Previous Cue"))
                LyricsPlayerIconButton(
                    systemName: player.isPlaying ? "pause.fill" : "play.fill",
                    diameter: 64,
                    fontSize: player.isPlaying ? 42 : 38
                ) {
                    player.togglePlayback()
                }
                .contentTransition(.symbolEffect(.replace))
                LyricsPlayerIconButton(systemName: "forward.end.fill", diameter: 48, fontSize: 28) {
                    suppressNextCueAdvance = true
                    onManualBaselineReset()
                    player.nextCue()
                }
                .help(Text("Next Cue"))
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 10) {
                lyricsMaskButton
                verticalLyricsModeButton

                if showStatisticsButton {
                    LyricsPlayerIconButton(
                        systemName: isStatisticsTracking ? "timer" : "chart.xyaxis.line",
                        diameter: 34,
                        fontSize: 19
                    ) {
                        onToggleStatisticsTracking()
                    }
                    .help(Text("Statistics"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var lyricsScrubber: some View {
        let duration = max(player.duration, 0)
        let displayedTime = min(max(scrubbingTime ?? player.currentTime, 0), max(duration, 0))
        let fraction = duration > 0 ? min(max(displayedTime / duration, 0), 1) : 0
        let isActive = isHoveringScrubber || scrubbingTime != nil
        return VStack(spacing: 5) {
            GeometryReader { proxy in
                let trackWidth = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.2))
                    Capsule()
                        .fill(.white.opacity(isActive ? 0.94 : 0.72))
                        .frame(width: trackWidth * fraction)
                }
                .frame(height: isActive ? 9 : 5)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            scrubbingTime = min(max(value.location.x / trackWidth, 0), 1) * duration
                        }
                        .onEnded { value in
                            scrubbingTime = nil
                            guard duration > 0 else { return }
                            seekLyricsPlayback(to: min(max(value.location.x / trackWidth, 0), 1) * duration)
                        }
                )
            }
            .frame(height: 14)
            .onHover { hovering in
                isHoveringScrubber = hovering
            }
            .animation(.smooth(duration: 0.16), value: isActive)

            HStack {
                Text(verbatim: lyricsTimeText(displayedTime))
                Spacer(minLength: 8)
                Text(verbatim: "-" + lyricsTimeText(max(duration - displayedTime, 0)))
            }
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.52))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Playback Position"))
        .accessibilityValue(Text(verbatim: lyricsTimeText(displayedTime)))
    }

    private var lyricsMaskButton: some View {
        LyricsPlayerIconButton(
            systemName: isLyricsMaskEnabled ? "eye.slash" : "eye",
            diameter: 34,
            fontSize: 19
        ) {
            withAnimation(.smooth(duration: 0.14)) {
                isLyricsMaskEnabled.toggle()
            }
        }
        .help(Text("Lyrics Mask"))
        .accessibilityLabel(Text("Lyrics Mask"))
    }

    private var verticalLyricsModeButton: some View {
        LyricsPlayerIconButton(
            systemName: isVerticalLyricsMode ? "rectangle" : "rectangle.portrait",
            diameter: 34,
            fontSize: 19
        ) {
            toggleVerticalLyricsMode()
        }
        .help(Text("Vertical Lyrics Mode"))
        .accessibilityLabel(Text("Vertical Lyrics Mode"))
    }

    /// The other orientation is a fresh list, so it always opens on the current line.
    private func toggleVerticalLyricsMode() {
        followResumeTask?.cancel()
        followResumeTask = nil
        isFollowingPlayback = true
        withAnimation(ReaderLyricsVisualSpec.lineChangeAnimation) {
            isVerticalLyricsMode.toggle()
        }
    }

    @ViewBuilder
    private func lyricsArtwork(
        metrics: ReaderLyricsLayoutMetrics,
        availableHeight: CGFloat,
        panelWidth: CGFloat
    ) -> some View {
        let size = artworkSize(metrics: metrics, availableHeight: availableHeight, panelWidth: panelWidth)
        Group {
            if let image = coverImage {
                ZStack {
                    Color.clear
                        .frame(width: size, height: size)

                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size, alignment: .center)
                }
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "book.closed")
                            .font(.system(size: size * 0.18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.48))
                    }
            }
        }
        .shadow(color: .black.opacity(player.isPlaying ? 0.38 : 0.22), radius: player.isPlaying ? 26 : 14, y: player.isPlaying ? 14 : 8)
        .scaleEffect(player.isPlaying ? 1 : ReaderLyricsVisualSpec.pausedArtworkScale)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: player.isPlaying)
    }

    private var lyricsPlayerMetadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .truncationMode(.middle)

            lyricsMetricRow
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lyricsMetricRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                if showStatisticsMetrics {
                    lyricsMetric(label: "Reading Speed:", value: readingSpeedText)
                }
                lyricsMetric(label: "Reading Progress:", value: readingProgressText)
                if showStatisticsMetrics {
                    lyricsMetric(label: "Reading Time:", value: readingTimeText)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                if showStatisticsMetrics {
                    lyricsMetric(label: "Reading Speed:", value: readingSpeedText)
                }
                lyricsMetric(label: "Reading Progress:", value: readingProgressText)
                if showStatisticsMetrics {
                    lyricsMetric(label: "Reading Time:", value: readingTimeText)
                }
            }
        }
    }

    private func lyricsMetric(label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }

    private func playerPanelWidth(metrics: ReaderLyricsLayoutMetrics, availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.32, 220), min(430, availableWidth * 0.44))
    }

    private func artworkSize(
        metrics: ReaderLyricsLayoutMetrics,
        availableHeight: CGFloat,
        panelWidth: CGFloat
    ) -> CGFloat {
        let reservedHeight = playerMetadataHeight(availableHeight: availableHeight)
            + ReaderLyricsVisualSpec.scrubberHeight
            + 64
            + 34
            + playerPanelSpacing(metrics: metrics, availableHeight: availableHeight) * 4
        return min(panelWidth, max(availableHeight - reservedHeight, 96))
    }

    private func playerLyricsSpacing(metrics: ReaderLyricsLayoutMetrics, availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.06, 28), 96)
    }

    private func playerPanelSpacing(
        metrics: ReaderLyricsLayoutMetrics,
        availableHeight: CGFloat
    ) -> CGFloat {
        min(max(availableHeight * 0.018, 8), 20)
    }

    private func playerMetadataHeight(availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.1, 50), 72)
    }

    private func playerControlSpacing(metrics: ReaderLyricsLayoutMetrics, availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.08, 16), 36)
    }

    private func lyricsColumnWidth(
        metrics: ReaderLyricsLayoutMetrics,
        availableWidth: CGFloat,
        panelWidth: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        max(
            min(metrics.contentMaxWidth, availableWidth - panelWidth - spacing),
            260
        )
    }

    private func handleCurrentCueChange(_ cue: SasayakiMatch?) {
        guard let cue else { return }
        if pendingManualCueID == cue.id {
            pendingManualCueID = nil
            lastReportedCue = cue
            return
        }
        if suppressNextCueAdvance {
            suppressNextCueAdvance = false
            lastReportedCue = cue
            onManualBaselineReset()
            return
        }
        let previous = lastReportedCue
        lastReportedCue = cue
        onCueAdvanced(previous, cue)
    }

    private func seekLyricsPlayback(to time: Double) {
        suppressNextCueAdvance = true
        onManualBaselineReset()
        player.seekRelative(time - player.currentTime)
        followResumeTask?.cancel()
        followResumeTask = nil
        isFollowingPlayback = true
    }

    private func handleLyricsScrollPhase(_ phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting, .decelerating:
            followResumeTask?.cancel()
            followResumeTask = nil
            guard isFollowingPlayback else { return }
            isFollowingPlayback = false
        case .idle:
            guard !isFollowingPlayback else { return }
            scheduleFollowResume()
        default:
            break
        }
    }

    private func scheduleFollowResume() {
        followResumeTask?.cancel()
        followResumeTask = nil
        guard player.isPlaying else { return }
        followResumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(ReaderLyricsVisualSpec.manualScrollFollowResumeDelay))
            guard !Task.isCancelled, player.isPlaying else { return }
            resumeFollowingPlayback()
        }
    }

    private func resumeFollowingPlayback() {
        followResumeTask?.cancel()
        followResumeTask = nil
        withAnimation(.smooth(duration: 0.24)) {
            isFollowingPlayback = true
        }
        requestLyricsScroll(animated: true)
    }

    private func followActiveCue(from previousIndex: Int?, to index: Int?) {
        let isNearbyAdvance = previousIndex.flatMap { previous in
            index.map { abs($0 - previous) <= ReaderLyricsVisualSpec.maxAnimatedFollowDistance }
        } ?? false
        let animated = animatesNextFollowScroll || isNearbyAdvance
        animatesNextFollowScroll = false
        requestLyricsScroll(animated: animated)
    }

    private func requestLyricsScroll(animated: Bool) {
        guard isFollowingPlayback else { return }
        lyricsScrollRequest = ReaderLyricsScrollRequest(
            generation: lyricsScrollRequest.generation &+ 1,
            animated: animated
        )
    }

    private func scrollLyrics(with proxy: ScrollViewProxy, animated: Bool) {
        guard isFollowingPlayback, let index = activeLyricsIndex else { return }
        let anchor = isVerticalLyricsMode ? verticalLyricsScrollAnchor : lyricsScrollAnchor
        if animated {
            withAnimation(ReaderLyricsVisualSpec.lineChangeAnimation) {
                proxy.scrollTo(index, anchor: anchor)
            }
        } else {
            proxy.scrollTo(index, anchor: anchor)
        }
    }

    private func updateHeldLyricsCue(_ cue: SasayakiMatch?) {
        guard let cue else { return }
        guard heldLyricsCue?.id != cue.id else { return }
        heldLyricsCue = cue
    }

    private func updateHeldLyricsCueForPlaybackPosition() {
        if let currentCue = player.currentCue {
            updateHeldLyricsCue(currentCue)
            return
        }
        guard let cue = cueForCurrentPlaybackPosition() else { return }
        updateHeldLyricsCue(cue)
    }

    private func cueForCurrentPlaybackPosition() -> SasayakiMatch? {
        guard let matches = player.matchData?.matches, !matches.isEmpty else { return nil }
        let playbackTime = player.currentTime - player.delay
        if let heldLyricsCue,
           let heldIndex = matches.firstIndex(where: { $0.id == heldLyricsCue.id }),
           playbackTime >= heldLyricsCue.endTime {
            let nextIndex = matches.index(after: heldIndex)
            if nextIndex == matches.endIndex || playbackTime < matches[nextIndex].startTime {
                return heldLyricsCue
            }
        }
        guard let previousCue = matches.last(where: { $0.startTime <= playbackTime }) else {
            return nil
        }
        return previousCue
    }

    /// Cues are ordered by start time, so a binary search finds the row without
    /// scanning the whole book on every playback tick.
    private func lyricsCueIndex(of cue: SasayakiMatch) -> Int? {
        let matches = lyricsCues
        var low = matches.startIndex
        var high = matches.endIndex
        while low < high {
            let mid = (low + high) / 2
            if matches[mid].startTime < cue.startTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var index = low
        while index < matches.endIndex, matches[index].startTime == cue.startTime {
            if matches[index].id == cue.id {
                return index
            }
            index += 1
        }
        return matches.firstIndex(where: { $0.id == cue.id })
    }

    private func isLyricsMaskVisible(for cue: SasayakiMatch) -> Bool {
        guard isLyricsMaskEnabled, player.isPlaying, !isLookupPopupVisible else { return false }
        return hoveredLyricsCueID != cue.id
    }

    private func updateLyricsMaskHover(_ hovering: Bool, cue: SasayakiMatch) {
        if hovering {
            hoveredLyricsCueID = cue.id
        } else if hoveredLyricsCueID == cue.id {
            hoveredLyricsCueID = nil
        }
    }

    private func maskedHorizontalLyricsText(
        _ cue: SasayakiMatch,
        fontSize: CGFloat,
        isFocused: Bool,
        isRightToLeft: Bool
    ) -> some View {
        ReaderLyricsMaskedTextOverlay {
            Text(cue.text)
                .font(.system(size: min(max(fontSize, 12), 72), weight: .bold))
                .foregroundStyle(.white.opacity(maskedLyricsOpacity(isFocused: isFocused)))
                .multilineTextAlignment(isRightToLeft ? .trailing : .leading)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: isRightToLeft ? .topTrailing : .topLeading
                )
        }
    }

    private func maskedVerticalLyricsText(
        _ cue: SasayakiMatch,
        fontSize: CGFloat,
        isFocused: Bool,
        availableHeight: CGFloat
    ) -> some View {
        let columnWidth = ReaderLyricsVerticalTextLayout.columnWidth(fontSize: fontSize)
        let columnSpacing = ReaderLyricsVerticalTextLayout.columnSpacing(fontSize: fontSize)
        let rowHeight = ReaderLyricsVerticalTextLayout.rowHeight(fontSize: fontSize)
        let columns = ReaderLyricsVerticalTextLayout.columns(
            from: cue.text,
            fontSize: fontSize,
            availableHeight: availableHeight
        )
        return ReaderLyricsMaskedTextOverlay {
            HStack(alignment: .center, spacing: columnSpacing) {
                ForEach(Array(columns.enumerated().reversed()), id: \.offset) { _, column in
                    VStack(spacing: 0) {
                        ForEach(Array(column.enumerated()), id: \.offset) { _, glyph in
                            Text(glyph.text)
                                .frame(width: columnWidth, height: rowHeight)
                        }
                    }
                }
            }
            .font(.system(size: min(max(fontSize, 12), 72), weight: .bold))
            .foregroundStyle(.white.opacity(maskedLyricsOpacity(isFocused: isFocused)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func maskedLyricsOpacity(isFocused: Bool) -> CGFloat {
        isFocused
            ? ReaderLyricsVisualSpec.lyricsMaskFocusedOpacity
            : ReaderLyricsVisualSpec.lyricsMaskContextOpacity
    }

    private func loadCoverImage() {
        coverImage = coverURL.flatMap(NSImage.init(contentsOf:))
    }

    private func lyricsTimeText(_ seconds: Double) -> String {
        let totalSeconds = max(Int(seconds.rounded(.down)), 0)
        let hours = totalSeconds / 3600
        let minutes = totalSeconds / 60 % 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private var readingSpeedText: String {
        "\(contentLanguage.displayCount(forRawCharacters: sessionStatistics.readingSpeed).formatted(.number.grouping(.never))) / h"
    }

    private var readingProgressText: String {
        let current = contentLanguage.displayCount(forRawCharacters: currentCharacter)
        let total = contentLanguage.displayCount(forRawCharacters: bookCharacterCount)
        let percent = bookCharacterCount > 0
            ? (Double(currentCharacter) / Double(bookCharacterCount) * 100)
            : 0
        return "\(current.formatted(.number.grouping(.never))) / \(total.formatted(.number.grouping(.never))) · \(String(format: "%.2f%%", percent))"
    }

    private var readingTimeText: String {
        Duration.seconds(sessionStatistics.readingTime).formatted(.time(pattern: .hourMinute))
    }

    private func lineProgress(for cue: SasayakiMatch) -> Double {
        let playbackTime = player.currentTime - player.delay
        let duration = max(cue.endTime - cue.startTime, 0.1)
        return min(max((playbackTime - cue.startTime) / duration, 0), 1)
    }

    private func progressRate(for cue: SasayakiMatch) -> Double {
        let duration = max(cue.endTime - cue.startTime, 0.1)
        return max(Double(player.rate), 0) / duration
    }
}

/// A scroll request is a value so every follow action re-scrolls, even when
/// the active cue has not changed since the user scrolled away.
private struct ReaderLyricsScrollRequest: Equatable {
    var generation = 0
    var animated = false
}

private extension ReaderLyricsVisualSpec {
    static var lineChangeAnimation: Animation {
        .interpolatingSpring(mass: 1, stiffness: 100, damping: 18, initialVelocity: 0)
    }

    static func highlightAnimation(highlighted: Bool) -> Animation {
        if highlighted {
            .interpolatingSpring(mass: 1, stiffness: 322, damping: 24, initialVelocity: 0)
        } else {
            .interpolatingSpring(mass: 2, stiffness: 300, damping: 50, initialVelocity: 0)
        }
    }
}

private struct LyricsPlayerIconButton: View {
    let systemName: String
    var diameter: CGFloat
    var fontSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: fontSize, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: diameter, height: diameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.88))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }
}

private struct ReaderLyricsMaskedTextOverlay<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let feather = ReaderLyricsVisualSpec.lyricsMaskBlurFeatherPadding
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .padding(feather)
                .blur(radius: ReaderLyricsVisualSpec.lyricsMaskBlurRadius, opaque: false)
                .offset(x: -feather, y: -feather)
        }
        .allowsHitTesting(false)
    }
}

private struct NativeReaderStatisticsSheet: View {
    let model: NativeReaderModel
    let contentLanguage: ContentLanguageProfile
    let onClose: () -> Void

    var body: some View {
        ReaderStatisticsContentView(
            sessionStatistics: model.sessionStatistics,
            todaysStatistics: model.todaysStatistics,
            allTimeStatistics: model.allTimeStatistics,
            bookCharacterCount: model.bookInfo.characterCount,
            currentCharacter: model.currentCharacter,
            chapterCharactersRemaining: model.currentChapterCharactersRemaining,
            contentLanguage: contentLanguage,
            isTracking: model.isTracking,
            onStart: model.startTracking,
            onStop: model.stopTracking,
            onClose: onClose
        )
        .background {
            NativeWindowActivityReader { _, isKey in
                model.updateStatisticsSheetActivity(isKey)
            }
        }
        .onDisappear {
            model.updateStatisticsSheetActivity(false)
        }
    }
}

/// Desktop side panel for Reader tools: a full-height card floating over the
/// page, so opening it never changes pagination.
private struct NativeReaderSidePanel<Content: View>: View {
    let edge: HorizontalEdge
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    static var width: CGFloat { 440 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        content()
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .background(NativeGlassPageBackground())
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.1), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.16), radius: 24, x: 0, y: 8)
            .padding(.vertical, 12)
            .padding(edge == .leading ? .leading : .trailing, 12)
            .onExitCommand(perform: onClose)
    }
}

private struct NativeReaderGlassIconButton: View {
    let systemName: String
    var diameter: CGFloat = 34
    var fontSize: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: fontSize, weight: .semibold))
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.plain)
        .nativeReaderGlassCircleControl()
    }
}

private extension View {
    @ViewBuilder
    func nativeReaderGlassCircleControl() -> some View {
        self
            .overlay {
                Circle()
                    .strokeBorder(.quaternary.opacity(0.58), lineWidth: 0.7)
            }
            .nativeReaderGlassCircle()
    }

    @ViewBuilder
    func nativeReaderGlassCapsuleControl() -> some View {
        self
            .overlay {
                Capsule()
                    .strokeBorder(.quaternary.opacity(0.58), lineWidth: 0.7)
            }
            .nativeReaderGlassCapsule()
    }

    @ViewBuilder
    func nativeReaderGlassCircle() -> some View {
        self.glassEffect(.regular.interactive(), in: Circle())
    }

    @ViewBuilder
    func nativeReaderGlassCapsule() -> some View {
        self.glassEffect(.regular.interactive(), in: Capsule())
    }
}

final class NativeReaderWKWebView: HoshiShiftHoverWKWebView {
    weak var shortcutManager: ShortcutManager?
    var hasSelection = false
    var onHighlightCreated: ((HighlightColor, HighlightData) -> Void)?
    private static let highlightMenuIdentifier = NSUserInterfaceItemIdentifier("hoshi.reader.highlights")

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard hasSelection else { return }

        if let existingItem = menu.items.first(where: { $0.identifier == Self.highlightMenuIdentifier }) {
            menu.removeItem(existingItem)
        }

        let submenu = NSMenu(title: String(localized: "Highlights"))
        for color in HighlightColor.allCases {
            let item = NSMenuItem(
                title: color.localizedName,
                action: #selector(createHighlight(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = color.rawValue
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: String(localized: "Highlights"), action: nil, keyEquivalent: "")
        item.identifier = Self.highlightMenuIdentifier
        item.image = NSImage(
            systemSymbolName: "highlighter",
            accessibilityDescription: String(localized: "Highlights")
        )
        item.submenu = submenu
        menu.insertItem(item, at: 0)
    }

    @objc private func createHighlight(_ sender: NSMenuItem) {
        guard hasSelection,
              let rawValue = sender.representedObject as? String,
              let color = HighlightColor(rawValue: rawValue) else {
            return
        }

        let id = UUID()
        let script = "window.hoshiHighlights.createHighlight('\(color.rawValue)', '\(id.uuidString)')"
        evaluateJavaScript(script) { [weak self] result, _ in
            guard let body = result as? [String: Any],
                  let start = body["start"] as? Int,
                  let offset = body["offset"] as? Int,
                  let text = body["text"] as? String else {
                return
            }
            self?.hasSelection = false
            self?.onHighlightCreated?(color, HighlightData(
                id: id,
                start: start,
                offset: offset,
                text: text
            ))
        }
    }

    override func keyDown(with event: NSEvent) {
        if shortcutManager?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Off-screen layout surface for page counting; never takes input.
final class NativeReaderPageMeasureWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

struct NativeReaderWebView: NSViewRepresentable {
    let chapterURL: URL
    let readAccessURL: URL
    let reloadID: String
    let progress: Double
    let bridge: WebViewBridge
    let bridgeCommandCount: Int
    let userConfig: UserConfig
    let shortcutManager: ShortcutManager
    let viewSize: CGSize
    let textColor: String?
    let backgroundColor: String
    let sasayakiTextColor: String
    let sasayakiBackgroundColor: String
    let contentLanguageID: String
    let highlightsJSON: String?
    let fragment: String?
    let pageNavigation: NativeReaderPageNavigation?
    /// Non-nil when the progress display counts pages; identifies the layout the
    /// page table is measured for.
    let pageLayoutKey: String?
    let spineURLs: [URL]
    let pageCacheDirectory: URL?
    var onPagesChanged: ([[Int]]) -> Void = { _ in }
    var onPageChanged: (URL, Int) -> Void = { _, _ in }
    var onNavigationHandled: (UUID) -> Void
    var onPageTurn: () -> Void
    var onNextChapter: () -> Bool
    var onPreviousChapter: () -> Bool
    var onProgressChanged: (Double) -> Void
    var onSaveBookmark: (Double) -> Void
    var onInternalLink: (URL) -> Bool
    var onInternalJump: (Double) -> Void
    var onTextSelected: (SelectionData) -> Int?
    var onHighlightCreated: (HighlightColor, HighlightData) -> Void
    var onTapOutside: () -> Void
    var onRestoreCompleted: () -> Void
    var onImageTapped: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "textSelected")
        config.userContentController.add(context.coordinator, name: "restoreCompleted")
        config.userContentController.add(context.coordinator, name: "imageTapped")
        config.userContentController.add(context.coordinator, name: "wheelNavigation")
        config.userContentController.add(context.coordinator, name: "tapOutside")
        config.userContentController.add(context.coordinator, name: "progressChanged")
        config.userContentController.add(context.coordinator, name: "selectionState")
        config.userContentController.add(context.coordinator, name: "pageChanged")

        let webView = NativeReaderWKWebView(frame: .zero, configuration: config)
        webView.shortcutManager = shortcutManager
        let coordinator = context.coordinator
        webView.onHighlightCreated = { [weak coordinator] color, creation in
            coordinator?.parent.onHighlightCreated(color, creation)
        }
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.reloadID = reloadID
        webView.loadFileURL(chapterURL, allowingReadAccessTo: readAccessURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        (webView as? NativeReaderWKWebView)?.shortcutManager = shortcutManager
        context.coordinator.syncTextColor()
        context.coordinator.syncBackgroundColor()
        context.coordinator.syncSasayakiColors()
        if !bridge.pendingCommands.isEmpty {
            let commands = bridge.pendingCommands
            bridge.pendingCommands.removeAll()
            commands.forEach { context.coordinator.handleCommand($0) }
        }
        if context.coordinator.reloadID != reloadID {
            context.coordinator.reloadID = reloadID
            context.coordinator.pendingProgress = progress
            (webView as? NativeReaderWKWebView)?.relinquishTextInputFocus()
            webView.loadFileURL(chapterURL, allowingReadAccessTo: readAccessURL)
        }
        context.coordinator.updatePageMeasurement()
        if let navigation = pageNavigation,
           context.coordinator.lastNavigationRequestID != navigation.id {
            guard NativeReaderNavigationConsumptionRegistry.consume(navigation.id) else {
                return
            }
            context.coordinator.lastNavigationRequestID = navigation.id
            context.coordinator.navigate(navigation.direction)
            DispatchQueue.main.async {
                onNavigationHandled(navigation.id)
            }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        (webView as? NativeReaderWKWebView)?.relinquishTextInputFocus()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "textSelected")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "restoreCompleted")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "imageTapped")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "wheelNavigation")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tapOutside")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "progressChanged")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "selectionState")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pageChanged")
        coordinator.stopMeasuringPages()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: NativeReaderWebView
        weak var webView: WKWebView?
        var reloadID = ""
        var pendingProgress: Double
        var lastNavigationRequestID: UUID?
        private var shouldSyncProgressAfterRestore = false
        private var hasSyncedTextColor = false
        private var lastTextColor: String?
        private var lastBackgroundColor: String?
        private var pagesWebView: NativeReaderPageMeasureWebView?
        private var measuringLayoutKey: String?
        private var measuredLayoutKey: String?
        private var measuredSpinePageStarts: [[Int]] = []
        private var spineMeasureTimeout: DispatchWorkItem?

        init(_ parent: NativeReaderWebView) {
            self.parent = parent
            self.pendingProgress = parent.progress
        }

        private static func cgFloatValue(_ value: Any?) -> CGFloat? {
            if let value = value as? CGFloat {
                return value
            }
            if let value = value as? Double {
                return CGFloat(value)
            }
            if let value = value as? Float {
                return CGFloat(value)
            }
            if let value = value as? Int {
                return CGFloat(value)
            }
            if let value = value as? NSNumber {
                return CGFloat(truncating: value)
            }
            return nil
        }

        static func textColorScript(_ hex: String?) -> String {
            if let hex {
                return "document.documentElement.style.setProperty('--hoshi-text-color', '\(hex)');"
            }
            return "document.documentElement.style.removeProperty('--hoshi-text-color');"
        }

        fileprivate func syncTextColor() {
            guard !hasSyncedTextColor || lastTextColor != parent.textColor else {
                return
            }
            applyTextColor(parent.textColor)
        }

        /// Keeps the page background in step with live theme and macOS
        /// appearance changes; the load-time script only sets the first value.
        fileprivate func syncBackgroundColor() {
            guard lastBackgroundColor != parent.backgroundColor else { return }
            lastBackgroundColor = parent.backgroundColor
            webView?.evaluateJavaScript(
                "document.documentElement.style.setProperty('--hoshi-reader-background-color', '\(parent.backgroundColor)');"
            ) { _, _ in }
        }

        private func applyTextColor(_ hex: String?) {
            hasSyncedTextColor = true
            lastTextColor = hex
            webView?.evaluateJavaScript(Self.textColorScript(hex)) { _, _ in }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "spineMeasured":
                guard message.webView === pagesWebView else { return }
                let starts = (message.body as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
                finishMeasuringSpine(starts.isEmpty ? [0] : starts)
            case "pageChanged":
                guard message.webView === webView,
                      let page = (message.body as? NSNumber)?.intValue,
                      let url = message.webView?.url else { return }
                parent.onPageChanged(url, page)
            case "selectionState":
                guard let hasSelection = message.body as? Bool,
                      let webView = message.webView as? NativeReaderWKWebView else {
                    return
                }
                webView.hasSelection = hasSelection
            case "wheelNavigation":
                guard !parent.userConfig.continuousMode, let direction = message.body as? String else { return }
                navigate(direction == "forward" ? .forward : .backward)
            case "progressChanged":
                guard parent.userConfig.continuousMode else { return }
                let progress: Double?
                if let value = message.body as? Double {
                    progress = value
                } else if let value = message.body as? NSNumber {
                    progress = value.doubleValue
                } else {
                    progress = nil
                }
                guard let progress else { return }
                parent.onPageTurn()
                parent.onProgressChanged(progress)
                parent.onSaveBookmark(progress)
            case "restoreCompleted":
                message.webView?.alphaValue = 1
                message.webView?.evaluateJavaScript(textAnimationScript) { _, _ in }
                if shouldSyncProgressAfterRestore {
                    shouldSyncProgressAfterRestore = false
                    syncInternalJumpProgress()
                }
                completeRestore()
            case "tapOutside":
                parent.onTapOutside()
            case "imageTapped":
                if let src = message.body as? String, let url = URL(string: src) {
                    parent.onImageTapped(url)
                }
            case "textSelected":
                guard let body = message.body as? [String: Any],
                      let text = body["text"] as? String,
                      let sentence = body["sentence"] as? String,
                      let rectData = body["rect"] as? [String: Any],
                      let x = Self.cgFloatValue(rectData["x"]),
                      let y = Self.cgFloatValue(rectData["y"]),
                      let w = Self.cgFloatValue(rectData["width"]),
                      let h = Self.cgFloatValue(rectData["height"]) else {
                    return
                }
                let viewportRect = CGRect(x: x, y: y, width: w, height: h)
                let scrollBoundsOrigin = message.webView?.visibleRect.origin ?? .zero
                let shouldSubtractVerticalScrollOffset = parent.userConfig.verticalWriting
                let selectionRect = ReaderViewportGeometry.selectionRect(
                    fromViewportRect: viewportRect,
                    adjustedContentInset: .zero,
                    scrollBoundsOrigin: scrollBoundsOrigin,
                    subtractVerticalScrollOffset: shouldSubtractVerticalScrollOffset
                )
                let selection = SelectionData(
                    text: text,
                    sentence: sentence,
                    rect: selectionRect,
                    normalizedOffset: body["normalizedOffset"] as? Int,
                    miningContext: MiningContextSelection.decode(body["miningContext"])
                )
                if let highlightCount = parent.onTextSelected(selection) {
                    highlightSelection(count: highlightCount)
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if parent.onInternalLink(url) {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            injectReader(into: webView, measuringPages: webView === pagesWebView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if webView === pagesWebView { finishMeasuringSpine([0]) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if webView === pagesWebView { finishMeasuringSpine([0]) }
        }

        // MARK: Page measurement

        private struct PageCache: Codable {
            let layoutKey: String
            let pageStarts: [[Int]]
        }

        private static let pageCacheFileName = "reader_pages.json"

        /// Lays out every spine item in a hidden web view with the visible Reader's
        /// layout and records where each page starts. Results are cached per book for
        /// the exact layout key, so the work only repeats after a layout change.
        func updatePageMeasurement() {
            guard let key = parent.pageLayoutKey, !parent.spineURLs.isEmpty else {
                stopMeasuringPages()
                measuredLayoutKey = nil
                return
            }
            guard key != measuredLayoutKey, key != measuringLayoutKey else { return }
            stopMeasuringPages()
            measuredLayoutKey = nil
            measuredSpinePageStarts = []

            if let directory = parent.pageCacheDirectory,
               let data = try? Data(contentsOf: directory.appendingPathComponent(Self.pageCacheFileName)),
               let cache = try? JSONDecoder().decode(PageCache.self, from: data),
               cache.layoutKey == key,
               cache.pageStarts.count == parent.spineURLs.count {
                measuredLayoutKey = key
                publishPages(cache.pageStarts)
                return
            }

            publishPages([])
            guard let webView else { return }
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "spineMeasured")
            let pagesWebView = NativeReaderPageMeasureWebView(
                frame: CGRect(origin: .zero, size: parent.viewSize),
                configuration: config
            )
            pagesWebView.alphaValue = 0
            pagesWebView.setAccessibilityElement(false)
            pagesWebView.navigationDelegate = self
            pagesWebView.setValue(false, forKey: "drawsBackground")
            webView.addSubview(pagesWebView, positioned: .below, relativeTo: nil)
            self.pagesWebView = pagesWebView
            measuringLayoutKey = key
            loadNextSpineForMeasurement()
        }

        func stopMeasuringPages() {
            spineMeasureTimeout?.cancel()
            spineMeasureTimeout = nil
            measuringLayoutKey = nil
            guard let pagesWebView else { return }
            pagesWebView.stopLoading()
            pagesWebView.configuration.userContentController.removeScriptMessageHandler(forName: "spineMeasured")
            pagesWebView.removeFromSuperview()
            self.pagesWebView = nil
        }

        private func loadNextSpineForMeasurement() {
            guard let pagesWebView else { return }
            let spineIndex = measuredSpinePageStarts.count
            guard parent.spineURLs.indices.contains(spineIndex) else { return }
            spineMeasureTimeout?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                // A spine item that never finishes layout counts as a single page.
                self?.finishMeasuringSpine([0])
            }
            spineMeasureTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
            pagesWebView.loadFileURL(parent.spineURLs[spineIndex], allowingReadAccessTo: parent.readAccessURL)
        }

        private func finishMeasuringSpine(_ starts: [Int]) {
            guard pagesWebView != nil, let key = measuringLayoutKey else { return }
            spineMeasureTimeout?.cancel()
            spineMeasureTimeout = nil
            measuredSpinePageStarts.append(starts)
            guard measuredSpinePageStarts.count >= parent.spineURLs.count else {
                loadNextSpineForMeasurement()
                return
            }
            let pageStarts = measuredSpinePageStarts
            stopMeasuringPages()
            measuredLayoutKey = key
            if let directory = parent.pageCacheDirectory,
               let data = try? JSONEncoder().encode(PageCache(layoutKey: key, pageStarts: pageStarts)) {
                try? data.write(to: directory.appendingPathComponent(Self.pageCacheFileName), options: .atomic)
            }
            publishPages(pageStarts)
        }

        private func publishPages(_ pageStarts: [[Int]]) {
            // May run inside updateNSView; defer the model mutation.
            DispatchQueue.main.async { [weak self] in
                self?.parent.onPagesChanged(pageStarts)
            }
        }

        private func injectReader(into webView: WKWebView, measuringPages: Bool = false) {
            let writingMode = parent.userConfig.verticalWriting ? "vertical-rl" : "horizontal-tb"
            let pageWidth = max(Int(parent.viewSize.width.rounded()), 1)
            let pageHeight = max(Int(parent.viewSize.height.rounded()), 1)
            let verticalPadding = Double(parent.userConfig.verticalPadding)
            let horizontalPadding = Double(parent.userConfig.horizontalPadding)
            let bottomOverlap = parent.userConfig.verticalWriting ? parent.userConfig.fontSize : 0
            let paragraphMode = parent.userConfig.paragraphMode && !parent.userConfig.continuousMode
            let horizontalPageColumns = parent.userConfig.readerTwoColumnHorizontalPages
                && !parent.userConfig.verticalWriting
                && !parent.userConfig.continuousMode
                && !paragraphMode ? 2 : 1
            let horizontalSpreadColumnGap = 32
            let horizontalSpreadPageSize = horizontalPageColumns > 1
                ? max(1, Double(pageWidth) - (Double(pageWidth) * horizontalPadding / 100.0) + Double(horizontalSpreadColumnGap))
                : Double(pageWidth)
            let horizontalSpreadSideClip = "\(horizontalPadding / 2)vw"
            let readerScriptName = parent.userConfig.continuousMode ? "scrollreader" : "reader"
            let readerScript = Self.bundleString(readerScriptName, extension: "js")
            let selectionScript = Self.bundleString("selection", extension: "js")
            let highlightsScript = Self.bundleString("highlights", extension: "js")
            let paragraphScript = paragraphMode ? Self.bundleString("paragraph", extension: "js") : ""
            let textColorCss = Self.textColorScript(parent.textColor)
            let backgroundColorCss = """
            document.documentElement.style.setProperty('--hoshi-reader-background-color', '\(parent.backgroundColor)');
            """
            let sasayakiColorCss = """
            document.documentElement.style.setProperty('--hoshi-sasayaki-text-color', '\(parent.sasayakiTextColor)');
            document.documentElement.style.setProperty('--hoshi-sasayaki-background-color', '\(parent.sasayakiBackgroundColor)');
            """
            let highlightsSetupScript = measuringPages ? "" : parent.highlightsJSON.map { "window.hoshiHighlights.applyHighlights(\($0));" } ?? ""
            let sasayakiSetupScript = measuringPages ? "" : parent.bridge.sasayakiCues.map { "window.hoshiReader.applySasayakiCues(\($0));" } ?? ""
            let initialRestoreScript: String = {
                if measuringPages {
                    return "document.fonts.ready.then(() => window.webkit.messageHandlers.spineMeasured.postMessage(window.hoshiReader.calculatePageStarts()))"
                }
                if let fragment = parent.fragment {
                    shouldSyncProgressAfterRestore = true
                    return "window.hoshiReader.jumpToFragment(\(Self.javaScriptStringLiteral(fragment)))"
                }
                shouldSyncProgressAfterRestore = false
                return "window.hoshiReader.restoreProgress(\(pendingProgress))"
            }()

            var fontFaceCss = ""
            if let fontURL = try? FontManager.shared.fontUrl(
                name: parent.userConfig.selectedFont,
                verticalWriting: parent.userConfig.verticalWriting
            ) {
                fontFaceCss = """
                @font-face {
                    font-family: '\(parent.userConfig.selectedFont)';
                    src: url('\(fontURL.absoluteString)');
                }
                """
            }

            let horizontalColumnWidth = horizontalPageColumns > 1
                ? "max(1px, calc((var(--page-width, 100vw) - \(horizontalPadding)vw - \(horizontalSpreadColumnGap)px) / 2))"
                : "calc(var(--page-width, 100vw) - \(horizontalPadding)vw)"
            let columnWidth = parent.userConfig.verticalWriting
                ? "var(--page-height, 100vh)"
                : horizontalColumnWidth
            let columnGap = parent.userConfig.verticalWriting
                ? "calc(\(verticalPadding)vh + \(bottomOverlap)px)"
                : (horizontalPageColumns > 1 ? "\(horizontalSpreadColumnGap)px" : "\(horizontalPadding)vw")
            let columnCountCss = horizontalPageColumns > 1 ? """
                column-count: 2 !important;
                -webkit-column-count: 2 !important;
            """ : ""
            let horizontalSpreadBodyCss = horizontalPageColumns > 1
                ? "position: relative !important;"
                : ""
            let horizontalSpreadClipCss = horizontalPageColumns > 1 ? """
            body::before,
            body::after {
                content: "";
                position: fixed;
                top: 0;
                bottom: 0;
                width: \(horizontalSpreadSideClip);
                background: var(--hoshi-reader-background-color);
                pointer-events: none;
                z-index: 2147483647;
            }
            body::before {
                left: 0;
            }
            body::after {
                right: 0;
            }
            """ : ""
            let rootOverflowCss = parent.userConfig.continuousMode
                ? (parent.userConfig.verticalWriting ? "overflow-y: hidden !important;" : "overflow-x: hidden !important;")
                : """
                overflow: hidden !important;
                width: var(--page-width, 100vw) !important;
                """
            let paginatedHtmlHeightCss = parent.userConfig.continuousMode ? "" : """
            html {
                height: var(--page-height, 100vh) !important;
            }
            """
            let bodyPageHeightCss = parent.userConfig.continuousMode ? "" : "height: var(--page-height, 100vh) !important;"
            let bodyColumnCss = parent.userConfig.continuousMode ? "" : """
                column-width: \(columnWidth) !important;
                column-gap: \(columnGap) !important;
                \(columnCountCss)
            """
            let publisherColumnResetCss = parent.userConfig.continuousMode ? "" : """
            body * {
                column-count: auto !important;
                -webkit-column-count: auto !important;
            }
            """
            let advancedCss = parent.userConfig.layoutAdvanced ? """
            line-height: \(parent.userConfig.lineHeight) !important;
            letter-spacing: \(parent.userConfig.characterSpacing / 100.0)em !important;
            """ : ""
            let bottomPaddingCss = parent.userConfig.verticalWriting && bottomOverlap > 0
                ? "padding-bottom: calc(\(verticalPadding / 2)vh + \(bottomOverlap)px) !important;"
                : ""
            let globalSizingCss = parent.userConfig.continuousMode || !parent.userConfig.verticalWriting ? """
            * {
                max-width: 100% !important;
                box-sizing: border-box !important;
            }
            """ : ""
            let horizontalOverflowCss = parent.userConfig.verticalWriting ? "" : """
                column-fill: auto !important;
                -webkit-column-fill: auto !important;
                overflow-wrap: anywhere !important;
                word-break: normal !important;
                orphans: 1;
                widows: 1;
            """
            let breakableTextCss = parent.userConfig.verticalWriting ? "" : """
            p, div, span, li {
                break-inside: auto !important;
                -webkit-column-break-inside: auto !important;
                overflow-wrap: anywhere !important;
                word-break: normal !important;
            }
            pre, code {
                white-space: pre-wrap !important;
                overflow-wrap: anywhere !important;
                word-break: break-word !important;
            }
            table {
                table-layout: fixed !important;
                width: 100% !important;
                overflow-wrap: anywhere !important;
                word-break: break-word !important;
            }
            """
            let pageBreakCss = parent.userConfig.avoidPageBreak ? """
            p {
                break-inside: avoid !important;
                -webkit-column-break-inside: avoid !important;
            }
            """ : ""
            let paragraphSpacingCss: String = {
                guard parent.userConfig.layoutAdvanced else { return "" }
                if parent.userConfig.verticalWriting {
                    return """
                    p {
                        margin-right: \(parent.userConfig.paragraphSpacing)em !important;
                        margin-left: \(parent.userConfig.paragraphSpacing)em !important;
                    }
                    """
                }
                return """
                p {
                    margin-top: \(parent.userConfig.paragraphSpacing)em !important;
                    margin-bottom: \(parent.userConfig.paragraphSpacing)em !important;
                }
                """
            }()
            let paragraphModeCss = paragraphMode ? """
            body {
                column-fill: auto !important;
                -webkit-column-fill: auto !important;
                font-kerning: none !important;
            }
            p.hoshi-paragraph {
                margin-block-start: 0 !important;
                break-before: column !important;
                -webkit-column-break-before: always !important;
            }
            ::highlight(hoshi-animation) {
                color: transparent !important;
            }
            """ : ""
            let gridCss = parent.userConfig.justifyText ? "" : """
                text-align: start !important;
                hanging-punctuation: allow-end !important;
                line-break: strict !important;
            """
            let imgWidth = parent.userConfig.continuousMode
                ? (parent.userConfig.verticalWriting ? "none" : "\(100 - horizontalPadding)vw")
                : (parent.userConfig.verticalWriting ? "\(100 - horizontalPadding)vw" : horizontalColumnWidth)
            let imgHeight = parent.userConfig.continuousMode
                ? (parent.userConfig.verticalWriting ? "calc(\(100 - verticalPadding)vh - \(Double(bottomOverlap) * (100 - verticalPadding) / 100)px)" : "none")
                : (parent.userConfig.verticalWriting
                    ? "calc(\(100 - verticalPadding)vh - \(Double(bottomOverlap) * (100 - verticalPadding) / 100)px)"
                    : "\(100 - verticalPadding)vh")
            let spacerJs: String = {
                if parent.userConfig.verticalWriting {
                    guard verticalPadding > 0 || bottomOverlap > 0 else { return "" }
                    return """
                    var spacer = document.createElement('div');
                    spacer.style.height = 'calc(\(verticalPadding / 2)vh + \(bottomOverlap)px)';
                    spacer.style.width = '100%';
                    spacer.style.display = 'block';
                    spacer.style.breakInside = 'avoid';
                    document.body.appendChild(spacer);
                    """
                }
                guard horizontalPadding > 0 else { return "" }
                return """
                var spacer = document.createElement('div');
                spacer.style.height = '100%';
                spacer.style.width = '\(horizontalPadding / 2)vw';
                spacer.style.display = 'block';
                spacer.style.breakInside = 'avoid';
                document.body.appendChild(spacer);
                """
            }()
            // Toggle mode keeps the rt box so revealing furigana never reflows the page.
            let hiddenFuriganaCss = parent.userConfig.verticalWriting
            ? """
            ruby.furigana-hidden > rt {
                color: transparent !important;
                background-image: linear-gradient(rgba(150, 150, 150, 0.75), rgba(150, 150, 150, 0.75)) !important;
                background-size: 0.14em 100% !important;
                background-position: left center !important;
                background-repeat: no-repeat !important;
            }
            """
            : """
            ruby.furigana-hidden > rt {
                color: transparent !important;
                background-image: linear-gradient(rgba(150, 150, 150, 0.75), rgba(150, 150, 150, 0.75)) !important;
                background-size: 100% 0.14em !important;
                background-position: center bottom !important;
                background-repeat: no-repeat !important;
            }
            """
            let dimmedFuriganaCss = parent.userConfig.readerFuriganaMode == .dimmed ? """
            ruby > rt, ruby > rp { opacity: 0.4 !important; }
            """ : ""
            let furiganaJs: String = {
                switch parent.userConfig.readerFuriganaMode {
                case .off, .dimmed:
                    return ""
                case .toggle:
                    return """
                    document.querySelectorAll('ruby').forEach(ruby => {
                        if (ruby.querySelector('rt')) {
                            ruby.classList.add('furigana-hidden');
                        }
                    });
                    """
                case .hidden:
                    return "document.querySelectorAll('rt').forEach(rt => rt.remove());"
                }
            }()
            let css = """
            \(fontFaceCss)
            @media (prefers-color-scheme: light) { :root { --hoshi-text-color: #000; } }
            @media (prefers-color-scheme: dark) { :root { --hoshi-text-color: #fff; } }
            \(globalSizingCss)
            html, body {
                margin: 0 !important;
                padding: 0 !important;
                color: var(--hoshi-text-color) !important;
                writing-mode: \(writingMode) !important;
                -webkit-writing-mode: \(writingMode) !important;
                \(rootOverflowCss)
            }
            \(paginatedHtmlHeightCss)
            body {
                \(bodyPageHeightCss)
                font-family: '\(parent.userConfig.selectedFont)', serif !important;
                font-size: \(parent.userConfig.fontSize)px !important;
                -webkit-text-size-adjust: none !important;
                box-sizing: border-box !important;
                \(bodyColumnCss)
                padding: \(verticalPadding / 2)vh \(horizontalPadding / 2)vw !important;
                \(bottomPaddingCss)
                \(horizontalOverflowCss)
                \(horizontalSpreadBodyCss)
                \(advancedCss)
                \(gridCss)
            }
            \(publisherColumnResetCss)
            \(horizontalSpreadClipCss)
            \(breakableTextCss)
            img.block-img {
                max-width: \(imgWidth) !important;
                max-height: \(imgHeight) !important;
                width: auto !important;
                height: auto !important;
                display: block !important;
                margin: auto !important;
                break-inside: avoid !important;
                -webkit-column-break-inside: avoid !important;
                object-fit: contain !important;
            }
            svg {
                max-width: \(imgWidth) !important;
                max-height: \(imgHeight) !important;
                width: 100% !important;
                height: 100% !important;
                display: block !important;
                margin: auto !important;
                break-inside: avoid !important;
                -webkit-column-break-inside: avoid !important;
            }
            .blur-wrapper {
                display: table;
                margin: auto;
                line-height: 0;
                overflow: hidden;
            }
            img.block-img.blurred,
            svg.blurred {
                filter: blur(24px) !important;
                clip-path: inset(0);
            }
            ::highlight(hoshi-selection) {
                background-color: rgba(160, 160, 160, 0.4) !important;
                color: inherit;
            }
            .hoshi-sasayaki-cue.hoshi-sasayaki-active {
                color: var(--hoshi-sasayaki-text-color) !important;
                background-color: var(--hoshi-sasayaki-background-color) !important;
            }
            ruby > rt, ruby > rp { -webkit-user-select: none; }
            ruby.furigana-hidden > rp,
            ruby.furigana-hidden > rt > * {
                visibility: hidden !important;
            }
            \(dimmedFuriganaCss)
            \(hiddenFuriganaCss)
            \(HighlightColor.css)
            \(pageBreakCss)
            \(paragraphSpacingCss)
            \(paragraphModeCss)
            """

            let script = """
            (function() {
                var viewport = document.querySelector('meta[name="viewport"]');
                if (viewport) { viewport.remove(); }
                var newViewport = document.createElement('meta');
                newViewport.name = 'viewport';
                newViewport.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
                document.head.appendChild(newViewport);
                document.documentElement.style.setProperty('--page-height', '\(pageHeight)px');
                document.documentElement.style.setProperty('--page-width', '\(pageWidth)px');
                var style = document.createElement('style');
                style.innerHTML = `\(css)`;
                document.head.appendChild(style);
                \(textColorCss)
                \(backgroundColorCss)
                \(sasayakiColorCss)
                window.scanNonJapaneseText = \(parent.userConfig.scanNonJapaneseText);
                \(spacerJs)
                \(selectionScript)
                window.hoshiSelection.language = '\(parent.contentLanguageID)';
                \(readerScript)
                \(highlightsScript)
                \(paragraphScript)
                const lookupScanLength = \(parent.userConfig.scanLength);
                window.hoshiSelection.registerModifierTracking();
                window.hoshiSelection.registerShiftHoverLookup(lookupScanLength, \(parent.userConfig.desktopLookupHoverDelayMs));
                window.hoshiReader.pageHeight = \(pageHeight);
                window.hoshiReader.pageWidth = \(pageWidth);
                window.hoshiReader.horizontalPageColumns = \(horizontalPageColumns);
                window.hoshiReader.horizontalSpreadPageSize = \(horizontalSpreadPageSize);
                window.hoshiReader.registerCopyText?.();
                window.hoshiReader.registerWheelNavigation?.(\(!parent.userConfig.continuousMode && parent.userConfig.readerWheelPageTurnEnabled ? "true" : "false"));
                if (\(parent.userConfig.continuousMode ? "true" : "false") && !window.hoshiNativeProgressRegistered) {
                    window.hoshiNativeProgressRegistered = true;
                    var hoshiNativeProgressFrame = null;
                    var hoshiNativeLastProgressPost = 0;
                    const postNativeProgress = () => {
                        hoshiNativeProgressFrame = null;
                        const now = Date.now();
                        if (now - hoshiNativeLastProgressPost < 250) { return; }
                        hoshiNativeLastProgressPost = now;
                        const progress = window.hoshiReader.calculateProgress?.();
                        if (typeof progress === 'number' && Number.isFinite(progress)) {
                            window.webkit?.messageHandlers?.progressChanged?.postMessage(progress);
                        }
                    };
                    window.addEventListener('scroll', () => {
                        if (hoshiNativeProgressFrame === null) {
                            hoshiNativeProgressFrame = requestAnimationFrame(postNativeProgress);
                        }
                    }, { passive: true });
                }
                \(furiganaJs)

                // Wrap text directly under ruby nodes so selection/highlight ranges stay stable.
                document.querySelectorAll('ruby').forEach(ruby => {
                    [...ruby.childNodes].forEach(node => {
                        if (node.nodeType !== Node.TEXT_NODE) {
                            return;
                        }
                        if (node.textContent.trim()) {
                            const span = document.createElement('span');
                            span.textContent = node.textContent;
                            node.replaceWith(span);
                        } else {
                            node.remove();
                        }
                    });
                });

                function setupImage(element, src, wrap, blurElement = element) {
                    var target = element;
                    if (\(parent.userConfig.blurImages ? "true" : "false")) {
                        blurElement.classList.add('blurred');
                        if (wrap) {
                            target = document.createElement('div');
                            target.className = 'blur-wrapper';
                            blurElement.before(target);
                            target.append(blurElement);
                        }
                    }
                    target.onclick = event => {
                        event.preventDefault();
                        event.stopPropagation();
                        if (blurElement.classList.contains('blurred')) {
                            blurElement.classList.remove('blurred');
                            return;
                        }
                        webkit.messageHandlers.imageTapped.postMessage(new URL(src, document.baseURI).href);
                    };
                }

                document.querySelectorAll('svg[preserveAspectRatio="none"]').forEach(svg => svg.removeAttribute('preserveAspectRatio'));
                document.querySelectorAll('svg').forEach(svg => {
                    var svgImage = svg.querySelector('image');
                    if (!svgImage) {
                        return;
                    }
                    setupImage(svgImage, svgImage.href.baseVal, false, svg);
                });
                var imagePromises = Array.from(document.querySelectorAll('img')).map(img => {
                    return new Promise(resolve => {
                        function processImg() {
                            const isGaiji = img.classList.contains('gaiji') || img.classList.contains('gaiji-line');
                            if (!isGaiji && (img.naturalWidth > 256 || img.naturalHeight > 256)) {
                                img.classList.add('block-img');
                                setupImage(img, img.src, true);
                            }
                            resolve();
                        }
                        if (img.complete) {
                            if (img.naturalWidth > 0) {
                                processImg();
                            } else {
                                resolve();
                            }
                        } else {
                            img.onload = processImg;
                            img.onerror = () => resolve();
                        }
                    });
                });
                document.addEventListener('click', event => {
                    if (event.target?.closest?.('a, button, input, textarea, select, [contenteditable="true"]')) { return; }
                    if (window.hoshiParagraph?.finishTextAnimation()) {
                        event.preventDefault();
                        event.stopPropagation();
                        return;
                    }
                    const browserSelection = window.getSelection();
                    if (browserSelection && !browserSelection.isCollapsed) { return; }
                    const selected = window.hoshiSelection.selectText(event.clientX, event.clientY, lookupScanLength);
                    if (!selected) { webkit.messageHandlers.tapOutside.postMessage(null); }
                }, true);
                let restoreFallback = setTimeout(() => {
                    window.webkit?.messageHandlers?.restoreCompleted?.postMessage(null);
                }, 2500);
                Promise.all(imagePromises)
                    .then(() => new Promise(resolve => setTimeout(resolve, 50)))
                    .then(() => \(paragraphMode ? "document.fonts.ready.then(() => window.hoshiParagraph.layoutParagraphs())" : "null"))
                    .then(() => {
                        window.hoshiReader.buildNodeOffsets?.();
                        \(sasayakiSetupScript)
                        \(highlightsSetupScript)
                        return \(initialRestoreScript);
                    })
                    .catch(error => {
                        console.error('Native reader restore failed', error);
                        window.webkit?.messageHandlers?.restoreCompleted?.postMessage(null);
                    })
                    .finally(() => clearTimeout(restoreFallback));
            })();
            """

            if measuringPages {
                webView.evaluateJavaScript(script) { [weak self] _, error in
                    if error != nil { self?.finishMeasuringSpine([0]) }
                }
                return
            }

            webView.alphaValue = 0
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let self else { return }
                if let error {
                    print("NativeReaderWebView injection error: \(error.localizedDescription)")
                    webView.alphaValue = 1
                    self.parent.onRestoreCompleted()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak webView] in
                guard let self, let webView, webView.alphaValue == 0 else { return }
                print("NativeReaderWebView restore fallback")
                webView.alphaValue = 1
                self.parent.onRestoreCompleted()
            }
        }

        private func completeRestore() {
            parent.onRestoreCompleted()
        }

        fileprivate func navigate(_ direction: NativeReaderNavigationDirection) {
            guard let webView else { return }
            parent.onPageTurn()
            let jsDirection = direction == .forward ? "forward" : "backward"
            let script = parent.userConfig.continuousMode
                ? Self.continuousNavigationScript(direction: direction, currentProgress: parent.progress)
                : """
                (function() {
                    window.hoshiParagraph?.finishTextAnimation();
                    var result = window.hoshiReader.paginate('\(jsDirection)');
                    if (result === 'scrolled') {
                        \(direction == .forward ? textAnimationScript : "")
                    }
                    return result;
                })()
                """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                if let outcome = result as? String, outcome == "limit" {
                    if direction == .forward {
                        _ = self.parent.onNextChapter()
                    } else {
                        _ = self.parent.onPreviousChapter()
                    }
                    return
                }
                if self.parent.userConfig.continuousMode {
                    if let progress = result as? Double {
                        self.parent.onProgressChanged(progress)
                        self.parent.onSaveBookmark(progress)
                    } else if let progress = result as? NSNumber {
                        let value = progress.doubleValue
                        self.parent.onProgressChanged(value)
                        self.parent.onSaveBookmark(value)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.syncProgress()
                        }
                    }
                    return
                }
                self.syncProgress()
            }
        }

        /// Reveals the visible page text gradually in paragraph mode; reads the
        /// live settings so speed changes apply without reloading the chapter.
        private var textAnimationScript: String {
            guard parent.userConfig.paragraphMode,
                  !parent.userConfig.continuousMode,
                  parent.userConfig.textAnimation else { return "" }
            return "window.hoshiParagraph?.animateText(\(parent.userConfig.textSpeed));"
        }

        fileprivate func handleCommand(_ command: WebViewCommand) {
            guard let webView else { return }
            switch command {
            case .loadChapter,
                 .navigate,
                 .stepContinuous:
                break
            case .restoreProgress(let progress):
                webView.evaluateJavaScript("window.hoshiReader.restoreProgress(\(progress))") { [weak self] _, _ in
                    self?.syncInternalJumpProgress()
                }
            case .jumpToFragment(let fragment):
                let literal = Self.javaScriptStringLiteral(fragment)
                webView.evaluateJavaScript("window.hoshiReader.jumpToFragment(\(literal))") { [weak self] _, _ in
                    self?.syncInternalJumpProgress()
                }
            case .clearSelection:
                clearSelection()
            case .updateTextColor(let hex):
                applyTextColor(hex)
            case .updateSasayakiColors(let textHex, let backgroundHex):
                webView.evaluateJavaScript("""
                    document.documentElement.style.setProperty('--hoshi-sasayaki-text-color', '\(textHex)');
                    document.documentElement.style.setProperty('--hoshi-sasayaki-background-color', '\(backgroundHex)');
                """) { _, _ in }
            case .applySasayakiCues(let cues, let completion):
                webView.evaluateJavaScript("window.hoshiReader.applySasayakiCues(\(cues))") { _, _ in completion?() }
            case .highlightSasayakiCue(let id, let reveal):
                let cue = Self.javaScriptStringLiteral(id)
                let revealFlag = reveal ? "true" : "false"
                webView.evaluateJavaScript("window.hoshiReader.highlightSasayakiCue(\(cue), \(revealFlag))") { [weak self] result, _ in
                    guard let self else { return }
                    if let progress = result as? Double {
                        self.parent.onPageTurn()
                        self.parent.onProgressChanged(progress)
                        self.parent.onSaveBookmark(progress)
                    } else if let progress = result as? NSNumber {
                        let value = progress.doubleValue
                        self.parent.onPageTurn()
                        self.parent.onProgressChanged(value)
                        self.parent.onSaveBookmark(value)
                    }
                }
            case .clearSasayakiCue:
                webView.evaluateJavaScript("window.hoshiReader.clearSasayakiCue()") { _, _ in }
            case .removeHighlight(let id):
                let literal = Self.javaScriptStringLiteral(id)
                webView.evaluateJavaScript("window.hoshiHighlights.removeHighlight(\(literal))") { _, _ in }
            }
        }

        fileprivate func syncSasayakiColors() {
            webView?.evaluateJavaScript("""
                document.documentElement.style.setProperty('--hoshi-sasayaki-text-color', '\(parent.sasayakiTextColor)');
                document.documentElement.style.setProperty('--hoshi-sasayaki-background-color', '\(parent.sasayakiBackgroundColor)');
            """) { _, _ in }
        }

        private func clearSelection() {
            webView?.evaluateJavaScript("window.hoshiSelection?.clearSelection?.()") { _, _ in }
        }

        private static func continuousNavigationScript(
            direction: NativeReaderNavigationDirection,
            currentProgress: Double
        ) -> String {
            let jsDirection = direction == .forward ? "forward" : "backward"
            let current = min(max(currentProgress, 0), 1)
            return """
            (function() {
                const direction = '\(jsDirection)';
                const vertical = window.hoshiReader?.isVertical?.() === true;
                const current = \(current);
                const total = vertical
                    ? Math.max(document.documentElement.scrollWidth, document.body.scrollWidth, window.innerWidth)
                    : Math.max(document.documentElement.scrollHeight, document.body.scrollHeight, window.innerHeight);
                const view = vertical ? window.innerWidth : window.innerHeight;
                const step = Math.min(Math.max((view / total) * 0.92, 0.06), 0.25);
                const next = direction === 'forward' ? current + step : current - step;
                if ((direction === 'forward' && current >= 0.995) || (direction === 'backward' && current <= 0.005)) {
                    return 'limit';
                }
                const target = Math.min(Math.max(next, 0), 1);
                window.hoshiReader?.restoreProgress?.(target);
                return target;
            })()
            """
        }

        private func syncProgress() {
            webView?.evaluateJavaScript("window.hoshiReader.calculateProgress()") { [weak self] result, _ in
                guard let self, let progress = result as? Double else { return }
                self.parent.onProgressChanged(progress)
                self.parent.onSaveBookmark(progress)
            }
        }

        private func syncInternalJumpProgress() {
            webView?.evaluateJavaScript("window.hoshiReader.calculateProgress()") { [weak self] result, _ in
                guard let self, let progress = result as? Double else { return }
                self.parent.onProgressChanged(progress)
                self.parent.onInternalJump(progress)
            }
        }

        private func highlightSelection(count: Int) {
            webView?.evaluateJavaScript("window.hoshiSelection.highlightSelection(\(count))") { _, _ in }
        }

        private static func bundleString(_ name: String, extension ext: String) -> String {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext),
                  let content = try? String(contentsOf: url, encoding: .utf8) else {
                return ""
            }
            return content
        }

        private static func javaScriptStringLiteral(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8) else {
                return "''"
            }
            return encoded
        }
    }
}

struct NativeFullscreenImageView: View {
    let url: URL
    let backgroundColor: Color
    var isBlurred = false
    var onReveal: (() -> Void)? = nil
    var onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backgroundColor.ignoresSafeArea()
            NativeFullscreenImageWebView(url: url)
                .padding(24)
                .blur(radius: isBlurred ? 36 : 0)
                .overlay {
                    if isBlurred {
                        ZStack {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onReveal?()
                                }
                            Image(systemName: "eye.slash.fill")
                                .font(.largeTitle.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(16)
                                .background(.black.opacity(0.45), in: Circle())
                                .allowsHitTesting(false)
                                .accessibilityLabel(Text("Unread Image"))
                        }
                    }
                }
            NativeGlassCircleButton(systemName: "xmark", diameter: 38, fontSize: 15) {
                onDismiss()
            }
            .padding(24)
        }
    }
}

private struct NativeFullscreenImageWebView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        load(url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        load(url, in: webView, coordinator: context.coordinator)
    }

    private func load(_ url: URL, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        let data = url.isFileURL ? try? Data(contentsOf: url) : nil
        webView.loadHTMLString(
            NativeFullscreenImageDocument.html(for: url, data: data),
            baseURL: nil
        )
    }
}

private func nsColorHex(_ color: Color) -> String {
    let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .labelColor
    return ColorHexCodec.hexString(
        red: nsColor.redComponent,
        green: nsColor.greenComponent,
        blue: nsColor.blueComponent,
        alpha: nsColor.alphaComponent
    )
}
