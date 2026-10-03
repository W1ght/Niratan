import AppKit
import Foundation
import Observation

nonisolated enum MangaPageTurn: Equatable, Sendable {
    case forward
    case backward
}

/// Where a newly shown spread should start when it is larger than the window:
/// turning backward with the wheel lands on the end of the previous page.
nonisolated enum MangaPageEntryEdge: Equatable, Sendable {
    case start
    case end
}

/// One-shot instructions from the reader model to the AppKit canvas.
nonisolated struct MangaCanvasCommand: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        /// Pans by a fraction of the viewport.
        case pan(dx: Double, dy: Double)
        /// Zooms to a panel, given as a normalized top-left rect on the page
        /// at `pageOffset` of the displayed spread.
        case focusPanel(pageOffset: Int, rect: CGRect)
        /// Returns to the configured fit and zoom.
        case resetZoom
    }

    let id: UUID
    let kind: Kind

    init(_ kind: Kind) {
        id = UUID()
        self.kind = kind
    }
}

nonisolated enum MangaReaderSettingsScope: String, CaseIterable, Identifiable, Sendable {
    case thisManga
    case allManga

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .thisManga: "This Manga"
        case .allManga: "All Manga"
        }
    }
}

nonisolated enum MangaPanelNavigationStatus: Equatable, Sendable {
    case panel(Int, of: Int)
    case noPanels
    case unavailable
    case failed
}

@Observable
@MainActor
final class MangaReaderViewModel {
    private struct PendingProgress {
        let chapter: MangaReadingChapter
        let pageIndex: Int
        let pageCount: Int
        let completed: Bool
    }

    private struct PanelCursor: Equatable {
        let spreadKey: [Int]
        let index: Int
    }

    let session: MangaReadingSession
    let pageProvider: any MangaPageContentProvider
    let popupPresentation = PopupPresentationCoordinator()
    let settingsStore: MangaReaderSettingsStore

    /// The effective settings for this title: global values merged with this
    /// title's overrides.
    private(set) var settings: MangaReaderSettings
    var settingsScope: MangaReaderSettingsScope = .thisManga
    var showsSettingsPanel = false {
        didSet {
            guard showsSettingsPanel != oldValue else { return }
            if showsSettingsPanel {
                popupPresentation.closeAll()
            }
        }
    }
    var isInterfaceHidden = false
    /// Viewport size of the reading area, reported by the view; automatic
    /// spreads show two pages only when it is landscape.
    var viewportSize: CGSize = .zero {
        didSet {
            let wasLandscape = oldValue.width > oldValue.height
            let isLandscape = viewportSize.width > viewportSize.height
            if wasLandscape != isLandscape || oldValue == .zero {
                rebuildSpreads()
            }
        }
    }

    var currentPageIndex: Int
    private(set) var currentChapterIndex: Int
    private(set) var pageReferences: [MangaPageReference]
    private(set) var presentationPages: [MangaPresentationPage] = []
    private(set) var spreads: [[Int]] = []
    private(set) var isPreparingPages = false
    private(set) var isLoadingChapter = false
    private(set) var isContentAvailable = true
    var errorMessage: String?
    var isOCREnabled = false
    var isRecognizingText = false
    var ocrRegionsByPage: [Int: [MangaOCRTextRegion]] = [:]
    var mokuroRegionsByPage: [Int: [MangaOCRTextRegion]] = [:]
    var ocrStatusMessage: String?
    var ocrCompletedPageCount = 0
    var ocrTotalPageCount = 0
    var ocrScanCancellationID = 0
    private(set) var lookupPageIndex: Int?
    private(set) var pageTurn: MangaPageTurn?
    private(set) var pageTurnToken = 0
    private(set) var pageEntryEdge: MangaPageEntryEdge = .start
    private(set) var canvasCommand: MangaCanvasCommand?
    private(set) var transientHint: String?
    private(set) var panelStatus: MangaPanelNavigationStatus?
    private(set) var pageLuminanceBySource: [Int: Double] = [:]
    private(set) var detectedLongStrip: Bool?
    /// The resolved OCR engine for this session; nil until resolved.
    private(set) var ocrEngine: MangaOCREngineSelection?
    private var sourcePixelSizes: [Int: CGSize] = [:]

    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var activeOCRScanID: UUID?
    @ObservationIgnored private var ocrContentGeneration = UUID()
    @ObservationIgnored private var isOCRScanPaused = false
    @ObservationIgnored private var cachedPageAnalyses: [MangaPageAnalysis]?
    @ObservationIgnored private var activeChapterLoadID: UUID?
    @ObservationIgnored private var pendingProgressByChapter:
        [String: PendingProgress] = [:]
    @ObservationIgnored private var pendingProgressOrder: [String] = []
    @ObservationIgnored private var completedProgressChapterIDs:
        Set<String> = []
    @ObservationIgnored private var progressWriteTask: Task<Void, Never>?
    @ObservationIgnored private var boundaryNoticeKey: String?
    @ObservationIgnored private var sizeProbeTask: Task<Void, Never>?
    @ObservationIgnored private var probedSourcePages: Set<Int> = []
    @ObservationIgnored private var panelCursor: PanelCursor?
    @ObservationIgnored private var panelsByPresentationPage: [Int: [CGRect]] = [:]
    @ObservationIgnored private var panelTask: Task<Void, Never>?
    @ObservationIgnored private let suggestedMode: MangaReaderMode?
    @ObservationIgnored private let suggestedDirection: MangaReadingDirection?
    /// Resolves panels for a page image in reading order (normalized,
    /// top-left origin). Nil when the panel model is unavailable.
    @ObservationIgnored var panelDetector: (@Sendable (CGImage, Bool) async throws -> [CGRect]?)?

    init(
        session: MangaReadingSession,
        pageProvider: any MangaPageContentProvider,
        settingsStore: MangaReaderSettingsStore = .shared
    ) {
        self.session = session
        self.pageProvider = pageProvider
        self.settingsStore = settingsStore
        suggestedMode = session.suggestedLayout.map {
            $0 == .continuous ? .continuous : .paged
        }
        suggestedDirection = session.suggestedDirection
        let resolvedSettings = Self.resolvedSettings(
            store: settingsStore,
            documentID: session.documentID,
            suggestedMode: session.suggestedLayout.map {
                $0 == .continuous ? .continuous : .paged
            },
            suggestedDirection: session.suggestedDirection
        )
        settings = resolvedSettings
        // Recognition starts on open only for on-device engines, or for
        // Google Lens after the upload disclosure was accepted.
        isOCREnabled = resolvedSettings.ocrTrigger == .automatic
            && (!resolvedSettings.ocrEngine.uploadsPages
                || MangaOCREngineRouter.hasGoogleLensConsent())
        currentChapterIndex = min(
            max(0, session.initialChapterIndex),
            max(0, session.chapters.count - 1)
        )
        pageReferences = session.initialPages
        currentPageIndex = min(
            max(0, session.initialPageIndex),
            max(0, session.initialPages.count - 1)
        )
        let sourcePaths = session.initialPages.map(\.displayPath)
        presentationPages = MangaPagePresentationResolver.unprocessedPages(
            sourcePaths: sourcePaths
        )
        isPreparingPages = pageProcessingOptions.requiresAnalysis
        rebuildSpreads()
        alignCurrentPageToSpread()
        panelDetector = { image, rightToLeft in
            guard await MangaPanelDetector.shared.isReady() else { return nil }
            return try await MangaPanelDetector.shared.detectPanels(
                in: image,
                rightToLeft: rightToLeft
            )
        }
    }

