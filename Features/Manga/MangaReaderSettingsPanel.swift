import SwiftUI

/// Fushi's in-reader settings sheet as a native inspector: four tabs whose
/// changes apply either to this manga (sparse overrides) or to every manga.
/// Styled like the video player inspector: a title header, an icon tab strip,
/// and System Settings–style grouped lists with flat fills.
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

        var systemName: String {
            switch self {
            case .reading: "book.pages"
            case .general: "gearshape"
            case .filters: "camera.filters"
            case .ocr: "text.viewfinder"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            MangaSettingsTabBar(selection: $tab)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            MangaSettingsHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case .reading: readingSection
                    case .general: generalSection
                    case .filters: filterSection
                    case .ocr: MangaReaderOCRSettingsSection(viewModel: viewModel, panel: self)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .vertical)

            MangaSettingsHairline()

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

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "book.pages.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Reader Settings")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(viewModel.title)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(viewModel.title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.showsSettingsPanel = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(MangaSettingsIconButtonStyle())
            .help("Close")
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apply Changes To")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                MangaSettingsSegmentedPicker(
                    selection: $viewModel.settingsScope,
                    values: MangaReaderSettingsScope.allCases
                ) { scope in
                    Text(LocalizedStringKey(scope.titleKey))
                }
                .accessibilityLabel(Text("Apply Changes To"))

                Button {
                    showsResetConfirmation = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(MangaSettingsIconButtonStyle(isFilled: true))
                .disabled(viewModel.overriddenSettingKeys().isEmpty)
                .help("Restore Global Defaults")
                .accessibilityLabel(Text("Restore Global Defaults"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    // MARK: Reading

    @ViewBuilder
    private var readingSection: some View {
        section("Layout") {
            pickerRow(
                "mode", "Reading Mode", systemImage: "book.pages",
                selection: binding(\.mode), values: MangaReaderMode.allCases
            ) { LocalizedStringKey($0.titleKey) }
            toggleRow(
                "autoDetectsMode", "Detect Long Strips Automatically",
                systemImage: "wand.and.stars", value: \.autoDetectsMode
            )
            pickerRow(
                "direction", "Reading Direction", systemImage: "arrow.left.arrow.right",
                selection: binding(\.direction), values: MangaReadingDirection.allCases
            ) { LocalizedStringKey($0.titleKey) }
            if viewModel.settings.mode == .paged {
                pickerRow(
                    "spreadMode", "Page Layout", systemImage: "book",
                    selection: binding(\.spreadMode), values: MangaSpreadMode.allCases
                ) { LocalizedStringKey($0.titleKey) }
                toggleRow(
                    "showsCoverAlone", "Show Cover Alone",
                    systemImage: "rectangle.portrait", value: \.showsCoverAlone
                )
                toggleRow(
                    "showsWidePagesAlone", "Show Wide Pages Alone",
                    systemImage: "rectangle", value: \.showsWidePagesAlone
                )
            }
            if viewModel.settings.mode == .continuous {
                toggleRow(
                    "showsPageGaps", "Page Gaps",
                    systemImage: "square.split.1x2", value: \.showsPageGaps
                )
                sliderRow(
                    "sidePaddingPercent", "Side Padding", systemImage: "arrow.left.and.right",
                    value: \.sidePaddingPercent, range: 0...24, step: 1, format: { "\($0)%" }
                )
                toggleRow(
                    "hidesInterfaceOnScroll", "Hide Interface While Scrolling",
                    systemImage: "eye.slash", value: \.hidesInterfaceOnScroll
                )
            }
        }

        section("Zoom") {
            if viewModel.settings.mode != .continuous {
                pickerRow(
                    "scaleType", "Page Scaling", systemImage: "arrow.up.left.and.arrow.down.right",
                    selection: binding(\.scaleType), values: MangaPageScaleType.allCases
                ) { LocalizedStringKey($0.titleKey) }
            }
            sliderRow(
                "zoomPercentage", "Default Zoom", systemImage: "plus.magnifyingglass",
                value: \.zoomPercentage,
                range: viewModel.settings.minimumEffectiveZoomPercentage...MangaReaderSettings.maximumZoomPercentage,
                step: 10, format: { "\($0)%" }
            )
            toggleRow(
                "disablesZoomOut", "Disable Zoom Out",
                systemImage: "minus.magnifyingglass", value: \.disablesZoomOut
            )
            sliderRow(
                "zoomSensitivity", "Zoom Sensitivity", systemImage: "dial.medium",
                value: \.zoomSensitivity, range: 25...400, step: 25, format: { "\($0)%" }
            )
            toggleRow(
                "doubleClickZoom", "Double-Click to Zoom",
                systemImage: "cursorarrow.click.2", value: \.doubleClickZoom
            )
            if viewModel.settings.doubleClickZoom {
                toggleRow(
                    "animatesDoubleClickZoom", "Animate Double-Click Zoom",
                    systemImage: "sparkles", value: \.animatesDoubleClickZoom
                )
            }
        }

        section("Page Turning") {
            pickerRow(
                "pageAnimation", "Page Animation", systemImage: "rectangle.stack",
                selection: binding(\.pageAnimation), values: MangaPageAnimation.allCases
            ) { LocalizedStringKey($0.titleKey) }
            toggleRow(
                "flashesOnPageChange", "Flash on Page Change",
                systemImage: "bolt", value: \.flashesOnPageChange
            )
            toggleRow(
                "autoScroll", "Auto-Scroll",
                systemImage: "arrow.down.circle", value: \.autoScroll
            )
            if viewModel.settings.autoScroll {
                sliderRow(
                    "autoScrollSpeed", "Auto-Scroll Speed", systemImage: "speedometer",
                    value: \.autoScrollSpeed, range: 5...200, step: 5, format: { "\($0)" }
                )
            }
        }
    }

    // MARK: General

    @ViewBuilder
    private var generalSection: some View {
        section("Click Zones") {
            pickerRow(
                "tapZoneLayout", "Layout", systemImage: "square.grid.3x3",
                selection: binding(\.tapZoneLayout), values: MangaTapZoneLayout.allCases
            ) { LocalizedStringKey($0.titleKey) }
            if viewModel.settings.tapZoneLayout != .disabled {
                toggleRow(
                    "invertsTapZonesHorizontally", "Invert Horizontally",
                    systemImage: "arrow.left.and.right", value: \.invertsTapZonesHorizontally
                )
                toggleRow(
                    "invertsTapZonesVertically", "Invert Vertically",
                    systemImage: "arrow.up.and.down", value: \.invertsTapZonesVertically
                )
                toggleRow(
                    "showsTapZonesOnOpen", "Show Click Zones When Opening",
                    systemImage: "hand.point.up.left", value: \.showsTapZonesOnOpen
                )
            }
        }

        section("Display") {
            pickerRow(
                "background", "Background", systemImage: "paintpalette",
                selection: binding(\.background), values: MangaReaderBackground.allCases
            ) { LocalizedStringKey($0.titleKey) }
            toggleRow(
                "usesAutomaticBackground", "Match Page Background",
                systemImage: "eyedropper", value: \.usesAutomaticBackground
            )
            toggleRow(
                "showsPageNumber", "Show Page Number When Interface Is Hidden",
                systemImage: "number", value: \.showsPageNumber
            )
            toggleRow(
                "showsReadingModeHint", "Show Reading Mode When Opening",
                systemImage: "info.circle", value: \.showsReadingModeHint
            )
            toggleRow(
                "keepsScreenOn", "Keep Display Awake",
                systemImage: "sun.max", value: \.keepsScreenOn
            )
        }

        section("Page Processing") {
            toggleRow(
                "cropsBorders", "Crop Borders",
                systemImage: "crop", value: \.cropsBorders
            )
            toggleRow(
                "splitsWidePages", "Split Wide Pages",
                systemImage: "rectangle.split.2x1", value: \.splitsWidePages
            )
            toggleRow(
                "rotatesWidePages", "Rotate Wide Pages to Fit",
                systemImage: "rotate.right", value: \.rotatesWidePages
            )
        }

        MangaPanelNavigationSettingsSection(viewModel: viewModel, panel: self)
    }

    // MARK: Filters

    @ViewBuilder
    private var filterSection: some View {
        section("Color") {
            toggleRow(
                "invertsColors", "Invert Colors",
                systemImage: "circle.righthalf.filled", value: \.invertsColors
            )
            toggleRow(
                "grayscale", "Grayscale",
                systemImage: "circle.dotted", value: \.grayscale
            )
            toggleRow(
                "einkMode", "E-Ink Mode",
                systemImage: "book.closed", value: \.einkMode
            )
            sliderRow(
                "brightness", "Brightness", systemImage: "sun.max",
                value: \.brightness, range: -100...100, step: 5, format: { "\($0)" }
            )
            sliderRow(
                "contrast", "Contrast", systemImage: "circle.lefthalf.filled",
                value: \.contrast, range: 0...200, step: 5, format: { "\($0)%" }
            )
            sliderRow(
                "saturation", "Saturation", systemImage: "drop",
                value: \.saturation, range: 0...200, step: 5, format: { "\($0)%" }
            )
        }

        section("Custom Color Filter") {
            toggleRow(
                "usesCustomColorFilter", "Custom Color Filter",
                systemImage: "camera.filters", value: \.usesCustomColorFilter
            )
            if viewModel.settings.usesCustomColorFilter {
                labeledRow("customColorFilterHex", "Filter Color", systemImage: "eyedropper.halffull") {
                    ColorPicker(
                        "Filter Color",
                        selection: colorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
                sliderRow(
                    "customColorFilterOpacity", "Filter Opacity", systemImage: "circle.bottomhalf.filled",
                    value: \.customColorFilterOpacity, range: 0...100, step: 5, format: { "\($0)%" }
                )
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

    /// A titled group whose rows are separated by inset hairlines.
    func section<Content: View>(
        _ title: LocalizedStringKey,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        MangaSettingsSection(title: title, footer: footer, content: content())
    }

    /// Icon, title, an optional "use global default" button when this manga
    /// overrides the value, then the trailing control.
    func labeledRow<Control: View>(
        _ key: String?,
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            MangaSettingsRowLabel(title: title, systemImage: systemImage)
            Spacer(minLength: 8)
            if let key {
                overrideResetButton(key)
            }
            control()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    func toggleRow(
        _ key: String,
        _ title: LocalizedStringKey,
        systemImage: String,
        value keyPath: WritableKeyPath<MangaReaderSettings, Bool>
    ) -> some View {
        labeledRow(key, title, systemImage: systemImage) {
            Toggle(title, isOn: binding(keyPath))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    func pickerRow<Value: Hashable>(
        _ key: String,
        _ title: LocalizedStringKey,
        systemImage: String,
        selection: Binding<Value>,
        values: [Value],
        valueTitle: @escaping (Value) -> LocalizedStringKey
    ) -> some View {
        labeledRow(key, title, systemImage: systemImage) {
            NativeGlassMenuPicker(selection: selection, values: values, minWidth: 0) { value in
                Text(valueTitle(value))
                    .font(.callout.weight(.medium))
            }
            .fixedSize()
        }
    }

    func sliderRow(
        _ key: String,
        _ title: LocalizedStringKey,
        systemImage: String,
        value keyPath: WritableKeyPath<MangaReaderSettings, Int>,
        range: ClosedRange<Int>,
        step: Int,
        format: @escaping (Int) -> String
    ) -> some View {
        MangaSettingSlider(
            title: title,
            systemImage: systemImage,
            value: viewModel.settings[keyPath: keyPath],
            range: range,
            step: step,
            format: format,
            resetButton: overrideResetButton(key)
        ) { value in
            var next = viewModel.settings
            next[keyPath: keyPath] = value
            viewModel.apply(next)
        }
    }

    @ViewBuilder
    private func overrideResetButton(_ key: String) -> some View {
        if viewModel.overriddenSettingKeys().contains(key) {
            Button {
                viewModel.resetOverride(key)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(MangaSettingsIconButtonStyle())
            .help("Customized for this manga. Click to use the global default.")
            .accessibilityLabel(Text("Use Global Default"))
        }
    }
}

/// A slider that edits locally and commits once on release, so dragging does
/// not rewrite stored settings on every tick.
private struct MangaSettingSlider<ResetButton: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let format: (Int) -> String
    let resetButton: ResetButton
    let onCommit: (Int) -> Void

    @State private var draft: Double = 0
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MangaSettingsRowLabel(title: title, systemImage: systemImage)
                Spacer(minLength: 8)
                resetButton
                Text(verbatim: format(snapped))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Continuous track (no tick marks); the value snaps to `step`.
            Slider(
                value: $draft,
                in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1))
            ) { editing in
                isEditing = editing
                if !editing {
                    draft = Double(snapped)
                    onCommit(snapped)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { draft = Double(value) }
        .onChange(of: value) { _, newValue in
            guard !isEditing else { return }
            draft = Double(newValue)
        }
    }

    private var snapped: Int {
        let offset = ((draft - Double(range.lowerBound)) / Double(step)).rounded() * Double(step)
        return min(max(range.lowerBound + Int(offset), range.lowerBound), range.upperBound)
    }
}

// MARK: - Components

/// Mirrors the video inspector's grouped list: a semibold title, one flat
/// fill per group, and rows separated by inset hairlines.
struct MangaSettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    var footer: LocalizedStringKey?
    let content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)

            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                        if index > 0 {
                            Rectangle()
                                .fill(.separator)
                                .frame(height: 0.5)
                                .padding(.leading, 12)
                                .opacity(0.7)
                        }
                        subview
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sectionFill, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(sectionStroke, lineWidth: 0.5)
            }

            if let footer {
                MangaSettingsFootnote(text: footer)
            }
        }
    }

    private var sectionFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.065) : Color.white.opacity(0.7)
    }

    private var sectionStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
}

struct MangaSettingsFootnote: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

struct MangaSettingsRowLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }
}

