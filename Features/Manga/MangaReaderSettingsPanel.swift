import SwiftUI

/// Fushi's in-reader settings sheet as a native inspector: four tabs whose
/// changes apply either to this manga (sparse overrides) or to every manga.
struct MangaReaderSettingsPanel: View {
    @Bindable var viewModel: MangaReaderViewModel
    @State private var tab: Tab = .reading
    @State private var showsResetConfirmation = false

    enum Tab: String, CaseIterable, Identifiable {
        case reading
        case general
        case filters
        case ocr

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .reading: "Reading"
            case .general: "General"
            case .filters: "Filters"
            case .ocr: "OCR"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings Section", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.titleKey).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Form {
                switch tab {
                case .reading: readingSection
                case .general: generalSection
                case .filters: filterSection
                case .ocr: MangaReaderOCRSettingsSection(viewModel: viewModel, panel: self)
                }
            }
            .formStyle(.grouped)

            footer
        }
        .confirmationDialog(
            "Restore Global Defaults?",
            isPresented: $showsResetConfirmation
        ) {
            Button("Restore Global Defaults", role: .destructive) {
                viewModel.resetAllOverrides()
            }
        } message: {
            Text("Every setting customized for this manga will follow the global value again.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Apply Changes To", selection: $viewModel.settingsScope) {
                ForEach(MangaReaderSettingsScope.allCases) { scope in
                    Text(LocalizedStringKey(scope.titleKey)).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            Button("Restore Global Defaults") {
                showsResetConfirmation = true
            }
            .disabled(viewModel.overriddenSettingKeys().isEmpty)
        }
        .padding(14)
    }

    // MARK: Reading

    @ViewBuilder
    private var readingSection: some View {
        Section("Layout") {
            row("mode") {
                Picker("Reading Mode", selection: binding(\.mode)) {
                    ForEach(MangaReaderMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                    }
                }
            }
            row("autoDetectsMode") {
                Toggle("Detect Long Strips Automatically", isOn: binding(\.autoDetectsMode))
            }
            row("direction") {
                Picker("Reading Direction", selection: binding(\.direction)) {
                    ForEach(MangaReadingDirection.allCases) { direction in
                        Text(LocalizedStringKey(direction.titleKey)).tag(direction)
                    }
                }
            }
            if viewModel.settings.mode == .paged {
                row("spreadMode") {
                    Picker("Page Layout", selection: binding(\.spreadMode)) {
                        ForEach(MangaSpreadMode.allCases) { spread in
                            Text(LocalizedStringKey(spread.titleKey)).tag(spread)
                        }
                    }
                }
                row("showsCoverAlone") {
                    Toggle("Show Cover Alone", isOn: binding(\.showsCoverAlone))
                }
                row("showsWidePagesAlone") {
                    Toggle("Show Wide Pages Alone", isOn: binding(\.showsWidePagesAlone))
                }
            }
            if viewModel.settings.mode == .continuous {
                row("showsPageGaps") {
                    Toggle("Page Gaps", isOn: binding(\.showsPageGaps))
                }
                row("sidePaddingPercent") {
                    slider(
                        "Side Padding",
                        value: \.sidePaddingPercent,
                        range: 0...24,
                        step: 1,
                        format: { "\($0)%" }
                    )
                }
                row("hidesInterfaceOnScroll") {
                    Toggle("Hide Interface While Scrolling", isOn: binding(\.hidesInterfaceOnScroll))
                }
            }
        }

        Section("Zoom") {
            if viewModel.settings.mode != .continuous {
                row("scaleType") {
                    Picker("Page Scaling", selection: binding(\.scaleType)) {
                        ForEach(MangaPageScaleType.allCases) { scale in
                            Text(LocalizedStringKey(scale.titleKey)).tag(scale)
                        }
                    }
                }
            }
            row("zoomPercentage") {
                slider(
                    "Default Zoom",
                    value: \.zoomPercentage,
                    range: viewModel.settings.minimumEffectiveZoomPercentage...MangaReaderSettings.maximumZoomPercentage,
                    step: 10,
                    format: { "\($0)%" }
                )
            }
            row("disablesZoomOut") {
                Toggle("Disable Zoom Out", isOn: binding(\.disablesZoomOut))
            }
            row("zoomSensitivity") {
                slider(
                    "Zoom Sensitivity",
                    value: \.zoomSensitivity,
                    range: 25...400,
                    step: 25,
                    format: { "\($0)%" }
                )
            }
            row("doubleClickZoom") {
                Toggle("Double-Click to Zoom", isOn: binding(\.doubleClickZoom))
            }
            if viewModel.settings.doubleClickZoom {
                row("animatesDoubleClickZoom") {
                    Toggle("Animate Double-Click Zoom", isOn: binding(\.animatesDoubleClickZoom))
                }
            }
        }

        Section("Page Turning") {
            row("pageAnimation") {
                Picker("Page Animation", selection: binding(\.pageAnimation)) {
                    ForEach(MangaPageAnimation.allCases) { animation in
                        Text(LocalizedStringKey(animation.titleKey)).tag(animation)
                    }
                }
            }
            row("flashesOnPageChange") {
                Toggle("Flash on Page Change", isOn: binding(\.flashesOnPageChange))
            }
            row("autoScroll") {
                Toggle("Auto-Scroll", isOn: binding(\.autoScroll))
            }
            if viewModel.settings.autoScroll {
                row("autoScrollSpeed") {
                    slider(
                        "Auto-Scroll Speed",
                        value: \.autoScrollSpeed,
                        range: 5...200,
                        step: 5,
                        format: { "\($0)" }
                    )
                }
            }
        }
    }

    // MARK: General

    @ViewBuilder
    private var generalSection: some View {
        Section("Click Zones") {
            row("tapZoneLayout") {
                Picker("Layout", selection: binding(\.tapZoneLayout)) {
                    ForEach(MangaTapZoneLayout.allCases) { layout in
                        Text(LocalizedStringKey(layout.titleKey)).tag(layout)
                    }
                }
            }
            if viewModel.settings.tapZoneLayout != .disabled {
                row("invertsTapZonesHorizontally") {
                    Toggle("Invert Horizontally", isOn: binding(\.invertsTapZonesHorizontally))
                }
                row("invertsTapZonesVertically") {
                    Toggle("Invert Vertically", isOn: binding(\.invertsTapZonesVertically))
                }
                row("showsTapZonesOnOpen") {
                    Toggle("Show Click Zones When Opening", isOn: binding(\.showsTapZonesOnOpen))
                }
            }
        }

        Section("Display") {
            row("background") {
                Picker("Background", selection: binding(\.background)) {
                    ForEach(MangaReaderBackground.allCases) { background in
                        Text(LocalizedStringKey(background.titleKey)).tag(background)
                    }
                }
            }
            row("usesAutomaticBackground") {
                Toggle("Match Page Background", isOn: binding(\.usesAutomaticBackground))
            }
            row("showsPageNumber") {
                Toggle("Show Page Number When Interface Is Hidden", isOn: binding(\.showsPageNumber))
            }
            row("showsReadingModeHint") {
                Toggle("Show Reading Mode When Opening", isOn: binding(\.showsReadingModeHint))
            }
            row("keepsScreenOn") {
                Toggle("Keep Display Awake", isOn: binding(\.keepsScreenOn))
            }
        }

        Section("Page Processing") {
            row("cropsBorders") {
                Toggle("Crop Borders", isOn: binding(\.cropsBorders))
            }
            row("splitsWidePages") {
                Toggle("Split Wide Pages", isOn: binding(\.splitsWidePages))
            }
            row("rotatesWidePages") {
                Toggle("Rotate Wide Pages to Fit", isOn: binding(\.rotatesWidePages))
            }
        }

        MangaPanelNavigationSettingsSection(viewModel: viewModel, panel: self)
    }

    // MARK: Filters

    @ViewBuilder
    private var filterSection: some View {
        Section("Color") {
            row("invertsColors") {
                Toggle("Invert Colors", isOn: binding(\.invertsColors))
            }
            row("grayscale") {
                Toggle("Grayscale", isOn: binding(\.grayscale))
            }
            row("einkMode") {
                Toggle("E-Ink Mode", isOn: binding(\.einkMode))
            }
            row("brightness") {
                slider("Brightness", value: \.brightness, range: -100...100, step: 5, format: { "\($0)" })
            }
            row("contrast") {
                slider("Contrast", value: \.contrast, range: 0...200, step: 5, format: { "\($0)%" })
            }
            row("saturation") {
                slider("Saturation", value: \.saturation, range: 0...200, step: 5, format: { "\($0)%" })
            }
        }

        Section("Custom Color Filter") {
            row("usesCustomColorFilter") {
                Toggle("Custom Color Filter", isOn: binding(\.usesCustomColorFilter))
            }
            if viewModel.settings.usesCustomColorFilter {
                row("customColorFilterHex") {
                    ColorPicker(
                        "Filter Color",
                        selection: colorBinding,
                        supportsOpacity: false
                    )
                }
                row("customColorFilterOpacity") {
                    slider(
                        "Filter Opacity",
                        value: \.customColorFilterOpacity,
                        range: 0...100,
                        step: 5,
                        format: { "\($0)%" }
                    )
                }
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    nsColor: MangaReaderSettings.color(
                        fromHex: viewModel.settings.customColorFilterHex
                    ) ?? .white
                )
            },
            set: { color in
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let hex = String(
                    format: "#%02X%02X%02X",
                    Int((srgb.redComponent * 255).rounded()),
                    Int((srgb.greenComponent * 255).rounded()),
                    Int((srgb.blueComponent * 255).rounded())
                )
                var next = viewModel.settings
                next.customColorFilterHex = hex
                viewModel.apply(next)
            }
        )
    }

    // MARK: Helpers

    func binding<Value>(
        _ keyPath: WritableKeyPath<MangaReaderSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] },
            set: { value in
                var next = viewModel.settings
                next[keyPath: keyPath] = value
                viewModel.apply(next)
            }
        )
    }

    /// Wraps a control with a "use global default" button when this manga
    /// overrides the value.
    func row<Content: View>(
        _ key: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            content()
            if viewModel.overriddenSettingKeys().contains(key) {
                Button {
                    viewModel.resetOverride(key)
                } label: {
                    Label("Use Global Default", systemImage: "arrow.uturn.backward.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .help("Customized for this manga. Click to use the global default.")
            }
        }
    }

    func slider(
        _ title: LocalizedStringKey,
        value keyPath: WritableKeyPath<MangaReaderSettings, Int>,
        range: ClosedRange<Int>,
        step: Int,
        format: @escaping (Int) -> String
    ) -> some View {
        MangaSettingSlider(
            title: title,
            value: viewModel.settings[keyPath: keyPath],
            range: range,
            step: step,
            format: format
        ) { value in
            var next = viewModel.settings
            next[keyPath: keyPath] = value
            viewModel.apply(next)
        }
    }
}

/// A slider that edits locally and commits once on release, so dragging does
/// not rewrite stored settings on every tick.
private struct MangaSettingSlider: View {
    let title: LocalizedStringKey
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let format: (Int) -> String
    let onCommit: (Int) -> Void

    @State private var draft: Double = 0
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: format(Int(draft.rounded())))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $draft,
                in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1)),
                step: Double(step)
            ) { editing in
                isEditing = editing
                if !editing {
                    onCommit(Int(draft.rounded()))
                }
            }
            .labelsHidden()
        }
        .onAppear { draft = Double(value) }
        .onChange(of: value) { _, newValue in
            guard !isEditing else { return }
            draft = Double(newValue)
        }
    }
}