    convenience init(
        item: MangaLibraryItem,
        source: MangaLibrarySource,
        profileID: String = ProfileRepository.shared.activeProfile.id,
        settingsStore: MangaReaderSettingsStore = .shared
    ) {
        do {
            let local = try MangaReadingSession.local(
                item: item,
                source: source,
                profileID: profileID
            )
            self.init(
                session: local.session,
                pageProvider: local.provider,
                settingsStore: settingsStore
            )
        } catch {
            let chapter = MangaReadingChapter(
                id: item.id,
                title: item.displayTitle
            )
            let fallback = MangaReadingSession(
                profileID: profileID,
                documentID: item.id,
                title: item.title,
                chapters: [chapter],
                initialChapterIndex: 0,
                initialPageIndex: item.currentPageIndex,
                initialPages: [],
                modifiedAt: item.modifiedAt,
                allowsCoverUpdates: false,
                suggestedLayout: nil,
                suggestedDirection: nil,
                progressWriter: { _, _, _, _ in },
                coverWriter: { _ in throw MangaPageLoaderError.pageUnavailable }
            )
            self.init(
                session: fallback,
                pageProvider: UnavailableMangaPageContentProvider(),
                settingsStore: settingsStore
            )
            errorMessage = error.localizedDescription
            isContentAvailable = false
        }
    }

    var title: String { session.title }
    var profileID: String { session.profileID }
    var allowsCoverUpdates: Bool { session.allowsCoverUpdates }
    var chapters: [MangaReadingChapter] { session.chapters }
    var currentChapter: MangaReadingChapter? {
        chapters.indices.contains(currentChapterIndex)
            ? chapters[currentChapterIndex]
            : nil
    }

    // MARK: Settings

    var direction: MangaReadingDirection { settings.direction }

    var mode: MangaReaderMode {
        if settings.autoDetectsMode, let detectedLongStrip {
            return detectedLongStrip ? .continuous : .paged
        }
        return settings.mode
    }

    var isDoubleSpread: Bool {
        guard mode == .paged else { return false }
        switch settings.spreadMode {
        case .single: return false
        case .double: return true
        case .automatic: return viewportSize.width > viewportSize.height
        }
    }

    /// The legacy three-way layout, kept for the canvas and tests.
    var layout: MangaReaderLayout {
        switch mode {
        case .continuous: .continuous
        case .verticalPaged: .singlePage
        case .paged: isDoubleSpread ? .doublePage : .singlePage
        }
    }

    var zoomPercentage: Int {
        get { settings.zoomPercentage }
        set {
            let clamped = min(
                MangaReaderSettings.maximumZoomPercentage,
                max(settings.minimumEffectiveZoomPercentage, newValue)
            )
            guard clamped != settings.zoomPercentage else { return }
            var next = settings
            next.zoomPercentage = clamped
            // In-page zoom is shared by every title, like Fushi's global zoom,
            // unless this title already keeps its own zoom.
            apply(
                next,
                scope: overriddenSettingKeys().contains("zoomPercentage")
                    ? .thisManga
                    : .allManga
            )
        }
    }

    var zoomScale: Double {
        Double(zoomPercentage) / 100
    }

    func overriddenSettingKeys() -> Set<String> {
        settingsStore.overriddenKeys(for: session.documentID)
    }

    /// Applies edited settings to the selected scope. Only the fields that
    /// changed are written, so a title override never copies unrelated values.
    func apply(
        _ newSettings: MangaReaderSettings,
        scope: MangaReaderSettingsScope? = nil
    ) {
        var newSettings = newSettings
        newSettings.normalize()
        guard newSettings != settings,
              let oldValues = MangaReaderSettingsStore.dictionary(from: settings),
              let newValues = MangaReaderSettingsStore.dictionary(from: newSettings) else {
            return
        }
        let resolvedScope = scope ?? settingsScope
        let documentID = resolvedScope == .thisManga ? session.documentID : nil
        for (key, value) in newValues {
            guard let oldValue = oldValues[key],
                  (oldValue as? NSObject)?.isEqual(value) != true else {
                continue
            }
            settingsStore.update(key, from: newSettings, documentID: documentID)
        }
        reloadSettings()
    }

    func resetOverride(_ key: String) {
        settingsStore.clearOverride(key, documentID: session.documentID)
        reloadSettings()
    }

    func resetAllOverrides() {
        settingsStore.clearOverrides(documentID: session.documentID)
        reloadSettings()
    }

    func toggleDirection() {
        var next = settings
        next.direction = settings.direction == .rightToLeft ? .leftToRight : .rightToLeft
        apply(next, scope: .thisManga)
    }

    func toggleReadingMode() {
        var next = settings
        next.autoDetectsMode = false
        next.mode = mode == .continuous ? .paged : .continuous
        apply(next, scope: .thisManga)
        showHint(String(localized: String.LocalizationValue(mode.titleKey)))
    }

    func cycleSpreadMode() {
        var next = settings
        switch settings.spreadMode {
        case .automatic: next.spreadMode = .single
        case .single: next.spreadMode = .double
        case .double: next.spreadMode = .automatic
        }
        apply(next, scope: .thisManga)
        showHint(String(localized: String.LocalizationValue(next.spreadMode.titleKey)))
    }

    func zoom(by percentage: Int) {
        zoomPercentage = zoomPercentage + percentage
    }

    private func reloadSettings() {
        let previous = settings
        let previousMode = mode
        settings = Self.resolvedSettings(
            store: settingsStore,
            documentID: session.documentID,
            suggestedMode: suggestedMode,
            suggestedDirection: suggestedDirection
        )
        settingsDidChange(from: previous, previousMode: previousMode)
    }

    private func settingsDidChange(
        from previous: MangaReaderSettings,
        previousMode: MangaReaderMode
    ) {
        guard previous != settings else { return }
        let processingChanged = previous.splitsWidePages != settings.splitsWidePages
            || previous.cropsBorders != settings.cropsBorders
            || previous.rotatesWidePages != settings.rotatesWidePages
        if previous.direction != settings.direction || processingChanged
            || previousMode != mode
            || previous.spreadMode != settings.spreadMode
            || previous.scaleType != settings.scaleType
            || previous.zoomPercentage != settings.zoomPercentage {
            popupPresentation.closeAll()
            resetPanelNavigation()
        }
        if processingChanged {
            pageProcessingPreferenceDidChange()
        } else if previous.direction != settings.direction {
            rebuildPresentationPagesIfPossible()
        }
        if previous.spreadMode != settings.spreadMode
            || previous.showsCoverAlone != settings.showsCoverAlone
            || previous.showsWidePagesAlone != settings.showsWidePagesAlone
            || previousMode != mode {
            rebuildSpreads()
        }
        if settings.autoDetectsMode, detectedLongStrip == nil {
            detectLongStrip()
        }
        if previous.ocrEngine != settings.ocrEngine {
            Task { await refreshOCREngine() }
        }
        if previous.panelNavigation != settings.panelNavigation {
            resetPanelNavigation()
            panelStatus = nil
        }
    }

