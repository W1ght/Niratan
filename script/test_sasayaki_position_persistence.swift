// test-sources: Models/Sasayaki.swift
import Foundation

@main
enum SasayakiPositionPersistenceTest {
    static func assertAlmostEqual(_ actual: Double, _ expected: Double, _ message: String) {
        if abs(actual - expected) > 0.0001 {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }

    static func makeMatch(start: Int, length: Int = 8) -> SasayakiMatch {
        SasayakiMatch(
            id: "cue-\(start)",
            startTime: 1,
            endTime: 2,
            text: "星",
            chapterIndex: 0,
            start: start,
            length: length
        )
    }

    static func main() {
        assertAlmostEqual(
            makeMatch(start: 50).readerProgress(chapterCharacterCount: 200),
            0.25,
            "cue start offset should map to Reader bookmark progress"
        )

        assertAlmostEqual(
            makeMatch(start: -10).readerProgress(chapterCharacterCount: 200),
            0,
            "negative cue offsets should clamp to the beginning of the chapter"
        )

        assertAlmostEqual(
            makeMatch(start: 250).readerProgress(chapterCharacterCount: 200),
            1,
            "cue offsets beyond the chapter should clamp to the end of the chapter"
        )

        assertAlmostEqual(
            makeMatch(start: 50).readerProgress(chapterCharacterCount: 0),
            0,
            "empty chapter character counts should resolve to the beginning"
        )

        print("PASS: Sasayaki cue Reader progress mapping is stable")
    }
}
