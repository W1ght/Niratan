import AppKit
@preconcurrency import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

let videoScreenLog = Logger(subsystem: "moe.shishamo.hoshi", category: "VideoScreen")

nonisolated final class DroppedFileURLAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    func urls() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
@MainActor
private final class VideoPlayerModelStore: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    let model = VideoPlayerViewModel(engine: MpvPlayerEngine())
}

struct VideoPlayerScreen: View {
    let isActive: Bool
    let openRequest: VideoWindowOpenRequest?
    let onConsumeOpenRequest: (UUID) -> Void
    let windowChrome: VideoWindowChromeController

    @Environment(UserConfig.self) var userConfig
    @Environment(ShortcutManager.self) var shortcutManager
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var modelStore = VideoPlayerModelStore()
    @State var openGate = VideoWindowOpenGate()
    @State var subtitles = VideoSubtitleController()
    @State var lookup = VideoLookupCoordinator()
    @State var miningHistory = VideoMiningHistoryStore()
    @State private var ambientBackdrop = VideoAmbientBackdropModel()
    @State private var profileRepository = ProfileRepository.shared
    @State var isInspectorVisible = false
    @State var isMiningHistoryVisible = false
    @State var selectedStudySidebarTab: VideoStudySidebarTab = .history
    @State var isPlaybackChromeVisible = true
    @State private var isSpeedPanelVisible = false
    @State private var isSavingScreenshot = false
    @State var isPointerInsidePlayerSurface = true
    @State var lastPlaybackChromePointerLocation: CGPoint?
    @State var areSubtitlesVisible = true
    @State var subtitleRenderingMode: VideoSubtitleRenderingMode = .overlayOnly
    @State var lastSelectedSubtitleTrackID: Int?
    @State var playbackChromeDragOffset: CGSize = .zero
    @State var playbackChromeStoredOffset: CGSize = .zero
    @State private var selectedInspectorTab: VideoInspectorTab = .subtitles
    @State var shortcutRegistrationIDs: [UUID] = []
    @State var pendingFileImportKind: VideoFileImportKind?
    @State var activeFileImportKind: VideoFileImportKind?
    @State private var isOpeningRemoteLink = false
    @State var isResolvingRemoteVideo = false
    @State var remoteVideoOpenErrorMessage: String?
    @State var remoteVideoOpenTask: Task<Void, Never>?
    @State var remoteVideoOpenGeneration = 0
    @State var playbackChromeAutoHideTask: Task<Void, Never>?
    @State var miningHistoryNotice: VideoMiningHistoryNotice?
    @State var miningHistoryNoticeTask: Task<Void, Never>?
    @State var miningHistoryNavigationTask: Task<Void, Never>?
    @State var miningHistoryNavigationGeneration = 0
    @State var videoOSD: VideoOnScreenDisplayItem?
    @State var videoOSDTask: Task<Void, Never>?
    @State var pendingHistoryEmbeddedSubtitleTrackID: Int?
    @State var subtitleTrackExtractionTask: Task<Void, Never>?
    @State var activeSubtitleTrackExtractionKey: String?
    @State var isLoadingPrimarySubtitle = false
    @State var primarySubtitleLoadGeneration = 0
    @State var shouldSkipNextAutomaticSubtitleRestore = false
    @State var isAwaitingEmbeddedSubtitleDefault = false
    @State var remoteSubtitleLoader = RemoteSubtitleLoader()
    @State var remoteSubtitleGeneration = 0
    @State var selectedRemoteSubtitleID: String?
    @State var selectedJimakuSubtitleID: String?
    @State var selectedJimakuSubtitleName: String?
    @State var selectedAJATTSubtitleID: String?
    @State var selectedAJATTSubtitleName: String?
    @State private var timelinePreview: VideoTimelinePreview?
    @State var timelinePreviewRequestedTime: TimeInterval?
    @AppStorage("videoStudySidebarWidth") private var studySidebarWidth: Double = Double(VideoMiningHistorySidebar.defaultWidth)
    @State private var studySidebarDragStartWidth: CGFloat?
    @State var inspectorOverlayFrame: CGRect = .zero

    static let playbackChromeEdgeInset: CGFloat = 16
    static let inspectorOverlayTrailingInset: CGFloat = 16
    private static let inspectorOverlayVerticalInset: CGFloat = 16
    private static let minimumVideoSurfaceWidth: CGFloat = 360
    private static let videoPlayerCoordinateSpace = "video-player"
    static let audioDelayRange: ClosedRange<TimeInterval> = -30...30

    static let subtitleFileExtensions = ["srt", "vtt", "ass", "ssa"]

    private let subtitleTypes: [UTType] = Self.subtitleFileExtensions.compactMap {
        UTType(filenameExtension: $0)
    }

    var model: VideoPlayerViewModel {
        modelStore.model
    }

    private var subtitleOverlayCues: [SubtitleCue] {
        if subtitles.document?.assRenderPlan != nil {
            return userConfig.videoRespectASSStyle
                ? subtitles.currentCues
                : ASSRenderPlan.uniqueTextCues(subtitles.currentCues)
        }
        switch subtitleRenderingMode {
        case .overlayOnly:
            return subtitles.currentCues
        case .preparingASS, .nativeOnly:
            return []
        case .splitASS:
            guard let primaryCueIDs = subtitles.document?.assRenderPlan?.primaryCueIDs else {
                return []
            }
            return subtitles.currentCues.filter { primaryCueIDs.contains($0.id) }
        }
    }

    var body: some View {
        lifecycleContent
    }

    private var lifecycleContent: some View {
        lifecycleFocusedContent
    }

    private var lifecycleFileImportContent: some View {
        observedContent
            .fileImporter(
                isPresented: fileImporterPresentation,
                allowedContentTypes: (pendingFileImportKind ?? activeFileImportKind)?.allowedContentTypes(
                    mediaTypes: VideoMediaTypes.contentTypes,
                    subtitleTypes: subtitleTypes
                ) ?? VideoMediaTypes.contentTypes,
                allowsMultipleSelection: false
            ) { result in
                guard let kind = activeFileImportKind ?? pendingFileImportKind else { return }
                pendingFileImportKind = nil
                activeFileImportKind = nil
                handleFileImport(result, kind: kind)
            }
            .sheet(isPresented: $isOpeningRemoteLink) {
                RemoteVideoLinkSheet { resolvedSource in
                    openRemoteLink(resolvedSource)
                }
            }
    }

    private var lifecycleActiveContent: some View {
        lifecycleFileImportContent
            .onAppear {
                synchronizePlaybackPreferences()
                miningHistory.updateLimit(userConfig.videoMiningHistoryLimit)
                installEmbeddedSubtitleHandler()
                synchronizeSelectedSubtitleTrack()
                performCatalogSubtitleMaintenance()
                if isActive {
                    registerKeyboardShortcuts()
                }
                schedulePlaybackChromeAutoHide()
            }
            .onChange(of: isActive, initial: true) { _, isActive in
                if isActive {
                    registerKeyboardShortcuts()
                    revealPlaybackChrome(scheduleHide: true)
                    refreshAmbientBackdrop(reason: .load)
                } else {
                    unregisterKeyboardShortcuts()
                    windowChrome.restorePlaybackCursor()
                    ambientBackdrop.suspend(clear: false)
                }
            }
    }

