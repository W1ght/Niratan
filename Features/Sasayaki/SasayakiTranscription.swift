// Copyright © 2026 Niratan contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import Observation

/// One audiobook session. Completed chunks survive sheet/window closure and process exit.
@MainActor @Observable
final class SasayakiTranscription {
    var language = "ja-JP"
    private(set) var isRunning = false
    private(set) var isRestoring = false
    private(set) var status = String(localized: "Ready to Transcribe")
    private(set) var startedAt: ContinuousClock.Instant?
    private(set) var elapsed: TimeInterval = 0
    private(set) var cues: [SasayakiCue] = []
    private(set) var subtitleURL: URL?
    var errorMessage: String?
    private var checkpoint: SasayakiTranscriptionCheckpoint?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var restoredAudioKey: String?
    private let storeDirectory: URL?
    private let maximumChunkDuration: Double

    init(storeDirectory: URL? = nil, maximumChunkDuration: Double = 300) {
        self.storeDirectory = storeDirectory
        self.maximumChunkDuration = maximumChunkDuration
    }

    var completedChunkCount: Int { checkpoint?.completed.count ?? 0 }
    var totalChunkCount: Int { checkpoint?.chunks.count ?? 0 }
    var completedDuration: Double { checkpoint?.completedDuration ?? 0 }
    var isComplete: Bool { checkpoint?.isComplete == true }
    var canResume: Bool { checkpoint != nil && !isComplete }
    var elapsedSeconds: TimeInterval {
        guard isRunning, let startedAt else { return elapsed }
        let duration = startedAt.duration(to: .now)
        return elapsed + Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    func restore(audioURL: URL, bookRootURL: URL, chapters: [SasayakiAudiobookChapter]) async {
        guard !isRunning else { return }
        let id = UUID()
        generation = id
        isRestoring = true
        let audioKey = bookRootURL.path + "|" + audioURL.path
        let useSavedLanguage = restoredAudioKey != audioKey
        checkpoint = nil
        cues = []
        subtitleURL = nil
        elapsed = 0
        defer { if generation == id { isRestoring = false } }
        do {
            let prepared = try await Self.load(audioURL: audioURL, bookRootURL: bookRootURL, language: language,
                                               chapters: chapters, directory: storeDirectory, maximumChunkDuration: maximumChunkDuration,
                                               useSavedLanguage: useSavedLanguage)
            guard generation == id, !Task.isCancelled else { return }
            restoredAudioKey = audioKey
            language = prepared.language
            checkpoint = prepared
            elapsed = prepared.elapsedSeconds
            cues = prepared.cues
            // A checkpoint is authoritative; recreate an absent/interrupted SRT export.
            if !prepared.completed.isEmpty {
                let url = try SasayakiTranscriptionProgressStore(directory: storeDirectory).save(prepared)
                subtitleURL = cues.isEmpty ? nil : url
            } else {
                subtitleURL = nil
            }
            errorMessage = nil
            status = isComplete ? String(localized: "Subtitles Generated") : canResume && completedChunkCount > 0
                ? String(localized: "Transcription Paused") : String(localized: "Ready to Transcribe")
        } catch {
            guard generation == id else { return }
            errorMessage = error.localizedDescription
        }
    }

    func start(audioURL: URL, bookRootURL: URL, chapters: [SasayakiAudiobookChapter], preferredTime: Double, restart: Bool = false) {
        guard !isRunning, !isRestoring else { return }
        let id = UUID()
        generation = id
        let localeID = language
        errorMessage = nil
        status = String(localized: "Preparing Speech Model…")
        startedAt = .now
        isRunning = true
        task = Task { [weak self] in
            do {
                guard let self else { return }
                let prepared = try await Self.load(audioURL: audioURL, bookRootURL: bookRootURL, language: localeID,
                                                   chapters: chapters, directory: self.storeDirectory, maximumChunkDuration: self.maximumChunkDuration)
                try Task.checkCancellation()
                guard self.generation == id else { return }
                self.checkpoint = restart ? SasayakiTranscriptionCheckpoint(source: prepared.source, language: localeID, chunks: prepared.chunks) : prepared
                self.elapsed = self.checkpoint?.elapsedSeconds ?? 0
                self.cues = self.checkpoint?.cues ?? []
                if self.cues.isEmpty { self.subtitleURL = nil }
                guard !self.isComplete else {
                    try self.saveProgress()
                    self.status = String(localized: "Subtitles Generated")
                    self.finish()
                    return
                }
                let locale = try await SasayakiSpeechEngine.prepare(language: localeID)
                try Task.checkCancellation()
                guard self.generation == id, let checkpoint = self.checkpoint else { return }
                let pending = SasayakiTranscriptionPlanner.pendingChunks(
                    chunks: checkpoint.chunks, completedChunkIDs: Set(checkpoint.completed.keys), preferredTime: preferredTime
                )
                self.status = String(localized: "Generating Subtitles…")
                let duration = checkpoint.chunks.last?.endTime ?? 0
                try await Self.runWorkers(audioURL: audioURL, locale: locale, chunks: pending, duration: duration) { [weak self] chunk, cues in
                    guard let self, self.generation == id else { throw CancellationError() }
                    guard try SasayakiTranscriptionSource.fingerprint(bookRootURL: bookRootURL, audioURL: audioURL) == checkpoint.source else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    try self.checkpoint?.record(chunkID: chunk.id, cues: cues, elapsedSeconds: self.elapsedSeconds)
                    self.cues = self.checkpoint?.cues ?? []
                    try self.saveProgress()
                }
                try Task.checkCancellation()
                guard self.generation == id else { return }
                self.finish()
                try self.saveProgress()
                self.status = String(localized: "Subtitles Generated")
                if self.cues.isEmpty { self.errorMessage = String(localized: "No speech was recognized. Check the audio and selected language.") }
            } catch {
                guard let self, self.generation == id else { return }
                self.finish()
                self.status = String(localized: "Transcription Paused")
                self.errorMessage = error is CancellationError ? nil : error.localizedDescription
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRestoring = false
        if isRunning {
            finish()
            status = String(localized: "Transcription Paused")
            do { try saveProgress() } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Changing sessions only clears the presentation, never the persisted transcript.
    func reset() {
        cancel()
        checkpoint = nil
        restoredAudioKey = nil
        subtitleURL = nil
        cues = []
        errorMessage = nil
        startedAt = nil
        elapsed = 0
        status = String(localized: "Ready to Transcribe")
    }

    private func finish() {
        elapsed = elapsedSeconds
        isRunning = false
        startedAt = nil
        task = nil
    }

    private func saveProgress() throws {
        guard var checkpoint else { return }
        checkpoint.recordElapsed(elapsedSeconds)
        // Serialized on the session actor: an older completion cannot overwrite a pause/new run.
        let url = try SasayakiTranscriptionProgressStore(directory: storeDirectory).save(checkpoint)
        self.checkpoint = checkpoint
        subtitleURL = checkpoint.cues.isEmpty ? nil : url
    }

    private nonisolated static func load(
        audioURL: URL, bookRootURL: URL, language: String, chapters: [SasayakiAudiobookChapter],
        directory: URL?, maximumChunkDuration: Double, useSavedLanguage: Bool = false
    ) async throws -> SasayakiTranscriptionCheckpoint {
        let accessing = audioURL.startAccessingSecurityScopedResource()
        defer { if accessing { audioURL.stopAccessingSecurityScopedResource() } }
        let source = try SasayakiTranscriptionSource.fingerprint(bookRootURL: bookRootURL, audioURL: audioURL)
        let file = try AVAudioFile(forReading: audioURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let chunks = SasayakiTranscriptionPlanner.chunks(duration: duration, chapters: chapters, maximumChunkDuration: maximumChunkDuration)
        guard !chunks.isEmpty else { throw SasayakiSpeechEngine.Failure.audio }
        let store = try SasayakiTranscriptionProgressStore(directory: directory)
        let chosenLanguage = useSavedLanguage ? store.preferredLanguage(source: source) ?? language : language
        return try store.load(source: source, language: chosenLanguage, chunks: chunks)
            ?? SasayakiTranscriptionCheckpoint(source: source, language: chosenLanguage, chunks: chunks)
    }

    private nonisolated static func runWorkers(
        audioURL: URL, locale: Locale, chunks: [SasayakiTranscriptionChunk], duration: Double,
        onCompleted: @escaping @MainActor @Sendable (SasayakiTranscriptionChunk, [SasayakiCue]) throws -> Void
    ) async throws {
        let accessing = audioURL.startAccessingSecurityScopedResource()
        defer { if accessing { audioURL.stopAccessingSecurityScopedResource() } }
        try await withThrowingTaskGroup(of: (SasayakiTranscriptionChunk, [SasayakiCue]).self) { group in
            var nextIndex = 0
            func enqueue() {
                guard nextIndex < chunks.count else { return }
                let chunk = chunks[nextIndex]
                nextIndex += 1
                group.addTask(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let cues = try await SasayakiSpeechEngine.transcribe(audioURL: audioURL, locale: locale, id: chunk.id,
                                                                       start: chunk.startTime, end: chunk.endTime, duration: duration)
                    return (chunk, cues)
                }
            }
            enqueue()
            enqueue()
            while let (chunk, cues) = try await group.next() {
                try Task.checkCancellation()
                try await onCompleted(chunk, cues)
                enqueue()
            }
        }
    }
}
