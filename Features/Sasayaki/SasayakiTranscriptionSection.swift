// Copyright © 2026 Niratan contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct SasayakiTranscriptionSection: View {
    @Bindable var transcription: SasayakiTranscription
    let audioURL: URL?
    let bookRootURL: URL
    let chapters: [SasayakiAudiobookChapter]
    let preferredTime: Double
    let onUseSubtitles: (URL) -> Void
    @State private var isExporting = false
    @State private var exportDocument = SasayakiSubtitleDocument(text: "")

    var body: some View {
        NativeSettingsSectionCard("Generate Subtitles") {
            VStack(alignment: .leading, spacing: 12) {
                Text("SpeechAnalyzer transcribes audio on this Mac. The first use may download a language model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Audio Language", selection: $transcription.language) {
                    Text("Japanese").tag("ja-JP")
                    Text("English").tag("en-US")
                }
                .disabled(transcription.isRunning || transcription.isRestoring)
                HStack {
                    if transcription.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Text(transcription.status)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Elapsed: \(Duration.seconds(transcription.elapsedSeconds).formatted(.time(pattern: .hourMinuteSecond)))")
                            .monospacedDigit()
                    }
                }
                if transcription.totalChunkCount > 0 {
                    ProgressView(value: Double(transcription.completedChunkCount), total: Double(transcription.totalChunkCount))
                    Text("Completed segments: \(transcription.completedChunkCount) / \(transcription.totalChunkCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("The current audio chapter is processed first. Completed segments are saved automatically and can be exported or matched immediately.")
                    .font(.caption).foregroundStyle(.secondary)
                if let last = transcription.cues.last {
                    Text(last.text).lineLimit(3).textSelection(.enabled)
                }
                HStack {
                    if transcription.isRunning {
                        Button("Pause") { transcription.cancel() }
                    } else {
                        Button {
                            if let audioURL {
                                transcription.start(audioURL: audioURL, bookRootURL: bookRootURL, chapters: chapters,
                                                    preferredTime: preferredTime, restart: transcription.isComplete)
                            }
                        } label: {
                            if transcription.isComplete { Text("Generate Again") }
                            else if transcription.completedChunkCount > 0 { Text("Resume Subtitle Generation") }
                            else { Text("Generate Subtitles") }
                        }
                        .disabled(audioURL == nil || transcription.isRestoring)
                    }
                }
                .buttonStyle(NativeSettingsActionButtonStyle())
                if let url = transcription.subtitleURL {
                    HStack {
                        Button("Export SRT…") {
                            exportDocument = SasayakiSubtitleDocument(text: SasayakiSRT.encode(transcription.cues))
                            isExporting = true
                        }
                        Button("Use for Subtitle Match") { onUseSubtitles(url) }
                    }
                    .buttonStyle(NativeSettingsActionButtonStyle())
                }
                if let error = transcription.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(12)
        }
        .task(id: RestoreKey(audioURL: audioURL, language: transcription.language, chapters: chapters)) {
            if let audioURL {
                await transcription.restore(audioURL: audioURL, bookRootURL: bookRootURL, chapters: chapters)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: UTType(filenameExtension: "srt") ?? .plainText,
            defaultFilename: audioURL?.deletingPathExtension().lastPathComponent ?? "subtitles"
        ) { result in
            if case .failure(let error) = result { transcription.errorMessage = error.localizedDescription }
        }
    }

    private struct RestoreKey: Hashable {
        let audioURL: URL?
        let language: String
        let chapters: [SasayakiAudiobookChapter]
    }
}

private struct SasayakiSubtitleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "srt") ?? .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
