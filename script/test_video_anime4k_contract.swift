import Foundation

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

private func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func requireOrdered(_ source: String, _ snippets: [String], _ message: String) {
    var lowerBound = source.startIndex
    for snippet in snippets {
        guard let range = source.range(of: snippet, range: lowerBound..<source.endIndex) else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        lowerBound = range.upperBound
    }
}

let manager = try source("Features/Video/Anime4KShaderManager.swift")
    + source("Features/Video/Playback/VideoShaderPreset.swift")
let playbackProtocol = try source("Features/Video/Playback/PlaybackEngine.swift")
    + source("Features/Video/Playback/VideoTrack.swift")
let mpvClient = try source("Features/Video/Playback/HSMpvClient.mm")
let mpvEngine = try source("Features/Video/Playback/MpvPlayerEngine.swift")
let userConfig = try source("Core/UserConfig.swift")
let settings = try source("Features/Settings/VideoSettingsView.swift")
let inspector = try source("Features/Video/VideoInspectorView.swift")
let screen = try source("Features/Video/VideoPlayerScreen.swift")
    + source("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + source("Features/Video/VideoPlayerScreen+Chrome.swift")
    + source("Features/Video/VideoPlayerScreen+OSD.swift")
    + source("Features/Video/VideoPlayerScreen+Mining.swift")
    + source("Features/Video/VideoPlayerScreen+Opening.swift")
    + source("Features/Video/VideoPlayerScreen+Shortcuts.swift")
let project = try source("Niratan.xcodeproj/project.pbxproj")
let localization = try source("Localizable.xcstrings")

require(
    !manager.contains("HOSHI_VIDEO"),
    "Anime4K must compile unconditionally in the single full-feature build"
)
require(
    manager.contains("enum VideoShaderPreset: String, CaseIterable, Codable")
        && manager.contains("case off")
        && manager.contains("case anime4KFast")
        && manager.contains("case anime4KHighQuality"),
    "Anime4K must expose only strong typed Off, Fast and High Quality presets"
)
require(
    manager.contains("static let releaseTag = \"v4.0.1\"")
        && manager.contains("static let maximumShaderBytes = 2 * 1_024 * 1_024")
        && manager.contains("raw.githubusercontent.com/bloc97/Anime4K")
        && manager.contains("cdn.jsdelivr.net/gh/bloc97/Anime4K@")
        && manager.contains("fastly.jsdelivr.net/gh/bloc97/Anime4K@"),
    "Anime4K downloads must stay pinned, bounded and limited to fixed fallback sources"
)
for checksum in [
    "A2A9BF7FBC1D75D09660CA2E701E4D7FB0CF5457B94DA47E1825032FA2B3671A",
    "67EA3ED26539E8DE3B7D307688535D2FF17E8D147E11DDA0247DA7770DBECF41",
    "716E02098A68F0D648761F2B96B4DD139E1CB09B174BB369FCA3AA34328FFF7E",
    "8C58291740146BD766A4D73F132775A797FE80F7D07919B5D767E27A5DC85656",
    "5AF62D8CD844916DC1126613E13BAD3BEAB195787F93A71200B47C6EC78F2E41",
    "4C53EC2E287908F7EE7BCB266B0170421626D663576468B7D7DAFC62962649A4",
    "35036722733305CD4D4E57660B883BBE2569BA2914033C254327107D7B77E35E",
    "5638FE31C37C151A3443FEA3451A3EF91AF073F4DBB9615F6C0D1E29DB11493D",
] {
    require(manager.contains(checksum), "Anime4K fixed shader checksum is missing: \(checksum)")
}
require(
    manager.contains("import CryptoKit")
        && manager.contains("SHA256.hash(data: data)")
        && manager.contains("source.contains(\"//!HOOK\")")
        && manager.contains("source.contains(\"//!BIND\")")
        && manager.contains("try data.write(to: destination, options: .atomic)"),
    "downloaded shaders must pass size, UTF-8, hook and SHA-256 checks before atomic storage"
)
require(
    manager.contains("session.bytes(for: request)")
        && manager.contains("guard data.count < Self.maximumShaderBytes"),
    "oversized shader responses must be stopped while streaming instead of first buffering the full body"
)
requireOrdered(
    mpvClient,
    [
        "const char *clearCommand[] = {\"change-list\", \"glsl-shaders\", \"clr\", \"\", NULL};",
        "const char *appendCommand[] = {",
        "\"change-list\"",
        "\"glsl-shaders\"",
        "\"append\"",
        "url.fileSystemRepresentation",
    ],
    "mpv must clear then append verified shader paths with change-list commands"
)
require(
    mpvClient.contains("const char *rollbackCommand[] = {\"change-list\", \"glsl-shaders\", \"clr\", \"\", NULL};")
        && !mpvClient.contains("glsl-shaders-append"),
    "mpv must clear partial shader chains after failure and never misuse glsl-shaders-append as a property"
)
require(
    playbackProtocol.contains("func setVideoShaderPreset(_ preset: VideoShaderPreset) throws")
        && mpvEngine.contains("Anime4KShaderManager.shared.installedShaderURLs(for: preset)")
        && mpvEngine.contains("guard appliedVideoShaderPreset != preset else { return }")
        && mpvEngine.contains("appliedVideoShaderPreset = preset"),
    "the playback boundary must accept strong typed presets and resolve only manager-owned paths"
)
require(
    userConfig.contains("var videoShaderPreset: VideoShaderPreset")
        && userConfig.contains("defaults.string(forKey: \"videoShaderPreset\")")
        && userConfig.contains(".flatMap(VideoShaderPreset.init) ?? .off"),
    "Anime4K must persist as an explicitly off-by-default Video preference"
)
require(
    settings.contains("VideoAnime4KPresetControl(minimumPickerWidth: 210)")
        && inspector.contains("VideoAnime4KPresetControl(")
        && inspector.contains("onActivate: onSetVideoShaderPreset"),
    "Video Settings and the player Video sidebar must reuse one Anime4K control"
)
require(
    manager.contains("var downloadTask: Task<Void, Never>?")
        && manager.contains("downloadTask = Task { @MainActor in")
        && manager.contains(".buttonStyle(.glassProminent)")
        && manager.contains(".buttonBorderShape(.capsule)")
        && !manager.contains("substantially more GPU power"),
    "Anime4K download must provide immediate task feedback through a native macOS 26 glass button without load annotations"
)
require(
    screen.contains(".onChange(of: userConfig.videoShaderPreset)")
        && screen.contains("model.setVideoShaderPreset(userConfig.videoShaderPreset)"),
    "the active player must apply setting changes immediately and on preference synchronization"
)
require(
    project.contains("Video/Anime4KShaderManager.swift")
        && localization.contains("\"Anime4K Upscaling\"")
        && localization.contains("\"Download and Apply\""),
    "the synchronized project and localization catalog must include the Anime4K feature"
)

print("Video Anime4K contract tests passed")
