import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func requireOrdered(_ source: String, _ snippets: [String], _ message: String) {
    var lowerBound = source.startIndex
    for snippet in snippets {
        guard let range = source.range(of: snippet, range: lowerBound..<source.endIndex) else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        lowerBound = range.upperBound
    }
}

func countOccurrences(_ source: String, of needle: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var lowerBound = source.startIndex
    while let range = source.range(of: needle, range: lowerBound..<source.endIndex) {
        count += 1
        lowerBound = range.upperBound
    }
    return count
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
let interactiveSubtitles = try source("Features/Video/Subtitles/InteractiveSubtitleTextView.swift")
let subtitleController = try source("Features/Video/Subtitles/VideoSubtitleController.swift")
let transcriptView = try source("Features/Video/Subtitles/SubtitleTranscriptView.swift")
let subtitleModel = try source("Models/Subtitle.swift")
let inspector = try source("Features/Video/VideoInspectorView.swift")
let inspectorState = try source("Features/Video/VideoInspectorState.swift")
let miningHistorySidebar = try source("Features/Video/VideoMiningHistorySidebar.swift")
let studyListCard = (try? source("Features/Video/VideoStudyListCard.swift")) ?? ""
let ambientBackdrop = (try? source("Features/Video/VideoAmbientBackdrop.swift")) ?? ""
let ambientModel = (try? source("Features/Video/VideoAmbientBackdropModel.swift")) ?? ""
let mpvClient = try source("Features/Video/Playback/HSMpvClient.mm")
let playbackEngine = try source("Features/Video/Playback/PlaybackEngine.swift")
    + source("Features/Video/Playback/VideoTrack.swift")
let playerViewModel = try source("Features/Video/VideoPlayerViewModel.swift")
let windowChrome = (try? source("Features/Video/VideoWindowChromeController.swift")) ?? ""
let videoMediaTypes = try source("Features/Video/VideoMediaTypes.swift")
let screen = try source("Features/Video/VideoPlayerScreen.swift")
    + source("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + source("Features/Video/VideoPlayerScreen+Chrome.swift")
    + source("Features/Video/VideoPlayerScreen+OSD.swift")
    + source("Features/Video/VideoPlayerScreen+Mining.swift")
    + source("Features/Video/VideoPlayerScreen+Opening.swift")
    + source("Features/Video/VideoPlayerScreen+Shortcuts.swift")
let lookup = try source("Features/Video/VideoLookupCoordinator.swift")
let popupPresentation = try source("Features/Popup/PopupPresentationCoordinator.swift")
let popup = try source("Features/Popup/PopupView.swift")
let rootView = try source("NativeMac/NativeMacRootView.swift")
let detailView = try source("NativeMac/NativeMacDetailView.swift")
let app = try source("NativeMac/HoshiNativeMacApp.swift")
let presenter = try source("NativeMac/VideoWindowPresenter.swift")
let profilesView = try source("Features/Settings/ProfilesView.swift")
let profileCoordinator = (try? source("Core/ProfileActivationCoordinator.swift")) ?? ""
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
let subtitleTimingSection = sourceBlock(
    inspector,
    from: "var subtitleTimingSection: some View",
    to: "func trackSection("
)
let videoCanvas = sourceBlock(
    screen,
    from: "var videoCanvas: some View",
    to: "var videoWindowDragStrip: some View"
)
let videoWindowDragStrip = sourceBlock(
    screen,
    from: "var videoWindowDragStrip: some View",
    to: "var videoControlsMetrics: VideoControlsMetrics"
)

require(
    controls.contains("primaryControlGroup")
        && controls.contains("progressControlStrip")
        && controls.contains("onToggleInspector")
        && !controls.contains("moreControlsMenu"),
    "video controls should use a compact IINA-like OSC with a dedicated inspector toggle"
)
require(
    controls.contains("static let floatingControlsWidth: CGFloat = 760")
        && controls.contains("static let floatingControlsHeight: CGFloat = 90")
        && controls.contains("static let floatingCornerRadius: CGFloat = 24")
        && controls.contains("static let floatingIconSize: CGFloat = 30")
        && controls.contains("static let floatingPlaybackButtonSize: CGFloat = 42")
        && controls.contains(".frame(width: activeChromeWidth, height: Self.floatingControlsHeight)")
        && controls.contains("static let compactProgressHorizontalInset: CGFloat = 0")
        && countOccurrences(controls, of: ".frame(maxWidth: .infinity)\n                .frame(height: Self.timelineHitHeight)") >= 2
        && controls.contains(".padding(.horizontal, Self.floatingHorizontalPadding)")
        && !controls.contains(".frame(maxWidth: 960)"),
    "video controls should be a timeline-first two-row panel that contracts with the video window"
)
if let floatingRange = controls.range(of: "private var floatingControls: some View"),
   let floatingEnd = controls[floatingRange.lowerBound...].range(of: "private var compactBottomControls: some View")?.lowerBound {
    let floating = controls[floatingRange.lowerBound..<floatingEnd]
    let progressIndex = floating.range(of: "progressControlStrip")?.lowerBound
    let controlsIndex = floating.range(of: "responsivePrimaryControlGroup")?.lowerBound
    require(
        progressIndex != nil && controlsIndex != nil && progressIndex! < controlsIndex!,
        "the floating panel should put the timeline above the button row"
    )
} else {
    require(false, "floating controls should be present before the compact bottom layout")
}
require(
    controls.contains("private struct VideoTimelineTrack: View")
        && controls.contains("isEmphasized: isProgressHovering || isScrubbing")
        && controls.contains("DragGesture(minimumDistance: 0)")
        && controls.contains("private func scrub(toX x: CGFloat, width: CGFloat)")
        && controls.contains("private func endScrubbing()")
        && controls.contains("onSeek(scrubTime)")
        && controls.contains(".accessibilityRepresentation {")
        && controls.contains("private struct VideoVolumeTrack: View")
        && controls.contains("restingHeight: 3"),
    "timeline and volume should be custom tracks that thicken on hover, seek on release, and stay accessible as sliders"
)
require(
    controls.contains("var isMiningHistoryVisible = false")
        && controls.contains("var isInspectorVisible = false")
        && controls.contains("isActive: isMiningHistoryVisible")
        && controls.contains("isActive: isInspectorVisible")
        && controls.contains("isActive: isSubtitleGapFastForwardEnabled")
        && screen.contains("isMiningHistoryVisible: isMiningHistoryVisible,")
        && screen.contains("isInspectorVisible: isInspectorVisible,"),
    "toggle buttons should show when their panel or mode is on"
)
require(
    screen.contains("private var inspectorOverlayBottomInset: CGFloat")
        && screen.contains("videoControlsMetrics.controlHeight + Self.inspectorOverlayVerticalInset / 2")
        && screen.contains("+ videoControlsMetrics.bottomInset\n                + videoControlsMetrics.controlHeight")
        && screen.contains(".padding(.bottom, inspectorOverlayBottomInset)"),
    "the inspector should end above the playback controls in both layouts instead of covering their tools"
)
require(
    controls.contains("static func chromeSize(")
        && controls.contains("availableWidth: CGFloat")
        && controls.contains("width: min(floatingControlsWidth, max(availableWidth - 32, 1))")
        && controls.contains("return CGSize(width: availableWidth, height: defaultSize.height)")
        && controls.contains("Self.chromeSize(for: layout, availableWidth: availableWidth).width")
        && screen.contains("VideoControlsView.chromeSize(")
        && screen.contains("availableWidth: size.width")
        && controls.contains("activeChromeWidth - horizontalPadding - Self.floatingProgressHorizontalInset * 2")
        && controls.contains("let trailingLimit = max(activeChromeWidth - halfWidth, halfWidth)")
        && !controls.contains("max(availableWidth, Self.controlsWidth)")
        && !screen.contains("max(size.width, videoControlsMetrics.chromeSize.width)"),
    "rendered OSC width, fallback seek geometry, popup placement, and PlayerScreen hit geometry should resolve from the same available width"
)
require(
    controls.contains("enum ControlDensity")
        && controls.contains("case full")
        && controls.contains("case condensed")
        && controls.contains("case minimal")
        && controls.contains("responsivePrimaryControlGroup")
        && controls.contains("responsiveCompactControlGroup")
        && !condensedControlGroup.isEmpty
        && condensedControlGroup.contains("episodeControls")
        && condensedControlGroup.contains("speedControlButton")
        && condensedControlGroup.contains("openVideoButton")
        && condensedControlGroup.contains("inspectorButton")
        && condensedControlGroup.contains("fullScreenButton")
        && !condensedControlGroup.contains("volumeControl")
        && !condensedControlGroup.contains("utilityControlGroup")
        && !minimalControlGroup.isEmpty
        && minimalControlGroup.contains("episodeControls")
        && minimalControlGroup.contains("fullScreenButton")
        && !minimalControlGroup.contains("speedControlButton")
        && !minimalControlGroup.contains("openVideoButton")
        && !minimalControlGroup.contains("inspectorButton")
        && controls.contains(".onChange(of: controlDensity)")
        && controls.contains("guard density == .minimal, isSpeedPanelVisible else { return }")
        && controls.contains("isSpeedPanelVisible = false"),
    "narrow Floating and Compact Bottom layouts should use condensed/minimal control combinations and dismiss an orphaned speed panel"
)
require(
    !controls.contains("let profiles: [HoshiProfile]")
        && !controls.contains("let selectedProfileID: String")
        && !controls.contains("var onSelectProfile: (String) -> Void")
        && !controls.contains("private var profileMenu: some View")
        && !controls.contains("Image(systemName: \"person.crop.circle\")")
        && !controls.contains("VideoProfileMenuTint"),
    "video playback controls should not expose a window-local Profile selector"
)
requireOrdered(
    controls,
    [
        "volumeControl",
        "Spacer(minLength: 0)",
        "episodeControls",
        "Spacer(minLength: 0)",
        "speedControlButton",
        "utilityControlGroup",
    ],
    "video utility controls should sit on the right side after playback controls"
)
requireOrdered(
    controls,
    [
        "var utilityControlGroup",
        "miningHistoryButton",
        "openVideoButton",
        "mineCurrentSubtitleButton",
        "inspectorButton",
        "fullScreenButton",
    ],
    "video utility control group should preserve the right-side action order"
)
require(
    controls.contains("var onSetSpeed: (Double) -> Void")
        && controls.contains("@Binding var isSpeedPanelVisible: Bool")
        && !controls.contains("@State private var isSpeedPanelVisible = false")
        && screen.contains("var isSpeedPanelVisible = false")
        && screen.contains("isSpeedPanelVisible: $isSpeedPanelVisible")
        && controls.contains("var speedInputText = \"\"")
        && controls.contains("var speedControlButton: some View")
        && controls.contains("var speedControlPanel: some View")
        && controls.contains("Label(\"Playback Speed\", systemImage: \"speedometer\")")
        && controls.contains("VideoPlaybackSpeed.label(snapshot.speed)")
        && controls.contains("VideoPlaybackSpeed.presetChoices")
        && controls.contains("Slider(")
        && controls.contains("VideoPlaybackSpeed.customInputLowerBound...VideoPlaybackSpeed.maximum")
        && controls.contains("TextField(\"Custom\", text: $speedInputText)")
        && controls.contains("commitSpeedInput()")
        && screen.contains("onSetSpeed: { speed in"),
    "video bottom controls should expose playback speed through a floating panel with presets, slider, and numeric input"
)
require(
    screen.contains("var shouldShowVideoDismissLayer: Bool")
        && screen.contains("hasActiveVideoPopup || isInspectorVisible || isSpeedPanelVisible")
        && screen.contains("isSpeedPanelVisible = false")
        && screen.contains("|| isSpeedPanelVisible"),
    "a canvas click should dismiss the speed panel while the panel keeps playback chrome visible"
)
require(
    !controls.contains(".glassEffect(.regular.interactive(), in: Circle())")
        && controls.contains("struct VideoPlaybackButtonStyle")
        && controls.contains("treatment.iconPressedFill(isPressed: configuration.isPressed)"),
    "the play button should use pressed feedback without a glass circle"
)
require(
    controls.contains("struct VideoSpeedControlButtonStyle")
        && !controls.contains("func speedFill(isSelected:")
        && !controls.contains("func speedStrokeOpacity(isSelected:"),
    "the speed button should not draw a persistent fill or stroke"
)
require(
    screen.contains("layout: userConfig.videoControlBarLayout")
        && screen.contains("var videoControlsMetrics: VideoControlsMetrics")
        && !screen.contains("profiles: profileRepository.index.profiles")
        && !screen.contains("selectedProfileID:")
        && !screen.contains("onSelectProfile:")
        && !screen.contains("selectVideoProfile("),
    "video screen should keep playback drag bounds aligned without wiring a Profile selector"
)
require(
    screen.contains("final class VideoPlayerModelStore: ObservableObject")
        && screen.contains("let model = VideoPlayerViewModel(engine: MpvPlayerEngine())")
        && screen.contains("var modelStore = VideoPlayerModelStore()")
        && screen.contains("var model: VideoPlayerViewModel")
        && screen.contains("modelStore.model")
        && !screen.contains("@State private var model")
        && !screen.contains("State(initialValue: VideoPlayerViewModel(engine: MpvPlayerEngine()))")
        && !screen.contains("@State private var model = VideoPlayerViewModel(engine: MpvPlayerEngine())"),
    "video screen should own the mpv-backed player model through StateObject storage so SwiftUI view reinitialization does not allocate extra mpv clients"
)
require(
    controls.contains("let canMineCurrentSubtitle: Bool")
        && controls.contains("var onMineCurrentSubtitle: () -> Void")
        && controls.contains("Label(\"Mine Current Subtitle\", systemImage: \"tray.and.arrow.down\")")
        && controls.contains(".disabled(!canMineCurrentSubtitle)"),
    "video controls should expose an asbplayer-style mine-current-subtitle action"
)
require(
    controls.contains("var onToggleMiningHistory: () -> Void")
        && controls.contains("var onOpenVideo: () -> Void")
        && controls.contains("Label(\"Mining History\", systemImage: \"clock.arrow.circlepath\")")
        && controls.contains("Label(\"Open Video\", systemImage: \"film\")")
        && screen.contains("onToggleMiningHistory: {")
        && screen.contains("onOpenVideo: {")
        && !screen.contains("private var videoTopControls")
        && !screen.contains("VideoTopGlassButtonStyle"),
    "layout A should integrate history and open-video actions into one widened bottom control bar"
)
require(
    controls.contains("var onDragChanged: (CGSize) -> Void")
        && controls.contains("var onDragEnded: (CGSize) -> Void")
        && controls.contains("var controlDragSurface: some View")
        && controls.contains("DragGesture(minimumDistance: 2, coordinateSpace: .global)")
        && controls.contains("Color.black.opacity(0.001)")
        && controls.contains(".contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))"),
    "video controls should use an IINA-like stable global drag coordinate space instead of moving local coordinates"
)
require(
    controls.contains(".background {\n            controlDragSurface")
        && !controls.contains("ZStack {\n            controlDragSurface"),
    "video control drag surface should follow the compact control content size instead of expanding to the player height"
)
require(
    screen.contains("switch userConfig.videoControlBarLayout")
        && screen.contains("case .compactBottom:\n            .zero")
        && screen.contains("case .floating:\n            clampedPlaybackChromeOffset("),
    "Compact Bottom should ignore draggable playback chrome offsets while Floating remains clamped"
)
require(
    screen.contains("if layout == .compactBottom {")
        && screen.contains("playbackChromeStoredOffset = .zero")
        && screen.contains("playbackChromeDragOffset = .zero"),
    "switching to Compact Bottom should clear stale Floating drag offsets"
)
require(
    controls.contains("VideoFloatingGlassSurface(cornerRadius: Self.floatingCornerRadius)")
        && controls.contains(".glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))"),
    "video controls should use a single Liquid Glass panel"
)
require(
    !controls.contains("Material"),
    "video controls should use Liquid Glass without a pre-macOS 26 material fallback"
)
require(
    !controls.contains("autoHide")
        && !controls.contains("controlVisibility"),
    "video controls should remain fixed in this phase and not add auto-hide behavior"
)
require(
    !subtitles.contains(".glassEffect(")
        && subtitles.contains("let backgroundDisabled: Bool")
        && subtitles.contains("!backgroundDisabled && normalizedBackgroundOpacity > 0")
        && !subtitles.contains("VideoSubtitleGlassSurface"),
    "subtitle overlay should remain transparent by default while allowing the explicit user-controlled background opacity setting"
)
require(
    subtitles.contains("let maskEnabled: Bool")
        && subtitles.contains("let maskMode: VideoSubtitleMaskMode")
        && subtitles.contains("let maskBlurRadius: Double")
        && subtitles.contains("let maskHiddenOpacity: Double")
        && subtitles.contains("let fontFamily: String")
        && subtitles.contains("let fontSize: Double")
        && subtitles.contains("let fontWeight: Int")
        && subtitles.contains("let edgeStyle: VideoSubtitleEdgeStyle")
        && subtitles.contains("let edgeStrength: Double")
        && subtitles.contains("let isLookupPopupVisible: Bool"),
    "subtitle overlay should receive text-only subtitle mask and appearance configuration"
)
require(
    subtitles.contains("VideoSubtitleEdgeRecipe.make(")
        && !subtitles.contains(".shadow(color: shadowColor"),
    "subtitle edges should use a glyph recipe instead of a row-level SwiftUI shadow"
)
require(
    interactiveSubtitles.contains("let edgeRecipe: VideoSubtitleEdgeRecipe")
        && interactiveSubtitles.contains("NSShadow()")
        && interactiveSubtitles.contains("shadow.shadowOffset = .zero")
        && interactiveSubtitles.contains("shadow.shadowColor = NSColor.black")
        && interactiveSubtitles.contains("textStorage.addAttribute(.shadow")
        && interactiveSubtitles.contains(".strokeWidth")
        && interactiveSubtitles.contains(".strokeColor")
        && !interactiveSubtitles.contains("CTFontDrawGlyphs")
        && !interactiveSubtitles.contains("SubtitleEdgeLayoutManager"),
    "interactive subtitles should apply stable zero-offset shadow and outline attributes at the glyph boundary"
)
require(
    !controls.contains("subtitleBottomClearance")
        && subtitles.contains("SubtitleVerticalPositionLayout(position: verticalPosition)")
        && !subtitles.contains("bottomClearance")
        && !subtitles.contains(".padding(.bottom"),
    "subtitle position should be independent of the active playback control surface"
)
require(
    interactiveSubtitles.contains("let fontFamily: String")
        && interactiveSubtitles.contains("let fontSize: Double")
        && interactiveSubtitles.contains("let fontWeight: Int")
        && interactiveSubtitles.contains("func subtitleFont() -> NSFont")
        && interactiveSubtitles.contains(".systemFont(ofSize: size, weight: subtitleFontWeight())")
        && !interactiveSubtitles.contains(".systemFont(ofSize: 20, weight: .medium)"),
    "interactive subtitle text should use configurable asbplayer-style font settings instead of the old hard-coded 20pt font"
)
require(
    subtitles.contains("var isHovering = false")
        && subtitles.contains(".onHover { hovering in")
        && subtitles.contains("var maskedBlurRadius: CGFloat")
        && subtitles.contains("var maskedOpacity: Double")
        && subtitles.contains("var isMaskRevealed: Bool")
        && subtitles.contains("isHovering || isLookupPopupVisible")
        && subtitles.contains(".blur(radius: maskedBlurRadius)")
        && subtitles.contains(".opacity(maskedOpacity)"),
    "subtitle overlay should reveal masked subtitles on hover or while a lookup popup is open using blur or opacity text effects"
)
require(
    subtitleController.contains("Task.detached")
        && subtitleController.contains("loadGeneration")
        && subtitleController.contains("applyPrimarySubtitleLoad")
        && !subtitleController.contains("applySecondarySubtitleLoad")
        && !subtitleController.contains("loadSecondary("),
    "external primary subtitle imports should parse off the main actor and ignore stale load completions without reintroducing secondary subtitle state"
)
require(
    screen.contains("enum VideoFileImportKind")
        && screen.contains("var pendingFileImportKind: VideoFileImportKind?")
        && screen.contains("var activeFileImportKind: VideoFileImportKind?")
        && screen.contains(".fileImporter(")
        && screen.contains("allowedContentTypes: (pendingFileImportKind ?? activeFileImportKind)?.allowedContentTypes(")
        && screen.contains("guard let kind = activeFileImportKind ?? pendingFileImportKind else { return }")
        && screen.contains("handleFileImport(result, kind: kind)")
        && !screen.contains("let panel = NSOpenPanel()")
        && !screen.contains("panel.runModal()"),
    "video inspector imports should use the same state-driven SwiftUI file importer path as the stable top controls path"
)
require(
    screen.contains(".onDrop(of: [.fileURL]")
        && screen.contains("handleDroppedFileURLs(")
        && screen.contains("loadDroppedMedia(")
        && screen.contains("loadDroppedSubtitle(")
        && screen.contains("isMediaFile(")
        && screen.contains("isSubtitleFile(")
        && screen.contains("loadPrimarySubtitle(from: subtitleURL, loadIntoMpv: true)")
        && screen.contains("openVideo(mediaURL, subtitleURL: subtitleURL)")
        && screen.contains("autoloadSubtitleIfAvailable(for: mediaURL)"),
    "video surface should accept dropped media and subtitle files while reusing the primary video/subtitle import paths"
)
require(
    videoMediaTypes.contains("supportedExtensions")
        && videoMediaTypes.contains("\"m4b\"")
        && videoMediaTypes.contains("\"m4a\"")
        && videoMediaTypes.contains("\"mp3\"")
        && videoMediaTypes.contains("\"flac\"")
        && videoMediaTypes.contains("\"opus\"")
        && videoMediaTypes.contains("\"m2ts\""),
    "video imports should expose mpv-oriented media extensions including audio books and audio-only files"
)
require(
    screen.contains("model.loadExternalSubtitle(url)")
        && screen.contains("loadPrimarySubtitle(from: url, loadIntoMpv: true)"),
    "external subtitle imports should be loaded into mpv instead of disabling subtitle tracks during import"
)
require(
    screen.contains("restoreRememberedSubtitleSelectionOrAutoload(for: mediaURL)")
        && screen.contains("VideoSubtitleAutoloadCandidate.bestCandidate(for: mediaURL)")
        && screen.contains("loadPrimarySubtitle(from: subtitleURL, loadIntoMpv: true)")
        && !screen.contains("useSelectedMpvTrackRenderer")
        && screen.contains("loadPrimarySubtitle(from: url, loadIntoMpv: true)"),
    "video import should auto-load same-folder subtitle sidecars through the same primary subtitle path as manual imports"
)
require(
    screen.contains("restoreRememberedSubtitleSelectionOrAutoload")
        && screen.contains(".onChange(of: model.loadGeneration)")
        && screen.contains(".onChange(of: model.snapshot.isLoaded)")
        && screen.contains("VideoSubtitleRestoreResolver.resolve(")
        && screen.contains("model.consumePendingSubtitleSelection()")
        && screen.contains("model.rememberSubtitleSelection("),
    "video should restore and persist the per-file subtitle selection through playback history"
)
require(
    screen.contains("openPlaylistEpisode(url)")
        && screen.contains("func openPlaylistEpisode(_ url: URL)")
        && screen.contains("lookup.closeAll(player: model)")
        && screen.contains("subtitles.clear()")
        && screen.contains("model.selectPlaylistItem(url)"),
    "episode selection should clear stale lookup/subtitle state before restoring the selected episode subtitles"
)
require(
    screen.contains("guard model.errorMessage == nil else")
        && screen.contains("shouldSkipNextAutomaticSubtitleRestore = false"),
    "failed explicit media loads must not leak subtitle-restore suppression into the next video"
)
require(
    !subtitles.contains("secondaryCues")
        && !inspector.contains("Open Secondary Subtitles")
        && !screen.contains("secondarySubtitle")
        && !screen.contains("secondarySubtitleName"),
    "video should keep secondary subtitle UI/state out of the current phase so primary subtitle import and lookup remain stable"
)
require(
    interactiveSubtitles.contains("PassThroughSubtitleScrollView")
        && interactiveSubtitles.contains("containsInteractiveText(at:")
        && interactiveSubtitles.contains("var onHoverChanged: ((Bool) -> Void)?")
        && interactiveSubtitles.contains("NSTrackingArea")
        && interactiveSubtitles.contains("mouseEntered(with event: NSEvent)")
        && interactiveSubtitles.contains("mouseExited(with event: NSEvent)")
        && interactiveSubtitles.contains("return nil"),
    "interactive subtitle views should pass through clicks outside rendered text while still reporting hover for subtitle masks"
)
require(
    interactiveSubtitles.contains("func performLookup(at point: CGPoint)")
        && interactiveSubtitles.contains("override func mouseDown(with event: NSEvent)")
        && interactiveSubtitles.contains("performLookup(at: point)")
        && interactiveSubtitles.contains("scheduleShiftHoverLookup(at: point)"),
    "Video click and Shift-hover lookup must reuse one point-to-character selection path"
)
require(
    interactiveSubtitles.contains("NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)")
        && interactiveSubtitles.contains("return event")
        && interactiveSubtitles.contains("NSEvent.removeMonitor")
        && interactiveSubtitles.contains("override func viewDidMoveToWindow()")
        && interactiveSubtitles.contains("deinit")
        && interactiveSubtitles.contains(".mouseMoved"),
    "Video Shift-hover modifier observation must be non-consuming and bound to the subtitle view lifecycle"
)
require(
    interactiveSubtitles.contains("let hoverLookupDelayMs: Int")
        && subtitles.contains("let hoverLookupDelayMs: Int")
        && screen.contains("hoverLookupDelayMs: userConfig.desktopLookupHoverDelayMs"),
    "Video Shift-hover must use the existing configurable Mac hover delay"
)
require(
    interactiveSubtitles.contains("syncDocumentViewFrame()")
        && interactiveSubtitles.contains("textView.textContainer?.heightTracksTextView = true")
        && interactiveSubtitles.contains("textView.isVerticallyResizable = false")
        && interactiveSubtitles.contains("contentView.scroll(to: .zero)"),
    "interactive subtitle text should pin the AppKit document view to its visible row and avoid first-layout scroll drift"
)
require(
    subtitles.contains("onHoverChanged: { hovering in")
        && subtitles.contains("isHovering = hovering"),
    "subtitle mask rows should receive hover from the AppKit subtitle view instead of relying only on SwiftUI hover"
)
require(
    screen.contains("onTapOutside: {")
        && screen.contains("lookup.presentation.handleTapInsidePopup(id: popupID)")
        && popupPresentation.contains("func handleTapInsidePopup(id: UUID)")
        && popupPresentation.contains("closeChildren(of: id)"),
    "tapping inside a video popup should use shared popup-stack semantics and close only its descendants"
)
require(
    screen.contains("if shouldShowVideoDismissLayer")
        && screen.contains("Color.clear")
        && screen.contains(".contentShape(Rectangle())")
        && screen.contains("dismissVideoOverlaysFromCanvas()")
        && screen.contains(".zIndex(2.5)")
        && screen.contains("var shouldShowVideoDismissLayer: Bool")
        && screen.contains("hasActiveVideoPopup || isInspectorVisible")
        && screen.contains("func dismissVideoPopupsIfNeeded()"),
    "video should install a transparent dismiss layer above subtitles so non-subtitle clicks close active lookup popups or the inspector"
)
require(
    screen.contains("onToggleInspector: {")
        && screen.contains("onToggleFullScreen: {")
        && screen.contains("dismissVideoPopupsThen")
        && !screen.contains(".simultaneousGesture("),
    "video controls and inspector interactions should defer until subtitle lookup popups finish closing without broad inspector tap gestures"
)
require(
    (
        screen.contains(".onTapGesture(count: 2)")
            || screen.contains("TapGesture(count: 2)")
    )
        && screen.contains("toggleFullScreenFromPointer()"),
    "video canvas should use double-click to toggle full screen without moving that behavior into the control bar"
)
require(
        screen.contains("var isPlaybackChromeVisible = true")
        && screen.contains("var isPointerInsidePlayerSurface = true")
        && screen.contains("var lastPlaybackChromePointerLocation: CGPoint?")
        && screen.contains("var playbackChromeDragOffset: CGSize = .zero")
        && screen.contains("var playbackChromeStoredOffset: CGSize = .zero")
        && screen.contains("var playbackChromeAutoHideTask: Task<Void, Never>?")
        && screen.contains("@Environment(\\.scenePhase) private var scenePhase")
        && screen.contains(".onChange(of: scenePhase)")
        && screen.contains("playerSurfaceHoverChanged(hovering)")
        && screen.contains(".onContinuousHover { phase in")
        && screen.contains("handleVideoPointerMovement(phase)")
        && screen.contains("let pointerLocation = NSEvent.mouseLocation")
        && screen.contains("guard lastPlaybackChromePointerLocation != pointerLocation else")
        && screen.contains("lastPlaybackChromePointerLocation = NSEvent.mouseLocation")
        && screen.contains("TapGesture(count: 1)")
        && screen.contains("togglePlaybackFromPointer()")
        && screen.contains("func schedulePlaybackChromeAutoHide()")
        && screen.contains(".onChange(of: isInspectorVisible)")
        && screen.contains("if inspectorVisible {")
        && screen.contains("revealPlaybackChrome(scheduleHide: false)")
        && screen.contains("schedulePlaybackChromeAutoHide()")
        && screen.contains("func hidePlaybackChromeForPointerExit()")
        && screen.contains("func clampedPlaybackChromeOffset")
        && screen.contains("playbackChromeStoredOffset = clampedPlaybackChromeOffset")
        && screen.contains("onDragChanged: { translation in")
        && screen.contains("onDragEnded: { translation in")
        && screen.contains(".position(playbackChromeBasePosition(in: geometry.size))")
        && screen.contains(".offset(playbackChromeCurrentOffset(in: geometry.size))")
        && screen.contains("Task.sleep(nanoseconds: 1_000_000_000)")
        && screen.contains("func hidePlaybackChromeAndCursor()")
        && screen.contains("windowChrome.hidePlaybackCursorUntilMouseMoves()")
        && screen.contains("windowChrome.restorePlaybackCursor()")
        && screen.contains("func playbackChromeHoverChanged(_ hovering: Bool)")
        && !screen.contains("revealPlaybackChrome(scheduleHide: false)\n        } else {\n            schedulePlaybackChromeAutoHide()")
        && !screen.contains("!isPointerOverPlaybackChrome,\n              !hasActiveVideoPopup")
        && screen.contains("var shouldShowPlaybackChrome: Bool"),
    "video playback chrome and cursor should share one one-second idle callback, restore on pointer activity, and remain draggable"
)
require(
    !screen.contains("scenePhase == .active,\n           isPointerInsidePlayerSurface")
        && !screen.contains("if isActive,\n           isPointerInsidePlayerSurface"),
    "the AppKit-owned Video window should not gate cursor hiding on SwiftUI scene or cached hover activity"
)
requireOrdered(
    screen,
    [
        "func hidePlaybackChromeAndCursor()",
        "isPlaybackChromeVisible = false",
        "windowChrome.hidePlaybackCursorUntilMouseMoves()",
        "func schedulePlaybackChromeAutoHide()",
        "hidePlaybackChromeAndCursor()",
    ],
    "video cursor hiding should run directly after playback chrome hiding from the same auto-hide task instead of a derived SwiftUI onChange"
)
require(
    screen.contains("var dragTransaction = Transaction(animation: nil)")
        && screen.contains("dragTransaction.disablesAnimations = true")
        && screen.contains("withTransaction(dragTransaction) {")
        && screen.contains("playbackChromeDragOffset = translation")
        && screen.contains("withAnimation(.smooth(duration: 0.18)) {")
        && screen.contains("playbackChromeStoredOffset = finalOffset"),
    "video playback chrome should track drag updates without animation and restore smooth animation only when the drag ends"
)
require(
    screen.contains("VideoShortcutActions.previousSubtitleCue.id")
        && screen.contains("seekRelativeSubtitleCue(offset: -1)")
        && screen.contains("VideoShortcutActions.nextSubtitleCue.id")
        && screen.contains("seekRelativeSubtitleCue(offset: 1)")
        && screen.contains("VideoShortcutActions.toggleSubtitlesVisible.id")
        && screen.contains("toggleSubtitlesVisible()")
        && screen.contains("VideoShortcutActions.cycleSubtitleTrack.id")
        && screen.contains("cycleSubtitleTrack()")
        && screen.contains("VideoShortcutActions.volumeDown.id")
        && screen.contains("adjustVolume(by: -5)")
        && screen.contains("VideoShortcutActions.volumeUp.id")
        && screen.contains("adjustVolume(by: 5)"),
    "video screen should wire subtitle navigation, subtitle visibility, subtitle track cycling and volume shortcuts"
)
require(
    lookup.contains("Logger(subsystem: \"moe.shishamo.hoshi\", category: \"VideoLookup\")")
        && lookup.contains("isClosingPopupStack")
        && lookup.contains("pendingCloseCompletions")
        && lookup.contains("Ignoring reentrant closeAll"),
    "video lookup popup dismissal should be logged and protected against reentrant close animations"
)
require(
    screen.contains("alignment: .bottom"),
    "video controls should float over the video instead of occupying a full-width bar"
)
require(
    screen.contains("if model.currentURL != nil {\n                    VideoControlsView(")
        && screen.contains(".opacity(shouldShowPlaybackChrome ? 1 : 0)")
        && screen.contains(".allowsHitTesting(shouldShowPlaybackChrome)")
        && screen.contains(".accessibilityHidden(!shouldShowPlaybackChrome)")
        && !screen.contains(".transition(.move(edge: .bottom).combined(with: .opacity))"),
    "video playback chrome should fade at a stable position like IINA instead of moving in from the bottom"
)
require(
    presenter.contains("final class VideoWindowPresenter: NSObject, NSWindowDelegate")
        && presenter.contains("window.collectionBehavior.insert(.fullScreenPrimary)")
        && presenter.contains("window.styleMask.insert(.fullSizeContentView)")
        && presenter.contains("window.titlebarAppearsTransparent = true")
        && presenter.contains("window.titlebarSeparatorStyle = .none")
        && !presenter.contains(".toolbarBackgroundVisibility(.hidden, for: .windowToolbar)")
        && !app.contains(".toolbar(.hidden, for: .windowToolbar)"),
    "dedicated Video window should keep standard traffic lights over full-size edge-to-edge playback"
)
require(
    !detailView.contains("VideoPlayerScreen")
        && detailView.contains("case .video:")
        && detailView.contains("VideoLibraryView(")
        && detailView.contains("onOpenVideo:")
        && detailView.contains("onOpenRemoteVideo:"),
    "main detail should expose the local video library while leaving playback lifecycle to the dedicated Video window"
)
require(
    screen.contains("let isActive: Bool")
        && (
            screen.contains(".onChange(of: isActive)")
                || screen.contains(".onChange(of: isActive, initial: true)")
        )
        && screen.contains("if isActive {")
        && screen.contains("registerKeyboardShortcuts()")
        && screen.contains("unregisterKeyboardShortcuts()"),
    "dedicated Video window should register shortcuts only while it is the active key window"
)
require(
    profileCoordinator.contains("enum ProfileActivationCoordinator")
        && profileCoordinator.contains("static func activateGlobal(")
        && profileCoordinator.contains("repository.activeProfile")
        && profileCoordinator.contains("ProfileSettingsStore.shared.activate")
        && profileCoordinator.contains("DictionaryManager.shared.activateProfile")
        && profileCoordinator.contains("AnkiManager.shared.activateProfile"),
    "global Profile activation should have one coordinator for Profile settings, dictionaries and Anki"
)
require(
    screen.contains("profileRepository.activeProfile")
        && !screen.contains("resolvedVideoProfile")
        && !screen.contains(".video(profileID:")
        && popup.contains("twoColumnLayout: effectiveTwoColumnLayout")
        && popup.contains("userConfig.dictionaryProfileSettings()")
        && !popup.contains("ProfileSettingsStore.shared.dictionarySettings("),
    "Video lookup popup should render from the globally active Profile without loading a player-local Profile"
)
require(
    !rootView.contains("ProfileActivationCoordinator")
        && !rootView.contains("profileRepository")
        && !presenter.contains("ProfileActivationCoordinator")
        && !presenter.contains("ProfileRepository")
        && !presenter.contains("activateVideoProfileIfNeeded")
        && profilesView.contains("ProfileActivationCoordinator.activateGlobal("),
    "only ProfilesView should request global Profile activation; main and Video window activity must not switch it"
)
require(
    !screen.contains("ProfileSettingsStore.shared.activate")
        && !screen.contains("DictionaryManager.shared.activateProfile")
        && !screen.contains("AnkiManager.shared.activateProfile")
        && !profilesView.contains("ProfileSettingsStore.shared.activate")
        && !profilesView.contains("DictionaryManager.shared.activateProfile")
        && !profilesView.contains("AnkiManager.shared.activateProfile")
        && profilesView.contains("setGlobalActiveProfile")
        && profilesView.contains("ProfileActivationCoordinator.activateGlobal("),
    "ProfilesView should select the global Profile through the coordinator without directly claiming shared services"
)
require(
    screen.contains(".ignoresSafeArea(.container, edges: .top)"),
    "video playback surface should extend into the hidden toolbar safe area so the top strip can show video"
)
require(
    !screen.contains("ToolbarItemGroup(placement: .primaryAction)")
        && screen.contains("struct VideoTitlebarBackdrop: NSViewRepresentable")
        && screen.contains("view.material = .titlebar")
        && videoCanvas.contains("if windowChrome.showsWindowedTitlebarSurface")
        && videoCanvas.contains("videoWindowDragStrip")
        && videoWindowDragStrip.contains(".opacity(shouldShowPlaybackChrome ? 1 : 0)")
        && !videoWindowDragStrip.contains("!windowChrome.isFullScreen")
        && videoWindowDragStrip.contains(".frame(height: 32)")
        && videoWindowDragStrip.contains("Divider()")
        && videoWindowDragStrip.contains("WindowDragGesture()")
        && !screen.contains("toggleSidebar()")
        && !screen.contains("videoTopControls"),
    "dedicated Video window should remove its custom titlebar surface outside stable windowed state while retaining the fading windowed drag strip"
)
require(
    screen.contains("ZStack(alignment: .trailing)")
        && screen.contains("inspectorOverlay")
        && screen.contains(".transition(.move(edge: .trailing).combined(with: .opacity))")
        && screen.contains("HStack(spacing: 0)")
        && screen.contains("VideoMiningHistorySidebar(")
        && screen.contains("var isMiningHistoryVisible = false"),
    "video inspector should still overlay the video while mining history uses a separate fixed sidebar that pushes the video"
)
require(
    screen.contains("let isTranscriptSidebarTab = selectedStudySidebarTab == .transcript")
        && screen.contains("let isChaptersSidebarTab = selectedStudySidebarTab == .chapters")
        && screen.contains("let sidebarTranscript = isTranscriptSidebarTab")
        && screen.contains("let sidebarChapters = isChaptersSidebarTab")
        && screen.contains("let sidebarCurrentTime = (isTranscriptSidebarTab || isChaptersSidebarTab)")
        && screen.contains("transcript: sidebarTranscript")
        && screen.contains("chapters: sidebarChapters")
        && screen.contains("currentTime: sidebarCurrentTime")
        && screen.contains("duration: isChaptersSidebarTab ? model.snapshot.duration : 0"),
    "video history sidebar should not receive hot playback transcript/chapter/currentTime state while the history tab is selected"
)
require(
    screen.contains("static let inspectorOverlayTrailingInset: CGFloat = 16")
        && screen.contains("static let inspectorOverlayVerticalInset: CGFloat = 16")
        && screen.contains(".padding(.top, Self.inspectorOverlayVerticalInset)")
        && screen.contains(".padding(.trailing, Self.inspectorOverlayTrailingInset)"),
    "video inspector should be inset from the video window edge"
)
require(
    screen.contains("subtitleRenderingMode.usesInteractiveOverlay")
        && screen.contains("maskEnabled: userConfig.videoSubtitleMaskEnabled")
        && screen.contains("maskMode: userConfig.videoSubtitleMaskMode")
        && screen.contains("maskBlurRadius: userConfig.videoSubtitleMaskBlurRadius")
        && screen.contains("maskHiddenOpacity: userConfig.videoSubtitleMaskHiddenOpacity")
        && screen.contains("fontFamily: userConfig.videoSubtitleFontFamily")
        && screen.contains("fontSize: userConfig.videoSubtitleFontSize")
        && screen.contains("subtitleColor: userConfig.videoSubtitleColor")
        && screen.contains("case .splitASS:")
        && screen.contains("primaryCueIDs.contains($0.id)")
        && screen.contains("verticalPosition: userConfig.videoSubtitleVerticalPosition")
        && screen.contains("isLookupPopupVisible: hasVisibleVideoPopup"),
    "split ASS should render only primary cues as visible interactive TextKit text using the configured appearance and height"
)
require(
    screen.contains("var hasActiveVideoPopup: Bool")
        && screen.contains("!lookup.presentation.popups.isEmpty")
        && screen.contains("var hasVisibleVideoPopup: Bool")
        && screen.contains("lookup.presentation.popups.contains { $0.showPopup }"),
    "video subtitle masks should reveal only for visible lookup popups while popup-stack lifecycle checks keep using the active stack"
)
require(
    !controls.contains(".background(.regularMaterial)"),
    "video controls should not use the old full-width regularMaterial bar"
)
require(
    inspector.contains("struct VideoInspectorView")
        && inspector.contains("enum VideoInspectorTab")
        && inspector.contains("case episodes")
        && inspector.contains("case video")
        && inspector.contains("case audio")
        && inspector.contains("case subtitles")
        && !inspector.contains("case transcript")
        && inspector.contains("onOpenTranscript")
        && !inspector.contains("onSeekToChapter")
        && !inspector.contains("inspectorSection(\"Chapters\""),
    "video inspector should route Transcript and Chapters into the study sidebar without duplicate chapter navigation"
)
require(
    inspector.contains("VideoInspectorGlassSurface")
        && inspector.contains("VideoInspectorTabBar(selection: $selectedTab)")
        && inspector.contains("matchedGeometryEffect(id: \"selection\", in: selectionNamespace)")
        && inspector.contains("VideoInspectorSegmentedPicker(")
        && !inspector.contains("NativeGlassSegmentedPicker(")
        && !inspector.contains("VideoInspectorSwiftUIGlassSegmentedControl")
        && !inspector.contains("ControlGroup {")
        && !inspector.contains(".buttonStyle(.glassProminent)")
        && !inspector.contains(".buttonStyle(.glass)")
        && !inspector.contains(".shadow(")
        && !inspector.contains("NSSegmentedControl")
        && inspector.contains("VideoInspectorSectionGlassSurface")
        && inspector.contains("private struct VideoInspectorChoiceRow")
        && inspector.contains("private struct VideoInspectorStepperDisplay")
        && !inspector.contains("VideoInspectorGlassButtonStyle")
        && !inspector.contains("SubtitleTranscriptView"),
    "video inspector should be one glass panel with a tab strip and flat grouped lists, without nested glass buttons"
)
require(
    inspector.contains("private var header: some View")
        && inspector.contains("String(localized: \"Now Playing\")")
        && inspector.contains("private var currentEpisodeIndex: Int?")
        && inspector.contains("VideoInspectorEpisodeRow(")
        && inspector.contains("inspectorSection(\"Picture Adjustments\"")
        && inspector.contains("rowLabel(\"A-B Loop\""),
    "video inspector should name the playing video and episode position, number episodes, and group picture and loop controls"
)
require(
    inspectorState.contains("struct VideoInspectorState: Equatable")
        && inspector.contains("let state: VideoInspectorState")
        && !inspector.contains("let snapshot: VideoPlaybackSnapshot")
        && playerViewModel.contains("var inspectorState = VideoInspectorState()")
        && playerViewModel.contains("let nextInspectorState = VideoInspectorState(snapshot: snapshot)")
        && inspector.contains("extension VideoInspectorView: Equatable")
        && screen.contains("VideoInspectorView(")
        && screen.contains("state: model.inspectorState")
        && screen.contains(".equatable()"),
    "video inspector should receive a stable state slice without playback currentTime so playback ticks do not rebuild the whole inspector"
)
require(
    countOccurrences(inspector, of: ".glassEffect(") == 1
        && inspector.contains("static let subtitleFontFamilies: [String] ="),
    "video inspector should keep only one outer glass effect and cache font families to avoid per-tick glass/font work"
)
require(
    inspector.contains("NativeGlassMenuPicker(")
        && inspector.contains("selection: subtitleFontFamily")
        && inspector.contains("values: [\"\"] + Self.subtitleFontFamilies")
        && !inspector.contains("Picker(selection: subtitleFontFamily)"),
    "video inspector subtitle font control should match the Appearance font menu picker"
)
require(
    mpvClient.contains("HSMpvTimePositionStateEmitInterval")
        && mpvClient.contains("_lastTimePositionStateEmitClock")
        && mpvClient.contains("_lastEmittedStateTimePosition")
        && mpvClient.contains("shouldEmitTimePositionState")
        && mpvClient.contains("shouldEmitState = [self shouldEmitTimePositionState]")
        && mpvClient.contains("if (!shouldEmitState) {")
        && mpvClient.contains("return;"),
    "mpv time-pos should throttle SwiftUI state emission so video playback ticks do not rebuild inspector scroll content every frame"
)
require(
    inspector.contains("subtitleMaskSection")
        && inspector.contains("subtitleMaskBlurRadius")
        && inspector.contains("subtitleMaskHiddenOpacity")
        && inspector.contains("Mask subtitles until hover"),
    "video inspector should expose subtitle mask toggle, mode and strength controls in the Subtitles tab"
)
require(
    playbackEngine.contains("static let allowedMilliseconds = -60_000...60_000")
        && playbackEngine.contains("static let sliderMilliseconds = -10_000...10_000")
        && inspector.contains("static let subtitleTimingLargeStepMilliseconds = 1_000")
        && inspector.contains("static let subtitleTimingSmallStepMilliseconds = 50")
        && inspector.contains("subtitleTimingSection")
        && inspector.contains("Slider(")
        && inspector.contains("get: { Double(VideoSubtitleTiming.clampedSliderMilliseconds(subtitleTimingMilliseconds)) }")
        && inspector.contains("in: Double(VideoSubtitleTiming.sliderMilliseconds.lowerBound)...Double(VideoSubtitleTiming.sliderMilliseconds.upperBound)")
        && inspector.contains("step: Double(Self.subtitleTimingSmallStepMilliseconds)")
        && inspector.contains("applySubtitleTimingMilliseconds(current - Self.subtitleTimingLargeStepMilliseconds)")
        && inspector.contains("applySubtitleTimingMilliseconds(current - Self.subtitleTimingSmallStepMilliseconds)")
        && inspector.contains("applySubtitleTimingMilliseconds(current + Self.subtitleTimingSmallStepMilliseconds)")
        && inspector.contains("applySubtitleTimingMilliseconds(current + Self.subtitleTimingLargeStepMilliseconds)")
        && inspector.contains("TextField(\"Offset\", text: $subtitleTimingInputText)")
        && inspector.contains("Image(systemName: \"keyboard\")")
        && subtitleTimingSection.contains("VideoInspectorStepperDisplay(")
        && inspector.contains(".lineLimit(1)\n                .minimumScaleFactor(0.7)")
        && !subtitleTimingSection.contains(".clipShape(Circle())"),
    "video subtitle timing should keep the slider at +/-10000ms, let buttons and input reach +/-60000ms, and avoid clipping the complete control row"
)
require(
    screen.contains("VideoShortcutActions.subtitleEarlier.id")
        && screen.contains("adjustSubtitleDelayWithOSD(by: -0.05)")
        && screen.contains("VideoShortcutActions.subtitleLater.id")
        && screen.contains("adjustSubtitleDelayWithOSD(by: 0.05)")
        && screen.contains("adjustAudioDelayWithOSD(by: -0.5)")
        && screen.contains("adjustAudioDelayWithOSD(by: 0.5)"),
    "video subtitle timing shortcuts should use 50ms steps while audio timing keeps 500ms steps"
)
require(
    screen.contains("VideoShortcutActions.alignPreviousSubtitleToCurrentTime.id")
        && screen.contains("alignAdjacentSubtitleToCurrentTime(.previous)")
        && screen.contains("VideoShortcutActions.alignNextSubtitleToCurrentTime.id")
        && screen.contains("alignAdjacentSubtitleToCurrentTime(.next)"),
    "video shortcuts should align the adjacent subtitle to the current playback time"
)
require(
    miningHistorySidebar.contains("transcriptToolbar")
        && miningHistorySidebar.contains("onAlignPreviousSubtitle")
        && miningHistorySidebar.contains("onAlignNextSubtitle")
        && miningHistorySidebar.contains("canAlignPreviousSubtitle")
        && miningHistorySidebar.contains("canAlignNextSubtitle"),
    "the Transcript study sidebar should expose enabled-state-aware subtitle alignment buttons"
)
require(
    mpvClient.contains("std::atomic_bool _nativeSubtitleRenderingEnabled")
        && mpvClient.contains("shouldRenderNativeImageSubtitles")
        && mpvClient.contains("hasSelectedSubtitle")
        && mpvClient.contains("_nativeSubtitleRenderingEnabled.load")
        && !mpvClient.contains("cues.count > 0 ? \"no\" : \"yes\""),
    "mpv should render subtitles only for explicit native ASS/SSA mode or selected bitmap tracks, independent of cue gaps"
)
require(
    mpvClient.contains("std::atomic<uint64_t> _loadGeneration")
        && mpvClient.contains("_loadGeneration.fetch_add(1")
        && mpvClient.contains("isCurrentLoadGeneration")
        && mpvClient.contains("guardedLoadGeneration"),
    "mpv callbacks queued by an older episode load must be discarded before they can overwrite the new episode restore state"
)
require(
    miningHistorySidebar.contains("struct VideoMiningHistorySidebar")
        && miningHistorySidebar.contains("static let minWidth: CGFloat = 320")
        && miningHistorySidebar.contains("static let defaultWidth: CGFloat = 340")
        && miningHistorySidebar.contains("static let maxWidth: CGFloat = 560")
        && miningHistorySidebar.contains("frame(minWidth: Self.minWidth, idealWidth: Self.defaultWidth, maxWidth: .infinity)")
        && miningHistorySidebar.contains("ScrollViewReader")
        && miningHistorySidebar.contains("enum VideoStudySidebarTab")
        && miningHistorySidebar.contains("case chapters")
        && miningHistorySidebar.contains("let chapters: [VideoChapter]")
        && miningHistorySidebar.contains("let duration: TimeInterval")
        && miningHistorySidebar.contains("private struct VideoStudyTabBar")
        && miningHistorySidebar.contains("SubtitleTranscriptView")
        && miningHistorySidebar.contains("chapterList")
        && miningHistorySidebar.contains("currentChapterID")
        && miningHistorySidebar.contains("onSeekChapter(chapter.id)")
        && miningHistorySidebar.contains("VideoStudyProgressBar(")
        && miningHistorySidebar.contains("No Chapters")
        && miningHistorySidebar.contains("VideoStudyListRow {\n            onJump(item)")
        && miningHistorySidebar.contains("Label(\"Copy Subtitle\", systemImage: \"doc.on.doc\")")
        && miningHistorySidebar.contains("Label(\"Delete\", systemImage: \"trash\")")
        && miningHistorySidebar.contains("onCopy(item)")
        && miningHistorySidebar.contains(".contextMenu {")
        && miningHistorySidebar.contains("VideoStudySearchField(prompt: \"Search Mining History\"")
        && miningHistorySidebar.contains("VideoStudySearchField(prompt: \"Search Transcript\"")
        && miningHistorySidebar.contains("for item in items.reversed()")
        && !miningHistorySidebar.contains("onContinueMining")
        && !miningHistorySidebar.contains(" Menu {")
        && !miningHistorySidebar.contains("Image(systemName: \"ellipsis\")")
        && miningHistorySidebar.contains("confirmationDialog")
        && miningHistorySidebar.contains("Clear Mining History"),
    "video study sidebar should switch between searchable newest-first mining history, transcript and chapters while preserving direct history actions"
)
require(
    studyListCard.contains("struct VideoStudyListRow")
        && studyListCard.contains("VideoStudyListRowSurface")
        && studyListCard.contains("struct VideoStudyGroup")
        && studyListCard.contains("struct VideoStudySearchField")
        && studyListCard.contains("enum VideoStudySearch")
        && studyListCard.contains("backgroundTint")
        && studyListCard.contains("onHover")
        && !studyListCard.contains(".glassEffect(")
        && !studyListCard.contains("Material")
        && !studyListCard.contains("withAnimation(.smooth(duration: 0.16))"),
    "video study lists should use lightweight flat row tint instead of per-row glass or hover animation during playback scrolling"
)
require(
    miningHistorySidebar.contains("VideoStudyListRow(")
        && miningHistorySidebar.contains("VideoStudyGroup {")
        && miningHistorySidebar.contains("VideoStudySidebarBackground")
        && !miningHistorySidebar.contains(".glassEffect(")
        && transcriptView.contains("VideoStudyListRow(")
        && transcriptView.contains("LazyVStack(spacing: 2)"),
    "mining history, transcript and chapters should share the flat study row presentation"
)
require(
    transcriptView.contains("extension SubtitleTranscriptView: Equatable")
        && transcriptView.contains("lhs.currentRowID == rhs.currentRowID")
        && transcriptView.contains("lhs.query == rhs.query")
        && transcriptView.contains("func followPlayback(")
        && transcriptView.contains("guard isFollowingPlayback,")
        && transcriptView.contains(".onScrollPhaseChange")
        && transcriptView.contains("Back to Current Line")
        && transcriptView.contains("proxy.scrollTo(row.id, anchor: .center)")
        && !transcriptView.contains("withAnimation(.smooth(duration: 0.18))")
        && miningHistorySidebar.contains("SubtitleTranscriptView(")
        && miningHistorySidebar.contains(".equatable()"),
    "video transcript sidebar should skip playback ticks inside the same subtitle row, pause following while the user scrolls, and avoid animated auto-scroll"
)
require(
    ambientBackdrop.contains("struct VideoAmbientBackdrop")
        && ambientBackdrop.contains("VideoAmbientPresentation")
        && ambientBackdrop.contains("usesBlurredLetterbox: false")
        && ambientBackdrop.contains("workspaceCornerRadius: 0")
        && screen.contains("guard ambientPresentation.usesBlurredLetterbox else")
        && ambientModel.contains("playbackInterval: TimeInterval = 3.0"),
    "windowed playback should disable current-frame ambient blur while keeping the isolated preview path dormant"
)
require(
    playbackEngine.contains("captureAmbientPreview(maximumDimension:")
        && mpvClient.contains("screenshot-raw")
        && mpvClient.contains("mpv_command_ret")
        && mpvClient.contains("dispatch_sync(_ambientPreviewQueue")
        && windowChrome.contains("private(set) var isFullScreen")
        && screen.contains("VideoAmbientBackdrop("),
    "ambient preview plumbing should stay behind the playback boundary and drain before shutdown even while the UI disables it"
)
require(
    mpvClient.contains("screenshot-to-file")
        && mpvClient.contains("\"video\"")
        && !ambientBackdrop.contains("captureScreenshot"),
    "mining screenshots should remain on mpv's video-only capture path instead of capturing the ambient UI"
)
require(
    screen.contains("var miningHistory = VideoMiningHistoryStore()")
        && screen.contains("mineCurrentSubtitle()")
        && screen.contains("miningHistory.record(")
        && screen.contains("VideoMiningHistoryNavigationResolver.resolve(")
        && screen.contains("copyMiningHistorySubtitle(")
        && screen.contains("showMiningHistoryNotice(.copied)")
        && screen.contains("VideoShortcutActions.mineCurrentSubtitle.id")
        && controls.contains("Label(\"Mining History\", systemImage: \"clock.arrow.circlepath\")"),
    "video mining should save, copy and restore current subtitles through the shared player flow"
)
require(
    !popup.contains("onMiningStarted")
        && !popup.contains("onMiningFinished")
        && !screen.contains("onMiningStarted:")
        && !screen.contains("onMiningFinished:"),
    "shared Popup mining should no longer expose Video-only history result hooks"
)
require(
    transcriptView.contains("var rowWindow = SubtitleTranscriptWindow()")
        && transcriptView.contains("transcript.rows(in: rowWindow.visibleRange)")
        && transcriptView.contains("extendWindowIfNeeded(forVisibleOffset:")
        && transcriptView.contains("rowWindow.followPlayback("),
    "video transcript should dynamically render a nearby row window and extend it during playback or scrolling"
)
require(
    screen.contains("let sidebarPendingABLoopStart = isTranscriptSidebarTab")
        && screen.contains("let sidebarABLoop = isTranscriptSidebarTab ? model.snapshot.abLoop : nil")
        && screen.contains("pendingABLoopStart: sidebarPendingABLoopStart")
        && screen.contains("abLoop: sidebarABLoop")
        && screen.contains("model.setABLoopStart(at: time)")
        && screen.contains("model.setABLoopEnd(at: time)")
        && miningHistorySidebar.contains("let pendingABLoopStart: TimeInterval?")
        && miningHistorySidebar.contains("let abLoop: VideoABLoop?")
        && miningHistorySidebar.contains("onSetTranscriptABLoopStart")
        && miningHistorySidebar.contains("onSetTranscriptABLoopEnd")
        && transcriptView.contains("abLoopMarkerButton(\"A\"")
        && transcriptView.contains("abLoopMarkerButton(\"B\"")
        && transcriptView.contains("onSetABLoopStart(row.startTime)")
        && transcriptView.contains("onSetABLoopEnd(row.endTime)"),
    "video transcript rows should expose A/B loop markers and wire them to playback state"
)
require(
    !subtitleModel.contains("struct SubtitleTranscript: Equatable")
        && subtitleModel.contains("let changeToken: ChangeToken")
        && subtitleModel.contains("struct ChangeToken: Equatable"),
    "subtitle transcript should expose a cheap change token and avoid whole-array Equatable comparisons"
)
require(
    !transcriptView.contains("onChange(of: transcript.rows)")
        && transcriptView.contains("onChange(of: transcript.changeToken)"),
    "video transcript should track a cheap transcript change token instead of comparing the full row array"
)
require(
    transcriptView.contains("var focusedRowID")
        && transcriptView.contains("row.id != focusedRowID || rowWindow.visibleRange != previousRange"),
    "video transcript should avoid re-scrolling the list on every playback tick while the focused row is unchanged"
)
require(
    !inspector.contains(".pickerStyle(.segmented)")
        && !inspector.contains(".buttonStyle(.bordered)"),
    "video inspector should not fall back to material segmented pickers or bordered buttons"
)

print("Video Liquid Glass contract tests passed")
