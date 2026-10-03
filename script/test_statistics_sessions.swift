// test-sources: Models/Statistics.swift Core/StatisticsStorage.swift Features/Reader/ReaderPageIndex.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func day(_ dateKey: String, characters: Int, seconds: Double, modified: Int) -> Statistics {
    Statistics(
        title: "Book",
        dateKey: dateKey,
        charactersRead: characters,
        readingTime: seconds,
        minReadingSpeed: 0,
        altMinReadingSpeed: 0,
        lastReadingSpeed: 0,
        maxReadingSpeed: 0,
        lastStatisticModified: modified
    )
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func ms(_ date: Date) -> Int { Int(StatisticsClock.milliseconds(date)) }

@main
struct StatisticsSessionsContract {
    static func main() throws {
        try sessionLog()
        try storage()
        pageIndex()
        print("statistics sessions contract passed")
    }

    static func sessionLog() throws {
        let legacy = [
            day("2026-08-02", characters: 1_000, seconds: 600, modified: ms(date(2026, 8, 2, 21))),
            day("2026-08-03", characters: 0, seconds: 0, modified: ms(date(2026, 8, 3, 21))),
            day("2026-08-04", characters: 300, seconds: 120, modified: ms(date(2026, 8, 4, 9)))
        ]
        let records = ReadingSessionLog.legacySessions(legacy, key: "book", resetMinutes: 0)
        expect(records.count == 2, "empty legacy days do not become sessions")
        let derived = ReadingSessionLog.dailyStatistics(records, title: "Book", resetMinutes: 0)
        expect(derived.map(\.dateKey) == ["2026-08-02", "2026-08-04"], "legacy sessions stay on their day")
        expect(derived[0].charactersRead == 1_000 && derived[0].readingTime == 600, "legacy totals are preserved")
        expect(derived[0].lastStatisticModified == legacy[0].lastStatisticModified, "derived rows keep the modification time")
        expect(
            ReadingSessionLog.legacyID(key: "book", dateKey: "2026-08-02")
                == ReadingSessionLog.legacyID(key: "book", dateKey: "2026-08-02"),
            "legacy ids are stable"
        )

        // Two sessions on one day aggregate; a session belongs to the day it started.
        var sessions = records
        sessions["a"] = Timestamped(modified: 10, value: ReadingSession(
            startedAt: StatisticsClock.milliseconds(date(2026, 8, 4, 23, 50)),
            endedAt: StatisticsClock.milliseconds(date(2026, 8, 5, 0, 20)),
            charactersRead: 200,
            readingTime: 1_800
        ))
        let days = ReadingSessionLog.days(sessions, resetMinutes: 0)
        expect(days.last?.dateKey == "2026-08-04" && days.last?.sessions.count == 2, "sessions group by start day")
        expect(days.last?.total.charactersRead == 500, "day totals sum sessions")
        let lateReset = ReadingSessionLog.days(sessions, resetMinutes: 60)
        expect(lateReset.last?.total.charactersRead == 500, "reset time regroups without losing sessions")

        // Merge import: newer remote day replaces local sessions of that day, older is ignored.
        let remoteNewer = day("2026-08-04", characters: 900, seconds: 900, modified: Int.max / 2)
        let remoteOlder = day("2026-08-02", characters: 1, seconds: 1, modified: 1)
        let merged = ReadingSessionLog.importingDaily(
            [remoteNewer, remoteOlder],
            into: sessions,
            key: "book",
            mode: .merge,
            resetMinutes: 0
        )
        let mergedDays = ReadingSessionLog.dailyStatistics(merged, title: "Book", resetMinutes: 0)
        expect(mergedDays.first { $0.dateKey == "2026-08-04" }?.charactersRead == 900, "newer remote day wins")
        expect(mergedDays.first { $0.dateKey == "2026-08-02" }?.charactersRead == 1_000, "older remote day is ignored")
        expect(ReadingSessionLog.entries(merged).count == 2, "replaced sessions become tombstones")

        // Replace import removes local days that are missing remotely.
        let replaced = ReadingSessionLog.importingDaily([remoteOlder], into: sessions, key: "book", mode: .replace, resetMinutes: 0)
        let replacedDays = ReadingSessionLog.dailyStatistics(replaced, title: "Book", resetMinutes: 0)
        expect(replacedDays.map(\.dateKey) == ["2026-08-02"], "replace keeps only remote days")
        expect(replacedDays.first?.charactersRead == 1, "replace takes remote values")

        // Editing and deleting.
        let edited = ReadingSessionLog.editing(id: "a", charactersRead: 50, readingTime: 60, in: sessions)
        expect(edited["a"]?.value?.charactersRead == 50 && edited["a"]?.value?.readingTime == 60, "editing updates a session")
        expect((edited["a"]?.modified ?? 0) > 10, "editing refreshes the modification time")
        let deleted = ReadingSessionLog.deleting(ids: ["a"], from: edited)
        expect(deleted["a"] != nil && deleted["a"]?.value == nil, "deleting leaves a tombstone")
        expect(ReadingSessionLog.total(deleted) == ReadingSessionLog.total(records), "tombstones do not count")
    }

