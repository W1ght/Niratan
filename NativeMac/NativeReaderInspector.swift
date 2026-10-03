import AppKit
import SwiftUI

/// Header for Reader side panels: a leading title like a desktop inspector,
/// with an optional subtitle and a compact close control.
struct NativeReaderInspectorHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    var subtitle: String?
    let onClose: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    init(
        title: LocalizedStringKey,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            accessory()
            NativeGlassCircleButton(systemName: "xmark", diameter: 28, fontSize: 11) {
                onClose()
            }
            .help(Text("Close"))
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
}

extension NativeReaderInspectorHeader where Accessory == EmptyView {
    init(title: LocalizedStringKey, subtitle: String? = nil, onClose: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, onClose: onClose) { EmptyView() }
    }
}

/// Small section caption used inside Reader side panels.
struct NativeReaderInspectorSectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// List row for Reader side panels: rounded hover/selection highlight
/// instead of full-width table rows.
struct NativeReaderInspectorRowButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        NativeReaderInspectorRowBody(
            label: configuration.label,
            isSelected: isSelected,
            isPressed: configuration.isPressed
        )
    }
}

private struct NativeReaderInspectorRowBody<Label: View>: View {
    let label: Label
    let isSelected: Bool
    let isPressed: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fill)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var fill: Color {
        if isSelected {
            return Color.accentColor.opacity(isPressed ? 0.26 : 0.18)
        }
        if isPressed {
            return Color.primary.opacity(0.1)
        }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }
}

/// One statistic: a large monospaced value over a caption.
struct NativeReaderStatTile: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }
}

/// Desktop tab strip for Reader side panels: equal-width icon+title tabs
/// with a sliding accent underline over a hairline divider.
struct NativeReaderInspectorTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> LocalizedStringKey
    let systemImage: (Tab) -> String
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 7) {
                        Label(title(tab), systemImage: systemImage(tab))
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        ZStack {
                            Capsule()
                                .fill(Color.clear)
                                .frame(height: 2)
                            if isSelected {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }
}

/// Closes Reader side panels and the gallery with Escape even while the page's
/// web view has focus. Only consumes Escape in this window while `isActive`.
struct NativeReaderEscapeDismissal: ViewModifier {
    let isActive: Bool
    let onEscape: () -> Void
    @State private var state = MonitorState()

    @MainActor
    private final class MonitorState {
        weak var window: NSWindow?
        var monitor: Any?
        var onEscape: () -> Void = {}

        func update(isActive: Bool) {
            if isActive, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self,
                          event.keyCode == 53,
                          event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                          let window = self.window,
                          event.window === window else {
                        return event
                    }
                    self.onEscape()
                    return nil
                }
            } else if !isActive, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .background {
                NativeWindowActivityReader { window, _ in
                    state.window = window
                }
            }
            .onChange(of: isActive, initial: true) { _, active in
                state.onEscape = onEscape
                state.update(isActive: active)
            }
            .onDisappear {
                state.update(isActive: false)
            }
    }
}
