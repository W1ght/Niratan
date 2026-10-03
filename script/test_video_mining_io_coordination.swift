// test-sources: Features/Video/Playback/PlaybackEngine.swift Features/Video/Playback/VideoTrack.swift Features/Video/Remote/RemoteVideoSource.swift Models/Subtitle.swift Features/Video/VideoMiningCoordinator.swift Features/Video/VideoMiningMediaStore.swift Features/Video/Remote/YouTubeURLParser.swift Models/Anki.swift Features/Popup/MiningContextSelection.swift Features/Video/VideoAudioClipRange.swift Features/Video/VideoMiningSelectionResolution.swift Features/Video/VideoMiningMediaStore+Audio.swift Core/AnkiMediaProcessor.swift Core/AnkiAudioCompressor.swift
// test-modules: SwiftLAME LAME
import AppKit
import AVFAudio
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

enum VideoThumbnailSuspendReason: Hashable, Sendable {
    case mining
}

enum VideoShaderPreset {
    case off
}

actor VideoThumbnailScheduler {
    static let shared = VideoThumbnailScheduler()

    private var suspensionCount = 0
    private var events: [String] = []

    func suspend(reason: VideoThumbnailSuspendReason) {
        suspensionCount += 1
        events.append("suspend")
    }

    func resume(reason: VideoThumbnailSuspendReason) {
        suspensionCount = max(0, suspensionCount - 1)
        events.append("resume")
    }

    func isSuspended() -> Bool {
        suspensionCount > 0
    }

    func eventLog() -> [String] {
        events
    }
}

