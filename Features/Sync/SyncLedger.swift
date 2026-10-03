//
//  SyncLedger.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

// Niratan keeps its local formats (daily ッツ statistics, highlight arrays, shelf lists) so
// backups, the ttu provider, the statistics dashboard and older builds keep working. The
// library sync model needs mergeable records instead, so each book keeps a ledger next to its
// files that remembers what was last applied locally. Comparing the local files with the
// ledger turns local edits into timestamped records; applying a merged record writes the
// local files and the ledger together.

nonisolated struct SyncDailyTotal: Codable, Equatable, Sendable {
    var charactersRead: Int
    var readingTime: Double

    static let zero = SyncDailyTotal(charactersRead: 0, readingTime: 0)

    var hasActivity: Bool {
        charactersRead != 0 || abs(readingTime) > 0.0005
    }

    func isClose(to other: SyncDailyTotal) -> Bool {
        charactersRead == other.charactersRead && abs(readingTime - other.readingTime) < 0.001
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        SyncDailyTotal(charactersRead: lhs.charactersRead + rhs.charactersRead, readingTime: lhs.readingTime + rhs.readingTime)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        SyncDailyTotal(charactersRead: lhs.charactersRead - rhs.charactersRead, readingTime: lhs.readingTime - rhs.readingTime)
    }
}

