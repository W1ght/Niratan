import AppKit
import IOKit.pwr_mgt
import SwiftUI
import UniformTypeIdentifiers

struct MangaReaderView: View {
    @Environment(UserConfig.self) private var userConfig
    @Environment(ShortcutManager.self) private var shortcutManager
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage("mangaGoogleOCRDisclosureAccepted")
    private var hasAcceptedGoogleOCRDisclosure = false
    @State private var profileRepository = ProfileRepository.shared
    @State private var viewModel: MangaReaderViewModel
    @State private var continuousScrollPosition: Int?
    @State private var showsGoogleOCRDisclosure = false
    @State private var showsPageNavigator = false
    @State private var showsZoomControls = false
    @State private var showsTapZones = false
    @State private var flashOpacity = 0.0
    @State private var continuousScrollRequest: MangaContinuousScrollRequest?
    @State private var shortcutRegistrationIDs: [UUID] = []
    @State private var displaySleepGuard = MangaDisplaySleepGuard()
    @State private var window: NSWindow?
    @State private var popupCoordinateSpace = MangaReaderPopupCoordinateSpace()

    init(item: MangaLibraryItem, source: MangaLibrarySource) {
        _viewModel = State(initialValue: MangaReaderViewModel(item: item, source: source))
        _continuousScrollPosition = State(initialValue: item.currentPageIndex)
    }

