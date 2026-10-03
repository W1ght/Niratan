// test-sources: Core/VideoSubtitlePositionPolicy.swift
import CoreGraphics
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
    abs(lhs - rhs) < 0.0001
}

@main
private enum VideoSubtitlePositionPolicyTests {
    static func main() {
        expect(
            VideoSubtitlePositionPolicy.range == 0...1,
            "position range should be normalized"
        )
        expect(
            VideoSubtitlePositionPolicy.defaultPosition == 0.9,
            "default should stay near the bottom"
        )
        expect(
            VideoSubtitlePositionPolicy.normalized(-1) == 0,
            "negative position should clamp to top"
        )
        expect(
            VideoSubtitlePositionPolicy.normalized(2) == 1,
            "oversized position should clamp to bottom"
        )
        expect(
            VideoSubtitlePositionPolicy.normalized(.nan) == 0.9,
            "invalid position should use the default"
        )

        expect(
            VideoSubtitlePositionPolicy.migratedLegacyPosition(nil) == 0.9,
            "missing legacy value should use default"
        )
        expect(
            VideoSubtitlePositionPolicy.migratedLegacyPosition(.nan) == 0.9,
            "invalid legacy value should use default"
        )
        expect(
            VideoSubtitlePositionPolicy.migratedLegacyPosition(0) == 0.9,
            "legacy neutral should use default"
        )
        expect(
            VideoSubtitlePositionPolicy.migratedLegacyPosition(200) == 0,
            "legacy maximum up should map to top"
        )
        expect(
            VideoSubtitlePositionPolicy.migratedLegacyPosition(400) == 0,
            "legacy values above released range should clamp to top"
        )
        expect(
            VideoSubtitlePositionPolicy.migratedLegacyPosition(-200) == 1,
            "legacy maximum down should map to bottom"
        )
        expect(
            VideoSubtitlePositionPolicy.migratedLegacyPosition(-400) == 1,
            "legacy values below released range should clamp to bottom"
        )
        expect(
            VideoSubtitlePositionPolicy.migratedLegacyPosition(100) == 0.45,
            "legacy positive midpoint should preserve upward direction"
        )
        expect(
            VideoSubtitlePositionPolicy.migratedLegacyPosition(-100) == 0.95,
            "legacy negative midpoint should preserve downward direction"
        )

        expect(
            close(
                VideoSubtitlePositionPolicy.originY(
                    viewportHeight: 800,
                    subtitleHeight: 100,
                    position: 0
                ),
                0
            ),
            "top endpoint should use zero origin"
        )
        expect(
            close(
                VideoSubtitlePositionPolicy.originY(
                    viewportHeight: 800,
                    subtitleHeight: 100,
                    position: 0.5
                ),
                350
            ),
            "middle should interpolate available travel"
        )
        expect(
            close(
                VideoSubtitlePositionPolicy.originY(
                    viewportHeight: 800,
                    subtitleHeight: 100,
                    position: 1
                ),
                700
            ),
            "bottom endpoint should subtract subtitle height"
        )
        expect(
            close(
                VideoSubtitlePositionPolicy.originY(
                    viewportHeight: 80,
                    subtitleHeight: 100,
                    position: 1
                ),
                0
            ),
            "oversized subtitle should remain top-aligned"
        )
        expect(
            close(
                VideoSubtitlePositionPolicy.originY(
                    viewportHeight: .nan,
                    subtitleHeight: 10,
                    position: 1
                ),
                0
            ),
            "invalid geometry should safely use zero"
        )

        print("Video subtitle position policy tests passed")
    }
}
