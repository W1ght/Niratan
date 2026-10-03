import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func source(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

let controls = try source("Features/Video/VideoControlsView.swift")
let screen = try source("Features/Video/VideoPlayerScreen.swift")
    + source("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + source("Features/Video/VideoPlayerScreen+Chrome.swift")
    + source("Features/Video/VideoPlayerScreen+OSD.swift")
    + source("Features/Video/VideoPlayerScreen+Mining.swift")
    + source("Features/Video/VideoPlayerScreen+Opening.swift")
    + source("Features/Video/VideoPlayerScreen+Shortcuts.swift")

require(
    !controls.contains("let profiles: [HoshiProfile]")
        && !controls.contains("let selectedProfileID: String")
        && !controls.contains("var onSelectProfile: (String) -> Void"),
    "video playback controls must not accept a window-local Profile selection"
)
require(
    !controls.contains("private var profileMenu: some View")
        && !controls.contains("private var selectedProfileName: String")
        && !controls.contains("private var profileMenuHelp: String")
        && !controls.contains("VideoProfileMenuTint")
        && !controls.contains("Image(systemName: \"person.crop.circle\")"),
    "video playback controls must not render a Profile picker or Profile affordance"
)
require(
    screen.contains("profileRepository.activeProfile")
        && screen.contains("contentLanguage: profileRepository.activeProfile.language")
        && !screen.contains("resolvedVideoProfile")
        && !screen.contains("selectVideoProfile(")
        && !screen.contains("setVideoProfile(")
        && !screen.contains(".video(profileID:")
        && !screen.contains("videoProfileID"),
    "video lookup, subtitle scanning and mining must consume the one globally active Profile without switching it"
)

print("Video global Profile contract tests passed")
