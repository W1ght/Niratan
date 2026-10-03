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

let app = try source("NativeMac/HoshiNativeMacApp.swift")
let nativeRoot = try source("NativeMac/NativeMacRootView.swift")
let presenter = try source("NativeMac/VideoWindowPresenter.swift")
let screen = try source("Features/Video/VideoPlayerScreen.swift")
    + source("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + source("Features/Video/VideoPlayerScreen+Chrome.swift")
    + source("Features/Video/VideoPlayerScreen+OSD.swift")
    + source("Features/Video/VideoPlayerScreen+Mining.swift")
    + source("Features/Video/VideoPlayerScreen+Opening.swift")
    + source("Features/Video/VideoPlayerScreen+Shortcuts.swift")
let commands = (try? source("Features/Video/VideoPlaybackCommands.swift")) ?? ""
let project = try source("Niratan.xcodeproj/project.pbxproj")

require(
    !app.contains("Window(\"Video\", id: VideoWindowCoordinator.windowID)")
        && nativeRoot.contains("VideoWindowPresenter.shared.open(")
        && presenter.contains("window.identifier = NSUserInterfaceItemIdentifier(VideoWindowCoordinator.windowID)"),
    "video playback should use the AppKit Video presenter instead of a SwiftUI Video window scene"
)
require(
    app.contains(".commands {\n            VideoPlaybackCommands()"),
    "video playback commands should be registered once at the app scene level and hidden outside the Video window"
)
require(
    commands.contains("struct VideoPlaybackCommands: Commands")
        && commands.contains("@FocusedValue(\\.videoPlaybackCommandContext)")
        && commands.contains("CommandMenu(\"Video\")")
        && commands.contains("CommandMenu(\"Audio\")")
        && commands.contains("CommandMenu(\"Subtitles\")"),
    "video playback commands should expose Video, Audio and Subtitles menus through SwiftUI command menus"
)
require(
    commands.contains("struct VideoPlaybackCommandContext")
        && commands.contains("struct VideoPlaybackCommandContextKey: FocusedValueKey")
        && commands.contains("var videoPlaybackCommandContext: VideoPlaybackCommandContext?"),
    "video playback commands should define a focused command context instead of duplicating player state"
)
require(
    commands.contains("final class VideoPlaybackMenuVisibilityController")
        && commands.contains("NSWindow.didBecomeKeyNotification")
        && commands.contains("NSWindow.didResignKeyNotification")
        && commands.contains("item.isHidden = !shouldShow")
        && commands.contains("VideoWindowCoordinator.windowID"),
    "video playback menus should be hidden outside the actual Video key window"
)
if let windowCheckRange = commands.range(of: "private func isVideoPlaybackWindow"),
   let windowCheckEnd = commands[windowCheckRange.lowerBound...].range(of: "\n    }\n}")?.lowerBound {
    let windowCheck = commands[windowCheckRange.lowerBound..<windowCheckEnd]
    require(
        windowCheck.contains("return window.identifier?.rawValue == VideoWindowCoordinator.windowID")
            && !windowCheck.contains("window.title")
            && !windowCheck.contains("\"视频\"")
            && !windowCheck.contains("\"影片\""),
        "video playback menus should key off the dedicated Video window id instead of the main library window title"
    )
} else {
    require(false, "video playback window visibility check should be present")
}
require(
    app.contains("VideoPlaybackMenuVisibilityController.shared.install()"),
    "app launch should install the Video command menu visibility bridge in Video builds"
)
require(
    commands.contains("String(localized: \"Video\")")
        && commands.contains("String(localized: \"Audio\")")
        && commands.contains("String(localized: \"Subtitles\")"),
    "video playback menu titles should use existing localized Video, Audio and Subtitles strings"
)
require(
    commands.contains("Button(\"Subtitle Earlier\") { run { $0.adjustSubtitleDelay(-0.05) } }")
        && commands.contains("Button(\"Subtitle Later\") { run { $0.adjustSubtitleDelay(0.05) } }")
        && commands.contains("Button(\"Audio Earlier\") { run { $0.adjustAudioDelay(-0.5) } }")
        && commands.contains("Button(\"Audio Later\") { run { $0.adjustAudioDelay(0.5) } }"),
    "video subtitle timing menu commands should use 50ms steps while audio timing keeps 500ms steps"
)
require(
    screen.contains(".focusedSceneValue(\\.videoPlaybackCommandContext, videoPlaybackCommandContext)")
        && screen.contains("var videoPlaybackCommandContext: VideoPlaybackCommandContext"),
    "video player screen should publish its current playback command context from the Video window"
)
require(
    project.contains("Video/VideoPlaybackCommands.swift"),
    "Xcode synchronized Features membership should include the Video playback commands file"
)

print("Video menu commands contract passed")
