// test-sources: Models/Anki.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoMiningContextTests {
    static func main() {
        let video = VideoMiningContext(
            fileName: "lesson-01.mkv",
            cueText: "星を見ています。",
            cueStart: 65.25,
            cueEnd: 68.5,
            previousCueText: "夜になりました。",
            nextCueText: "きれいですね。"
        )

        expect(video.timestamp == "0:01:05.250", "timestamp should be stable and millisecond precise")
        expect(video.value(for: .videoFileName) == "lesson-01.mkv", "file name handlebar should resolve")
        expect(video.value(for: .videoSubtitle) == "星を見ています。", "subtitle handlebar should resolve")
        expect(video.value(for: .videoPreviousSubtitle) == "夜になりました。", "previous cue should resolve")
        expect(video.value(for: .videoNextSubtitle) == "きれいですね。", "next cue should resolve")

        let lapisMappings = AnkiFieldTemplate.appliedDefaultMappings(
            noteType: "Lapis",
            availableFields: ["SentenceAudio", "Picture", "MiscInfo"],
            existing: [:]
        )
        expect(
            lapisMappings["SentenceAudio"] == Handlebars.sasayakiAudio.rawValue,
            "the shared audio mapping should use Sasayaki audio for EPUB and the subtitle clip for Video"
        )
        expect(
            lapisMappings["Picture"] == Handlebars.bookCover.rawValue,
            "the shared picture mapping should use the book cover for EPUB and the frame for Video"
        )
        expect(
            lapisMappings["MiscInfo"] == Handlebars.documentTitle.rawValue,
            "the shared defaults should use the document or video title in MiscInfo"
        )
        print("Video mining context tests passed")
    }
}
