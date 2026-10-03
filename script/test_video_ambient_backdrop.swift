// test-sources: Features/Video/Playback/PlaybackEngine.swift Features/Video/VideoAmbientBackdropModel.swift Features/Video/VideoAmbientBackdrop.swift Features/Video/Playback/VideoTrack.swift Features/Video/Remote/RemoteVideoSource.swift Features/Video/Playback/VideoShaderPreset.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift
import AppKit
import Foundation

@MainActor
private final class FakeAmbientPlaybackEngine: PlaybackEngine {
    var snapshot = VideoPlaybackSnapshot()
    var onSnapshotChanged: ((VideoPlaybackSnapshot) -> Void)?
    var captureCount = 0
    var previewGeneration = 0
    var captureDelayNanoseconds: UInt64 = 0

    func load(source: VideoPlaybackSource) throws {}
    func play() {}
    func pause() {}
    func seek(to time: TimeInterval) {}
    func setSpeed(_ speed: Double) {}
    func setVolume(_ volume: Double) {}
    func setMuted(_ muted: Bool) {}
    func setSubtitleDelay(_ delay: TimeInterval) {}
    func selectTrack(type: VideoTrackType, id: Int?) {}
    func shutdown() {}

    func captureAmbientPreview(maximumDimension: Int) async -> VideoAmbientPreview? {
        captureCount += 1
        if captureDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: captureDelayNanoseconds)
        }
        return VideoAmbientPreview(
            image: NSImage(size: NSSize(width: maximumDimension, height: 180)),
            generation: previewGeneration
        )
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct VideoAmbientBackdropTests {
    @MainActor
    static func main() async {
        let windowed = VideoAmbientPresentation.resolve(isFullScreen: false)
        require(!windowed.usesBlurredLetterbox, "windowed playback should not blur the current video into its letterbox")
        require(windowed.workspaceCornerRadius == 0, "windowed playback should not add a rounded ambient workspace")

        let fullScreen = VideoAmbientPresentation.resolve(isFullScreen: true)
        require(!fullScreen.usesBlurredLetterbox, "full screen should keep pure black letterboxing without ambient blur")
        require(fullScreen.workspaceCornerRadius == 0, "full screen should remove the workspace corner radius")

        let engine = FakeAmbientPlaybackEngine()
        let model = VideoAmbientBackdropModel()
        engine.previewGeneration = 1
        model.reset(for: 1)
        model.refresh(
            reason: .playback,
            engine: engine,
            generation: 1,
            isLoaded: true,
            isPlaying: true,
            isActive: true,
            isFullScreen: false,
            now: 10
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        require(engine.captureCount == 1, "active playback should capture its first ambient preview")
        require(model.image != nil, "a current-generation preview should become the ambient image")

        model.refresh(
            reason: .playback,
            engine: engine,
            generation: 1,
            isLoaded: true,
            isPlaying: true,
            isActive: true,
            isFullScreen: false,
            now: 11
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        require(engine.captureCount == 1, "playback previews should be throttled for three seconds")

        model.refresh(
            reason: .playback,
            engine: engine,
            generation: 1,
            isLoaded: true,
            isPlaying: true,
            isActive: true,
            isFullScreen: false,
            now: 13.1
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        require(engine.captureCount == 2, "playback should refresh after the throttle interval")

        engine.previewGeneration = 2
        engine.captureDelayNanoseconds = 80_000_000
        model.reset(for: 2)
        model.refresh(
            reason: .load,
            engine: engine,
            generation: 2,
            isLoaded: true,
            isPlaying: false,
            isActive: true,
            isFullScreen: false
        )
        model.refresh(
            reason: .seek,
            engine: engine,
            generation: 2,
            isLoaded: true,
            isPlaying: false,
            isActive: true,
            isFullScreen: false
        )
        try? await Task.sleep(nanoseconds: 120_000_000)
        require(engine.captureCount == 3, "ambient preview requests must not overlap")

        engine.captureDelayNanoseconds = 0
        engine.previewGeneration = 2
        model.reset(for: 3)
        model.refresh(
            reason: .load,
            engine: engine,
            generation: 3,
            isLoaded: true,
            isPlaying: false,
            isActive: true,
            isFullScreen: false
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        require(model.image == nil, "a stale media-generation preview must be discarded")

        engine.previewGeneration = 4
        model.reset(for: 4)
        model.refresh(
            reason: .load,
            engine: engine,
            generation: 4,
            isLoaded: true,
            isPlaying: false,
            isActive: true,
            isFullScreen: true
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        require(engine.captureCount == 5, "full screen should request an ambient preview")
        require(model.image != nil, "a full-screen ambient preview should become the ambient image")

        print("Video ambient backdrop tests passed")
    }
}
