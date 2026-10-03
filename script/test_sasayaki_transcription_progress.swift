// test-sources: Models/Sasayaki.swift Features/Sasayaki/SasayakiTranscriptionProgress.swift Features/Sasayaki/SasayakiSRT.swift
// Runs entirely in a disposable directory and never reads the user's books.
import Foundation

@main
struct SasayakiTranscriptionProgressTests {
    static func main() throws {
        try planning()
        try storage()
        print("Sasayaki transcription planning and progress tests passed")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String = "Condition failed") rethrows {
        let satisfied = try condition()
        precondition(satisfied, message)
    }

    private static func planning() throws {
        let simple = SasayakiTranscriptionPlanner.chunks(duration: 900.2, chapters: [])
        precondition(simple.map(\.startTime) == [0, 300, 600, 900])
        precondition(simple.last!.endTime == 900.2, "Do not lose short final audio")
        precondition(simple.allSatisfy { $0.chapterID == nil })
        precondition(SasayakiTranscriptionPlanner.chunks(duration: .nan, chapters: []).isEmpty)
        precondition(SasayakiTranscriptionPlanner.chunks(duration: .infinity, chapters: []).isEmpty)
        precondition(SasayakiTranscriptionPlanner.chunks(duration: 0, chapters: []).isEmpty)
        precondition(SasayakiTranscriptionPlanner.chunks(duration: 60, chapters: [], maximumChunkDuration: 0).isEmpty)

        let chapters = [
            SasayakiAudiobookChapter(id: 2, title: "Later", startTime: 980, endTime: nil),
            SasayakiAudiobookChapter(id: 0, title: "First", startTime: 20, endTime: 500),
            SasayakiAudiobookChapter(id: 1, title: "Current", startTime: 560, endTime: 1000),
            SasayakiAudiobookChapter(id: 3, title: "Invalid", startTime: .nan, endTime: nil)
        ]
        let chunks = SasayakiTranscriptionPlanner.chunks(duration: 1300, chapters: chapters)
        precondition(chunks.map(\.startTime) == [0, 20, 320, 500, 560, 860, 980, 1280])
        precondition(chunks.map(\.endTime) == [20, 320, 500, 560, 860, 980, 1280, 1300])
        precondition(chunks.map(\.chapterID) == [nil, 0, 0, nil, 1, 1, 2, 2])
        precondition(chunks.allSatisfy { $0.duration > 0 && $0.duration <= 300 })
        precondition(zip(chunks, chunks.dropFirst()).allSatisfy { $0.endTime == $1.startTime })

        let preferred = SasayakiTranscriptionPlanner.pendingChunks(chunks: chunks, completedChunkIDs: [4], preferredTime: 900)
        precondition(preferred.map(\.id) == [5, 6, 7, 0, 1, 2, 3])
        let wholeChapter = SasayakiTranscriptionPlanner.pendingChunks(chunks: chunks, completedChunkIDs: [], preferredTime: 900)
        precondition(wholeChapter.map(\.id).prefix(2) == [4, 5], "Start with the whole current chapter")
        let noMarkers = SasayakiTranscriptionPlanner.pendingChunks(chunks: simple, completedChunkIDs: [], preferredTime: 730)
        precondition(noMarkers.map(\.id) == [2, 3, 0, 1])
        let atBoundary = SasayakiTranscriptionPlanner.pendingChunks(chunks: chunks, completedChunkIDs: [], preferredTime: 980)
        precondition(atBoundary.first?.chapterID == 2)
        let atEnd = SasayakiTranscriptionPlanner.pendingChunks(chunks: simple, completedChunkIDs: [], preferredTime: 900.2)
        precondition(atEnd.first?.id == 3)
        let invalidTime = SasayakiTranscriptionPlanner.pendingChunks(chunks: simple, completedChunkIDs: [], preferredTime: .nan)
        precondition(invalidTime.first?.id == 0)
    }