    private var lifecyclePreferenceContent: some View {
        lifecycleActiveContent
            .onChange(of: profileRepository.index.globalActiveProfileId) { _, _ in
                lookup.closeAll(player: model)
            }
            .onChange(of: userConfig.videoAutoPlayNext) { _, _ in
                synchronizePlaybackPreferences()
            }
            .onChange(of: userConfig.videoRememberPlaybackPosition) { _, _ in
                synchronizePlaybackPreferences()
            }
            .onChange(of: userConfig.videoSubtitleGapFastForwardEnabled) { _, enabled in
                model.setSubtitleGapFastForwardEnabled(enabled)
                updateSubtitleGapPlayback()
            }
            .onChange(of: userConfig.videoSubtitleGapFastForwardSpeed) { _, speed in
                model.setSubtitleGapFastForwardSpeed(speed)
                updateSubtitleGapPlayback()
            }
            .onChange(of: userConfig.videoHardwareDecodingEnabled) { _, _ in
                synchronizePlaybackPreferences()
            }
            .onChange(of: userConfig.videoDeinterlacingEnabled) { _, _ in
                synchronizePlaybackPreferences()
            }
            .onChange(of: userConfig.videoHDREnhancementEnabled) { _, _ in
                synchronizePlaybackPreferences()
            }
            .onChange(of: userConfig.videoShaderPreset) { _, preset in
                _ = model.setVideoShaderPreset(preset)
            }
            .onChange(of: userConfig.videoBrightness) { _, _ in
                synchronizeVideoEqualizerPreferences()
            }
            .onChange(of: userConfig.videoContrast) { _, _ in
                synchronizeVideoEqualizerPreferences()
            }
            .onChange(of: userConfig.videoSaturation) { _, _ in
                synchronizeVideoEqualizerPreferences()
            }
            .onChange(of: userConfig.videoGamma) { _, _ in
                synchronizeVideoEqualizerPreferences()
            }
            .onChange(of: userConfig.videoHue) { _, _ in
                synchronizeVideoEqualizerPreferences()
            }
            .onChange(of: userConfig.videoMiningHistoryLimit) { _, limit in
                miningHistory.updateLimit(limit)
            }
    }

    private var lifecycleExternalInputContent: some View {
        lifecyclePreferenceContent
            .onChange(of: openRequest, initial: true) { _, request in
                handleExternalOpenRequest(request)
            }
    }

