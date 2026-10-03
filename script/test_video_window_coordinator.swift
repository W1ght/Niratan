// test-sources: Features/Video/VideoMediaTypes.swift Features/Video/VideoWindowCoordinator.swift Features/Video/Remote/RemoteVideoSource.swift Features/Video/Playback/PlaybackEngine.swift Features/Video/Playback/VideoTrack.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift
import Foundation

nonisolated enum VideoShaderPreset {
    case off
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoWindowCoordinatorTests {
    @MainActor
    static func main() {
        let coordinator = VideoWindowCoordinator()
        let url = URL(fileURLWithPath: "/tmp/Episode 01.mkv")

        let initialSessionID = coordinator.sessionID
        let first = coordinator.requestOpen(url)
        expect(
            coordinator.sessionID != initialSessionID,
            "opening a closed window should create a fresh player session"
        )
        expect(coordinator.pendingRequest == first, "request should become pending")
        coordinator.consume(UUID())
        expect(coordinator.pendingRequest == first, "unrelated consumption must be ignored")
        coordinator.consume(first.id)
        expect(coordinator.pendingRequest == nil, "matching request should be consumed")

        coordinator.windowDidAppear()
        let activeSessionID = coordinator.sessionID
        let second = coordinator.requestOpen(url, startsFromBeginning: true)
        expect(second.id != first.id, "reopening the same path should create a new request")
        expect(second.url == url.standardizedFileURL, "request URL should be standardized")
        expect(
            second.startsFromBeginning,
            "coordinator should preserve an explicit from-beginning intent"
        )
        expect(
            coordinator.sessionID == activeSessionID,
            "replacing media in the visible window should reuse its player session"
        )
        coordinator.windowDidDisappear()
        _ = coordinator.requestOpen(url)
        expect(
            coordinator.sessionID != activeSessionID,
            "reopening after close should replace the shutdown player session"
        )

        expect(VideoMediaTypes.isMediaFile(url), "mkv should be recognized as video media")
        expect(
            VideoMediaTypes.isMediaFile(URL(fileURLWithPath: "/tmp/audio.m4b")),
            "audio-only mpv formats should remain supported"
        )
        expect(
            !VideoMediaTypes.isMediaFile(URL(fileURLWithPath: "/tmp/book.epub")),
            "EPUB must not be routed into the Video window"
        )

        var openGate = VideoWindowOpenGate()
        let queued = VideoWindowOpenRequest(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            url: url
        )
        expect(
            openGate.receive(queued) == nil,
            "an initial external request must wait until the mpv render view is attached"
        )
        expect(
            openGate.renderDidBecomeReady() == queued,
            "render readiness should release the queued initial request exactly once"
        )
        expect(
            openGate.renderDidBecomeReady() == nil,
            "repeated render-ready notifications must not reopen the queued video"
        )

        let replacement = VideoWindowOpenRequest(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            url: url
        )
        expect(
            openGate.receive(replacement) == replacement,
            "requests received after render attachment should open immediately"
        )

        print("Video window coordinator tests passed")
    }
}
