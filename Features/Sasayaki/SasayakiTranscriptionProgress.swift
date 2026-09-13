// Copyright © 2026 Niratan contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// The owned interval uses the original audiobook timeline. Audio supplied to the
/// analyzer may include extra context outside this interval.
nonisolated struct SasayakiTranscriptionChunk: Codable, Hashable, Sendable {
    let id: Int
    let startTime: Double
    let endTime: Double
    let chapterID: Int?

    var duration: Double { endTime - startTime }
}

nonisolated enum SasayakiTranscriptionPlanner {
    static func chunks(
        duration: Double,
        chapters: [SasayakiAudiobookChapter],
        maximumChunkDuration: Double = 300
    ) -> [SasayakiTranscriptionChunk] {
        guard duration.isFinite, duration > 0,
              maximumChunkDuration.isFinite, maximumChunkDuration > 0 else { return [] }

        let validChapters = chapters.filter {
            $0.startTime.isFinite && $0.startTime >= 0 && $0.startTime < duration
        }.sorted {
            $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime
        }
        var result: [SasayakiTranscriptionChunk] = []
        func appendRange(start: Double, end: Double, chapterID: Int?) {
            var cursor = start
            while cursor < end {
                let next = min(end, cursor + maximumChunkDuration)
                guard next > cursor else { break }
                result.append(.init(id: result.count, startTime: cursor, endTime: next, chapterID: chapterID))
                cursor = next
            }
        }

        var cursor = 0.0
        for (index, chapter) in validChapters.enumerated() {
            let nextStart = index + 1 < validChapters.count ? validChapters[index + 1].startTime : duration
            let end = chapter.endTime.flatMap {
                $0.isFinite && $0 > chapter.startTime ? min($0, nextStart) : nil
            } ?? nextStart
            if chapter.startTime > cursor {
                appendRange(start: cursor, end: chapter.startTime, chapterID: nil)
            }
            appendRange(start: max(cursor, chapter.startTime), end: end, chapterID: chapter.id)
            cursor = max(cursor, end)
        }
        appendRange(start: cursor, end: duration, chapterID: nil)
        return result
    }

    /// Prioritize the whole current chapter, then later audio, then earlier audio.
    /// Without chapter markers the current chunk is the first scheduling unit.
    static func pendingChunks(
        chunks: [SasayakiTranscriptionChunk],
        completedChunkIDs: Set<Int>,
        preferredTime: Double
    ) -> [SasayakiTranscriptionChunk] {
        let ordered = chunks.sorted { $0.startTime < $1.startTime }
        guard let first = ordered.first, let last = ordered.last else { return [] }
        let time = preferredTime.isFinite ? min(max(preferredTime, first.startTime), last.endTime) : first.startTime
        let current = ordered.first { $0.startTime <= time && time < $0.endTime } ?? last
        let chapterChunks = current.chapterID.map { chapterID in
            ordered.filter { $0.chapterID == chapterID }
        } ?? [current]
        let currentIDs = Set(chapterChunks.map(\.id))
        let chapterEnd = chapterChunks.last?.endTime ?? current.endTime
        let later = ordered.filter { !currentIDs.contains($0.id) && $0.startTime >= chapterEnd }
        let earlier = ordered.filter { !currentIDs.contains($0.id) && $0.startTime < chapterEnd }
        return (chapterChunks + later + earlier).filter { !completedChunkIDs.contains($0.id) }
    }
}

/// Metadata fingerprinting avoids a full read of a many-hour audiobook. The book
/// root and audio are explicit session inputs, independent of the active Profile.
nonisolated struct SasayakiTranscriptionSource: Codable, Equatable, Sendable {
    let bookRootPath: String
    let audioPath: String
    let fileSize: Int64
    let modificationDate: Date

    static func fingerprint(bookRootURL: URL, audioURL: URL) throws -> Self {
        guard bookRootURL.isFileURL, audioURL.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let canonicalAudio = audioURL.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: canonicalAudio.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return .init(
            bookRootPath: bookRootURL.standardizedFileURL.resolvingSymlinksInPath().path,
            audioPath: canonicalAudio.path,
            fileSize: size.int64Value,
            modificationDate: date
        )
    }
}