    private static func resolvedSettings(
        store: MangaReaderSettingsStore,
        documentID: String,
        suggestedMode: MangaReaderMode?,
        suggestedDirection: MangaReadingDirection?
    ) -> MangaReaderSettings {
        var settings = store.effectiveSettings(for: documentID)
        let overridden = store.overriddenKeys(for: documentID)
        // Source hints (for example a webtoon source) act as this title's
        // default until the reader chooses a value for the title.
        if let suggestedMode, !overridden.contains("mode"), !settings.autoDetectsMode {
            settings.mode = suggestedMode
        }
        if let suggestedDirection, !overridden.contains("direction") {
            settings.direction = suggestedDirection
        }
        return settings
    }

    // MARK: Pages

    var pageCount: Int {
        presentationPages.count
    }

    var sourcePageCount: Int {
        pageReferences.count
    }

    var displayedPageIndices: [Int] {
        guard mode != .continuous else { return [currentPageIndex] }
        let spread = currentSpread
        return direction == .rightToLeft ? Array(spread.reversed()) : spread
    }

    var displayedPages: [MangaPresentationPage] {
        displayedPageIndices.compactMap {
            presentationPages.indices.contains($0)
                ? presentationPages[$0]
                : nil
        }
    }

    private var currentSpread: [Int] {
        guard pageCount > 0 else { return [] }
        if let index = MangaSpreadResolver.spreadIndex(
            containing: currentPageIndex,
            in: spreads
        ) {
            return spreads[index]
        }
        return [min(max(0, currentPageIndex), pageCount - 1)]
    }

    private var currentSpreadIndex: Int? {
        MangaSpreadResolver.spreadIndex(containing: currentPageIndex, in: spreads)
    }

    var pageLabel: String {
        guard pageCount > 0 else { return "0 / 0" }
        let spread = currentSpread
        if mode != .continuous, spread.count > 1 {
            return "\(spread[0] + 1)–\(spread[spread.count - 1] + 1) / \(pageCount)"
        }
        return "\(currentPageIndex + 1) / \(pageCount)"
    }

    var hasPreviousChapter: Bool {
        currentChapterIndex > 0
    }

    var hasNextChapter: Bool {
        currentChapterIndex + 1 < chapters.count
    }

    var canGoBackward: Bool {
        if mode == .continuous {
            return currentPageIndex > 0 || hasPreviousChapter
        }
        return (currentSpreadIndex ?? 0) > 0 || hasPreviousChapter
    }

    var canGoForward: Bool {
        if mode == .continuous {
            return currentPageIndex < pageCount - 1 || hasNextChapter
        }
        return (currentSpreadIndex ?? 0) < spreads.count - 1 || hasNextChapter
    }

    var visibleOCRRequestID: String {
        let sourceIndices = displayedPages.map(\.sourcePageIndex)
        return "\(currentChapterIndex)|\(isOCREnabled)|\(ocrEngine?.signature ?? "-")|\(sourceIndices.map(String.init).joined(separator: ","))"
    }

    var fullOCRRequestID: String {
        "\(currentChapterIndex)|\(isOCREnabled)|\(mode == .continuous)|\(ocrScanCancellationID)|\(ocrEngine?.signature ?? "-")"
    }

    var pageProcessingOptions: MangaPageProcessingOptions {
        MangaPageProcessingOptions(
            splitsWidePages: settings.splitsWidePages,
            readingDirection: direction,
            cropsWhiteBorders: settings.cropsBorders,
            rotatesWidePages: settings.rotatesWidePages
        )
    }

    var pageProcessingRequestID: String {
        [
            settings.splitsWidePages.description,
            direction.rawValue,
            settings.cropsBorders.description,
            settings.rotatesWidePages.description,
            String(currentChapterIndex),
        ].joined(separator: "|")
    }

    var ocrProgress: Double {
        guard ocrTotalPageCount > 0 else { return 0 }
        return Double(ocrCompletedPageCount) / Double(ocrTotalPageCount)
    }

    var isOCRRecognitionPaused: Bool {
        isOCRScanPaused
    }

    var visibleOCRRegions: [Int: [MangaOCRTextRegion]] {
        Dictionary(
            uniqueKeysWithValues: displayedPages.map { page in
                (
                    page.index,
                    MangaPageProcessor.regions(
                        rawLookupRegions(at: page.sourcePageIndex),
                        for: page
                    )
                )
            }
        )
    }

    func lookupRegions(for page: MangaPresentationPage) -> [MangaOCRTextRegion] {
        MangaPageProcessor.regions(
            rawLookupRegions(at: page.sourcePageIndex),
            for: page
        )
    }

    func lookupRequestID(for page: MangaPresentationPage) -> String {
        "\(page.sourcePageIndex)|\(page.index)|\(isOCREnabled)|\(pageProcessingRequestID)"
    }

    var allVisiblePagesUseMokuro: Bool {
        displayedPages.allSatisfy {
            mokuroRegionsByPage[$0.sourcePageIndex] != nil
        }
    }

    /// Background luminance of the first displayed page, for the automatic
    /// background.
    var currentPageLuminance: Double? {
        displayedPages.first.flatMap { pageLuminanceBySource[$0.sourcePageIndex] }
    }

    var pageBackgroundColor: NSColor {
        settings.backgroundColor(pageLuminance: currentPageLuminance)
    }

    func preparePageProcessing() async {
        if settings.autoDetectsMode, detectedLongStrip == nil {
            detectLongStrip()
        }
        guard pageProcessingOptions.requiresAnalysis else {
            isPreparingPages = false
            rebuildPresentationPages(using: nil)
            return
        }
        if let cachedPageAnalyses {
            isPreparingPages = false
            rebuildPresentationPages(using: cachedPageAnalyses)
            return
        }
        guard !pageReferences.isEmpty else { return }

        isPreparingPages = true
        let provider = pageProvider
        let references = pageReferences
        let analysisTask = Task(priority: .userInitiated) {
            var analyses: [MangaPageAnalysis] = []
            analyses.reserveCapacity(references.count)
            for page in references {
                try Task.checkCancellation()
                let payload = try await provider.payload(for: page)
                guard let imageData = payload.imageData else {
                    analyses.append(MangaPageAnalysis(
                        pixelWidth: 1200,
                        pixelHeight: 1800,
                        whiteBorderContentRect: CGRect(
                            x: 0,
                            y: 0,
                            width: 1,
                            height: 1
                        )
                    ))
                    continue
                }
                analyses.append(
                    try MangaPageProcessor.analyze(
                        imageData
                    )
                )
            }
            return analyses
        }
        do {
            let analyses = try await withTaskCancellationHandler {
                try await analysisTask.value
            } onCancel: {
                analysisTask.cancel()
            }
            try Task.checkCancellation()
            cachedPageAnalyses = analyses
            for (index, analysis) in analyses.enumerated() {
                sourcePixelSizes[index] = CGSize(
                    width: analysis.pixelWidth,
                    height: analysis.pixelHeight
                )
                pageLuminanceBySource[index] = analysis.backgroundLuminance
            }
            isPreparingPages = false
            rebuildPresentationPages(using: analyses)
        } catch is CancellationError {
            return
        } catch {
            isPreparingPages = false
            showOCRStatus(error.localizedDescription)
        }
    }

    // MARK: Navigation

    func goBackward() {
        turn(.backward, entryEdge: .start)
    }

    func goForward() {
        turn(.forward, entryEdge: .start)
    }

