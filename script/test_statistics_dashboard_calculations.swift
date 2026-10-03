// test-sources: Models/Book.swift Models/Statistics.swift Core/StatisticsStorage.swift Features/Bookshelf/StatisticsDashboardModels.swift
import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("Assertion failed: \(message). expected=\(expected) actual=\(actual)\n", stderr)
        exit(1)
    }
}

func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("Assertion failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct StatisticsDashboardCalculationTests {
static func main() throws {
let calendar = Calendar(identifier: .gregorian)
let today = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
let monday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 29))!
let june24 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 24))!
let june25 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 25))!
let june26 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 26))!
let june30 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 30))!

let settings = StatisticsTargetSettings(
    dailyTargetType: .characters,
    dailyCharacterTarget: 5_000,
    dailyDurationTargetMinutes: 30,
    weeklyTargetDays: 2
)

let firstBook = StatisticsBookContribution(
    bookID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    title: "Alpha",
    coverPath: "/covers/alpha.jpg",
    characters: 4_000,
    readingTime: 1_800
)
let firstBookJune25 = StatisticsBookContribution(
    bookID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    title: "Alpha",
    coverPath: "/covers/alpha.jpg",
    characters: 5_200,
    readingTime: 2_600
)
let firstBookJune26 = StatisticsBookContribution(
    bookID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    title: "Alpha",
    coverPath: "/covers/alpha.jpg",
    characters: 5_100,
    readingTime: 2_400
)
let secondBook = StatisticsBookContribution(
    bookID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
    title: "Beta",
    coverPath: nil,
    characters: 2_000,
    readingTime: 900
)
let secondBookToday = StatisticsBookContribution(
    bookID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
    title: "Beta",
    coverPath: nil,
    characters: 3_500,
    readingTime: 1_800
)
let shortBookBurst = StatisticsBookContribution(
    bookID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    title: "Alpha",
    coverPath: "/covers/alpha.jpg",
    characters: 5_000,
    readingTime: 10
)
let thirdBookID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
let bookRecords = [
    StatisticsBookRecord(id: firstBook.bookID, title: "Alpha", coverPath: "/covers/alpha.jpg", totalCharacters: 100_000),
    StatisticsBookRecord(id: secondBook.bookID, title: "Beta", coverPath: nil, totalCharacters: 50_000),
    StatisticsBookRecord(id: thirdBookID, title: "Gamma", coverPath: nil, totalCharacters: 75_000)
]

let days = [
    StatisticsDayAggregate(date: june24, characters: 4_000, readingTime: 1_800, bookContributions: [firstBook]),
    StatisticsDayAggregate(date: june25, characters: 5_200, readingTime: 2_600, bookContributions: [firstBookJune25]),
    StatisticsDayAggregate(date: june26, characters: 5_100, readingTime: 2_400, bookContributions: [firstBookJune26]),
    StatisticsDayAggregate(date: june30, characters: 6_000, readingTime: 2_700, bookContributions: [firstBook, secondBook]),
    StatisticsDayAggregate(date: today, characters: 3_500, readingTime: 1_800, bookContributions: [secondBookToday])
]

let recentWindow = StatisticsDateRange.recentYear(endingAt: today, calendar: calendar)
assertEqual(recentWindow.start, calendar.date(from: DateComponents(year: 2025, month: 7, day: 2))!, "recent year starts one year plus one day before today")
assertEqual(recentWindow.end, today, "recent year ends today")
assertEqual(StatisticsDateRange.fixedYear(2026, today: today, calendar: calendar).end, today, "current fixed year clips to today")
assertEqual(StatisticsDateRange.fixedYear(2025, today: today, calendar: calendar).end, calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!, "past fixed year ends on Dec 31")
assertEqual(StatisticsDateRange.mondayStartOfWeek(for: today, calendar: calendar), monday, "week starts on Monday")

let weekRange = StatisticsDateRange.selectedRange(mode: .week, anchor: today, window: recentWindow, calendar: calendar)
assertEqual(weekRange.start, monday, "week selection starts Monday")
assertEqual(weekRange.end, today, "week selection clips to the current statistics window")

