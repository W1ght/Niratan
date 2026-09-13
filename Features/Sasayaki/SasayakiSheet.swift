//
//  SasayakiSheet.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SasayakiPlaybackLimits {
    static let speedRange: ClosedRange<Float> = 0.5...2.5
}

private enum SasayakiFileImportKind {
    case audio
    case subtitle
}

private enum SasayakiSheetTab: String, CaseIterable, Identifiable {
    case resources
    case chapters
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .resources: "Resources"
        case .chapters: "Chapters"
        case .settings: "Settings"
        }
    }
}

struct SasayakiSheet: View {
    @Environment(UserConfig.self) private var userConfig
    var player: SasayakiPlayer
    let bookTitle: String
    let bookCoverURL: URL?
    let onImportAudio: (URL) throws -> Void
    let onDismiss: () -> Void

    @State private var isFileImporterPresented = false
    @State private var pendingFileImportKind: SasayakiFileImportKind?
    @State private var subtitleURL: URL?
    @State private var selectedTab: SasayakiSheetTab = .resources
    @State private var userSelectedTab = false

    private static let audioContentTypes = ["mp3", "m4b"].compactMap { UTType(filenameExtension: $0) }
    private static let subtitleContentTypes: [UTType] = {
        let explicitTypes = ["srt"].compactMap { UTType(filenameExtension: $0) }
        return explicitTypes + [.plainText, .text]
    }()