    /// Wheel paging lands on the matching edge of an enlarged page.
    func turnFromWheel(_ turn: MangaPageTurn) {
        self.turn(turn, entryEdge: turn == .backward ? .end : .start)
    }

    func handleLeftArrow() {
        if direction == .rightToLeft {
            goForward()
        } else {
            goBackward()
        }
    }

    func handleRightArrow() {
        if direction == .rightToLeft {
            goBackward()
        } else {
            goForward()
        }
    }

    func handleTapZone(_ action: MangaTapZoneAction) {
        switch action {
        case .next: goForward()
        case .previous: goBackward()
        case .menu: toggleInterface()
        }
    }

    func toggleInterface() {
        isInterfaceHidden.toggle()
    }

    func pan(dx: Double, dy: Double) {
        canvasCommand = MangaCanvasCommand(.pan(dx: dx, dy: dy))
    }

    @discardableResult
    func handleEscape() -> Bool {
        if !popupPresentation.popups.isEmpty {
            popupPresentation.closeAll()
            return true
        }
        if showsSettingsPanel {
            showsSettingsPanel = false
            return true
        }
        if isInterfaceHidden {
            isInterfaceHidden = false
            return true
        }
        return false
    }

    func go(to pageIndex: Int) {
        go(to: pageIndex, turn: nil, entryEdge: .start)
    }

    func goToFirstPage() {
        go(to: 0, turn: .backward, entryEdge: .start)
    }

    func goToLastPage() {
        go(to: pageCount - 1, turn: .forward, entryEdge: .start)
    }

    private func go(
        to pageIndex: Int,
        turn: MangaPageTurn?,
        entryEdge: MangaPageEntryEdge
    ) {
        guard pageCount > 0 else { return }
        var clamped = min(max(0, pageIndex), pageCount - 1)
        if mode != .continuous,
           let spreadIndex = MangaSpreadResolver.spreadIndex(
               containing: clamped,
               in: spreads
           ) {
            clamped = spreads[spreadIndex][0]
        }
        guard clamped != currentPageIndex else { return }
        popupPresentation.closeAll()
        resetPanelNavigation()
        if let turn {
            pageTurn = turn
            pageTurnToken += 1
        } else {
            pageTurn = nil
        }
        pageEntryEdge = entryEdge
        currentPageIndex = clamped
        persistProgress()
        probePageSizesIfNeeded()
    }

    private func turn(_ turn: MangaPageTurn, entryEdge: MangaPageEntryEdge) {
        guard pageCount > 0 else {
            advanceChapter(turn)
            return
        }
        if mode != .continuous,
           settings.panelNavigation,
           advancePanel(turn) {
            return
        }
        if mode == .continuous {
            let target = currentPageIndex + (turn == .forward ? 1 : -1)
            if presentationPages.indices.contains(target) {
                go(to: target, turn: turn, entryEdge: entryEdge)
            } else {
                advanceChapter(turn)
            }
            return
        }
        let spreadIndex = currentSpreadIndex ?? 0
        let target = spreadIndex + (turn == .forward ? 1 : -1)
        if spreads.indices.contains(target) {
            go(to: spreads[target][0], turn: turn, entryEdge: entryEdge)
        } else {
            advanceChapter(turn)
        }
    }

    /// Fushi opens the neighbouring chapter when paging past either end; going
    /// backward lands on the previous chapter's last page.
    private func advanceChapter(_ turn: MangaPageTurn) {
        guard !isLoadingChapter else { return }
        switch turn {
        case .forward:
            guard hasNextChapter else {
                showBoundaryNotice(String(localized: "This is the last page."))
                return
            }
            let next = currentChapterIndex + 1
            pageTurn = .forward
            pageTurnToken += 1
            Task { await openChapter(at: next, pageIndex: 0) }
        case .backward:
            guard hasPreviousChapter else {
                showBoundaryNotice(String(localized: "This is the first page."))
                return
            }
            let previous = currentChapterIndex - 1
            pageTurn = .backward
            pageTurnToken += 1
            Task { await openChapter(at: previous, pageIndex: Int.max) }
        }
    }

    private func showBoundaryNotice(_ message: String) {
        let key = "\(currentChapterIndex)|\(message)"
        guard boundaryNoticeKey != key else { return }
        boundaryNoticeKey = key
        showOCRStatus(message)
    }

    func openChapter(at index: Int, pageIndex: Int = 0) async {
        guard chapters.indices.contains(index),
              index != currentChapterIndex || pageReferences.isEmpty else {
            return
        }
        invalidateOCRForChapterChange()
        persistProgress()
        popupPresentation.closeAll()
        resetPanelNavigation()
        isLoadingChapter = true
        isPreparingPages = false
        errorMessage = nil
        let loadID = UUID()
        activeChapterLoadID = loadID
        await pageProvider.cancelPendingRequests()
        let chapter = chapters[index]
        do {
            let pages = try await pageProvider.pages(for: chapter)
            try Task.checkCancellation()
            guard activeChapterLoadID == loadID else { return }
            currentChapterIndex = index
            pageReferences = pages
            cachedPageAnalyses = nil
            sourcePixelSizes = [:]
            pageLuminanceBySource = [:]
            probedSourcePages = []
            detectedLongStrip = nil
            panelsByPresentationPage = [:]
            boundaryNoticeKey = nil
            currentPageIndex = min(
                max(0, pageIndex),
                max(0, pages.count - 1)
            )
            presentationPages =
                MangaPagePresentationResolver.unprocessedPages(
                    sourcePaths: pages.map(\.displayPath)
                )
            rebuildSpreads()
            alignCurrentPageToSpread()
            isContentAvailable = !pages.isEmpty
            isLoadingChapter = false
            activeChapterLoadID = nil
            isPreparingPages = pageProcessingOptions.requiresAnalysis
            persistProgress()
            if isPreparingPages {
                await preparePageProcessing()
            } else if settings.autoDetectsMode {
                detectLongStrip()
            }
        } catch is CancellationError {
            guard activeChapterLoadID == loadID else { return }
            isLoadingChapter = false
            activeChapterLoadID = nil
        } catch {
            guard activeChapterLoadID == loadID else { return }
            isLoadingChapter = false
            activeChapterLoadID = nil
            errorMessage = error.localizedDescription
        }
    }

    func goToPreviousChapter() async {
        guard hasPreviousChapter else { return }
        await openChapter(at: currentChapterIndex - 1)
    }

    func goToNextChapter() async {
        guard hasNextChapter else { return }
        await openChapter(at: currentChapterIndex + 1)
    }

    // MARK: Hints

    func showReadingModeHintIfNeeded() {
        guard settings.showsReadingModeHint else { return }
        let modeTitle = String(localized: String.LocalizationValue(mode.titleKey))
        if mode == .paged {
            let spreadTitle = String(
                localized: String.LocalizationValue(
                    isDoubleSpread ? MangaSpreadMode.double.titleKey : MangaSpreadMode.single.titleKey
                )
            )
            showHint("\(modeTitle) · \(spreadTitle)")
        } else {
            showHint(modeTitle)
        }
    }