let snapshot = StatisticsDashboardSnapshot(days: days, skippedCorruptBookIDs: [UUID()])
let todaySummary = StatisticsDashboardCalculator.todaySummary(snapshot: snapshot, today: today, settings: settings, calendar: calendar)
assertEqual(todaySummary.characters, 3_500, "today characters")
assertEqual(todaySummary.readingTime, 1_800, "today reading time")
assertEqual(todaySummary.targetPercent, 70, "today target percent")
assertEqual(todaySummary.dailyStreakDays, 1, "daily streak falls back to previous completed days when today is incomplete")

let shortOnlySnapshot = StatisticsDashboardSnapshot(days: [
    StatisticsDayAggregate(date: today, characters: 5_000, readingTime: 10, bookContributions: [shortBookBurst])
])
let shortOnlyTodaySummary = StatisticsDashboardCalculator.todaySummary(snapshot: shortOnlySnapshot, today: today, settings: settings, calendar: calendar)
assertEqual(shortOnlyTodaySummary.characters, 5_000, "today summary keeps sub-minute characters")
assertEqual(shortOnlyTodaySummary.averageSpeedPerHour, nil, "today speed ignores sub-minute samples")

let weekSummary = StatisticsDashboardCalculator.weekSummary(snapshot: snapshot, today: today, settings: settings, calendar: calendar)
assertEqual(weekSummary.range.start, monday, "week summary starts Monday")
assertEqual(weekSummary.characters, 9_500, "week summary sums elapsed/future week dates")
assertEqual(weekSummary.metTargetDays, 1, "week summary counts met target days")
assertEqual(weekSummary.weeklyStreakWeeks, 1, "weekly streak includes previous completed week when current week incomplete")

let rangeSummary = StatisticsDashboardCalculator.rangeSummary(days: days, range: StatisticsDateRange(start: june24, end: today), settings: settings, calendar: calendar)
assertEqual(rangeSummary.characters, 23_800, "range summary sums characters")
assertEqual(rangeSummary.readingTime, 11_300, "range summary sums time")
assertEqual(rangeSummary.averageSpeedPerHour, Optional(7_582), "range summary calculates hourly speed")
assertEqual(rangeSummary.targetDays, 3, "range summary counts target days")

let speedSummary = StatisticsDashboardCalculator.speedSummary(days: days, range: StatisticsDateRange(start: june24, end: today), calendar: calendar)
assertEqual(speedSummary.weightedAverageSpeedPerHour, Optional(7_582), "speed summary uses weighted average")
assertEqual(speedSummary.medianDaySpeedPerHour, 7_650, "speed summary calculates active-day median")
assertEqual(speedSummary.recentActiveDaySpeedPerHour, 7_582, "speed summary calculates recent active-day speed")
assertEqual(speedSummary.speedChangePercent, nil, "speed summary avoids short-window change noise")
assertEqual(speedSummary.bestDay?.date, june24, "speed summary breaks best-day ties by date")
assertEqual(speedSummary.bestDay?.speedPerHour, 8_000, "speed summary records best-day speed")
assertEqual(speedSummary.worstDay?.date, today, "speed summary records slowest day")

let june27 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 27))!
let june29 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 29))!
let shortBurst = StatisticsDayAggregate(date: june27, characters: 5_000, readingTime: 10, bookContributions: [shortBookBurst])
let shortBurstThisWeek = StatisticsDayAggregate(date: june29, characters: 5_000, readingTime: 10, bookContributions: [shortBookBurst])
let noisySpeedDays = days + [shortBurst, shortBurstThisWeek]
let noisyRangeSummary = StatisticsDashboardCalculator.rangeSummary(days: noisySpeedDays, range: StatisticsDateRange(start: june24, end: today), settings: settings, calendar: calendar)
assertEqual(noisyRangeSummary.characters, 33_800, "range summary keeps sub-minute characters")
assertEqual(noisyRangeSummary.averageSpeedPerHour, Optional(7_582), "range speed ignores sub-minute samples")
let noisyWeekSummary = StatisticsDashboardCalculator.weekSummary(snapshot: StatisticsDashboardSnapshot(days: noisySpeedDays), today: today, settings: settings, calendar: calendar)
assertEqual(noisyWeekSummary.characters, 14_500, "week summary keeps sub-minute characters")
assertEqual(noisyWeekSummary.averageSpeedPerHour, Optional(7_600), "week speed ignores sub-minute samples")
let filteredSpeedSummary = StatisticsDashboardCalculator.speedSummary(days: noisySpeedDays, range: StatisticsDateRange(start: june24, end: today), calendar: calendar)
assertEqual(filteredSpeedSummary.weightedAverageSpeedPerHour, Optional(7_582), "speed summary weighted speed ignores sub-minute samples")
assertEqual(filteredSpeedSummary.bestDay?.date, june24, "speed summary ignores sub-minute samples")
let shortOnlySpeedSummary = StatisticsDashboardCalculator.speedSummary(days: [shortBurst], range: StatisticsDateRange(start: june24, end: today), calendar: calendar)
assertEqual(shortOnlySpeedSummary.weightedAverageSpeedPerHour, nil, "speed summary shows no average without valid samples")
let noisyTrend = StatisticsDashboardCalculator.trendPoints(grain: .day, range: StatisticsDateRange(start: june24, end: today), days: noisySpeedDays, calendar: calendar)
let shortBurstTrend = noisyTrend.first { $0.id == "2026-06-27" }
assertEqual(shortBurstTrend?.averageSpeedPerHour, nil, "speed trend keeps sub-minute samples as missing speed")
assertEqual(shortBurstTrend?.value(for: .speed), nil, "speed trend does not plot missing speed as zero")

let speedChangeStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
let fourteenSpeedDays = (0..<14).map { offset in
    let date = calendar.date(byAdding: .day, value: offset, to: speedChangeStart)!
    return StatisticsDayAggregate(date: date, characters: 1_000 + offset * 100, readingTime: 600, bookContributions: [
        StatisticsBookContribution(bookID: firstBook.bookID, title: "Alpha", coverPath: nil, characters: 1_000 + offset * 100, readingTime: 600)
    ])
}
let speedChangeRange = StatisticsDateRange(start: fourteenSpeedDays.first!.date, end: calendar.date(byAdding: .day, value: 27, to: speedChangeStart)!)
assertEqual(
    StatisticsDashboardCalculator.speedSummary(days: fourteenSpeedDays, range: speedChangeRange, calendar: calendar).speedChangePercent,
    nil,
    "speed change waits for non-overlapping early and recent windows"
)
let twentyEightSpeedDays = (0..<28).map { offset in
    let date = calendar.date(byAdding: .day, value: offset, to: speedChangeStart)!
    let characters = offset < 14 ? 1_000 : 2_000
    return StatisticsDayAggregate(date: date, characters: characters, readingTime: 600, bookContributions: [
        StatisticsBookContribution(bookID: firstBook.bookID, title: "Alpha", coverPath: nil, characters: characters, readingTime: 600)
    ])
}
assertEqual(
    StatisticsDashboardCalculator.speedSummary(days: twentyEightSpeedDays, range: speedChangeRange, calendar: calendar).speedChangePercent,
    Optional(100),
    "speed change compares non-overlapping first and recent active-day windows"
)

let trend = StatisticsDashboardCalculator.trendPoints(grain: .day, range: weekRange, days: days, calendar: calendar)
assertEqual(trend.count, 2, "week trend trims inactive leading days")
assertEqual(trend[0].characters, 6_000, "week trend includes Tuesday data")
assertEqual(trend[1].characters, 3_500, "week trend includes Wednesday data")
assertEqual(trend[0].averageSpeedPerHour, Optional(8_000), "week trend exposes speed values")
assertEqual(trend[0].value(for: .characters), Optional(6_000), "trend character metric uses characters")
assertEqual(trend[0].value(for: .duration), Optional(2_700), "trend duration metric uses reading time")
assertEqual(trend[0].value(for: .speed), Optional(8_000), "trend speed metric uses average speed")

let dailyRangeTrend = StatisticsDashboardCalculator.trendPoints(
    grain: .day,
    range: StatisticsDateRange(start: june24, end: today),
    days: days,
    calendar: calendar
)
assertEqual(dailyRangeTrend.count, 8, "day trend fills every calendar day in the selected range")
assertEqual(dailyRangeTrend[0].id, "2026-06-24", "day trend starts at the selected range start")
assertEqual(dailyRangeTrend[3].id, "2026-06-27", "day trend includes missing days")
assertEqual(dailyRangeTrend[3].characters, 0, "day trend fills missing days with zero values")
assertEqual(dailyRangeTrend[6].characters, 6_000, "day trend keeps recorded daily values")
assertEqual(dailyRangeTrend[7].id, "2026-07-01", "day trend ends at the selected range end")

