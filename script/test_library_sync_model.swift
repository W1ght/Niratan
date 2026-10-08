// test-sources: Models/Sync.swift Models/Statistics.swift Models/Highlight.swift Models/Book.swift Features/Sync/SyncLedger.swift
import Foundation

// Minimal stand-in for the app's storage layer; the ledger only needs these entry points.
enum BookStorage {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func getBooksDirectory() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("niratan-sync-model-test")
    }

    static func delete(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let key = "テスト本"
let title = "テスト本"
var clock: Int64 = 1_800_000_000_000

func tick() -> Int64 {
    clock += 1_000
    return clock
}

/// One installation: its local daily statistics plus the sync ledger next to them.
struct Device {
    let id: String
    var statistics: [Statistics] = []
    var ledger = SyncBookLedger()

    func total(_ dateKey: String) -> SyncDailyTotal {
        SyncStatisticsBridge.dailyTotals(statistics)[dateKey] ?? .zero
    }

    mutating func setDay(_ dateKey: String, characters: Int, seconds: Double) {
        statistics = StatisticsEditor.updating(
            dateKey: dateKey,
            title: title,
            charactersRead: characters,
            readingTime: seconds,
            modifiedAt: Int(tick()),
            in: statistics
        )
    }

    mutating func read(_ dateKey: String, characters: Int, seconds: Double) {
        let current = total(dateKey)
        setDay(dateKey, characters: current.charactersRead + characters, seconds: current.readingTime + seconds)
    }

    /// Exercises the legacy daily adapter still used for the one-time session migration.
    mutating func sync(with remote: inout [String: Timestamped<ReadingSession?>]) {
        SyncStatisticsBridge.reconcile(ledger: &ledger, statistics: statistics, key: key, deviceID: id, resetMinutes: 0, now: tick())
        let merged = SyncBook.mergeRecords(ledger.sessions, remote)
        ledger.sessions = merged
        SyncStatisticsBridge.assignDays(&ledger, resetMinutes: 0)
        if let updated = SyncStatisticsBridge.applyingSessions(ledger, to: statistics, title: title) {
            statistics = updated
        }
        ledger.appliedDaily = SyncStatisticsBridge.dailyTotals(statistics)

        // The next reconcile must not invent changes (the uploaded document is stable).
        let before = ledger.sessions
        SyncStatisticsBridge.reconcile(ledger: &ledger, statistics: statistics, key: key, deviceID: id, resetMinutes: 0, now: tick())
        require(ledger.sessions == before, "reconcile right after apply should be a no-op for \(id)")
        remote = merged
    }
}

func highlight(_ id: UUID, color: HighlightColor = .yellow) -> Highlight {
    Highlight(id: id, character: 10, offset: 2, text: "猫", color: color, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
}

func book(generation: Int, deleted: Bool = false, title: String, modified: Int64) -> SyncBook {
    SyncBook(generation: generation, deleted: deleted, metadata: Timestamped(modified: modified, value: SyncMetadata(title: title)))
}

@main
struct LibrarySyncModelTest {
    @MainActor
    static func main() throws {
        // MARK: Statistics

        let day1 = "2026-09-01"
        let day2 = "2026-09-02"

        // Session start times file back under the same reporting day.
        let derived = SyncStatisticsBridge.session(dateKey: day1, total: SyncDailyTotal(charactersRead: 1, readingTime: 1), resetMinutes: 240)
        require(SyncStatisticsBridge.dateKey(for: derived, resetMinutes: 240) == day1, "derived sessions keep their reporting day")
        require(SyncStatisticsBridge.dateKey(for: derived, resetMinutes: 0) == day1, "devices with another reset time agree on the day")

        // Both devices already share day1 (e.g. through ッツ sync): legacy ids prevent double counting.
        var remote: [String: Timestamped<ReadingSession?>] = [:]
        var mac = Device(id: "MAC")
        var other = Device(id: "OTHER")
        mac.setDay(day1, characters: 1000, seconds: 600)
        other.setDay(day1, characters: 1000, seconds: 600)
        mac.sync(with: &remote)
        other.sync(with: &remote)
        require(other.total(day1) == SyncDailyTotal(charactersRead: 1000, readingTime: 600), "shared history must not double: \(other.total(day1))")
        mac.sync(with: &remote)
        require(mac.total(day1) == SyncDailyTotal(charactersRead: 1000, readingTime: 600), "shared history must not double on the first device")

        // Reading on both devices on the same and on a new day adds up.
        mac.read(day1, characters: 100, seconds: 60)
        other.read(day1, characters: 50, seconds: 30)
        mac.read(day2, characters: 200, seconds: 120)
        other.read(day2, characters: 300, seconds: 180)
        mac.sync(with: &remote)
        other.sync(with: &remote)
        mac.sync(with: &remote)
        for device in [mac, other] {
            require(device.total(day1) == SyncDailyTotal(charactersRead: 1150, readingTime: 690), "\(device.id) day1 should combine both devices: \(device.total(day1))")
            require(device.total(day2) == SyncDailyTotal(charactersRead: 500, readingTime: 300), "\(device.id) day2 should combine both devices: \(device.total(day2))")
        }

        // Deleting a day in the statistics editor writes zeros; every device follows.
        mac.setDay(day2, characters: 0, seconds: 0)
        mac.sync(with: &remote)
        other.sync(with: &remote)
        require(other.total(day2) == .zero, "a cleared day should clear on other devices: \(other.total(day2))")
        // Later reading that day on the other device still counts.
        other.read(day2, characters: 40, seconds: 20)
        other.sync(with: &remote)
        mac.sync(with: &remote)
        require(mac.total(day2) == SyncDailyTotal(charactersRead: 40, readingTime: 20), "reading after a clear should sync: \(mac.total(day2))")

        // Both devices clear the same day before syncing: no negative totals.
        let day3 = "2026-09-03"
        mac.read(day3, characters: 100, seconds: 50)
        mac.sync(with: &remote)
        other.sync(with: &remote)
        mac.setDay(day3, characters: 0, seconds: 0)
        other.setDay(day3, characters: 0, seconds: 0)
        mac.sync(with: &remote)
        other.sync(with: &remote)
        mac.sync(with: &remote)
        require(mac.total(day3) == .zero && other.total(day3) == .zero, "concurrent clears stay at zero: \(mac.total(day3)) \(other.total(day3))")

        // Concurrent corrections of one day agree on one of the edited values. (Raising a
        // total counts as additional reading, so only lowering edits replace the day.)
        mac.setDay(day3, characters: 200, seconds: 100)
        mac.sync(with: &remote)
        other.sync(with: &remote)
        mac.setDay(day3, characters: 50, seconds: 30)
        other.setDay(day3, characters: 60, seconds: 40)
        mac.sync(with: &remote)
        other.sync(with: &remote)
        mac.sync(with: &remote)
        require(mac.total(day3) == other.total(day3), "concurrent edits converge: \(mac.total(day3)) vs \(other.total(day3))")
        require([50, 60].contains(mac.total(day3).charactersRead), "concurrent edits keep one edit: \(mac.total(day3))")

        // Editing a day sets the exact total everywhere.
        other.setDay(day1, characters: 2000, seconds: 1200)
        other.sync(with: &remote)
        mac.sync(with: &remote)
        require(mac.total(day1) == SyncDailyTotal(charactersRead: 2000, readingTime: 1200), "an edited day should match the edit: \(mac.total(day1))")

        // A tombstoned device session moves on to a fresh id instead of losing new reading.
        let ownID = SyncSessionID.device("MAC", key: key, dateKey: day2)
        remote[ownID] = Timestamped(modified: tick(), value: nil)
        mac.ledger.sessions[ownID] = Timestamped(modified: tick(), value: nil)
        mac.read(day2, characters: 10, seconds: 5)
        mac.sync(with: &remote)
        other.sync(with: &remote)
        let macDay2 = mac.total(day2)
        require(other.total(day2) == macDay2, "devices agree after a tombstoned session: \(other.total(day2)) vs \(macDay2)")

        // Two older devices can hold the same synced daily total under different native
        // ids after daily imports. Migration uses their shared wire id as the baseline.
        let baseline = SyncDailyTotal(charactersRead: 200, readingTime: 120)
        let baselineSession = SyncStatisticsBridge.session(dateKey: day1, total: baseline, resetMinutes: 0)
        let baselineID = SyncSessionID.legacy(key: key, dateKey: day1)
        let legacyRecords: ReadingSessionRecords = [baselineID: Timestamped(modified: 8, value: baselineSession)]
        let nativeA: ReadingSessionRecords = ["native-a": Timestamped(modified: 10, value: SyncStatisticsBridge.session(dateKey: day1, total: SyncDailyTotal(charactersRead: 220, readingTime: 130), resetMinutes: 0))]
        let nativeB: ReadingSessionRecords = ["native-b": Timestamped(modified: 11, value: SyncStatisticsBridge.session(dateKey: day1, total: SyncDailyTotal(charactersRead: 230, readingTime: 140), resetMinutes: 0))]
        var ledgerA = SyncBookLedger(sessions: legacyRecords, appliedDaily: [day1: baseline])
        var ledgerB = ledgerA
        let migratedA = SyncSessionMigration.canonicalRecords(nativeA, ledger: &ledgerA, key: key, deviceID: "A", resetMinutes: 0, now: 20)
        let migratedB = SyncSessionMigration.canonicalRecords(nativeB, ledger: &ledgerB, key: key, deviceID: "B", resetMinutes: 0, now: 21)
        require(migratedA[baselineID] == legacyRecords[baselineID], "shared historical session ids and timestamps survive migration")
        require(migratedA["native-a"]?.value == nil && migratedB["native-b"]?.value == nil, "native ids carrying imported aggregates are retired")
        require(ReadingSessionLog.total(migratedA) == ReadingSessionLog.total(nativeA), "migration preserves this device's accumulated activity")
        require(ReadingSessionLog.total(migratedB) == ReadingSessionLog.total(nativeB), "migration preserves the other device's accumulated activity")
        let migratedMerged = SyncBook.mergeRecords(migratedA, migratedB)
        require(ReadingSessionLog.total(migratedMerged) == ReadingTotal(charactersRead: 250, readingTime: 150), "two migrations keep the 200 shared baseline once and combine only 20+30 local reading")
        require(ReadingSessionLog.total(SyncBook.mergeRecords(migratedMerged, legacyRecords)) == ReadingSessionLog.total(migratedMerged), "an old cloud document cannot duplicate the migrated baseline")

        // MARK: Highlights


        let first = UUID()
        var macLedger = SyncBookLedger()
        var otherLedger = SyncBookLedger()
        SyncHighlightBridge.reconcile(ledger: &macLedger, local: [highlight(first)], now: tick())
        var highlightRemote = macLedger.highlights ?? [:]
        otherLedger.highlights = highlightRemote
        var otherHighlights = SyncHighlightBridge.highlights(from: highlightRemote)
        require(otherHighlights.map(\.id) == [first], "a new highlight reaches the other device")

        // Recolor on one device, delete on the other: deletion wins.
        SyncHighlightBridge.reconcile(ledger: &macLedger, local: [highlight(first, color: .blue)], now: tick())
        otherHighlights = []
        SyncHighlightBridge.reconcile(ledger: &otherLedger, local: otherHighlights, now: tick())
        highlightRemote = SyncBook.mergeRecords(macLedger.highlights ?? [:], otherLedger.highlights ?? [:])
        require(SyncHighlightBridge.highlights(from: highlightRemote).isEmpty, "deleting a highlight wins over editing it")
        macLedger.highlights = highlightRemote
        // A stale local copy cannot resurrect it.
        SyncHighlightBridge.reconcile(ledger: &macLedger, local: [highlight(first, color: .blue)], now: tick())
        require(macLedger.highlights?[first.uuidString]?.value == nil, "a deleted highlight stays deleted")
        require(SyncHighlightBridge.sameContent([], macLedger.highlights ?? [:]), "applied highlights match the merged records")

        var furigana = SyncHighlight(highlight(first))
        furigana.textFurigana = "<ruby>猫<rt>ねこ</rt></ruby>"
        furigana.color = "future-color"
        let furiganaRecords = [first.uuidString: Timestamped(modified: tick(), value: furigana as SyncHighlight?)]
        let localFurigana = SyncHighlightBridge.highlights(from: furiganaRecords)
        require(localFurigana.first?.textFurigana == furigana.textFurigana, "remote furigana is present in local highlight storage")
        var furiganaLedger = SyncBookLedger(highlights: furiganaRecords)
        SyncHighlightBridge.reconcile(ledger: &furiganaLedger, local: localFurigana, now: tick())
        require(furiganaLedger.highlights == furiganaRecords, "an untouched unknown color and furigana round trip without a new timestamp")
        var recolored = localFurigana[0]
        recolored = Highlight(id: recolored.id, character: recolored.character, offset: recolored.offset, text: recolored.text, textFurigana: recolored.textFurigana, color: .blue, createdAt: recolored.createdAt)
        SyncHighlightBridge.reconcile(ledger: &furiganaLedger, local: [recolored], now: tick())
        require(furiganaLedger.highlights?[first.uuidString]?.value?.textFurigana == furigana.textFurigana, "local recoloring preserves remote furigana")

        // MARK: Shelves

        let bookID = UUID()
        var membership = SyncBookLedger()
        var shelves = [BookShelf(name: "小説", bookIds: [bookID]), BookShelf(name: "漫画", bookIds: [])]
        SyncShelfMembershipBridge.reconcile(ledger: &membership, bookID: bookID, shelves: shelves, now: tick())
        require(membership.shelves?["小説"]?.value == true, "existing membership is recorded")
        shelves[0].bookIds = []
        shelves[1].bookIds = [bookID]
        SyncShelfMembershipBridge.reconcile(ledger: &membership, bookID: bookID, shelves: shelves, now: tick())
        require(membership.shelves?["小説"]?.value == false && membership.shelves?["漫画"]?.value == true, "moving a book updates both memberships")

        // A membership for a shelf this device does not have yet is kept, not cleared.
        membership.shelves?["リモート"] = Timestamped(modified: tick(), value: true)
        SyncShelfMembershipBridge.reconcile(ledger: &membership, bookID: bookID, shelves: shelves, now: tick())
        require(membership.shelves?["リモート"]?.value == true, "remote-only shelf memberships survive")
        var applied = shelves
        _ = SyncShelfMembershipBridge.apply(["小説": Timestamped(modified: tick(), value: true)], bookID: bookID, to: &applied)
        require(applied[0].bookIds == [bookID] && applied[1].bookIds.isEmpty, "applying memberships edits local shelves")

        let shelfList = SyncShelfLedger.reconcile(local: shelves, ledger: nil, now: tick())
        require(shelfList.shelves.values.allSatisfy { $0.modified == 0 }, "the first shelf list never overrides remote edits")
        let renamed = SyncShelfLedger.reconcile(local: [shelves[1]], ledger: shelfList, now: tick())
        require(renamed.shelves["小説"]?.value == nil && renamed.shelves["漫画"]?.value == 0, "a removed shelf becomes a deletion marker")

        // MARK: Book documents


        let renamedRemote = book(generation: 1, title: "新しい題名", modified: 20)
        let localBook = book(generation: 1, title: "古い題名", modified: 10)
        require(SyncBook.merge(localBook, renamedRemote).metadata.value.title == "新しい題名", "newer metadata wins")
        require(SyncBook.merge(book(generation: 2, title: "再読", modified: 1), renamedRemote).generation == 2, "a re-imported generation replaces the old one")
        var deleted = book(generation: 1, deleted: true, title: "古い題名", modified: 5)
        deleted.sessions = ["s": Timestamped(modified: 1, value: ReadingSession(startedAt: 0, endedAt: 0, charactersRead: 5, readingTime: 5))]
        let mergedDeleted = SyncBook.merge(renamedRemote, deleted)
        require(mergedDeleted.deleted && mergedDeleted.bookmark == nil, "deleting a book wins over edits")
        require(mergedDeleted.sessions["s"]?.value != nil, "statistics of a deleted book are kept")

        // Documents written by upstream Hoshi Reader (formatVersion 1) decode.
        let upstream = """
        {"formatVersion":1,"generation":1,"deleted":false,"metadata":{"modified":3,"value":{"title":"本"}},"characterCount":10,"files":{},"highlights":{},"sessions":{},"shelves":{}}
        """
        let decoded = try SyncFormat.decode(SyncBook.self, from: Data(upstream.utf8))
        require(decoded.metadata.value.title == "本" && decoded.metadata.value.language == nil, "upstream documents decode")
        do {
            _ = try SyncFormat.decode(SyncBook.self, from: Data(upstream.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2").utf8))
            require(false, "unknown format versions must stop the sync")
        } catch is SyncFormatError {
        }

        print("PASS: library sync model")
    }
}
