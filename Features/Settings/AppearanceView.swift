//
//  AppearanceView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers

struct AppearanceView: View {
    let userConfig: UserConfig
    let showDismiss: Bool
    @Environment(\.dismiss) var dismiss
    @State private var isImportingFont = false
    @State private var importedFonts: [String] = []
    @State private var downloadingFont: String? = nil
    @State private var showingDeleteConfirmation = false
    @State private var fontToDelete: String? = nil

    var body: some View {
        @Bindable var userConfig = userConfig
        let fontSelection = Binding<String>(
            get: { userConfig.selectedFont },
            set: { newFont in
                guard downloadingFont == nil else { return }

                guard FontManager.downloadableFonts.contains(newFont),
                      !FontManager.shared.hasDownloadedFont(name: newFont) else {
                    userConfig.selectedFont = newFont
                    return
                }

                let previousFont = userConfig.selectedFont
                downloadingFont = newFont

                Task {
                    let success = await FontManager.downloadFont(newFont)
                    downloadingFont = nil
                    userConfig.selectedFont = success ? newFont : previousFont
                }
            }
        )
        Group {
            nativeAppearanceContent(fontSelection: fontSelection)
        }
        .toolbar {
            if showDismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .navigationTitle("Appearance")
        .inlineNavigationTitleIfAvailable()
        .onAppear {
            importedFonts = (try? FontManager.shared.storedFonts())?.map { $0.deletingPathExtension().lastPathComponent } ?? []
        }
    }

    @ViewBuilder
    private func nativeAppearanceContent(fontSelection: Binding<String>) -> some View {
        @Bindable var userConfig = userConfig

        NativeSettingsForm {
            NativeSettingsSectionCard("Theme") {
                    NativeGlassSegmentedPicker(
                        selection: $userConfig.theme,
                        values: Themes.allCases,
                        minSegmentWidth: 44,
                        fillsWidth: true
                    ) { mode in
                        textForTheme(mode)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    if userConfig.theme == .system {
                        NativeSettingsSeparator()
                        NativeSettingsToggle("Use Sepia as Light Theme", isOn: $userConfig.systemLightSepia)
                    }
                    if userConfig.theme == .custom {
                        NativeSettingsSeparator()
                        NativeSettingsRow("Interface") {
                            NativeGlassSegmentedPicker(
                                selection: $userConfig.uiTheme,
                                values: [Themes.system, .light, .dark],
                                minSegmentWidth: 58
                            ) { mode in
                                textForTheme(mode)
                            }
                        }
                        NativeSettingsSeparator()
                        NativeSettingsRow("Background Color") {
                            ColorPicker("", selection: $userConfig.customBackgroundColor)
                                .labelsHidden()
                        }
                        NativeSettingsSeparator()
                        NativeSettingsRow("Text Color") {
                            ColorPicker("", selection: $userConfig.customTextColor)
                                .labelsHidden()
                        }
                        NativeSettingsSeparator()
                        NativeSettingsRow("Info Color") {
                            ColorPicker("", selection: $userConfig.customInfoColor)
                                .labelsHidden()
                        }
                    }
                }

            NativeSettingsSectionCard("Text") {
                    NativeSettingsRow("Text Orientation") {
                        NativeGlassSegmentedPicker(
                            selection: $userConfig.verticalWriting,
                            values: [true, false],
                            minSegmentWidth: 74
                        ) { isVertical in
                            Text(isVertical ? "Vertical" : "Horizontal")
                        }
                    }
                    NativeSettingsSeparator()
                    NativeSettingsRow("Font") {
                        NativeGlassMenuPicker(
                            selection: fontSelection,
                            values: availableFonts,
                            minWidth: 140
                        ) { font in
                            Text(font)
                        }
                        .disabled(downloadingFont != nil)

                        if !FontManager.shared.isDefaultFont(name: userConfig.selectedFont) {
                            Button {
                                fontToDelete = userConfig.selectedFont
                                showingDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .confirmationDialog("", isPresented: $showingDeleteConfirmation, titleVisibility: .hidden) {
                                Button("Delete", role: .destructive) {
                                    if let fontName = fontToDelete {
                                        try? FontManager.shared.deleteFont(name: fontName)
                                        userConfig.selectedFont = FontManager.defaultFonts[0]
                                        importedFonts = (try? FontManager.shared.storedFonts())?.map { $0.deletingPathExtension().lastPathComponent } ?? []
                                    }
                                }
                            } message: {
                                if let fontName = fontToDelete {
                                    Text("Delete \"\(fontName)\"?")
                                }
                            }
                        }

                        if downloadingFont != nil {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button {
                            isImportingFont = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(NativeSettingsActionButtonStyle())
                        .help(Text("Import Font"))
                        .accessibilityLabel(Text("Import Font"))
                        .fileImporter(
                            isPresented: $isImportingFont,
                            allowedContentTypes: [.font],
                            onCompletion: { result in
                                if case .success(let url) = result {
                                    FontManager.shared.importFont(from: url)
                                    importedFonts = (try? FontManager.shared.storedFonts())?.map { $0.deletingPathExtension().lastPathComponent } ?? []
                                }
                            }
                        )
                    }
                    NativeSettingsSeparator()
                    NativeSettingsRow("Font Size") {
                        Text("\(userConfig.fontSize)")
                            .fontWeight(.semibold)
                        Stepper("", value: $userConfig.fontSize, in: 16...40)
                            .labelsHidden()
                    }
                    NativeSettingsSeparator()
                    NativeSettingsRow("Furigana") {
                        NativeGlassSegmentedPicker(
                            selection: $userConfig.readerFuriganaMode,
                            values: FuriganaMode.allCases,
                            minSegmentWidth: 64
                        ) { mode in
                            switch mode {
                            case .off: Text("Show")
                            case .dimmed: Text("Dimmed")
                            case .toggle: Text("Tap to Reveal")
                            case .hidden: Text("Hidden")
                            }
                        }
                    }
                }

            NativeSettingsSectionCard("Layout") {
                    NativeSettingsRow("Mode") {
                        NativeGlassSegmentedPicker(
                            selection: $userConfig.continuousMode,
                            values: [false, true],
                            minSegmentWidth: 78
                        ) { isContinuous in
                            Text(isContinuous ? "Continuous" : "Paginated")
                        }
                    }
                    if !userConfig.continuousMode {
                        NativeSettingsSeparator()
                        NativeSettingsToggle("Paragraph Mode", isOn: $userConfig.paragraphMode)

                        if userConfig.paragraphMode {
                            NativeSettingsSeparator()
                            NativeSettingsToggle("Text Animation", isOn: $userConfig.textAnimation)

                            if userConfig.textAnimation {
                                NativeSettingsSeparator()
                                NativeSettingsSliderRow(
                                    title: "Text Speed",
                                    value: String(localized: "\(userConfig.textSpeed)/s")
                                ) {
                                    Slider(value: .init(
                                        get: { Double(userConfig.textSpeed) },
                                        set: { userConfig.textSpeed = Int($0) }
                                    ), in: 25...100, step: 5)
                                }
                            }
                        }
                    }
                    // Paragraph mode pages show one paragraph at a time, so spreads only apply without it.
                    if !userConfig.continuousMode && !userConfig.verticalWriting && !userConfig.paragraphMode {
                        NativeSettingsSeparator()
                        NativeSettingsToggle("Two-Column Horizontal Pages", isOn: $userConfig.readerTwoColumnHorizontalPages)
                    }
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Mouse Wheel Page Turn", isOn: $userConfig.readerWheelPageTurnEnabled)

                    if userConfig.continuousMode {
                        NativeSettingsSeparator()
                        NativeSettingsSliderRow(
                            title: "Chapter Swipe Distance",
                            value: "\(userConfig.chapterSwipeDistance)"
                        ) {
                            Slider(value: .init(
                                get: { Double(userConfig.chapterSwipeDistance) },
                                set: { userConfig.chapterSwipeDistance = Int($0) }
                            ), in: 10...60, step: 5)
                        }
                    }

                    NativeSettingsSeparator()
                    NativeSettingsRow("Horizontal Padding") {
                        Text("\(userConfig.horizontalPadding)%")
                            .fontWeight(.semibold)
                        Stepper("", value: $userConfig.horizontalPadding, in: 0...80, step: 1)
                            .labelsHidden()
                    }
                    NativeSettingsSeparator()
                    NativeSettingsRow("Vertical Padding") {
                        Text("\(userConfig.verticalPadding)%")
                            .fontWeight(.semibold)
                        Stepper("", value: $userConfig.verticalPadding, in: 0...50, step: 1)
                            .labelsHidden()
                    }
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Avoid Page Break", isOn: $userConfig.avoidPageBreak)
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Justify Text", isOn: $userConfig.justifyText)
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Blur Images", isOn: $userConfig.blurImages)
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Advanced", isOn: $userConfig.layoutAdvanced)

                    if userConfig.layoutAdvanced {
                        NativeSettingsSeparator()
                        NativeSettingsSliderRow(
                            title: "Line Height",
                            value: String(format: "%.2f", userConfig.lineHeight)
                        ) {
                            Slider(value: $userConfig.lineHeight, in: 1.0...2.5, step: 0.05)
                        }
                        NativeSettingsSeparator()
                        NativeSettingsSliderRow(
                            title: "Character Spacing",
                            value: "\(Int(userConfig.characterSpacing))%"
                        ) {
                            Slider(value: $userConfig.characterSpacing, in: -10...10, step: 1)
                        }
                        NativeSettingsSeparator()
                        NativeSettingsSliderRow(
                            title: "Paragraph Spacing",
                            value: "\(String(format: "%.1f", userConfig.paragraphSpacing))em"
                        ) {
                            Slider(value: $userConfig.paragraphSpacing, in: 0...3, step: 0.1)
                        }
                    }
                }

            NativeSettingsSectionCard("Display") {
                    NativeSettingsToggle("Show Title", isOn: $userConfig.readerShowTitle)
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Show Progress", isOn: $userConfig.readerShowProgress)
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Show Chapter Progress", isOn: $userConfig.readerShowChapterProgress)

                    if userConfig.readerShowProgress || userConfig.readerShowChapterProgress {
                        NativeSettingsSeparator()
                        NativeSettingsRow {
                            if userConfig.readerProgressCount == .pages {
                                NativeSettingsSubtitledLabel(
                                    "Count",
                                    subtitle: "Pages are counted for the current layout and window size, and are unavailable in continuous mode."
                                )
                            } else {
                                Text("Count")
                            }
                        } accessory: {
                            NativeGlassSegmentedPicker(
                                selection: $userConfig.readerProgressCount,
                                values: ReaderProgressCount.allCases,
                                minSegmentWidth: 64
                            ) { count in
                                switch count {
                                case .off: Text("Off")
                                case .characters: Text("Characters")
                                case .pages: Text("Pages")
                                }
                            }
                        }
                        NativeSettingsSeparator()
                        NativeSettingsToggle("Show Percentage", isOn: $userConfig.readerShowPercentage)
                        NativeSettingsSeparator()
                        NativeSettingsRow("Progress Position") {
                            NativeGlassSegmentedPicker(
                                selection: $userConfig.readerShowProgressTop,
                                values: [true, false],
                                minSegmentWidth: 54
                            ) { isTop in
                                Text(isTop ? "Top" : "Bottom")
                            }
                        }
                    }

                    if userConfig.enableStatistics {
                        NativeSettingsSeparator()
                        NativeSettingsToggle("Show Statistics Toggle", isOn: $userConfig.readerShowStatisticsToggle)
                        NativeSettingsSeparator()
                        NativeSettingsToggle("Show Reading Speed", isOn: $userConfig.readerShowReadingSpeed)
                        NativeSettingsSeparator()
                        NativeSettingsToggle("Show Reading Time", isOn: $userConfig.readerShowReadingTime)
                    }

                    if userConfig.enableSasayaki {
                        NativeSettingsSeparator()
                        NativeSettingsToggle("Show Sasayaki Toggle", isOn: $userConfig.readerShowSasayakiToggle)
                    }
                }

            NativeSettingsSectionCard("Popup") {
                    NativeSettingsSliderRow(title: "Width", value: "\(userConfig.popupWidth)") {
                        Slider(value: .init(
                            get: { Double(userConfig.popupWidth) },
                            set: { userConfig.popupWidth = Int($0) }
                        ), in: 100...1400, step: 10)
                    }
                    NativeSettingsSeparator()
                    NativeSettingsSliderRow(title: "Height", value: "\(userConfig.popupHeight)") {
                        Slider(value: .init(
                            get: { Double(userConfig.popupHeight) },
                            set: { userConfig.popupHeight = Int($0) }
                        ), in: 100...800, step: 10)
                    }
                    NativeSettingsSeparator()
                    NativeSettingsSliderRow(title: "Scale", value: String(format: "%.2f", userConfig.popupScale)) {
                        Slider(value: Bindable(userConfig).popupScale, in: 0.8...1.5, step: 0.05)
                    }
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Show Action Bar", isOn: Bindable(userConfig).popupActionBar)
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Disable Transparency", isOn: Bindable(userConfig).popupDisableTransparency)
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Full-width", isOn: Bindable(userConfig).popupFullWidth)
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Swipe to Dismiss", isOn: Bindable(userConfig).popupSwipeToDismiss)

                    if userConfig.popupSwipeToDismiss {
                        NativeSettingsSeparator()
                        NativeSettingsSliderRow(title: "Swipe Threshold", value: "\(userConfig.popupSwipeThreshold)") {
                            Slider(value: .init(
                                get: { Double(userConfig.popupSwipeThreshold) },
                                set: { userConfig.popupSwipeThreshold = Int($0) }
                            ), in: 20...80, step: 5)
                        }
                    }
                }
            }
    }


    private func textForTheme(_ theme: Themes) -> Text {
        switch theme {
        case .system:
            Text("System")
        case .light:
            Text("Light")
        case .dark:
            Text("Dark")
        case .sepia:
            Text("Sepia")
        case .custom:
            Text("Custom")
        }
    }

    private var availableFonts: [String] {
        Self.uniqueFonts(
            FontManager.defaultFonts
            + FontManager.downloadableFonts
            + importedFonts
        )
    }

    private static func uniqueFonts(_ fonts: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for font in fonts where !seen.contains(font) {
            seen.insert(font)
            result.append(font)
        }
        return result
    }
}
