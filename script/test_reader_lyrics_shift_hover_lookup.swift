// test-sources: Features/Reader/Lyrics/ReaderLyricsShiftHoverLookupState.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum ReaderLyricsShiftHoverLookupTests {
    static func main() {
        var state = ReaderLyricsShiftHoverLookupState()

        expect(!state.setHoverPointAvailable(true), "hover alone should not schedule lookup")
        expect(state.setShiftPressed(true), "pressing Shift over lyrics text should schedule lookup")
        expect(state.pointerMoved(), "moving while Shift remains pressed should schedule lookup")
        expect(!state.setShiftPressed(false), "releasing Shift should stop lookup")
        expect(!state.pointerMoved(), "pointer movement without Shift should not schedule lookup")

        expect(!state.setHoverPointAvailable(false), "pointer exit should cancel lyrics hover availability")
        expect(!state.setShiftPressed(true), "Shift outside lyrics text should not schedule lookup")
        expect(state.setHoverPointAvailable(true), "entering lyrics text while Shift is held should schedule lookup")
        state.cancel()
        expect(!state.pointerMoved(), "cancel should clear Shift and hover state")

        expect(ReaderLyricsShiftHoverLookupState.normalizedDelayMilliseconds(-20) == 0, "delay should not be negative")
        expect(ReaderLyricsShiftHoverLookupState.normalizedDelayMilliseconds(45) == 45, "valid delay should be unchanged")
        expect(ReaderLyricsShiftHoverLookupState.normalizedDelayMilliseconds(2_000) == 1_000, "delay should have a safe upper bound")

        print("Reader lyrics Shift-hover lookup tests passed")
    }
}
