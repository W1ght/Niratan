// test-sources: Features/Popup/MiningContextSelection.swift Models/Subtitle.swift Features/Video/VideoMiningContextSelectionBuilder.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoMiningContextSelectionTests {
    static func main() {
        let cues = [
            SubtitleCue(id: "a", startTime: 1, endTime: 2, text: "前。"),
            SubtitleCue(id: "b", startTime: 3, endTime: 4, text: "対象の字幕。"),
            SubtitleCue(id: "c", startTime: 5, endTime: 6, text: "後。")
        ]
        let selection = VideoMiningContextSelectionBuilder.build(
            cues: cues,
            currentCueID: "b",
            targetUTF16Location: 2
        )
        expect(selection?.currentIndex == 1, "current video cue should anchor the selection")
        expect(selection?.sentences.map(\.text) == ["前。", "対象の字幕。", "後。"], "video context should preserve cue order")
        expect(selection?.sentences[1].mediaRange == MiningContextMediaRange(start: 3, end: 4), "video context should retain cue timing")
        expect(selection?.sentences[1].targetUTF16Range == NSRange(location: 2, length: 0), "video context should retain the lookup offset")
        expect(VideoMiningContextSelectionBuilder.build(cues: cues, currentCueID: "missing", targetUTF16Location: 0) == nil, "missing cues should not create a context source")
        print("Video mining context selection tests passed")
    }
}
