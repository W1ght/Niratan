// test-sources: Features/Popup/MiningContextSelection.swift Models/Subtitle.swift Features/Video/VideoMiningContextSelectionBuilder.swift Features/Video/VideoMiningSelectionResolution.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoMiningSelectionResolutionTests {
    static func main() {
        let cues = [
            SubtitleCue(id: "a", startTime: 1, endTime: 2, text: "前。"),
            SubtitleCue(id: "b", startTime: 3, endTime: 4, text: "現在。"),
            SubtitleCue(id: "c", startTime: 5, endTime: 6, text: "次。"),
            SubtitleCue(id: "d", startTime: 7, endTime: 8, text: "次の次。")
        ]
        var expanded = VideoMiningContextSelectionBuilder.build(
            cues: cues,
            currentCueID: "b",
            targetUTF16Location: 0
        )!
        expanded.addNext()
        let expandedResolution = VideoMiningSelectionResolution.resolve(
            cue: cues[1],
            cues: cues,
            selectedContext: expanded.result
        )
        expect(expandedResolution.sentence == "現在。\n次。", "expanded video sentence should include the selected cue range")
        expect(expandedResolution.cueStart == 3 && expandedResolution.cueEnd == 6, "expanded media should span selected cues")
        expect(expandedResolution.previousCueText == "前。", "expanded previous subtitle should sit outside the range")
        expect(expandedResolution.nextCueText == "次の次。", "expanded next subtitle should sit outside the range")

        let definitionSelection = MiningContextSelection(
            sentences: [MiningContextSentence(id: "definition", text: "词典里的上下文。")],
            currentIndex: 0
        ).result
        let definitionResolution = VideoMiningSelectionResolution.resolve(
            cue: cues[1],
            cues: cues,
            selectedContext: definitionSelection
        )
        expect(definitionResolution.sentence == "词典里的上下文。", "nested popup context should become the sentence field")
        expect(definitionResolution.cueText == "現在。", "untimed popup context should preserve the original video subtitle field")
        expect(definitionResolution.cueStart == 3 && definitionResolution.cueEnd == 4, "untimed popup context should preserve the original media range")
        expect(definitionResolution.previousCueText == "前。" && definitionResolution.nextCueText == "次。", "untimed popup context should preserve adjacent video subtitles")
        print("Video mining selection resolution tests passed")
    }
}