let june20 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 20))!
let june23 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 23))!
let july3 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 3))!
let paddedDailyTrend = StatisticsDashboardCalculator.trendPoints(
    grain: .day,
    range: StatisticsDateRange(start: june20, end: july3),
    days: days,
    calendar: calendar
)
assertEqual(paddedDailyTrend.count, 8, "day trend trims inactive leading and trailing range edges")
assertEqual(paddedDailyTrend.first?.id, "2026-06-24", "day trend starts at the first active day in range")
assertEqual(paddedDailyTrend.last?.id, "2026-07-01", "day trend ends at the last active day in range")

let emptyDailyTrend = StatisticsDashboardCalculator.trendPoints(
    grain: .day,
    range: StatisticsDateRange(start: june20, end: june23),
    days: days,
    calendar: calendar
)
assertEqual(emptyDailyTrend.count, 0, "day trend returns no points when the selected range has no records")

let weeklyRangeTrend = StatisticsDashboardCalculator.trendPoints(
    grain: .week,
    range: StatisticsDateRange(start: june24, end: today),
    days: days,
    calendar: calendar
)
assertEqual(weeklyRangeTrend.count, 2, "week trend fills every week touched by the selected range")
assertEqual(weeklyRangeTrend[0].characters, 14_300, "week trend aggregates clipped first-week days")
assertEqual(weeklyRangeTrend[1].characters, 9_500, "week trend aggregates clipped final-week days")

let monthlyRangeTrend = StatisticsDashboardCalculator.trendPoints(
    grain: .month,
    range: StatisticsDateRange(start: june24, end: today),
    days: days,
    calendar: calendar
)
assertEqual(monthlyRangeTrend.count, 2, "month trend fills every month touched by the selected range")
assertEqual(monthlyRangeTrend[0].id, "2026-06", "month trend uses stable year-month ids")
assertEqual(monthlyRangeTrend[0].characters, 20_300, "month trend aggregates selected June days")
assertEqual(monthlyRangeTrend[1].id, "2026-07", "month trend includes the selected July tail")
assertEqual(monthlyRangeTrend[1].characters, 3_500, "month trend aggregates selected July days")

let rankedByCharacters = StatisticsDashboardCalculator.bookRankingRows(
    days: days,
    range: StatisticsDateRange(start: june24, end: today),
    metric: .characters,
    limit: 8
)
assertEqual(rankedByCharacters.map(\.title), ["Alpha", "Beta"], "book ranking sorts by selected character metric")
assertEqual(rankedByCharacters[0].characters, 18_300, "book ranking sums per-book characters")
assertEqual(rankedByCharacters[1].readingTime, 2_700, "book ranking keeps per-book duration")

let rankedByDuration = StatisticsDashboardCalculator.bookRankingRows(
    days: days,
    range: StatisticsDateRange(start: june24, end: today),
    metric: .duration,
    limit: 8
)
assertEqual(rankedByDuration.map(\.title), ["Alpha", "Beta"], "book ranking sorts by selected duration metric")
assertEqual(rankedByDuration[0].readingTime, 8_600, "duration ranking sums reading time")

let rankedBySpeed = StatisticsDashboardCalculator.bookRankingRows(
    days: days,
    range: StatisticsDateRange(start: june24, end: today),
    metric: .speed,
    limit: 8
)
assertEqual(rankedBySpeed.map(\.title), ["Alpha", "Beta"], "book ranking sorts by weighted book speed")
assertEqual(rankedBySpeed[0].averageSpeedPerHour, Optional(7_660), "book ranking calculates per-book weighted speed")

let limitedRanking = StatisticsDashboardCalculator.bookRankingRows(
    days: days,
    range: StatisticsDateRange(start: june24, end: today),
    metric: .characters,
    limit: 1
)
assertEqual(limitedRanking.count, 1, "book ranking respects top limit")

