//
//  Statistics.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  Copyright © 2026 ッツ Reader Authors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

enum StatisticsAutostartMode: String, CaseIterable, Codable {
    case off = "Off"
    case pageturn = "Page Turn"
    case on = "On"
}

enum StatisticsSyncMode: String, CaseIterable, Codable {
    case merge = "Merge"
    case replace = "Replace"
}

nonisolated enum StatisticsResetTimePreference {
    static let resetTimeKey = "statisticsResetTime"
    static let minutesMigrationKey = "statisticsResetTimeMigratedToMinutes"

    static func load(from defaults: UserDefaults) -> Int {
        guard let storedValue = defaults.object(forKey: resetTimeKey) as? Int else {
            return 0
        }

        if defaults.bool(forKey: minutesMigrationKey) {
            let normalized = StatisticsDayBoundary.normalizedResetMinutes(storedValue)
            if normalized != storedValue {
                defaults.set(normalized, forKey: resetTimeKey)
            }
            return normalized
        }

        let legacyHours = min(max(storedValue, 0), 23)
        let migratedMinutes = legacyHours * 60
        defaults.set(migratedMinutes, forKey: resetTimeKey)
        defaults.set(true, forKey: minutesMigrationKey)
        return migratedMinutes
    }

    static func save(_ resetMinutes: Int, to defaults: UserDefaults) {
        defaults.set(
            StatisticsDayBoundary.normalizedResetMinutes(resetMinutes),
            forKey: resetTimeKey
        )
        defaults.set(true, forKey: minutesMigrationKey)
    }
}

nonisolated enum StatisticsDayBoundary {
    static let minutesPerDay = 24 * 60

    static func normalizedResetMinutes(_ resetMinutes: Int) -> Int {
        min(max(resetMinutes, 0), minutesPerDay - 1)
    }

    static func reportingDay(
        containing date: Date,
        resetMinutes: Int,
        calendar: Calendar = .current
    ) -> Date {
        let resetMinutes = normalizedResetMinutes(resetMinutes)
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let reportingDate: Date
        if minuteOfDay < resetMinutes {
            reportingDate = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        } else {
            reportingDate = date
        }
        return calendar.startOfDay(for: reportingDate)
    }

    static func dateKey(
        for date: Date,
        resetMinutes: Int,
        calendar: Calendar = .current
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withFullDate]
        return formatter.string(
            from: reportingDay(
                containing: date,
                resetMinutes: resetMinutes,
                calendar: calendar
            )
        )
    }
}

// https://github.com/ttu-ttu/ebook-reader/blob/2703b50ec52b2e4f70afcab725c0f47dd8a66bf4/apps/web/src/lib/data/database/books-db/versions/v6/books-db-v6.ts#L68
struct Statistics: Codable {
    let title: String
    let dateKey: String
    var charactersRead: Int
    var readingTime: Double
    var minReadingSpeed: Int
    var altMinReadingSpeed: Int
    var lastReadingSpeed: Int
    var maxReadingSpeed: Int
    var lastStatisticModified: Int
}

