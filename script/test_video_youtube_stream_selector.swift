// test-sources: Features/Video/Remote/RemoteVideoResolver.swift Features/Video/Remote/YouTubeMediaModels.swift Features/Video/Remote/YouTubeStreamSelector.swift Features/Video/Remote/RemoteVideoSource.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift
import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func stream(
    id: String,
    height: Int? = nil,
    video: Bool,
    audio: Bool,
    bitrate: Int,
    ext: String,
    native: Bool = true
) -> YouTubeMediaStreamDescriptor {
    YouTubeMediaStreamDescriptor(
        url: URL(string: "https://example.com/\(id)")!,
        formatID: id,
        height: height,
        hasVideo: video,
        hasAudio: audio,
        bitrate: bitrate,
        fileExtension: ext,
        prefersNativeCodec: native
    )
}

@main
private enum VideoYouTubeStreamSelectorTests {
    static func main() throws {
        let streams = [
            stream(id: "18", height: 360, video: true, audio: true, bitrate: 700_000, ext: "mp4"),
            stream(id: "160", height: 144, video: true, audio: false, bitrate: 120_000, ext: "mp4"),
            stream(id: "134", height: 360, video: true, audio: false, bitrate: 500_000, ext: "mp4"),
            stream(id: "22-webm", height: 720, video: true, audio: false, bitrate: 2_000_000, ext: "webm", native: false),
            stream(id: "136", height: 720, video: true, audio: false, bitrate: 1_500_000, ext: "mp4"),
            stream(id: "137", height: 1080, video: true, audio: false, bitrate: 3_000_000, ext: "mp4"),
            stream(id: "271", height: 1440, video: true, audio: false, bitrate: 5_000_000, ext: "webm", native: false),
            stream(id: "251", video: false, audio: true, bitrate: 160_000, ext: "webm"),
            stream(id: "140", video: false, audio: true, bitrate: 128_000, ext: "m4a"),
        ]

        let selection = try YouTubeStreamSelector.select(from: streams)
        expect(
            selection.qualityOptions.map(\.height),
            [1080, 720, 360, 144],
            "qualities should be distinct, descending and capped at 1080p"
        )
        expect(
            selection.qualityOptions.map(\.id),
            ["137", "136", "134", "160"],
            "native-preferred streams should win within each height"
        )
        expect(
            selection.externalAudio?.formatID,
            "140",
            "M4A audio should be preferred for the split playback path"
        )
        expect(
            selection.playback.height,
            1080,
            "initial playback should select the highest allowed height"
        )
        expect(
            selection.muxedFallback?.formatID,
            "18",
            "progressive stream should remain available for audio recovery"
        )
        expect(
            selection.mining?.formatID,
            "18",
            "progressive stream should be preferred for mining"
        )

        do {
            _ = try YouTubeStreamSelector.select(from: [])
            fputs("FAIL: empty stream list should be rejected\n", stderr)
            exit(1)
        } catch RemoteVideoResolverError.noPlayableStream {
            // Expected.
        }

        print("Video YouTube stream selector tests passed")
    }
}
