// test-sources: Features/Popup/MiningContextSelection.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum MiningContextSelectionTests {
    static func main() {
        let sentences = [
            MiningContextSentence(id: "0", text: "前の前。"),
            MiningContextSentence(id: "1", text: "前。"),
            MiningContextSentence(
                id: "2",
                text: "現在の文。",
                targetUTF16Range: NSRange(location: 0, length: 2),
                mediaRange: MiningContextMediaRange(start: 10, end: 12)
            ),
            MiningContextSentence(
                id: "3",
                text: "次。",
                mediaRange: MiningContextMediaRange(start: 12.5, end: 14)
            ),
            MiningContextSentence(id: "4", text: "次の次。")
        ]
        var selection = MiningContextSelection(sentences: sentences, currentIndex: 2)

        expect(selection.selectedRange == 2...2, "selection should start at the current sentence")
        expect(selection.canAddPrevious, "previous context should initially be available")
        expect(!selection.canRemovePrevious, "previous rollback should initially be disabled")
        expect(selection.canAddNext, "next context should initially be available")
        expect(!selection.canRemoveNext, "next rollback should initially be disabled")

        selection.addPrevious()
        selection.addPrevious()
        expect(selection.selectedRange == 0...2, "adding previous context should extend only the lower bound")
        expect(!selection.canAddPrevious, "previous add should stop at the source boundary")
        expect(selection.canRemovePrevious, "previous rollback should enable after extending")

        selection.removePrevious()
        expect(selection.selectedRange == 1...2, "previous rollback should remove one leading sentence")
        selection.removePrevious()
        selection.removePrevious()
        expect(selection.selectedRange == 2...2, "previous rollback must not cross the current sentence")

        selection.addNext()
        selection.addNext()
        expect(selection.selectedRange == 2...4, "adding next context should extend only the upper bound")
        expect(selection.canRemoveNext, "next rollback should enable after extending")
        selection.removeNext()
        expect(selection.selectedRange == 2...3, "next rollback should remove one trailing sentence")
        selection.setCurrentTargetUTF16Length(4)

        let result = selection.result
        expect(result.sentence == "現在の文。\n次。", "selected sentences should join in source order")
        expect(result.mediaRange == MiningContextMediaRange(start: 10, end: 14), "media range should span timed selected sentences")
        expect(result.previousSentence?.text == "前。", "previous sentence should sit outside the selected range")
        expect(result.nextSentence?.text == "次の次。", "next sentence should sit outside the selected range")
        expect(result.currentSentence.targetUTF16Range == NSRange(location: 0, length: 4), "lookup match length should update the current target highlight")

        let invalid = MiningContextSelection(sentences: sentences, currentIndex: 99)
        expect(invalid.currentIndex == 4, "invalid current indexes should clamp safely")

        let decoded = MiningContextSelection.decode([
            "currentIndex": 1,
            "sentences": [
                ["id": "a", "text": "前。"],
                ["id": "b", "text": "対象。", "targetLocation": 0]
            ]
        ])
        expect(decoded?.currentIndex == 1, "web context payload should decode its current index")
        expect(decoded?.sentences.map(\.text) == ["前。", "対象。"], "web context payload should preserve sentence order")
        expect(decoded?.sentences[1].targetUTF16Range == NSRange(location: 0, length: 0), "web context payload should preserve the target location")
        expect(MiningContextSelection.decode(["sentences": []]) == nil, "empty web context payloads should be rejected")

        struct TimedCue {
            let id: String
            let text: String
            let start: TimeInterval
            let end: TimeInterval
        }
        let timedCues = [
            TimedCue(id: "before", text: "前の句。", start: 1, end: 2),
            TimedCue(id: "current", text: "現在の句。", start: 3, end: 4),
            TimedCue(id: "after", text: "後の句。", start: 5, end: 6)
        ]
        let timedSelection = MiningContextSelection.timedSentences(
            from: timedCues,
            currentID: "current",
            targetUTF16Location: 2,
            id: \.id,
            text: \.text,
            mediaRange: { MiningContextMediaRange(start: $0.start, end: $0.end) }
        )
        expect(timedSelection?.currentIndex == 1, "timed context should anchor the selected cue")
        expect(timedSelection?.canAddPrevious == true, "timed context should expose the previous cue for lyrics context selection")
        expect(timedSelection?.canAddNext == true, "timed context should expose the next cue for lyrics context selection")
        expect(timedSelection?.sentences[1].targetUTF16Range == NSRange(location: 2, length: 0), "timed context should keep the clicked offset on the current cue")
        expect(timedSelection?.sentences[1].mediaRange == MiningContextMediaRange(start: 3, end: 4), "timed context should keep current cue timing")
        expect(
            MiningContextSelection.timedSentences(
                from: timedCues,
                currentID: "missing",
                targetUTF16Location: 0,
                id: \.id,
                text: \.text,
                mediaRange: { MiningContextMediaRange(start: $0.start, end: $0.end) }
            ) == nil,
            "missing current cue should not create a timed context"
        )
        print("Mining context selection tests passed")
    }
}