    var body: some View {
        NativeReaderSheetPanel("Sasayaki", onClose: onDismiss) {
            VStack(spacing: 0) {
                if player.hasAudio {
                    playbackHeader
                }

                HStack {
                    Spacer(minLength: 0)
                    NativeGlassSegmentedPicker(
                        selection: selectedTabBinding,
                        values: SasayakiSheetTab.allCases,
                        minSegmentWidth: 72
                    ) { tab in
                        Text(tab.title)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

                selectedContent
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: allowedContentTypes(for: pendingFileImportKind)
        ) { result in
            let importKind = pendingFileImportKind
            defer {
                pendingFileImportKind = nil
                isFileImporterPresented = false
            }

            guard case .success(let url) = result else { return }
            switch importKind {
            case .audio:
                do {
                    try onImportAudio(url)
                } catch {
                    player.errorMessage = error.localizedDescription
                }
            case .subtitle:
                subtitleURL = url
            case nil:
                break
            }
        }
        .onChange(of: player.transcription.subtitleURL) { oldURL, newURL in
            if let oldURL, subtitleURL == oldURL { subtitleURL = newURL }
        }
        .onAppear(perform: selectDefaultTabIfNeeded)
        .onChange(of: player.hasAudio) { _, _ in
            selectDefaultTabIfNeeded()
        }
        .onChange(of: player.audiobookChapters) { _, _ in
            selectDefaultTabIfNeeded()
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .resources:
            resourcesTab
        case .chapters:
            chaptersTab
        case .settings:
            settingsTab
        }
    }

    private var selectedTabBinding: Binding<SasayakiSheetTab> {
        Binding(
            get: { selectedTab },
            set: { tab in
                userSelectedTab = true
                selectedTab = tab
            }
        )
    }

    private var playbackHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                audiobookCover

                VStack(alignment: .leading, spacing: 3) {
                    Text(player.audiobookMetadata.title ?? bookTitle)
                        .font(.headline)
                        .lineLimit(1)

                    if let artist = player.audiobookMetadata.artist {
                        Text(artist)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let currentChapterTitle {
                        Text(currentChapterTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            audioControls
            Text("\(Self.formatTime(player.currentTime)) / \(Self.formatTime(player.duration))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var audiobookCover: some View {
        SasayakiAudiobookCoverView(
            artworkData: player.audiobookMetadata.artworkData,
            fallbackURL: bookCoverURL,
            audioURL: player.audioURL
        )
        .frame(width: 72, height: 72)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var currentChapterTitle: String? {
        guard let id = player.currentAudiobookChapterID else { return nil }
        return player.audiobookChapters.first(where: { $0.id == id })?.title
    }

    private var resourcesTab: some View {
        NativeSettingsForm {
            NativeSettingsSectionCard("Audio") {
                NativeSettingsRow("Load Audio") {
                    Button("Load Audio") {
                        pendingFileImportKind = .audio
                        isFileImporterPresented = true
                    }
                    .buttonStyle(NativeSettingsActionButtonStyle())
                }

                if let errorMessage = player.errorMessage {
                    NativeSettingsSeparator()
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }

            SasayakiTranscriptionSection(
                transcription: player.transcription,
                audioURL: player.audioURL,
                bookRootURL: player.rootURL,
                chapters: player.audiobookChapters,
                preferredTime: player.currentTime
            ) { url in
                subtitleURL = url
            }

            SasayakiSubtitleMatchSection(
                rootURL: player.rootURL,
                fileURL: $subtitleURL,
                displayName: subtitleURL != nil && subtitleURL == player.transcription.subtitleURL ? String(localized: "Generated Subtitles") : nil,
                onImportRequested: {
                    pendingFileImportKind = .subtitle
                    isFileImporterPresented = true
                }
            ) { matchData in
                player.updateMatchData(matchData)
            }
        }
    }

    @ViewBuilder
    private var chaptersTab: some View {
        if player.isLoadingAudiobookChapters {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading Chapters...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if player.audiobookChapters.isEmpty {
            ContentUnavailableView("No Chapters", systemImage: "list.bullet")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(player.audiobookChapters) { chapter in
                Button {
                    player.seekToAudiobookChapter(chapter)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chapter.title)
                                .lineLimit(1)
                            if player.currentAudiobookChapterID == chapter.id {
                                Text("Current Chapter")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        Text(Self.formatChapterTime(chapter.startTime))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    player.currentAudiobookChapterID == chapter.id
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var settingsTab: some View {
        @Bindable var userConfig = userConfig

        return NativeSettingsForm {
            NativeSettingsSectionCard("Playback") {
                VStack(spacing: 8) {
                    HStack {
                        Text("Delay")
                        Spacer()
                        Text(String(format: "%+.2fs", player.delay))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                    Slider(value: Bindable(player).delay, in: -2...2, step: 0.05)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                NativeSettingsSeparator()

                VStack(spacing: 8) {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text(String(format: "%.2fx", player.rate))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                    Slider(value: Bindable(player).rate, in: SasayakiPlaybackLimits.speedRange, step: 0.05)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            NativeSettingsSectionCard("Settings") {
                NativeSettingsToggle("Show Sasayaki Toggle", isOn: $userConfig.readerShowSasayakiToggle)
                NativeSettingsSeparator()
                NativeSettingsToggle("Auto-Scroll", isOn: $userConfig.sasayakiAutoScroll)
                NativeSettingsSeparator()
                NativeSettingsToggle("Auto-Pause on Lookup", isOn: $userConfig.sasayakiAutoPause)
            }

            NativeSettingsSectionCard("Light Theme") {
                NativeSettingsRow("Text Color") {
                    ColorPicker("", selection: $userConfig.sasayakiTextColor)
                        .labelsHidden()
                }
                NativeSettingsSeparator()
                NativeSettingsRow("Background Color") {
                    ColorPicker("", selection: $userConfig.sasayakiBackgroundColor)
                        .labelsHidden()
                }
            }

            NativeSettingsSectionCard("Dark Theme") {
                NativeSettingsRow("Text Color") {
                    ColorPicker("", selection: $userConfig.sasayakiDarkTextColor)
                        .labelsHidden()
                }
                NativeSettingsSeparator()
                NativeSettingsRow("Background Color") {
                    ColorPicker("", selection: $userConfig.sasayakiDarkBackgroundColor)
                        .labelsHidden()
                }
            }
        }
    }

    private func selectDefaultTabIfNeeded() {
        guard !userSelectedTab else { return }
        selectedTab = player.hasAudio && !player.audiobookChapters.isEmpty ? .chapters : .resources
    }

    private func allowedContentTypes(for importKind: SasayakiFileImportKind?) -> [UTType] {
        switch importKind {
        case .audio:
            Self.audioContentTypes
        case .subtitle:
            Self.subtitleContentTypes
        case nil:
            Self.audioContentTypes
        }
    }

    private var audioControls: some View {
        HStack(spacing: 20) {
            Button {
                player.skip(forward: false)
            } label: {
                Image(systemName: "15.arrow.trianglehead.counterclockwise")
            }

            Button {
                player.prevCue()
            } label: {
                Image(systemName: "backward.fill")
            }

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30))
            }

            Button {
                player.nextCue()
            } label: {
                Image(systemName: "forward.fill")
            }

            Button {
                player.skip(forward: true)
            } label: {
                Image(systemName: "15.arrow.trianglehead.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .font(.title2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func formatChapterTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct SasayakiAudiobookCoverView: View {
    let artworkData: Data?
    let fallbackURL: URL?
    let audioURL: URL?

    @State private var artworkImage: NSImage?

    var body: some View {
        Group {
            if let artworkImage {
                Image(nsImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                CoverImage(url: fallbackURL, maxPixelSize: 256) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    ZStack {
                        Color.secondary.opacity(0.14)
                        Image(systemName: "waveform")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: SasayakiArtworkLoadKey(audioURL: audioURL, byteCount: artworkData?.count)) {
            artworkImage = artworkData.flatMap(NSImage.init(data:))
        }
    }
}

private struct SasayakiArtworkLoadKey: Hashable {
    let audioPath: String?
    let byteCount: Int?

    init(audioURL: URL?, byteCount: Int?) {
        audioPath = audioURL?.path(percentEncoded: false)
        self.byteCount = byteCount
    }
}
