// test-sources: Features/Reader/Lyrics/ReaderLyricsLayoutMetrics.swift
import CoreGraphics
import Foundation

@main
enum ReaderLyricsLayoutMetricsTest {
    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual != expected {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }

    static func assertTrue(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func assertLessThanOrEqual(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        if actual > expected {
            fputs("FAIL: \(message): expected <= \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }

    static func assertGreaterThanOrEqual(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        if actual < expected {
            fputs("FAIL: \(message): expected >= \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let compact = ReaderLyricsLayoutMetrics(size: CGSize(width: 900, height: 620))
        assertEqual(
            ReaderLyricsVisualSpec.defaultLineSpacing,
            25,
            "lyrics mode should carry over the synced lyrics default line spacing"
        )
        assertEqual(
            ReaderLyricsVisualSpec.deselectedLineScale,
            0.98,
            "lyrics mode should use the synced lyrics deselected line transform"
        )
        assertEqual(
            ReaderLyricsVisualSpec.lineFinishProgressAnimationDuration,
            0.25,
            "lyrics progress completion animation should match the synced lyrics timing"
        )
        assertEqual(
            ReaderLyricsVisualSpec.lineProgressionGradientFeather,
            40,
            "lyrics Metal progression feather should match the synced lyrics stored spec value"
        )
        assertEqual(
            ReaderLyricsVisualSpec.lineFitHorizontalMargin,
            12,
            "lyrics line fitting should reserve horizontal breathing room before Metal texture clipping"
        )
        assertEqual(
            ReaderLyricsVisualSpec.lyricsMaskBlurRadius,
            24,
            "lyrics mask blur should be wide enough to avoid hard glyph start edges"
        )
        assertEqual(
            ReaderLyricsVisualSpec.lyricsMaskBlurFeatherPadding,
            60,
            "lyrics mask blur should reserve enough feather padding for soft edges"
        )
        assertEqual(
            ReaderLyricsVisualSpec.lyricsMaskFocusedOpacity,
            0.52,
            "focused lyrics mask should be dimmer than clear text so blur edges do not read as hard boundaries"
        )
        assertEqual(
            ReaderLyricsVisualSpec.lyricsMaskContextOpacity,
            0.32,
            "context lyrics mask should stay softly visible without making row starts too obvious"
        )
        assertEqual(
            ReaderLyricsVisualSpec.minimumFocusedFittedFontSize,
            24,
            "focused lyrics should shrink for long lines without collapsing below readable size"
        )
        assertEqual(
            ReaderLyricsVisualSpec.minimumContextFittedFontSize,
            18,
            "context lyrics should keep a smaller readable floor when fitted to width"
        )
        assertTrue(
            compact.contextRadius <= 2,
            "compact Reader windows should reduce visible lyrics context instead of forcing nine rows"
        )
        assertLessThanOrEqual(
            compact.totalLyricsRowsHeight,
            compact.availableLyricsHeight,
            "compact lyrics rows should fit inside the available vertical lyrics area"
        )
        assertLessThanOrEqual(
            compact.contentMaxWidth,
            900 - compact.lyricsHorizontalPadding * 2,
            "lyrics content width should never exceed the current window width minus padding"
        )

        let unflippedPopupRect = ReaderLyricsPopupCoordinateSpace.popupRect(
            convertedRect: CGRect(x: 500, y: 500, width: 40, height: 20),
            contentBounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
            isContentViewFlipped: false,
            topSafeAreaInset: 32
        )
        assertEqual(
            unflippedPopupRect.origin.y,
            248,
            "lyrics popup coordinates should subtract the transparent titlebar safe-area inset from unflipped AppKit coordinates"
        )

        let flippedPopupRect = ReaderLyricsPopupCoordinateSpace.popupRect(
            convertedRect: CGRect(x: 120, y: 42, width: 32, height: 18),
            contentBounds: CGRect(x: 0, y: 0, width: 640, height: 480),
            isContentViewFlipped: true,
            topSafeAreaInset: 32
        )
        assertEqual(
            flippedPopupRect.origin.y,
            10,
            "lyrics popup coordinates should subtract the same safe-area inset from flipped AppKit coordinates"
        )
        assertEqual(
            ReaderLyricsPopupCoordinateSpace.popupRect(
                convertedRect: CGRect(x: 0, y: 8, width: 0, height: 0),
                contentBounds: CGRect(x: 0, y: 0, width: 640, height: 480),
                isContentViewFlipped: true,
                topSafeAreaInset: 32
            ).origin.y,
            0,
            "lyrics popup coordinates should clamp top-edge selections after safe-area correction"
        )

        let liveMushokuWindow = ReaderLyricsLayoutMetrics(size: CGSize(width: 1419, height: 672))
        assertTrue(
            liveMushokuWindow.contextRadius <= 2,
            "the tested Mushoku Tensei landscape window should keep the cue window small enough for controls"
        )
        assertLessThanOrEqual(
            liveMushokuWindow.totalLyricsRowsHeight,
            liveMushokuWindow.availableLyricsHeight,
            "the tested Mushoku Tensei landscape rows should fit above the bottom controls"
        )

        let short = ReaderLyricsLayoutMetrics(size: CGSize(width: 720, height: 480))
        assertEqual(short.contextRadius, 1, "very short windows should keep only one cue above and below")
        assertLessThanOrEqual(
            short.totalLyricsRowsHeight,
            short.availableLyricsHeight,
            "very short lyrics rows should fit without vertical clipping"
        )

        let tall = ReaderLyricsLayoutMetrics(size: CGSize(width: 1440, height: 1000))
        assertEqual(tall.contextRadius, 4, "tall Reader windows should restore the full context window with synced-lyrics spacing")
        assertTrue(
            tall.focusedFontSize > compact.focusedFontSize,
            "tall Reader windows should allow larger focused lyrics"
        )
        assertLessThanOrEqual(tall.contentMaxWidth, 920, "wide lyrics content should keep the readable max width")

        let baseFocusedFontSize: CGFloat = 40
        let measuredLongLineWidth: CGFloat = 900
        let availableLineWidth: CGFloat = 620
        let fittedFocusedFontSize = ReaderLyricsLayoutMetrics.fittedLineFontSize(
            baseFontSize: baseFocusedFontSize,
            measuredTextWidth: measuredLongLineWidth,
            availableWidth: availableLineWidth,
            minimumFontSize: ReaderLyricsVisualSpec.minimumFocusedFittedFontSize
        )
        let effectiveLineWidth = availableLineWidth - ReaderLyricsVisualSpec.lineFitHorizontalMargin * 2
        assertTrue(
            fittedFocusedFontSize < baseFocusedFontSize,
            "long focused lyrics should reduce font size before the Metal texture clips the right edge"
        )
        assertGreaterThanOrEqual(
            fittedFocusedFontSize,
            ReaderLyricsVisualSpec.minimumFocusedFittedFontSize,
            "long focused lyrics should stay above the readable fitted font floor"
        )
        assertLessThanOrEqual(
            measuredLongLineWidth * fittedFocusedFontSize / baseFocusedFontSize,
            effectiveLineWidth + 0.5,
            "fitted focused lyrics should fit inside the effective line width"
        )

        let unchangedFontSize = ReaderLyricsLayoutMetrics.fittedLineFontSize(
            baseFontSize: baseFocusedFontSize,
            measuredTextWidth: 480,
            availableWidth: availableLineWidth,
            minimumFontSize: ReaderLyricsVisualSpec.minimumFocusedFittedFontSize
        )
        assertEqual(
            unchangedFontSize,
            baseFocusedFontSize,
            "short lyrics should keep the visual spec font size"
        )

        let verticalGlyphs = ReaderLyricsVerticalTextLayout.glyphs(from: "あ\n😀い")
        assertEqual(
            verticalGlyphs.map(\.text),
            ["あ", " ", "😀", "い"],
            "vertical lyrics glyph layout should preserve drawable glyph order while normalizing line breaks"
        )
        assertEqual(
            verticalGlyphs.map(\.utf16Start),
            [0, 1, 2, 4],
            "vertical lyrics glyph layout should keep UTF-16 offsets for lookup highlights"
        )

        let wrappedColumns = ReaderLyricsVerticalTextLayout.columns(
            from: "ABCDEFGHIJ",
            fontSize: 20,
            availableHeight: 66
        )
        assertEqual(
            wrappedColumns.map { $0.map(\.text).joined() },
            ["ABC", "DEF", "GHI", "J"],
            "long vertical lyrics should wrap into additional columns instead of shrinking into one overlong column"
        )
        assertEqual(
            ReaderLyricsVerticalTextLayout.columnCount(
                glyphCount: 10,
                fontSize: 20,
                availableHeight: 66
            ),
            4,
            "vertical lyrics column count should be derived from row height and available height"
        )
        assertEqual(
            ReaderLyricsVerticalTextLayout.contentWidth(
                glyphCount: 10,
                fontSize: 20,
                availableHeight: 66,
                columnWidth: 30,
                columnSpacing: 8
            ),
            144,
            "wrapped vertical lyrics should reserve width for every generated column plus inner spacing"
        )
        let fittedVerticalFontSize = ReaderLyricsVerticalTextLayout.fittedFontSize(
            text: String(repeating: "長", count: 40),
            baseFontSize: 40,
            availableHeight: 132,
            availableWidth: 320,
            minimumFontSize: 18
        )
        assertTrue(
            fittedVerticalFontSize < 40,
            "long vertical lyrics should reduce font size when wrapped columns would exceed available width"
        )
        assertLessThanOrEqual(
            ReaderLyricsVerticalTextLayout.contentWidth(
                glyphCount: 40,
                fontSize: fittedVerticalFontSize,
                availableHeight: 132,
                columnWidth: ReaderLyricsVerticalTextLayout.columnWidth(fontSize: fittedVerticalFontSize),
                columnSpacing: ReaderLyricsVerticalTextLayout.columnSpacing(fontSize: fittedVerticalFontSize)
            ),
            320 - ReaderLyricsVisualSpec.lineFitHorizontalMargin * 2 + 1,
            "fitted vertical lyrics should fit wrapped columns inside the effective lyric width"
        )

        print("reader lyrics layout metrics passed")
    }
}
