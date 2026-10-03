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

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
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

let screen = read("Features/Video/VideoPlayerScreen.swift")
    + read("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + read("Features/Video/VideoPlayerScreen+Chrome.swift")
    + read("Features/Video/VideoPlayerScreen+OSD.swift")
    + read("Features/Video/VideoPlayerScreen+Mining.swift")
    + read("Features/Video/VideoPlayerScreen+Opening.swift")
    + read("Features/Video/VideoPlayerScreen+Shortcuts.swift")
let anki = read("Core/AnkiManager.swift")
let ankiView = read("Features/Settings/AnkiView.swift")
let ankiModels = read("Models/Anki.swift")
let exporter = read("Features/Video/Playback/VideoAudioClipExporter.swift")
let animatedExporterHeader = read("Features/Video/Playback/HSMpvAnimatedAVIFExporter.h")
let animatedExporter = read("Features/Video/Playback/HSMpvAnimatedAVIFExporter.mm")
let playbackEngine = read("Features/Video/Playback/PlaybackEngine.swift")
    + read("Features/Video/Playback/VideoTrack.swift")
let mpvEngine = read("Features/Video/Playback/MpvPlayerEngine.swift")
let clientHeader = read("Features/Video/Playback/HSMpvClient.h")
let clientImplementation = read("Features/Video/Playback/HSMpvClient.mm")
let coordinator = read("Features/Video/VideoMiningCoordinator.swift")
let mediaStore = read("Features/Video/VideoMiningMediaStore.swift")
let sasayakiPlayer = read("Features/Sasayaki/SasayakiPlayer.swift")
let mining = read("Features/Popup/AnkiMining.swift")
let popup = read("Features/Popup/PopupView.swift")
let architecture = read("docs/VIDEO_LEARNING_ARCHITECTURE.md")

require(
    screen.contains("let needsScreenshot = AnkiManager.shared.needsVideoScreenshot")
        && screen.contains("let needsAudioClip = AnkiManager.shared.needsVideoAudioClip")
        && screen.contains("captureScreenshot: needsScreenshot")
        && screen.contains("captureAudioClip: needsAudioClip")
        && !screen.contains("captureScreenshot: true")
        && !screen.contains("captureAudioClip: true"),
    "video subtitle mining should capture media requested by shared or legacy Video field mappings"
)
require(
    coordinator.contains("VideoAudioClipRange.resolve(")
        && coordinator.contains("subtitleDelay: snapshot.subtitleDelay")
        && coordinator.contains("duration: snapshot.duration")
        && coordinator.contains("audioClipErrorMessage"),
    "video mining should apply subtitle delay, clamp the clip range, and retain export failures"
)
require(
    mining.contains("needsVideoAudioClip")
        && mining.contains("audioClipURL == nil")
        && mining.contains("audioClipFilename == nil")
        && mining.contains("audioClipErrorMessage"),
    "mapped shared or legacy video audio should fail before AnkiConnect only when neither fallback URL nor direct filename is available"
)
require(
    mining.contains("needsVideoScreenshot")
        && mining.contains("screenshotURL == nil")
        && mining.contains("screenshotFilename == nil")
        && mining.contains("screenshotErrorMessage"),
    "mapped video screenshots should fail before AnkiConnect when capture did not produce usable media"
)
require(
    anki.contains("fieldMappings.values.contains(Handlebars.bookCover.rawValue)")
        && anki.contains("fieldMappings.values.contains(Handlebars.sasayakiAudio.rawValue)")
        && anki.contains("if context.video == nil")
        && anki.contains("videoScreenshotFields.append(field)")
        && anki.contains("videoAudioFields.append(field)"),
    "book-cover and sasayaki-audio must route to Video screenshot and subtitle audio when mining from Video"
)
require(
    mining.contains("func preflightAnkiMining")
        && mining.contains("preflightAlreadyPassed")
        && mining.contains("ProfileRepository.shared.activeProfile.id")
        && !mining.contains("profileID: context.profileID"),
    "Anki mining should preflight the globally active Profile before expensive media capture"
)
require(
    anki.contains("func getMediaDirPath")
        && anki.contains("cachedAnkiMediaDirectories")
        && anki.contains("action: \"getMediaDirPath\"")
        && anki.contains("isWritableFile"),
    "AnkiManager should cache and validate Anki collection.media paths for direct local media writes"
)
require(
    anki.contains("directAudioMarkup(filename:")
        && anki.contains("directImageMarkup(filename:")
        && anki.contains("[sound:\\(")
        && anki.contains("<img src=\\\"\\(")
        && anki.contains("writeDirectMedia"),
    "AnkiManager should write local media directly and put Anki media markup into note fields"
)
require(
    anki.contains("context.video?.audioClipFilename")
        && anki.contains("context.video?.screenshotFilename")
        && anki.contains("context.video?.audioClipURL")
        && anki.contains("context.video?.screenshotURL"),
    "AnkiManager should support direct Video filenames while preserving fallback URL attachments"
)
require(
    coordinator.contains("ankiMediaDirectory:")
        && coordinator.contains("captureScreenshot(to:")
        && coordinator.contains("exportAudioClip(")
        && coordinator.contains("try mediaStore.replaceMediaItem(")
        && coordinator.contains("screenshotFilename = filenames.screenshot")
        && coordinator.contains("audioClipFilename = filenames.audioClip")
        && coordinator.contains("let screenshotReady = await screenshotTask.value")
        && coordinator.contains("let audioReady = await audioTask.value")
        && coordinator.contains("waitForDirectMediaGeneration")
        && coordinator.contains("screenshotErrorMessage = String(")
        && coordinator.contains("audioClipErrorMessage = String("),
    "Video mining should await direct media writes and expose filenames only after the files are ready"
)
require(
    screen.contains("compressScreenshot: AnkiManager.shared.compressImages")
        && screen.contains("imageFormat: AnkiManager.shared.imageCompressionFormat")
        && coordinator.contains("compressScreenshot: Bool")
        && coordinator.contains("imageFormat: AnkiImageCompressionFormat")
        && coordinator.contains("preparedScreenshot("),
    "video mining must receive persisted screenshot compression"
)
require(
    playbackEngine.contains("func captureAnimatedScreenshot(")
        && mpvEngine.contains("HSMpvAnimatedAVIFExporter.exportAnimatedAVIF(")
        && coordinator.contains("quality: screenshotQuality")
        && coordinator.contains("fps: avifFramesPerSecond")
        && coordinator.contains("maximumHeight: avifMaximumHeight")
        && coordinator.contains("imageFormat == .avif")
        && mediaStore.contains("animatedScreenshotURL()")
        && animatedExporterHeader.contains("exportAnimatedAVIFFromURL")
        && animatedExporter.contains("svt_av1_enc_init_handle")
        && animatedExporter.contains("avformat_alloc_output_context2")
        && animatedExporter.contains("\"rawvideo\"")
        && animatedExporter.contains("format=yuv420p10le")
        && animatedExporter.contains("encoder_bit_depth = 10")
        && animatedExporter.contains("intra_period_length = 0")
        && animatedExporter.contains("NSDataReadingMappedIfSafe")
        && animatedExporter.contains("video-out-params/w")
        && animatedExporter.contains("configuration.color_primaries")
        && animatedExporter.contains("endTime = MIN(endTime, startTime + 15.0)")
        && animatedExporter.contains("transpose=clock")
        && !animatedExporter.contains("\"yuv4mpegpipe\"")
        && !animatedExporter.contains("vo-image-format")
        && animatedExporter.contains("\"avif\"")
        && animatedExporter.contains("floor((1.0 - quality) * 63.0)")
        && animatedExporter.contains("stream->avg_frame_rate"),
    "AVIF video cards should stream scaled 10-bit YUV frames from mpv into bundled SVT-AV1 and the AVIF muxer"
)
require(
    ankiView.contains("Audio Compression Format")
        && ankiView.contains("Audio Quality")
        && ankiView.contains("Compress Images")
        && ankiView.contains("Image Quality")
        && ankiView.contains("Image Format")
        && ankiView.contains("AnkiImageCompressionFormat.allCases")
        && ankiView.contains("AVIF Maximum Height")
        && ankiView.contains("AVIF Frame Rate")
        && anki.contains("animatedAVIFMaximumHeight: animatedAVIFMaximumHeight")
        && anki.contains("animatedAVIFFramesPerSecond: animatedAVIFFramesPerSecond")
        && screen.contains("animatedAVIFMaximumHeight: AnkiManager.shared.animatedAVIFMaximumHeight")
        && screen.contains("animatedAVIFFramesPerSecond: AnkiManager.shared.animatedAVIFFramesPerSecond")
        && ankiModels.contains("_h\\(maximumHeight)")
        && ankiModels.contains("_fps\\(framesPerSecond)")
        && ankiView.contains("repeated cards reuse matching media files."),
    "the full app should persist custom AVIF resolution and frame rate without cache collisions"
)
require(
    anki.contains("AnkiMediaProcessor.image(")
        && anki.contains("if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))")
        && sasayakiPlayer.contains("var miningAudioCache:")
        && sasayakiPlayer.contains("if let cached = miningAudioCache[cacheKey]")
        && mediaStore.contains("claimDirectMediaGeneration(at destination:")
        && mediaStore.contains("waitForDirectMediaGeneration(at destination:")
        && mediaStore.contains("directMediaInFlight")
        && coordinator.contains("mediaStore.claimDirectMediaGeneration"),
    "book covers and repeated sentence audio should reuse existing or in-flight Anki media"
)
require(
    coordinator.contains("suspendVideoThumbnailsForMining()")
        && coordinator.contains("resumeVideoThumbnailsForMining()")
        && coordinator.contains("await VideoThumbnailScheduler.shared.suspend(reason: .mining)")
        && coordinator.contains("await VideoThumbnailScheduler.shared.resume(reason: .mining)")
        && coordinator.contains("if captureScreenshot || captureAudioClip"),
    "Video mining should suspend low-priority library thumbnail work during screenshot and audio export"
)
require(
    clientImplementation.contains("@[@\"oac\", @\"pcm_s16le\"]")
        && clientImplementation.contains("@[@\"of\", @\"wav\"]"),
    "video mining should export a lossless intermediate before applying the selected audio bitrate"
)
if let mineEntryRange = popup.range(of: "private func mineEntry("),
   let mineEntryEnd = popup[mineEntryRange.lowerBound...].range(of: "private func showMiningToast")?.lowerBound {
    let mineEntry = popup[mineEntryRange.lowerBound..<mineEntryEnd]
    let preflightIndex = mineEntry.range(of: "preflightAnkiMining(content: content)")?.lowerBound
    let sasayakiIndex = mineEntry.range(of: "cueSentenceAudio")?.lowerBound
    let videoContextIndex = mineEntry.range(of: "miningContextProvider")?.lowerBound
    require(
        preflightIndex != nil
            && sasayakiIndex != nil
            && videoContextIndex != nil
            && preflightIndex! < sasayakiIndex!
            && preflightIndex! < videoContextIndex!,
        "Popup mining should check duplicate/configuration before preparing Sasayaki or Video media"
    )
} else {
    require(false, "Popup mining entry point should be available for preflight ordering checks")
}
require(
    anki.contains("videoAudioFields")
        && anki.contains("videoScreenshotFields")
        && anki.contains("context.video?.audioClipURL")
        && anki.contains("context.video?.screenshotURL")
        && anki.contains("\"audio\"")
        && anki.contains("\"picture\""),
    "AnkiConnect should attach video audio and screenshot media through mapped fields"
)
require(
    mining.contains("let profileID = context.profileID ?? ProfileRepository.shared.activeProfile.id")
        && mining.contains("ProfileRepository.shared.activeProfile.id == profileID")
        && popup.contains("let miningProfileID = profileRepository.activeProfile.id")
        && popup.contains("profileRepository.activeProfile.id == miningProfileID")
        && anki.contains("struct NoteBuildConfiguration")
        && anki.contains("configuration: configuration"),
    "Anki mining must retain one explicit Profile and snapshot its field configuration across asynchronous media and AnkiConnect work"
)
require(
    !ankiView.contains("videoAnimeCardSection")
        && !ankiView.contains("\"Anime Card Fields\"")
        && !ankiView.contains("\"Apply Anime Card Preset\"")
        && !ankiView.contains("applyAnimeCardPreset()")
        && !ankiView.contains("animeCardHandlebar(for:"),
    "Anki settings should not restore the old heuristic anime-card helper section"
)
require(
    ankiView.contains("Apply Defaults")
        && !ankiView.contains("Apply Novel Defaults")
        && !ankiView.contains("Apply Anime Defaults")
        && !ankiView.contains("AnkiFieldMappingPreset"),
    "Anki settings should expose one shared default restore for EPUB and Video"
)
require(
    ankiView.contains(".filter { !hidden.contains($0) }")
        && anki.contains("Handlebars.videoAudioClip.rawValue")
        && anki.contains("Handlebars.videoScreenshot.rawValue"),
    "Video placeholders should remain available through normal field mapping"
)
require(
    !exporter.contains("AVFoundation")
        && exporter.contains("HSMpvAudioClipExporter")
        && exporter.contains("audioTrackID"),
    "video audio export should use the bundled libmpv bridge and selected audio track"
)
require(
    clientHeader.contains("HSMpvAudioClipExporter")
        && clientImplementation.contains("mpv_create()")
        && clientImplementation.contains("audio-channels")
        && clientImplementation.contains("oacopts"),
    "the native bridge should run an isolated bundled-libmpv audio encoder"
)
require(
    architecture.contains("mpvacious-style")
        && architecture.contains("{video-screenshot}")
        && architecture.contains("{video-audio-clip}"),
    "video architecture docs should describe the anime card media-mining flow"
)

print("Video anime mining contract passed")
