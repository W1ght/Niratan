// test-sources: Features/Reader/Lyrics/ReaderLyricsTextView.swift Features/Reader/Lyrics/ReaderLyricsLayoutMetrics.swift Features/Reader/Lyrics/ReaderLyricsSelectionResolver.swift Features/Reader/Lyrics/ReaderLyricsShiftHoverLookupState.swift
import AppKit

@main
struct ReaderLyricsWrappedTextTest {
    @MainActor static func main() {
        _ = NSApplication.shared
        let text = String(repeating: "これは長い文章です。改行しても最後まで表示します。", count: 8)
        let narrow = ReaderLyricsHorizontalTextLayout(text: text, fontSize: 34, weight: .bold, width: 280)
        let wide = ReaderLyricsHorizontalTextLayout(text: text, fontSize: 34, weight: .bold, width: 700)
        precondition(narrow.height > wide.height)
        let rects = narrow.characterRects
        precondition(Set(rects.map(\.minY)).count > 2, "fixture must exercise more than two visual lines")
        precondition(rects.allSatisfy { $0.maxY <= narrow.height }, "last character must fit measured height")
        precondition(narrow.manager.glyphRange(for: narrow.container).length == narrow.manager.numberOfGlyphs)
        let pixelWidth = 560
        let pixelHeight = Int(narrow.height * 2)
        let values = narrow.progressionValues(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: 2)
        for (index, rect) in rects.enumerated() {
            let x = min(pixelWidth - 1, max(0, Int(rect.midX * 2)))
            let y = min(pixelHeight - 1, max(0, Int(rect.midY * 2)))
            let value = values[y * pixelWidth + x]
            let expected = (Float(index) + 0.5) / Float(rects.count)
            precondition(abs(value - expected) < 1 / Float(rects.count), "progress must follow character order across lines")
        }
        let emoji = ReaderLyricsHorizontalTextLayout(text: "あ👨‍👩‍👧‍👦e\u{301}い", fontSize: 34, weight: .bold, width: 280)
        precondition(emoji.characterRects.count == 4, "grapheme clusters must not split into UTF-16 units")
        let breaks = ReaderLyricsHorizontalTextLayout(text: "一行目\n二行目\n三行目\n最終行", fontSize: 34, weight: .bold, width: 280)
        precondition(Set(breaks.characterRects.map(\.minY)).count >= 4)
        let rtl = ReaderLyricsHorizontalTextLayout(text: "אבגדה", fontSize: 34, weight: .bold, width: 280)
        precondition(rtl.characterRects.first!.minX > rtl.characterRects.last!.minX)
        let rtlValues = rtl.progressionValues(pixelWidth: 280, pixelHeight: Int(rtl.height), scale: 1)
        let first = rtl.characterRects[0]
        precondition(rtlValues[Int(first.midY) * 280 + Int(first.midX)] < 0.2)
        verifyReusedSelectableLayout()
        print("reader lyrics wrapped text passed: multi-line height, character order, graphemes, newlines, RTL, resized selection geometry")
    }

    @MainActor private static func verifyReusedSelectableLayout() {
        let text = String(repeating: "これは長い文章です。改行しても最後まで表示します。", count: 3)
        let view = ReaderLyricsMetalTextContainerView(frame: .zero)
        // Reuse one live view, including two distinct font sizes in the same
        // rounded cache bucket, fractional widths, and focused/context changes.
        let sizes: [(CGFloat, CGFloat)] = [
            (612, 34.49), (612, 34.01), (280.25, 48),
            (700.75, 25.84), (540.25, 34.22), (280, 34)
        ]
        for (width, fontSize) in sizes {
            let expected = ReaderLyricsHorizontalTextLayout(
                text: text, fontSize: fontSize, weight: .bold, width: width
            )
            view.configure(
                text: text, scanLength: 16, fontSize: fontSize, layoutWidth: width,
                weight: .bold, textColor: .white, upcomingTextColor: .gray,
                progressFraction: 1, progressRatePerSecond: 0, isProgressAnimating: false,
                lookupHighlightColor: .blue, lookupHighlightTextColor: .white,
                hoverLookupDelayMs: 45, isLookupPopupVisible: true,
                onSelection: { _, _, _ in nil }
            )
            // A SwiftUI height transition must not discard the tail of the text
            // from the selection container, even before the final frame arrives.
            for height in [expected.height / 2, expected.height] {
                view.frame.size = CGSize(width: width, height: height)
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
                let textView = scroll.documentView as! NSTextView
                let manager = textView.layoutManager!
                let container = textView.textContainer!
                manager.ensureLayout(for: container)
                precondition(textView.font?.pointSize == fontSize, "fractional font changes must invalidate selection layout")
                precondition(manager.glyphRange(for: container).length == manager.numberOfGlyphs,
                             "every wrapped glyph must remain selectable during row resizing")
                for (offset, rect) in expected.characterRects.enumerated() {
                    let glyphRange = manager.glyphRange(
                        forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil
                    )
                    let actual = manager.boundingRect(forGlyphRange: glyphRange, in: container)
                    precondition(actual == rect, "selection and rasterization must agree at every character, including the last line")
                    let glyph = manager.glyphIndex(for: CGPoint(x: rect.midX, y: rect.midY),
                                                   in: container, fractionOfDistanceThroughGlyph: nil)
                    precondition(manager.characterIndexForGlyph(at: glyph) == offset)
                }
                let fullRange = NSRange(location: 0, length: text.utf16.count)
                textView.setSelectedRange(fullRange)
                precondition(textView.selectedRange() == fullRange)
            }
        }
    }
}
