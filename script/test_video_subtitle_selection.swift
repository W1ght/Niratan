// test-sources: Features/Video/Subtitles/SubtitleSelectionResolver.swift Core/SelectionLookup/TextSelectionResolver.swift Models/Profile.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoSubtitleSelectionTests {
    static func main() {
        let sentence = "夜空の星を見ています。"
        expect(
            SubtitleSelectionResolver.lookupText(
                in: sentence,
                utf16Offset: 3,
                scanLength: 6,
                contentLanguage: .japanese
            ) == "星を見ていま",
            "lookup text should begin at the clicked UTF-16 offset"
        )
        expect(
            SubtitleSelectionResolver.lookupText(
                in: sentence,
                utf16Offset: 100,
                scanLength: 6,
                contentLanguage: .japanese
            ).isEmpty,
            "out-of-range clicks should be ignored"
        )
        expect(
            SubtitleSelectionResolver.lookupText(
                in: "  星です",
                utf16Offset: 0,
                scanLength: 6,
                contentLanguage: .japanese
            ) == "星です",
            "leading whitespace should not be sent to the lookup engine"
        )
        let candidate = SubtitleSelectionResolver.lookupCandidate(
            in: "😀  星を見ます。",
            utf16Offset: 2,
            scanLength: 8,
            contentLanguage: .japanese
        )
        expect(candidate?.text == "星を見ます。", "lookup candidate should trim leading whitespace")
        expect(candidate?.utf16Start == 4, "lookup candidate should retain the adjusted UTF-16 start")
        expect(
            candidate.flatMap { SubtitleSelectionResolver.highlightRange(for: $0, matchedText: "星を") }
                == NSRange(location: 4, length: 2),
            "highlight range should use the matched UTF-16 length"
        )
        expect(
            SubtitleSelectionResolver.highlightRange(
                for: SubtitleLookupCandidate(text: "😀星", utf16Start: 0),
                matchedText: "😀"
            ) == NSRange(location: 0, length: 2),
            "highlight range should preserve surrogate-pair length"
        )
        let englishCandidate = SubtitleSelectionResolver.lookupCandidate(
            in: "We watched don't panic together.",
            utf16Offset: 14,
            scanLength: 16,
            contentLanguage: .english
        )
        expect(
            englishCandidate?.text == "don't panic toge",
            "English lookup should rewind a click in the middle of a word to its beginning"
        )
        expect(
            englishCandidate?.utf16Start == 11,
            "English lookup should report the rewound word start for highlighting and mining"
        )
        print("Video subtitle selection tests passed")
    }
}
