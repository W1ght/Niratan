//
//  StatisticsStorage.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Per-book reading sessions. `statistics_sessions.json` is the source of truth; the
/// TTU-compatible daily `statistics.json` is always re-derived from it so TTU sync,
/// backups and older builds keep reading the format they know.
nonisolated enum StatisticsStorage {
    static let sessionsFileName = "statistics_sessions.json"

    private struct SessionsFile: Codable {
        var sessions: ReadingSessionRecords
        /// The daily rows last written to `statistics.json` (dateKey -> modification time).
        /// Rows that differ were written by something else and are imported on load.
        var exportedDaily: [String: Int]
    }

    static var currentResetMinutes: Int {
        StatisticsResetTimePreference.load(from: .standard)
    }

    static func load(root: URL, resetMinutes: Int = currentResetMinutes) -> ReadingSessionRecords {
        let daily = loadDaily(root: root)
        let reconciled = reconciled(root: root, daily: daily, resetMinutes: resetMinutes)
        if reconciled.needsSave {
            try? write(reconciled.records, root: root, title: title(root: root, daily: daily), resetMinutes: resetMinutes)
        }
        return reconciled.records
    }

    static func save(_ records: ReadingSessionRecords, root: URL, resetMinutes: Int = currentResetMinutes) throws {
        try write(records, root: root, title: title(root: root, daily: loadDaily(root: root)), resetMinutes: resetMinutes)
    }

    /// Read-only daily view for background readers such as the Statistics dashboard.
    static func dailyStatistics(root: URL, resetMinutes: Int = currentResetMinutes) -> [Statistics]? {
        let daily = loadDaily(root: root)
        let records = reconciled(root: root, daily: daily, resetMinutes: resetMinutes).records
        guard !records.isEmpty || daily != nil else { return nil }
        return ReadingSessionLog.dailyStatistics(
            records,
            title: title(root: root, daily: daily),
            resetMinutes: resetMinutes
        )
    }

    static func hasStatistics(root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionsFileName).path(percentEncoded: false))
            || FileManager.default.fileExists(atPath: root.appendingPathComponent(dailyFileName).path(percentEncoded: false))
    }

    static func importDaily(
        _ statistics: [Statistics],
        root: URL,
        mode: StatisticsSyncMode,
        resetMinutes: Int = currentResetMinutes
    ) throws {
        let current = load(root: root, resetMinutes: resetMinutes)
        let updated = ReadingSessionLog.importingDaily(
            statistics,
            into: current,
            key: root.lastPathComponent,
            mode: mode,
            resetMinutes: resetMinutes
        )
        guard updated != current else { return }
        try write(
            updated,
            root: root,
            title: statistics.first?.title ?? title(root: root, daily: loadDaily(root: root)),
            resetMinutes: resetMinutes
        )
    }

    // MARK: - Private

    private static let dailyFileName = "statistics.json"

    private static func loadDaily(root: URL) -> [Statistics]? {
        decode([Statistics].self, from: root.appendingPathComponent(dailyFileName))
    }

    private static func reconciled(
        root: URL,
        daily: [Statistics]?,
        resetMinutes: Int
    ) -> (records: ReadingSessionRecords, needsSave: Bool) {
        let key = root.lastPathComponent
        guard let file = decode(SessionsFile.self, from: root.appendingPathComponent(sessionsFileName)) else {
            // First load after the session upgrade: convert each legacy day into one session.
            guard let daily, !daily.isEmpty else { return ([:], false) }
            return (ReadingSessionLog.legacySessions(daily, key: key, resetMinutes: resetMinutes), true)
        }

        let external = StatisticsEditor.deduplicated(daily ?? []).filter {
            file.exportedDaily[$0.dateKey] != $0.lastStatisticModified
        }
        guard !external.isEmpty else { return (file.sessions, false) }
        let records = ReadingSessionLog.importingDaily(
            external,
            into: file.sessions,
            key: key,
            mode: .merge,
            resetMinutes: resetMinutes
        )
        return (records, true)
    }

    private static func write(
        _ records: ReadingSessionRecords,
        root: URL,
        title: String,
        resetMinutes: Int
    ) throws {
        let daily = ReadingSessionLog.dailyStatistics(records, title: title, resetMinutes: resetMinutes)
        let file = SessionsFile(
            sessions: records,
            exportedDaily: Dictionary(daily.map { ($0.dateKey, $0.lastStatisticModified) }, uniquingKeysWith: max)
        )
        try encode(file, to: root.appendingPathComponent(sessionsFileName))
        try encode(daily, to: root.appendingPathComponent(dailyFileName))
    }

    private static func title(root: URL, daily: [Statistics]?) -> String {
        if let title = daily?.first(where: { !$0.title.isEmpty })?.title {
            return title
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("metadata.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return (object["renamedTitle"] as? String) ?? (object["title"] as? String) ?? ""
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
