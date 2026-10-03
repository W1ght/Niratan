import AppKit
import SwiftUI

enum VideoStudySidebarTab: String, CaseIterable, Identifiable {
    case history
    case transcript
    case chapters

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .history: "Mining History"
        case .transcript: "Transcript"
        case .chapters: "Chapters"
        }
    }

    var systemName: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .transcript: "text.alignleft"
        case .chapters: "list.bullet.rectangle"
        }
    }
}

/// Docked study sidebar beside the video: an icon tab strip, a per-tab toolbar,
/// and flat grouped lists. Only the transcript and chapters tabs receive the
/// playback clock, so the history tab never re-renders during playback.
struct VideoMiningHistorySidebar: View {
    static let minWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 340
    static let maxWidth: CGFloat = 560

    @Binding var selectedTab: VideoStudySidebarTab
    let items: [VideoMiningHistoryItem]
    let transcript: SubtitleTranscript
    let chapters: [VideoChapter]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let pendingABLoopStart: TimeInterval?
    let abLoop: VideoABLoop?
    let isTranscriptLoading: Bool
    let transcriptErrorMessage: String?
    let canAlignPreviousSubtitle: Bool
    let canAlignNextSubtitle: Bool
    var onClose: () -> Void
    var onJump: (VideoMiningHistoryItem) -> Void
    var onSeekTranscript: (TimeInterval) -> Void
    var onSetTranscriptABLoopStart: (TimeInterval) -> Void
    var onSetTranscriptABLoopEnd: (TimeInterval) -> Void
    var onAlignPreviousSubtitle: () -> Void
    var onAlignNextSubtitle: () -> Void
    var onSeekChapter: (Int) -> Void
    var onCopy: (VideoMiningHistoryItem) -> Void
    var onDelete: (String) -> Void
    var onClear: () -> Void

    @State private var historyQuery = ""
    @State private var transcriptQuery = ""
    @State private var isConfirmingClear = false

    private struct HistorySection: Identifiable {
        let id: String
        let title: String
        var items: [VideoMiningHistoryItem]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
                .opacity(0.6)