    private static func storage() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sasayaki-progress-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = scratch.appendingPathComponent("source.m4b")
        let sourceBytes = Data("disposable audio stand-in".utf8)
        try sourceBytes.write(to: audio)
        let source = try SasayakiTranscriptionSource.fingerprint(bookRootURL: scratch.appendingPathComponent("book"), audioURL: audio)
        let alias = scratch.appendingPathComponent("alias.m4b")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: audio)
        let aliased = try SasayakiTranscriptionSource.fingerprint(bookRootURL: scratch.appendingPathComponent("book"), audioURL: alias)
        precondition(source == aliased, "Canonical symlink paths should reuse progress")

        let output = scratch.appendingPathComponent("app-support", isDirectory: true)
        let store = try SasayakiTranscriptionProgressStore(directory: output)
        let chunks = SasayakiTranscriptionPlanner.chunks(duration: 600.2, chapters: [])
        try require(try store.load(source: source, language: "ja-JP", chunks: chunks) == nil)
        var checkpoint = SasayakiTranscriptionCheckpoint(source: source, language: "ja-JP", chunks: chunks)
        try checkpoint.record(chunkID: 1, cues: [.init(id: "0", startTime: 340, endTime: 350, text: "次の章です。")], elapsedSeconds: 8)
        checkpoint.recordElapsed(11)
        let subtitleURL = try store.save(checkpoint)
        precondition(subtitleURL.deletingLastPathComponent() == output)
        precondition(!checkpoint.isComplete && checkpoint.completedDuration == 300)
        precondition(store.preferredLanguage(source: source) == "ja-JP")
        let english = SasayakiTranscriptionCheckpoint(source: source, language: "en-US", chunks: chunks)
        try store.save(english)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: store.checkpointURL(source: source, language: "ja-JP").path
        )
        precondition(store.preferredLanguage(source: source) == "en-US")

        let recreatedStore = try SasayakiTranscriptionProgressStore(directory: output)
        var resumed = try recreatedStore.load(source: source, language: "ja-JP", chunks: chunks)!
        precondition(resumed.elapsedSeconds == 11 && resumed.completed.keys.sorted() == [1])
        precondition(resumed.cues.first?.startTime == 340, "Partial results must retain audiobook-global timestamps")
        try require(try String(contentsOf: subtitleURL, encoding: .utf8).contains("00:05:40,000"))
        try resumed.record(chunkID: 0, cues: [.init(id: "0", startTime: 5, endTime: 7, text: "最初の章です。")], elapsedSeconds: 10)
        try resumed.record(chunkID: 2, cues: [], elapsedSeconds: 16)
        precondition(resumed.elapsedSeconds == 16 && resumed.isComplete)
        precondition(resumed.cues.map(\.startTime) == [5, 340])
        precondition(Set(resumed.cues.map(\.id)).count == 2, "Worker-local cue IDs must not collide")
        precondition(resumed.completedDuration == 600.2, "Silence and short final chunks count as completed")
        try store.save(resumed)
        let final = try store.load(source: source, language: "ja-JP", chunks: chunks)!
        precondition(final.isComplete && final.cues.count == 2 && final.elapsedSeconds == 16)
        try require(try String(contentsOf: subtitleURL, encoding: .utf8).contains("最初の章です。"))

        let differentPlan = SasayakiTranscriptionPlanner.chunks(duration: 600.2, chapters: [], maximumChunkDuration: 200)
        try require(try store.load(source: source, language: "ja-JP", chunks: differentPlan) == nil)
        let englishProgress = try store.load(source: source, language: "en-US", chunks: chunks)!
        precondition(englishProgress.completed.isEmpty && !englishProgress.isComplete)
        let otherBook = try SasayakiTranscriptionSource.fingerprint(bookRootURL: scratch.appendingPathComponent("other-book"), audioURL: audio)
        try require(try store.load(source: otherBook, language: "ja-JP", chunks: chunks) == nil)

        // The checkpoint is authoritative if its derived SRT was missing when the
        // App stopped. Saving after reload reconstructs the complete projection.
        try FileManager.default.removeItem(at: subtitleURL)
        let repair = try store.load(source: source, language: "ja-JP", chunks: chunks)!
        try store.save(repair)
        try require(try String(contentsOf: subtitleURL, encoding: .utf8).contains("次の章です。"))

        // Force the SRT projection write to fail after the JSON was committed.
        // Reload must still expose every completed chunk for the repair attempt.
        let failingStore = try SasayakiTranscriptionProgressStore(directory: scratch.appendingPathComponent("projection-failure"))
        let blockedSRT = failingStore.subtitleURL(source: source, language: "ja-JP")
        try FileManager.default.createDirectory(at: blockedSRT, withIntermediateDirectories: true)
        do {
            try failingStore.save(final)
            preconditionFailure("A directory at the SRT path should reject the projection write")
        } catch {}
        let durableAfterFailure = try failingStore.load(source: source, language: "ja-JP", chunks: chunks)!
        precondition(durableAfterFailure.isComplete && durableAfterFailure.cues == final.cues)
        try FileManager.default.removeItem(at: blockedSRT)
        try failingStore.save(durableAfterFailure)
        try require(try String(contentsOf: blockedSRT, encoding: .utf8).contains("次の章です。"))

        let checkpointURL = store.checkpointURL(source: source, language: "ja-JP")
        let originalCheckpointData = try Data(contentsOf: checkpointURL)
        var unknownVersion = try JSONSerialization.jsonObject(with: originalCheckpointData) as! [String: Any]
        unknownVersion["schemaVersion"] = 999
        let futureData = try JSONSerialization.data(withJSONObject: unknownVersion)
        try futureData.write(to: checkpointURL)
        try require(try store.load(source: source, language: "ja-JP", chunks: chunks) == nil)
        try require(try Data(contentsOf: checkpointURL) == futureData, "Reading unsupported state must not remove it")
        try store.save(final)
        let preservedFuture = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".preserved-") }
        precondition(preservedFuture.count == 1)
        try require(try Data(contentsOf: preservedFuture[0]) == futureData)
        var unsupportedEngine = try JSONSerialization.jsonObject(with: originalCheckpointData) as! [String: Any]
        unsupportedEngine["engine"] = "different-engine"
        try JSONSerialization.data(withJSONObject: unsupportedEngine).write(to: checkpointURL)
        try require(try store.load(source: source, language: "ja-JP", chunks: chunks) == nil)
        try Data("{truncated".utf8).write(to: checkpointURL)
        try require(try store.load(source: source, language: "ja-JP", chunks: chunks) == nil)
        try require(try Data(contentsOf: audio) == sourceBytes, "Progress operations must never write source media")
        try store.save(final)
        let preserved = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".preserved-") }
        precondition(preserved.count == 2)
        let newlyPreserved = preserved.first { !preservedFuture.contains($0) }!
        try require(try Data(contentsOf: newlyPreserved) == Data("{truncated".utf8))

        let replacement = SasayakiTranscriptionCheckpoint(source: source, language: "ja-JP", chunks: differentPlan)
        try store.save(replacement)
        let preservedPlans = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".preserved-") }
        precondition(preservedPlans.count == 3, "Keep completed results when a new chapter plan replaces them")
        try require(try store.load(source: source, language: "ja-JP", chunks: differentPlan)?.completed.isEmpty == true)

        try FileManager.default.setAttributes([.modificationDate: source.modificationDate.addingTimeInterval(30)], ofItemAtPath: audio.path)
        let modified = try SasayakiTranscriptionSource.fingerprint(bookRootURL: scratch.appendingPathComponent("book"), audioURL: audio)
        precondition(modified != source && modified.fileSize == source.fileSize)
        precondition(store.checkpointURL(source: modified, language: "ja-JP") != checkpointURL)
        try Data("changed size".utf8).write(to: audio)
        let resized = try SasayakiTranscriptionSource.fingerprint(bookRootURL: scratch.appendingPathComponent("book"), audioURL: audio)
        precondition(resized.fileSize != source.fileSize)

        do {
            try resumed.record(chunkID: 99, cues: [], elapsedSeconds: 17)
            preconditionFailure("Reject unrelated chunks")
        } catch {}
        do {
            try resumed.record(chunkID: 0, cues: [.init(id: "bad", startTime: .nan, endTime: 7, text: "invalid")], elapsedSeconds: 17)
            preconditionFailure("Reject invalid cue times")
        } catch {}
        precondition(resumed.cues == final.cues, "Rejected writes must retain accepted progress")
    }
}
