// test-sources: Features/Video/Remote/RemoteVideoSource.swift Features/Video/VideoWindowCoordinator.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift Features/Video/Playback/PlaybackEngine.swift Features/Video/Playback/VideoTrack.swift
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
private enum VideoWindowOpenRequestTests {
    @MainActor
    static func main() {
        let videoURL = URL(fileURLWithPath: "/tmp/Episode.mkv")
        let subtitleURL = URL(fileURLWithPath: "/tmp/Episode.ja.srt")

        let coordinator = VideoWindowCoordinator()
        let request = coordinator.requestOpen(
            videoURL,
            subtitleURL: subtitleURL,
            startsFromBeginning: true
        )

        expect(request.url == videoURL.standardizedFileURL, "request should standardize video URL")
        expect(request.subtitleURL == subtitleURL.standardizedFileURL, "request should carry bound subtitle URL")
        expect(request.startsFromBeginning, "request should carry the from-beginning intent")
        expect(coordinator.pendingRequest == request, "coordinator should publish the pending request")

        var gate = VideoWindowOpenGate()
        expect(gate.receive(request) == nil, "gate should hold requests until render is ready")
        expect(
            gate.renderDidBecomeReady()?.subtitleURL == subtitleURL.standardizedFileURL,
            "gate should release the pending subtitle request when render becomes ready"
        )

        let remoteIdentity = RemoteVideoIdentity(
            providerID: "youtube",
            remoteID: "immediate-open",
            originalURL: URL(string: "https://www.youtube.com/watch?v=immediate-open")!,
            canonicalURL: nil,
            title: "Immediate Open",
            thumbnailURL: nil
        )
        let remoteRequest = RemoteVideoWindowOpenRequest(
            identity: remoteIdentity,
            preferredSubtitleLanguages: ["ja"],
            forceRefresh: true,
            startsFromBeginning: true
        )
        let queuedRemote = coordinator.requestOpen(remoteRequest: remoteRequest)
        expect(
            queuedRemote.source == .unresolvedRemote(remoteRequest),
            "remote opens should enter the window before stream resolution"
        )
        expect(
            queuedRemote.url == remoteIdentity.originalURL,
            "remote open requests should expose their durable page URL"
        )
        expect(
            queuedRemote.startsFromBeginning,
            "remote open requests should retain their from-beginning intent"
        )

        print("Video window open request tests passed")
    }
}
