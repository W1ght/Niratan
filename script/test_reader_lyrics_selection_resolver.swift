// test-sources: Features/Reader/Lyrics/ReaderLyricsSelectionResolver.swift
import Foundation

@main
enum ReaderLyricsSelectionResolverTest {
    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func utf16Offset(of needle: String, in text: String) -> Int {
        let range = (text as NSString).range(of: needle)
        if range.location == NSNotFound {
            fputs("FAIL: missing test needle \(needle)\n", stderr)
            exit(1)
        }
        return range.location
    }

    static func main() {
        let longFocusedLine = "今まさにこちらに向かって踏み込もうとしたヤツの足元を陥没させる。"
        let candidatesFromKomi = ReaderLyricsSelectionResolver.lookupCandidates(
            in: longFocusedLine,
            utf16Offset: utf16Offset(of: "込", in: longFocusedLine),
            scanLength: 12
        )
        expect(
            candidatesFromKomi.first?.text.hasPrefix("込もう") == true,
            "lyrics lookup should preserve the exact clicked-character candidate first"
        )
        expect(
            candidatesFromKomi.contains {
                $0.utf16Start == utf16Offset(of: "踏", in: longFocusedLine)
                    && $0.text.hasPrefix("踏み込もう")
            },
            "lyrics lookup should include a fallback candidate starting at the word head for clicks inside a long focused word"
        )

        let candidatesFromMoto = ReaderLyricsSelectionResolver.lookupCandidates(
            in: longFocusedLine,
            utf16Offset: utf16Offset(of: "元", in: longFocusedLine),
            scanLength: 8
        )
        expect(
            candidatesFromMoto.contains {
                $0.utf16Start == utf16Offset(of: "足", in: longFocusedLine)
                    && $0.text.hasPrefix("足元")
            },
            "lyrics lookup should include a fallback candidate for a kanji compound clicked on its second character"
        )

        let punctuated = "一撃目を避けた。これは大きい。"
        let candidatesAfterPunctuation = ReaderLyricsSelectionResolver.lookupCandidates(
            in: punctuated,
            utf16Offset: utf16Offset(of: "れ", in: punctuated),
            scanLength: 12
        )
        let sentenceStart = utf16Offset(of: "こ", in: punctuated)
        expect(
            candidatesAfterPunctuation.allSatisfy { $0.utf16Start >= sentenceStart },
            "lyrics lookup fallback should not cross Japanese punctuation into the previous sentence"
        )

        let leadingWhitespace = "  星です"
        let leadingCandidate = ReaderLyricsSelectionResolver.lookupCandidates(
            in: leadingWhitespace,
            utf16Offset: 0,
            scanLength: 8
        ).first
        expect(
            leadingCandidate == ReaderLyricsLookupCandidate(text: "星です", utf16Start: 2),
            "lyrics lookup should keep trimming leading whitespace from the clicked candidate"
        )

        print("reader lyrics selection resolver passed")
    }
}
