// test-sources: Models/Statistics.swift
import Foundation

@main
enum StatisticsDayBoundaryTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let beforeReset = makeDate(
            year: 2026,
            month: 8,
            day: 10,
            hour: 3,
            minute: 59,
            calendar: calendar
        )
        let atReset = makeDate(
            year: 2026,
            month: 8,
            day: 10,
            hour: 4,
            minute: 0,
            calendar: calendar
        )

        require(
            StatisticsDayBoundary.dateKey(
                for: beforeReset,
                resetMinutes: 4 * 60,
                calendar: calendar
            ) == "2026-08-09",
            "times before reset belong to the previous reporting day"
        )
        require(
            StatisticsDayBoundary.dateKey(
                for: atReset,
                resetMinutes: 4 * 60,
                calendar: calendar
            ) == "2026-08-10",
            "the reset minute begins the new reporting day"
        )
        require(
            StatisticsDayBoundary.dateKey(
                for: beforeReset,
                resetMinutes: 0,
                calendar: calendar
            ) == "2026-08-10",
            "midnight preserves calendar-day behavior"
        )
        require(
            StatisticsDayBoundary.normalizedResetMinutes(-30) == 0,
            "negative reset values clamp to midnight"
        )
        require(
            StatisticsDayBoundary.normalizedResetMinutes(2_000) == 1_439,
            "reset values clamp to the final minute of the day"
        )

        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstMorning = makeDate(
            year: 2026,
            month: 3,
            day: 8,
            hour: 3,
            minute: 30,
            calendar: calendar
        )
        require(
            StatisticsDayBoundary.dateKey(
                for: dstMorning,
                resetMinutes: 4 * 60,
                calendar: calendar
            ) == "2026-03-07",
            "daylight-saving transitions still honor the local reset time"
        )

        let suiteName = "moe.shishamo.hoshi.tests.statistics-reset.\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        require(
            StatisticsResetTimePreference.load(from: defaults) == 0,
            "missing preferences default to midnight"
        )
        defaults.set(4, forKey: StatisticsResetTimePreference.resetTimeKey)
        require(
            StatisticsResetTimePreference.load(from: defaults) == 240,
            "legacy hour values migrate to minutes"
        )
        require(
            defaults.bool(forKey: StatisticsResetTimePreference.minutesMigrationKey),
            "hour-to-minute migration is recorded"
        )

        StatisticsResetTimePreference.save(275, to: defaults)
        require(
            StatisticsResetTimePreference.load(from: defaults) == 275,
            "minute-level preferences round-trip without remigration"
        )

        print("Statistics day-boundary tests passed")
    }
}