nonisolated enum StatisticsEditor {
    static func visibleStatistics(_ statistics: [Statistics]) -> [Statistics] {
        deduplicated(statistics)
            .filter { $0.charactersRead > 0 || $0.readingTime > 0 }
            .sorted { $0.dateKey < $1.dateKey }
    }

    static func updating(
        dateKey: String,
        title: String,
        charactersRead: Int,
        readingTime: Double,
        modifiedAt: Int,
        in statistics: [Statistics]
    ) -> [Statistics] {
        var records = deduplicated(statistics)
        let charactersRead = max(charactersRead, 0)
        let readingTime = max(readingTime, 0)
        let speed = readingTime > 0
            ? Int((Double(charactersRead) / readingTime) * 3600)
            : 0
        let existingTitle = records.first(where: { $0.dateKey == dateKey })?.title ?? title
        let record = Statistics(
            title: existingTitle,
            dateKey: dateKey,
            charactersRead: charactersRead,
            readingTime: readingTime,
            minReadingSpeed: speed,
            altMinReadingSpeed: speed,
            lastReadingSpeed: speed,
            maxReadingSpeed: speed,
            lastStatisticModified: modifiedAt
        )

        if let index = records.firstIndex(where: { $0.dateKey == dateKey }) {
            records[index] = record
        } else {
            records.append(record)
        }
        return records.sorted { $0.dateKey < $1.dateKey }
    }

    static func deleting(
        dateKey: String,
        title: String,
        modifiedAt: Int,
        from statistics: [Statistics]
    ) -> [Statistics] {
        updating(
            dateKey: dateKey,
            title: title,
            charactersRead: 0,
            readingTime: 0,
            modifiedAt: modifiedAt,
            in: statistics
        )
    }

    static func deletingAll(
        title: String,
        modifiedAt: Int,
        from statistics: [Statistics]
    ) -> [Statistics] {
        deduplicated(statistics)
            .map {
                Statistics(
                    title: $0.title.isEmpty ? title : $0.title,
                    dateKey: $0.dateKey,
                    charactersRead: 0,
                    readingTime: 0,
                    minReadingSpeed: 0,
                    altMinReadingSpeed: 0,
                    lastReadingSpeed: 0,
                    maxReadingSpeed: 0,
                    lastStatisticModified: modifiedAt
                )
            }
            .sorted { $0.dateKey < $1.dateKey }
    }

    static func deduplicated(_ statistics: [Statistics]) -> [Statistics] {
        var grouped: [String: Statistics] = [:]
        for statistic in statistics {
            if let existing = grouped[statistic.dateKey] {
                if statistic.lastStatisticModified > existing.lastStatisticModified {
                    grouped[statistic.dateKey] = statistic
                }
            } else {
                grouped[statistic.dateKey] = statistic
            }
        }
        return Array(grouped.values)
    }
}

nonisolated struct Timestamped<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var modified: Int64
    var value: Value
}

