// test-sources: Features/Video/Playback/VideoTrack.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func track(
    _ id: Int,
    _ title: String,
    language: String? = nil,
    type: VideoTrackType = .subtitle,
    external: String? = nil,
    isImage: Bool = false
) -> VideoTrack {
    VideoTrack(
        id: id, type: type, title: title, language: language,
        codec: isImage ? "hdmv_pgs_subtitle" : "ass", ffIndex: nil,
        externalFilename: external, isImage: isImage, isSelected: false
    )
}

@main
struct VideoEmbeddedSubtitleDefaultTests {
    static func main() {
        let pick = VideoEmbeddedSubtitleDefault.preferredTrack(in:)

        expect(
            pick([track(1, "English", language: "eng"), track(2, "日本語", language: "jpn")])?.id == 2,
            "the Japanese track should win over other languages"
        )
        expect(
            pick([track(1, "English", language: "eng"), track(2, "Commentary", language: "eng")]) == nil,
            "without a Japanese track subtitles should stay off"
        )
        expect(
            pick([track(1, "Signs & Songs", language: "ja"), track(2, "Full", language: "ja")])?.id == 2,
            "full dialogue should beat a signs/songs track"
        )
        expect(
            pick([track(1, "Forced", language: "jpn"), track(2, "Dialogue", language: "jpn")])?.id == 2,
            "forced tracks should rank below full dialogue"
        )
        expect(
            pick([track(1, "PGS", language: "jpn", isImage: true), track(2, "Text", language: "jpn")])?.id == 2,
            "text subtitles should beat image subtitles for lookup"
        )
        expect(
            pick([track(1, "PGS", language: "jpn", isImage: true)])?.id == 1,
            "an image track is still better than nothing"
        )
        expect(
            pick([track(1, "日本語字幕"), track(2, "Untitled")])?.id == 1,
            "an untagged track titled in Japanese should be recognised"
        )
        expect(
            pick([track(1, "Japanese (CC)")])?.id == 1,
            "an English title naming Japanese should be recognised"
        )
        expect(
            pick([track(1, "Full", language: "ja-JP")])?.id == 1,
            "regional Japanese language tags should match"
        )
        expect(
            pick([track(1, "Sidecar", language: "jpn", external: "/tmp/a.ass")]) == nil,
            "external sidecars are handled by the autoload path, not the embedded default"
        )
        expect(
            pick([track(1, "Audio", language: "jpn", type: .audio)]) == nil,
            "only subtitle tracks are eligible"
        )
        expect(
            pick([track(3, "Dialogue A", language: "jpn"), track(4, "Dialogue B", language: "jpn")])?.id == 3,
            "equally ranked tracks should keep mpv's order"
        )

        let tracks = [
            track(1, "日本語", language: "jpn"),
            track(2, "test.srt", external: "/tmp/videos/test.srt"),
            track(3, "Audio", type: .audio, external: "/tmp/videos/test.srt"),
        ]
        expect(
            VideoSubtitleTrackMatching.trackID(forFileNamed: "test.srt", in: tracks) == 2,
            "the primary subtitle should map to its external mpv track"
        )
        expect(
            VideoSubtitleTrackMatching.trackID(forFileNamed: "other.srt", in: tracks) == nil,
            "a primary subtitle without a track keeps its own inspector row"
        )
        expect(
            VideoSubtitleTrackMatching.trackID(forFileNamed: nil, in: tracks) == nil,
            "no primary subtitle maps to no track"
        )

        print("Video embedded subtitle default tests passed")
    }
}
