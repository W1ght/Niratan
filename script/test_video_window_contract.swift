import Foundation

private func read(_ path: String) -> String {
    guard let value = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("FAIL: unable to read \(path)\n", stderr)
        exit(1)
    }
    return value
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func countOccurrences(_ source: String, of needle: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var lowerBound = source.startIndex
    while let range = source.range(of: needle, range: lowerBound..<source.endIndex) {
        count += 1
        lowerBound = range.upperBound
    }
    return count
}

private func sourceBlock(
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

private func containsInOrder(_ source: String, _ needles: [String]) -> Bool {
    var lowerBound = source.startIndex
    for needle in needles {
        guard let range = source.range(
            of: needle,
            range: lowerBound..<source.endIndex
        ) else {
            return false
        }
        lowerBound = range.upperBound
    }
    return true
}

let app = read("NativeMac/HoshiNativeMacApp.swift")
let root = read("NativeMac/NativeMacRootView.swift")
let detail = read("NativeMac/NativeMacDetailView.swift")
let player = read("Features/Video/VideoPlayerScreen.swift")
    + read("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + read("Features/Video/VideoPlayerScreen+Chrome.swift")
    + read("Features/Video/VideoPlayerScreen+OSD.swift")
    + read("Features/Video/VideoPlayerScreen+Mining.swift")
    + read("Features/Video/VideoPlayerScreen+Opening.swift")
    + read("Features/Video/VideoPlayerScreen+Shortcuts.swift")
let renderView = read("Features/Video/Playback/MpvRenderView.swift")
let windowChrome = read("Features/Video/VideoWindowChromeController.swift")
let coordinator = read("Features/Video/VideoWindowCoordinator.swift")
let presenter = read("NativeMac/VideoWindowPresenter.swift")
let shortcutManager = read("Core/Shortcuts/ShortcutManager.swift")
let windowActivity = read("NativeMac/NativeWindowActivityReader.swift")
let playbackEngine = read("Features/Video/Playback/PlaybackEngine.swift")
    + read("Features/Video/Playback/VideoTrack.swift")
let mpvEngine = read("Features/Video/Playback/MpvPlayerEngine.swift")
let clientHeader = read("Features/Video/Playback/HSMpvClient.h")
let clientImplementation = read("Features/Video/Playback/HSMpvClient.mm")
let liveResizeConstraint = sourceBlock(
    windowChrome,
    from: "func constrainedFrameSize(for proposedFrameSize: NSSize) -> NSSize",
    to: "func toggleFullScreen()"
)
let defaultFrameSizing = sourceBlock(
    presenter,
    from: "func defaultVideoWindowFrame() -> NSRect",
    to: "func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize"
)
let makeVideoWindow = sourceBlock(
    presenter,
    from: "func makeWindow(",
    to: "func configureVideoWindowChrome(_ window: NSWindow)"
)
let titlebarAppearance = sourceBlock(
    windowChrome,
    from: "func applyTitlebarAppearance(for state: FullScreenState)",
    to: "func updateFullScreenState()"
)
let chromeVisibility = sourceBlock(
    windowChrome,
    from: "func applyChromeVisibility(",
    to: "func restoreAttachedWindow()"
)
let fullScreenSystemChrome = sourceBlock(
    windowChrome,
    from: "func prepareSystemChromeForFullScreenTransition()",
    to: "func applyTitlebarAppearance(for state: FullScreenState)"
)
let windowedTitlebarPresentation = sourceBlock(
    windowChrome,
    from: "var showsWindowedTitlebarSurface: Bool",
    to: "var hasWindow: Bool"
)

require(
    coordinator.contains("static let windowID = \"video-player\"")
        && presenter.contains("final class VideoWindowPresenter: NSObject, NSWindowDelegate")
        && presenter.contains("NSWindow(")
        && presenter.contains("window.identifier = NSUserInterfaceItemIdentifier(VideoWindowCoordinator.windowID)")
        && presenter.contains("window.collectionBehavior.insert(.fullScreenPrimary)")
        && presenter.contains("window.contentViewController = hostingController")
        && !app.contains(".windowManagerRole(.principal)")
        && !app.contains("Window(\"Video\", id: VideoWindowCoordinator.windowID)")
        && presenter.contains(".id(videoWindowCoordinator.sessionID)")
        && presenter.contains("videoWindowCoordinator.windowDidDisappear()"),
    "Video variant should declare one AppKit-owned non-restoring dedicated system-fullscreen player window"
)
require(
    presenter.contains("window.styleMask.insert(.fullSizeContentView)")
        && presenter.contains("window.titlebarAppearsTransparent = true")
        && presenter.contains("window.titlebarSeparatorStyle = .none")
        && presenter.contains("window.acceptsMouseMovedEvents = true")
        && !presenter.contains(".toolbarBackgroundVisibility(.hidden, for: .windowToolbar)")
        && !app.contains(".toolbar(.hidden, for: .windowToolbar)"),
    "dedicated Video window should extend video under one transparent native titlebar without replacing its system controls"
)
require(
    presenter.contains("window.isReleasedWhenClosed = false")
        && presenter.contains("scheduleWindowTeardown(")
        && presenter.contains("DispatchQueue.main.async")
        && presenter.contains("closingWindow.contentViewController = nil")
        && presenter.contains("closingWindow.delegate = nil")
        && !presenter.contains("window = nil\n    }"),
    "manual Video NSWindow should remain retained through AppKit close teardown before releasing SwiftUI content"
)
require(
    windowChrome.contains("final class VideoWindowChromeController")
        && windowChrome.contains("weak var window: NSWindow?")
        && windowChrome.contains("standardWindowButton(.closeButton)")
        && windowChrome.contains("standardWindowButton(.miniaturizeButton)")
        && windowChrome.contains("standardWindowButton(.zoomButton)")
        && windowChrome.contains("func setChromeVisible(_ visible: Bool)")
        && windowChrome.contains("func toggleFullScreen()")
        && windowChrome.contains("func exitFullScreen()")
        && windowChrome.contains("window.toggleFullScreen(nil)")
        && windowChrome.contains("NSWindow.willEnterFullScreenNotification")
        && windowChrome.contains("NSWindow.willExitFullScreenNotification")
        && windowChrome.contains("NSWindow.didExitFullScreenNotification")
        && windowChrome.contains("enum FullScreenState")
        && windowChrome.contains("currentSystemFullScreenState()")
        && windowChrome.contains("func fullScreenTransitionDidFail()")
        && presenter.contains("windowDidFailToEnterFullScreen")
        && presenter.contains("windowDidFailToExitFullScreen")
        && !windowChrome.contains("scheduleFullScreenTransitionFallback()")
        && windowChrome.contains("var chromeVisible = true")
        && windowChrome.contains("chromeVisible = visible")
        && windowChrome.contains("applyChromeVisibility(animated: !isLiveResizing)")
        && windowChrome.contains("NSAnimationContext.runAnimationGroup")
        && windowChrome.contains("$0.animator().alphaValue = targetAlpha")
        && windowChrome.contains("compactMap({ $0 as? NSTextField })")
        && windowChrome.contains("pointerActivityGeneration &+= 1")
        && !windowChrome.contains("insert(.fullScreenNone)")
        && !windowChrome.contains("button.action = #selector"),
    "Video window chrome should fade the native title and traffic lights with playback chrome while preserving system fullscreen"
)
require(
    !titlebarAppearance.isEmpty
        && titlebarAppearance.contains("case .fullScreen:")
        && titlebarAppearance.contains("window.titlebarAppearsTransparent = false")
        && titlebarAppearance.contains("case .windowed:")
        && titlebarAppearance.contains("window.titlebarAppearsTransparent = originalTitlebarAppearsTransparent ?? true")
        && windowChrome.contains("originalTitlebarAppearsTransparent = window?.titlebarAppearsTransparent")
        && countOccurrences(windowChrome, of: "applyTitlebarAppearance(for:") >= 3,
    "Video native fullscreen should follow IINA's opaque system-titlebar lifecycle and restore the prior transparent windowed titlebar"
)
require(
    chromeVisibility.contains("guard case .windowed = fullScreenState else { return }")
        && windowedTitlebarPresentation.contains("case .windowed:")
        && windowedTitlebarPresentation.contains("case .entering, .fullScreen, .exiting:")
        && fullScreenSystemChrome.contains("titleTextField(in: window)?.alphaValue = 0")
        && fullScreenSystemChrome.contains("titleTextField(in: window)?.alphaValue = 1")
        && fullScreenSystemChrome.contains("button.isHidden = false")
        && !fullScreenSystemChrome.contains("titleTextField(in: window)?.isHidden = false")
        && countOccurrences(windowChrome, of: "releaseSystemChromeToFullScreen()") >= 3,
    "Video native fullscreen should remove the custom windowed titlebar surface and hand the transient system title and traffic lights back to AppKit"
)
require(
    windowChrome.contains("enum VideoWindowAspectLayout")
        && windowChrome.contains("func setVideoLayout(")
        && windowChrome.contains("applyVideoAspectFit")
        && windowChrome.contains("window.setFrame(")
        && windowChrome.contains("clearVideoAspectConstraint()")
        && windowChrome.contains("window.contentAspectRatio = .zero")
        && !windowChrome.contains("window.contentAspectRatio = aspectRatio"),
    "Video window chrome should fit the window frame without installing persistent AppKit aspect-ratio constraints"
)
require(
    presenter.contains("var videoWindowChrome: VideoWindowChromeController?")
        && presenter.contains("let videoWindowChrome = VideoWindowChromeController()")
        && presenter.contains("VideoWindowRootView(videoWindowChrome: videoWindowChrome)")
        && presenter.contains("var videoWindowChrome: VideoWindowChromeController")
        && presenter.contains("_videoWindowChrome = State(initialValue: videoWindowChrome)")
        && presenter.contains("windowChrome: videoWindowChrome")
        && presenter.contains("videoWindowChrome.attach(window)"),
    "the dedicated Video window and SwiftUI root should share one window-scoped chrome controller"
)
require(
    presenter.contains("enum VideoWindowGeometry")
        && presenter.contains("static let minimumSize = NSSize(width: 285, height: 120)")
        && presenter.contains("window.minSize = VideoWindowGeometry.minimumSize")
        && presenter.contains("minWidth: VideoWindowGeometry.minimumSize.width")
        && presenter.contains("minHeight: VideoWindowGeometry.minimumSize.height")
        && countOccurrences(presenter, of: "VideoWindowGeometry.minimumSize") >= 3
        && !presenter.contains("window.minSize = NSSize(width: 900, height: 620)")
        && !presenter.contains(".frame(minWidth: 900, minHeight: 620)")
        && !presenter.contains("window.maxSize ="),
    "the AppKit window and SwiftUI root should share IINA's 285x120 minimum envelope without imposing a maximum window size"
)
require(
    presenter.contains("static let defaultSize = NSSize(width: 1132, height: 637)")
        && !defaultFrameSizing.isEmpty
        && defaultFrameSizing.contains("return NSRect(origin: .zero, size: VideoWindowGeometry.defaultSize)")
        && defaultFrameSizing.contains("let defaultSize = VideoWindowGeometry.defaultSize")
        && defaultFrameSizing.contains("let scale = min(")
        && defaultFrameSizing.contains("visibleFrame.width / defaultSize.width")
        && defaultFrameSizing.contains("visibleFrame.height / defaultSize.height")
        && defaultFrameSizing.contains("width: defaultSize.width * scale")
        && defaultFrameSizing.contains("height: defaultSize.height * scale")
        && !defaultFrameSizing.contains("VideoWindowGeometry.minimumSize")
        && !presenter.contains("defaultSizeFloor")
        && !presenter.contains("defaultScreenCoverage")
        && !presenter.contains("0.78")
        && !presenter.contains("0.86"),
    "default Video window sizing should use the independent 1132x637 screenshot target and only scale both axes together when the visible screen is smaller"
)
require(
    !makeVideoWindow.isEmpty
        && containsInOrder(
            makeVideoWindow,
            [
                "let defaultFrame = defaultVideoWindowFrame()",
                "contentRect: defaultFrame",
                "window.contentViewController = hostingController",
                "window.setFrame(defaultFrame, display: false)",
            ]
        ),
    "Video window creation should restore the requested default frame after NSHostingController fitting has temporarily replaced it with the 285x120 content minimum"
)
require(
    presenter.contains("func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize")
        && presenter.contains("videoWindowChrome?.constrainedFrameSize(for: frameSize) ?? frameSize")
        && presenter.contains("func windowWillStartLiveResize(_ notification: Notification)")
        && presenter.contains("videoWindowChrome?.beginLiveResize()")
        && presenter.contains("func windowDidEndLiveResize(_ notification: Notification)")
        && presenter.contains("videoWindowChrome?.endLiveResize()")
        && windowChrome.contains("func constrainedFrameSize(for proposedFrameSize: NSSize) -> NSSize")
        && windowChrome.contains("var liveResizeSession: LiveResizeSession?")
        && windowChrome.contains("session.referenceFrameSize")
        && windowChrome.contains("session.resizeDriver")
        && windowChrome.contains("case .windowed = fullScreenState")
        && windowChrome.contains("VideoWindowAspectLayout.constrainedFrameSize(")
        && !liveResizeConstraint.isEmpty
        && !liveResizeConstraint.contains("visibleFrame")
        && !liveResizeConstraint.contains("maxSize")
        && !liveResizeConstraint.contains("maximumFrameSize"),
    "user-driven Video window resizing should freeze one gesture baseline and driver without clamping the IINA-like maximum range to a screen or maxSize"
)
require(
    player.contains("let windowChrome: VideoWindowChromeController")
        && player.contains(".onChange(of: shouldShowPlaybackChrome, initial: true)")
        && player.contains("windowChrome.setChromeVisible(isVisible)")
        && player.contains(".onChange(of: windowChrome.pointerActivityGeneration)")
        && player.contains("windowChrome.toggleFullScreen()")
        && player.contains("isFullScreen: windowChrome.isFullScreen")
        && player.contains("windowChrome.setVideoLayout(")
        && player.contains("videoWindowAspectRatio")
        && player.contains("aspectFittingSidebarWidth")
        && !player.contains("NSApp.keyWindow?.toggleFullScreen(nil)"),
    "Video chrome visibility, full screen and aspect fitting should use the dedicated player window instead of global key-window state"
)
require(
    windowChrome.contains("func hidePlaybackCursorUntilMouseMoves()")
        && windowChrome.contains("NSApp.isActive")
        && windowChrome.contains("window?.isKeyWindow == true")
        && windowChrome.contains("NSCursor.setHiddenUntilMouseMoves(true)")
        && windowChrome.contains("func restorePlaybackCursor()")
        && windowChrome.contains("NSCursor.setHiddenUntilMouseMoves(false)")
        && windowChrome.contains("shouldRehidePlaybackCursorAfterMouseButtonEvent")
        && windowChrome.contains("NSEvent.addLocalMonitorForEvents(")
        && windowChrome.contains(".leftMouseDown")
        && windowChrome.contains(".rightMouseDown")
        && windowChrome.contains(".otherMouseDown")
        && windowChrome.contains("rehidePlaybackCursorAfterMouseButtonEventIfNeeded")
        && !windowChrome.contains("NSWindow.windowNumber(")
        && !windowChrome.contains("pointerWindowNumber == window?.windowNumber")
        && !windowChrome.contains("isCursorHiddenUntilMouseMoves")
        && !player.contains(".onChange(of: shouldHideVideoCursor"),
    "Video cursor auto-hide should follow IINA's direct AppKit call and reapply only for mouse-button events while playback chrome remains hidden"
)
require(
    player.contains("@AppStorage(\"videoStudySidebarWidth\")")
        && !player.contains("@SceneStorage(\"videoStudySidebarWidth\")"),
    "video player is hosted in a manual NSWindow and should not use SceneStorage for sidebar width"
)
require(
    playbackEngine.contains("var videoDisplaySize: CGSize?")
        && mpvEngine.contains("videoDisplaySize: videoWidth > 0 && videoHeight > 0")
        && clientHeader.contains("NSInteger videoWidth")
        && clientHeader.contains("NSInteger videoHeight")
        && clientImplementation.contains("mpv_observe_property(_handle, 12, \"video-params\", MPV_FORMAT_NODE)")
        && clientImplementation.contains("HSMpvVideoDisplaySizeFromNode"),
    "Video playback snapshots should carry mpv display dimensions for window aspect fitting"
)
require(
    mpvEngine.contains("weak var attachedRenderView: HSMpvOpenGLView?")
        && mpvEngine.contains("if attachedRenderView === view { return true }")
        && mpvEngine.contains("client.attach(to: view)")
        && mpvEngine.contains("attachedRenderView = view")
        && !mpvEngine.contains("guard !isRenderAttached else { return true }"),
    "mpv playback should reattach when fullscreen transitions provide a new OpenGL render view"
)
require(
    clientImplementation.contains("if (_renderContext) {")
        && clientImplementation.contains("if (_renderContext && _view != view) {")
        && clientImplementation.contains("[view replaceRenderLayerWithCopyOfLayer:previousLayer];")
        && clientImplementation.contains("transferredContext = [previousState takeContextForTransfer];")
        && clientImplementation.contains("_renderLayer = view.openGLLayer;")
        && clientImplementation.contains("_renderContextState = _renderLayer.renderContextState;")
        && clientImplementation.contains("[view setRenderContext:transferredContext];")
        && clientImplementation.contains("[self installRenderUpdateCallbackForView:view];")
        && clientImplementation.contains("[view requestForcedRender];\n        return YES;"),
    "mpv client should transfer the render context on its creation CGL objects when SwiftUI replaces the OpenGL view"
)
require(
    clientImplementation.contains("@interface HSMpvRenderUpdateTarget : NSObject")
        && clientImplementation.contains("@property (atomic, weak, nullable) HSMpvOpenGLView *view;")
        && clientImplementation.contains("@property (atomic) uint64_t generation;")
        && clientImplementation.contains("HSMpvRenderUpdateTarget *_renderUpdateTarget;")
        && clientImplementation.contains("void *_renderUpdateContext;")
        && clientImplementation.contains("_renderUpdateTarget = [[HSMpvRenderUpdateTarget alloc] init];")
        && clientImplementation.contains("HSMpvRenderUpdateTarget *target = (__bridge HSMpvRenderUpdateTarget *)context;")
        && clientImplementation.contains("uint64_t generation = target.generation;")
        && clientImplementation.contains("if (target.generation != generation) {")
        && clientImplementation.contains("HSMpvOpenGLView *view = target.view;")
        && clientImplementation.contains("[view requestRender];")
        && clientImplementation.contains("CFBridgingRetain(_renderUpdateTarget)")
        && clientImplementation.contains("CFRelease((CFTypeRef)_renderUpdateContext)")
        && clientImplementation.contains("_renderUpdateTarget.view = nil;")
        && clientImplementation.contains("_renderUpdateTarget.generation += 1;")
        && !clientImplementation.contains("mpv_render_context_set_update_callback(_renderContext, HSMpvRenderUpdate, (__bridge void *)view);"),
    "mpv render update callbacks should keep a retained stable weak-view target across asynchronous main-queue redraws"
)
require(
    clientImplementation.contains("- (void)performWithLockedOpenGLContext:(void (^)(void))body")
        && clientImplementation.contains("CGLLockContext(_context);")
        && clientImplementation.contains("CGLSetCurrentContext(_context);")
        && clientImplementation.contains("CGLUnlockContext(_context);")
        && clientImplementation.contains("[self performWithLockedOpenGLContext:^{")
        && clientImplementation.contains("[view performWithLockedOpenGLContext:^{")
        && clientImplementation.contains("HSMpvOpenGLLayer *renderLayer = _renderLayer ?: view.openGLLayer;")
        && clientImplementation.contains("[renderLayer performWithLockedOpenGLContext:^{")
        && clientImplementation.contains("[renderContextState invalidateAndPerform:")
        && clientImplementation.contains("mpv_render_context_free(context);"),
    "mpv OpenGL render context should be rendered and lifetime-invalidated/freed only while its CGL context is current and locked"
)
require(
    clientImplementation.contains("NSRecursiveLock *_subtitleCueLock;")
        && clientImplementation.contains("_subtitleCueLock = [[NSRecursiveLock alloc] init];")
        && clientImplementation.contains("- (void)resetSubtitleCueCache")
        && clientImplementation.contains("- (NSArray<HSMpvSubtitleCueInfo *> *)upsertFallbackSubtitleCueWithText:")
        && clientImplementation.contains("[_subtitleCueLock lock];")
        && clientImplementation.contains("[_subtitleCueLock unlock];")
        && !clientImplementation.contains("[_fallbackSubtitleCues removeAllObjects];"),
    "mpv subtitle cue cache should serialize fallback cue mutation before dispatching NSArray snapshots to the main queue"
)
require(
    !detail.contains("VideoPlayerScreen")
        && detail.contains("case .video:")
        && detail.contains("VideoLibraryView(")
        && detail.contains("onOpenVideo: onOpenVideo")
        && detail.contains("onOpenRemoteVideo: onOpenRemoteVideo"),
    "main detail should render the Video library without keeping a hidden VideoPlayerScreen alive"
)
require(
    !root.contains("@Environment(\\.openWindow)")
        && root.contains("VideoMediaTypes.isMediaFile(url)")
        && root.contains("openVideoWindow(with: url)")
        && root.contains("VideoWindowPresenter.shared.open(")
        && !root.contains("isSelectingVideoFile")
        && !root.contains("lastNonVideoSection"),
    "URL/file routes should open media in the dedicated player while sidebar Video stays on the library page"
)
require(
    player.contains("let openRequest: VideoWindowOpenRequest?")
        && player.contains(".onChange(of: openRequest, initial: true)")
        && player.contains("openGate.receive(request)")
        && player.contains("openGate.renderDidBecomeReady()")
        && renderView.contains("let onRenderReady: () -> Void")
        && !player.contains("toggleSidebar()")
        && !player.contains("Label(\"Sidebar\", systemImage: \"sidebar.leading\")"),
    "dedicated player should wait for render attachment before consuming external requests"
)
require(
    player.contains("VideoMediaTypes.contentTypes")
        && player.contains("VideoMediaTypes.isMediaFile")
        && !player.contains("private static let mpvMediaExtensions"),
    "main picker, player picker and drop routing should share one media type source"
)
require(
    windowActivity.contains("struct NativeWindowActivityReader")
        && windowActivity.contains("NSWindow.didBecomeKeyNotification")
        && windowActivity.contains("NSWindow.didResignKeyNotification")
        && shortcutManager.contains("weak var managedWindow: NSWindow?")
        && shortcutManager.contains("func manageEvents(for window: NSWindow?)")
        && shortcutManager.contains("event.window === managedWindow"),
    "each scene should route keyboard events only through the manager that owns the event window"
)
require(
    presenter.contains("var isKeyWindow = false")
        && presenter.contains("NativeWindowActivityReader")
        && presenter.contains("isActive: isKeyWindow")
        && player.contains("let isActive: Bool")
        && !presenter.contains("activateVideoProfileIfNeeded")
        && !presenter.contains("ProfileActivationCoordinator")
        && !presenter.contains("ProfileRepository")
        && !root.contains("ProfileActivationCoordinator"),
    "Video key-window state should control shortcuts only and must not activate a window-local Profile"
)

print("Video window contract tests passed")