            switch selectedTab {
            case .history:
                historyTab
            case .transcript:
                transcriptTab
            case .chapters:
                chaptersTab
            }
        }
        .frame(minWidth: Self.minWidth, idealWidth: Self.defaultWidth, maxWidth: .infinity)
        .background {
            VideoStudySidebarBackground()
        }
        .overlay(alignment: .leading) {
            Divider()
        }
        .confirmationDialog(
            "Clear Mining History?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Mining History", role: .destructive, action: onClear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved subtitle from Mining History.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VideoStudyTabBar(selection: $selectedTab)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(VideoStudyIconButtonStyle(isFilled: true))
            .help("Close")
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Mining History

    private var normalizedHistoryQuery: String {
        VideoStudySearch.normalizedQuery(historyQuery)
    }

    /// Newest first, grouped into consecutive runs from the same video.
    private var historySections: [HistorySection] {
        let query = normalizedHistoryQuery
        var result: [HistorySection] = []
        for item in items.reversed() {
            if !query.isEmpty,
               !VideoStudySearch.matches(item.subtitleText, query: query),
               !VideoStudySearch.matches(item.videoTitle, query: query) {
                continue
            }
            let title = item.videoTitle.isEmpty ? item.videoFileName : item.videoTitle
            if result.last?.title == title {
                result[result.count - 1].items.append(item)
            } else {
                result.append(HistorySection(id: "\(title)-\(result.count)", title: title, items: [item]))
            }
        }
        return result
    }

    @ViewBuilder
    private var historyTab: some View {
        if items.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                historyToolbar

                let sections = historySections
                if sections.isEmpty {
                    noResultsState(normalizedHistoryQuery)
                } else {
                    historyList(sections)
                }
            }
        }
    }

    private var historyToolbar: some View {
        HStack(spacing: 8) {
            VideoStudySearchField(prompt: "Search Mining History", text: $historyQuery)

            Button(role: .destructive) {
                isConfirmingClear = true
            } label: {
                Label("Clear Mining History", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(VideoStudyIconButtonStyle(isFilled: true))
            .help("Clear Mining History")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func historyList(_ sections: [HistorySection]) -> some View {
        let query = normalizedHistoryQuery

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        VideoStudySectionHeader(title: section.title) {
                            Text(section.items.count, format: .number)
                        }

                        VideoStudyGroup {
                            ForEach(section.items) { item in
                                historyRow(item, query: query)
                                    .id(item.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func historyRow(_ item: VideoMiningHistoryItem, query: String) -> some View {
        VideoStudyListRow {
            onJump(item)
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if item.subtitleText.isEmpty {
                        Text("Blank Subtitle")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(VideoStudySearch.highlighted(item.subtitleText, query: query))
                    }
                }
                .font(.callout)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Label {
                        Text(VideoTimeFormatter.string(from: item.cueStart))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .labelStyle(VideoStudyCompactLabelStyle())

                    Text(verbatim: "·")

                    Text(item.createdAt, format: .relative(presentation: .named))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } accessories: {
            HStack(spacing: 4) {
                Button {
                    onCopy(item)
                } label: {
                    Label("Copy Subtitle", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(VideoStudyIconButtonStyle())
                .help("Copy Subtitle")

                Button(role: .destructive) {
                    onDelete(item.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(VideoStudyIconButtonStyle())
                .help("Delete")
            }
        }
        .contextMenu {
            Button("Jump to Subtitle", systemImage: "play") {
                onJump(item)
            }
            Button("Copy Subtitle", systemImage: "doc.on.doc") {
                onCopy(item)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                onDelete(item.id)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Mining History Empty", systemImage: "tray")
        } description: {
            Text("Mined video subtitles will appear here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func noResultsState(_ query: String) -> some View {
        ContentUnavailableView.search(text: query)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptTab: some View {
        VStack(spacing: 0) {
            if !transcript.rows.isEmpty {
                transcriptToolbar
            }

            SubtitleTranscriptView(
                transcript: transcript,
                currentTime: currentTime,
                pendingABLoopStart: pendingABLoopStart,
                abLoop: abLoop,
                isLoading: isTranscriptLoading,
                errorMessage: transcriptErrorMessage,
                query: VideoStudySearch.normalizedQuery(transcriptQuery),
                onSeek: onSeekTranscript,
                onSetABLoopStart: onSetTranscriptABLoopStart,
                onSetABLoopEnd: onSetTranscriptABLoopEnd
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transcriptToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoStudySearchField(prompt: "Search Transcript", text: $transcriptQuery)

            HStack(spacing: 6) {
                Text("Align to Current Time")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 4)

                Button(action: onAlignPreviousSubtitle) {
                    Label("Previous", systemImage: "arrow.left.to.line")
                        .labelStyle(VideoStudyCompactLabelStyle())
                }
                .disabled(!canAlignPreviousSubtitle)
                .help("Align Previous Subtitle to Current Time")

                Button(action: onAlignNextSubtitle) {
                    Label("Next", systemImage: "arrow.right.to.line")
                        .labelStyle(VideoStudyCompactLabelStyle())
                }
                .disabled(!canAlignNextSubtitle)
                .help("Align Next Subtitle to Current Time")
            }
            .buttonStyle(VideoStudyChipButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Chapters

    @ViewBuilder
    private var chaptersTab: some View {
        if chapters.isEmpty {
            chapterEmptyState
        } else {
            chapterList
        }
    }

    private var chapterEmptyState: some View {
        ContentUnavailableView {
            Label("No Chapters", systemImage: "list.bullet.rectangle")
        } description: {
            Text("This video does not contain chapter markers.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var currentChapterID: Int? {
        chapters
            .filter { $0.startTime <= currentTime }
            .max(by: { $0.startTime < $1.startTime })?
            .id
    }

    /// End of a chapter is the next later chapter start, or the end of the video.
    private func chapterEndTime(after chapter: VideoChapter) -> TimeInterval? {
        let nextStart = chapters
            .lazy
            .map(\.startTime)
            .filter { $0 > chapter.startTime }
            .min()
        if let nextStart {
            return nextStart
        }
        return duration > chapter.startTime ? duration : nil
    }

    private var chapterList: some View {
        let currentID = currentChapterID
        let currentNumber = chapters.firstIndex { $0.id == currentID }.map { $0 + 1 }

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VideoStudySectionHeader(title: chapterSectionTitle(currentNumber: currentNumber)) {
                        if duration > 0 {
                            Text(VideoTimeFormatter.string(from: duration))
                        }
                    }

                    VideoStudyGroup {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                                chapterRow(
                                    chapter,
                                    number: index + 1,
                                    isCurrent: chapter.id == currentID
                                )
                                .id(chapter.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onAppear {
                guard let currentID else { return }
                proxy.scrollTo(currentID, anchor: .center)
            }
            .onChange(of: currentID) { _, chapterID in
                guard let chapterID else { return }
                withAnimation(.smooth(duration: 0.18)) {
                    proxy.scrollTo(chapterID, anchor: .center)
                }
            }
        }
    }

    private func chapterSectionTitle(currentNumber: Int?) -> String {
        if let currentNumber {
            return String(localized: "Chapter \(currentNumber) of \(chapters.count)")
        }
        return String(localized: "\(chapters.count) Chapters")
    }

    private func chapterRow(_ chapter: VideoChapter, number: Int, isCurrent: Bool) -> some View {
        let endTime = chapterEndTime(after: chapter)

        return VideoStudyListRow(isSelected: isCurrent) {
            onSeekChapter(chapter.id)
        } content: {
            HStack(alignment: .top, spacing: 10) {
                Text(number, format: .number)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                    .frame(minWidth: 26, minHeight: 22)
                    .background(
                        isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title.isEmpty ? String(localized: "Chapter \(number)") : chapter.title)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Text(VideoTimeFormatter.string(from: chapter.startTime))
                        if let endTime {
                            Text(verbatim: "·")
                            Text(VideoTimeFormatter.string(from: endTime - chapter.startTime))
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if isCurrent, let endTime, endTime > chapter.startTime {
                        VideoStudyProgressBar(
                            fraction: (currentTime - chapter.startTime) / (endTime - chapter.startTime)
                        )
                        .padding(.top, 2)
                    }
                }
            }
        }
        .help(chapter.title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

private struct VideoStudyTabBar: View {
    @Binding var selection: VideoStudySidebarTab
    @Namespace private var selectionNamespace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VideoStudySidebarTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selection = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemName)
                            .font(.system(size: 12, weight: .semibold))
                        Text(tab.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedFill)
                                .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(Text(tab.title))
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(2)
        .background(containerFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var containerFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.9)
    }
}

private struct VideoStudyProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityValue(Text(min(max(fraction, 0), 1), format: .percent.precision(.fractionLength(0))))
    }
}

struct VideoStudyCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// Docked beside the video rather than over it, so it shares the library's solid page tone.
private struct VideoStudySidebarBackground: View {
    var body: some View {
        NativeGlassPageBackground()
    }
}

struct VideoStudySidebarResizeHandle: View {
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 10)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(isHovering ? 0.28 : 0.12))
                    .frame(width: 2)
                    .padding(.vertical, 10)
            }
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                }
            }
    }
}
