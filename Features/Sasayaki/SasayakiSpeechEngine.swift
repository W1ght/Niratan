// Copyright © 2026 Niratan contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import Speech

/// Each worker decodes only its bounded audio range; source media is never written.
enum SasayakiSpeechEngine {
    nonisolated static func prepare(language: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw Failure.unsupported
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        return locale
    }

    nonisolated static func transcribe(
        audioURL: URL, locale: Locale, id: Int, start: Double, end: Double, duration: Double
    ) async throws -> [SasayakiCue] {
        let contextStart = max(0, start - 2)
        let contextEnd = min(duration, end + 2)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SasayakiWorker-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audio.caf")
        try extract(audioURL, to: url, start: contextStart, end: contextEnd)
        try Task.checkCancellation()
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        let file = try AVAudioFile(forReading: url)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                var cues: [SasayakiCue] = []
                for try await result in module.results {
                    try Task.checkCancellation()
                    let tokens = result.text.runs.compactMap { run -> SasayakiTimedText? in
                        guard let range = run.audioTimeRange else { return nil }
                        return SasayakiTimedText(
                            text: String(result.text[run.range].characters),
                            start: contextStart + range.start.seconds,
                            end: contextStart + CMTimeRangeGetEnd(range).seconds
                        )
                    }
                    // SpeechTranscriber supplies word timings. Do not assign a many-sentence
                    // result one giant subtitle if a provider unexpectedly omits attributes.
                    let parts = tokens.isEmpty ? [SasayakiTimedText(
                        text: String(result.text.characters),
                        start: contextStart + result.range.start.seconds,
                        end: contextStart + CMTimeRangeGetEnd(result.range).seconds
                    )] : tokens
                    cues.append(contentsOf: SasayakiSpeechCueBuilder.build(
                        parts, ownedRange: start..<end, idPrefix: "\(id)-\(cues.count)"
                    ))
                }
                try Task.checkCancellation()
                return cues
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private nonisolated static func extract(_ source: URL, to destination: URL, start: Double, end: Double) throws {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        let firstFrame = AVAudioFramePosition((start * format.sampleRate).rounded())
        let lastFrame = min(file.length, AVAudioFramePosition((end * format.sampleRate).rounded()))
        file.framePosition = firstFrame
        let output = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw Failure.audio }
        while file.framePosition < lastFrame {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), lastFrame - file.framePosition))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    enum Failure: LocalizedError {
        case unsupported, audio
        nonisolated var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "SpeechAnalyzer is unavailable for this language or Mac.")
            case .audio: String(localized: "Could not read audiobook audio.")
            }
        }
    }
}

struct SasayakiTimedText: Sendable {
    let text: String
    let start: Double
    let end: Double
}

enum SasayakiSpeechCueBuilder {
    nonisolated static func build(_ tokens: [SasayakiTimedText], ownedRange: Range<Double>, idPrefix: String) -> [SasayakiCue] {
        var cues: [SasayakiCue] = []
        var text = ""
        var first = 0.0, last = 0.0
        func flush() {
            let cleaned = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, last > first {
                cues.append(SasayakiCue(id: "\(idPrefix)-\(cues.count)", startTime: first, endTime: last, text: cleaned))
            }
            text = ""
        }
        for token in tokens {
            guard token.start.isFinite, token.end.isFinite, token.end > token.start,
                  ownedRange.contains((token.start + token.end) / 2) else { continue }
            if !text.isEmpty && (token.start - last > 0.8 || token.end - first > 8 || text.count + token.text.count > 80) { flush() }
            if text.isEmpty { first = token.start }
            text += token.text
            last = token.end
            if let ending = token.text.trimmingCharacters(in: .whitespacesAndNewlines).last,
               "。！？.!?".contains(ending) { flush() }
        }
        flush()
        return cues
    }
}
