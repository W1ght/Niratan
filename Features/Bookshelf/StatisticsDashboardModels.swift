//
//  StatisticsDashboardModels.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum StatisticsRangeMode: String, CaseIterable, Identifiable {
    case year
    case month
    case week
    case day

    var id: String { rawValue }
}

enum DailyTargetType: String, CaseIterable, Codable, Identifiable {
    case characters
    case duration

    var id: String { rawValue }
}

enum StatisticsTrendMetric: String, CaseIterable, Identifiable {
    case characters
    case duration
    case speed

    var id: String { rawValue }
}

enum StatisticsTrendGrain: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }
}

enum StatisticsBookRankingMetric: String, CaseIterable, Identifiable {
    case characters
    case duration
    case speed

    var id: String { rawValue }
}

struct StatisticsTargetSettings: Equatable {
    var dailyTargetType: DailyTargetType = .characters
    var dailyCharacterTarget: Int = 5_000
    var dailyDurationTargetMinutes: Int = 30
    var weeklyTargetDays: Int = 4

    static let characterTargetRange = 500...50_000
    static let characterTargetStep = 500
    static let durationTargetMinutesRange = 5...240
    static let durationTargetMinutesStep = 5
    static let weeklyTargetDaysRange = 1...7

    func clamped() -> StatisticsTargetSettings {
        StatisticsTargetSettings(
            dailyTargetType: dailyTargetType,
            dailyCharacterTarget: Self.snapCharacterTarget(dailyCharacterTarget),
            dailyDurationTargetMinutes: Self.snapDurationTarget(dailyDurationTargetMinutes),
            weeklyTargetDays: min(max(weeklyTargetDays, Self.weeklyTargetDaysRange.lowerBound), Self.weeklyTargetDaysRange.upperBound)
        )
    }

    static func snapCharacterTarget(_ value: Int) -> Int {
        snap(value, range: characterTargetRange, step: characterTargetStep)
    }

    static func snapDurationTarget(_ value: Int) -> Int {
        snap(value, range: durationTargetMinutesRange, step: durationTargetMinutesStep)
    }

    private static func snap(_ value: Int, range: ClosedRange<Int>, step: Int) -> Int {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let offset = clamped - range.lowerBound
        let snapped = range.lowerBound + ((offset + step / 2) / step) * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

struct StatisticsDateRange: Equatable {
    let start: Date
    let end: Date

    init(start: Date, end: Date) {
        precondition(end >= start, "Statistics range end must be on or after start.")
        self.start = start
        self.end = end
    }

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= start && day <= end
    }

    func coerce(_ date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        if day < start { return start }
        if day > end { return end }
        return day
    }

    func dayCount(calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: start, to: end).day.map { $0 + 1 } ?? 1
    }

    static func recentYear(endingAt today: Date, calendar: Calendar) -> StatisticsDateRange {
        let end = calendar.startOfDay(for: today)
        let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: end) ?? end
        let start = calendar.date(byAdding: .day, value: 1, to: oneYearAgo) ?? oneYearAgo
        return StatisticsDateRange(start: start, end: end)
    }

    static func fixedYear(_ year: Int, today: Date, calendar: Calendar) -> StatisticsDateRange {
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? calendar.startOfDay(for: today)
        let end: Date
        if calendar.component(.year, from: today) == year {
            end = calendar.startOfDay(for: today)
        } else {
            end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? start
        }
        return StatisticsDateRange(start: start, end: end)
    }

    static func mondayStartOfWeek(for date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
    }

    static func selectedRange(
        mode: StatisticsRangeMode,
        anchor: Date,
        window: StatisticsDateRange,
        calendar: Calendar
    ) -> StatisticsDateRange {
        let anchor = window.coerce(anchor, calendar: calendar)
        let unclipped: StatisticsDateRange
        switch mode {
        case .year:
            unclipped = window
        case .month:
            let components = calendar.dateComponents([.year, .month], from: anchor)
            let start = calendar.date(from: components) ?? anchor
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            let end = calendar.date(byAdding: .day, value: -1, to: nextMonth) ?? start
            unclipped = StatisticsDateRange(start: start, end: end)
        case .week:
            let start = mondayStartOfWeek(for: anchor, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            unclipped = StatisticsDateRange(start: start, end: end)
        case .day:
            unclipped = StatisticsDateRange(start: anchor, end: anchor)
        }

        return StatisticsDateRange(
            start: max(unclipped.start, window.start),
            end: min(unclipped.end, window.end)
        )
    }
}

