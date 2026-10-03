// test-sources: Features/Video/Remote/RemotePlaybackSession.swift Features/Video/Remote/RemoteVideoSource.swift Features/Video/Remote/RemoteVideoResolver.swift Features/Video/Playback/PlaybackEngine.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift Features/Video/Playback/VideoTrack.swift Features/Video/Playback/VideoShaderPreset.swift
import Foundation

private actor ResolverRecorder {
    private var sources: [ResolvedRemoteVideoSource]
    private(set) var forceRefreshValues: [Bool] = []

    init(sources: [ResolvedRemoteVideoSource]) {
        self.sources = sources
    }

    func resolve(
        identity: RemoteVideoIdentity,
        preferredSubtitleLanguages: [String],
        forceRefresh: Bool
    ) throws -> ResolvedRemoteVideoSource {
        forceRefreshValues.append(forceRefresh)
        guard !sources.isEmpty else {
            throw RemoteVideoResolverError.noPlayableStream
        }
        return sources.removeFirst()
    }

    func calls() -> [Bool] {
        forceRefreshValues
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func source(
    suffix: String,
    expiresAt: Date? = Date().addingTimeInterval(600),
    includesFallback: Bool = true,
    selectedHeight: Int = 1080
) -> ResolvedRemoteVideoSource {
    let headers = ["User-Agent": "HoshiTests"]
    let audioStream = RemoteVideoStream(
        url: URL(string: "https://cdn.example/audio-\(suffix).m4a")!,
        formatID: "audio-\(suffix)",
        hasVideo: false,
        hasAudio: true,
        httpHeaders: headers
    )
    let qualityOptions = [1080, 720].map { height in
        RemoteVideoQualityOption(
            id: "video-\(height)-\(suffix)",
            height: height,
            playbackStream: RemoteVideoStream(
                url: URL(string: "https://cdn.example/video-\(height)-\(suffix).mp4")!,
                formatID: "video-\(height)-\(suffix)",
                height: height,
                hasVideo: true,
                hasAudio: false,
                httpHeaders: headers
            ),
            audioStream: audioStream
        )
    }
    let resolved = ResolvedRemoteVideoSource(
        identity: RemoteVideoIdentity(
            providerID: "youtube",
            remoteID: "fixture",
            originalURL: URL(string: "https://video.example/watch/fixture")!,
            canonicalURL: nil,
            title: "Fixture",
            thumbnailURL: nil
        ),
        playbackStream: RemoteVideoStream(
            url: URL(string: "https://cdn.example/video-1080-\(suffix).mp4")!,
            formatID: "video-1080-\(suffix)",
            height: 1080,
            hasVideo: true,
            hasAudio: false,
            httpHeaders: headers
        ),
        audioStream: audioStream,
        muxedFallbackStream: includesFallback ? RemoteVideoStream(
            url: URL(string: "https://cdn.example/muxed-\(suffix).mp4")!,
            formatID: "muxed-\(suffix)",
            height: 720,
            hasVideo: true,
            hasAudio: true,
            httpHeaders: headers
        ) : nil,
        miningStream: nil,
        subtitleOptions: [],
        selectedSubtitleLanguage: nil,
        resolvedAt: Date(),
        expiresAt: expiresAt,
        qualityOptions: qualityOptions
    )
    return resolved.selectingQuality(height: selectedHeight)!
}

@main
private enum VideoRemotePlaybackSessionTests {
    static func main() async throws {
        try await testFreshSourceIsReusedWithoutResolving()
        try await testExpiredSourceForcesOneRefresh()
        try await testRefreshPreservesSelectedQuality()
        try await testInitialLoadFailureRefreshesAndPreservesResumeTime()
        try await testAudioFailureRefreshesThenFallsBackOnce()
        try await testFailureAfterMuxedFallbackIsTerminal()
        try await testStaleGenerationIsIgnored()
        print("Video remote playback session tests passed")
    }

    private static func session(
        initial: ResolvedRemoteVideoSource,
        refreshed: [ResolvedRemoteVideoSource]
    ) -> (RemotePlaybackSession, ResolverRecorder) {
        let recorder = ResolverRecorder(sources: refreshed)
        return (
            RemotePlaybackSession(
                source: initial,
                preferredSubtitleLanguages: ["ja"]
            ) { identity, preferredLanguages, forceRefresh in
                try await recorder.resolve(
                    identity: identity,
                    preferredSubtitleLanguages: preferredLanguages,
                    forceRefresh: forceRefresh
                )
            },
            recorder
        )
    }

    private static func testFreshSourceIsReusedWithoutResolving() async throws {
        let initial = source(suffix: "fresh")
        let (session, recorder) = session(initial: initial, refreshed: [])
        let preparation = await session.prepare(now: Date())

        guard case .play(let attempt) = preparation else {
            expect(false, "a fresh source should be playable")
            return
        }
        expect(attempt.source == initial, "fresh preparation should reuse the current source")
        let calls = await recorder.calls()
        expect(calls.isEmpty, "fresh preparation should not call the resolver")
    }

    private static func testExpiredSourceForcesOneRefresh() async throws {
        let refreshed = source(suffix: "refreshed")
        let (session, recorder) = session(
            initial: source(suffix: "expired", expiresAt: Date().addingTimeInterval(-1)),
            refreshed: [refreshed]
        )
        let preparation = await session.prepare(now: Date())

        guard case .play(let attempt) = preparation else {
            expect(false, "an expired source should refresh")
            return
        }
        expect(attempt.source == refreshed, "expired preparation should use the refreshed source")
        let calls = await recorder.calls()
        expect(calls == [true], "expiry should force exactly one resolution")
    }

    private static func testRefreshPreservesSelectedQuality() async throws {
        let (session, _) = session(
            initial: source(
                suffix: "expired-720",
                expiresAt: Date().addingTimeInterval(-1),
                selectedHeight: 720
            ),
            refreshed: [source(suffix: "refreshed-quality")]
        )
        guard case .play(let attempt) = await session.prepare(now: Date()) else {
            expect(false, "expired selected quality should refresh")
            return
        }
        expect(
            attempt.source.playbackStream.height == 720,
            "forced refresh should retain the user's selected YouTube quality"
        )
    }

    private static func testInitialLoadFailureRefreshesAndPreservesResumeTime() async throws {
        let refreshed = source(suffix: "retry")
        let (session, recorder) = session(initial: source(suffix: "initial"), refreshed: [refreshed])
        guard case .play(let initialAttempt) = await session.prepare() else {
            expect(false, "initial source should prepare")
            return
        }
        let recovery = await session.recover(
            from: .remoteLoadFailed,
            generation: initialAttempt.generation,
            resumeTime: 42
        )

        guard case .retry(let attempt) = recovery else {
            expect(false, "initial load failure should retry")
            return
        }
        expect(attempt.source == refreshed, "load failure should use a refreshed source")
        expect(attempt.resumeTime == 42, "load failure should preserve the resume time")
        let calls = await recorder.calls()
        expect(calls == [true], "load failure should force exactly one resolution")
    }

    private static func testAudioFailureRefreshesThenFallsBackOnce() async throws {
        let refreshed = source(suffix: "audio-refresh")
        let (session, recorder) = session(initial: source(suffix: "initial"), refreshed: [refreshed])
        guard case .play(let initialAttempt) = await session.prepare() else {
            expect(false, "initial source should prepare")
            return
        }

        let firstRecovery = await session.recover(
            from: .externalAudioUnavailable,
            generation: initialAttempt.generation,
            resumeTime: 17
        )
        guard case .retry(let refreshedAttempt) = firstRecovery else {
            expect(false, "first audio failure should refresh")
            return
        }
        expect(refreshedAttempt.source == refreshed, "first audio retry should use refreshed URLs")
        let refreshCalls = await recorder.calls()
        expect(refreshCalls == [true], "audio recovery should refresh only once")

        let secondRecovery = await session.recover(
            from: .externalAudioUnavailable,
            generation: refreshedAttempt.generation,
            resumeTime: 18
        )
        guard case .retry(let fallbackAttempt) = secondRecovery else {
            expect(false, "audio failure after refresh should use the muxed fallback")
            return
        }
        expect(fallbackAttempt.source.audioStream == nil, "muxed fallback should remove external audio")
        expect(fallbackAttempt.source.playbackStream.hasAudio, "muxed fallback should contain audio")
        expect(
            fallbackAttempt.source.playbackStream.formatID == "muxed-audio-refresh",
            "the selected fallback should be the refreshed muxed stream"
        )
        expect(fallbackAttempt.resumeTime == 18, "fallback should preserve the latest resume time")
        let fallbackCalls = await recorder.calls()
        expect(fallbackCalls == [true], "fallback must not run a second forced resolution")
    }

    private static func testFailureAfterMuxedFallbackIsTerminal() async throws {
        let refreshed = source(suffix: "terminal")
        let (session, _) = session(initial: source(suffix: "initial"), refreshed: [refreshed])
        guard case .play(let initialAttempt) = await session.prepare(),
              case .retry(let refreshedAttempt) = await session.recover(
                from: .externalAudioUnavailable,
                generation: initialAttempt.generation,
                resumeTime: 0
              ),
              case .retry(let fallbackAttempt) = await session.recover(
                from: .externalAudioUnavailable,
                generation: refreshedAttempt.generation,
                resumeTime: 0
              ) else {
            expect(false, "fixture should reach muxed fallback")
            return
        }

        let terminal = await session.recover(
            from: .audioUnavailable,
            generation: fallbackAttempt.generation,
            resumeTime: 0
        )
        expect(terminal == .terminal(.audioUnavailable), "fallback failure should be terminal")
    }

    private static func testStaleGenerationIsIgnored() async throws {
        let refreshed = source(suffix: "generation")
        let (session, recorder) = session(initial: source(suffix: "initial"), refreshed: [refreshed])
        guard case .play(let initialAttempt) = await session.prepare(),
              case .retry = await session.recover(
                from: .remoteLoadFailed,
                generation: initialAttempt.generation,
                resumeTime: 0
              ) else {
            expect(false, "fixture should refresh once")
            return
        }

        let stale = await session.recover(
            from: .externalAudioUnavailable,
            generation: initialAttempt.generation,
            resumeTime: 0
        )
        expect(stale == .ignored, "a completion from an old generation should be ignored")
        let calls = await recorder.calls()
        expect(calls == [true], "stale recovery must not resolve again")
    }
}