    private var lifecycleChromeContent: some View {
        lifecycleExternalInputContent
            .onChange(of: isInspectorVisible) { _, inspectorVisible in
                if inspectorVisible {
                    revealPlaybackChrome(scheduleHide: false)
                } else {
                    schedulePlaybackChromeAutoHide()
                }
            }
            .onChange(of: hasActiveVideoPopup) { _, hasPopup in
                if hasPopup {
                    revealPlaybackChrome(scheduleHide: false)
                } else {
                    schedulePlaybackChromeAutoHide()
                }
            }
            .onChange(of: isSpeedPanelVisible) { _, isVisible in
                if isVisible {
                    revealPlaybackChrome(scheduleHide: false)
                } else {
                    schedulePlaybackChromeAutoHide()
                }
            }
            .onChange(of: shouldShowPlaybackChrome, initial: true) { _, isVisible in
                windowChrome.setChromeVisible(isVisible)
            }
            .onChange(of: windowChrome.pointerActivityGeneration) { _, _ in
                revealPlaybackChrome(scheduleHide: true)
            }
            .onChange(of: videoWindowAspectRatio, initial: true) { _, _ in
                synchronizeVideoWindowLayout()
            }
            .onChange(of: isMiningHistoryVisible, initial: true) { _, _ in
                synchronizeVideoWindowLayout()
            }
            .onChange(of: isMiningHistoryVisible) { _, isVisible in
                if isVisible {
                    revealPlaybackChrome(scheduleHide: false)
                } else {
                    schedulePlaybackChromeAutoHide()
                }
            }
            .onChange(of: studySidebarWidth, initial: true) { _, _ in
                synchronizeVideoWindowLayout()
            }
            .onChange(of: windowChrome.isFullScreen, initial: true) { _, isFullScreen in
                synchronizeVideoWindowLayout()
                if model.currentURL != nil {
                    revealPlaybackChrome(scheduleHide: true)
                }
                if isFullScreen {
                    ambientBackdrop.suspend(clear: false)
                } else {
                    refreshAmbientBackdrop(reason: .load)
                }
            }
            .onChange(of: windowChrome.isWindowGeometryTransitioning) { _, isTransitioning in
                if isTransitioning {
                    playbackChromeAutoHideTask?.cancel()
                    windowChrome.restorePlaybackCursor()
                    if model.currentURL != nil {
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            isPlaybackChromeVisible = true
                        }
                    }
                } else {
                    schedulePlaybackChromeAutoHide()
                }
            }
    }

    private var lifecycleModelContent: some View {
        lifecycleChromeContent
            .onChange(of: userConfig.videoRespectASSStyle) { _, _ in
                applyPreparedSubtitleRendering(logicalTrackID: model.snapshot.tracks.first {
                    $0.type == .subtitle && $0.isSelected
                }?.id)
            }
            .onChange(of: model.snapshot.tracks) { _, _ in
                restorePendingHistorySubtitleTrackIfAvailable()
                restoreRememberedSubtitleSelectionOrAutoload()
                applyEmbeddedSubtitleDefaultIfReady()
                synchronizeSelectedSubtitleTrack()
            }
            .onChange(of: model.snapshot.isLoaded) { _, isLoaded in
                guard isLoaded else { return }
                restoreRememberedSubtitleSelectionOrAutoload()
                applyEmbeddedSubtitleDefaultIfReady()
                refreshAmbientBackdrop(reason: .load)
            }
            .onChange(of: model.snapshot.isPlaying) { wasPlaying, isPlaying in
                if wasPlaying, !isPlaying {
                    refreshAmbientBackdrop(reason: .pause)
                }
                updateSubtitleGapPlayback()
            }
            .onChange(of: model.loadGeneration) { _, generation in
                ambientBackdrop.reset(for: generation)
                handleVideoLoadGeneration()
            }
    }

    private var lifecycleSceneContent: some View {
        lifecycleModelContent
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    hidePlaybackChromeForPointerExit()
                }
            }
    }

    private var lifecycleDisappearContent: some View {
        lifecycleSceneContent
            .onDisappear {
                unregisterKeyboardShortcuts()
                playbackChromeAutoHideTask?.cancel()
                windowChrome.restorePlaybackCursor()
                miningHistoryNoticeTask?.cancel()
                miningHistoryNavigationTask?.cancel()
                videoOSDTask?.cancel()
                subtitleTrackExtractionTask?.cancel()
                cancelPendingRemoteVideoOpen()
                remoteSubtitleLoader.cancelAndCleanup()
                clearTimelinePreview(clearCache: true)
                ambientBackdrop.suspend(clear: true)
                resumeVideoThumbnailsForVideoSession()
                model.engine.onEmbeddedSubtitleCuesChanged = nil
                lookup.closeAll(player: model)
                invalidatePrimarySubtitleLoad()
                _ = model.configureSubtitleRendering(.overlayOnly)
                subtitles.clear()
                model.shutdown()
            }
    }

    private var lifecycleAlertContent: some View {
        lifecycleDisappearContent
            .alert("Video Error", isPresented: errorAlertBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(
                    remoteVideoOpenErrorMessage
                        ?? model.errorMessage
                        ?? subtitles.errorMessage
                        ?? ""
                )
            }
    }

    private var lifecycleFocusedContent: some View {
        lifecycleAlertContent
            .focusedSceneValue(\.videoPlaybackCommandContext, videoPlaybackCommandContext)
    }

    private var observedContent: some View {
        playerSurface
            .ignoresSafeArea(.container, edges: .top)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDroppedItems(providers)
            }
            .onChange(of: model.snapshot.currentTime) { oldTime, time in
                subtitles.update(
                    time: time,
                    subtitleDelay: model.snapshot.subtitleDelay
                )
                updateSubtitleGapPlayback()
                refreshAmbientBackdrop(
                    reason: abs(time - oldTime) > 1.5 ? .seek : .playback
                )
            }
            .onChange(of: model.snapshot.subtitleDelay) { _, delay in
                subtitles.update(
                    time: model.snapshot.currentTime,
                    subtitleDelay: delay
                )
                updateSubtitleGapPlayback()
            }
            .onChange(of: model.currentURL) { oldURL, newURL in
                subtitleTrackExtractionTask?.cancel()
                subtitleTrackExtractionTask = nil
                activeSubtitleTrackExtractionKey = nil
                clearTimelinePreview(clearCache: true)
                if newURL != nil {
                    suspendVideoThumbnailsForVideoSession()
                    revealPlaybackChrome(scheduleHide: true)
                } else {
                    resumeVideoThumbnailsForVideoSession()
                    playbackChromeAutoHideTask?.cancel()
                    windowChrome.restorePlaybackCursor()
                    isPlaybackChromeVisible = true
                }
            }
    }

    private var playerSurface: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                videoSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                if isMiningHistoryVisible {
                    let sidebarWidth = clampedStudySidebarWidth(
                        CGFloat(studySidebarWidth),
                        availableSize: geometry.size
                    )
                    let isTranscriptSidebarTab = selectedStudySidebarTab == .transcript
                    let isChaptersSidebarTab = selectedStudySidebarTab == .chapters
                    let sidebarTranscript = isTranscriptSidebarTab
                        ? subtitles.transcript
                        : SubtitleTranscript(primary: nil, secondary: nil)
                    let sidebarChapters = isChaptersSidebarTab ? model.snapshot.chapters : []
                    let sidebarCurrentTime = (isTranscriptSidebarTab || isChaptersSidebarTab)
                        ? model.snapshot.currentTime
                        : 0
                    let sidebarPendingABLoopStart = isTranscriptSidebarTab
                        ? model.pendingABLoopStart
                        : nil
                    let sidebarABLoop = isTranscriptSidebarTab ? model.snapshot.abLoop : nil
                    let sidebarIsTranscriptLoading = isTranscriptSidebarTab
                        && subtitles.isTranscriptLoading
                    let sidebarTranscriptErrorMessage = isTranscriptSidebarTab
                        ? subtitles.transcriptErrorMessage
                        : nil
                    let canAlignPreviousSubtitle = isTranscriptSidebarTab
                        && subtitleAlignmentDelay(.previous) != nil
                    let canAlignNextSubtitle = isTranscriptSidebarTab
                        && subtitleAlignmentDelay(.next) != nil

                    VideoMiningHistorySidebar(
                        selectedTab: $selectedStudySidebarTab,
                        items: miningHistory.items,
                        transcript: sidebarTranscript,
                        chapters: sidebarChapters,
                        currentTime: sidebarCurrentTime,
                        duration: isChaptersSidebarTab ? model.snapshot.duration : 0,
                        pendingABLoopStart: sidebarPendingABLoopStart,
                        abLoop: sidebarABLoop,
                        isTranscriptLoading: sidebarIsTranscriptLoading,
                        transcriptErrorMessage: sidebarTranscriptErrorMessage,
                        canAlignPreviousSubtitle: canAlignPreviousSubtitle,
                        canAlignNextSubtitle: canAlignNextSubtitle,
                        onClose: {
                            withAnimation(.smooth(duration: 0.22)) {
                                isMiningHistoryVisible = false
                            }
                        },
                        onJump: { item in
                            navigateToHistoryItem(item)
                        },
                        onSeekTranscript: { time in
                            dismissVideoPopupsIfNeeded()
                            model.seek(to: time + model.snapshot.subtitleDelay)
                        },
                        onSetTranscriptABLoopStart: { time in
                            dismissVideoPopupsIfNeeded()
                            model.setABLoopStart(at: time)
                        },
                        onSetTranscriptABLoopEnd: { time in
                            dismissVideoPopupsIfNeeded()
                            model.setABLoopEnd(at: time)
                        },
                        onAlignPreviousSubtitle: {
                            _ = alignAdjacentSubtitleToCurrentTime(.previous)
                        },
                        onAlignNextSubtitle: {
                            _ = alignAdjacentSubtitleToCurrentTime(.next)
                        },
                        onSeekChapter: { chapterID in
                            dismissVideoPopupsIfNeeded()
                            model.seekToChapter(chapterID)
                        },
                        onCopy: { item in
                            copyMiningHistorySubtitle(item)
                        },
                        onDelete: { id in
                            miningHistory.delete(id: id)
                        },
                        onClear: {
                            miningHistory.clear()
                        }
                    )
                    .frame(width: sidebarWidth)
                    .overlay(alignment: .leading) {
                        VideoStudySidebarResizeHandle()
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        if studySidebarDragStartWidth == nil {
                                            studySidebarDragStartWidth = sidebarWidth
                                        }

                                        let startWidth = studySidebarDragStartWidth ?? sidebarWidth
                                        let nextWidth = startWidth - value.translation.width
                                        studySidebarWidth = Double(
                                            clampedStudySidebarWidth(
                                                nextWidth,
                                                availableSize: geometry.size
                                            )
                                        )
                                    }
                                    .onEnded { _ in
                                        studySidebarWidth = Double(
                                            clampedStudySidebarWidth(
                                                CGFloat(studySidebarWidth),
                                                availableSize: geometry.size
                                            )
                                        )
                                        studySidebarDragStartWidth = nil
                                    }
                            )
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.black)
            .onHover { hovering in
                playerSurfaceHoverChanged(hovering)
            }
            .animation(.smooth(duration: 0.22), value: isMiningHistoryVisible)
        }
    }

    private func clampedStudySidebarWidth(
        _ width: CGFloat,
        availableSize: CGSize
    ) -> CGFloat {
        let availableMaxWidth = max(
            VideoMiningHistorySidebar.minWidth,
            min(
                VideoMiningHistorySidebar.maxWidth,
                availableSize.width - Self.minimumVideoSurfaceWidth
            )
        )
        let clampedWidth = min(max(width, VideoMiningHistorySidebar.minWidth), availableMaxWidth)
        return VideoWindowAspectLayout.aspectFittingSidebarWidth(
            contentSize: availableSize,
            videoAspectRatio: windowChrome.isFullScreen ? nil : videoWindowAspectRatio,
            proposedWidth: clampedWidth,
            minWidth: VideoMiningHistorySidebar.minWidth,
            maxWidth: availableMaxWidth
        )
    }

    private var videoSurface: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                ZStack(alignment: .trailing) {
                    videoCanvas
                    if isInspectorVisible {
                        inspectorOverlay
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: VideoInspectorOverlayFramePreferenceKey.self,
                                        value: proxy.frame(in: .named(Self.videoPlayerCoordinateSpace))
                                    )
                                }
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .contentShape(Rectangle())
                            .onTapGesture {}
                            .zIndex(10)
                    }
                }
                .animation(.smooth(duration: 0.22), value: isInspectorVisible)
                .coordinateSpace(name: Self.videoPlayerCoordinateSpace)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: ambientPresentation.workspaceCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    if ambientPresentation.workspaceCornerRadius > 0 {
                        RoundedRectangle(
                            cornerRadius: ambientPresentation.workspaceCornerRadius,
                            style: .continuous
                        )
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                        .allowsHitTesting(false)
                    }
                }

                ForEach(lookup.presentation.popups) { popup in
                    popupView(popup, screenSize: geometry.size)
                }

                if let miningHistoryNotice {
                    videoMiningHistoryNotice(miningHistoryNotice)
                        .padding(.top, 42)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1000)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var ambientPresentation: VideoAmbientPresentation {
        VideoAmbientPresentation.resolve(isFullScreen: windowChrome.isFullScreen)
    }

    private var videoWindowAspectRatio: CGFloat? {
        VideoWindowAspectLayout.videoAspectRatio(
            displaySize: model.snapshot.videoDisplaySize,
            override: model.snapshot.aspectRatio,
            rotation: model.snapshot.rotation
        )
    }

    private func synchronizeVideoWindowLayout() {
        windowChrome.setVideoLayout(
            videoAspectRatio: videoWindowAspectRatio,
            studySidebarWidth: CGFloat(studySidebarWidth),
            isStudySidebarVisible: isMiningHistoryVisible && !windowChrome.isFullScreen
        )
    }

    private func refreshAmbientBackdrop(reason: VideoAmbientRefreshReason) {
        guard ambientPresentation.usesBlurredLetterbox else {
            ambientBackdrop.suspend(clear: true)
            return
        }
        ambientBackdrop.refresh(
            reason: reason,
            engine: model.engine,
            generation: model.loadGeneration,
            isLoaded: model.snapshot.isLoaded,
            isPlaying: model.snapshot.isPlaying,
            isActive: isActive && scenePhase == .active,
            isFullScreen: windowChrome.isFullScreen
        )
    }

    private func suspendVideoThumbnailsForVideoSession() {
        Task {
            await VideoThumbnailScheduler.shared.suspend(reason: .playback)
        }
    }

    private func resumeVideoThumbnailsForVideoSession() {
        Task {
            await VideoThumbnailScheduler.shared.resume(reason: .playback)
        }
    }

    private func updateTimelinePreview(at time: TimeInterval?) {
        guard let time,
              model.currentURL != nil,
              model.snapshot.duration > 0 else {
            clearTimelinePreview()
            return
        }

        let clampedTime = clampedTimelinePreviewTime(time)
        timelinePreviewRequestedTime = clampedTime
        timelinePreview = VideoTimelinePreview(time: clampedTime, pngData: nil)
    }

    private func clearTimelinePreview(clearCache _: Bool = false) {
        timelinePreviewRequestedTime = nil
        timelinePreview = nil
    }

    private func clampedTimelinePreviewTime(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        let duration = max(model.snapshot.duration, 0)
        guard duration > 0 else { return 0 }
        return min(max(time, 0), duration)
    }

    private var videoCanvas: some View {
        GeometryReader { geometry in
            let subtitleViewport = VideoWindowAspectLayout.videoViewport(
                in: geometry.size,
                renderGeometry: model.snapshot.videoRenderGeometry,
                aspectRatio: videoWindowAspectRatio
            )

            ZStack(alignment: .bottom) {
                MpvRenderView(
                    engine: model.engine as! MpvPlayerEngine,
                    onRenderReady: handleRenderReady
                )
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        handleVideoPointerMovement(phase)
                    }
                    .gesture(
                        TapGesture(count: 2)
                            .onEnded {
                                toggleFullScreenFromPointer()
                            }
                            .exclusively(
                                before: TapGesture(count: 1)
                                    .onEnded {
                                        togglePlaybackFromPointer()
                                    }
                            )
                    )

                VideoAmbientBackdrop(
                    image: ambientBackdrop.image,
                    presentation: ambientPresentation
                )
                .zIndex(0.25)

                if windowChrome.showsWindowedTitlebarSurface {
                    videoWindowDragStrip
                        .zIndex(0.5)
                }

                if model.currentURL != nil {
                    VideoSurfaceScrollBridge(
                        isEnabled: shouldHandleVideoSurfaceVolumeScroll,
                        excludedRects: videoSurfaceVolumeScrollExcludedRects(in: geometry.size),
                        onScroll: { delta in
                            adjustVolume(by: delta)
                            revealPlaybackChrome(scheduleHide: true)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .zIndex(1.5)
                }

                if shouldShowVideoDismissLayer {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissVideoOverlaysFromCanvas()
                        }
                        .zIndex(2.5)
                }

                if model.currentURL == nil {
                    ContentUnavailableView {
                        Label("No Video Open", systemImage: "play.rectangle")
                    } description: {
                        Text("Open a local video file to start watching.")
                    } actions: {
                        Button("Open Video") {
                            presentFileImporter(.video)
                        }
                        Button("Open Link") {
                            isOpeningRemoteLink = true
                        }
                    }
                    .foregroundStyle(.white)
                    .zIndex(2)
                } else if areSubtitlesVisible,
                          subtitleRenderingMode.usesInteractiveOverlay {
                    SubtitleOverlayView(
                        cues: subtitleOverlayCues,
                        contextCues: subtitles.document?.cues ?? subtitles.currentCues,
                        scanLength: userConfig.scanLength,
                        contentLanguage: profileRepository.activeProfile.language,
                        hoverLookupDelayMs: userConfig.desktopLookupHoverDelayMs,
                        maskEnabled: userConfig.videoSubtitleMaskEnabled,
                        maskMode: userConfig.videoSubtitleMaskMode,
                        maskBlurRadius: userConfig.videoSubtitleMaskBlurRadius,
                        maskHiddenOpacity: userConfig.videoSubtitleMaskHiddenOpacity,
                        fontFamily: userConfig.videoSubtitleFontFamily,
                        fontSize: userConfig.videoSubtitleFontSize,
                        fontWeight: userConfig.videoSubtitleFontWeight,
                        edgeStyle: userConfig.videoSubtitleEdgeStyle,
                        edgeStrength: userConfig.videoSubtitleEdgeStrength,
                        backgroundOpacity: userConfig.videoSubtitleBackgroundOpacity,
                        backgroundDisabled: userConfig.videoSubtitleBackgroundDisabled,
                        verticalPosition: userConfig.videoSubtitleVerticalPosition,
                        subtitleColor: userConfig.videoSubtitleColor,
                        lookupHighlightColor: userConfig.videoSubtitleLookupHighlightColor,
                        lookupHighlightTextColor: userConfig.videoSubtitleLookupHighlightTextColor,
                        isLookupPopupVisible: hasVisibleVideoPopup,
                        isPlaybackPaused: !model.snapshot.isPlaying,
                        assRenderPlan: userConfig.videoRespectASSStyle ? subtitles.document?.assRenderPlan : nil,
                        playbackTime: model.snapshot.currentTime - model.snapshot.subtitleDelay
                    ) { cue, selection in
                        lookup.present(
                            selection: selection,
                            cue: cue,
                            player: model,
                            userConfig: userConfig,
                            replacingExisting: true
                        )
                    }
                    .frame(
                        width: subtitleViewport.width,
                        height: subtitleViewport.height,
                        alignment: .bottom
                    )
                    .position(
                        x: subtitleViewport.midX,
                        y: subtitleViewport.midY
                    )
                    .zIndex(2)
                }

                if shouldShowVideoLoadingIndicator {
                    ZStack {
                        Color.black

                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Loading Video...")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.86))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Loading Video..."))
                    .zIndex(50)
                }

                if let videoOSD, model.currentURL != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        VideoOnScreenDisplayView(item: videoOSD)
                            .padding(.top, 30)
                            .padding(.leading, 28)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(2.6)
                }

                if model.currentURL != nil {
                    VideoControlsView(
                        snapshot: model.snapshot,
                        timelinePreview: timelinePreview,
                        playlist: model.playlist,
                        canSaveScreenshot: model.snapshot.isLoaded && !model.snapshot.isSeeking
                            && model.snapshot.videoDisplaySize != nil && !isSavingScreenshot,
                        canMineCurrentSubtitle: canMineCurrentSubtitle,
                        isFullScreen: windowChrome.isFullScreen,
                        isSubtitleGapFastForwardEnabled: userConfig.videoSubtitleGapFastForwardEnabled,
                        isMiningHistoryVisible: isMiningHistoryVisible,
                        isInspectorVisible: isInspectorVisible,
                        layout: userConfig.videoControlBarLayout,
                        availableWidth: geometry.size.width,
                        isSpeedPanelVisible: $isSpeedPanelVisible,
                        onTogglePlayback: {
                            model.togglePlayback()
                            revealPlaybackChrome(scheduleHide: true)
                        },
                        onSeek: { time in
                            model.seek(to: time)
                            revealPlaybackChrome(scheduleHide: true)
                        },
                        onPrevious: {
                            model.playPrevious()
                            revealPlaybackChrome(scheduleHide: true)
                        },
                        onNext: {
                            model.playNext()
                            revealPlaybackChrome(scheduleHide: true)
                        },
                        onSetVolume: { volume in
                            setVolumeWithOSD(volume)
                            revealPlaybackChrome(scheduleHide: true)
                        },
                        onToggleMuted: {
                            toggleMuteWithOSD()
                            revealPlaybackChrome(scheduleHide: true)
                        },
                        onSetSpeed: { speed in
                            dismissVideoPopupsIfNeeded()
                            setSpeedWithOSD(speed)
                            revealPlaybackChrome(scheduleHide: true)
                        },
                        onToggleMiningHistory: {
                            revealPlaybackChrome(scheduleHide: false)
                            dismissVideoPopupsThen {
                                toggleMiningHistory()
                            }
                        },
                        onOpenVideo: {
                            revealPlaybackChrome(scheduleHide: true)
                            dismissVideoPopupsThen {
                                presentFileImporter(.video)
                            }
                        },
                        onSaveScreenshot: saveCleanScreenshot,
                        onMineCurrentSubtitle: {
                            mineCurrentSubtitle()
                            revealPlaybackChrome(scheduleHide: true)
                        },
                        onToggleSubtitleGapFastForward: {
                            toggleSubtitleGapFastForward()
                            revealPlaybackChrome(scheduleHide: true)
                        },
                        onToggleInspector: {
                            revealPlaybackChrome(scheduleHide: false)
                            dismissVideoPopupsThen {
                                toggleInspector()
                            }
                        },
                        onToggleFullScreen: {
                            revealPlaybackChrome(scheduleHide: true)
                            dismissVideoPopupsThen {
                                toggleFullScreen()
                            }
                        },
                        onTimelinePreviewTimeChanged: { time in
                            updateTimelinePreview(at: time)
                            if time != nil {
                                revealPlaybackChrome(scheduleHide: false)
                            } else {
                                schedulePlaybackChromeAutoHide()
                            }
                        },
                        onDragChanged: { translation in
                            revealPlaybackChrome(scheduleHide: false)
                            var dragTransaction = Transaction(animation: nil)
                            dragTransaction.disablesAnimations = true
                            withTransaction(dragTransaction) {
                                playbackChromeDragOffset = translation
                            }
                        },
                        onDragEnded: { translation in
                            let finalOffset = clampedPlaybackChromeOffset(
                                CGSize(
                                    width: playbackChromeStoredOffset.width + translation.width,
                                    height: playbackChromeStoredOffset.height + translation.height
                                ),
                                in: geometry.size
                            )
                            withAnimation(.smooth(duration: 0.18)) {
                                playbackChromeStoredOffset = finalOffset
                                playbackChromeDragOffset = .zero
                            }
                            revealPlaybackChrome(scheduleHide: true)
                        }
                    )
                    .position(playbackChromeBasePosition(in: geometry.size))
                    .offset(playbackChromeCurrentOffset(in: geometry.size))
                    .onHover { hovering in
                        playbackChromeHoverChanged(hovering)
                    }
                    .opacity(shouldShowPlaybackChrome ? 1 : 0)
                    .allowsHitTesting(shouldShowPlaybackChrome)
                    .accessibilityHidden(!shouldShowPlaybackChrome)
                    .zIndex(3)
                }

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.easeInOut(duration: 0.16), value: shouldShowPlaybackChrome)
            .onPreferenceChange(VideoInspectorOverlayFramePreferenceKey.self) { frame in
                inspectorOverlayFrame = frame ?? .zero
            }
            .onChange(of: geometry.size) { _, size in
                guard !windowChrome.isWindowGeometryTransitioning else { return }
                let nextStoredOffset: CGSize
                if userConfig.videoControlBarLayout == .compactBottom {
                    nextStoredOffset = .zero
                } else {
                    nextStoredOffset = clampedPlaybackChromeOffset(
                        playbackChromeStoredOffset,
                        in: size
                    )
                }
                if playbackChromeStoredOffset != nextStoredOffset {
                    playbackChromeStoredOffset = nextStoredOffset
                }
                if playbackChromeDragOffset != .zero {
                    playbackChromeDragOffset = .zero
                }
            }
            .onChange(of: userConfig.videoControlBarLayout) { _, layout in
                if layout == .compactBottom {
                    playbackChromeStoredOffset = .zero
                } else {
                    playbackChromeStoredOffset = clampedPlaybackChromeOffset(
                        playbackChromeStoredOffset,
                        in: geometry.size
                    )
                }
                playbackChromeDragOffset = .zero
            }
        }
    }

    private var videoWindowDragStrip: some View {
        VStack(spacing: 0) {
            ZStack {
                VideoTitlebarBackdrop()
                    .overlay(alignment: .bottom) {
                        Divider()
                    }
                    .opacity(shouldShowPlaybackChrome ? 1 : 0)
                    .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
            }
            .frame(height: 32)
            Spacer(minLength: 0)
        }
    }

    var videoControlsMetrics: VideoControlsMetrics {
        VideoControlsView.metrics(for: userConfig.videoControlBarLayout)
    }

    private var inspectorOverlay: some View {
        VideoInspectorView(
            selectedTab: $selectedInspectorTab,
            state: model.inspectorState,
            playlist: model.playlist,
            currentURL: model.currentURL,
            currentTitle: model.currentTitle,
            primarySubtitleName: selectedRemoteSubtitleID == nil
                ? (selectedAJATTSubtitleName
                    ?? selectedJimakuSubtitleName
                    ?? externalSubtitleName)
                : nil,
            isPrimarySubtitleActive: areSubtitlesVisible
                && subtitles.document != nil
                && subtitles.document?.format != .embedded,
            remoteSubtitleOptions: currentRemoteSubtitleOptions,
            selectedRemoteSubtitleID: selectedRemoteSubtitleID,
            selectedJimakuSubtitleID: selectedJimakuSubtitleID,
            selectedJimakuSubtitleName: selectedJimakuSubtitleName,
            selectedAJATTSubtitleID: selectedAJATTSubtitleID,
            selectedAJATTSubtitleName: selectedAJATTSubtitleName,
            remoteQualityOptions: currentRemoteQualityOptions,
            selectedRemoteQualityID: selectedRemoteQualityID,
            onSelectEpisode: { url in
                openPlaylistEpisode(url)
            },
            onSetSpeed: { speed in
                dismissVideoPopupsIfNeeded()
                setSpeedWithOSD(speed)
            },
            onSetSubtitleDelay: { delay in
                dismissVideoPopupsIfNeeded()
                setSubtitleDelayWithOSD(delay)
            },
            onSetAudioDelay: { delay in
                dismissVideoPopupsIfNeeded()
                setAudioDelayWithOSD(delay)
            },
            onSetLoopMode: { mode in
                dismissVideoPopupsIfNeeded()
                model.setLoopMode(mode)
            },
            onSetABLoopStart: {
                dismissVideoPopupsIfNeeded()
                model.setABLoopStart()
            },
            onSetABLoopEnd: {
                dismissVideoPopupsIfNeeded()
                model.setABLoopEnd()
            },
            onClearABLoop: {
                dismissVideoPopupsIfNeeded()
                model.clearABLoop()
            },
            onSetAspectRatio: { aspectRatio in
                dismissVideoPopupsIfNeeded()
                model.setAspectRatio(aspectRatio)
            },
            onRotateClockwise: {
                dismissVideoPopupsIfNeeded()
                model.rotateClockwise()
            },
            onSetVideoShaderPreset: { preset in
                dismissVideoPopupsIfNeeded()
                _ = model.setVideoShaderPreset(preset)
            },
            onSelectTrack: { type, id in
                dismissVideoPopupsIfNeeded()
                if type == .subtitle {
                    if let id {
                        selectSubtitleTrack(id, rememberSelection: true)
                    } else {
                        // Turning the subtitle track off should not discard a
                        // downloaded catalog subtitle from External Subtitles.
                        applySubtitlesOff(clearPrimary: false, rememberSelection: true)
                        showSubtitleTrackOSD(track: nil)
                    }
                    return
                }
                model.selectTrack(type: type, id: id)
            },
            onSelectRemoteSubtitle: { option in
                dismissVideoPopupsIfNeeded()
                loadRemoteSubtitle(option, rememberSelection: true)
            },
            onSelectJimakuSubtitle: { file in
                dismissVideoPopupsIfNeeded()
                loadJimakuSubtitle(file)
            },
            onSelectAJATTSubtitle: { file in
                dismissVideoPopupsIfNeeded()
                loadAJATTSubtitle(file)
            },
            onSelectOpenSubtitles: { option in
                dismissVideoPopupsIfNeeded()
                loadCatalogSubtitle(option: option, id: option.id, name: option.name, source: .openSubtitles)
            },
            onSelectExternalSubtitle: {
                dismissVideoPopupsIfNeeded()
                restoreRememberedExternalSubtitle()
            },
            onSelectRemoteQuality: { option in
                dismissVideoPopupsIfNeeded()
                selectRemoteQuality(option)
            },
            onOpenSubtitle: {
                dismissVideoPopupsIfNeeded()
                presentFileImporter(.primarySubtitle)
            },
            onClearPrimarySubtitle: {
                dismissVideoPopupsIfNeeded()
                applySubtitlesOff(clearPrimary: true, rememberSelection: true)
                showSubtitleTrackOSD(track: nil)
            },
            onOpenTranscript: {
                toggleTranscriptSidebar()
            },
            onClose: {
                dismissVideoPopupsIfNeeded()
                isInspectorVisible = false
            }
        )
        .equatable()
        .padding(.top, Self.inspectorOverlayVerticalInset)
        .padding(.bottom, inspectorOverlayBottomInset)
        .padding(.trailing, Self.inspectorOverlayTrailingInset)
    }

    /// Playback chrome stays visible while the inspector is open, so the
    /// inspector ends above the controls instead of covering their trailing
    /// tools (including its own toggle). The floating panel sits in its
    /// default bottom position; a panel dragged elsewhere can still overlap.
    private var inspectorOverlayBottomInset: CGFloat {
        switch userConfig.videoControlBarLayout {
        case .floating:
            Self.playbackChromeEdgeInset
                + videoControlsMetrics.bottomInset
                + videoControlsMetrics.controlHeight
                + Self.inspectorOverlayVerticalInset / 2
        case .compactBottom:
            videoControlsMetrics.controlHeight + Self.inspectorOverlayVerticalInset / 2
        }
    }

    var currentRemoteSubtitleOptions: [RemoteVideoSubtitleOption] {
        guard case .remoteStream(let source) = model.currentSource else { return [] }
        return source.subtitleOptions
    }

    private var externalSubtitleName: String? {
        if let document = subtitles.document, document.format != .embedded {
            return document.sourceURL.lastPathComponent
        }
        guard let url = model.rememberedExternalSubtitleURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url.lastPathComponent
    }

    private var currentRemoteQualityOptions: [RemoteVideoQualityOption] {
        guard case .remoteStream(let source) = model.currentSource,
              source.identity.supportsQualitySelection,
              source.qualityOptions.count > 1 else { return [] }
        return source.qualityOptions
    }

    var selectedRemoteQualityID: String? {
        guard case .remoteStream(let source) = model.currentSource else { return nil }
        return source.qualityOptions.first {
            $0.playbackStream.url == source.playbackStream.url
                && $0.audioStream?.url == source.audioStream?.url
        }?.id
    }

    private var videoPlaybackCommandContext: VideoPlaybackCommandContext {
        VideoPlaybackCommandContext(
            snapshot: model.snapshot,
            playlist: model.playlist,
            currentURL: model.currentURL,
            areSubtitlesVisible: areSubtitlesVisible,
            primarySubtitleName: subtitles.document?.sourceURL.lastPathComponent,
            canMineCurrentSubtitle: canMineCurrentSubtitle,
            openVideo: {
                dismissVideoPopupsThen {
                    presentFileImporter(.video)
                }
            },
            openRemoteLink: {
                dismissVideoPopupsThen {
                    isOpeningRemoteLink = true
                }
            },
            playPause: {
                guard model.currentURL != nil else { return }
                model.togglePlayback()
            },
            previousEpisode: {
                guard model.playlist.previousURL != nil else { return }
                model.playPrevious()
            },
            nextEpisode: {
                guard model.playlist.nextURL != nil else { return }
                model.playNext()
            },
            setSpeed: { speed in
                dismissVideoPopupsIfNeeded()
                setSpeedWithOSD(speed)
            },
            setAspectRatio: { aspectRatio in
                dismissVideoPopupsIfNeeded()
                model.setAspectRatio(aspectRatio)
            },
            rotateClockwise: {
                dismissVideoPopupsIfNeeded()
                model.rotateClockwise()
            },
            toggleFileLoop: {
                dismissVideoPopupsIfNeeded()
                model.setLoopMode(model.snapshot.loopMode == .file ? .none : .file)
            },
            setABLoopStart: {
                dismissVideoPopupsIfNeeded()
                model.setABLoopStart()
            },
            setABLoopEnd: {
                dismissVideoPopupsIfNeeded()
                model.setABLoopEnd()
            },
            clearABLoop: {
                dismissVideoPopupsIfNeeded()
                model.clearABLoop()
            },
            selectTrack: { type, id in
                dismissVideoPopupsIfNeeded()
                if type == .subtitle {
                    if let id {
                        selectSubtitleTrack(id, rememberSelection: true)
                    } else {
                        applySubtitlesOff(clearPrimary: true, rememberSelection: true)
                        showSubtitleTrackOSD(track: nil)
                    }
                    return
                }
                model.selectTrack(type: type, id: id)
            },
            toggleMuted: {
                toggleMuteWithOSD()
            },
            adjustVolume: { delta in
                adjustVolume(by: delta)
            },
            adjustAudioDelay: { delta in
                adjustAudioDelayWithOSD(by: delta)
            },
            resetAudioDelay: {
                setAudioDelayWithOSD(0)
            },
            openSubtitles: {
                dismissVideoPopupsIfNeeded()
                presentFileImporter(.primarySubtitle)
            },
            clearPrimarySubtitle: {
                dismissVideoPopupsIfNeeded()
                applySubtitlesOff(clearPrimary: true, rememberSelection: true)
                showSubtitleTrackOSD(track: nil)
            },
            toggleSubtitlesVisible: {
                toggleSubtitlesVisible()
            },
            previousSubtitleCue: {
                _ = seekRelativeSubtitleCue(offset: -1)
            },
            nextSubtitleCue: {
                _ = seekRelativeSubtitleCue(offset: 1)
            },
            cycleSubtitleTrack: {
                _ = cycleSubtitleTrack()
            },
            adjustSubtitleDelay: { delta in
                adjustSubtitleDelayWithOSD(by: delta)
            },
            resetSubtitleDelay: {
                setSubtitleDelayWithOSD(0)
            },
            openTranscript: {
                toggleTranscriptSidebar()
            },
            mineCurrentSubtitle: {
                mineCurrentSubtitle()
            }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: {
                remoteVideoOpenErrorMessage != nil
                    || model.errorMessage != nil
                    || subtitles.errorMessage != nil
            },
            set: { visible in
                if !visible {
                    remoteVideoOpenErrorMessage = nil
                    model.errorMessage = nil
                    subtitles.errorMessage = nil
                }
            }
        )
    }

    private func openRemoteLink(_ resolvedSource: ResolvedRemoteVideoSource) {
        openVideo(.remoteStream(resolvedSource), subtitleURL: nil)
    }

    private func handleRenderReady() {
        guard let request = openGate.renderDidBecomeReady() else { return }
        openExternalRequest(request)
    }

    private var shouldShowVideoLoadingIndicator: Bool {
        isResolvingRemoteVideo
            || (
                model.currentURL != nil
                    && !model.snapshot.isLoaded
                    && model.errorMessage == nil
            )
    }

    func loadDroppedMedia(_ mediaURL: URL, subtitleURL: URL?) {
        openVideo(mediaURL, subtitleURL: subtitleURL)
    }

    func isMediaFile(_ url: URL) -> Bool {
        VideoMediaTypes.isMediaFile(url)
    }

    nonisolated static func fileURL(from item: Any?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }

    private func popupView(_ popup: PopupItem, screenSize: CGSize) -> some View {
        let popupID = popup.id
        return PopupView(
            userConfig: userConfig,
            isVisible: Binding(
                get: {
                    lookup.presentation.popups
                        .first(where: { $0.id == popupID })?
                        .showPopup ?? false
                },
                set: { visible in
                    lookup.presentation.setVisibility(id: popupID, visible: visible)
                }
            ),
            selectionData: popup.currentSelection,
            lookupResults: popup.lookupResults,
            dictionaryStyles: popup.dictionaryStyles,
            screenSize: screenSize,
            isVertical: false,
            isFullWidth: false,
            bottomInset: videoControlsMetrics.popupBottomInset,
            coverURL: nil,
            documentTitle: model.currentTitle,
            profileID: profileRepository.activeProfile.id,
            clearSelection: popup.clearSelection,
            onTextSelected: { selection in
                lookup.presentation.closeChildren(of: popupID)
                return lookup.present(
                    selection: selection,
                    player: model,
                    userConfig: userConfig
                )
            },
            onTapOutside: {
                lookup.presentation.handleTapInsidePopup(id: popupID)
            },
            onSwipeDismiss: {
                lookup.dismiss(id: popupID, player: model)
            },
            miningContextProvider: { _, selectedContext in
                guard let cue = lookup.activeCue,
                      let videoURL = model.currentURL else {
                    return MiningContext(
                        sentence: popup.currentSelection?.sentence ?? "",
                        documentTitle: model.currentTitle,
                        coverURL: nil
                    )
                }
                let needsScreenshot = AnkiManager.shared.needsVideoScreenshot
                let needsAudioClip = AnkiManager.shared.needsVideoAudioClip
                let ankiMediaDirectory = (needsScreenshot || needsAudioClip)
                    ? await AnkiManager.shared.getMediaDirPath()
                    : nil
                return await VideoMiningCoordinator.context(
                    cue: cue,
                    selectedContext: selectedContext,
                    document: subtitles.document,
                    videoURL: videoURL,
                    videoTitle: model.currentTitle ?? videoURL.lastPathComponent,
                    mediaIdentity: model.currentMediaIdentity
                        ?? .localFile(path: videoURL.standardizedFileURL.path),
                    engine: model.engine,
                    captureScreenshot: needsScreenshot,
                    compressScreenshot: AnkiManager.shared.compressImages,
                    imageFormat: AnkiManager.shared.imageCompressionFormat,
                    screenshotQuality: AnkiManager.shared.imageCompressionQuality,
                    animatedAVIFMaximumHeight: AnkiManager.shared.animatedAVIFMaximumHeight,
                    animatedAVIFFramesPerSecond: AnkiManager.shared.animatedAVIFFramesPerSecond,
                    captureAudioClip: needsAudioClip,
                    audioFormat: AnkiManager.shared.audioCompressionFormat,
                    audioBitrateKbps: AnkiManager.shared.audioCompressionBitrateKbps,
                    ankiMediaDirectory: ankiMediaDirectory
                )
            }
        )
        .id(popupID)
        .zIndex(Double(100 + (
            lookup.presentation.popups.firstIndex(where: { $0.id == popupID }) ?? 0
        )))
    }

    private func synchronizePlaybackPreferences() {
        model.autoPlayNext = userConfig.videoAutoPlayNext
        model.rememberPlaybackPosition = userConfig.videoRememberPlaybackPosition
        model.setSubtitleGapFastForwardEnabled(userConfig.videoSubtitleGapFastForwardEnabled)
        model.setSubtitleGapFastForwardSpeed(userConfig.videoSubtitleGapFastForwardSpeed)
        model.setHardwareDecodingEnabled(userConfig.videoHardwareDecodingEnabled)
        model.setDeinterlacingEnabled(userConfig.videoDeinterlacingEnabled)
        model.setHDREnhancementEnabled(userConfig.videoHDREnhancementEnabled)
        _ = model.setVideoShaderPreset(userConfig.videoShaderPreset)
        synchronizeVideoEqualizerPreferences()
    }

    func toggleSubtitleGapFastForward() {
        userConfig.videoSubtitleGapFastForwardEnabled.toggle()
        model.setSubtitleGapFastForwardEnabled(userConfig.videoSubtitleGapFastForwardEnabled)
        updateSubtitleGapPlayback()
    }

    private func updateSubtitleGapPlayback() {
        model.updateSubtitleGapPlayback(
            slice: subtitles.slice(
                time: model.snapshot.currentTime,
                subtitleDelay: model.snapshot.subtitleDelay
            ),
            playbackTime: model.snapshot.currentTime - model.snapshot.subtitleDelay,
            isPlaybackPaused: !model.snapshot.isPlaying
        )
    }

    private func synchronizeVideoEqualizerPreferences() {
        model.setVideoEqualizer(.brightness, value: userConfig.videoBrightness)
        model.setVideoEqualizer(.contrast, value: userConfig.videoContrast)
        model.setVideoEqualizer(.saturation, value: userConfig.videoSaturation)
        model.setVideoEqualizer(.gamma, value: userConfig.videoGamma)
        model.setVideoEqualizer(.hue, value: userConfig.videoHue)
    }

    private var fileImporterPresentation: Binding<Bool> {
        Binding(
            get: { pendingFileImportKind != nil },
            set: { isPresented in
                if !isPresented {
                    pendingFileImportKind = nil
                }
            }
        )
    }

    var shouldShowPlaybackChrome: Bool {
        model.currentURL == nil
            || (
                isPointerInsidePlayerSurface
                    && (
                        isPlaybackChromeVisible
                            || hasActiveVideoPopup
                            || isInspectorVisible
                            || isMiningHistoryVisible
                            || isSpeedPanelVisible
                    )
            )
    }

    func adjustVolume(by delta: Double) {
        setVolumeWithOSD(model.snapshot.volume + delta)
    }

    private func saveCleanScreenshot() {
        guard model.snapshot.isLoaded, !model.snapshot.isSeeking,
              !isSavingScreenshot, let sourceURL = model.currentURL else { return }
        isSavingScreenshot = true
        revealPlaybackChrome(scheduleHide: false)
        let window = NSApp.keyWindow
        let seconds = model.snapshot.currentTime
        let filename = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
        Task { @MainActor in
            defer {
                isSavingScreenshot = false
                revealPlaybackChrome(scheduleHide: true)
            }
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("niratan-screenshot-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            do {
                // Capture before presenting the panel so playback cannot change the chosen frame.
                // PlaybackEngine uses mpv's video-only capture, excluding subtitles and window chrome.
                try await model.engine.captureScreenshot(to: temporaryURL)
                let data = try Data(contentsOf: temporaryURL)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "\(filename)-\(String(format: "%.3f", seconds)).png"
                let response = await withCheckedContinuation { continuation in
                    if let window {
                        panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                    } else {
                        panel.begin { continuation.resume(returning: $0) }
                    }
                }
                guard response == .OK, let destination = panel.url else { return }
                let scoped = destination.startAccessingSecurityScopedResource()
                defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                try data.write(to: destination, options: .atomic)
                showVideoOSD(VideoOnScreenDisplayItem(title: "Screenshot Saved", value: ""))
            } catch {
                model.errorMessage = String(localized: "Unable to save the video screenshot.")
            }
        }
    }

    private var canMineCurrentSubtitle: Bool {
        userConfig.videoMiningHistoryLimit > 0
            && model.currentURL != nil
            && subtitles.document != nil
            && !subtitles.currentCues.isEmpty
    }

    private func handleVideoLoadGeneration() {
        if shouldSkipNextAutomaticSubtitleRestore {
            shouldSkipNextAutomaticSubtitleRestore = false
            _ = model.consumePendingSubtitleSelection()
            if model.subtitlePreservingLoadGeneration == model.loadGeneration {
                restorePreservedSubtitleRenderingAfterMediaReload()
            }
            return
        }
        if model.subtitlePreservingLoadGeneration == model.loadGeneration {
            _ = model.consumePendingSubtitleSelection()
            restorePreservedSubtitleRenderingAfterMediaReload()
            return
        }
        lookup.closeAll(player: model)
        cancelSubtitleTrackExtraction()
        invalidatePrimarySubtitleLoad()
        subtitles.clear()
        isAwaitingEmbeddedSubtitleDefault = false
        guard let mediaURL = model.currentURL else { return }
        restoreRememberedSubtitleSelectionOrAutoload(for: mediaURL)
    }

    var hasActiveVideoPopup: Bool {
        !lookup.presentation.popups.isEmpty
    }

    private var hasVisibleVideoPopup: Bool {
        lookup.presentation.popups.contains { $0.showPopup }
    }

    private var shouldShowVideoDismissLayer: Bool {
        hasActiveVideoPopup || isInspectorVisible || isSpeedPanelVisible
    }

    private var shouldHandleVideoSurfaceVolumeScroll: Bool {
        model.currentURL != nil
            && !hasActiveVideoPopup
    }

    func dismissVideoPopupsIfNeeded() {
        guard hasActiveVideoPopup else { return }
        videoScreenLog.info("Dismissing active video lookup popups")
        lookup.closeAll(player: model)
    }

    func dismissVideoPopupsThen(_ action: @escaping () -> Void) {
        guard hasActiveVideoPopup else {
            action()
            return
        }
        videoScreenLog.info("Deferring video action until lookup popup stack closes")
        lookup.closeAll(player: model) {
            action()
        }
    }

    private func dismissVideoOverlaysFromCanvas() {
        dismissVideoPopupsIfNeeded()
        if isSpeedPanelVisible {
            withAnimation(.smooth(duration: 0.16)) {
                isSpeedPanelVisible = false
            }
        }
        if isInspectorVisible {
            videoScreenLog.info("Closing video inspector from canvas tap")
            isInspectorVisible = false
        }
    }

    private func toggleInspector(tab: VideoInspectorTab? = nil) {
        videoScreenLog.info(
            "Toggling video inspector visible=\(self.isInspectorVisible) requestedTab=\(tab?.rawValue ?? "none")"
        )
        if let tab {
            if isInspectorVisible, selectedInspectorTab == tab {
                isInspectorVisible = false
            } else {
                selectedInspectorTab = tab
                isInspectorVisible = true
            }
            return
        }

        isInspectorVisible.toggle()
    }

}