struct StatisticsBookContribution: Codable, Equatable {
    let bookID: UUID
    let title: String
    let coverPath: String?
    let characters: Int
    let readingTime: Double
}

struct StatisticsDayAggregate: Codable, Equatable {
    let date: Date
    let characters: Int
    let readingTime: Double
    let bookContributions: [StatisticsBookContribution]

    var activeBookCount: Int {
        bookContributions.filter { $0.characters > 0 || $0.readingTime > 0 }.count
    }

    func targetRatio(settings: StatisticsTargetSettings) -> Double {
        switch settings.dailyTargetType {
        case .characters:
            guard settings.dailyCharacterTarget > 0 else { return 0 }
            return Double(characters) / Double(settings.dailyCharacterTarget)
        case .duration:
            let targetSeconds = Double(settings.dailyDurationTargetMinutes * 60)
            guard targetSeconds > 0 else { return 0 }
            return readingTime / targetSeconds
        }
    }
}

struct StatisticsDashboardSnapshot: Codable, Equatable {
    var days: [StatisticsDayAggregate]
    var books: [StatisticsBookRecord] = []
    var skippedCorruptBookIDs: [UUID] = []
}

struct StatisticsBookRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let coverPath: String?
    let totalCharacters: Int
}

struct StatisticsBookSnapshotInput: Sendable {
    let id: UUID
    let title: String
    let cover: String?
    let folder: String
}

struct StatisticsTodaySummary: Equatable {
    let date: Date
    let targetPercent: Int
    let characters: Int
    let readingTime: Double
    let averageSpeedPerHour: Int?
    let dailyStreakDays: Int
}

struct StatisticsWeekDaySummary: Equatable {
    let date: Date
    let isToday: Bool
    let isFuture: Bool
    let percent: Int?
    let metTarget: Bool
}

struct StatisticsWeekSummary: Equatable {
    let range: StatisticsDateRange
    let elapsedDays: Int
    let characters: Int
    let readingTime: Double
    let averageSpeedPerHour: Int?
    let targetDays: Int
    let metTargetDays: Int
    let dailyStreakDays: Int
    let weeklyStreakWeeks: Int
    let averageCharactersPerElapsedDay: Int
    let averageReadingTimePerElapsedDay: Double
    let days: [StatisticsWeekDaySummary]
}

struct StatisticsRangeSummary: Equatable {
    let characters: Int
    let readingTime: Double
    let averageSpeedPerHour: Int?
    let targetDays: Int
    let targetProgressPercent: Int
}

struct StatisticsSpeedDay: Equatable {
    let date: Date
    let speedPerHour: Int
}

struct StatisticsSpeedSummary: Equatable {
    let weightedAverageSpeedPerHour: Int?
    let medianDaySpeedPerHour: Int?
    let recentActiveDaySpeedPerHour: Int?
    let speedChangePercent: Int?
    let bestDay: StatisticsSpeedDay?
    let worstDay: StatisticsSpeedDay?
}

struct StatisticsTrendPoint: Equatable, Identifiable {
    let id: String
    let label: String
    let characters: Int
    let readingTime: Double
    let averageSpeedPerHour: Int?
    let bookBreakdown: [StatisticsTrendBookBreakdown]

    func value(for metric: StatisticsTrendMetric) -> Double? {
        switch metric {
        case .characters:
            Double(characters)
        case .duration:
            readingTime
        case .speed:
            averageSpeedPerHour.map(Double.init)
        }
    }
}

struct StatisticsTrendBookBreakdown: Equatable, Identifiable {
    let title: String
    let characters: Int

    var id: String { title }
}

struct StatisticsBookRankingRow: Equatable, Identifiable {
    let id: UUID
    let title: String
    let characters: Int
    let readingTime: Double
    let averageSpeedPerHour: Int?
}

struct StatisticsShelfComparisonRow: Equatable, Identifiable {
    let id: String
    let name: String
    let bookCount: Int
    let totalCharacters: Int
    let recordedCharacters: Int
    let readingTime: Double
    let averageSpeedPerHour: Int?
}

