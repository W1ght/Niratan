import SwiftUI

/// One row in the study sidebar. Rows stay flat — a tint on hover, an accent
/// tint plus a leading bar when selected — so playback-driven re-renders never
/// touch glass. Accessories fade in on hover unless the row asks to keep them.
struct VideoStudyListRow<Content: View, Accessories: View>: View {
    let isSelected: Bool
    let showsAccessoriesAlways: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessories: () -> Accessories

    @State private var isHovered = false

    init(
        isSelected: Bool = false,
        showsAccessoriesAlways: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessories: @escaping () -> Accessories
    ) {
        self.isSelected = isSelected
        self.showsAccessoriesAlways = showsAccessoriesAlways
        self.action = action
        self.content = content
        self.accessories = accessories
    }

    var body: some View {
        let showsAccessories = showsAccessoriesAlways || isHovered

        HStack(alignment: .center, spacing: 8) {
            Button(action: action) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            accessories()
                .opacity(showsAccessories ? 1 : 0)
                .allowsHitTesting(showsAccessories)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .modifier(VideoStudyListRowSurface(isSelected: isSelected, isHovered: isHovered))
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

extension VideoStudyListRow where Accessories == EmptyView {
    init(
        isSelected: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            isSelected: isSelected,
            action: action,
            content: content,
            accessories: { EmptyView() }
        )
    }
}

private struct VideoStudyListRowSurface: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    @Environment(\.colorScheme) private var colorScheme

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(backgroundTint)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 7)
                        .padding(.leading, 3)
                }
            }
            .contentShape(shape)
    }

    private var backgroundTint: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.14)
        }
        guard isHovered else { return .clear }
        return Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05)
    }
}

/// Grouped-list container: one flat fill per group with a hairline border.
struct VideoStudyGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(4)
        .background(groupFill, in: shape)
        .overlay {
            shape.strokeBorder(groupStroke, lineWidth: 0.5)
        }
    }

    private var groupFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.7)
    }

    private var groupStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
}

struct VideoStudySectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)

            Spacer(minLength: 8)

            trailing()
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }
}

struct VideoStudySearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onExitCommand {
                    text = ""
                    isFocused = false
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(fieldFill, in: shape)
        .overlay {
            shape.strokeBorder(
                isFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1),
                lineWidth: isFocused ? 1 : 0.5
            )
        }
    }

    private var fieldFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.25) : Color.black.opacity(0.05)
    }
}

enum VideoStudySearch {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ text: String?, query: String) -> Bool {
        guard let text, !query.isEmpty else { return false }
        return text.range(of: query, options: options) != nil
    }

    static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result[searchStart...].range(of: query, options: options) {
            result[range].backgroundColor = Color.accentColor.opacity(0.3)
            searchStart = range.upperBound
        }
        return result
    }
}

/// Small circular icon buttons used for row and toolbar actions.
struct VideoStudyIconButtonStyle: ButtonStyle {
    var isFilled = false

    func makeBody(configuration: Configuration) -> some View {
        VideoStudyIconButtonBody(configuration: configuration, isFilled: isFilled)
    }
}

private struct VideoStudyIconButtonBody: View {
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

/// Pill buttons for inline toolbar actions.
struct VideoStudyChipButtonStyle: ButtonStyle {
    var isSelected = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .frame(minHeight: 26)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(fill(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }

    private func fill(isPressed: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(isPressed ? 0.8 : 1)
        }
        let base = colorScheme == .dark ? 0.08 : 0.06
        return Color.primary.opacity(isPressed ? base + 0.08 : base)
    }
}