private struct MangaSettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 0.5)
            .opacity(0.6)
    }
}

/// Icon-over-title tabs with a sliding selection pill.
private struct MangaSettingsTabBar: View {
    @Binding var selection: MangaReaderSettingsPanel.Tab
    @Namespace private var selectionNamespace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MangaReaderSettingsPanel.Tab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemName)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(height: 17)
                        Text(tab.titleKey)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selectedFill)
                                .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tab.titleKey))
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .background(containerFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var containerFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.9)
    }
}

/// Compact two-option switch with a sliding thumb.
private struct MangaSettingsSegmentedPicker<SelectionValue: Hashable, SegmentLabel: View>: View {
    @Binding var selection: SelectionValue
    let values: [SelectionValue]
    @ViewBuilder var label: (SelectionValue) -> SegmentLabel

    @Namespace private var thumbNamespace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selection = value
                    }
                } label: {
                    label(value)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(selection == value ? .primary : .secondary)
                        .background {
                            if selection == value {
                                Capsule()
                                    .fill(thumbFill)
                                    .matchedGeometryEffect(id: "thumb", in: thumbNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(trackFill, in: Capsule())
    }

    private var trackFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
    }

    private var thumbFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.white
    }
}

/// Small pill buttons for inline actions inside a group.
struct MangaSettingsChipButtonStyle: ButtonStyle {
    var isProminent = false
    var isDestructive = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .foregroundStyle(foreground)
            .background(fill(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }

    private var foreground: Color {
        if isDestructive {
            return .red
        }
        return isProminent ? .accentColor : .primary
    }

    private func fill(isPressed: Bool) -> Color {
        if isDestructive {
            return Color.red.opacity(isPressed ? 0.22 : 0.12)
        }
        if isProminent {
            return Color.accentColor.opacity(isPressed ? 0.26 : 0.16)
        }
        let base = colorScheme == .dark ? 0.08 : 0.06
        return Color.primary.opacity(isPressed ? base + 0.08 : base)
    }
}

struct MangaSettingsIconButtonStyle: ButtonStyle {
    var isFilled = false

    func makeBody(configuration: Configuration) -> some View {
        MangaSettingsIconButtonBody(configuration: configuration, isFilled: isFilled)
    }
}

private struct MangaSettingsIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isFilled: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(Circle().fill(fill))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }

    private var fill: Color {
        let resting = isFilled ? (colorScheme == .dark ? 0.09 : 0.07) : 0
        if configuration.isPressed {
            return Color.primary.opacity(resting + 0.12)
        }
        if isHovered && isEnabled {
            return Color.primary.opacity(resting + 0.07)
        }
        return Color.primary.opacity(resting)
    }
}
