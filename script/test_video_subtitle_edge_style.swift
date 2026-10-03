// test-sources: Features/Video/Subtitles/VideoSubtitleEdgeStyle.swift
import CoreGraphics
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
    expect(abs(actual - expected) < 0.0001, "\(message): got \(actual), expected \(expected)")
}

@main
private enum VideoSubtitleEdgeStyleTests {
    static func main() {
        let fresh = VideoSubtitleEdgePreferenceResolver.resolve(
            edgeStyleRawValue: nil,
            edgeStrength: nil,
            legacyShadowRadius: nil
        )
        expect(
            fresh == .init(style: .highContrast, strength: 0.5),
            "fresh installs should use High Contrast at 50%"
        )

        let legacy = VideoSubtitleEdgePreferenceResolver.resolve(
            edgeStyleRawValue: nil,
            edgeStrength: nil,
            legacyShadowRadius: 7.5
        )
        expect(
            legacy == .init(style: .softShadow, strength: 0.75),
            "legacy radius should migrate to Soft Shadow"
        )

        let invalid = VideoSubtitleEdgePreferenceResolver.resolve(
            edgeStyleRawValue: "future-value",
            edgeStrength: 3,
            legacyShadowRadius: 2
        )
        expect(
            invalid == .init(style: .highContrast, strength: 1),
            "invalid new data should fall back and clamp without reusing legacy data"
        )
        expect(
            VideoSubtitleEdgePreferenceResolver.normalizedStrength(.nan) == 0.5,
            "non-finite strength should fall back to 50%"
        )

        let highContrast = VideoSubtitleEdgeRecipe.make(
            style: .highContrast,
            strength: 0.5,
            fontSize: 36
        )
        expect(
            highContrast.shadowRadius == 0 && highContrast.shadowPassCount == 0,
            "High Contrast should avoid the unstable combined TextKit shadow path"
        )
        expectClose(highContrast.outlineWidth, 1.875, "default High Contrast outline width")

        let soft = VideoSubtitleEdgeRecipe.make(
            style: .softShadow,
            strength: 0.5,
            fontSize: 36
        )
        expectClose(soft.shadowRadius, 3, "Soft Shadow radius")
        expect(
            soft.shadowPassCount == 1 && soft.outlineWidth == 0,
            "Soft Shadow should not add an outline"
        )

        let outline = VideoSubtitleEdgeRecipe.make(
            style: .clearOutline,
            strength: 0.5,
            fontSize: 36
        )
        expect(
            outline.shadowPassCount == 0 && outline.shadowRadius == 0,
            "Clear Outline should not add a shadow"
        )
        expectClose(outline.outlineWidth, 1.25, "Clear Outline width")

        let off = VideoSubtitleEdgeRecipe.make(style: .off, strength: 1, fontSize: 72)
        expect(off == .none, "Off should suppress every edge effect")
        let zero = VideoSubtitleEdgeRecipe.make(style: .highContrast, strength: 0, fontSize: 36)
        expect(zero == .none, "zero strength should suppress every edge effect")

        let maximumSoftShadow = VideoSubtitleEdgeRecipe.make(
            style: .softShadow,
            strength: 1,
            fontSize: 72
        )
        expectClose(
            maximumSoftShadow.shadowRadius,
            8,
            "Soft Shadow radius should cap at 8pt"
        )

        let maximumHighContrast = VideoSubtitleEdgeRecipe.make(
            style: .highContrast,
            strength: 1,
            fontSize: 72
        )
        expect(
            maximumHighContrast.shadowRadius == 0
                && maximumHighContrast.shadowPassCount == 0,
            "High Contrast should remain outline-only at maximum strength"
        )
        expectClose(
            maximumHighContrast.outlineWidth,
            2.5,
            "High Contrast outline should cap at 2.5pt to preserve the glyph fill"
        )

        print("Video subtitle edge style tests passed")
    }
}