    static func storage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("niratan-statistics-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dailyURL = root.appendingPathComponent("statistics.json")
        let sessionsURL = root.appendingPathComponent(StatisticsStorage.sessionsFileName)

        let legacy = [day("2026-08-02", characters: 1_000, seconds: 600, modified: ms(date(2026, 8, 2, 21)))]
        try JSONEncoder().encode(legacy).write(to: dailyURL)

        expect(StatisticsStorage.dailyStatistics(root: root, resetMinutes: 0)?.first?.charactersRead == 1_000, "read-only view converts legacy rows")
        expect(!FileManager.default.fileExists(atPath: sessionsURL.path), "read-only view does not migrate")

        var records = StatisticsStorage.load(root: root, resetMinutes: 0)
        expect(records.count == 1, "load migrates legacy days")
        expect(FileManager.default.fileExists(atPath: sessionsURL.path), "migration writes the sessions file")

        // The reader appends a session; statistics.json is re-derived.
        records["live"] = Timestamped(modified: StatisticsClock.milliseconds(date(2026, 8, 2, 22)), value: ReadingSession(
            startedAt: StatisticsClock.milliseconds(date(2026, 8, 2, 21, 30)),
            endedAt: StatisticsClock.milliseconds(date(2026, 8, 2, 22)),
            charactersRead: 500,
            readingTime: 300
        ))
        try StatisticsStorage.save(records, root: root, resetMinutes: 0)
        var daily = try JSONDecoder().decode([Statistics].self, from: Data(contentsOf: dailyURL))
        expect(daily.count == 1 && daily[0].charactersRead == 1_500, "statistics.json aggregates sessions per day")

        // Reloading our own export never re-imports it, even after a reset time change.
        expect(StatisticsStorage.load(root: root, resetMinutes: 0) == records, "own export is not imported again")
        expect(StatisticsStorage.load(root: root, resetMinutes: 23 * 60) == records, "reset time change does not duplicate sessions")

        // An older build edits statistics.json directly: the newer row is imported.
        daily = [day("2026-08-02", characters: 2_000, seconds: 900, modified: ms(date(2026, 8, 3, 8)))]
        try JSONEncoder().encode(daily).write(to: dailyURL)
        let reconciled = StatisticsStorage.load(root: root, resetMinutes: 0)
        expect(ReadingSessionLog.total(reconciled).charactersRead == 2_000, "external newer day replaces that day")

        // TTU import with an empty day array never clears sessions in merge mode.
        try StatisticsStorage.importDaily([], root: root, mode: .merge, resetMinutes: 0)
        expect(ReadingSessionLog.total(StatisticsStorage.load(root: root, resetMinutes: 0)).charactersRead == 2_000, "empty import keeps data")
    }

    static func pageIndex() {
        // Spine 0 covers characters 0..<100 in 3 pages, spine 1 covers 100..<150 in 2 pages.
        let index = ReaderPageIndex(spinePageStarts: [[0, 40, 80], [0, 30]], spineStartCharacters: [0, 100])
        expect(index.totalPages == 5, "pages are summed across spine items")
        expect(index.page(at: 0, spineIndex: 0) == 0, "first character is on the first page")
        expect(index.page(at: 79, spineIndex: 0) == 1, "lookup picks the last page starting before the character")
        expect(index.page(at: 100, spineIndex: 1) == 3, "next spine starts on its own first page")
        expect(index.page(spineIndex: 1, localPage: 5) == 4, "local pages clamp to the spine")

        let wholeBook = index.progress(page: 3, chapterStart: 0, chapterCount: 150, bookCharacterCount: 150)
        expect(wholeBook == .init(page: 4, total: 5, chapterPage: 4, chapterTotal: 5), "single chapter spans the book")
        let secondChapter = index.progress(page: 4, chapterStart: 100, chapterCount: 50, bookCharacterCount: 150)
        expect(secondChapter == .init(page: 5, total: 5, chapterPage: 2, chapterTotal: 2), "chapter pages restart at the chapter")
        let firstChapter = index.progress(page: 1, chapterStart: 0, chapterCount: 100, bookCharacterCount: 150)
        expect(firstChapter?.chapterTotal == 3 && firstChapter?.chapterPage == 2, "chapter ends before the next chapter page")
        expect(ReaderPageIndex(spinePageStarts: [], spineStartCharacters: []).progress(page: 0, chapterStart: 0, chapterCount: 0, bookCharacterCount: 0) == nil, "no pages before measurement")
    }
}
