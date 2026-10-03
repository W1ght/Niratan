// test-sources: Models/Subtitle.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func expectFast(
    _ label: String,
    maxSeconds: TimeInterval,
    operation: () -> Void
) {
    let start = Date()
    operation()
    let elapsed = Date().timeIntervalSince(start)
    expect(
        elapsed <= maxSeconds,
        "\(label) should complete in \(maxSeconds)s, got \(String(format: "%.3f", elapsed))s"
    )
}

@main
private enum VideoTranscriptTests {
    static func main() {
        let primary = SubtitleDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/primary.srt"),
            format: .srt,
            cues: [
                SubtitleCue(id: "p1", startTime: 1, endTime: 3, text: "第一"),
                SubtitleCue(id: "p2", startTime: 4, endTime: 6, text: "第二")
            ],
            warnings: []
        )
        let secondary = SubtitleDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/secondary.vtt"),
            format: .webVTT,
            cues: [
                SubtitleCue(id: "s1", startTime: 0.5, endTime: 3.2, text: "First"),
                SubtitleCue(id: "s2", startTime: 3.8, endTime: 6.1, text: "Second")
            ],
            warnings: []
        )

        let transcript = SubtitleTranscript(primary: primary, secondary: secondary)
        expect(transcript.rows.count == 2, "transcript should follow primary cue count")
        expect(
            transcript.rows[0].secondaryText == "First",
            "transcript should pair the overlapping secondary cue"
        )
        expect(
            transcript.rows[1].secondaryText == "Second",
            "transcript should pair later overlapping cues"
        )
        expect(
            transcript.row(containing: 4.5)?.primaryText == "第二",
            "transcript should resolve the active row"
        )
        expect(
            transcript.nearestRowIndex(at: 4.5) == 1,
            "transcript should resolve the active row index"
        )
        expect(
            transcript.nearestRowIndex(at: 3.5) == 1,
            "transcript should resolve the next row index between cues"
        )

        let largePrimary = SubtitleDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/large-primary.srt"),
            format: .srt,
            cues: (0..<20_000).map { index in
                let start = TimeInterval(index)
                return SubtitleCue(
                    id: "p\(index)",
                    startTime: start,
                    endTime: start + 0.8,
                    text: "Primary \(index)"
                )
            },
            warnings: []
        )
        let largeSecondary = SubtitleDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/large-secondary.vtt"),
            format: .webVTT,
            cues: (0..<20_000).map { index in
                let start = TimeInterval(index) + 0.1
                return SubtitleCue(
                    id: "s\(index)",
                    startTime: start,
                    endTime: start + 0.8,
                    text: "Secondary \(index)"
                )
            },
            warnings: []
        )
        expectFast("large bilingual transcript build", maxSeconds: 0.45) {
            let largeTranscript = SubtitleTranscript(
                primary: largePrimary,
                secondary: largeSecondary
            )
            expect(largeTranscript.rows.count == 20_000, "large transcript should keep all primary rows")
            expect(
                largeTranscript.rows[19_999].secondaryText == "Secondary 19999",
                "large transcript should pair the final row without timing out"
            )

            var window = SubtitleTranscriptWindow(windowSize: 80, extensionSize: 40)
            window.reset(rowCount: largeTranscript.rows.count, focusing: 10_000)
            expect(
                window.visibleRange.count == 80,
                "transcript window should initially expose only a nearby row range"
            )
            expect(
                window.visibleRange.contains(10_000),
                "transcript window should include the playback row"
            )
            expect(
                largeTranscript.rows(in: window.visibleRange).count == 80,
                "transcript window should slice rows without rendering the full list"
            )

            let initialUpper = window.visibleRange.upperBound
            window.extendAfter(rowCount: largeTranscript.rows.count)
            expect(
                window.visibleRange.upperBound == initialUpper + 40,
                "scrolling to the bottom edge should load the next transcript chunk"
            )

            window.followPlayback(rowCount: largeTranscript.rows.count, focusing: 19_990)
            expect(
                window.visibleRange.contains(19_990),
                "playback should move the transcript window in chunks"
            )
            expect(
                window.visibleRange.upperBound == largeTranscript.rows.count,
                "playback near the end should clamp the window to the final row"
            )
        }
        print("Video transcript tests passed")
    }
}