let shelfRows = StatisticsDashboardCalculator.shelfComparisonRows(
    books: bookRecords,
    shelves: [
        BookShelf(name: "Favorites", bookIds: [firstBook.bookID]),
        BookShelf(name: "Mixed", bookIds: [firstBook.bookID, secondBook.bookID])
    ],
    days: days,
    range: StatisticsDateRange(start: june24, end: today),
    unshelvedName: "Unshelved",
    calendar: calendar
)
assertEqual(shelfRows.map(\.name), ["Mixed", "Favorites", "Unshelved"], "shelf comparison sorts by recorded characters and includes unshelved books")
assertEqual(shelfRows[0].bookCount, 2, "shelf comparison counts books in a shelf")
assertEqual(shelfRows[0].totalCharacters, 150_000, "shelf comparison sums total book characters")
assertEqual(shelfRows[0].recordedCharacters, 23_800, "shelf comparison sums recorded characters")
assertEqual(shelfRows[0].readingTime, 11_300, "shelf comparison sums reading time")
assertEqual(shelfRows[0].averageSpeedPerHour, Optional(7_582), "shelf comparison calculates weighted speed")
assertEqual(shelfRows[2].bookCount, 1, "shelf comparison includes books outside all shelves")
assertEqual(shelfRows[2].recordedCharacters, 0, "unshelved row can represent books with no selected-range records")

let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hoshi-statistics-dashboard-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempRoot) }

let validBookID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
let invalidBookID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
let validBook = BookMetadata(id: validBookID, title: "Valid Book", cover: "cover.jpg", folder: "valid", lastAccess: today)
let invalidBook = BookMetadata(id: invalidBookID, title: "Broken Book", cover: nil, folder: "broken", lastAccess: today)
let validRoot = tempRoot.appendingPathComponent(validBook.folder)
let invalidRoot = tempRoot.appendingPathComponent(invalidBook.folder)
try FileManager.default.createDirectory(at: validRoot, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
try Data(#"{"characterCount":2500,"chapterInfo":{}}"#.utf8).write(to: validRoot.appendingPathComponent("bookinfo.json"))
let validStats = [
    Statistics(title: "Ignored Title", dateKey: "2026-07-01", charactersRead: 1_200, readingTime: 600, minReadingSpeed: 0, altMinReadingSpeed: 0, lastReadingSpeed: 7_200, maxReadingSpeed: 7_200, lastStatisticModified: 1)
]
let encoded = try JSONEncoder().encode(validStats)
try encoded.write(to: validRoot.appendingPathComponent("statistics.json"))
try Data("{not-json".utf8).write(to: invalidRoot.appendingPathComponent("statistics.json"))

let loaded = StatisticsDashboardRepository.loadSnapshot(books: [validBook, invalidBook], booksDirectory: tempRoot, calendar: calendar)
assertEqual(loaded.days.count, 1, "repository loads valid statistics")
assertEqual(loaded.books.count, 2, "repository records every local book for shelf comparison")
assertEqual(loaded.books.first { $0.id == validBookID }?.totalCharacters, Optional(2_500), "repository loads bookinfo character count")
assertEqual(loaded.books.first { $0.id == invalidBookID }?.totalCharacters, Optional(0), "repository keeps books without bookinfo with zero total characters")
assertEqual(loaded.days[0].characters, 1_200, "repository preserves characters")
assertEqual(loaded.days[0].bookContributions[0].title, "Valid Book", "repository prefers current display title")
assertEqual(loaded.days[0].bookContributions[0].coverPath, validRoot.appendingPathComponent("cover.jpg").path(percentEncoded: false), "repository resolves relative cover paths from the book root")
assertEqual(loaded.skippedCorruptBookIDs, [invalidBookID], "repository reports corrupt statistics")

let cacheInputs = [validBook, invalidBook].map {
    StatisticsBookSnapshotInput(id: $0.id, title: $0.displayTitle, cover: $0.cover, folder: $0.folder)
}
StatisticsDashboardRepository.storeCachedSnapshot(loaded, bookInputs: cacheInputs, booksDirectory: tempRoot)
assertEqual(
    StatisticsDashboardRepository.cachedSnapshot(bookInputs: cacheInputs, booksDirectory: tempRoot),
    Optional(loaded),
    "repository reads cached dashboard snapshots"
)
let renamedInputs = [
    StatisticsBookSnapshotInput(id: validBook.id, title: "Renamed Book", cover: validBook.cover, folder: validBook.folder),
    StatisticsBookSnapshotInput(id: invalidBook.id, title: invalidBook.displayTitle, cover: invalidBook.cover, folder: invalidBook.folder)
]
assertEqual(
    StatisticsDashboardRepository.cachedSnapshot(bookInputs: renamedInputs, booksDirectory: tempRoot),
    nil,
    "repository ignores cache entries for a different visible book set"
)
assertEqual(
    StatisticsTargetSettings.snapCharacterTarget(60_000),
    50_000,
    "character goals clamp at 50,000"
)

print("statistics dashboard calculation tests passed")
}
}
