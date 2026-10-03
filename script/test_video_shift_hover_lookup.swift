// test-sources: Features/Video/Subtitles/VideoShiftHoverLookupState.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoShiftHoverLookupTests {
    static func main() {
        var state = VideoShiftHoverLookupState()

        expect(!state.setHoverPointAvailable(true), "hover alone should not schedule lookup")
        expect(state.setShiftPressed(true), "pressing Shift over text should schedule lookup")
        expect(state.pointerMoved(), "moving while Shift remains pressed should schedule lookup")
        expect(!state.setShiftPressed(false), "releasing Shift should stop lookup")
        expect(!state.pointerMoved(), "pointer movement without Shift should not schedule lookup")

        expect(!state.setHoverPointAvailable(false), "pointer exit should cancel hover availability")
        expect(!state.setShiftPressed(true), "Shift outside text should not schedule lookup")
        expect(state.setHoverPointAvailable(true), "entering text while Shift is held should schedule lookup")
        state.cancel()
        expect(!state.pointerMoved(), "cancel should clear Shift and hover state")

        expect(VideoShiftHoverLookupState.normalizedDelayMilliseconds(-20) == 0, "delay should not be negative")
        expect(VideoShiftHoverLookupState.normalizedDelayMilliseconds(45) == 45, "valid delay should be unchanged")
        expect(VideoShiftHoverLookupState.normalizedDelayMilliseconds(2_000) == 1_000, "delay should have a safe upper bound")

        print("Video Shift-hover lookup tests passed")
    }
}
