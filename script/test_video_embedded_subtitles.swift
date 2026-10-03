// test-sources: Features/Video/Playback/PlaybackEngine.swift Features/Video/Playback/VideoTrack.swift Features/Video/Subtitles/VideoSubtitleController.swift Features/Video/Remote/RemoteVideoSource.swift Models/Subtitle.swift Features/Video/Subtitles/SubtitleCueStore.swift Features/Video/Subtitles/SubtitleParser.swift Features/Video/Remote/YouTubeURLParser.swift Features/Video/Subtitles/EmbeddedSubtitlePayloadParser.swift
import Foundation

// PlaybackEngine references the Video-only shader preset, but this focused
// subtitle harness intentionally does not compile the Anime4K UI/store.
nonisolated enum VideoShaderPreset {
    case off
}

// The production extractor depends on the Objective-C++ FFmpeg bridge. This
// focused controller harness only needs the immutable result shape.
nonisolated struct ExtractedSubtitleTrack: Sendable {
    let codec: String?
    let cues: [VideoEmbeddedSubtitleCue]
    let reconstructedASSData: Data?

    nonisolated func reconstructedASSData(
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Data? {
        if isCancelled() {
            throw CancellationError()
        }
        return reconstructedASSData
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfter: Int
    private var checks = 0

    init(cancelAfter: Int) {
        self.cancelAfter = cancelAfter
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks >= cancelAfter
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }
}

@main
private enum VideoEmbeddedSubtitleTests {
    @MainActor
    static func main() async {
        let assTrack = VideoTrack(
            id: 3,
            type: .subtitle,
            title: "ASS",
            language: "ja",
            codec: "ass",
            ffIndex: 3,
            externalFilename: nil,
            isImage: false,
            isSelected: true
        )
        let subRipTrack = VideoTrack(
            id: 4,
            type: .subtitle,
            title: "SRT",
            language: "ja",
            codec: "subrip",
            ffIndex: 4,
            externalFilename: nil,
            isImage: false,
            isSelected: false
        )
        let imageTrack = VideoTrack(
            id: 5,
            type: .subtitle,
            title: "PGS",
            language: nil,
            codec: "hdmv_pgs_subtitle",
            ffIndex: 5,
            externalFilename: nil,
            isImage: true,
            isSelected: false
        )
        expect(
            VideoSubtitleRenderingPolicy.initialMode(for: assTrack) == .preparingASS
                && VideoSubtitleRenderingPolicy.initialMode(for: subRipTrack) == .overlayOnly
                && VideoSubtitleRenderingPolicy.initialMode(for: imageTrack) == .nativeOnly,
            "ASS/SSA should stay hidden while ownership is prepared, bitmap tracks should stay native, and ordinary text should keep the overlay"
        )
        expect(
            VideoSubtitleRenderingPolicy.initialMode(
                forSubtitleURL: URL(fileURLWithPath: "/tmp/styled.ASS")
            ) == .preparingASS
                && VideoSubtitleRenderingPolicy.initialMode(
                    forSubtitleURL: URL(fileURLWithPath: "/tmp/plain.srt")
                ) == .overlayOnly,
            "external ASS/SSA should stay hidden until classification completes"
        )
        expect(
            VideoSubtitleRenderingMode.overlayOnly.usesInteractiveOverlay
                && !VideoSubtitleRenderingMode.preparingASS.usesInteractiveOverlay
                && !VideoSubtitleRenderingMode.nativeOnly.usesInteractiveOverlay
                && VideoSubtitleRenderingMode.splitASS(
                    effectsURL: URL(fileURLWithPath: "/tmp/effects.ass"),
                    logicalTrackID: 3
                ).usesInteractiveOverlay,
            "only overlay-owned modes should expose interactive glyph hit targets"
        )

        let controller = VideoSubtitleController()
        let videoURL = URL(fileURLWithPath: "/tmp/Episode 1.mkv")
        controller.loadEmbedded(
            [
                VideoEmbeddedSubtitleCue(
                    id: "embedded-1",
                    startTime: 1,
                    endTime: 2.5,
                    text: "内蔵字幕"
                )
            ],
            sourceURL: videoURL
        )

        expect(
            controller.document?.format == .embedded,
            "embedded cues should use the embedded subtitle source"
        )
        controller.update(time: 1.5)
        expect(
            controller.currentCues.map(\.text) == ["内蔵字幕"],
            "embedded text cues should drive the Hoshi overlay"
        )
        controller.loadEmbedded(
            [
                VideoEmbeddedSubtitleCue(
                    id: "embedded-2",
                    startTime: 3,
                    endTime: 4.5,
                    text: "次の字幕"
                ),
                VideoEmbeddedSubtitleCue(
                    id: "embedded-2-duplicate",
                    startTime: 3,
                    endTime: 4.5,
                    text: "次の字幕"
                )
            ],
            sourceURL: videoURL
        )
        expect(
            controller.transcript.rows.map(\.primaryText) == ["内蔵字幕", "次の字幕"],
            "embedded transcript should merge rolling cue snapshots and deduplicate repeated cues"
        )
        controller.loadEmbedded([], sourceURL: videoURL)
        expect(
            controller.transcript.rows.map(\.primaryText) == ["内蔵字幕", "次の字幕"],
            "empty embedded snapshots between subtitle lines should not clear the transcript list"
        )

        let bilingualController = VideoSubtitleController()
        bilingualController.loadEmbedded(
            [
                VideoEmbeddedSubtitleCue(
                    id: "embedded-primary",
                    startTime: 10,
                    endTime: 12,
                    text: "主字幕"
                )
            ],
            sourceURL: videoURL
        )
        bilingualController.loadEmbedded(
            [
                VideoEmbeddedSubtitleCue(
                    id: "embedded-primary-bilingual",
                    startTime: 10,
                    endTime: 12,
                    text: "主字幕\nSecondary subtitle"
                )
            ],
            sourceURL: videoURL
        )
        expect(
            bilingualController.transcript.rows.map(\.primaryText) == ["主字幕"],
            "embedded current snapshots that merge primary and secondary subtitles should not duplicate transcript rows"
        )

        let reversedBilingualController = VideoSubtitleController()
        reversedBilingualController.loadEmbedded(
            [
                VideoEmbeddedSubtitleCue(
                    id: "embedded-primary-bilingual",
                    startTime: 14,
                    endTime: 16,
                    text: "主字幕\nSecondary subtitle"
                )
            ],
            sourceURL: videoURL
        )
        reversedBilingualController.loadEmbedded(
            [
                VideoEmbeddedSubtitleCue(
                    id: "embedded-primary",
                    startTime: 14,
                    endTime: 16,
                    text: "主字幕"
                )
            ],
            sourceURL: videoURL
        )
        expect(
            reversedBilingualController.transcript.rows.map(\.primaryText) == ["主字幕"],
            "embedded bilingual snapshot deduplication should not depend on arrival order"
        )

        let overlappingTextController = VideoSubtitleController()
        overlappingTextController.loadEmbedded(
            [
                VideoEmbeddedSubtitleCue(
                    id: "embedded-short",
                    startTime: 18,
                    endTime: 20,
                    text: "he"
                ),
                VideoEmbeddedSubtitleCue(
                    id: "embedded-long",
                    startTime: 18,
                    endTime: 20,
                    text: "the subtitle"
                )
            ],
            sourceURL: videoURL
        )
        expect(
            overlappingTextController.transcript.rows.map(\.primaryText) == ["he", "the subtitle"],
            "same-timing subtitles should not deduplicate merely because one text contains another"
        )

        let roundedTimingController = VideoSubtitleController()
        roundedTimingController.loadEmbedded(
            [
                VideoEmbeddedSubtitleCue(
                    id: "rounded-primary",
                    startTime: 22.0004,
                    endTime: 24.0004,
                    text: "丸め字幕"
                ),
                VideoEmbeddedSubtitleCue(
                    id: "rounded-bilingual",
                    startTime: 22.00049,
                    endTime: 24.00049,
                    text: "丸め字幕\nRounded subtitle"
                ),
                VideoEmbeddedSubtitleCue(
                    id: "next-millisecond",
                    startTime: 22.0006,
                    endTime: 24.0006,
                    text: "丸め字幕"
                )
            ],
            sourceURL: videoURL
        )
        expect(
            roundedTimingController.transcript.rows.count == 2,
            "embedded deduplication should preserve millisecond rounding semantics"
        )

        if let realASSPath = ProcessInfo.processInfo.environment["HOSHI_REAL_ASS_PATH"],
           !realASSPath.isEmpty {
            let realASSController = VideoSubtitleController()
            let realASSURL = URL(fileURLWithPath: realASSPath)
            let loadTask = realASSController.load(realASSURL)
            await loadTask.value
            expect(
                realASSController.document?.format == .ass,
                "real ASS import should create an ASS subtitle document"
            )
            expect(
                !realASSController.transcript.rows.isEmpty,
                "real ASS import should populate the transcript"
            )
            if let firstCue = realASSController.document?.cues.first {
                realASSController.update(time: firstCue.startTime)
                expect(
                    realASSController.currentCues.contains(firstCue),
                    "real ASS import should drive current overlay cues"
                )
            }
        }

        controller.beginEmbeddedTrack(trackID: 4, sourceURL: videoURL)
        expect(
            controller.transcript.rows.isEmpty,
            "switching embedded tracks should immediately clear the previous transcript"
        )
        expect(
            controller.isTranscriptLoading,
            "switching embedded tracks should expose a transcript loading state"
        )
        let completeTrackLoad = await Task.detached {
            VideoSubtitleController.prepareEmbeddedTranscript(
                [
                    VideoEmbeddedSubtitleCue(
                        id: "track-4-1",
                        startTime: 25,
                        endTime: 28.74,
                        text: "今度の中間テスト"
                    )
                ],
                sourceURL: videoURL
            )
        }.value
        controller.replaceEmbeddedTranscript(
            completeTrackLoad,
            trackID: 4
        )
        expect(
            controller.transcript.rows.map(\.primaryText) == ["今度の中間テスト"],
            "a complete embedded extraction should replace the transcript for the selected track"
        )
        expect(
            !controller.isTranscriptLoading,
            "a complete embedded extraction should finish the loading state"
        )

        let completeTranscriptToken = controller.transcript.changeToken
        controller.loadEmbedded(
            [
                VideoEmbeddedSubtitleCue(
                    id: "live-after-complete",
                    startTime: 25,
                    endTime: 28.74,
                    text: "实时字幕不应重建完整时间线"
                )
            ],
            sourceURL: videoURL
        )
        expect(
            controller.transcript.changeToken == completeTranscriptToken
                && controller.transcript.rows.map(\.primaryText) == ["今度の中間テスト"],
            "live subtitle callbacks should not rebuild an installed complete timeline"
        )

        let staleTrackLoad = await Task.detached {
            VideoSubtitleController.prepareEmbeddedTranscript(
                [
                    VideoEmbeddedSubtitleCue(
                        id: "stale-track",
                        startTime: 1,
                        endTime: 2,
                        text: "旧轨道"
                    )
                ],
                sourceURL: videoURL
            )
        }.value
        controller.replaceEmbeddedTranscript(
            staleTrackLoad,
            trackID: 3
        )
        expect(
            controller.transcript.rows.map(\.primaryText) == ["今度の中間テスト"],
            "a stale extraction must not overwrite the newly selected subtitle track"
        )

        let largeCueCount = 8_432
        let largeEmbeddedCues = (0..<largeCueCount).map { index in
            let timingGroup = index % 1_808
            let startTime = Double(timingGroup) * 1.25
            return VideoEmbeddedSubtitleCue(
                id: "large-\(index)",
                startTime: startTime,
                endTime: startTime + 1,
                text: "字幕イベント \(index) / timing \(timingGroup)"
            )
        }
        let cancellation = CancellationProbe(cancelAfter: 330)
        var didCancelPreparation = false
        do {
            _ = try VideoSubtitleController.prepareEmbeddedTranscript(
                Array(largeEmbeddedCues.prefix(300)),
                sourceURL: videoURL,
                isCancelled: { cancellation.isCancelled() }
            )
        } catch is CancellationError {
            didCancelPreparation = true
        } catch {
            fputs("FAIL: cancellable embedded preparation threw \(error)\n", stderr)
            exit(1)
        }
        expect(
            didCancelPreparation && cancellation.checkCount == 330,
            "embedded transcript preparation should observe cancellation inside deduplication"
        )

        let preparationStart = Date()
        let largeLoad = await Task.detached {
            VideoSubtitleController.prepareEmbeddedTranscript(
                largeEmbeddedCues,
                sourceURL: videoURL
            )
        }.value
        let preparationDuration = Date().timeIntervalSince(preparationStart)
        expect(
            largeLoad.transcript.rows.count == largeCueCount,
            "large embedded subtitle preparation should preserve unique cues"
        )
        expect(
            preparationDuration < 2,
            "8k embedded subtitle preparation should remain near-linear (took \(preparationDuration)s)"
        )

        let externalURL = URL(fileURLWithPath: "/tmp/external.srt")
        let external = """
        1
        00:00:01,000 --> 00:00:03,000
        外掛字幕
        """
        try! external.write(to: externalURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: externalURL)
        }
        let externalLoad = controller.load(externalURL)
        await externalLoad.value
        controller.loadEmbedded(
            [
                VideoEmbeddedSubtitleCue(
                    id: "embedded-2",
                    startTime: 1,
                    endTime: 3,
                    text: "不应覆盖"
                )
            ],
            sourceURL: videoURL
        )
        controller.update(time: 2)
        expect(
            controller.currentCues.map(\.text) == ["外掛字幕"],
            "embedded updates should not replace an active external subtitle"
        )

        print("Video embedded subtitle tests passed")
    }
}
