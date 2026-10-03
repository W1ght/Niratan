// test-sources: Features/Sync/TtuSyncNaming.swift Models/Statistics.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct TtuSyncNamingTests {
    static func main() {
        let cases: [(String, String)] = [
            ("吾輩は猫である", "吾輩は猫である"),
            ("a/b", "a%2Fb"),
            ("Why?", "Why%3F"),
            ("<tag>", "%3Ctag%3E"),
            ("C:\\path", "C%3A%5Cpath"),
            ("a|b", "a%7Cb"),
            ("100%", "100%25"),
            ("say \"hi\"", "say %22hi%22"),
            ("a*b", "a~ttu-star~b"),
            ("ends with dot.", "ends with dot~ttu-dend~"),
            ("ends with space ", "ends with space~ttu-spc~"),
        ]
        for (title, encoded) in cases {
            let sanitized = TtuSyncNaming.sanitize(title)
            expect(sanitized == encoded, "sanitize(\(title)) = \(sanitized), expected \(encoded)")
            expect(TtuSyncNaming.desanitize(sanitized) == title, "\(title) should round-trip")
        }

        // Pinned against the current implementation so sync file names cannot drift silently.
        let stats = [
            Statistics(
                title: "本", dateKey: "2026-10-01", charactersRead: 1_200, readingTime: 600,
                minReadingSpeed: 6_000, altMinReadingSpeed: 5_000, lastReadingSpeed: 7_200,
                maxReadingSpeed: 7_200, lastStatisticModified: 111
            ),
            Statistics(
                title: "本", dateKey: "2026-10-02", charactersRead: 3_000, readingTime: 1_200,
                minReadingSpeed: 8_000, altMinReadingSpeed: 7_000, lastReadingSpeed: 9_000,
                maxReadingSpeed: 9_000, lastStatisticModified: 222
            ),
        ]
        let name = TtuSyncNaming.statisticsFileName(stats: stats)
        let expected = "statistics_1_6_222_4200_1800.0_6000_5000_8400.0_9000_900.0_1029.0_2100.0_2400.0_8400.0_8397.0_na.json"
        expect(name == expected, "statistics file name \(name)")

        expect(
            TtuSyncNaming.statisticsFileName(stats: [])
                == "statistics_1_6_0_0_0.0_0_0_0.0_0_0.0_0.0_0.0_0.0_0.0_0.0_na.json",
            "empty statistics should not divide by zero"
        )

        print("ttu sync naming tests passed")
    }
}