nonisolated struct SasayakiTranscriptionCheckpoint: Codable, Sendable {
    static let currentSchemaVersion = 1
    static let currentEngine = "apple-speech-transcriber-word-timing-v1"

    let schemaVersion: Int
    let engine: String
    let source: SasayakiTranscriptionSource
    let language: String
    let chunks: [SasayakiTranscriptionChunk]
    private(set) var completed: [Int: [SasayakiCue]]
    private(set) var elapsedSeconds: TimeInterval

    init(source: SasayakiTranscriptionSource, language: String, chunks: [SasayakiTranscriptionChunk]) {
        schemaVersion = Self.currentSchemaVersion
        engine = Self.currentEngine
        self.source = source
        self.language = language
        self.chunks = chunks
        completed = [:]
        elapsedSeconds = 0
    }

    var cues: [SasayakiCue] {
        chunks.flatMap { chunk in
            (completed[chunk.id] ?? []).enumerated().map { index, cue in
                SasayakiCue(id: "\(chunk.id):\(index)", startTime: cue.startTime, endTime: cue.endTime, text: cue.text)
            }
        }.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
            return $0.id < $1.id
        }
    }

    var completedDuration: Double {
        chunks.filter { completed[$0.id] != nil }.reduce(0) { $0 + $1.duration }
    }

    var isComplete: Bool { !chunks.isEmpty && chunks.allSatisfy { completed[$0.id] != nil } }

    /// elapsedSeconds is total wall-clock time across runs, not a sum of parallel
    /// workers' durations. An empty cue list still completes a silent chunk.
    mutating func record(chunkID: Int, cues: [SasayakiCue], elapsedSeconds: TimeInterval) throws {
        guard chunks.contains(where: { $0.id == chunkID }),
              cues.allSatisfy(Self.isValidCue),
              elapsedSeconds.isFinite, elapsedSeconds >= 0 else {
            throw CocoaError(.coderInvalidValue)
        }
        completed[chunkID] = cues
        self.elapsedSeconds = max(self.elapsedSeconds, elapsedSeconds)
    }

    /// Also retain time spent in preparation or a partially processed chunk when
    /// the session stops, without falsely marking that chunk completed.
    mutating func recordElapsed(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        elapsedSeconds = max(elapsedSeconds, seconds)
    }

    fileprivate var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion, engine == Self.currentEngine,
              !chunks.isEmpty, !language.isEmpty, source.fileSize >= 0,
              elapsedSeconds.isFinite, elapsedSeconds >= 0,
              Set(chunks.map(\.id)).count == chunks.count,
              Set(completed.keys).isSubset(of: Set(chunks.map(\.id))) else { return false }
        var previousEnd = 0.0
        for chunk in chunks {
            guard chunk.id >= 0, chunk.startTime.isFinite, chunk.endTime.isFinite,
                  chunk.startTime == previousEnd, chunk.endTime > chunk.startTime else { return false }
            previousEnd = chunk.endTime
        }
        return completed.values.allSatisfy { $0.allSatisfy(Self.isValidCue) }
    }

    private static func isValidCue(_ cue: SasayakiCue) -> Bool {
        cue.startTime.isFinite && cue.endTime.isFinite && cue.startTime >= 0
            && cue.endTime > cue.startTime && !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Only writes App-owned output. The checkpoint is authoritative; its SRT is a
/// regenerable projection and can be repaired by saving a loaded checkpoint.
nonisolated struct SasayakiTranscriptionProgressStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) throws {
        if let directory {
            guard directory.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
            self.directory = directory.standardizedFileURL
        } else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            self.directory = support.appendingPathComponent("moe.shishamo.hoshi/SasayakiTranscription", isDirectory: true)
        }
    }

    func load(
        source: SasayakiTranscriptionSource,
        language: String,
        chunks: [SasayakiTranscriptionChunk]? = nil
    ) throws -> SasayakiTranscriptionCheckpoint? {
        let url = checkpointURL(source: source, language: language)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        // Reading unsupported or corrupt checkpoints leaves them untouched.
        guard let checkpoint = try? JSONDecoder().decode(SasayakiTranscriptionCheckpoint.self, from: data),
              checkpoint.isValid, checkpoint.source == source, checkpoint.language == language,
              chunks == nil || checkpoint.chunks == chunks else { return nil }
        return checkpoint
    }

    @discardableResult
    func save(_ checkpoint: SasayakiTranscriptionCheckpoint) throws -> URL {
        guard checkpoint.isValid else { throw CocoaError(.coderInvalidValue) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let checkpointURL = checkpointURL(source: checkpoint.source, language: checkpoint.language)
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            let existingData = try Data(contentsOf: checkpointURL)
            let existing = try? JSONDecoder().decode(SasayakiTranscriptionCheckpoint.self, from: existingData)
            if existing?.isValid != true || existing?.source != checkpoint.source
                || existing?.language != checkpoint.language || existing?.chunks != checkpoint.chunks {
                // A changed chapter plan or unreadable checkpoint must not destroy
                // an earlier result. Keep the original bytes before replacing it.
                let preservedURL = directory.appendingPathComponent(
                    checkpointURL.deletingPathExtension().lastPathComponent + ".preserved-\(UUID()).json"
                )
                try existingData.write(to: preservedURL, options: .atomic)
            }
        }
        try encoder.encode(checkpoint).write(
            to: checkpointURL, options: .atomic
        )
        let srtURL = subtitleURL(source: checkpoint.source, language: checkpoint.language)
        try SasayakiSRT.encode(checkpoint.cues).write(to: srtURL, atomically: true, encoding: .utf8)
        return srtURL
    }

    func subtitleURL(source: SasayakiTranscriptionSource, language: String) -> URL {
        directory.appendingPathComponent(storageKey(source: source, language: language) + ".srt")
    }

    /// Restore the most recently saved supported language for this exact source.
    /// File metadata is enough; do not decode two large transcripts just to choose
    /// the initial language control value.
    func preferredLanguage(source: SasayakiTranscriptionSource) -> String? {
        ["ja-JP", "en-US"].compactMap { language -> (String, Date)? in
            let url = checkpointURL(source: source, language: language)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            return (language, modified)
        }.max { $0.1 < $1.1 }?.0
    }

    func checkpointURL(source: SasayakiTranscriptionSource, language: String) -> URL {
        directory.appendingPathComponent(storageKey(source: source, language: language) + ".json")
    }

    private func storageKey(source: SasayakiTranscriptionSource, language: String) -> String {
        // Hash only small identity metadata, never audiobook bytes. Length-prefixed
        // strings prevent path/language delimiter ambiguity.
        let fields = [String(SasayakiTranscriptionCheckpoint.currentSchemaVersion),
                      SasayakiTranscriptionCheckpoint.currentEngine,
                      source.bookRootPath, source.audioPath, String(source.fileSize),
                      String(source.modificationDate.timeIntervalSinceReferenceDate.bitPattern), language]
        let identity = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
