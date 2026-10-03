import Foundation

private func require(
    _ source: String,
    contains text: String,
    _ message: String
) {
    guard source.contains(text) else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func read(_ path: String) -> String {
    guard let value = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("FAIL: could not read \(path)\n", stderr)
        exit(1)
    }
    return value
}

let controls = read("Features/Video/VideoControlsView.swift")
let screen = read("Features/Video/VideoPlayerScreen.swift")
    + read("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + read("Features/Video/VideoPlayerScreen+Chrome.swift")
    + read("Features/Video/VideoPlayerScreen+OSD.swift")
    + read("Features/Video/VideoPlayerScreen+Mining.swift")
    + read("Features/Video/VideoPlayerScreen+Opening.swift")
    + read("Features/Video/VideoPlayerScreen+Shortcuts.swift")
let windowChrome = read("Features/Video/VideoWindowChromeController.swift")
let shortcutActions = read("Features/Video/VideoShortcutActions.swift")
let mpvEngine = read("Features/Video/Playback/MpvPlayerEngine.swift")
let mpvClient = read("Features/Video/Playback/HSMpvClient.mm")
let app = read("NativeMac/HoshiNativeMacApp.swift")
let presenter = read("NativeMac/VideoWindowPresenter.swift")

require(
    controls,
    contains: "var onToggleFullScreen: () -> Void",
    "the Video control surface should expose a fullscreen action"
)
require(
    controls.contains("Button(action: onToggleFullScreen)")
        && controls.contains("Image(systemName: isFullScreen")
        && controls.contains("\"arrow.down.right.and.arrow.up.left\"")
        && controls.contains("\"arrow.up.left.and.arrow.down.right\""),
    "the Video control surface should render a fullscreen button"
)
require(
    screen,
    contains: "onToggleFullScreen: {",
    "the Video screen should wire the control through a fullscreen action closure"
)
require(
    screen,
    contains: "toggleFullScreen()",
    "the Video fullscreen control should still call the shared fullscreen implementation"
)
require(
    screen,
    contains: "dismissVideoPopupsIfNeeded()",
    "the Video fullscreen control should dismiss active subtitle lookup popups before continuing"
)
require(
    screen,
    contains: "func toggleFullScreen()",
    "fullscreen UI and shortcuts should share one implementation"
)
require(
    controls,
    contains: "let isFullScreen: Bool",
    "the Video control surface should know whether it is already in full screen"
)
require(
    shortcutActions,
    contains: """
    static let toggleFullScreen = ShortcutAction(
        id: "video.toggleFullScreen",
        titleKey: "Toggle Full Screen",
        category: .video,
        scopes: [.video],
        defaultBinding: KeyboardShortcutBinding(key: "f")
    )
""",
    "Video fullscreen should default to the single-key F shortcut"
)
require(
    controls.contains("var fullScreenButton: some View")
        && controls.contains("Button(action: onToggleFullScreen)")
        && controls.contains("Image(systemName: isFullScreen")
        && controls.contains("\"arrow.down.right.and.arrow.up.left\"")
        && controls.contains("\"arrow.up.left.and.arrow.down.right\""),
    "the custom Video fullscreen button should remain visible and switch to an exit affordance while fullscreen"
)
require(
    screen,
    contains: """
                    VideoShortcutActions.exitFocusMode.id: {
                        guard windowChrome.isFullScreen else {
                            return false
                        }
                        exitFullScreen()
                        return true
                    }
""",
    "the Video Esc shortcut should exit native fullscreen through the guarded window path"
)
require(
    windowChrome.contains("window?.toggleFullScreen(nil)")
        || windowChrome.contains("window.toggleFullScreen(nil)"),
    "Video fullscreen should use the system NSWindow fullscreen transition"
)
require(
    !app.contains(".windowManagerRole(.principal)")
        && presenter.contains("window.collectionBehavior.insert(.fullScreenPrimary)")
        && windowChrome.contains("window.collectionBehavior.remove(.fullScreenNone)"),
    "the dedicated Video window should use AppKit NSWindow system fullscreen without SwiftUI's principal fullscreen role"
)
require(
    windowChrome.contains("NSWindow.willEnterFullScreenNotification")
        && windowChrome.contains("NSWindow.didEnterFullScreenNotification")
        && windowChrome.contains("NSWindow.willExitFullScreenNotification")
        && windowChrome.contains("NSWindow.didExitFullScreenNotification"),
    "Video fullscreen should track native fullscreen will/did transitions with an IINA-style state machine"
)
require(
    !windowChrome.contains("managedFullScreenSnapshot")
        && !windowChrome.contains("enterManagedFullScreen")
        && !windowChrome.contains("exitManagedFullScreen"),
    "Video fullscreen must not fall back to managed frame fullscreen"
)
require(
    screen,
    contains: """
                    VideoShortcutActions.toggleFullScreen.id: {
                        guard windowChrome.hasWindow else { return false }
                        if windowChrome.isFullScreen {
                            exitFullScreen()
                            return true
                        }
""",
    "the Video fullscreen shortcut should use the guarded system fullscreen exit while already fullscreen"
)
require(
    !screen.contains("isRenderSuppressedForFullScreenExit")
        && !screen.contains("detachRenderViewForFullScreenExit")
        && !mpvEngine.contains("func detachRenderViewForFullScreenExit()")
        && !mpvEngine.contains("clearDrawable()")
        && !mpvEngine.contains("removeFromSuperview()"),
    "Video fullscreen should keep the mpv/OpenGL render view stable through native fullscreen transitions"
)
require(
    !windowChrome.contains("insert(.fullScreenNone)")
        && !windowChrome.contains("insert(.fullScreenDisallowsTiling)")
        && !windowChrome.contains("button.action = #selector"),
    "Video windows should not disable system fullscreen or replace the green traffic-light action"
)
require(
    windowChrome.contains("enum FullScreenState")
        && windowChrome.contains("case entering")
        && windowChrome.contains("case exiting")
        && windowChrome.contains("var isFullScreenTransitioning: Bool")
        && windowChrome.contains("guard let window, !isFullScreenTransitioning else { return }")
        && windowChrome.contains("func fullScreenTransitionDidFail()")
        && presenter.contains("func windowDidFailToEnterFullScreen(_ window: NSWindow)")
        && presenter.contains("func windowDidFailToExitFullScreen(_ window: NSWindow)")
        && presenter.contains("name: .videoWindowFullScreenTransitionDidFail")
        && windowChrome.contains("MainActor.assumeIsolated")
        && windowChrome.contains("var isWindowGeometryTransitioning: Bool")
        && !windowChrome.contains("fullScreenTransitionFallbackTask")
        && !windowChrome.contains("Task.sleep")
        && windowChrome.contains("return window.styleMask.contains(.fullScreen)")
        && windowChrome.contains("guard !isFullScreenTransitioning else { return }"),
    "Video fullscreen controls should ignore repeated toggles and resolve failures from AppKit instead of guessing transition completion on a timer"
)
require(
    presenter.contains("\"moe.shishamo.hoshi.video.fullScreenTransitionDidFail\"")
        && mpvClient.contains("@\"moe.shishamo.hoshi.video.fullScreenTransitionDidFail\""),
    "the AppKit fullscreen-failure publisher and render-host observer should use the same notification name"
)
require(
    windowChrome.contains("window.contentAspectRatio = .zero")
        && !windowChrome.contains("window.contentAspectRatio = aspectRatio")
        && !windowChrome.contains("window.aspectRatio =")
        && windowChrome.contains("case .windowed = fullScreenState")
        && windowChrome.contains("endLiveResize()")
        && windowChrome.contains("applyChromeVisibility(animated: false, forceVisible: true)")
        && !windowChrome.contains("styleMask.insert(.fullSizeContentView)"),
    "Video live resizing should avoid persistent AppKit aspect constraints and bypass non-windowed states"
)

print("Video fullscreen contract tests passed")
