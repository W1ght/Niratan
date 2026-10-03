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

    var systemImage: String {
        switch self {
        case .resources: "tray.and.arrow.down"
        case .chapters: "list.bullet"
        case .settings: "gearshape"
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
    @State private var scrubTime: Double?

    private static let audioContentTypes = ["mp3", "m4b"].compactMap { UTType(filenameExtension: $0) }
    private static let subtitleContentTypes: [UTType] = {
        let explicitTypes = ["srt"].compactMap { UTType(filenameExtension: $0) }
        return explicitTypes + [.plainText, .text]
    }()

    var body: some View {
        VStack(spacing: 0) {
            NativeReaderInspectorHeader(title: "Sasayaki", subtitle: currentChapterTitle, onClose: onDismiss)

            if player.hasAudio {
                playbackHeader
            }

            NativeReaderInspectorTabBar(
                tabs: SasayakiSheetTab.allCases,
                selection: selectedTabBinding,
                title: \.title,
                systemImage: \.systemImage
            )
            .padding(.bottom, 10)

            selectedContent
        }
        .environment(\.nativeSettingsPresentation, .inspector)
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
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                audiobookCover

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.audiobookMetadata.title ?? bookTitle)
                        .font(.headline)
                        .lineLimit(2)

                    if let artist = player.audiobookMetadata.artist {
                        Text(artist)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { scrubTime ?? player.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(player.duration, 1)
                ) { isEditing in
                    if !isEditing, let target = scrubTime {
                        player.seekRelative(target - player.currentTime)
                        scrubTime = nil
                    }
                }
                .controlSize(.small)

                HStack {
                    Text(Self.formatTime(scrubTime ?? player.currentTime))
                    Spacer()
                    Text("-" + Self.formatTime(max(player.duration - (scrubTime ?? player.currentTime), 0)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            audioControls
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var audiobookCover: some View {
        SasayakiAudiobookCoverView(
            artworkData: player.audiobookMetadata.artworkData,
            fallbackURL: bookCoverURL,
            audioURL: player.audioURL
        )
        .frame(width: 64, height: 64)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
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
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(player.audiobookChapters) { chapter in
                        let isCurrent = player.currentAudiobookChapterID == chapter.id
                        Button {
                            player.seekToAudiobookChapter(chapter)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "circle.fill")
                                    .font(.system(size: isCurrent ? 11 : 4))
                                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                                    .frame(width: 14)
                                Text(chapter.title)
                                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Text(Self.formatChapterTime(chapter.startTime))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(NativeReaderInspectorRowButtonStyle(isSelected: isCurrent))
                        .accessibilityValue(isCurrent ? Text("Current Chapter") : Text(""))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
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
        HStack(spacing: 10) {
            NativeGlassCircleButton(systemName: "15.arrow.trianglehead.counterclockwise", diameter: 34, fontSize: 14) {
                player.skip(forward: false)
            }
            NativeGlassCircleButton(systemName: "backward.fill", diameter: 34, fontSize: 13) {
                player.prevCue()
            }

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .help(player.isPlaying ? Text("Pause") : Text("Play"))

            NativeGlassCircleButton(systemName: "forward.fill", diameter: 34, fontSize: 13) {
                player.nextCue()
            }
            NativeGlassCircleButton(systemName: "15.arrow.trianglehead.clockwise", diameter: 34, fontSize: 14) {
                player.skip(forward: true)
            }
        }
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