private struct VideoTitlebarBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .titlebar
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private enum VideoVolumeScrollDelta {
    private static let wheelStep = 5.0
    private static let preciseScale = 0.5
    private static let maximumPreciseStep = 5.0
    private static let minimumPreciseStep = 0.1

    static func adjustment(
        deltaX: Double,
        deltaY: Double,
        hasPreciseScrollingDeltas: Bool
    ) -> Double? {
        guard deltaY.isFinite,
              abs(deltaY) >= 0.01,
              abs(deltaY) >= abs(deltaX) else {
            return nil
        }

        guard hasPreciseScrollingDeltas else {
            return deltaY > 0 ? Self.wheelStep : -Self.wheelStep
        }

        let preciseDelta = deltaY * Self.preciseScale
        guard abs(preciseDelta) >= Self.minimumPreciseStep else { return nil }
        return min(max(preciseDelta, -Self.maximumPreciseStep), Self.maximumPreciseStep)
    }
}

private struct VideoSurfaceScrollBridge: NSViewRepresentable {
    let isEnabled: Bool
    let excludedRects: [CGRect]
    var onScroll: (Double) -> Void

    func makeNSView(context: Context) -> VideoSurfaceScrollMonitorView {
        let view = VideoSurfaceScrollMonitorView()
        view.isEnabled = isEnabled
        view.excludedRects = excludedRects
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: VideoSurfaceScrollMonitorView, context: Context) {
        view.isEnabled = isEnabled
        view.excludedRects = excludedRects
        view.onScroll = onScroll
    }
}

