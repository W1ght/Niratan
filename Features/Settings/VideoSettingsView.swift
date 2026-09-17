import AppKit
import SwiftUI

struct VideoSettingsView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var jimakuAPIKeyDraft = ""
    @State private var isJimakuAPIKeyStored = false
    @State private var isJimakuCredentialOperationInProgress = false
    @State private var jimakuCredentialStatusMessage: String?
    @State private var isShowingJimakuRemovalConfirmation = false

    var body: some View {
        @Bindable var userConfig = userConfig

        NativeSettingsForm {
            NativeSettingsSectionCard("Playback") {
                NativeSettingsToggle(
                    "Auto-Play Next Episode",
                    isOn: $userConfig.videoAutoPlayNext
                )
                NativeSettingsSeparator()
                NativeSettingsToggle(
                    "Remember Playback State",
                    isOn: $userConfig.videoRememberPlaybackPosition
                )
                NativeSettingsSeparator()
                NativeSettingsToggle(
                    "Auto-pause on Lookup",
                    isOn: $userConfig.videoAutoPauseOnLookup
                )
                NativeSettingsSeparator()
                NativeSettingsToggle(
                    "Fast-forward Subtitle Gaps",
                    isOn: $userConfig.videoSubtitleGapFastForwardEnabled
                )
                NativeSettingsRow("Fast-forward Speed") {
                    Text(String(format: "%.1fx", userConfig.videoSubtitleGapFastForwardSpeed))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper(
                        "",
                        value: $userConfig.videoSubtitleGapFastForwardSpeed,
                        in: 1.1...5.0,
                        step: 0.1
                    )
                    .labelsHidden()
                }
                Text("Temporarily speeds through gaps between subtitle lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeSettingsSeparator()
                NativeSettingsRow("Control Bar Layout") {
                    NativeGlassSegmentedPicker(
                        selection: $userConfig.videoControlBarLayout,
                        values: VideoControlBarLayout.allCases,
                        minSegmentWidth: 104
                    ) { layout in
                        switch layout {
                        case .floating:
                            Text("Floating")
                        case .compactBottom:
                            Text("Compact Bottom")
                        }
                    }
                }
                NativeSettingsSeparator()
                NativeSettingsRow("Default Seek Interval") {
                    Text("\(Int(userConfig.videoSeekInterval)) s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper(
                        "",
                        value: $userConfig.videoSeekInterval,
                        in: 1...60,
                        step: 1
                    )
                    .labelsHidden()
                }
            } footer: {
                Text("Restores playback position, subtitles, speed, timing, and audio track for each video.")
            }

            videoEnhancementSection

            NativeSettingsSectionCard("Mining") {
                NativeSettingsRow("Mining History Storage Limit") {
                    Text("\(userConfig.videoMiningHistoryLimit)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper(
                        "",
                        value: $userConfig.videoMiningHistoryLimit,
                        in: 0...1000,
                        step: 1
                    )
                    .labelsHidden()
                }
            } footer: {
                Text("Set to 0 to disable and clear Mining History.")
            }

            jimakuSection
            NativeSettingsSectionCard("OpenSubtitles") {
                SubtitleSourceCredentialView(provider: .openSubtitles)
            }

            subtitleAppearanceSection

            NativeSettingsSectionCard {
                Text("Subtitle Mask")
            } content: {
                NativeSettingsToggle(
                    "Mask subtitles until hover",
                    isOn: $userConfig.videoSubtitleMaskEnabled
                )
                NativeSettingsSeparator()
                NativeSettingsRow("Mask Mode") {
                    NativeGlassSegmentedPicker(
                        selection: $userConfig.videoSubtitleMaskMode,
                        values: VideoSubtitleMaskMode.allCases,
                        minSegmentWidth: 94
                    ) { mode in
                        Text(LocalizedStringKey(mode.rawValue))
                            .font(.caption.weight(.semibold))
                    }
                }
                .disabled(!userConfig.videoSubtitleMaskEnabled)
                NativeSettingsSeparator()
                if userConfig.videoSubtitleMaskMode == .blur {
                    NativeSettingsSliderRow(
                        title: "Blur Radius",
                        value: "\(Int(userConfig.videoSubtitleMaskBlurRadius)) px"
                    ) {
                        Slider(
                            value: $userConfig.videoSubtitleMaskBlurRadius,
                            in: 0...20,
                            step: 1
                        )
                    }
                } else {
                    NativeSettingsSliderRow(
                        title: "Hidden Opacity",
                        value: "\(Int(userConfig.videoSubtitleMaskHiddenOpacity * 100))%"
                    ) {
                        Slider(
                            value: $userConfig.videoSubtitleMaskHiddenOpacity,
                            in: 0...1,
                            step: 0.05
                        )
                    }
                }
            } footer: {
                Text("Masked subtitles are shown normally while the pointer is over the subtitle row.")
            }
        }
        .navigationTitle("Video")
        .task {
            await refreshJimakuCredentialState()
        }
        .confirmationDialog(
            "Remove Jimaku API Key?",
            isPresented: $isShowingJimakuRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove API Key", role: .destructive) {
                removeJimakuAPIKey()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved Jimaku API key will be removed from this Mac.")
        }
    }

    private var jimakuSection: some View {
        NativeSettingsSectionCard("Jimaku") {
            NativeSettingsRow("API Key") {
                SecureField("Enter a new API key", text: $jimakuAPIKeyDraft)
                    .nativeSettingsTextField()
                    .frame(maxWidth: 320)
                    .onSubmit(saveJimakuAPIKey)

                Button("Save", action: saveJimakuAPIKey)
                    .disabled(
                        jimakuAPIKeyDraft
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                            || isJimakuCredentialOperationInProgress
                    )

                Button("Remove") {
                    isShowingJimakuRemovalConfirmation = true
                }
                .disabled(
                    !isJimakuAPIKeyStored
                        || isJimakuCredentialOperationInProgress
                )
            }
            NativeSettingsSeparator()
            NativeSettingsRow {
                Link(
                    "Create API Key",
                    destination: URL(string: "https://jimaku.cc/account")!
                )
            } accessory: {
                if isJimakuCredentialOperationInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(
                    jimakuCredentialStatusMessage
                        ?? (isJimakuAPIKeyStored ? String(localized: "Saved in Keychain") : String(localized: "Not configured"))
                )
                .foregroundStyle(.secondary)
            }
        } footer: {
            Text("The API key is stored in macOS Keychain and is sent only to Jimaku API requests.")
            Text("Jimaku search and downloads require a Jimaku account and are subject to Jimaku's rate limits.")
        }
    }

    private func refreshJimakuCredentialState() async {
        do {
            isJimakuAPIKeyStored = try await JimakuCredentialStore.shared.hasAPIKey()
            jimakuCredentialStatusMessage = nil
        } catch {
            isJimakuAPIKeyStored = false
            jimakuCredentialStatusMessage = String(
                localized: "Unable to read the Jimaku API key from Keychain."
            )
        }
    }

    private func saveJimakuAPIKey() {
        let apiKey = jimakuAPIKeyDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return }
        isJimakuCredentialOperationInProgress = true
        jimakuCredentialStatusMessage = nil
        Task { @MainActor in
            defer { isJimakuCredentialOperationInProgress = false }
            do {
                try await JimakuCredentialStore.shared.save(apiKey: apiKey)
                jimakuAPIKeyDraft = ""
                isJimakuAPIKeyStored = true
                jimakuCredentialStatusMessage = String(localized: "Jimaku API key saved.")
                NotificationCenter.default.post(name: .jimakuCredentialDidChange, object: nil)
            } catch {
                jimakuCredentialStatusMessage = String(localized: "Unable to save the Jimaku API key.")
            }
        }
    }

    private func removeJimakuAPIKey() {
        isJimakuCredentialOperationInProgress = true
        jimakuCredentialStatusMessage = nil
        Task { @MainActor in
            defer { isJimakuCredentialOperationInProgress = false }
            do {
                try await JimakuCredentialStore.shared.removeAPIKey()
                jimakuAPIKeyDraft = ""
                isJimakuAPIKeyStored = false
                jimakuCredentialStatusMessage = String(localized: "Jimaku API key removed.")
                NotificationCenter.default.post(name: .jimakuCredentialDidChange, object: nil)
            } catch {
                jimakuCredentialStatusMessage = String(localized: "Unable to remove the Jimaku API key.")
            }
        }
    }

    private var videoEnhancementSection: some View {
        @Bindable var userConfig = userConfig

        return NativeSettingsSectionCard {
            Text("Video Enhancement")
        } content: {
            NativeSettingsToggle(
                "Hardware Decoding",
                isOn: $userConfig.videoHardwareDecodingEnabled
            )
            NativeSettingsSeparator()
            NativeSettingsToggle(
                "Deinterlace",
                isOn: $userConfig.videoDeinterlacingEnabled
            )
            NativeSettingsSeparator()
            NativeSettingsToggle(
                "HDR",
                isOn: $userConfig.videoHDREnhancementEnabled
            )
            NativeSettingsSeparator()
            NativeSettingsRow("Anime4K Upscaling") {
                VideoAnime4KPresetControl(minimumPickerWidth: 210)
                    .frame(maxWidth: 430, alignment: .trailing)
            }
            NativeSettingsSeparator()
            videoEqualizerSlider(.brightness, value: $userConfig.videoBrightness)
            NativeSettingsSeparator()
            videoEqualizerSlider(.contrast, value: $userConfig.videoContrast)
            NativeSettingsSeparator()
            videoEqualizerSlider(.saturation, value: $userConfig.videoSaturation)
            NativeSettingsSeparator()
            videoEqualizerSlider(.gamma, value: $userConfig.videoGamma)
            NativeSettingsSeparator()
            videoEqualizerSlider(.hue, value: $userConfig.videoHue)
        } footer: {
            Text("Hardware decoding uses mpv's automatic safe decoder path. HDR changes mpv tone-mapping peak handling.")
        }
    }

    private var subtitleAppearanceSection: some View {
        @Bindable var userConfig = userConfig

        return NativeSettingsSectionCard {
            Text("Subtitle Appearance")
        } content: {
            NativeSettingsRow("Subtitle Font") {
                NativeGlassMenuPicker(
                    selection: $userConfig.videoSubtitleFontFamily,
                    values: [""] + Self.subtitleFontFamilies,
                    minWidth: 170
                ) { family in
                    if family.isEmpty {
                        Text("System Default")
                    } else {
                        Text(verbatim: family)
                    }
                }
                .frame(maxWidth: 260)
            }
            NativeSettingsSeparator()
            NativeSettingsSliderRow(
                title: "Subtitle Size",
                value: "\(Int(userConfig.videoSubtitleFontSize)) px"
            ) {
                Slider(
                    value: $userConfig.videoSubtitleFontSize,
                    in: 12...72,
                    step: 1
                )
            }
            NativeSettingsSeparator()
            NativeSettingsRow("Subtitle Weight") {
                Text("\(userConfig.videoSubtitleFontWeight)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Stepper(
                    "",
                    value: $userConfig.videoSubtitleFontWeight,
                    in: 100...900,
                    step: 100
                )
                .labelsHidden()
            }
            NativeSettingsSeparator()
            NativeSettingsRow("Edge Style") {
                NativeGlassMenuPicker(
                    selection: $userConfig.videoSubtitleEdgeStyle,
                    values: VideoSubtitleEdgeStyle.allCases,
                    minWidth: 170
                ) { style in
                    Text(style.localizedTitle)
                }
                .frame(maxWidth: 260)
            }
            NativeSettingsSeparator()
            NativeSettingsSliderRow(
                title: "Edge Strength",
                value: "\(Int((userConfig.videoSubtitleEdgeStrength * 100).rounded()))%"
            ) {
                Slider(
                    value: $userConfig.videoSubtitleEdgeStrength,
                    in: 0...1,
                    step: 0.05
                )
                .disabled(userConfig.videoSubtitleEdgeStyle == .off)
            }
            NativeSettingsSeparator()
            NativeSettingsSliderRow(
                title: "Background Opacity",
                value: "\(Int(userConfig.videoSubtitleBackgroundOpacity * 100))%"
            ) {
                Slider(
                    value: $userConfig.videoSubtitleBackgroundOpacity,
                    in: 0...1,
                    step: 0.05
                )
                .disabled(userConfig.videoSubtitleBackgroundDisabled)
            }
            NativeSettingsSeparator()
            NativeSettingsToggle(
                "No Background",
                isOn: $userConfig.videoSubtitleBackgroundDisabled
            )
            NativeSettingsSeparator()
            NativeSettingsRow("Vertical Position") {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $userConfig.videoSubtitleVerticalPosition,
                        in: VideoSubtitlePositionPolicy.range
                    )
                    .labelsHidden()
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 280)
            }
            NativeSettingsSeparator()
            NativeSettingsRow("Subtitle Color") {
                ColorPicker("Subtitle Color", selection: $userConfig.videoSubtitleColor)
                    .labelsHidden()
            }
            NativeSettingsSeparator()
            NativeSettingsRow("Lookup Highlight Color") {
                ColorPicker("Lookup Highlight Color", selection: $userConfig.videoSubtitleLookupHighlightColor)
                    .labelsHidden()
            }
            NativeSettingsSeparator()
            NativeSettingsRow("Lookup Highlight Text Color") {
                ColorPicker("Lookup Highlight Text Color", selection: $userConfig.videoSubtitleLookupHighlightTextColor)
                    .labelsHidden()
            }
            NativeSettingsSeparator()
            NativeSettingsRow {
                Button("Restore Defaults", action: userConfig.resetVideoSubtitleAppearance)
            } accessory: {
                EmptyView()
            }
        } footer: {
            Text("Customize subtitle typography, text color, and lookup highlight colors.")
            Text("Let subtitle background stay transparent.")
        }
    }

    private static var subtitleFontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func videoEqualizerSlider(
        _ adjustment: VideoEqualizerAdjustment,
        value: Binding<Double>
    ) -> some View {
        NativeSettingsSliderRow(
            title: LocalizedStringKey(adjustment.title),
            value: "\(Int(value.wrappedValue.rounded()))"
        ) {
            HStack(spacing: 10) {
                Slider(
                    value: value,
                    in: VideoEqualizerAdjustment.minimum...VideoEqualizerAdjustment.maximum,
                    step: 1
                )
                Button {
                    value.wrappedValue = VideoEqualizerAdjustment.neutral
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset")
            }
        }
    }
}
