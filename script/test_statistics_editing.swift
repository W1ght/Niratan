// test-sources: Models/Statistics.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func statistic(
    dateKey: String,
    characters: Int,
    seconds: Double,
    modified: Int
) -> Statistics {
    Statistics(
        title: "Book",
        dateKey: dateKey,
        charactersRead: characters,
        readingTime: seconds,
        minReadingSpeed: 1,
        altMinReadingSpeed: 1,
        lastReadingSpeed: 1,
        maxReadingSpeed: 1,
        lastStatisticModified: modified
    )
}

@main
struct StatisticsEditingContract {
    static func main() {
        let original = [
            statistic(dateKey: "2026-08-02", characters: 100, seconds: 60, modified: 1),
            statistic(dateKey: "2026-08-02", characters: 250, seconds: 120, modified: 2),
            statistic(dateKey: "2026-08-03", characters: 300, seconds: 180, modified: 3)
        ]

        let visible = StatisticsEditor.visibleStatistics(original)
        expect(visible.count == 2, "duplicate dates should be collapsed")
        expect(visible.first?.charactersRead == 250, "newest duplicate should win")

        let updated = StatisticsEditor.updating(
            dateKey: "2026-08-02",
            title: "Book",
            charactersRead: 600,
            readingTime: 120,
            modifiedAt: 10,
            in: original
        )
        let updatedDay = updated.first { $0.dateKey == "2026-08-02" }
        expect(updatedDay?.charactersRead == 600, "editing should replace characters")
        expect(updatedDay?.lastReadingSpeed == 18_000, "editing should recalculate speed")
        expect(updatedDay?.lastStatisticModified == 10, "editing should refresh modification time")

        let deleted = StatisticsEditor.deleting(
            dateKey: "2026-08-02",
            title: "Book",
            modifiedAt: 11,
            from: updated
        )
        let tombstone = deleted.first { $0.dateKey == "2026-08-02" }
        expect(tombstone?.charactersRead == 0 && tombstone?.readingTime == 0, "deletion should write a zero-value tombstone")
        expect(!StatisticsEditor.visibleStatistics(deleted).contains { $0.dateKey == "2026-08-02" }, "deleted day should be hidden")

        let deletedAll = StatisticsEditor.deletingAll(
            title: "Book",
            modifiedAt: 12,
            from: original
        )
        expect(deletedAll.count == 2, "delete all should preserve one tombstone per date")
        expect(deletedAll.allSatisfy { $0.charactersRead == 0 && $0.readingTime == 0 }, "all records should be tombstones")
        expect(StatisticsEditor.visibleStatistics(deletedAll).isEmpty, "delete all should leave no visible records")

        print("Statistics editing contract passed")
    }
}