enum StatisticsDashboardCalculator {
    private static let minimumSpeedSampleSeconds: Double = 60

    static func todaySummary(
        snapshot: StatisticsDashboardSnapshot,
        today: Date,
        settings: StatisticsTargetSettings,
        calendar: Calendar
    ) -> StatisticsTodaySummary {
        let daysByDate = dictionaryByDate(snapshot.days, calendar: calendar)
        let today = calendar.startOfDay(for: today)
        let aggregate = daysByDate[today] ?? emptyDay(today)
        return StatisticsTodaySummary(
            date: today,
            targetPercent: percent(aggregate.targetRatio(settings: settings)),
            characters: aggregate.characters,
            readingTime: aggregate.readingTime,
            averageSpeedPerHour: averageSpeedPerHourForSpeedSamples([aggregate]),
            dailyStreakDays: dailyGoalStreak(daysByDate: daysByDate, today: today, settings: settings, calendar: calendar)
        )
    }

    static func weekSummary(
        snapshot: StatisticsDashboardSnapshot,
        today: Date,
        settings: StatisticsTargetSettings,
        calendar: Calendar
    ) -> StatisticsWeekSummary {
        let daysByDate = dictionaryByDate(snapshot.days, calendar: calendar)
        let today = calendar.startOfDay(for: today)
        let start = StatisticsDateRange.mondayStartOfWeek(for: today, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let range = StatisticsDateRange(start: start, end: end)
        let dates = dates(in: range, calendar: calendar)
        let aggregates = dates.map { daysByDate[$0] ?? emptyDay($0) }
        let summary = aggregateRange(aggregates, settings: settings)
        let elapsedDays = min(max(calendar.dateComponents([.day], from: start, to: today).day.map { $0 + 1 } ?? 1, 1), 7)

        return StatisticsWeekSummary(
            range: range,
            elapsedDays: elapsedDays,
            characters: summary.characters,
            readingTime: summary.readingTime,
            averageSpeedPerHour: summary.averageSpeedPerHour,
            targetDays: settings.weeklyTargetDays,
            metTargetDays: aggregates.filter { $0.targetRatio(settings: settings) >= 1 }.count,
            dailyStreakDays: dailyGoalStreak(daysByDate: daysByDate, today: today, settings: settings, calendar: calendar),
            weeklyStreakWeeks: weeklyGoalStreak(daysByDate: daysByDate, today: today, settings: settings, calendar: calendar),
            averageCharactersPerElapsedDay: Int((Double(summary.characters) / Double(elapsedDays)).rounded()),
            averageReadingTimePerElapsedDay: summary.readingTime / Double(elapsedDays),
            days: dates.map { date in
                let aggregate = daysByDate[date]
                let isFuture = date > today
                let ratio = aggregate?.targetRatio(settings: settings) ?? 0
                return StatisticsWeekDaySummary(
                    date: date,
                    isToday: date == today,
                    isFuture: isFuture,
                    percent: aggregate == nil || isFuture ? nil : percent(ratio),
                    metTarget: !isFuture && ratio >= 1
                )
            }
        )
    }

    static func rangeSummary(
        days: [StatisticsDayAggregate],
        range: StatisticsDateRange,
        settings: StatisticsTargetSettings,
        calendar: Calendar
    ) -> StatisticsRangeSummary {
        let rangeDays = dates(in: range, calendar: calendar)
        let daysByDate = dictionaryByDate(days, calendar: calendar)
        return aggregateRange(rangeDays.map { daysByDate[$0] ?? emptyDay($0) }, settings: settings)
    }

    static func speedSummary(
        days: [StatisticsDayAggregate],
        range: StatisticsDateRange,
        calendar: Calendar
    ) -> StatisticsSpeedSummary {
        let activeDays = days
            .filter { range.contains($0.date, calendar: calendar) && !speedSamples(in: $0).isEmpty }
            .sorted { $0.date < $1.date }
        let speedDays = activeDays.map { day in
            StatisticsSpeedDay(
                date: calendar.startOfDay(for: day.date),
                speedPerHour: averageSpeedPerHourForSpeedSamples([day]) ?? 0
            )
        }
        let weightedSpeed = averageSpeedPerHourForSpeedSamples(activeDays)
        let recent = Array(activeDays.suffix(7))
        let recentSpeed = averageSpeedPerHourForSpeedSamples(recent)

        return StatisticsSpeedSummary(
            weightedAverageSpeedPerHour: weightedSpeed,
            medianDaySpeedPerHour: median(speedDays.map(\.speedPerHour)),
            recentActiveDaySpeedPerHour: recentSpeed,
            speedChangePercent: speedChangePercent(activeDays: activeDays),
            bestDay: speedDays.max {
                if $0.speedPerHour != $1.speedPerHour {
                    return $0.speedPerHour < $1.speedPerHour
                }
                return $0.date > $1.date
            },
            worstDay: speedDays.min {
                if $0.speedPerHour != $1.speedPerHour {
                    return $0.speedPerHour < $1.speedPerHour
                }
                return $0.date < $1.date
            }
        )
    }

    static func trendPoints(
        grain: StatisticsTrendGrain,
        range: StatisticsDateRange,
        days: [StatisticsDayAggregate],
        calendar: Calendar
    ) -> [StatisticsTrendPoint] {
        let daysInRange = days
            .filter { range.contains($0.date, calendar: calendar) }
            .sorted { $0.date < $1.date }
        guard let trendRange = activeTrendRange(from: daysInRange, calendar: calendar) else {
            return []
        }
        switch grain {
        case .day:
            let daysByDate = dictionaryByDate(days, calendar: calendar)
            return dates(in: trendRange, calendar: calendar).map { date in
                trendPoint(
                    id: isoDateString(date, calendar: calendar),
                    label: compactDayString(date, calendar: calendar),
                    days: daysByDate[date].map { [$0] } ?? []
                )
            }
        case .week:
            let grouped = Dictionary(grouping: daysInRange) { day in
                StatisticsDateRange.mondayStartOfWeek(for: day.date, calendar: calendar)
            }
            var result: [StatisticsTrendPoint] = []
            var cursor = StatisticsDateRange.mondayStartOfWeek(for: trendRange.start, calendar: calendar)
            while cursor <= trendRange.end {
                result.append(
                    trendPoint(
                        id: isoWeekString(cursor, calendar: calendar),
                        label: isoWeekString(cursor, calendar: calendar),
                        days: grouped[cursor].orEmpty
                    )
                )
                guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
                cursor = next
            }
            return result
        case .month:
            let grouped = Dictionary(grouping: daysInRange) { day in
                monthStart(for: day.date, calendar: calendar)
            }
            var result: [StatisticsTrendPoint] = []
            var cursor = monthStart(for: trendRange.start, calendar: calendar)
            let endMonth = monthStart(for: trendRange.end, calendar: calendar)
            while cursor <= endMonth {
                result.append(
                    trendPoint(
                        id: monthString(cursor, calendar: calendar),
                        label: monthString(cursor, calendar: calendar),
                        days: grouped[cursor].orEmpty
                    )
                )
                guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
            }
            return result
        }
    }

    static func bookRankingRows(
        days: [StatisticsDayAggregate],
        range: StatisticsDateRange,
        metric: StatisticsBookRankingMetric,
        limit: Int
    ) -> [StatisticsBookRankingRow] {
        var grouped: [UUID: [StatisticsBookContribution]] = [:]
        for day in days where range.contains(day.date, calendar: .current) {
            for contribution in day.bookContributions where contribution.characters > 0 || contribution.readingTime > 0 {
                grouped[contribution.bookID, default: []].append(contribution)
            }
        }

        return grouped.compactMap { bookID, contributions -> StatisticsBookRankingRow? in
            guard let first = contributions.first else { return nil }
            return StatisticsBookRankingRow(
                id: bookID,
                title: first.title,
                characters: contributions.reduce(0) { $0 + $1.characters },
                readingTime: contributions.reduce(0) { $0 + $1.readingTime },
                averageSpeedPerHour: averageSpeedPerHourForSpeedSamples(in: contributions)
            )
        }
        .filter { bookRankingValue($0, metric: metric) > 0 }
        .sorted {
            let left = bookRankingValue($0, metric: metric)
            let right = bookRankingValue($1, metric: metric)
            if left != right {
                return left > right
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        .prefix(max(limit, 0))
        .map { $0 }
    }

    static func shelfComparisonRows(
        books: [StatisticsBookRecord],
        shelves: [BookShelf],
        days: [StatisticsDayAggregate],
        range: StatisticsDateRange,
        unshelvedName: String,
        calendar: Calendar
    ) -> [StatisticsShelfComparisonRow] {
        let bookIDs = Set(books.map(\.id))
        let contributionsByBook = contributionsByBook(days: days, range: range, calendar: calendar)
        var rows: [StatisticsShelfComparisonRow] = []
        var shelvedIDs = Set<UUID>()

        for shelf in shelves {
            let ids = shelf.bookIds.filter { bookIDs.contains($0) }
            shelvedIDs.formUnion(ids)
            rows.append(
                shelfComparisonRow(
                    id: "shelf:\(shelf.name)",
                    name: shelf.name,
                    bookIDs: Set(ids),
                    books: books,
                    contributionsByBook: contributionsByBook
                )
            )
        }

        let unshelvedIDs = bookIDs.subtracting(shelvedIDs)
        if !unshelvedIDs.isEmpty {
            rows.append(
                shelfComparisonRow(
                    id: "unshelved",
                    name: unshelvedName,
                    bookIDs: unshelvedIDs,
                    books: books,
                    contributionsByBook: contributionsByBook
                )
            )
        }

        return rows
            .filter { $0.bookCount > 0 }
            .sorted {
                if $0.recordedCharacters != $1.recordedCharacters {
                    return $0.recordedCharacters > $1.recordedCharacters
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    static func dates(in range: StatisticsDateRange, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        var cursor = range.start
        while cursor <= range.end {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return dates
    }

    static func averageSpeedPerHour(characters: Int, readingTime: Double) -> Int {
        guard readingTime > 0 else { return 0 }
        return Int((Double(characters) / readingTime * 3_600).rounded())
    }

    private static func averageSpeedPerHourForSpeedSamples(_ days: [StatisticsDayAggregate]) -> Int? {
        let samples = days.flatMap(speedSamples)
        guard !samples.isEmpty else { return nil }
        return averageSpeedPerHour(
            characters: samples.reduce(0) { $0 + $1.characters },
            readingTime: samples.reduce(0) { $0 + $1.readingTime }
        )
    }

    private static func speedSamples(in day: StatisticsDayAggregate) -> [(characters: Int, readingTime: Double)] {
        if day.bookContributions.isEmpty {
            guard day.characters > 0 && day.readingTime >= minimumSpeedSampleSeconds else { return [] }
            return [(day.characters, day.readingTime)]
        }
        return day.bookContributions.compactMap { contribution in
            guard contribution.characters > 0 && contribution.readingTime >= minimumSpeedSampleSeconds else { return nil }
            return (contribution.characters, contribution.readingTime)
        }
    }

    private static func averageSpeedPerHourForSpeedSamples(in contributions: [StatisticsBookContribution]) -> Int? {
        let samples = contributions.compactMap { contribution -> (characters: Int, readingTime: Double)? in
            guard contribution.characters > 0 && contribution.readingTime >= minimumSpeedSampleSeconds else { return nil }
            return (contribution.characters, contribution.readingTime)
        }
        guard !samples.isEmpty else { return nil }
        return averageSpeedPerHour(
            characters: samples.reduce(0) { $0 + $1.characters },
            readingTime: samples.reduce(0) { $0 + $1.readingTime }
        )
    }

    private static func aggregateRange(_ days: [StatisticsDayAggregate], settings: StatisticsTargetSettings) -> StatisticsRangeSummary {
        let characters = days.reduce(0) { $0 + $1.characters }
        let readingTime = days.reduce(0) { $0 + $1.readingTime }
        return StatisticsRangeSummary(
            characters: characters,
            readingTime: readingTime,
            averageSpeedPerHour: averageSpeedPerHourForSpeedSamples(days),
            targetDays: days.filter { $0.targetRatio(settings: settings) >= 1 }.count,
            targetProgressPercent: days.count == 1 ? percent(days[0].targetRatio(settings: settings)) : 0
        )
    }

    private static func dailyGoalStreak(
        daysByDate: [Date: StatisticsDayAggregate],
        today: Date,
        settings: StatisticsTargetSettings,
        calendar: Calendar
    ) -> Int {
        var cursor = today
        if (daysByDate[today]?.targetRatio(settings: settings) ?? 0) < 1 {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }

        var streak = 0
        while (daysByDate[cursor]?.targetRatio(settings: settings) ?? 0) >= 1 {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return streak
    }

    private static func weeklyGoalStreak(
        daysByDate: [Date: StatisticsDayAggregate],
        today: Date,
        settings: StatisticsTargetSettings,
        calendar: Calendar
    ) -> Int {
        var weekStart = StatisticsDateRange.mondayStartOfWeek(for: today, calendar: calendar)
        if !weekMet(daysByDate: daysByDate, weekStart: weekStart, settings: settings, calendar: calendar) {
            weekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        }

        var streak = 0
        while weekMet(daysByDate: daysByDate, weekStart: weekStart, settings: settings, calendar: calendar) {
            streak += 1
            weekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        }
        return streak
    }

    private static func weekMet(
        daysByDate: [Date: StatisticsDayAggregate],
        weekStart: Date,
        settings: StatisticsTargetSettings,
        calendar: Calendar
    ) -> Bool {
        (0..<7).filter { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return false }
            return (daysByDate[date]?.targetRatio(settings: settings) ?? 0) >= 1
        }.count >= settings.weeklyTargetDays
    }

    private static func dictionaryByDate(_ days: [StatisticsDayAggregate], calendar: Calendar) -> [Date: StatisticsDayAggregate] {
        Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.date), $0) })
    }

    private static func emptyDay(_ date: Date) -> StatisticsDayAggregate {
        StatisticsDayAggregate(date: date, characters: 0, readingTime: 0, bookContributions: [])
    }

    private static func bookRankingValue(_ row: StatisticsBookRankingRow, metric: StatisticsBookRankingMetric) -> Double {
        switch metric {
        case .characters:
            Double(row.characters)
        case .duration:
            row.readingTime
        case .speed:
            Double(row.averageSpeedPerHour ?? 0)
        }
    }

    private static func contributionsByBook(
        days: [StatisticsDayAggregate],
        range: StatisticsDateRange,
        calendar: Calendar
    ) -> [UUID: [StatisticsBookContribution]] {
        var grouped: [UUID: [StatisticsBookContribution]] = [:]
        for day in days where range.contains(day.date, calendar: calendar) {
            for contribution in day.bookContributions where contribution.characters > 0 || contribution.readingTime > 0 {
                grouped[contribution.bookID, default: []].append(contribution)
            }
        }
        return grouped
    }

    private static func shelfComparisonRow(
        id: String,
        name: String,
        bookIDs: Set<UUID>,
        books: [StatisticsBookRecord],
        contributionsByBook: [UUID: [StatisticsBookContribution]]
    ) -> StatisticsShelfComparisonRow {
        let records = books.filter { bookIDs.contains($0.id) }
        let contributions = bookIDs.flatMap { contributionsByBook[$0].orEmpty }
        return StatisticsShelfComparisonRow(
            id: id,
            name: name,
            bookCount: records.count,
            totalCharacters: records.reduce(0) { $0 + $1.totalCharacters },
            recordedCharacters: contributions.reduce(0) { $0 + $1.characters },
            readingTime: contributions.reduce(0) { $0 + $1.readingTime },
            averageSpeedPerHour: averageSpeedPerHourForSpeedSamples(in: contributions)
        )
    }

    private static func percent(_ ratio: Double) -> Int {
        Int((ratio * 100).rounded())
    }

    private static func median(_ values: [Int]) -> Int? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Int((Double(sorted[middle - 1] + sorted[middle]) / 2).rounded())
        }
        return sorted[middle]
    }

    private static func speedChangePercent(activeDays: [StatisticsDayAggregate]) -> Int? {
        guard activeDays.count >= 28 else { return nil }
        let earlyDays = Array(activeDays.prefix(14))
        let recentDays = Array(activeDays.suffix(14))
        guard let earlySpeed = averageSpeedPerHourForSpeedSamples(earlyDays),
              let recentSpeed = averageSpeedPerHourForSpeedSamples(recentDays) else { return nil }
        guard earlySpeed > 0 else { return nil }
        return Int(((Double(recentSpeed - earlySpeed) / Double(earlySpeed)) * 100).rounded())
    }

    private static func activeTrendRange(
        from days: [StatisticsDayAggregate],
        calendar: Calendar
    ) -> StatisticsDateRange? {
        guard let first = days.first, let last = days.last else { return nil }
        return StatisticsDateRange(
            start: calendar.startOfDay(for: first.date),
            end: calendar.startOfDay(for: last.date)
        )
    }

    private static func isoDateString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func compactDayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }

    private static func monthStart(for date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))
            .map(calendar.startOfDay(for:)) ?? calendar.startOfDay(for: date)
    }

    private static func monthString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private static func isoWeekString(_ date: Date, calendar: Calendar) -> String {
        var isoCalendar = Calendar(identifier: .iso8601)
        isoCalendar.timeZone = calendar.timeZone
        let components = isoCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", components.yearForWeekOfYear ?? 0, components.weekOfYear ?? 0)
    }

    private static func trendPoint(id: String, label: String, days: [StatisticsDayAggregate]) -> StatisticsTrendPoint {
        StatisticsTrendPoint(
            id: id,
            label: label,
            characters: days.reduce(0) { $0 + $1.characters },
            readingTime: days.reduce(0) { $0 + $1.readingTime },
            averageSpeedPerHour: averageSpeedPerHourForSpeedSamples(days),
            bookBreakdown: trendBookBreakdown(days: days)
        )
    }

    private static func trendBookBreakdown(days: [StatisticsDayAggregate]) -> [StatisticsTrendBookBreakdown] {
        var grouped: [String: Int] = [:]
        for contribution in days.flatMap(\.bookContributions) where contribution.characters > 0 {
            grouped[contribution.title, default: 0] += contribution.characters
        }
        return grouped
            .map { StatisticsTrendBookBreakdown(title: $0.key, characters: $0.value) }
            .sorted {
                if $0.characters != $1.characters {
                    return $0.characters > $1.characters
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            .prefix(5)
            .map { $0 }
    }
}

enum StatisticsDashboardRepository {
    nonisolated private static let bookInfoFileName = "bookinfo.json"
    nonisolated private static let cacheFileName = "statistics_dashboard_cache.json"
    nonisolated private static let cacheSchemaVersion = 1
    nonisolated private static let memoryCache = StatisticsDashboardMemoryCache()

    static func loadSnapshot(
        books: [BookMetadata],
        booksDirectory: URL,
        calendar: Calendar
    ) -> StatisticsDashboardSnapshot {
        loadSnapshot(
            bookInputs: books.map {
                StatisticsBookSnapshotInput(
                    id: $0.id,
                    title: $0.displayTitle,
                    cover: $0.cover,
                    folder: $0.folder
                )
            },
            booksDirectory: booksDirectory,
            calendar: calendar
        )
    }

    nonisolated static func loadSnapshot(
        bookInputs: [StatisticsBookSnapshotInput],
        booksDirectory: URL,
        calendar: Calendar,
        resetMinutes: Int = StatisticsStorage.currentResetMinutes
    ) -> StatisticsDashboardSnapshot {
        var skippedCorruptBookIDs: [UUID] = []
        var contributionsByDate: [Date: [StatisticsBookContribution]] = [:]
        var bookRecords: [StatisticsBookRecord] = []

        for book in bookInputs {
            let root = booksDirectory.appendingPathComponent(book.folder)
            let coverPath = resolvedCoverPath(
                for: book,
                root: root,
                booksDirectory: booksDirectory
            )
            bookRecords.append(
                StatisticsBookRecord(
                    id: book.id,
                    title: book.title,
                    coverPath: coverPath,
                    totalCharacters: loadBookCharacterCount(root: root) ?? 0
                )
            )

            guard StatisticsStorage.hasStatistics(root: root) else {
                continue
            }

            // Days are derived from sessions, so they follow the current reset time.
            guard let statistics = StatisticsStorage.dailyStatistics(root: root, resetMinutes: resetMinutes) else {
                skippedCorruptBookIDs.append(book.id)
                continue
            }

            for statistic in statistics where statistic.charactersRead > 0 || statistic.readingTime > 0 {
                guard let date = parseDateKey(statistic.dateKey, calendar: calendar) else { continue }
                let contribution = StatisticsBookContribution(
                    bookID: book.id,
                    title: book.title.isEmpty ? statistic.title : book.title,
                    coverPath: coverPath,
                    characters: statistic.charactersRead,
                    readingTime: statistic.readingTime
                )
                contributionsByDate[date, default: []].append(contribution)
            }
        }

        let days = contributionsByDate
            .map { date, contributions in
                StatisticsDayAggregate(
                    date: date,
                    characters: contributions.reduce(0) { $0 + $1.characters },
                    readingTime: contributions.reduce(0) { $0 + $1.readingTime },
                    bookContributions: contributions.sorted {
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }
                )
            }
            .sorted { $0.date < $1.date }

        return StatisticsDashboardSnapshot(
            days: days,
            books: bookRecords.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            skippedCorruptBookIDs: skippedCorruptBookIDs
        )
    }

    nonisolated static func cachedSnapshot(
        bookInputs: [StatisticsBookSnapshotInput],
        booksDirectory: URL
    ) -> StatisticsDashboardSnapshot? {
        let key = cacheKey(for: bookInputs)
        if let snapshot = memoryCache.snapshot(for: key) {
            return snapshot
        }

        let url = cacheURL(booksDirectory: booksDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }

        do {
            let payload = try JSONDecoder().decode(StatisticsDashboardCachePayload.self, from: data)
            guard payload.schemaVersion == cacheSchemaVersion, payload.cacheKey == key else {
                return nil
            }
            memoryCache.store(payload.snapshot, for: key)
            return payload.snapshot
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    nonisolated static func storeCachedSnapshot(
        _ snapshot: StatisticsDashboardSnapshot,
        bookInputs: [StatisticsBookSnapshotInput],
        booksDirectory: URL
    ) {
        let key = cacheKey(for: bookInputs)
        memoryCache.store(snapshot, for: key)

        let payload = StatisticsDashboardCachePayload(
            schemaVersion: cacheSchemaVersion,
            cacheKey: key,
            createdAt: Date(),
            snapshot: snapshot
        )
        let url = cacheURL(booksDirectory: booksDirectory)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func cacheURL(booksDirectory: URL) -> URL {
        booksDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(cacheFileName)
    }

    nonisolated private static func cacheKey(for bookInputs: [StatisticsBookSnapshotInput]) -> String {
        bookInputs
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { input in
                [
                    input.id.uuidString,
                    input.folder,
                    input.title,
                    input.cover ?? ""
                ].joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")
    }

    nonisolated private static func loadBookCharacterCount(root: URL) -> Int? {
        let url = root.appendingPathComponent(bookInfoFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let characterCount = object["characterCount"] as? Int
        else {
            return nil
        }
        return characterCount
    }

    nonisolated private static func parseDateKey(_ dateKey: String, calendar: Calendar) -> Date? {
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            .map(calendar.startOfDay(for:))
    }

    nonisolated private static func resolvedCoverPath(for book: StatisticsBookSnapshotInput, root: URL, booksDirectory: URL) -> String? {
        guard let cover = book.cover else { return nil }
        if cover.hasPrefix("/") {
            return cover
        }
        if cover.hasPrefix("Books/") {
            return booksDirectory
                .deletingLastPathComponent()
                .appendingPathComponent(cover)
                .path(percentEncoded: false)
        }
        return root.appendingPathComponent(cover).path(percentEncoded: false)
    }
}

nonisolated private struct StatisticsDashboardCachePayload: Codable {
    let schemaVersion: Int
    let cacheKey: String
    let createdAt: Date
    let snapshot: StatisticsDashboardSnapshot
}

nonisolated private final class StatisticsDashboardMemoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: StatisticsDashboardSnapshot] = [:]

    nonisolated func snapshot(for key: String) -> StatisticsDashboardSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[key]
    }

    nonisolated func store(_ snapshot: StatisticsDashboardSnapshot, for key: String) {
        lock.lock()
        snapshots[key] = snapshot
        lock.unlock()
    }
}

private extension Optional where Wrapped == [StatisticsDayAggregate] {
    var orEmpty: [StatisticsDayAggregate] {
        self ?? []
    }
}

private extension Optional where Wrapped == [StatisticsBookContribution] {
    var orEmpty: [StatisticsBookContribution] {
        self ?? []
    }
}