private final class VideoSurfaceScrollMonitorView: NSView {
    var isEnabled = false
    var excludedRects: [CGRect] = []
    var onScroll: ((Double) -> Void)?

    nonisolated(unsafe) private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resetScrollMonitor()
    }

    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
    }

    private func resetScrollMonitor() {
        removeScrollMonitor()
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            guard let delta = self.scrollDelta(for: event) else { return event }
            self.onScroll?(delta)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func scrollDelta(for event: NSEvent) -> Double? {
        guard isEnabled,
              let window,
              event.window === window else {
            return nil
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint) else { return nil }
        if excludedRects.contains(where: { $0.contains(localPoint) }) {
            return nil
        }
        return VideoVolumeScrollDelta.adjustment(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
        )
    }
}

private struct VideoInspectorOverlayFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

enum SubtitleTrackExtractionOutcome: Sendable {
    case success(PreparedSubtitleLoad)
    case failure(String)
    case cancelled
}

enum VideoFileImportKind {
    case video
    case primarySubtitle

    func allowedContentTypes(
        mediaTypes: [UTType],
        subtitleTypes: [UTType]
    ) -> [UTType] {
        switch self {
        case .video:
            mediaTypes
        case .primarySubtitle:
            subtitleTypes
        }
    }
}

enum VideoMiningHistoryNotice: String, Identifiable {
    case saved
    case copied
    case noSubtitle
    case disabled

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .saved:
            "Saved to Mining History"
        case .copied:
            "Subtitle Copied"
        case .noSubtitle:
            "No subtitle is active at the current time."
        case .disabled:
            "Mining History is disabled in Video Settings."
        }
    }

    var systemImage: String {
        switch self {
        case .saved, .copied:
            "checkmark.circle.fill"
        case .noSubtitle, .disabled:
            "exclamationmark.triangle.fill"
        }
    }
}
