import SwiftUI

struct MiningContextSelectionView: View {
    @State private var selection: MiningContextSelection
    @State private var isSubmitting = false
    @State private var resultMessage: String?

    let onCancel: () -> Void
    let onConfirm: (MiningContextSelectionResult) async -> AnkiMiningResult

    init(
        selection: MiningContextSelection,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (MiningContextSelectionResult) async -> AnkiMiningResult
    ) {
        _selection = State(initialValue: selection)
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            rangeSummary
            sentenceStack
            rangeControls
            if let resultMessage {
                Label(resultMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            footer
        }
        .padding(24)
        .frame(width: 620)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Adjust before mining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Select Sentence Context")
                    .font(.title2.weight(.semibold))
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Cancel")
        }
    }

    private var rangeSummary: some View {
        HStack(spacing: 10) {
            Text("Selected \(selection.result.sentences.count) sentences")
                .font(.callout.weight(.medium))
            Spacer()
            if let range = selection.result.mediaRange {
                Text("\(Self.time(range.start)) – \(Self.time(range.end))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sentenceStack: some View {
        ScrollView {
            VStack(spacing: -8) {
                ForEach(Array(selection.result.sentences.enumerated()), id: \.element.id) { index, sentence in
                    let isCurrent = index == selection.result.currentSentenceIndex
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(isCurrent ? "Current Sentence" : contextPositionLabel(index: index))
                            Spacer()
                            if let range = sentence.mediaRange {
                                Text(Self.time(range.start))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(Self.highlightedText(for: sentence))
                            .font(isCurrent ? .body.weight(.semibold) : .body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(isCurrent ? 18 : 15)
                    .background(
                        isCurrent ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(
                                isCurrent ? Color.accentColor.opacity(0.58) : Color.primary.opacity(0.1),
                                lineWidth: 1
                            )
                    }
                    .scaleEffect(isCurrent ? 1 : 0.975)
                    .opacity(isCurrent ? 1 : 0.78)
                    .zIndex(isCurrent ? 2 : 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 360)
    }

    private var rangeControls: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                contextButton("Remove Previous", systemImage: "minus", enabled: selection.canRemovePrevious) {
                    selection.removePrevious()
                }
                contextButton("Add Previous", systemImage: "plus", enabled: selection.canAddPrevious) {
                    selection.addPrevious()
                }
                Spacer(minLength: 12)
                contextButton("Remove Next", systemImage: "minus", enabled: selection.canRemoveNext) {
                    selection.removeNext()
                }
                contextButton("Add Next", systemImage: "plus", enabled: selection.canAddNext) {
                    selection.addNext()
                }
            }
        }
    }

    private func contextButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(MiningContextGlassButtonStyle())
        .disabled(!enabled || isSubmitting)
    }

    private var footer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(MiningContextGlassButtonStyle())
                    .disabled(isSubmitting)
                Button("Confirm Mining") {
                    submit()
                }
                .buttonStyle(MiningContextGlassButtonStyle(isProminent: true))
                .disabled(isSubmitting)
            }
        }
    }

    private func contextPositionLabel(index: Int) -> LocalizedStringKey {
        index < selection.result.currentSentenceIndex ? "Previous Context" : "Next Context"
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        resultMessage = nil
        let result = selection.result
        Task {
            let miningResult = await onConfirm(result)
            await MainActor.run {
                isSubmitting = false
                switch miningResult.status {
                case .added, .pending:
                    onCancel()
                case .duplicate, .failed:
                    resultMessage = miningResult.message
                }
            }
        }
    }

    private static func highlightedText(for sentence: MiningContextSentence) -> AttributedString {
        var attributed = AttributedString(sentence.text)
        guard let range = sentence.targetUTF16Range,
              range.length > 0,
              let stringRange = Range(range, in: sentence.text),
              let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
              let upper = AttributedString.Index(stringRange.upperBound, within: attributed) else {
            return attributed
        }
        attributed[lower..<upper].backgroundColor = .accentColor.opacity(0.35)
        attributed[lower..<upper].font = .body.bold()
        return attributed
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        let hours = Int(value) / 3600
        let minutes = (Int(value) % 3600) / 60
        let remaining = value - Double(hours * 3600 + minutes * 60)
        return String(format: "%02d:%02d:%06.3f", hours, minutes, remaining)
    }
}

private struct MiningContextGlassButtonStyle: ButtonStyle {
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 15)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .contentShape(Capsule())
            .background {
                if isProminent || configuration.isPressed {
                    Capsule()
                        .fill(
                            isProminent
                                ? Color.accentColor.opacity(configuration.isPressed ? 0.26 : 0.18)
                                : Color.primary.opacity(0.08)
                        )
                }
            }
            .modifier(MiningContextGlassButtonSurface(isProminent: isProminent))
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }

    private var foregroundStyle: some ShapeStyle {
        if isEnabled {
            isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary)
        } else {
            AnyShapeStyle(Color.secondary)
        }
    }
}

private struct MiningContextGlassButtonSurface: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if isProminent {
            content
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.18)).interactive(), in: Capsule())
        } else {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        }
    }
}