@MainActor
private final class DelayedMediaEngine: PlaybackEngine {
    var snapshot = VideoPlaybackSnapshot(duration: 30)
    var onSnapshotChanged: ((VideoPlaybackSnapshot) -> Void)?
    var onError: ((String) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onEmbeddedSubtitleCuesChanged: (([VideoEmbeddedSubtitleCue]) -> Void)?

    private let delay: Duration

    init(delay: Duration = .milliseconds(250)) {
        self.delay = delay
    }

    func load(source: VideoPlaybackSource) throws {}
    func play() {}
    func pause() {}
    func seek(to time: TimeInterval) {}
    func setSpeed(_ speed: Double) {}
    func setVolume(_ volume: Double) {}
    func setMuted(_ muted: Bool) {}
    func setSubtitleDelay(_ delay: TimeInterval) {}
    func setAudioDelay(_ delay: TimeInterval) {}
    func setLoopMode(_ mode: VideoLoopMode) {}
    func setABLoop(_ loop: VideoABLoop?) {}
    func setAspectRatio(_ aspectRatio: VideoAspectRatio) {}
    func setRotation(_ degrees: Int) {}
    func setHardwareDecodingEnabled(_ enabled: Bool) {}
    func setDeinterlacingEnabled(_ enabled: Bool) {}
    func setHDREnhancementEnabled(_ enabled: Bool) {}
    func setVideoEqualizer(_ adjustment: VideoEqualizerAdjustment, value: Double) {}
    func seekToChapter(_ index: Int) {}
    func captureAmbientPreview(maximumDimension: Int) async -> VideoAmbientPreview? { nil }
    func loadExternalSubtitle(url: URL) {}
    func selectTrack(type: VideoTrackType, id: Int?) {}
    func shutdown() {}

    func captureScreenshot(to url: URL) async throws {
        try await Task.sleep(for: delay)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        memset(bitmap.bitmapData!, 0x7f, bitmap.bytesPerRow * bitmap.pixelsHigh)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    func exportAudioClip(from start: TimeInterval, to end: TimeInterval, to url: URL) async throws {
        try await Task.sleep(for: delay)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
        buffer.frameLength = 4_410
        try file.write(from: buffer)
    }
}

@main
private enum VideoMiningIOCoordinationTests {
    @MainActor
    static func main() async {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("hoshi-video-mining-io-\(UUID().uuidString)", isDirectory: true)
        let ankiMediaDirectory = root.appendingPathComponent("collection.media", isDirectory: true)
        try? fileManager.createDirectory(at: ankiMediaDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let videoURL = root.appendingPathComponent("Episode 1.mp4")
        try? Data("video identity".utf8).write(to: videoURL)
        let cue = SubtitleCue(id: "cue-1", startTime: 3, endTime: 4, text: "星を見ています。")
        let document = SubtitleDocument(
            sourceURL: root.appendingPathComponent("Episode 1.srt"),
            format: .srt,
            cues: [cue],
            warnings: []
        )

        let localExportSource = VideoPlaybackSource.localFile(videoURL)
            .audioExportSource(selectedAudioTrackID: 7)
        expect(localExportSource?.url == videoURL.standardizedFileURL, "local export should use its file URL")
        expect(localExportSource?.httpHeaders.isEmpty == true, "local export should not invent HTTP headers")
        expect(localExportSource?.audioTrackID == 7, "local export should preserve selected track id")

        let remoteIdentity = RemoteVideoIdentity(
            providerID: "youtube",
            remoteID: "mining-export",
            originalURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!,
            canonicalURL: nil,
            title: "Remote Export",
            thumbnailURL: nil
        )
        let remoteMiningStream = RemoteVideoStream(
            url: URL(string: "https://cdn.example/mining-export.mp4")!,
            hasVideo: true,
            hasAudio: true,
            httpHeaders: ["Referer": "https://www.youtube.com/"]
        )
        let remoteResolved = ResolvedRemoteVideoSource(
            identity: remoteIdentity,
            playbackStream: RemoteVideoStream(
                url: URL(string: "https://cdn.example/video-only.mp4")!,
                hasVideo: true,
                hasAudio: false
            ),
            audioStream: nil,
            miningStream: remoteMiningStream,
            subtitleOptions: [],
            selectedSubtitleLanguage: nil,
            resolvedAt: Date(),
            expiresAt: nil
        )
        let remoteExportSource = VideoPlaybackSource.remoteStream(remoteResolved)
            .audioExportSource(selectedAudioTrackID: 9)
        expect(remoteExportSource?.url == remoteMiningStream.url, "remote export should use a real HTTPS media stream")
        expect(remoteExportSource?.httpHeaders == remoteMiningStream.httpHeaders, "remote export should retain stream headers")
        expect(remoteExportSource?.audioTrackID == nil, "remote direct stream should not reuse mpv track ids")

        let start = Date()
        let context = await VideoMiningCoordinator.context(
            cue: cue,
            document: document,
            videoURL: videoURL,
            videoTitle: "Episode Display Title",
            mediaIdentity: .localFile(path: videoURL.standardizedFileURL.path),
            engine: DelayedMediaEngine(),
            captureScreenshot: true,
            compressScreenshot: true,
            captureAudioClip: true,
            ankiMediaDirectory: ankiMediaDirectory,
            mediaStore: VideoMiningMediaStore(fileManager: fileManager)
        )
        let elapsed = Date().timeIntervalSince(start)

        guard let screenshotFilename = context.video?.screenshotFilename,
              let audioFilename = context.video?.audioClipFilename else {
            fputs("FAIL: direct media context should expose deterministic Anki media filenames\n", stderr)
            exit(1)
        }

        let screenshotURL = ankiMediaDirectory.appendingPathComponent(screenshotFilename)
        let audioURL = ankiMediaDirectory.appendingPathComponent(audioFilename)
        // Since 1.5.6 the card waits for its media, so Anki never receives a
        // reference to a file that is still being written.
        expect(
            elapsed >= 0.25,
            "direct media context should wait for the delayed capture and export"
        )
        expect(
            fileManager.fileExists(atPath: screenshotURL.path(percentEncoded: false)),
            "direct screenshot should be written before the context is returned"
        )
        expect(
            fileManager.fileExists(atPath: audioURL.path(percentEncoded: false)),
            "direct audio should be written before the context is returned"
        )

        try? await Task.sleep(for: .seconds(1))
        let suspendedAfterGeneration = await VideoThumbnailScheduler.shared.isSuspended()
        let schedulerEvents = await VideoThumbnailScheduler.shared.eventLog()
        expect(
            fileManager.fileExists(atPath: screenshotURL.path(percentEncoded: false)),
            "direct screenshot file should eventually be written while thumbnails are suspended"
        )
        expect(screenshotFilename.hasSuffix(".jpg"), "compressed direct image name")
        guard let screenshotData = try? Data(contentsOf: screenshotURL) else {
            fputs("FAIL: compressed direct image data could not be read\n", stderr)
            exit(1)
        }
        expect(
            screenshotData.starts(with: [0xFF, 0xD8]),
            "compressed direct image data"
        )
        expect(
            fileManager.fileExists(atPath: audioURL.path(percentEncoded: false)),
            "direct audio file should eventually be written while thumbnails are suspended"
        )
        expect(
            !suspendedAfterGeneration,
            "video thumbnails should resume after direct media generation finishes"
        )
        expect(
            schedulerEvents == ["suspend", "resume"],
            "direct media generation should use one thumbnail suspension window"
        )

        print("Video mining IO coordination tests passed")
    }
}