nonisolated struct SyncBookLedger: Codable, Equatable, Sendable {
    /// Every reading session known for the book, including deletion markers.
    var sessions: [String: Timestamped<ReadingSession?>] = [:]
    /// Reporting day of each session, fixed when the session is first seen so a later reset
    /// time change does not move history between days.
    var sessionDays: [String: String] = [:]
    /// Daily totals as they were after the last reconcile/apply; `nil` until the first sync.
    var appliedDaily: [String: SyncDailyTotal]?
    var highlights: [String: Timestamped<SyncHighlight?>]?
    var shelves: [String: Timestamped<Bool>]?
    var metadata: Timestamped<SyncMetadata>?
    var audiobook: Timestamped<SyncPlayback>?

    static let fileName = ".sync_ledger.json"

    @MainActor
    static func load(root: URL) -> SyncBookLedger {
        BookStorage.load(SyncBookLedger.self, from: root.appendingPathComponent(fileName)) ?? SyncBookLedger()
    }

    @MainActor
    func save(root: URL) throws {
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Last applied shelf list, stored next to `shelves.json`.
@MainActor
enum SyncShelfLedger {
    static let fileName = ".sync_shelves.json"

    static func load() -> SyncShelves? {
        guard let directory = try? BookStorage.getBooksDirectory() else { return nil }
        return BookStorage.load(SyncShelves.self, from: directory.appendingPathComponent(fileName))
    }

    static func save(_ shelves: SyncShelves?) throws {
        let url = try BookStorage.getBooksDirectory().appendingPathComponent(fileName)
        guard let shelves else {
            try BookStorage.delete(at: url)
            return
        }
        try JSONEncoder().encode(shelves).write(to: url, options: .atomic)
    }

    /// Turns the local shelf list into timestamped records relative to the last applied list.
    static func reconcile(local: [BookShelf], ledger: SyncShelves?, now: Int64) -> SyncShelves {
        guard var result = ledger else {
            var shelves: [String: Timestamped<Int?>] = [:]
            for (index, shelf) in local.enumerated() {
                shelves[key(shelf.name)] = Timestamped(modified: 0, value: index)
            }
            return SyncShelves(shelves: shelves)
        }
        let localNames = Set(local.map { key($0.name) })
        for (index, shelf) in local.enumerated() where result.shelves[key(shelf.name)]?.value != index {
            result.shelves[key(shelf.name)] = Timestamped(modified: now, value: index)
        }
        for (name, record) in result.shelves where record.value != nil && !localNames.contains(name) {
            result.shelves[name] = Timestamped(modified: now, value: nil)
        }
        return result
    }

    nonisolated static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }
}

nonisolated enum SyncDevice {
    private static let key = "googleDriveSyncDeviceID"

    /// Identifies this installation's reading sessions; not part of backups.
    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

nonisolated enum SyncStatisticsBridge {
    static func dailyTotals(_ statistics: [Statistics]) -> [String: SyncDailyTotal] {
        var totals: [String: SyncDailyTotal] = [:]
        for statistic in StatisticsEditor.deduplicated(statistics) {
            totals[statistic.dateKey] = SyncDailyTotal(charactersRead: statistic.charactersRead, readingTime: statistic.readingTime)
        }
        return totals
    }

    static func dateKey(for session: ReadingSession, resetMinutes: Int) -> String {
        StatisticsDayBoundary.dateKey(for: Date(syncMilliseconds: session.startedAt), resetMinutes: resetMinutes)
    }

    /// Sessions derived from daily totals start half a day after the reporting day begins, so
    /// devices whose reset times differ by less than twelve hours file them under the same day.
    static func session(dateKey: String, total: SyncDailyTotal, resetMinutes: Int) -> ReadingSession {
        let start = reportingDayStart(dateKey: dateKey, resetMinutes: resetMinutes)
            .addingTimeInterval(12 * 60 * 60)
        return ReadingSession(
            startedAt: start.syncMilliseconds,
            endedAt: start.addingTimeInterval(max(total.readingTime, 0)).syncMilliseconds,
            charactersRead: total.charactersRead,
            readingTime: total.readingTime
        )
    }

    static func reportingDayStart(dateKey: String, resetMinutes: Int) -> Date {
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        let calendar = Calendar.current
        let components = DateComponents(
            year: parts.count > 0 ? parts[0] : 1970,
            month: parts.count > 1 ? parts[1] : 1,
            day: parts.count > 2 ? parts[2] : 1
        )
        let day = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        return day.addingTimeInterval(Double(StatisticsDayBoundary.normalizedResetMinutes(resetMinutes)) * 60)
    }

    /// Converts local daily edits into sessions owned by this device. Existing history becomes
    /// one legacy session per day on the first sync; afterwards each day's difference between
    /// the local total and every other known session is stored in this device's session.
    static func reconcile(
        ledger: inout SyncBookLedger,
        statistics: [Statistics],
        key: String,
        deviceID: String,
        resetMinutes: Int,
        now: Int64
    ) {
        let daily = dailyTotals(statistics)
        assignDays(&ledger, resetMinutes: resetMinutes)

        guard let applied = ledger.appliedDaily else {
            let modifiedByDay = Dictionary(
                StatisticsEditor.deduplicated(statistics).map { ($0.dateKey, Int64($0.lastStatisticModified)) },
                uniquingKeysWith: max
            )
            for (dateKey, total) in daily where total.hasActivity {
                let id = SyncSessionID.legacy(key: key, dateKey: dateKey)
                guard ledger.sessions[id] == nil else { continue }
                ledger.sessions[id] = Timestamped(
                    modified: modifiedByDay[dateKey] ?? now,
                    value: session(dateKey: dateKey, total: total, resetMinutes: resetMinutes)
                )
                ledger.sessionDays[id] = dateKey
            }
            ledger.appliedDaily = daily
            return
        }

        let byDay = sessionsByDay(ledger)
        for dateKey in Set(daily.keys).union(applied.keys).sorted() {
            let local = daily[dateKey] ?? .zero
            let previous = applied[dateKey] ?? .zero
            if local.charactersRead < previous.charactersRead || local.readingTime < previous.readingTime - 0.001 {
                // An edit or clear in the statistics editor: the day becomes exactly the local
                // value. Other sessions of that day are deleted (deletion wins), so concurrent
                // edits never add up to a negative or doubled total.
                for id in (byDay[dateKey] ?? [:]).keys {
                    ledger.sessions[id] = Timestamped(modified: now, value: nil)
                }
                // Corrections share one id per day, so concurrent corrections resolve to the
                // newest instead of adding up.
                let ownID = ownSessionID(ledger, deviceID: "edit", key: key, dateKey: dateKey)
                if local.hasActivity {
                    ledger.sessions[ownID] = Timestamped(
                        modified: now,
                        value: session(dateKey: dateKey, total: local, resetMinutes: resetMinutes)
                    )
                    ledger.sessionDays[ownID] = dateKey
                }
                continue
            }
            let ownID = ownSessionID(ledger, deviceID: deviceID, key: key, dateKey: dateKey)
            let others = (byDay[dateKey] ?? [:])
                .filter { $0.key != ownID }
                .values
                .reduce(SyncDailyTotal.zero) { $0 + $1 }
            let target = local - others
            let current = ledger.sessions[ownID]?.value.map {
                SyncDailyTotal(charactersRead: $0.charactersRead, readingTime: $0.readingTime)
            } ?? .zero
            guard !target.isClose(to: current) else { continue }
            ledger.sessions[ownID] = Timestamped(
                modified: now,
                value: session(dateKey: dateKey, total: target, resetMinutes: resetMinutes)
            )
            ledger.sessionDays[ownID] = dateKey
        }
        ledger.appliedDaily = daily
    }

    /// Daily totals of every live session, with the newest change of each day.
    static func totals(_ ledger: SyncBookLedger) -> [String: (total: SyncDailyTotal, modified: Int64)] {
        var result: [String: (total: SyncDailyTotal, modified: Int64)] = [:]
        for (id, record) in ledger.sessions {
            guard let session = record.value, let dateKey = ledger.sessionDays[id] else { continue }
            let current = result[dateKey] ?? (.zero, 0)
            result[dateKey] = (
                current.total + SyncDailyTotal(charactersRead: session.charactersRead, readingTime: session.readingTime),
                max(current.modified, record.modified)
            )
        }
        return result
    }

    /// Rewrites daily statistics so each day equals the sum of its sessions. Returns `nil`
    /// when the file already matches.
    static func applyingSessions(
        _ ledger: SyncBookLedger,
        to statistics: [Statistics],
        title: String
    ) -> [Statistics]? {
        let totals = totals(ledger)
        var records = StatisticsEditor.deduplicated(statistics)
        var changed = false
        let days = Set(records.map(\.dateKey)).union(totals.keys)
        for dateKey in days.sorted() {
            let target = totals[dateKey]?.total ?? .zero
            let existing = records.first { $0.dateKey == dateKey }
            let current = existing.map { SyncDailyTotal(charactersRead: $0.charactersRead, readingTime: $0.readingTime) } ?? .zero
            if target.isClose(to: current) {
                continue
            }
            if existing == nil && !target.hasActivity {
                continue
            }
            let modified = max(Int(totals[dateKey]?.modified ?? 0), existing?.lastStatisticModified ?? 0)
            records = StatisticsEditor.updating(
                dateKey: dateKey,
                title: title,
                charactersRead: target.charactersRead,
                readingTime: target.readingTime,
                modifiedAt: modified,
                in: records
            )
            changed = true
        }
        return changed ? records : nil
    }

    static func assignDays(_ ledger: inout SyncBookLedger, resetMinutes: Int) {
        for (id, record) in ledger.sessions where ledger.sessionDays[id] == nil {
            if let session = record.value {
                ledger.sessionDays[id] = dateKey(for: session, resetMinutes: resetMinutes)
            }
        }
    }

    private static func sessionsByDay(_ ledger: SyncBookLedger) -> [String: [String: SyncDailyTotal]] {
        var result: [String: [String: SyncDailyTotal]] = [:]
        for (id, record) in ledger.sessions {
            guard let session = record.value, let dateKey = ledger.sessionDays[id] else { continue }
            result[dateKey, default: [:]][id] = SyncDailyTotal(
                charactersRead: session.charactersRead,
                readingTime: session.readingTime
            )
        }
        return result
    }

    /// A deleted session can never be revived (deletion wins), so this device moves on to the
    /// next id for that day.
    private static func ownSessionID(_ ledger: SyncBookLedger, deviceID: String, key: String, dateKey: String) -> String {
        var generation = 0
        while true {
            let id = SyncSessionID.device(generation == 0 ? deviceID : "\(deviceID)#\(generation)", key: key, dateKey: dateKey)
            if let record = ledger.sessions[id], record.value == nil {
                generation += 1
                continue
            }
            return id
        }
    }
}

nonisolated enum SyncHighlightBridge {
    static func reconcile(ledger: inout SyncBookLedger, local: [Highlight], now: Int64) {
        guard var records = ledger.highlights else {
            ledger.highlights = Dictionary(uniqueKeysWithValues: local.map {
                ($0.id.uuidString, Timestamped(modified: $0.createdAt.syncMilliseconds, value: SyncHighlight($0) as SyncHighlight?))
            })
            return
        }
        let localIDs = Set(local.map(\.id.uuidString))
        for highlight in local {
            let id = highlight.id.uuidString
            if let record = records[id] {
                guard let value = record.value else { continue }
                if !matches(value, highlight) {
                    var updated = SyncHighlight(highlight)
                    updated.textFurigana = value.textFurigana
                    records[id] = Timestamped(modified: now, value: updated)
                }
            } else {
                records[id] = Timestamped(modified: highlight.createdAt.syncMilliseconds, value: SyncHighlight(highlight))
            }
        }
        for (id, record) in records where record.value != nil && !localIDs.contains(id) {
            records[id] = Timestamped(modified: now, value: nil)
        }
        ledger.highlights = records
    }

    static func highlights(from records: [String: Timestamped<SyncHighlight?>]) -> [Highlight] {
        records.compactMap { id, record in record.value?.highlight(id: id) }
            .sorted { ($0.character, $0.createdAt) < ($1.character, $1.createdAt) }
    }

    static func sameContent(_ local: [Highlight], _ records: [String: Timestamped<SyncHighlight?>]) -> Bool {
        let live = records.compactMapValues { $0.value }
        guard live.count == local.count else { return false }
        return local.allSatisfy { highlight in
            live[highlight.id.uuidString].map { matches($0, highlight) } ?? false
        }
    }

    private static func matches(_ value: SyncHighlight, _ highlight: Highlight) -> Bool {
        // A color this build does not know is shown as yellow but must not be rewritten.
        let sameColor = HighlightColor(rawValue: value.color) == nil
            ? highlight.color == .yellow
            : value.color == highlight.color.rawValue
        return value.character == highlight.character
            && value.offset == highlight.offset
            && value.text == highlight.text
            && sameColor
    }
}

nonisolated enum SyncShelfMembershipBridge {
    /// Memberships of one book, limited to shelves that exist locally: a shelf that only exists
    /// remotely keeps its remote membership until the shelf list itself arrives.
    static func reconcile(ledger: inout SyncBookLedger, bookID: UUID, shelves: [BookShelf], now: Int64) {
        let localNames = Set(shelves.map { SyncShelfLedger.key($0.name) })
        let memberOf = Set(shelves.filter { $0.bookIds.contains(bookID) }.map { SyncShelfLedger.key($0.name) })
        guard var records = ledger.shelves else {
            ledger.shelves = Dictionary(uniqueKeysWithValues: memberOf.map { ($0, Timestamped(modified: 0, value: true)) })
            return
        }
        for name in localNames {
            let member = memberOf.contains(name)
            if (records[name]?.value ?? false) != member {
                records[name] = Timestamped(modified: now, value: member)
            }
        }
        ledger.shelves = records
    }

    /// Applies memberships to shelves that exist locally. Returns whether anything changed.
    static func apply(_ records: [String: Timestamped<Bool>], bookID: UUID, to shelves: inout [BookShelf]) -> Bool {
        var changed = false
        for index in shelves.indices {
            let member = records[SyncShelfLedger.key(shelves[index].name)]?.value ?? false
            let contains = shelves[index].bookIds.contains(bookID)
            if member && !contains {
                shelves[index].bookIds.append(bookID)
                changed = true
            } else if !member && contains {
                shelves[index].bookIds.removeAll { $0 == bookID }
                changed = true
            }
        }
        return changed
    }
}
