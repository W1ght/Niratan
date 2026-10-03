// test-sources: Features/Video/Remote/RemoteVideoSource.swift Models/Subtitle.swift Features/Video/VideoMiningHistoryStore.swift Features/Video/VideoMiningHistoryNavigation.swift Features/Video/Remote/YouTubeURLParser.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoMiningHistoryTests {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-video-mining-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appendingPathComponent("Episode 1.mkv")
        let subtitleURL = directory.appendingPathComponent("Episode 1.ja.srt")
        try Data().write(to: videoURL)
        try Data().write(to: subtitleURL)

        let document = SubtitleDocument(
            sourceURL: subtitleURL,
            format: .srt,
            cues: [],
            warnings: []
        )
        let earlierCue = SubtitleCue(
            id: "earlier",
            startTime: 65.25,
            endTime: 68.5,
            text: "星を見ています。"
        )
        let laterCue = SubtitleCue(
            id: "later",
            startTime: 67,
            endTime: 70,
            text: "きれいですね。"
        )

        let fileURL = directory.appendingPathComponent("history.json")
        let store = VideoMiningHistoryStore(fileURL: fileURL, limit: 2)
        let firstID = store.record(
            id: "first",
            cues: [laterCue, earlierCue],
            document: document,
            videoURL: videoURL,
            embeddedSubtitleTrackID: nil,
            date: Date(timeIntervalSince1970: 100)
        )

        expect(firstID == "first", "record should return its id")
        expect(store.items.count == 1, "record should append one item")
        expect(
            store.items[0].subtitleText == "星を見ています。\nきれいですね。",
            "overlapping cues should merge in display order"
        )
        expect(store.items[0].cueStart == 65.25, "merged cue should use earliest start")
        expect(store.items[0].cueEnd == 70, "merged cue should use latest end")
        expect(store.items[0].videoPath == videoURL.standardizedFileURL.path, "video path should persist")
        expect(store.items[0].subtitleSourceName == "Episode 1.ja.srt", "subtitle source name should persist")
        expect(
            store.items[0].subtitleSourcePath == subtitleURL.standardizedFileURL.path,
            "external subtitle path should persist"
        )
        expect(store.items[0].subtitleFormat == .srt, "subtitle format should persist")

        _ = store.record(
            id: "second",
            cues: [earlierCue],
            document: document,
            videoURL: videoURL,
            embeddedSubtitleTrackID: nil,
            date: Date(timeIntervalSince1970: 120)
        )
        _ = store.record(
            id: "third",
            cues: [laterCue],
            document: document,
            videoURL: videoURL,
            embeddedSubtitleTrackID: nil,
            date: Date(timeIntervalSince1970: 130)
        )
        expect(store.items.map(\.id) == ["second", "third"], "limit should retain newest items in order")

        store.updateLimit(1)
        expect(store.items.map(\.id) == ["third"], "lowering limit should prune oldest items")

        let reloaded = VideoMiningHistoryStore(fileURL: fileURL, limit: 25)
        expect(reloaded.items.map(\.id) == ["third"], "items should persist across reload")
        reloaded.updateLimit(0)
        expect(reloaded.items.isEmpty, "zero limit should clear persisted history")
        let disabledID = reloaded.record(
            id: "disabled",
            cues: [earlierCue],
            document: document,
            videoURL: videoURL,
            embeddedSubtitleTrackID: nil
        )
        expect(disabledID == nil, "zero limit should disable recording")

        let embeddedStore = VideoMiningHistoryStore(
            fileURL: directory.appendingPathComponent("embedded.json"),
            limit: 25
        )
        let embeddedDocument = SubtitleDocument(
            sourceURL: videoURL,
            format: .embedded,
            cues: [earlierCue],
            warnings: []
        )
        _ = embeddedStore.record(
            id: "embedded",
            cues: [earlierCue],
            document: embeddedDocument,
            videoURL: videoURL,
            embeddedSubtitleTrackID: 7
        )
        expect(embeddedStore.items[0].subtitleSourcePath == nil, "embedded subtitles should not store a second path")
        expect(embeddedStore.items[0].embeddedSubtitleTrackID == 7, "embedded subtitle track should persist")

        let remoteIdentity = RemoteVideoIdentity(
            providerID: "youtube",
            remoteID: "remote-history",
            originalURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!,
            canonicalURL: nil,
            title: "Remote History Title",
            thumbnailURL: nil
        )
        let remoteDocument = SubtitleDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/temporary-remote-subtitle.vtt"),
            format: .webVTT,
            cues: [earlierCue],
            warnings: []
        )
        _ = embeddedStore.record(
            id: "remote",
            cues: [earlierCue],
            document: remoteDocument,
            videoURL: remoteIdentity.originalURL,
            videoTitle: remoteIdentity.title,
            mediaIdentity: remoteIdentity.mediaIdentity,
            remoteVideoIdentity: remoteIdentity,
            embeddedSubtitleTrackID: nil
        )
        let remoteHistoryItem = embeddedStore.items.first { $0.id == "remote" }!
        expect(remoteHistoryItem.videoPath == nil, "remote history must not persist a synthetic file path")
        expect(remoteHistoryItem.videoTitle == "Remote History Title", "remote history should persist its title")
        expect(remoteHistoryItem.remoteVideoIdentity == remoteIdentity, "remote history should persist durable identity")
        let remoteReady = VideoMiningHistoryNavigationResolver.resolve(
            item: remoteHistoryItem,
            currentVideoURL: nil,
            subtitleDelay: 0.5
        )
        guard case let .ready(remoteDestination) = remoteReady else {
            expect(false, "remote history should resolve without filesystem checks")
            return
        }
        expect(
            remoteDestination.media == .remote(remoteIdentity),
            "remote history navigation should return a remote destination"
        )

        let legacyURL = directory.appendingPathComponent("legacy.json")
        let legacyJSON = """
        [{
          "id": "legacy",
          "createdAt": 0,
          "status": "failed",
          "message": "old failure",
          "expression": "星",
          "subtitleText": "古い字幕",
          "videoFileName": "Legacy.mkv",
          "cueStart": 12.5,
          "cueEnd": 14.0
        }]
        """
        try Data(legacyJSON.utf8).write(to: legacyURL)
        let legacyStore = VideoMiningHistoryStore(fileURL: legacyURL, limit: 25)
        expect(legacyStore.items.count == 1, "legacy status history should decode")
        expect(legacyStore.items[0].subtitleText == "古い字幕", "legacy subtitle text should survive migration")
        expect(legacyStore.items[0].videoPath == nil, "legacy item should remain pathless")
        expect(
            legacyStore.items[0].subtitleSourceName == "Legacy.mkv",
            "legacy item should fall back to video name as source"
        )

        let ready = VideoMiningHistoryNavigationResolver.resolve(
            item: storeItem(
                videoURL: videoURL,
                subtitleURL: subtitleURL,
                subtitleFormat: .srt
            ),
            currentVideoURL: nil,
            subtitleDelay: 0.5
        )
        guard case let .ready(destination) = ready else {
            expect(false, "existing video and subtitle paths should resolve")
            return
        }
        expect(destination.media == .localFile(videoURL.standardizedFileURL), "resolver should return local media")
        expect(destination.subtitleURL == subtitleURL.standardizedFileURL, "resolver should return subtitle URL")
        expect(destination.seekTime == 13, "resolver should add subtitle delay")

        let missingVideo = VideoMiningHistoryNavigationResolver.resolve(
            item: storeItem(
                videoURL: directory.appendingPathComponent("Missing.mkv"),
                subtitleURL: subtitleURL,
                subtitleFormat: .srt
            ),
            currentVideoURL: nil,
            subtitleDelay: 0
        )
        expect(missingVideo == .missingVideo, "missing video should not mutate playback")

        let missingSubtitle = VideoMiningHistoryNavigationResolver.resolve(
            item: storeItem(
                videoURL: videoURL,
                subtitleURL: directory.appendingPathComponent("Missing.srt"),
                subtitleFormat: .srt
            ),
            currentVideoURL: nil,
            subtitleDelay: 0
        )
        expect(missingSubtitle == .missingSubtitle, "missing external subtitle should be reported")

        let legacyItem = VideoMiningHistoryItem(
            id: "pathless",
            createdAt: Date(),
            subtitleText: "字幕",
            videoFileName: "Episode 1.mkv",
            videoPath: nil,
            subtitleSourceName: "Episode 1.mkv",
            subtitleSourcePath: nil,
            subtitleFormat: nil,
            embeddedSubtitleTrackID: nil,
            cueStart: 12.5,
            cueEnd: 14
        )
        let legacyReady = VideoMiningHistoryNavigationResolver.resolve(
            item: legacyItem,
            currentVideoURL: videoURL,
            subtitleDelay: -20
        )
        guard case let .ready(legacyDestination) = legacyReady else {
            expect(false, "legacy item should resolve against current same-name video")
            return
        }
        expect(legacyDestination.seekTime == 0, "negative delayed seek should clamp to zero")

        let legacyUnavailable = VideoMiningHistoryNavigationResolver.resolve(
            item: legacyItem,
            currentVideoURL: directory.appendingPathComponent("Other.mkv"),
            subtitleDelay: 0
        )
        expect(
            legacyUnavailable == .legacySourceUnavailable,
            "pathless legacy item should reject a different current video"
        )

        embeddedStore.delete(id: "embedded")
        expect(embeddedStore.items.map(\.id) == ["remote"], "delete should remove only the selected item")
        embeddedStore.delete(id: "remote")
        expect(embeddedStore.items.isEmpty, "remote history should remain individually removable")
        store.clear()
        expect(store.items.isEmpty, "clear should remove all items")

        print("Video mining history tests passed")
    }

    private static func storeItem(
        videoURL: URL,
        subtitleURL: URL,
        subtitleFormat: SubtitleFormat
    ) -> VideoMiningHistoryItem {
        VideoMiningHistoryItem(
            id: UUID().uuidString,
            createdAt: Date(),
            subtitleText: "字幕",
            videoFileName: videoURL.lastPathComponent,
            videoPath: videoURL.standardizedFileURL.path,
            subtitleSourceName: subtitleURL.lastPathComponent,
            subtitleSourcePath: subtitleURL.standardizedFileURL.path,
            subtitleFormat: subtitleFormat,
            embeddedSubtitleTrackID: nil,
            cueStart: 12.5,
            cueEnd: 14
        )
    }
}