    init(
        session: MangaReadingSession,
        pageProvider: any MangaPageContentProvider
    ) {
        _viewModel = State(
            initialValue: MangaReaderViewModel(
                session: session,
                pageProvider: pageProvider
            )
        )
        _continuousScrollPosition = State(
            initialValue: session.initialPageIndex
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                readerContent
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        viewModel.viewportSize = size
                    }

                if showsTapZones {
                    MangaTapZoneHint(settings: viewModel.settings)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                Color.white
                    .opacity(flashOpacity)
                    .allowsHitTesting(false)

                ForEach(viewModel.popupPresentation.popups) { popup in
                    popupView(popup, screenSize: geometry.size)
                }

                statusOverlay
            }
            .overlay(alignment: .topLeading) {
                if let hint = viewModel.transientHint {
                    Text(hint)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(14)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if !viewModel.isInterfaceHidden,
                   viewModel.pageCount > 1,
                   viewModel.isContentAvailable {
                    MangaReaderBottomBar(
                        viewModel: viewModel,
                        onJumpToPage: jumpToPage
                    )
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if viewModel.isInterfaceHidden, viewModel.settings.showsPageNumber,
                   viewModel.pageCount > 0 {
                    Text(viewModel.pageLabel)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.isInterfaceHidden {
                    Button {
                        withAnimation(.smooth) {
                            viewModel.isInterfaceHidden = false
                        }
                    } label: {
                        Label("Show Interface", systemImage: "menubar.rectangle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .opacity(0.35)
                    .padding(12)
                    .help("Show Interface")
                }
            }
            .background(
                MangaReaderCoordinateSpaceReader(
                    coordinateSpace: popupCoordinateSpace
                )
            )
            .background(MangaWindowReader { window = $0 })
        }
        .background(Color(nsColor: viewModel.pageBackgroundColor))
        .animation(.smooth(duration: 0.2), value: viewModel.isInterfaceHidden)
        .animation(.smooth(duration: 0.2), value: viewModel.transientHint)
        .navigationTitle(viewModel.title)
        .toolbar {
            MangaReaderToolbar(
                viewModel: viewModel,
                showsPageNavigator: $showsPageNavigator,
                showsZoomControls: $showsZoomControls,
                onJumpToPage: jumpToPage,
                onToggleOCR: toggleOCR,
                onToggleFullScreen: toggleFullScreen
            )
        }
        .inspector(isPresented: $viewModel.showsSettingsPanel) {
            MangaReaderSettingsPanel(viewModel: viewModel)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .alert(
            "Unable to Open Manga",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert(
            "Use Google Lens Text Recognition?",
            isPresented: $showsGoogleOCRDisclosure
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                hasAcceptedGoogleOCRDisclosure = true
                viewModel.toggleOCR()
            }
        } message: {
            Text("Recognizing an entire manga sends a reduced copy of every page without Mokuro text to Google. Results are cached on this Mac so reopening does not recognize the same pages again. Google Lens requires an internet connection.")
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.home) {
            viewModel.goToFirstPage()
            syncContinuousPosition()
            return .handled
        }
        .onKeyPress(.end) {
            viewModel.goToLastPage()
            syncContinuousPosition()
            return .handled
        }
        .onChange(of: viewModel.mode) { _, mode in
            if mode == .continuous {
                continuousScrollPosition = viewModel.currentPageIndex
            }
            viewModel.showReadingModeHintIfNeeded()
        }
        .onChange(of: viewModel.pageTurnToken) { _, _ in
            flashIfNeeded()
        }
        .onChange(of: viewModel.isInterfaceHidden) { _, hidden in
            setToolbarVisible(!hidden)
        }
        .onChange(of: viewModel.settings.keepsScreenOn) { _, _ in
            updateDisplaySleepGuard()
        }
        .onChange(of: controlActiveState) { _, _ in
            updateDisplaySleepGuard()
        }
        .onChange(
            of: profileRepository.index.globalActiveProfileId
        ) { _, _ in
            // Lookup state belongs to the Profile that created it. Close
            // it before the new Profile's Anki mapping becomes active.
            viewModel.closeOCRLookup()
        }
        .onAppear {
            registerKeyboardShortcuts()
            updateDisplaySleepGuard()
            viewModel.showReadingModeHintIfNeeded()
            if viewModel.settings.showsTapZonesOnOpen,
               viewModel.settings.tapZoneLayout != .disabled {
                showsTapZones = true
            }
        }
        .onDisappear {
            unregisterKeyboardShortcuts()
            displaySleepGuard.isActive = false
            setToolbarVisible(true)
            // Model sessions hold hundreds of megabytes; reload on demand.
            Task {
                await MangaLocalOCREngine.shared.unload()
                await MangaPanelDetector.shared.unload()
            }
        }
        .task(id: showsTapZones) {
            guard showsTapZones else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation { showsTapZones = false }
        }
        .task {
            await viewModel.refreshOCREngine()
        }
        .onChange(of: MangaOCRModelManager.shared.revision) { _, _ in
            Task { await viewModel.refreshOCREngine() }
        }
        .task(id: viewModel.visibleOCRRequestID) {
            await viewModel.loadVisibleOCRRegions()
        }
        .task(id: viewModel.pageProcessingRequestID) {
            await viewModel.preparePageProcessing()
            if viewModel.mode == .continuous {
                continuousScrollPosition = viewModel.currentPageIndex
            }
        }
        .task(id: viewModel.fullOCRRequestID) {
            await viewModel.recognizeAllPages()
        }
        .task(id: pagedAutoScrollID) {
            await runPagedAutoScroll()
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        VStack(spacing: 8) {
            if viewModel.isRecognizingText {
                HStack(spacing: 10) {
                    ProgressView(value: viewModel.ocrProgress)
                        .frame(width: 96)
                    Text(
                        "OCR \(viewModel.ocrCompletedPageCount) / \(viewModel.ocrTotalPageCount)"
                    )
                    .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let message = viewModel.ocrStatusMessage {
                Label(message, systemImage: "text.viewfinder")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if viewModel.settings.panelNavigation,
               let status = viewModel.panelStatus {
                MangaPanelStatusChip(status: status)
            }
        }
        .padding(.top, 12)
        .allowsHitTesting(false)
        .zIndex(1_000)
    }

    @ViewBuilder
    private var readerContent: some View {
        if !viewModel.isContentAvailable {
            ContentUnavailableView {
                Label("Unable to Open Manga", systemImage: "exclamationmark.triangle")
            } description: {
                Text(viewModel.errorMessage ?? String(localized: "The manga source is no longer available."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.isLoadingChapter || viewModel.isPreparingPages {
            ProgressView("Preparing Manga Pages…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch viewModel.mode {
            case .paged, .verticalPaged:
                MangaPagedReader(
                    viewModel: viewModel,
                    ocrRegions: viewModel.visibleOCRRegions,
                    showsOCRSelection: !viewModel.popupPresentation.popups.isEmpty,
                    style: canvasStyle,
                    actions: canvasActions
                )
            case .continuous:
                MangaContinuousReader(
                    viewModel: viewModel,
                    scrollPosition: $continuousScrollPosition,
                    scrollRequest: $continuousScrollRequest,
                    popupCoordinateSpace: popupCoordinateSpace,
                    showsOCRSelection: !viewModel.popupPresentation.popups.isEmpty,
                    style: canvasStyle,
                    actions: canvasActions
                )
            }
        }
    }

    private var canvasStyle: MangaCanvasStyle {
        MangaCanvasStyle(
            settings: viewModel.settings,
            backgroundColor: viewModel.pageBackgroundColor,
            isPopupOpen: !viewModel.popupPresentation.popups.isEmpty
        )
    }

    private var canvasActions: MangaCanvasActions {
        var actions = MangaCanvasActions()
        actions.onSetCover = viewModel.allowsCoverUpdates
            ? { pageIndex in viewModel.setCover(to: pageIndex) }
            : nil
        actions.onZoomScaleChange = { scale in
            viewModel.zoomPercentage = Int((scale * 100).rounded())
        }
        actions.onWheelTurn = { turn in
            viewModel.turnFromWheel(turn)
            syncContinuousPosition()
        }
        actions.onTapZone = { action in
            withAnimation(.smooth(duration: 0.2)) {
                viewModel.handleTapZone(action)
            }
            syncContinuousPosition()
        }
        actions.onSwipeTurn = { turn in
            turn == .forward ? viewModel.goForward() : viewModel.goBackward()
        }
        actions.onDismissOCRSelection = viewModel.closeOCRLookup
        actions.onOCRSelection = { region, rect in
            viewModel.presentOCRLookup(
                region: region,
                anchorRect: rect,
                userConfig: userConfig
            )
        }
        actions.onPreviousPage = {
            viewModel.goBackward()
            syncContinuousPosition()
        }
        actions.onNextPage = {
            viewModel.goForward()
            syncContinuousPosition()
        }
        actions.onJumpToPage = {
            viewModel.isInterfaceHidden = false
            showsPageNavigator = true
        }
        actions.onToggleDirection = viewModel.toggleDirection
        actions.onZoomStep = { step in
            viewModel.zoom(by: step)
        }
        return actions
    }

    private func jumpToPage(_ pageIndex: Int) {
        viewModel.go(to: pageIndex)
        syncContinuousPosition()
    }

    private func toggleOCR() {
        if viewModel.isRecognizingText {
            viewModel.cancelOCRRecognition()
            return
        }
        if viewModel.isOCRRecognitionPaused {
            viewModel.resumeOCRRecognition()
            return
        }
        guard !viewModel.isOCREnabled,
              viewModel.settings.ocrEngine == .googleLens,
              !hasAcceptedGoogleOCRDisclosure else {
            viewModel.toggleOCR()
            return
        }
        showsGoogleOCRDisclosure = true
    }

    /// Hides or shows the window toolbar without resizing the window, so the
    /// page area grows into the toolbar's space instead of the window shrinking.
    private func setToolbarVisible(_ visible: Bool) {
        guard let window, let toolbar = window.toolbar,
              toolbar.isVisible != visible else {
            return
        }
        let frame = window.frame
        toolbar.isVisible = visible
        if !window.styleMask.contains(.fullScreen) {
            window.setFrame(frame, display: true)
        }
    }

    /// The display stays awake only while the manga window is active.
    private func updateDisplaySleepGuard() {
        displaySleepGuard.isActive = viewModel.settings.keepsScreenOn
            && controlActiveState == .key
    }

    private func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    private func syncContinuousPosition() {
        guard viewModel.mode == .continuous else { return }
        withAnimation(.smooth) {
            continuousScrollPosition = viewModel.currentPageIndex
        }
    }

    private func flashIfNeeded() {
        guard viewModel.settings.flashesOnPageChange else { return }
        flashOpacity = 0.9
        withAnimation(.linear(duration: 0.08).delay(0.02)) {
            flashOpacity = 0
        }
    }

    // MARK: Auto-scroll

    private var isAutoScrollActive: Bool {
        viewModel.settings.autoScroll
            && !viewModel.showsSettingsPanel
            && viewModel.popupPresentation.popups.isEmpty
            && !viewModel.isLoadingChapter
    }

    private var pagedAutoScrollID: String {
        "\(isAutoScrollActive)|\(viewModel.mode.rawValue)|\(viewModel.settings.autoScrollSpeed)|\(viewModel.currentPageIndex)"
    }

    /// Fushi turns one page every viewport-height / speed seconds in paged
    /// modes; the long strip scrolls continuously instead.
    private func runPagedAutoScroll() async {
        guard isAutoScrollActive, viewModel.mode != .continuous else { return }
        let height = max(200, viewModel.viewportSize.height)
        let interval = Double(height) / Double(max(5, viewModel.settings.autoScrollSpeed))
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled, isAutoScrollActive, viewModel.canGoForward else { return }
        viewModel.goForward()
    }

    // MARK: Keyboard

    private func registerKeyboardShortcuts() {
        guard shortcutRegistrationIDs.isEmpty else { return }
        shortcutRegistrationIDs = [
            shortcutManager.register(
                scope: .popup,
                handlers: [
                    PopupShortcutActions.dismiss.id: {
                        guard let popup = viewModel.popupPresentation.popups.last else {
                            return false
                        }
                        viewModel.dismissPopup(id: popup.id)
                        return true
                    },
                ]
            ),
            shortcutManager.register(
                scope: .manga,
                handlers: mangaShortcutHandlers
            ),
        ]
    }

    private func unregisterKeyboardShortcuts() {
        shortcutRegistrationIDs.forEach(shortcutManager.unregister)
        shortcutRegistrationIDs.removeAll()
    }

    private var mangaShortcutHandlers: [String: ShortcutHandler] {
        [
            MangaShortcutActions.pageLeft.id: {
                pageHorizontally(left: true)
            },
            MangaShortcutActions.pageRight.id: {
                pageHorizontally(left: false)
            },
            MangaShortcutActions.nextPage.id: {
                pageVertically(.forward)
            },
            MangaShortcutActions.previousPage.id: {
                pageVertically(.backward)
            },
            MangaShortcutActions.pageDown.id: {
                pageVertically(.forward)
            },
            MangaShortcutActions.pageUp.id: {
                pageVertically(.backward)
            },
            MangaShortcutActions.advance.id: {
                pageVertically(.forward)
            },
            MangaShortcutActions.toggleInterface.id: {
                withAnimation(.smooth(duration: 0.2)) {
                    viewModel.toggleInterface()
                }
                return true
            },
            MangaShortcutActions.toggleFullScreen.id: {
                toggleFullScreen()
                return true
            },
            MangaShortcutActions.toggleSettings.id: {
                viewModel.showsSettingsPanel.toggle()
                return true
            },
            MangaShortcutActions.panLeft.id: { pan(dx: -0.15, dy: 0) },
            MangaShortcutActions.panRight.id: { pan(dx: 0.15, dy: 0) },
            MangaShortcutActions.panUp.id: { pan(dx: 0, dy: -0.15) },
            MangaShortcutActions.panDown.id: { pan(dx: 0, dy: 0.15) },
            MangaShortcutActions.back.id: {
                handleBack()
            },
        ]
    }

    private func pageHorizontally(left: Bool) -> Bool {
        guard viewModel.isContentAvailable else { return false }
        if left {
            viewModel.handleLeftArrow()
        } else {
            viewModel.handleRightArrow()
        }
        syncContinuousPosition()
        return true
    }

    /// In the long strip the vertical keys scroll by most of a screen, like
    /// Fushi leaving them to the page's own scrolling.
    private func pageVertically(_ turn: MangaPageTurn) -> Bool {
        guard viewModel.isContentAvailable else { return false }
        if viewModel.mode == .continuous {
            continuousScrollRequest = MangaContinuousScrollRequest(turn: turn)
        } else if turn == .forward {
            viewModel.goForward()
        } else {
            viewModel.goBackward()
        }
        return true
    }

    private func pan(dx: Double, dy: Double) -> Bool {
        guard viewModel.mode != .continuous else { return false }
        viewModel.pan(dx: dx, dy: dy)
        return true
    }

    /// Fushi's back steps: close the dictionary, the settings, the hidden
    /// interface, full screen, and finally the reader.
    private func handleBack() -> Bool {
        if viewModel.handleEscape() {
            return true
        }
        if let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return true
        }
        window?.performClose(nil)
        return true
    }

    private func popupView(_ popup: PopupItem, screenSize: CGSize) -> some View {
        let popupID = popup.id
        return PopupView(
            userConfig: userConfig,
            isVisible: Binding(
                get: {
                    viewModel.popupPresentation.popups
                        .first(where: { $0.id == popupID })?
                        .showPopup ?? false
                },
                set: {
                    viewModel.popupPresentation.setVisibility(id: popupID, visible: $0)
                }
            ),
            selectionData: popup.currentSelection,
            lookupResults: popup.lookupResults,
            dictionaryStyles: popup.dictionaryStyles,
            screenSize: screenSize,
            isVertical: popup.isVertical,
            isFullWidth: false,
            centersOnSelection: true,
            coverURL: nil,
            documentTitle: viewModel.title,
            profileID: profileRepository.activeProfile.id,
            clearSelection: popup.clearSelection,
            onTextSelected: { selection in
                viewModel.popupPresentation.closeChildren(of: popupID)
                return viewModel.presentNestedLookup(
                    selection: selection,
                    userConfig: userConfig
                )
            },
            onTapOutside: {
                viewModel.popupPresentation.handleTapInsidePopup(id: popupID)
            },
            onSwipeDismiss: {
                viewModel.dismissPopup(id: popupID)
            },
            miningContextProvider: { sentence, _ in
                await viewModel.miningContext(sentence: sentence)
            }
        )
        .id(popupID)
    }
}

// MARK: - Toolbar

private struct MangaReaderToolbar: ToolbarContent {
    @Bindable var viewModel: MangaReaderViewModel
    @Binding var showsPageNavigator: Bool
    @Binding var showsZoomControls: Bool
    let onJumpToPage: (Int) -> Void
    let onToggleOCR: () -> Void
    let onToggleFullScreen: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button {
                    viewModel.handleLeftArrow()
                } label: {
                    Label(
                        viewModel.direction == .rightToLeft ? "Next Page" : "Previous Page",
                        systemImage: "chevron.left"
                    )
                }
                .disabled(
                    viewModel.direction == .rightToLeft
                        ? !viewModel.canGoForward
                        : !viewModel.canGoBackward
                )

                Button {
                    viewModel.handleRightArrow()
                } label: {
                    Label(
                        viewModel.direction == .rightToLeft ? "Previous Page" : "Next Page",
                        systemImage: "chevron.right"
                    )
                }
                .disabled(
                    viewModel.direction == .rightToLeft
                        ? !viewModel.canGoBackward
                        : !viewModel.canGoForward
                )
            }
            .controlGroupStyle(.navigation)
            .labelStyle(.iconOnly)
            .controlSize(.large)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            if viewModel.chapters.count > 1 {
                Menu {
                    Button {
                        Task { await viewModel.goToPreviousChapter() }
                    } label: {
                        Label("Previous Chapter", systemImage: "chevron.left")
                    }
                    .disabled(!viewModel.hasPreviousChapter)

                    Button {
                        Task { await viewModel.goToNextChapter() }
                    } label: {
                        Label("Next Chapter", systemImage: "chevron.right")
                    }
                    .disabled(!viewModel.hasNextChapter)

                    Divider()

                    ForEach(Array(viewModel.chapters.enumerated()), id: \.element.id) {
                        index,
                        chapter in
                        Button {
                            Task { await viewModel.openChapter(at: index) }
                        } label: {
                            Label(
                                chapter.title,
                                systemImage: index
                                    == viewModel.currentChapterIndex
                                    ? "checkmark"
                                    : "book.pages"
                            )
                        }
                    }
                } label: {
                    Label("Chapters", systemImage: "list.bullet.rectangle")
                }
            }

            if !viewModel.allVisiblePagesUseMokuro {
                Button {
                    onToggleOCR()
                } label: {
                    if viewModel.isRecognizingText {
                        Label(
                            "Cancel Text Recognition",
                            systemImage: "xmark.circle"
                        )
                    } else if viewModel.isOCRRecognitionPaused {
                        Label(
                            "Resume Text Recognition",
                            systemImage: "play.circle"
                        )
                    } else {
                        Label(
                            viewModel.isOCREnabled
                                ? "Hide Recognized Text"
                                : "Recognize Entire Manga",
                            systemImage: viewModel.isOCREnabled
                                ? "text.viewfinder"
                                : "viewfinder"
                        )
                    }
                }
                .help(
                    viewModel.isRecognizingText
                        ? "Cancel Text Recognition"
                        : viewModel.isOCRRecognitionPaused
                            ? "Resume Text Recognition"
                            : "Recognize Entire Manga"
                )

                if viewModel.isOCRRecognitionPaused {
                    Button {
                        viewModel.toggleOCR()
                    } label: {
                        Label("Hide Recognized Text", systemImage: "eye.slash")
                    }
                    .help("Hide Recognized Text")
                }
            }

            Menu {
                Picker("Reading Mode", selection: modeBinding) {
                    ForEach(MangaReaderMode.allCases) { mode in
                        Label(LocalizedStringKey(mode.titleKey), systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.inline)

                if viewModel.mode == .paged {
                    Picker("Page Layout", selection: spreadBinding) {
                        ForEach(MangaSpreadMode.allCases) { spread in
                            Label(LocalizedStringKey(spread.titleKey), systemImage: spread.systemImage)
                                .tag(spread)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Picker("Reading Direction", selection: directionBinding) {
                    ForEach(MangaReadingDirection.allCases) { direction in
                        Label(LocalizedStringKey(direction.titleKey), systemImage: direction.systemImage)
                            .tag(direction)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Reading Mode", systemImage: viewModel.mode.systemImage)
            }
            .help("Reading Mode")

            Button {
                showsZoomControls.toggle()
            } label: {
                Label {
                    Text(verbatim: "\(viewModel.zoomPercentage)%")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
            }
            .help("Page Zoom")
            .popover(isPresented: $showsZoomControls, arrowEdge: .top) {
                MangaZoomControls(viewModel: viewModel)
            }

            Button {
                showsPageNavigator.toggle()
            } label: {
                Text(viewModel.pageLabel)
                    .monospacedDigit()
            }
            .help("Jump to Page")
            .popover(isPresented: $showsPageNavigator, arrowEdge: .top) {
                MangaPageNavigator(
                    viewModel: viewModel,
                    onJumpToPage: onJumpToPage
                )
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    viewModel.isInterfaceHidden = true
                }
            } label: {
                Label("Hide Interface", systemImage: "rectangle.dashed")
            }
            .help("Hide Interface")

            Button {
                viewModel.showsSettingsPanel.toggle()
            } label: {
                Label("Reader Settings", systemImage: "slider.horizontal.3")
            }
            .help("Reader Settings")
        }
    }

    private var modeBinding: Binding<MangaReaderMode> {
        Binding(
            get: { viewModel.mode },
            set: { mode in
                var next = viewModel.settings
                next.mode = mode
                next.autoDetectsMode = false
                viewModel.apply(next, scope: .thisManga)
            }
        )
    }

    private var spreadBinding: Binding<MangaSpreadMode> {
        Binding(
            get: { viewModel.settings.spreadMode },
            set: { spread in
                var next = viewModel.settings
                next.spreadMode = spread
                viewModel.apply(next, scope: .thisManga)
            }
        )
    }

    private var directionBinding: Binding<MangaReadingDirection> {
        Binding(
            get: { viewModel.direction },
            set: { direction in
                var next = viewModel.settings
                next.direction = direction
                viewModel.apply(next, scope: .thisManga)
            }
        )
    }
}

// MARK: - Bottom bar

/// Fushi's bottom page slider. It runs right-to-left for right-to-left books
/// and only changes the page when released.
private struct MangaReaderBottomBar: View {
    @Bindable var viewModel: MangaReaderViewModel
    let onJumpToPage: (Int) -> Void

    @State private var sliderPage = 1.0
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(Int(sliderPage.rounded()))")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 32)

            Slider(
                value: $sliderPage,
                in: 1...Double(max(2, viewModel.pageCount)),
                step: 1
            ) { editing in
                isEditing = editing
                if !editing {
                    onJumpToPage(Int(sliderPage.rounded()) - 1)
                }
            }
            .environment(
                \.layoutDirection,
                viewModel.direction == .rightToLeft ? .rightToLeft : .leftToRight
            )
            .accessibilityLabel(Text("Jump to Page"))
            .accessibilityValue(Text(viewModel.pageLabel))

            Text(verbatim: "\(viewModel.pageCount)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 32)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 24)
        .onAppear(perform: sync)
        .onChange(of: viewModel.currentPageIndex) { _, _ in
            guard !isEditing else { return }
            sync()
        }
    }

    private func sync() {
        sliderPage = Double(min(max(1, viewModel.currentPageIndex + 1), max(1, viewModel.pageCount)))
    }
}

private struct MangaPanelStatusChip: View {
    let status: MangaPanelNavigationStatus

    var body: some View {
        Label(title, systemImage: "square.grid.2x2")
            .font(.callout)
            .foregroundStyle(isWarning ? Color.orange : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
    }

    private var title: String {
        switch status {
        case let .panel(index, total):
            String(
                format: String(localized: "Panel %lld / %lld"),
                Int64(index),
                Int64(total)
            )
        case .noPanels:
            String(localized: "No panels detected")
        case .unavailable:
            String(localized: "Panel model unavailable")
        case .failed:
            String(localized: "Panel detection failed")
        }
    }

    private var isWarning: Bool {
        switch status {
        case .unavailable, .failed: true
        default: false
        }
    }
}

/// Shows the click zones for a few seconds after opening, like Fushi's
/// tap-zone overlay.
private struct MangaTapZoneHint: View {
    let settings: MangaReaderSettings

    var body: some View {
        Canvas { context, size in
            let columns = 24
            let rows = 24
            let cell = CGSize(
                width: size.width / CGFloat(columns),
                height: size.height / CGFloat(rows)
            )
            for row in 0..<rows {
                for column in 0..<columns {
                    let point = CGPoint(
                        x: (CGFloat(column) + 0.5) / CGFloat(columns),
                        y: (CGFloat(row) + 0.5) / CGFloat(rows)
                    )
                    guard let action = settings.tapZoneAction(at: point) else { continue }
                    let rect = CGRect(
                        x: CGFloat(column) * cell.width,
                        y: CGFloat(row) * cell.height,
                        width: cell.width + 0.5,
                        height: cell.height + 0.5
                    )
                    context.fill(Path(rect), with: .color(color(for: action)))
                }
            }
        }
    }

    private func color(for action: MangaTapZoneAction) -> Color {
        switch action {
        case .previous: Color.blue.opacity(0.28)
        case .next: Color.green.opacity(0.28)
        case .menu: Color.gray.opacity(0.18)
        }
    }
}

// MARK: - Zoom and page navigator popovers

private struct MangaZoomControls: View {
    @Bindable var viewModel: MangaReaderViewModel

    @State private var sliderPercentage = 100.0
    @State private var percentageText = "100"
    @FocusState private var isPercentageFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Page Zoom", systemImage: "magnifyingglass")
                    .font(.headline)

                Spacer()

                HStack(spacing: 4) {
                    TextField("", text: $percentageText)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($isPercentageFieldFocused)
                        .frame(width: 58)
                        .mangaGlassNumericField()
                        .accessibilityLabel(Text("Zoom Percentage"))
                        .onSubmit(commitPercentageText)
                        .onChange(of: percentageText) { _, newValue in
                            let digits = newValue.filter(\.isNumber)
                            if digits != newValue {
                                percentageText = digits
                            }
                        }
                    Text(verbatim: "%")
                }
            }

            HStack(spacing: 10) {
                Text(verbatim: "\(minimumPercentage)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Slider(
                    value: $sliderPercentage,
                    in: Double(minimumPercentage)...Double(MangaReaderSettings.maximumZoomPercentage),
                    step: 1
                ) { editing in
                    if editing {
                        isPercentageFieldFocused = false
                    } else {
                        apply(Int(sliderPercentage.rounded()))
                    }
                }
                .accessibilityLabel(Text("Page Zoom"))
                .onChange(of: sliderPercentage) { _, newValue in
                    percentageText = String(Int(newValue.rounded()))
                }

                Text(verbatim: "\(MangaReaderSettings.maximumZoomPercentage)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear(perform: syncFromViewModel)
        .onChange(of: viewModel.zoomPercentage) { _, _ in
            guard !isPercentageFieldFocused else { return }
            syncFromViewModel()
        }
        .onChange(of: isPercentageFieldFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commitPercentageText()
            }
        }
    }

    private var minimumPercentage: Int {
        viewModel.settings.minimumEffectiveZoomPercentage
    }

    private func commitPercentageText() {
        guard let percentage = Int(percentageText) else {
            syncFromViewModel()
            return
        }
        apply(percentage)
    }

    private func apply(_ percentage: Int) {
        viewModel.zoomPercentage = percentage
        sliderPercentage = Double(viewModel.zoomPercentage)
        percentageText = String(viewModel.zoomPercentage)
    }

    private func syncFromViewModel() {
        sliderPercentage = Double(viewModel.zoomPercentage)
        percentageText = String(viewModel.zoomPercentage)
    }
}

private struct MangaPageNavigator: View {
    @Bindable var viewModel: MangaReaderViewModel
    let onJumpToPage: (Int) -> Void

    @State private var pageText = ""
    @State private var sliderPage = 1.0
    @FocusState private var isPageFieldFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                pageButton(
                    title: "First Page",
                    systemImage: "backward.end.fill",
                    disabled: viewModel.currentPageIndex == 0
                ) {
                    jump(to: 0)
                }

                pageButton(
                    title: "Previous Page",
                    systemImage: "backward.fill",
                    disabled: !viewModel.canGoBackward
                ) {
                    viewModel.goBackward()
                }

                TextField("", text: $pageText)
                    .font(.title3.monospacedDigit())
                    .focused($isPageFieldFocused)
                    .mangaGlassNumericField()
                    .accessibilityLabel(Text("Page Number"))
                    .onSubmit(commitPageText)
                    .onChange(of: pageText) { _, newValue in
                        let digits = newValue.filter(\.isNumber)
                        if digits != newValue {
                            pageText = digits
                        }
                    }

                pageButton(
                    title: "Next Page",
                    systemImage: "forward.fill",
                    disabled: !viewModel.canGoForward
                ) {
                    viewModel.goForward()
                }

                pageButton(
                    title: "Last Page",
                    systemImage: "forward.end.fill",
                    disabled: viewModel.currentPageIndex >= viewModel.pageCount - 1
                ) {
                    jump(to: viewModel.pageCount - 1)
                }
            }

            Slider(
                value: $sliderPage,
                in: 1...Double(max(1, viewModel.pageCount)),
                step: 1
            ) { editing in
                if !editing {
                    jump(to: Int(sliderPage.rounded()) - 1)
                }
            }
            .disabled(viewModel.pageCount <= 1)
            .accessibilityLabel(Text("Jump to Page"))
            .accessibilityValue(Text(viewModel.pageLabel))
        }
        .padding(18)
        .frame(width: 440)
        .onAppear(perform: syncControls)
        .onChange(of: viewModel.currentPageIndex) { _, _ in
            syncControls()
        }
    }

    @ViewBuilder
    private func pageButton(
        title: LocalizedStringKey,
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(disabled)
        .help(title)
    }

    private func commitPageText() {
        guard let requestedPage = Int(pageText) else {
            syncControls()
            return
        }
        jump(to: requestedPage - 1)
        isPageFieldFocused = false
    }

    private func jump(to pageIndex: Int) {
        guard viewModel.pageCount > 0 else { return }
        onJumpToPage(min(max(0, pageIndex), viewModel.pageCount - 1))
        syncControls()
    }

    private func syncControls() {
        let page = min(max(1, viewModel.currentPageIndex + 1), max(1, viewModel.pageCount))
        pageText = String(page)
        sliderPage = Double(page)
    }
}

extension View {
    func mangaGlassNumericField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(
                .regular.interactive(),
                in: .rect(cornerRadius: 10)
            )
    }
}

// MARK: - Paged reader

private struct MangaPagedReader: View {
    let viewModel: MangaReaderViewModel
    let ocrRegions: [Int: [MangaOCRTextRegion]]
    let showsOCRSelection: Bool
    let style: MangaCanvasStyle
    let actions: MangaCanvasActions

    var body: some View {
        GeometryReader { proxy in
            MangaAsyncSpread(
                viewModel: viewModel,
                pages: viewModel.displayedPages
            ) { images in
                MangaZoomableCanvas(
                    images: images,
                    pageIndices: viewModel.displayedPageIndices,
                    sourcePageIndices: viewModel.displayedPages.map(
                        \.sourcePageIndex
                    ),
                    ocrRegions: ocrRegions,
                    showsOCRSelection: showsOCRSelection,
                    style: style,
                    actions: actions,
                    turn: viewModel.pageTurn,
                    turnToken: viewModel.pageTurnToken,
                    entryEdge: viewModel.pageEntryEdge,
                    verticalPaging: viewModel.mode == .verticalPaged,
                    command: viewModel.canvasCommand
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color(nsColor: style.backgroundColor))
        }
    }
}

/// Keeps the previous spread on screen until the next one is decoded, so
/// page turns animate between two complete spreads.
private struct MangaAsyncSpread<Content: View>: View {
    let viewModel: MangaReaderViewModel
    let pages: [MangaPresentationPage]
    @ViewBuilder let content: ([NSImage]) -> Content

    @State private var images: [NSImage] = []
    @State private var loadedPages: [MangaPresentationPage] = []

    var body: some View {
        Group {
            if !images.isEmpty {
                content(images)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: pages) {
            guard loadedPages != pages else { return }
            var loadedImages: [NSImage] = []
            for page in pages {
                guard let image = await viewModel.renderedImage(for: page),
                      !Task.isCancelled else {
                    return
                }
                loadedImages.append(image)
            }
            images = loadedImages
            loadedPages = pages
        }
    }
}

private struct MangaZoomableCanvas: NSViewRepresentable {
    let images: [NSImage]
    let pageIndices: [Int]
    let sourcePageIndices: [Int]
    let ocrRegions: [Int: [MangaOCRTextRegion]]
    let showsOCRSelection: Bool
    let style: MangaCanvasStyle
    let actions: MangaCanvasActions
    let turn: MangaPageTurn?
    let turnToken: Int
    let entryEdge: MangaPageEntryEdge
    let verticalPaging: Bool
    let command: MangaCanvasCommand?

    func makeNSView(context: Context) -> MangaZoomScrollView {
        MangaZoomScrollView()
    }

    func updateNSView(_ scrollView: MangaZoomScrollView, context: Context) {
        scrollView.setContent(
            images: images,
            pageIndices: pageIndices,
            sourcePageIndices: sourcePageIndices,
            ocrRegions: ocrRegions,
            showsOCRSelection: showsOCRSelection,
            style: style,
            actions: actions,
            turn: turn,
            turnToken: turnToken,
            entryEdge: entryEdge,
            verticalPaging: verticalPaging,
            command: command
        )
    }
}

// MARK: - Continuous reader

struct MangaContinuousScrollRequest: Equatable {
    let id = UUID()
    let turn: MangaPageTurn
}

private struct MangaContinuousReader: View {
    let viewModel: MangaReaderViewModel
    @Binding var scrollPosition: Int?
    @Binding var scrollRequest: MangaContinuousScrollRequest?
    let popupCoordinateSpace: MangaReaderPopupCoordinateSpace
    let showsOCRSelection: Bool
    let style: MangaCanvasStyle
    let actions: MangaCanvasActions

    @State private var visiblePageIndex: Int?
    @State private var requestedScrollTarget: Int?
    @State private var scrollTargetAttempts = 0
    @State private var hasRestoredPosition = false
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var contentOffsetY: CGFloat = 0
    @State private var hideAnchorY: CGFloat = 0
    @State private var interactionHost = MangaContinuousInteractionHost()

    private static let hideThreshold: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            let settings = viewModel.settings
            let padding = geometry.size.width * CGFloat(settings.sidePaddingPercent) / 100
            let basePageWidth = max(320, geometry.size.width - padding * 2)
            let pageWidth = basePageWidth * viewModel.zoomScale
            let gap: CGFloat = settings.showsPageGaps ? 12 : 0

            ScrollViewReader { scrollProxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: gap) {
                        ForEach(viewModel.presentationPages) { page in
                            MangaAsyncPage(
                                viewModel: viewModel,
                                page: page,
                                placeholderHeight: pageWidth * viewModel.pageAspectRatio(for: page)
                            ) { image in
                                MangaContinuousPageCanvas(
                                    image: image,
                                    pageIndex: page.index,
                                    sourcePageIndex: page.sourcePageIndex,
                                    ocrRegions: viewModel.lookupRegions(for: page),
                                    showsOCRSelection: showsOCRSelection,
                                    popupCoordinateSpace: popupCoordinateSpace,
                                    style: style,
                                    actions: actions,
                                    interactionHost: interactionHost
                                )
                                    .frame(width: pageWidth)
                                    .aspectRatio(
                                        image.size.width / max(image.size.height, 1),
                                        contentMode: .fit
                                    )
                            }
                            .id(page.index)
                            .frame(width: pageWidth)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: MangaContinuousPageFramePreferenceKey.self,
                                        value: [
                                            page.index: proxy.frame(
                                                in: .named(MangaContinuousPageFramePreferenceKey.coordinateSpace)
                                            ),
                                        ]
                                    )
                                }
                            }
                            .task(id: viewModel.lookupRequestID(for: page)) {
                                await viewModel.loadOCRRegions(
                                    for: [page.sourcePageIndex]
                                )
                            }
                        }
                    }
                    .frame(
                        width: max(geometry.size.width, pageWidth + padding * 2),
                        alignment: .top
                    )
                }
                .scrollPosition($position)
                .coordinateSpace(name: MangaContinuousPageFramePreferenceKey.coordinateSpace)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    contentOffsetY = offset
                    updateInterfaceVisibility(for: offset)
                }
                .onPreferenceChange(MangaContinuousPageFramePreferenceKey.self) { frames in
                    guard let pageIndex = topVisiblePageIndex(
                        in: frames,
                        viewportHeight: geometry.size.height
                    ) else {
                        return
                    }
                    // The first layout pass decides where the strip opens:
                    // the reader's current page, not the top of the chapter.
                    if !hasRestoredPosition {
                        hasRestoredPosition = true
                        let target = viewModel.currentPageIndex
                        if target > 0, target != pageIndex {
                            requestedScrollTarget = target
                            scrollTargetAttempts = 0
                            scrollProxy.scrollTo(target, anchor: .top)
                            return
                        }
                    }
                    if let requestedScrollTarget {
                        guard pageIndex == requestedScrollTarget else {
                            // Lazy pages grow as their images decode; keep
                            // aiming at the requested page for a while.
                            if scrollTargetAttempts < 30 {
                                scrollTargetAttempts += 1
                                scrollProxy.scrollTo(requestedScrollTarget, anchor: .top)
                            } else {
                                self.requestedScrollTarget = nil
                            }
                            return
                        }
                        self.requestedScrollTarget = nil
                    }
                    visiblePageIndex = pageIndex
                    if scrollPosition != pageIndex {
                        scrollPosition = pageIndex
                    }
                    viewModel.go(to: pageIndex)
                }
                .onChange(of: scrollPosition) { _, pageIndex in
                    guard let pageIndex, pageIndex != visiblePageIndex else { return }
                    requestedScrollTarget = pageIndex
                    scrollTargetAttempts = 0
                    scrollProxy.scrollTo(pageIndex, anchor: .top)
                }
                .onChange(of: scrollRequest) { _, request in
                    guard let request else { return }
                    scrollByScreen(request.turn, viewportHeight: geometry.size.height)
                }
                .onAppear {
                    configureInteractionHost(viewportHeight: geometry.size.height)
                    guard let pageIndex = scrollPosition else { return }
                    requestedScrollTarget = pageIndex
                    scrollTargetAttempts = 0
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo(pageIndex, anchor: .top)
                    }
                }
                .onChange(of: style) { _, _ in
                    configureInteractionHost(viewportHeight: geometry.size.height)
                }
                .onChange(of: geometry.size.height) { _, height in
                    configureInteractionHost(viewportHeight: height)
                }
                .task(id: autoScrollID) {
                    await runAutoScroll()
                }
            }
        }
        .background(Color(nsColor: style.backgroundColor))
    }

    private var autoScrollID: String {
        "\(viewModel.settings.autoScroll)|\(viewModel.settings.autoScrollSpeed)|\(viewModel.showsSettingsPanel)|\(showsOCRSelection)"
    }

    private func configureInteractionHost(viewportHeight: CGFloat) {
        interactionHost.style = style
        interactionHost.actions = actions
        interactionHost.onScrollPage = { turn in
            scrollByScreen(turn, viewportHeight: viewportHeight)
        }
        interactionHost.onDoubleClickZoom = {
            viewModel.zoomPercentage = viewModel.zoomPercentage > 100 ? 100 : 200
        }
    }

    /// Fushi's long-strip click zones and vertical keys move 90% of a screen.
    private func scrollByScreen(_ turn: MangaPageTurn, viewportHeight: CGFloat) {
        let distance = viewportHeight * 0.9
        let target = max(0, contentOffsetY + (turn == .forward ? distance : -distance))
        withAnimation(.smooth(duration: 0.25)) {
            position.scrollTo(y: target)
        }
    }

    private func updateInterfaceVisibility(for offset: CGFloat) {
        guard viewModel.settings.hidesInterfaceOnScroll else {
            hideAnchorY = offset
            return
        }
        let delta = offset - hideAnchorY
        if delta > Self.hideThreshold {
            if !viewModel.isInterfaceHidden {
                withAnimation(.smooth(duration: 0.2)) {
                    viewModel.isInterfaceHidden = true
                }
            }
            hideAnchorY = offset
        } else if delta < -Self.hideThreshold {
            if viewModel.isInterfaceHidden {
                withAnimation(.smooth(duration: 0.2)) {
                    viewModel.isInterfaceHidden = false
                }
            }
            hideAnchorY = offset
        }
    }

    private func runAutoScroll() async {
        guard viewModel.settings.autoScroll,
              !viewModel.showsSettingsPanel,
              !showsOCRSelection else {
            return
        }
        let speed = CGFloat(viewModel.settings.autoScrollSpeed)
        let frameInterval = 1.0 / 60
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(frameInterval))
            guard !Task.isCancelled else { return }
            position.scrollTo(y: contentOffsetY + speed * CGFloat(frameInterval))
        }
    }

    private func topVisiblePageIndex(
        in frames: [Int: CGRect],
        viewportHeight: CGFloat
    ) -> Int? {
        let visibleFrames = frames.filter {
            $0.value.maxY > 0 && $0.value.minY < viewportHeight
        }
        if let crossingTop = visibleFrames
            .filter({ $0.value.minY <= 1 && $0.value.maxY > 1 })
            .max(by: { $0.value.minY < $1.value.minY }) {
            return crossingTop.key
        }
        return visibleFrames.min(by: {
            abs($0.value.minY) < abs($1.value.minY)
        })?.key
    }
}

private struct MangaContinuousPageFramePreferenceKey: PreferenceKey {
    static let coordinateSpace = "manga-continuous-pages"
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(
        value: inout [Int: CGRect],
        nextValue: () -> [Int: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

@MainActor
final class MangaReaderPopupCoordinateSpace {
    weak var rootView: NSView?

    func topLeadingRect(_ rect: CGRect, from sourceView: NSView) -> CGRect {
        guard let rootView,
              sourceView.window === rootView.window else {
            return rect
        }
        let converted = rootView.convert(rect, from: sourceView)
        let y = rootView.isFlipped
            ? converted.minY
            : rootView.bounds.height - converted.maxY
        return CGRect(
            x: converted.minX,
            y: y,
            width: converted.width,
            height: converted.height
        )
    }
}

private struct MangaReaderCoordinateSpaceReader: NSViewRepresentable {
    let coordinateSpace: MangaReaderPopupCoordinateSpace

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        coordinateSpace.rootView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        coordinateSpace.rootView = view
    }
}

private struct MangaWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MangaWindowTrackingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class MangaWindowTrackingView: NSView {
    var onWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let window = window
        DispatchQueue.main.async { [weak self] in
            self?.onWindow?(window)
        }
    }
}

private struct MangaContinuousPageCanvas: NSViewRepresentable {
    let image: NSImage
    let pageIndex: Int
    let sourcePageIndex: Int
    let ocrRegions: [MangaOCRTextRegion]
    let showsOCRSelection: Bool
    let popupCoordinateSpace: MangaReaderPopupCoordinateSpace
    let style: MangaCanvasStyle
    let actions: MangaCanvasActions
    let interactionHost: MangaContinuousInteractionHost

    func makeNSView(context: Context) -> MangaSpreadDocumentView {
        let view = MangaSpreadDocumentView()
        view.setFitsSinglePageToBounds()
        return view
    }

    func updateNSView(_ view: MangaSpreadDocumentView, context: Context) {
        view.interactionHost = interactionHost
        view.actions = actions
        view.applyStyle(style)
        view.setImages(
            [image],
            pageIndices: [pageIndex],
            sourcePageIndices: [sourcePageIndex]
        )
        view.setOCRRegions(
            [pageIndex: ocrRegions],
            pageIndices: [pageIndex],
            showsSelection: showsOCRSelection,
            onDismissSelection: actions.onDismissOCRSelection,
            onSelection: { [weak view] region, documentRect in
                guard let view else { return nil }
                return actions.onOCRSelection(
                    region,
                    popupCoordinateSpace.topLeadingRect(
                        documentRect,
                        from: view
                    )
                )
            }
        )
        view.configureContinuousZoom(
            scale: style.zoomScale,
            onScaleChange: actions.onZoomScaleChange
        )
        view.onSetCover = actions.onSetCover
    }
}

private struct MangaAsyncPage<Content: View>: View {
    let viewModel: MangaReaderViewModel
    let page: MangaPresentationPage
    let placeholderHeight: CGFloat
    @ViewBuilder let content: (NSImage) -> Content

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                content(image)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .frame(height: placeholderHeight)
            }
        }
        .task(id: page) {
            image = nil
            guard let renderedImage = await viewModel.renderedImage(for: page),
                  !Task.isCancelled else {
                return
            }
            image = renderedImage
        }
    }
}

// MARK: - Display sleep

/// Keeps the display awake while a manga is open, like Fushi's "keep screen
/// on". The assertion is released when the reader closes.
@MainActor
final class MangaDisplaySleepGuard {
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? acquire() : release()
        }
    }

    private func acquire() {
        guard !hasAssertion else { return }
        let reason = "Reading manga" as CFString
        hasAssertion = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        ) == kIOReturnSuccess
    }

    private func release() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
    }

    deinit {
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
        }
    }
}
