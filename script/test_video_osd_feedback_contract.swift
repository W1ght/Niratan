import Foundation

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let screenURL = repo.appendingPathComponent("Features/Video/VideoPlayerScreen.swift")
let screenSubtitlesURL = repo.appendingPathComponent("Features/Video/VideoPlayerScreen+Subtitles.swift")
let osdURL = repo.appendingPathComponent("Features/Video/VideoOnScreenDisplay.swift")

func read(_ url: URL) -> String {
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        fputs("Missing \(url.path)\n", stderr)
        exit(1)
    }
    return source
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Missing Video OSD contract: \(message)\n", stderr)
        exit(1)
    }
}

let screen = read(screenURL) + read(screenSubtitlesURL)
    + read(repo.appendingPathComponent("Features/Video/VideoPlayerScreen+Chrome.swift"))
    + read(repo.appendingPathComponent("Features/Video/VideoPlayerScreen+OSD.swift"))
    + read(repo.appendingPathComponent("Features/Video/VideoPlayerScreen+Mining.swift"))
    + read(repo.appendingPathComponent("Features/Video/VideoPlayerScreen+Opening.swift"))
    + read(repo.appendingPathComponent("Features/Video/VideoPlayerScreen+Shortcuts.swift"))
let osd = read(osdURL)

require(osd.contains("struct VideoOnScreenDisplayItem"), "reusable OSD item type")
require(osd.contains("struct VideoOnScreenDisplayView"), "reusable OSD SwiftUI view")
require(osd.contains("meterProgress"), "optional meter progress for ranged values")

for helper in [
    "showSpeedOSD",
    "showVolumeOSD",
    "showMuteOSD",
    "showSubtitleVisibilityOSD",
    "showSubtitleTrackOSD",
    "showSubtitleDelayOSD",
    "showAudioDelayOSD",
] {
    require(screen.contains(helper), "\(helper) helper")
}

for marker in [
    "showSpeedOSD(normalizedSpeed)",
    "showVolumeOSD(clampedVolume)",
    "showMuteOSD(isMuted: isMuted)",
    "showSubtitleVisibilityOSD(isVisible: areSubtitlesVisible)",
    "showSubtitleTrackOSD(track: track)",
    "showSubtitleDelayOSD(clampedDelay)",
    "showAudioDelayOSD(clampedDelay)",
    "videoOSDTask?.cancel()",
] {
    require(screen.contains(marker), "wiring marker \(marker)")
}

print("Video OSD feedback contract passed")
