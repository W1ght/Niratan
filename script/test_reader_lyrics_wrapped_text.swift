import AppKit

@main
struct ReaderLyricsWrappedTextTest {
    @MainActor static func main() {
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
        print("reader lyrics wrapped text passed: multi-line height, character order, graphemes, newlines, RTL")
    }
}
