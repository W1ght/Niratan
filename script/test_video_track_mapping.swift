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

let path = "Features/Video/Playback/MpvPlayerEngine.swift"
let source = try String(contentsOfFile: path, encoding: .utf8)
let nativeSource = try String(
    contentsOfFile: "Features/Video/Playback/HSMpvClient.mm",
    encoding: .utf8
)
let extractorSource = try String(
    contentsOfFile: "Features/Video/Subtitles/VideoSubtitleTrackExtractor.swift",
    encoding: .utf8
)
let playbackBoundary = try String(
    contentsOfFile: "Features/Video/Playback/VideoTrack.swift",
    encoding: .utf8
) + String(
    contentsOfFile: "Features/Video/Playback/PlaybackEngine.swift",
    encoding: .utf8
)
let subtitleController = try String(
    contentsOfFile: "Features/Video/Subtitles/VideoSubtitleController.swift",
    encoding: .utf8
)
let playerScreen = try String(
    contentsOfFile: "Features/Video/VideoPlayerScreen.swift",
    encoding: .utf8
) + String(contentsOfFile: "Features/Video/VideoPlayerScreen+Subtitles.swift", encoding: .utf8)
    + String(contentsOfFile: "Features/Video/VideoPlayerScreen+Chrome.swift", encoding: .utf8)
    + String(contentsOfFile: "Features/Video/VideoPlayerScreen+OSD.swift", encoding: .utf8)
    + String(contentsOfFile: "Features/Video/VideoPlayerScreen+Mining.swift", encoding: .utf8)
    + String(contentsOfFile: "Features/Video/VideoPlayerScreen+Opening.swift", encoding: .utf8)
    + String(contentsOfFile: "Features/Video/VideoPlayerScreen+Shortcuts.swift", encoding: .utf8)
require(
    source,
    contains: "track.type == \"sub\" ? \"subtitle\" : track.type",
    "mpv sub tracks should map to the Hoshi subtitle track type"
)
require(source, contains: "ffIndex: track.ffIndex >= 0", "track mapping should preserve the FFmpeg stream index")
require(source, contains: "externalFilename: track.externalFilename", "track mapping should preserve external subtitle paths")
require(source, contains: "isImage: track.isImage", "track mapping should identify bitmap subtitle tracks")
require(nativeSource, contains: "strcmp(key, \"ff-index\")", "native track metadata should read FFmpeg stream indices")
require(nativeSource, contains: "strcmp(key, \"external-filename\")", "native track metadata should read external subtitle paths")
require(nativeSource, contains: "strcmp(key, \"image\")", "native track metadata should read bitmap subtitle flags")
require(extractorSource, contains: "HSSubtitleTrackExtractor.extractTextSubtitle", "selected text tracks should use the bundled extractor")
require(
    extractorSource,
    contains: "isCancelled: @escaping @Sendable () -> Bool",
    "subtitle extraction should accept cooperative cancellation"
)
require(
    nativeSource,
    contains: "HSMpvSubtitleExtractionIsCancelled(isCancelled)",
    "native subtitle packet scanning should observe cancellation"
)
require(
    nativeSource,
    contains: "_nativeSubtitleRenderingEnabled",
    "mpv should keep an explicit subtitle rendering mode for complex ASS/SSA tracks"
)
require(
    nativeSource,
    contains: "- (void)setNativeSubtitleRenderingEnabled:(BOOL)enabled",
    "the playback boundary should expose native subtitle rendering without coupling SwiftUI to mpv"
)
require(
    nativeSource,
    contains: "mpv_set_property_string(_handle, \"sub-visibility\", enabled ? \"yes\" : \"no\")",
    "native subtitle mode should control mpv/libass visibility directly"
)
require(
    playbackBoundary,
    contains: "case overlayOnly",
    "subtitle rendering modes should include overlay-only ownership"
)
require(
    playbackBoundary,
    contains: "case preparingASS",
    "ASS classification should have a non-visible preparation mode"
)
require(
    playbackBoundary,
    contains: "case nativeOnly",
    "subtitle rendering modes should include native-only ownership"
)
require(
    playbackBoundary,
    contains: "case splitASS(effectsURL: URL, logicalTrackID: Int?)",
    "the playback boundary should distinguish overlay, native, and split ASS ownership"
)
require(
    nativeSource,
    contains: "__niratan_internal_ass_effects__",
    "the effects-only implementation track should have a reserved hidden title"
)
require(
    nativeSource,
    contains: "installASSSubtitleEffectsFromURL",
    "the native playback boundary should install a filtered ASS effects track"
)
require(
    nativeSource,
    contains: "clearASSSubtitleEffectsRestoringLogicalTrack",
    "the native playback boundary should remove internal effects and restore the logical track"
)
require(
    nativeSource,
    contains: "track.selected = YES",
    "the internal effects track should remain hidden while the original logical subtitle stays selected in UI"
)
require(
    nativeSource,
    contains: "Publish the logical selection before `sub-add`",
    "the logical ASS selection should be published before mpv can emit the internal track snapshot"
)
require(
    source,
    contains: "subtitleRenderingMode = .overlayOnly\n        loadedSource = source",
    "every media load should invalidate the cached split ASS installation"
)
require(
    source,
    contains: "case .overlayOnly, .preparingASS:",
    "ASS preparation should hide native libass without exposing interactive hit targets"
)
require(
    playerScreen,
    contains: "case .preparingASS, .nativeOnly:",
    "the subtitle overlay should remain empty while ASS ownership is being prepared"
)
require(
    playerScreen,
    contains: "else if initialMode == .preparingASS",
    "a failed external ASS preparation should atomically reveal the original libass track"
)
require(
    playerScreen,
    contains: "subtitles.transcriptErrorMessage != nil",
    "a failed embedded ASS extraction should remain on its native fallback during later track updates"
)
require(
    subtitleController,
    contains: "discardTemporaryResources()",
    "prepared ASS loads should own explicit temporary-resource cleanup"
)
require(
    playerScreen,
    contains: "load.discardTemporaryResources()",
    "stale or cancelled embedded ASS preparation should remove its temporary effects file"
)
require(
    subtitleController,
    contains: "func markASSEffectsInstallationFailed()",
    "an ASS effects installation failure should be latched for the current subtitle document"
)
require(
    subtitleController,
    contains: "guard !assEffectsPreparationFailed else { return false }",
    "track updates should not repeatedly retry a failed ASS effects installation"
)
require(
    playerScreen,
    contains: "guard loadGeneration == primarySubtitleLoadGeneration else { return }",
    "an obsolete external subtitle load must not clear the loading state of a newer request"
)
require(
    playerScreen,
    contains: "subtitles.cancelPendingPrimaryLoad()",
    "turning subtitles off should invalidate an unfinished controller parse"
)
require(
    playerScreen,
    contains: "restorePreservedSubtitleRenderingAfterMediaReload()",
    "a preserved ASS overlay should restore its logical mpv track after a media reload"
)
require(
    playerScreen,
    contains: "applyPreparedSubtitleRendering(logicalTrackID: nil)",
    "external and catalog documents should keep their interactive renderer while no mpv track is selected"
)
require(
    playerScreen,
    contains: "Clear a split effects track before `beginEmbeddedTrack` releases",
    "a changed embedded-track key should clear native effects before deleting its temporary file"
)
require(
    source,
    contains: "snapshot.tracks = []",
    "opening another video should invalidate the previous video's tracks so an identical new track list still reloads its transcript"
)

print("Video track mapping tests passed")
