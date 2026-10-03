// test-sources: NativeMac/NativeReaderWheelNavigation.swift
import Foundation

@main
enum ReaderWheelNavigationTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        require(
            NativeReaderWheelNavigationResolver.navigation(
                deltaX: 0,
                deltaY: -1,
                hasPreciseScrollingDeltas: false,
                hasMomentum: false
            ) == .forward,
            "scrolling a mouse wheel down should advance the paginated Reader"
        )
        require(
            NativeReaderWheelNavigationResolver.navigation(
                deltaX: 0,
                deltaY: 1,
                hasPreciseScrollingDeltas: false,
                hasMomentum: false
            ) == .backward,
            "scrolling a mouse wheel up should move back in the paginated Reader"
        )
        require(
            NativeReaderWheelNavigationResolver.navigation(
                deltaX: 0,
                deltaY: -12,
                hasPreciseScrollingDeltas: true,
                hasMomentum: false
            ) == nil,
            "the discrete mouse-wheel resolver must not consume precise trackpad input"
        )
        require(
            NativeReaderWheelNavigationResolver.navigation(
                deltaX: 0,
                deltaY: -12,
                hasPreciseScrollingDeltas: false,
                hasMomentum: true
            ) == nil,
            "momentum scrolling must not turn Reader pages"
        )
        require(
            NativeReaderWheelNavigationResolver.navigation(
                deltaX: 2,
                deltaY: 1,
                hasPreciseScrollingDeltas: false,
                hasMomentum: false
            ) == nil,
            "horizontal-dominant wheel input must not turn Reader pages"
        )

        var accumulator = NativeReaderWheelNavigationAccumulator()
        require(
            accumulator.consume(
                deltaX: 0,
                deltaY: -0.4,
                hasPreciseScrollingDeltas: false,
                hasMomentum: false
            ) == nil,
            "a partial wheel delta should wait for the navigation threshold"
        )
        require(
            accumulator.consume(
                deltaX: 0,
                deltaY: -0.6,
                hasPreciseScrollingDeltas: false,
                hasMomentum: false
            ) == .forward,
            "same-direction wheel deltas should navigate after crossing the threshold"
        )
        require(
            accumulator.consume(
                deltaX: 0,
                deltaY: 0.5,
                hasPreciseScrollingDeltas: false,
                hasMomentum: false
            ) == nil
                && accumulator.consume(
                    deltaX: 0,
                    deltaY: -0.6,
                    hasPreciseScrollingDeltas: false,
                    hasMomentum: false
                ) == nil,
            "reversing wheel direction should clear the previous partial delta"
        )

        var trackpadAccumulator = NativeReaderTrackpadNavigationAccumulator()
        require(
            trackpadAccumulator.consume(
                deltaX: 0,
                deltaY: -20,
                phase: .began,
                hasMomentum: false
            ) == nil
                && trackpadAccumulator.consume(
                    deltaX: 0,
                    deltaY: -30,
                    phase: .changed,
                    hasMomentum: false
                ) == nil,
            "a trackpad gesture should wait for the higher page-turn threshold"
        )
        require(
            trackpadAccumulator.consume(
                deltaX: 0,
                deltaY: -10,
                phase: .changed,
                hasMomentum: false
            ) == .forward,
            "a trackpad gesture should turn one page after crossing the threshold"
        )
        require(
            trackpadAccumulator.consume(
                deltaX: 0,
                deltaY: -100,
                phase: .changed,
                hasMomentum: false
            ) == nil,
            "one trackpad gesture must never turn a second page"
        )
        require(
            trackpadAccumulator.consume(
                deltaX: 0,
                deltaY: -100,
                phase: .changed,
                hasMomentum: true
            ) == nil,
            "trackpad momentum must never turn another page"
        )
        _ = trackpadAccumulator.consume(
            deltaX: 0,
            deltaY: 0,
            phase: .ended,
            hasMomentum: false
        )
        require(
            trackpadAccumulator.consume(
                deltaX: 0,
                deltaY: 25,
                phase: .began,
                hasMomentum: false
            ) == nil
                && trackpadAccumulator.consume(
                    deltaX: 0,
                    deltaY: 35,
                    phase: .changed,
                    hasMomentum: false
                ) == .backward,
            "lifting and starting a new trackpad gesture should allow one page turn in the opposite direction"
        )
        _ = trackpadAccumulator.consume(
            deltaX: 0,
            deltaY: 0,
            phase: .ended,
            hasMomentum: false
        )
        require(
            trackpadAccumulator.consume(
                deltaX: 80,
                deltaY: -30,
                phase: .began,
                hasMomentum: false
            ) == nil
                && trackpadAccumulator.consume(
                    deltaX: 0,
                    deltaY: -29,
                    phase: .changed,
                    hasMomentum: false
                ) == nil,
            "horizontal-dominant trackpad input should not contribute to the page-turn threshold"
        )

        print("Reader wheel navigation tests passed")
    }
}
