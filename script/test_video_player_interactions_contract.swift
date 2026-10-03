import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

func maybeSource(_ path: String) -> String? {
    try? source(path)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func sourceBlock(
    _ source: String,
    from startMarker: String,
    to endMarker: String
) -> String {
    guard let start = source.range(of: startMarker),
          let end = source.range(
              of: endMarker,
              range: start.upperBound..<source.endIndex
          ) else {
        return ""
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

let controls = try source("Features/Video/VideoControlsView.swift")
let subtitles = try source("Features/Video/Subtitles/SubtitleOverlayView.swift")
let screen = try source("Features/Video/VideoPlayerScreen.swift")
    + source("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + source("Features/Video/VideoPlayerScreen+Chrome.swift")
    + source("Features/Video/VideoPlayerScreen+OSD.swift")
    + source("Features/Video/VideoPlayerScreen+Mining.swift")
    + source("Features/Video/VideoPlayerScreen+Opening.swift")
    + source("Features/Video/VideoPlayerScreen+Shortcuts.swift")
let lookupCoordinator = try source("Features/Video/VideoLookupCoordinator.swift")
let playbackEngine = try source("Features/Video/Playback/PlaybackEngine.swift")
    + source("Features/Video/Playback/VideoTrack.swift")
let mpvEngine = try source("Features/Video/Playback/MpvPlayerEngine.swift")
let clientHeader = try source("Features/Video/Playback/HSMpvClient.h")
let clientImplementation = try source("Features/Video/Playback/HSMpvClient.mm")
let thumbnailStore = maybeSource("Features/Video/VideoThumbnailStore.swift")
let subtitlePositionLayout = maybeSource(
    "Features/Video/Subtitles/SubtitleVerticalPositionLayout.swift"
)

require(
    screen.contains(".onChange(of: windowChrome.isWindowGeometryTransitioning)")
        && screen.contains("playbackChromeAutoHideTask?.cancel()")
        && screen.contains("transaction.disablesAnimations = true")
        && screen.contains("guard !windowChrome.isWindowGeometryTransitioning else { return }")
        && screen.contains("!windowChrome.isWindowGeometryTransitioning,"),
    "window resize and fullscreen transitions should suspend playback-chrome auto-hide animations"
)

let floatingControls = sourceBlock(
    controls,
    from: "var floatingControls: some View",
    to: "var compactBottomControls: some View"
)
let compactBottomControls = sourceBlock(
    controls,
    from: "var compactBottomControls: some View",
    to: "var compactBottomScrim: some View"
)
let condensedControlGroup = sourceBlock(
    controls,
    from: "var condensedControlGroup: some View",
    to: "var minimalControlGroup: some View"
)
let minimalControlGroup = sourceBlock(
    controls,
    from: "var minimalControlGroup: some View",
    to: "var utilityControlGroup: some View"
)

require(
    playbackEngine.contains("struct VideoRenderGeometry: Equatable")
        && playbackEngine.contains("var videoRenderGeometry: VideoRenderGeometry?")
        && clientHeader.contains("HSMpvVideoGeometryHandler")
        && clientHeader.contains("videoGeometryHandler")
        && clientImplementation.contains("\"osd-dimensions\"")
        && clientImplementation.contains("HSMpvMapValue(osdDimensions, \"mt\")")
        && clientImplementation.contains("HSMpvMapValue(osdDimensions, \"mb\")")
        && clientImplementation.contains("HSMpvMapValue(osdDimensions, \"ml\")")
        && clientImplementation.contains("HSMpvMapValue(osdDimensions, \"mr\")")
        && mpvEngine.contains("client?.videoGeometryHandler")
        && screen.contains("renderGeometry: model.snapshot.videoRenderGeometry"),
    "interactive subtitles should use mpv OSD-to-video margins as the primary fitted-video viewport"
)

require(
    screen.contains("loadPrimarySubtitle(from: subtitleURL, loadIntoMpv: true)")
        && screen.contains("VideoSubtitleRenderingPolicy.initialMode(forSubtitleURL: url)")
        && playbackEngine.contains("case preparingASS")
        && screen.contains("applyPreparedSubtitleRendering(logicalTrackID: logicalTrackID)"),
    "automatically matched ASS sidecars should stay hidden during preparation and atomically reveal their final render plan"
)

require(
    screen.contains("""
        if track.isSelected && areSubtitlesVisible && subtitles.document?.format == .embedded {
            synchronizeSelectedSubtitleTrack()
        } else {
            areSubtitlesVisible = true
""")
        && screen.contains("""
            subtitles.clearPrimary()
            model.selectTrack(type: .subtitle, id: trackID)
        }
"""),
    "reselecting the active subtitle track should preserve its interactive transcript"
)

require(
    subtitles.contains("let isPlaybackPaused: Bool")
        && subtitles.contains("isHovering || isLookupPopupVisible || isPlaybackPaused")
        && screen.contains("isPlaybackPaused: !model.snapshot.isPlaying"),
    "video subtitle masks should reveal while playback is paused"
)

require(
    !controls.contains("VideoVolumeScrollBridge")
        && screen.contains("VideoSurfaceScrollBridge(")
        && screen.contains("isEnabled: shouldHandleVideoSurfaceVolumeScroll")
        && screen.contains("onScroll: { delta in")
        && screen.contains("adjustVolume(by: delta)")
        && screen.contains("var shouldHandleVideoSurfaceVolumeScroll: Bool")
        && screen.contains("model.currentURL != nil")
        && screen.contains("!hasActiveVideoPopup")
        && !screen.contains("&& !isInspectorVisible")
        && !screen.contains("&& !isMiningHistoryVisible")
        && screen.contains("NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)")
        && screen.contains("excludedRects: videoSurfaceVolumeScrollExcludedRects(in: geometry.size)")
        && screen.contains("VideoInspectorOverlayFramePreferenceKey")
        && screen.contains("inspectorOverlayFrame")
        && screen.contains("excludedRects.contains(where: { $0.contains(localPoint) })")
        && !screen.contains("excludedRects.contains { $0.contains(localPoint) }")
        && screen.contains("VideoVolumeScrollDelta.adjustment(")
        && screen.contains("event.hasPreciseScrollingDeltas")
        && screen.contains(".allowsHitTesting(false)"),
    "video surface should support mouse wheel and precise touchpad volume scrolling while study sidebar or inspector are open without stealing inspector scroll"
)

require(
    screen.contains("hasPreciseScrollingDeltas: Bool")
        && screen.contains("return deltaY > 0 ? Self.wheelStep : -Self.wheelStep")
        && screen.contains("let preciseDelta = deltaY * Self.preciseScale"),
    "video surface volume scroll normalization should use notched steps for mouse wheels and smooth deltas for touchpads"
)

require(
    !controls.contains("NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)"),
    "video controls should not own the wheel monitor because scrolling over the video surface drives volume"
)

require(
    playbackEngine.contains("struct VideoTimelinePreview: Equatable")
        && thumbnailStore?.contains("actor VideoThumbnailScheduler") == true
        && !playbackEngine.contains("captureTimelinePreviewPNGData(at time: TimeInterval")
        && !mpvEngine.contains("func captureTimelinePreviewPNGData("),
    "video timeline preview should keep time-only hover previews while library thumbnails remain isolated in VideoThumbnailScheduler"
)

require(
    controls.contains("VideoTimelineChapterMarkers(")
        && controls.contains("chapters: snapshot.chapters")
        && controls.contains("duration: snapshot.duration")
        && controls.contains("guard duration.isFinite, duration > 0 else")
        && controls.contains("chapter.startTime.isFinite")
        && controls.contains("chapter.startTime > 0")
        && controls.contains("chapter.startTime < duration")
        && controls.contains(".allowsHitTesting(false)")
        && controls.contains(".accessibilityHidden(true)"),
    "video timeline should render non-interactive chapter-start markers while rejecting invalid boundary times"
)

require(
    controls.contains("let timelinePreview: VideoTimelinePreview?")
        && controls.contains("var onTimelinePreviewTimeChanged: (TimeInterval?) -> Void")
        && controls.contains("let layout: VideoControlBarLayout")
        && controls.contains("let availableWidth: CGFloat")
        && controls.contains("static func metrics(for layout: VideoControlBarLayout) -> VideoControlsMetrics")
        && controls.contains("compactBottomControls")
        && controls.contains("floatingControls")
        && controls.contains("compactBottomScrim")
        && controls.contains("activeChromeWidth")
        && controls.contains("static let floatingControlsWidth: CGFloat = 760")
        && controls.contains("static let floatingControlsHeight: CGFloat = 90")
        && controls.contains("static let floatingProgressHorizontalInset: CGFloat = 54")
        && controls.contains("static let compactProgressHorizontalInset: CGFloat = 0")
        && controls.contains("bottomInset: 0")
        && controls.contains(".frame(width: activeChromeWidth, height: Self.metrics(for: .compactBottom).chromeSize.height, alignment: .bottom)")
        && controls.contains("var controlTreatment: VideoControlTreatment")
        && controls.contains("VideoGlassIconButtonStyle(treatment: controlTreatment)")
        && controls.contains("VideoSpeedControlButtonStyle(treatment: controlTreatment, isActive: isSpeedPanelVisible)")
        && controls.contains("VideoPlaybackButtonStyle(treatment: controlTreatment)")
        && !controls.contains("VideoProfileMenuTint")
        && !controls.contains("private var profileMenu")
        && !controls.contains("Image(systemName: \"person.crop.circle\")")
        && controls.contains(".foregroundStyle(compactControlForeground)")
        && !controls.contains(".padding(.bottom, 4)")
        && controls.contains(".padding(.bottom, 12)\n        .frame(width: activeChromeWidth, height: Self.metrics(for: .compactBottom).chromeSize.height, alignment: .bottom)")
        && !controls.contains("VideoCompactControlSurface")
        && controls.contains("timelineProgressControl")
        && controls.contains(".padding(.horizontal, Self.compactProgressHorizontalInset)")
        && controls.contains("VideoProgressHoverBridge(")
        && controls.contains("timelinePreviewBubble")
        && controls.contains("VideoProgressFramePreferenceKey")
        && controls.contains(".zIndex(20)")
        && controls.contains("onTimelinePreviewTimeChanged(time)")
        && controls.contains("Text(VideoTimeFormatter.string(from: preview.time))")
        && !controls.contains("timelinePreviewImage")
        && !controls.contains("previewImage(from:")
        && !controls.contains("NSImage(data:")
        && !controls.contains("Image(systemName: \"photo\")"),
    "video controls should keep the time preview without rendering frame thumbnail placeholders when previews are disabled"
)

require(
    controls.contains("static func chromeSize(")
        && controls.contains("for layout: VideoControlBarLayout")
        && controls.contains("availableWidth: CGFloat")
        && controls.contains("width: min(floatingControlsWidth, max(availableWidth - 32, 1))")
        && controls.contains("return CGSize(width: availableWidth, height: defaultSize.height)")
        && controls.contains("Self.chromeSize(for: layout, availableWidth: availableWidth).width")
        && screen.contains("func playbackChromeSize(in size: CGSize) -> CGSize")
        && screen.contains("VideoControlsView.chromeSize(")
        && screen.contains("availableWidth: size.width")
        && !controls.contains("max(availableWidth, Self.controlsWidth)")
        && !screen.contains("max(size.width, videoControlsMetrics.chromeSize.width)"),
    "Floating and Compact Bottom should share one available-width resolver with PlayerScreen instead of forcing their old 690/760-point widths"
)

require(
    controls.contains("enum ControlDensity")
        && controls.contains("case full")
        && controls.contains("case condensed")
        && controls.contains("case minimal")
        && controls.contains("var controlDensity: ControlDensity")
        && controls.contains("if activeChromeWidth >= 390")
        && controls.contains("return .condensed")
        && controls.contains("return .minimal")
        && controls.contains("responsivePrimaryControlGroup")
        && controls.contains("responsiveCompactControlGroup")
        && !floatingControls.isEmpty
        && floatingControls.contains("responsivePrimaryControlGroup")
        && floatingControls.contains("progressControlStrip")
        && !compactBottomControls.isEmpty
        && compactBottomControls.contains("timelineProgressControl")
        && compactBottomControls.contains("responsiveCompactControlGroup"),
    "both OSC layouts should select full, condensed, or minimal controls while keeping a seekable timeline at narrow widths"
)

require(
    !condensedControlGroup.isEmpty
        && condensedControlGroup.contains("episodeControls")
        && condensedControlGroup.contains("speedControlButton")
        && condensedControlGroup.contains("openVideoButton")
        && condensedControlGroup.contains("inspectorButton")
        && condensedControlGroup.contains("fullScreenButton")
        && !condensedControlGroup.contains("volumeControl")
        && !condensedControlGroup.contains("utilityControlGroup")
        && !condensedControlGroup.contains("subtitleGapFastForwardButton")
        && !condensedControlGroup.contains("miningHistoryButton")
        && !condensedControlGroup.contains("mineCurrentSubtitleButton"),
    "condensed OSC should preserve playback, speed, open, inspector, and fullscreen while dropping width-heavy volume and secondary utilities"
)

require(
    !minimalControlGroup.isEmpty
        && minimalControlGroup.contains("episodeControls")
        && minimalControlGroup.contains("fullScreenButton")
        && !minimalControlGroup.contains("volumeControl")
        && !minimalControlGroup.contains("speedControlButton")
        && !minimalControlGroup.contains("utilityControlGroup")
        && !minimalControlGroup.contains("openVideoButton")
        && !minimalControlGroup.contains("inspectorButton")
        && !minimalControlGroup.contains("mineCurrentSubtitleButton"),
    "minimal OSC should retain only previous/play/next and fullscreen instead of overflowing the 285-point window"
)

require(
    controls.contains(".onChange(of: controlDensity)")
        && controls.contains("guard density == .minimal, isSpeedPanelVisible else { return }")
        && controls.contains("isSpeedPanelVisible = false"),
    "entering minimal density should close a speed panel whose trigger is no longer visible"
)

require(
    screen.contains("VideoControlsView.metrics(for: userConfig.videoControlBarLayout)")
        && screen.contains("layout: userConfig.videoControlBarLayout")
        && screen.contains("isSubtitleGapFastForwardEnabled: userConfig.videoSubtitleGapFastForwardEnabled")
        && screen.contains("onToggleSubtitleGapFastForward: {")
        && screen.contains("availableWidth: geometry.size.width")
        && screen.contains("playbackChromeSize(in: size)")
        && screen.contains("playbackChromeBottomEdgeInset")
        && screen.contains("bottomInset: videoControlsMetrics.popupBottomInset")
        && screen.contains("var videoControlsMetrics: VideoControlsMetrics"),
    "video screen should keep playback chrome and popup placement layout-aware"
)

require(
    subtitles.contains("SubtitleVerticalPositionLayout(position: verticalPosition)")
        && subtitles.contains("VStack(spacing: 8)")
        && subtitles.contains("SubtitleOverlayRowHeightMeasurer.height(")
        && !subtitles.contains("bottomClearance")
        && !subtitles.contains("verticalPositionOffset")
        && !subtitles.contains(".padding(.bottom")
        && !screen.contains("bottomClearance: videoControlsMetrics.subtitleBottomClearance")
        && !controls.contains("subtitleBottomClearance")
        && subtitlePositionLayout?.contains(
            "struct SubtitleVerticalPositionLayout: Layout"
        ) == true
        && subtitlePositionLayout?.contains(
            "VideoSubtitlePositionPolicy.originY("
        ) == true
        && subtitlePositionLayout?.contains("anchor: .topLeading") == true,
    "video subtitles should use measured relative placement without control-bar clearance"
)

require(
    screen.contains("let subtitleViewport = VideoWindowAspectLayout.videoViewport(")
        && screen.contains("in: geometry.size")
        && screen.contains("aspectRatio: videoWindowAspectRatio")
        && screen.contains("width: subtitleViewport.width")
        && screen.contains("height: subtitleViewport.height")
        && screen.contains("x: subtitleViewport.midX")
        && screen.contains("y: subtitleViewport.midY")
        && subtitles.contains("geometry.frame(in: .named(\"video-player\"))"),
    "video subtitles should be framed inside the effective picture viewport while lookup rectangles remain in player coordinates"
)

require(
    screen.contains("updateSubtitleGapPlayback()")
        && screen.contains("subtitles.slice(")
        && screen.contains("model.updateSubtitleGapPlayback(")
        && screen.contains(".onChange(of: userConfig.videoSubtitleGapFastForwardEnabled)")
        && screen.contains(".onChange(of: userConfig.videoSubtitleGapFastForwardSpeed)")
        && screen.contains("model.setSubtitleGapFastForwardSpeed(userConfig.videoSubtitleGapFastForwardSpeed)")
        && screen.contains("VideoShortcutActions.toggleSubtitleGapFastForward.id"),
    "video player should drive subtitle gap fast-forward from subtitle timing, settings, and shortcuts"
)

require(
    screen.contains("var timelinePreview: VideoTimelinePreview?")
        && screen.contains("timelinePreview: timelinePreview")
        && screen.contains("onTimelinePreviewTimeChanged: { time in")
        && screen.contains("updateTimelinePreview(at: time)")
        && !screen.contains("startTimelinePreviewPrewarmIfAvailable()")
        && !screen.contains("timelinePreviewPrewarmTask")
        && !screen.contains("timelinePreviewDemandTask")
        && !screen.contains("model.engine.captureTimelinePreviewPNGData")
        && screen.contains("clearTimelinePreview(clearCache: true)"),
    "video screen should avoid CPU-heavy thumbnail generation during normal playback"
)

require(
    screen.contains("suspendVideoThumbnailsForVideoSession()")
        && screen.contains("resumeVideoThumbnailsForVideoSession()")
        && screen.contains("await VideoThumbnailScheduler.shared.suspend(reason: .playback)")
        && screen.contains("await VideoThumbnailScheduler.shared.resume(reason: .playback)")
        && screen.contains("if newURL != nil {")
        && screen.contains(".onDisappear {")
        && !screen.contains("if isPlaying {\n                    suspendVideoThumbnailsFor")
        && !screen.contains("if !model.snapshot.isPlaying {\n                    resumeVideoThumbnailsFor"),
    "video sessions should suspend library thumbnail generation from media open until the player closes, independent of pause/play state"
)

require(
    lookupCoordinator.contains("suspendVideoThumbnailsForLookupIfNeeded()")
        && lookupCoordinator.contains("resumeVideoThumbnailsForLookupIfNeeded()")
        && lookupCoordinator.contains("await VideoThumbnailScheduler.shared.suspend(reason: .lookup)")
        && lookupCoordinator.contains("await VideoThumbnailScheduler.shared.resume(reason: .lookup)")
        && lookupCoordinator.contains("guard self.presentation.popups.isEmpty else")
        && lookupCoordinator.contains("resumePlaybackAfterPopupIfNeeded(player: player)"),
    "video lookup popups should preemptively suspend library thumbnails until the popup stack closes"
)

require(
    lookupCoordinator.contains("if userConfig.videoAutoPauseOnLookup {")
        && lookupCoordinator.contains("shouldResumePlayback = player.snapshot.isPlaying")
        && lookupCoordinator.contains("if shouldResumePlayback {")
        && lookupCoordinator.contains("player.engine.pause()"),
    "video lookup popups should pause playback only when the Video lookup auto-pause setting is enabled"
)

print("Video player interaction contract tests passed")