    func showHint(_ message: String) {
        transientHint = message
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            transientHint = nil
        }
    }

    // MARK: Spreads and geometry

    /// Height / width of a display page, from its decoded size when known.
    /// Long-strip placeholders use it so scrolling to a page lands correctly
    /// before every image above it has been decoded.
    func pageAspectRatio(for page: MangaPresentationPage) -> CGFloat {
        guard let size = sourcePixelSizes[page.sourcePageIndex],
              size.width > 0, size.height > 0 else {
            return 1.42
        }
        var width = size.width * page.transform.sourceRect.width
        var height = size.height * page.transform.sourceRect.height
        if page.transform.rotatesClockwise {
            swap(&width, &height)
        }
        return width > 0 ? height / width : 1.42
    }

    private func rebuildSpreads() {
        let double = isDoubleSpread
        let pages = presentationPages
        let sizes = sourcePixelSizes
        let next = MangaSpreadResolver.spreads(
            pageCount: pages.count,
            isDouble: double,
            showsCoverAlone: settings.showsCoverAlone,
            showsWidePagesAlone: settings.showsWidePagesAlone,
            isWide: { index in
                guard pages.indices.contains(index),
                      let size = sizes[pages[index].sourcePageIndex] else {
                    return false
                }
                let transform = pages[index].transform
                var width = size.width * transform.sourceRect.width
                var height = size.height * transform.sourceRect.height
                if transform.rotatesClockwise {
                    swap(&width, &height)
                }
                return width >= height
            }
        )
        guard next != spreads else { return }
        spreads = next
        alignCurrentPageToSpread()
        if double {
            probePageSizesIfNeeded()
        }
    }

    private func alignCurrentPageToSpread() {
        guard mode != .continuous,
              let spreadIndex = currentSpreadIndex else {
            return
        }
        currentPageIndex = spreads[spreadIndex][0]
    }

    /// Wide-page pairing needs page sizes; read the image headers of nearby
    /// pages ahead of time so spreads settle before the reader reaches them.
    private func probePageSizesIfNeeded() {
        guard isDoubleSpread, settings.showsWidePagesAlone,
              !presentationPages.isEmpty else {
            return
        }
        let center = presentationPages.indices.contains(currentPageIndex)
            ? presentationPages[currentPageIndex].sourcePageIndex
            : 0
        let indices = ((center - 2)...(center + 8)).filter {
            pageReferences.indices.contains($0)
                && sourcePixelSizes[$0] == nil
                && !probedSourcePages.contains($0)
        }
        guard !indices.isEmpty else { return }
        probedSourcePages.formUnion(indices)
        let references = indices.map { pageReferences[$0] }
        let provider = pageProvider
        let generation = ocrContentGeneration
        sizeProbeTask = Task(priority: .utility) { [weak self] in
            var sizes: [Int: CGSize] = [:]
            for (index, reference) in zip(indices, references) {
                guard !Task.isCancelled,
                      let payload = try? await provider.payload(for: reference),
                      let data = payload.imageData,
                      let size = MangaPageProcessor.pixelSize(of: data) else {
                    continue
                }
                sizes[index] = size
            }
            guard let self, !Task.isCancelled,
                  self.ocrContentGeneration == generation,
                  !sizes.isEmpty else {
                return
            }
            self.sourcePixelSizes.merge(sizes) { _, new in new }
            self.rebuildSpreads()
        }
    }

    private func recordPageGeometry(sourcePageIndex: Int, data: Data) {
        guard sourcePixelSizes[sourcePageIndex] == nil
                || (settings.usesAutomaticBackground
                    && pageLuminanceBySource[sourcePageIndex] == nil) else {
            return
        }
        let needsLuminance = settings.usesAutomaticBackground
            && pageLuminanceBySource[sourcePageIndex] == nil
        let generation = ocrContentGeneration
        Task(priority: .utility) { [weak self] in
            let geometry = await Task.detached(priority: .utility) {
                (
                    MangaPageProcessor.pixelSize(of: data),
                    needsLuminance ? MangaPageProcessor.backgroundLuminance(of: data) : nil
                )
            }.value
            guard let self, self.ocrContentGeneration == generation else { return }
            if let luminance = geometry.1 {
                self.pageLuminanceBySource[sourcePageIndex] = luminance
            }
            if let size = geometry.0, self.sourcePixelSizes[sourcePageIndex] == nil {
                self.sourcePixelSizes[sourcePageIndex] = size
                if self.isDoubleSpread, self.settings.showsWidePagesAlone {
                    self.rebuildSpreads()
                }
            }
        }
    }

    /// Fushi's automatic mode: a median page height/width ratio above 2 means
    /// a long-strip (webtoon) chapter.
    private func detectLongStrip() {
        let references = Array(pageReferences.prefix(5))
        guard !references.isEmpty else { return }
        let provider = pageProvider
        let generation = ocrContentGeneration
        Task(priority: .utility) { [weak self] in
            var ratios: [Double] = []
            for reference in references {
                guard let payload = try? await provider.payload(for: reference),
                      let data = payload.imageData,
                      let size = MangaPageProcessor.pixelSize(of: data),
                      size.width > 0 else {
                    continue
                }
                ratios.append(size.height / size.width)
            }
            guard let self, self.ocrContentGeneration == generation,
                  !ratios.isEmpty else {
                return
            }
            let sorted = ratios.sorted()
            let median = sorted[sorted.count / 2]
            let previousMode = self.mode
            self.detectedLongStrip = median > MangaReaderSettings.webtoonAspectThreshold
            if previousMode != self.mode {
                self.rebuildSpreads()
                self.alignCurrentPageToSpread()
            }
        }
    }

    // MARK: Panel navigation

    private func resetPanelNavigation() {
        panelTask?.cancel()
        panelTask = nil
        if panelCursor != nil {
            panelCursor = nil
            canvasCommand = MangaCanvasCommand(.resetZoom)
        }
        if settings.panelNavigation {
            panelStatus = nil
        }
    }

    /// Steps through the panels of the displayed spread in reading order.
    /// Returns false when the page itself should turn.
    private func advancePanel(_ turn: MangaPageTurn) -> Bool {
        let spread = currentSpread
        guard !spread.isEmpty else { return false }
        let readingOrderPages = spread
        var flattened: [(pageIndex: Int, rect: CGRect)] = []
        var missing: [Int] = []
        for pageIndex in readingOrderPages {
            if let panels = panelsByPresentationPage[pageIndex] {
                flattened.append(contentsOf: panels.map { (pageIndex, $0) })
            } else {
                missing.append(pageIndex)
            }
        }
        if !missing.isEmpty {
            guard panelDetector != nil else {
                panelStatus = .unavailable
                return false
            }
            loadPanels(for: missing, thenAdvance: turn)
            return true
        }
        guard !flattened.isEmpty else {
            panelStatus = .noPanels
            return false
        }
        let next: Int
        if let panelCursor, panelCursor.spreadKey == spread {
            next = panelCursor.index + (turn == .forward ? 1 : -1)
        } else {
            next = turn == .forward ? 0 : flattened.count - 1
        }
        guard flattened.indices.contains(next) else {
            panelCursor = nil
            return false
        }
        panelCursor = PanelCursor(spreadKey: spread, index: next)
        let target = flattened[next]
        let displayOffset = displayedPageIndices.firstIndex(of: target.pageIndex) ?? 0
        canvasCommand = MangaCanvasCommand(
            .focusPanel(pageOffset: displayOffset, rect: target.rect)
        )
        panelStatus = .panel(next + 1, of: flattened.count)
        return true
    }

    private func loadPanels(for pageIndices: [Int], thenAdvance turn: MangaPageTurn) {
        guard panelTask == nil, let panelDetector else { return }
        let pages = pageIndices.compactMap { index in
            presentationPages.indices.contains(index) ? presentationPages[index] : nil
        }
        let references = pageReferences
        let provider = pageProvider
        let rightToLeft = direction == .rightToLeft
        let spread = currentSpread
        panelTask = Task { [weak self] in
            var results: [Int: [CGRect]] = [:]
            var failed = false
            var unavailable = false
            for page in pages {
                guard references.indices.contains(page.sourcePageIndex) else { continue }
                do {
                    let payload = try await provider.payload(for: references[page.sourcePageIndex])
                    guard let data = payload.imageData else {
                        results[page.index] = []
                        continue
                    }
                    let rendered = try await Task.detached(priority: .userInitiated) {
                        try MangaPageProcessor.renderedImage(from: data, transform: page.transform)
                    }.value
                    guard let image = rendered.image.cgImage(
                        forProposedRect: nil,
                        context: nil,
                        hints: nil
                    ) else {
                        results[page.index] = []
                        continue
                    }
                    guard let panels = try await panelDetector(image, rightToLeft) else {
                        unavailable = true
                        break
                    }
                    results[page.index] = panels
                } catch is CancellationError {
                    return
                } catch {
                    failed = true
                    results[page.index] = []
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.panelTask = nil
            if unavailable {
                self.panelStatus = .unavailable
                return
            }
            self.panelsByPresentationPage.merge(results) { _, new in new }
            if failed {
                self.panelStatus = .failed
            }
            guard self.currentSpread == spread else { return }
            if !self.advancePanel(turn) {
                self.turnPageIgnoringPanels(turn)
            }
        }
    }

    private func turnPageIgnoringPanels(_ turn: MangaPageTurn) {
        let spreadIndex = currentSpreadIndex ?? 0
        let target = spreadIndex + (turn == .forward ? 1 : -1)
        if spreads.indices.contains(target) {
            go(to: spreads[target][0], turn: turn, entryEdge: .start)
        } else {
            advanceChapter(turn)
        }
    }

    // MARK: OCR

    /// Resolves "Automatic" against the downloaded models. Called on open,
    /// when the engine preference changes and after model downloads.
    func refreshOCREngine() async {
        let selection = await MangaOCREngineRouter.resolve(settings.ocrEngine)
        guard selection != ocrEngine else { return }
        let hadEngine = ocrEngine != nil
        ocrEngine = selection
        if hadEngine {
            // Each engine has its own cache; show the new engine's pages.
            ocrRegionsByPage = [:]
            activeOCRScanID = nil
            isRecognizingText = false
            isOCRScanPaused = false
            ocrScanCancellationID += 1
        }
    }

    /// Fushi's "Re-run OCR on this volume": drops this engine's cached pages
    /// for the current chapter and recognizes them again.
    func rerunOCR() {
        guard let ocrEngine else { return }
        let itemID = ocrCacheItemID
        let language = ocrLanguage
        popupPresentation.closeAll()
        ocrRegionsByPage = [:]
        activeOCRScanID = nil
        isRecognizingText = false
        isOCRScanPaused = false
        isOCREnabled = true
        Task {
            await MangaOCRService.shared.clear(
                itemID: itemID,
                engineID: ocrEngine.engine.cacheEngineID,
                language: language
            )
            ocrScanCancellationID += 1
        }
    }

    func toggleOCR() {
        isOCREnabled.toggle()
        isOCRScanPaused = false
        ocrScanCancellationID += 1
        popupPresentation.closeAll()
        if !isOCREnabled {
            isRecognizingText = false
            activeOCRScanID = nil
        }
    }

    func cancelOCRRecognition() {
        guard isRecognizingText else { return }
        isOCRScanPaused = true
        activeOCRScanID = nil
        isRecognizingText = false
        ocrScanCancellationID += 1
        showOCRStatus(
            String(localized: "Text recognition paused. Completed pages remain available.")
        )
    }

    func resumeOCRRecognition() {
        guard isOCREnabled, isOCRScanPaused else { return }
        isOCRScanPaused = false
        ocrScanCancellationID += 1
    }

    func loadVisibleOCRRegions() async {
        guard !isLoadingChapter else { return }
        await loadOCRRegions(
            for: Array(Set(displayedPages.map(\.sourcePageIndex))).sorted()
        )
    }

    func loadOCRRegions(for requestedIndices: [Int]) async {
        guard !isLoadingChapter else { return }
        let contentGeneration = ocrContentGeneration
        let requestedIndices = requestedIndices.filter {
            $0 >= 0 && $0 < sourcePageCount
        }
        guard !requestedIndices.isEmpty else { return }

        do {
            for pageIndex in requestedIndices where mokuroRegionsByPage[pageIndex] == nil {
                try Task.checkCancellation()
                guard pageReferences.indices.contains(pageIndex) else {
                    throw MangaPageLoaderError.pageUnavailable
                }
                let payload = try await pageProvider.payload(
                    for: pageReferences[pageIndex]
                )
                let regions = payload.embeddedTextRegions
                try Task.checkCancellation()
                guard ocrContentGeneration == contentGeneration else {
                    return
                }
                if let regions {
                    mokuroRegionsByPage[pageIndex] = regions
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard ocrContentGeneration == contentGeneration else {
                return
            }
            showOCRStatus(error.localizedDescription)
            return
        }

        guard isOCREnabled else { return }
        let pagePaths = ocrPageIdentities
        for pageIndex in requestedIndices
        where mokuroRegionsByPage[pageIndex] == nil
            && ocrRegionsByPage[pageIndex] == nil {
            try? Task.checkCancellation()
            guard !Task.isCancelled,
                  let key = ocrCacheKey(
                      pageIndex: pageIndex,
                      pagePaths: pagePaths
                  ) else {
                return
            }
            if let regions = await MangaOCRService.shared.cachedRegions(
                for: key,
                pagePaths: pagePaths
            ) {
                guard isOCREnabled,
                      ocrContentGeneration == contentGeneration else {
                    return
                }
                ocrRegionsByPage[pageIndex] = regions
            }
        }
    }

    func recognizeAllPages() async {
        guard isOCREnabled,
              !isOCRScanPaused,
              !isLoadingChapter,
              sourcePageCount > 0,
              let currentChapter,
              let selection = ocrEngine else {
            return
        }
        // Google Lens never runs without the upload disclosure.
        if selection.engine.uploadsPages,
           !MangaOCREngineRouter.hasGoogleLensConsent() {
            return
        }
        guard selection.isAvailable else {
            showOCRStatus(
                String(localized: "Download the OCR model in Reader Settings to recognize text.")
            )
            return
        }
        let contentGeneration = ocrContentGeneration

        do {
            let usesMokuro = try await pageProvider.hasEmbeddedText(
                for: currentChapter
            )
            guard ocrContentGeneration == contentGeneration else {
                return
            }
            if usesMokuro {
                await loadVisibleOCRRegions()
                return
            }
        } catch is CancellationError {
            return
        } catch {
            guard ocrContentGeneration == contentGeneration else {
                return
            }
            showOCRStatus(error.localizedDescription)
            return
        }

        let scanID = UUID()
        activeOCRScanID = scanID
        isRecognizingText = true
        ocrCompletedPageCount = 0
        ocrTotalPageCount = sourcePageCount
        defer {
            if activeOCRScanID == scanID {
                activeOCRScanID = nil
                isRecognizingText = false
            }
        }

        let sourcePageIndex = currentSourcePageIndex
        let pageOrder = Array(sourcePageIndex..<sourcePageCount)
            + Array(0..<sourcePageIndex)
        var requestedNetworkPage = false
        var hasFailedPages = false
        let pagePaths = ocrPageIdentities

        for pageIndex in pageOrder {
            do {
                try Task.checkCancellation()
                guard isOCREnabled,
                      activeOCRScanID == scanID,
                      ocrContentGeneration == contentGeneration,
                      let key = ocrCacheKey(
                          pageIndex: pageIndex,
                          pagePaths: pagePaths
                      ) else {
                    throw CancellationError()
                }

                if let regions = await MangaOCRService.shared.cachedRegions(
                    for: key,
                    pagePaths: pagePaths
                ) {
                    guard isOCREnabled,
                          activeOCRScanID == scanID,
                          ocrContentGeneration == contentGeneration else {
                        throw CancellationError()
                    }
                    ocrRegionsByPage[pageIndex] = regions
                    ocrCompletedPageCount += 1
                    continue
                }

                let payload = try await payloadForOCR(at: pageIndex)
                guard let imageData = payload.imageData else {
                    throw MangaPageLoaderError.pageUnavailable
                }
                try Task.checkCancellation()
                guard isOCREnabled,
                      activeOCRScanID == scanID,
                      ocrContentGeneration == contentGeneration else {
                    throw CancellationError()
                }
                requestedNetworkPage = true
                let regions: [MangaOCRTextRegion]
                switch selection.engine {
                case .googleLens:
                    regions = try await MangaOCRService.shared.recognizeText(
                        in: imageData,
                        key: key,
                        pagePaths: pagePaths
                    )
                case .appleVision, .local:
                    let engine = selection.engine
                    let language = key.language
                    let rightToLeft = direction == .rightToLeft
                    regions = try await MangaOCRService.shared.recognizeText(
                        in: imageData,
                        key: key,
                        pagePaths: pagePaths,
                        idPrefix: engine.cacheEngineID
                    ) { data in
                        try await MangaOCREngineRouter.recognize(
                            data,
                            engine: engine,
                            language: language,
                            rightToLeft: rightToLeft
                        )
                    }
                }
                try Task.checkCancellation()
                guard isOCREnabled,
                      activeOCRScanID == scanID,
                      ocrContentGeneration == contentGeneration else {
                    throw CancellationError()
                }
                ocrRegionsByPage[pageIndex] = regions
                ocrCompletedPageCount += 1
            } catch is CancellationError {
                return
            } catch {
                guard activeOCRScanID == scanID,
                      ocrContentGeneration == contentGeneration else {
                    return
                }
                hasFailedPages = true
                ocrCompletedPageCount += 1
            }
        }
        if hasFailedPages {
            showOCRStatus(
                String(
                    localized:
                        "Text recognition finished with some pages pending. They will be retried next time."
                )
            )
        } else if requestedNetworkPage {
            showOCRStatus(String(localized: "Text recognition complete."))
        }
    }

    // MARK: Lookup

    func presentOCRLookup(
        region: MangaOCRTextRegion,
        anchorRect: CGRect,
        userConfig: UserConfig
    ) -> Int? {
        let profile = ProfileRepository.shared.activeProfile
        guard let candidate = TextSelectionResolver.lookupCandidate(
            in: region.sentence,
            utf16Offset: region.utf16Offset,
            scanLength: userConfig.scanLength,
            contentLanguage: profile.language
        ) else {
            return nil
        }
        let selection = SelectionData(
            text: candidate.text,
            sentence: region.sentence,
            rect: anchorRect,
            normalizedOffset: candidate.utf16Start,
            miningContext: .text(
                region.sentence,
                targetUTF16Location: candidate.utf16Start
            )
        )
        let matchedLength = popupPresentation.present(
            selection: selection,
            userConfig: userConfig,
            replacingExisting: true,
            isVertical: region.isVertical
        )
        if matchedLength != nil {
            lookupPageIndex = region.pageIndex
        }
        if matchedLength == nil {
            showOCRStatus(String(localized: "No dictionary result found."))
        }
        return matchedLength
    }

    func presentNestedLookup(
        selection: SelectionData,
        userConfig: UserConfig
    ) -> Int? {
        popupPresentation.present(
            selection: selection,
            userConfig: userConfig
        )
    }

    func dismissPopup(id: UUID) {
        popupPresentation.dismiss(id: id)
    }

    func closeOCRLookup() {
        popupPresentation.closeAll()
    }

    func showOCRStatus(_ message: String) {
        ocrStatusMessage = message
        statusTask?.cancel()
        statusTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            ocrStatusMessage = nil
        }
    }

    func imageData(at pageIndex: Int) async -> Data? {
        await pagePayload(at: pageIndex)?.imageData
    }

    private func pagePayload(
        at pageIndex: Int
    ) async -> MangaPagePayload? {
        guard pageReferences.indices.contains(pageIndex) else { return nil }
        do {
            return try await pageProvider.payload(
                for: pageReferences[pageIndex]
            )
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renderedImage(
        for page: MangaPresentationPage
    ) async -> NSImage? {
        guard pageReferences.indices.contains(page.sourcePageIndex) else {
            return nil
        }
        do {
            let payload = try await pageProvider.payload(
                for: pageReferences[page.sourcePageIndex]
            )
            guard let imageData = payload.imageData else {
                return Self.renderedTextPage(
                    payload.text ?? "",
                    title: pageReferences[page.sourcePageIndex].displayPath
                )
            }
            prefetchPages(around: page.sourcePageIndex)
            recordPageGeometry(sourcePageIndex: page.sourcePageIndex, data: imageData)
            let rendered = try await Task.detached(priority: .userInitiated) {
                try MangaPageProcessor.renderedImage(
                    from: imageData,
                    transform: page.transform
                )
            }.value
            return rendered.image
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func prefetchPages(around pageIndex: Int) {
        let indices = ((pageIndex - 2)...(pageIndex + 2))
            .filter {
                $0 != pageIndex && pageReferences.indices.contains($0)
            }
        let pages = indices.map { pageReferences[$0] }
        let provider = pageProvider
        Task(priority: .utility) {
            await provider.prefetch(pages: pages)
        }
    }

    func setCover(to pageIndex: Int) {
        guard pageReferences.indices.contains(pageIndex) else {
            showOCRStatus(String(localized: "The selected manga page could not be used as a cover."))
            return
        }
        Task {
            do {
                let payload = try await pageProvider.payload(
                    for: pageReferences[pageIndex]
                )
                guard let imageData = payload.imageData else {
                    throw MangaPageLoaderError.pageUnavailable
                }
                try await session.coverWriter(imageData)
                showOCRStatus(String(localized: "Manga cover updated."))
            } catch is CancellationError {
                return
            } catch {
                showOCRStatus(error.localizedDescription)
            }
        }
    }

    func miningContext(sentence: String) async -> MiningContext {
        guard let pageIndex = lookupPageIndex,
              pageReferences.indices.contains(pageIndex),
              let payload = await pagePayload(at: pageIndex),
              let imageData = payload.imageData,
              let imageExtension = payload.fileExtension else {
            return MiningContext(
                sentence: sentence,
                documentTitle: session.title,
                coverURL: nil
            )
        }
        return MiningContext(
            sentence: sentence,
            documentTitle: session.title,
            coverURL: nil,
            manga: MangaMiningContext(
                pageIndex: pageIndex,
                imageData: imageData,
                imageExtension: imageExtension
            )
        )
    }

    private var currentSourcePageIndex: Int {
        guard presentationPages.indices.contains(currentPageIndex) else {
            return min(
                max(0, currentPageIndex),
                max(0, sourcePageCount - 1)
            )
        }
        return presentationPages[currentPageIndex].sourcePageIndex
    }

    private func rawLookupRegions(
        at sourcePageIndex: Int
    ) -> [MangaOCRTextRegion] {
        if let mokuroRegions = mokuroRegionsByPage[sourcePageIndex] {
            return mokuroRegions
        }
        return isOCREnabled
            ? ocrRegionsByPage[sourcePageIndex] ?? []
            : []
    }

    private func pageProcessingPreferenceDidChange() {
        popupPresentation.closeAll()
        if pageProcessingOptions.requiresAnalysis {
            if cachedPageAnalyses != nil {
                rebuildPresentationPagesIfPossible()
            } else {
                isPreparingPages = true
            }
        } else {
            isPreparingPages = false
            rebuildPresentationPages(using: nil)
        }
    }

    private func rebuildPresentationPagesIfPossible() {
        guard let cachedPageAnalyses else { return }
        rebuildPresentationPages(using: cachedPageAnalyses)
    }

    private func rebuildPresentationPages(
        using analyses: [MangaPageAnalysis]?
    ) {
        let sourcePaths = pageReferences.map(\.displayPath)
        let currentPage = presentationPages.indices.contains(currentPageIndex)
            ? presentationPages[currentPageIndex]
            : nil
        let nextPages: [MangaPresentationPage]
        if let analyses, pageProcessingOptions.requiresAnalysis {
            nextPages = MangaPagePresentationResolver.pages(
                sourcePaths: sourcePaths,
                analyses: analyses,
                options: pageProcessingOptions
            )
        } else {
            nextPages = MangaPagePresentationResolver.unprocessedPages(
                sourcePaths: sourcePaths
            )
        }

        presentationPages = nextPages
        panelsByPresentationPage = [:]
        guard !nextPages.isEmpty else {
            currentPageIndex = 0
            rebuildSpreads()
            return
        }
        if let currentPage,
           let exactIndex = nextPages.firstIndex(where: {
               $0.sourcePageIndex == currentPage.sourcePageIndex
                   && $0.transform == currentPage.transform
           }) {
            currentPageIndex = exactIndex
        } else {
            let sourcePageIndex = currentPage?.sourcePageIndex
                ?? min(max(0, currentPageIndex), sourcePageCount - 1)
            currentPageIndex = nextPages.firstIndex(where: {
                $0.sourcePageIndex == sourcePageIndex
            }) ?? 0
        }
        rebuildSpreads()
        alignCurrentPageToSpread()
    }

    private func ocrCacheKey(
        pageIndex: Int,
        pagePaths: [String]
    ) -> MangaOCRCacheKey? {
        guard pagePaths.indices.contains(pageIndex),
              let ocrEngine else {
            return nil
        }
        return MangaOCRCacheKey(
            itemID: ocrCacheItemID,
            pageIndex: pageIndex,
            pagePath: pagePaths[pageIndex],
            modifiedAt: session.modifiedAt,
            language: ocrLanguage,
            engineID: ocrEngine.engine.cacheEngineID,
            engineSignature: ocrEngine.signature
        )
    }

    private var ocrLanguage: MangaOCRLanguage {
        guard let profile = ProfileRepository.shared.profile(id: session.profileID)
        else {
            return .japanese
        }
        switch profile.language {
        case .japanese: return .japanese
        case .english: return .english
        }
    }

    private var ocrCacheItemID: String {
        guard let currentChapter,
              currentChapter.remoteIdentity != nil else {
            return session.documentID
        }
        return SuwayomiIdentity.sha256(
            [
                session.profileID,
                session.documentID,
                currentChapter.id,
            ].joined(separator: "\u{1f}")
        )
    }

    private var ocrPageIdentities: [String] {
        pageReferences.map(\.ocrCacheIdentity)
    }

    private func payloadForOCR(
        at pageIndex: Int,
        maximumAttempts: Int = 3
    ) async throws -> MangaPagePayload {
        guard pageReferences.indices.contains(pageIndex) else {
            throw MangaPageLoaderError.pageUnavailable
        }
        let page = pageReferences[pageIndex]
        var attempt = 0
        while true {
            do {
                return try await pageProvider.payload(for: page)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                guard attempt < maximumAttempts else { throw error }
                try await Task.sleep(
                    for: .milliseconds(350 * attempt)
                )
            }
        }
    }

    private nonisolated static func renderedTextPage(
        _ text: String,
        title: String
    ) -> NSImage {
        let size = NSSize(width: 1200, height: 1800)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.textBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 10
        paragraph.paragraphSpacing = 14
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (title as NSString).draw(
            in: NSRect(x: 82, y: 80, width: size.width - 164, height: 42),
            withAttributes: headingAttributes
        )
        (text as NSString).draw(
            with: NSRect(x: 82, y: 150, width: size.width - 164, height: size.height - 232),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        image.unlockFocus()
        return image
    }

    private func persistProgress() {
        guard let chapter = currentChapter else { return }
        let pageIndex = currentSourcePageIndex
        let pageCount = sourcePageCount
        let completed = pageCount > 0 && pageIndex >= pageCount - 1
        if completed || chapter.wasReadAtOpen {
            completedProgressChapterIDs.insert(chapter.id)
        }
        let pendingCompletion =
            completedProgressChapterIDs.contains(chapter.id)
            || pendingProgressByChapter[chapter.id]?.completed == true
        if pendingProgressByChapter[chapter.id] == nil {
            pendingProgressOrder.append(chapter.id)
        }
        pendingProgressByChapter[chapter.id] = PendingProgress(
            chapter: chapter,
            pageIndex: pageIndex,
            pageCount: pageCount,
            completed: pendingCompletion
        )
        guard progressWriteTask == nil else { return }
        progressWriteTask = Task {
            while let chapterID = pendingProgressOrder.first {
                pendingProgressOrder.removeFirst()
                guard let progress =
                    pendingProgressByChapter.removeValue(
                        forKey: chapterID
                    ) else {
                    continue
                }
                await session.progressWriter(
                    progress.chapter,
                    progress.pageIndex,
                    progress.pageCount,
                    progress.completed
                )
            }
            progressWriteTask = nil
        }
    }

    private func invalidateOCRForChapterChange() {
        ocrContentGeneration = UUID()
        activeOCRScanID = nil
        isRecognizingText = false
        ocrScanCancellationID += 1
        ocrCompletedPageCount = 0
        ocrTotalPageCount = 0
        ocrRegionsByPage = [:]
        mokuroRegionsByPage = [:]
        lookupPageIndex = nil
        statusTask?.cancel()
        statusTask = nil
        ocrStatusMessage = nil
        sizeProbeTask?.cancel()
        sizeProbeTask = nil
    }
}