nonisolated enum StatisticsClock {
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

// Upstream Hoshi Reader records one session per reading stint instead of one mutable
// record per day; days and totals are derived from the sessions.
nonisolated struct ReadingSession: Codable, Equatable, Sendable {
    var startedAt: Int64
    var endedAt: Int64
    var charactersRead = 0
    var readingTime = 0.0

    var hasActivity: Bool {
        charactersRead > 0 || readingTime > 0
    }

    var readingSpeed: Int {
        ReadingTotal.speed(charactersRead: charactersRead, readingTime: readingTime)
    }

    var startDate: Date {
        StatisticsClock.date(startedAt)
    }

    var total: ReadingTotal {
        ReadingTotal(charactersRead: charactersRead, readingTime: readingTime)
    }

    mutating func track(characters: Int, time: Double, until date: Date) {
        charactersRead = max(charactersRead + characters, 0)
        readingTime += time
        endedAt = StatisticsClock.milliseconds(date)
    }

    static func starting(at date: Date) -> ReadingSession {
        let timestamp = StatisticsClock.milliseconds(date)
        return ReadingSession(startedAt: timestamp, endedAt: timestamp)
    }
}

nonisolated struct ReadingTotal: Equatable, Sendable {
    var charactersRead = 0
    var readingTime = 0.0

    var readingSpeed: Int {
        Self.speed(charactersRead: charactersRead, readingTime: readingTime)
    }

    var hasActivity: Bool {
        charactersRead > 0 || readingTime > 0
    }

    func timeToRead(_ characters: Int) -> Double {
        readingSpeed > 0 ? Double(max(characters, 0)) / (Double(readingSpeed) / 3_600) : 0
    }

    mutating func add(_ session: ReadingSession) {
        charactersRead += session.charactersRead
        readingTime += session.readingTime
    }

    mutating func add(_ total: ReadingTotal) {
        charactersRead += total.charactersRead
        readingTime += total.readingTime
    }

    static func speed(charactersRead: Int, readingTime: Double) -> Int {
        readingTime > 0 ? Int((Double(charactersRead) / readingTime) * 3_600) : 0
    }
}

typealias ReadingSessionRecords = [String: Timestamped<ReadingSession?>]

nonisolated struct ReadingSessionEntry: Identifiable, Equatable, Sendable {
    let id: String
    let session: ReadingSession
    let modified: Int64
}

nonisolated struct ReadingSessionDay: Identifiable, Equatable, Sendable {
    let dateKey: String
    var sessions: [ReadingSessionEntry]

    var id: String { dateKey }

    var total: ReadingTotal {
        sessions.reduce(into: ReadingTotal()) { $0.add($1.session) }
    }

    var lastModified: Int64 {
        sessions.map(\.modified).max() ?? 0
    }
}

nonisolated enum ReadingSessionLog {
    static func dateKey(for session: ReadingSession, resetMinutes: Int, calendar: Calendar = .current) -> String {
        StatisticsDayBoundary.dateKey(for: session.startDate, resetMinutes: resetMinutes, calendar: calendar)
    }

    static func entries(_ records: ReadingSessionRecords) -> [ReadingSessionEntry] {
        records.compactMap { id, record in
            record.value.map { ReadingSessionEntry(id: id, session: $0, modified: record.modified) }
        }
        .sorted {
            $0.session.startedAt == $1.session.startedAt ? $0.id < $1.id : $0.session.startedAt < $1.session.startedAt
        }
    }

    static func days(
        _ records: ReadingSessionRecords,
        resetMinutes: Int,
        calendar: Calendar = .current
    ) -> [ReadingSessionDay] {
        var days: [String: ReadingSessionDay] = [:]
        for entry in entries(records) {
            let key = dateKey(for: entry.session, resetMinutes: resetMinutes, calendar: calendar)
            days[key, default: ReadingSessionDay(dateKey: key, sessions: [])].sessions.append(entry)
        }
        return days.values.sorted { $0.dateKey < $1.dateKey }
    }

    static func total(_ records: ReadingSessionRecords) -> ReadingTotal {
        records.values.reduce(into: ReadingTotal()) { total, record in
            if let session = record.value { total.add(session) }
        }
    }

    /// TTU-compatible daily rows derived from sessions. Each row carries the newest session
    /// modification time, so a round trip through `statistics.json` is stable.
    static func dailyStatistics(
        _ records: ReadingSessionRecords,
        title: String,
        resetMinutes: Int,
        calendar: Calendar = .current
    ) -> [Statistics] {
        days(records, resetMinutes: resetMinutes, calendar: calendar).compactMap { day in
            let total = day.total
            guard total.hasActivity else { return nil }
            let speed = total.readingSpeed
            return Statistics(
                title: title,
                dateKey: day.dateKey,
                charactersRead: total.charactersRead,
                readingTime: total.readingTime,
                minReadingSpeed: speed,
                altMinReadingSpeed: speed,
                lastReadingSpeed: speed,
                maxReadingSpeed: speed,
                lastStatisticModified: Int(day.lastModified)
            )
        }
    }

    /// Matches upstream's legacy session id so the same day converts to the same session.
    static func legacyID(key: String, dateKey: String) -> String {
        let hash = SHA256.hash(data: Data("\(key.precomposedStringWithCanonicalMapping)\n\(dateKey)\nlegacy".utf8))
        return hash.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }.uuidString
    }

    static func legacySessions(
        _ statistics: [Statistics],
        key: String,
        resetMinutes: Int,
        calendar: Calendar = .current
    ) -> ReadingSessionRecords {
        var records: ReadingSessionRecords = [:]
        for statistic in StatisticsEditor.visibleStatistics(statistics) {
            guard let session = session(for: statistic, resetMinutes: resetMinutes, calendar: calendar) else { continue }
            records[legacyID(key: key, dateKey: statistic.dateKey)] = Timestamped(
                modified: Int64(statistic.lastStatisticModified),
                value: session
            )
        }
        return records
    }

    /// Applies TTU daily rows (sync, backup, or a `statistics.json` written by an older build)
    /// to sessions. In merge mode a row only replaces a day whose sessions are all older.
    static func importingDaily(
        _ statistics: [Statistics],
        into records: ReadingSessionRecords,
        key: String,
        mode: StatisticsSyncMode,
        resetMinutes: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ReadingSessionRecords {
        var records = records
        var days = Dictionary(
            uniqueKeysWithValues: days(records, resetMinutes: resetMinutes, calendar: calendar).map { ($0.dateKey, $0) }
        )
        let nowStamp = StatisticsClock.milliseconds(now)

        for imported in StatisticsEditor.deduplicated(statistics).sorted(by: { $0.dateKey < $1.dateKey }) {
            let previous = days.removeValue(forKey: imported.dateKey)
            let previousIDs = previous?.sessions.map(\.id) ?? []
            let modified = Int64(imported.lastStatisticModified)
            if mode == .merge, let previous, previous.lastModified >= modified {
                continue
            }
            let hasActivity = imported.charactersRead > 0 || imported.readingTime > 0
            if !hasActivity, previousIDs.isEmpty {
                continue
            }
            let value = hasActivity ? session(for: imported, resetMinutes: resetMinutes, calendar: calendar) : nil
            if mode == .replace, previousIDs.count == 1, previous?.sessions.first?.session == value {
                continue
            }

            var id = previousIDs.min() ?? legacyID(key: key, dateKey: imported.dateKey)
            if !previousIDs.contains(id), records[id] != nil {
                id = UUID().uuidString
            }
            let timestamp = mode == .replace ? nowStamp : modified
            for previousID in previousIDs where previousID != id || value == nil {
                records[previousID] = Timestamped(modified: timestamp, value: nil)
            }
            if let value {
                records[id] = Timestamped(modified: timestamp, value: value)
            }
        }

        if mode == .replace {
            for day in days.values {
                for entry in day.sessions {
                    records[entry.id] = Timestamped(modified: nowStamp, value: nil)
                }
            }
        }
        return records
    }

    static func editing(
        id: String,
        charactersRead: Int,
        readingTime: Double,
        in records: ReadingSessionRecords,
        now: Date = .now
    ) -> ReadingSessionRecords {
        guard var session = records[id]?.value else { return records }
        session.charactersRead = max(charactersRead, 0)
        session.readingTime = max(readingTime, 0)
        guard session != records[id]?.value else { return records }
        var records = records
        records[id] = Timestamped(modified: StatisticsClock.milliseconds(now), value: session)
        return records
    }

    static func deleting(
        ids: [String],
        from records: ReadingSessionRecords,
        now: Date = .now
    ) -> ReadingSessionRecords {
        var records = records
        let timestamp = StatisticsClock.milliseconds(now)
        for id in ids where records[id]?.value != nil {
            records[id] = Timestamped(modified: timestamp, value: nil)
        }
        return records
    }

    private static func session(
        for statistic: Statistics,
        resetMinutes: Int,
        calendar: Calendar
    ) -> ReadingSession? {
        let parts = statistic.dateKey.split(separator: "-").compactMap { Int($0) }
        let resetMinutes = StatisticsDayBoundary.normalizedResetMinutes(resetMinutes)
        guard parts.count == 3,
              var start = calendar.date(from: DateComponents(
                  year: parts[0],
                  month: parts[1],
                  day: parts[2],
                  hour: resetMinutes / 60,
                  minute: resetMinutes % 60
              )) else {
            return nil
        }
        let readingTime = max(statistic.readingTime, 0)
        let estimatedEnd = Date(timeIntervalSince1970: Double(statistic.lastStatisticModified) / 1_000)
        let estimatedStart = estimatedEnd.addingTimeInterval(-readingTime)
        if StatisticsDayBoundary.dateKey(for: estimatedStart, resetMinutes: resetMinutes, calendar: calendar) == statistic.dateKey,
           StatisticsDayBoundary.dateKey(for: estimatedEnd, resetMinutes: resetMinutes, calendar: calendar) == statistic.dateKey {
            start = estimatedStart
        }
        return ReadingSession(
            startedAt: StatisticsClock.milliseconds(start),
            endedAt: StatisticsClock.milliseconds(start.addingTimeInterval(readingTime)),
            charactersRead: max(statistic.charactersRead, 0),
            readingTime: readingTime
        )
    }
}
