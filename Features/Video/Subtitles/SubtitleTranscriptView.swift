import SwiftUI

struct SubtitleTranscriptView: View {
    let transcript: SubtitleTranscript
    let currentTime: TimeInterval
    let pendingABLoopStart: TimeInterval?
    let abLoop: VideoABLoop?
    let isLoading: Bool
    let errorMessage: String?
    /// Already trimmed; an empty query shows the windowed, playback-following list.
    let query: String
    var onSeek: (TimeInterval) -> Void
    var onSetABLoopStart: (TimeInterval) -> Void
    var onSetABLoopEnd: (TimeInterval) -> Void

    @State private var rowWindow = SubtitleTranscriptWindow()
    @State private var focusedRowID: String?
    /// Cleared when the user scrolls the list themselves; restored by "Back to Current Line".
    @State private var isFollowingPlayback = true

    var body: some View {
        VStack(spacing: 0) {
            if transcript.rows.isEmpty {
                emptyState
            } else if !query.isEmpty {
                searchResults
            } else {
                transcriptRows
            }
        }
        .onAppear {
            resetWindowForCurrentTime()
        }
        .onChange(of: transcript.changeToken) { _, _ in
            isFollowingPlayback = true
            resetWindowForCurrentTime()
        }
        .onChange(of: query.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            isFollowingPlayback = true
            resetWindowForCurrentTime()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if isLoading {
                ContentUnavailableView {
                    Label("Loading Transcript", systemImage: "captions.bubble")
                } description: {
                    Text("Reading the selected subtitle track…")
                } actions: {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Transcript Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "captions.bubble",
                    description: Text("Load subtitles to view the transcript.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private var transcriptRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(transcript.rows(in: rowWindow.visibleRange).enumerated()), id: \.element.id) { offset, row in
                        transcriptRow(row, query: "")
                            .id(row.id)
                            .onAppear {
                                extendWindowIfNeeded(forVisibleOffset: offset)
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 56)
            }
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    isFollowingPlayback = false
                }
            }
            .task {
                await scrollToCurrentRow(using: proxy)
            }
            .onChange(of: currentTime) { _, time in
                followPlayback(time, using: proxy)
            }
            .overlay(alignment: .bottom) {
                if !isFollowingPlayback, currentRowID != nil {
                    backToCurrentButton(using: proxy)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.2), value: isFollowingPlayback)
        }
    }

    private var searchResults: some View {
        let matches = transcript.rows.filter {
            VideoStudySearch.matches($0.primaryText, query: query)
                || VideoStudySearch.matches($0.secondaryText, query: query)
        }

        return Group {
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Text("\(matches.count) Matches")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)

                        ForEach(matches) { row in
                            transcriptRow(row, query: query)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.automatic)
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
    }

    private func backToCurrentButton(using proxy: ScrollViewProxy) -> some View {
        Button {
            isFollowingPlayback = true
            resetWindowForCurrentTime()
            Task { await scrollToCurrentRow(using: proxy) }
        } label: {
            Label("Back to Current Line", systemImage: "arrow.down.to.line")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .nativeGlassCapsuleSurface()
    }

    private func transcriptRow(_ row: SubtitleTranscriptRow, query: String) -> some View {
        let isCurrent = row.startTime <= currentTime && currentTime <= row.endTime
        let isLoopStart = isABLoopStart(row)
        let isLoopEnd = isABLoopEnd(row)

        return VideoStudyListRow(
            isSelected: isCurrent,
            showsAccessoriesAlways: isLoopStart || isLoopEnd
        ) {
            onSeek(row.startTime)
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(VideoTimeFormatter.string(from: row.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 38, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(VideoStudySearch.highlighted(row.primaryText, query: query))
                        .font(.callout.weight(isCurrent ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    if let secondaryText = row.secondaryText,
                       !secondaryText.isEmpty {
                        Text(VideoStudySearch.highlighted(secondaryText, query: query))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } accessories: {
            HStack(spacing: 4) {
                abLoopMarkerButton("A", isActive: isLoopStart) {
                    onSetABLoopStart(row.startTime)
                }
                abLoopMarkerButton("B", isActive: isLoopEnd) {
                    onSetABLoopEnd(row.endTime)
                }
                .disabled(!canSetABLoopEnd)
            }
        }
    }

    private var canSetABLoopEnd: Bool {
        pendingABLoopStart != nil || abLoop != nil
    }

    private func isABLoopStart(_ row: SubtitleTranscriptRow) -> Bool {
        guard let start = pendingABLoopStart ?? abLoop?.start else { return false }
        return rowContains(row, time: start)
    }

    private func isABLoopEnd(_ row: SubtitleTranscriptRow) -> Bool {
        guard let end = abLoop?.end, pendingABLoopStart == nil else { return false }
        return rowContains(row, time: end)
    }

    private func rowContains(_ row: SubtitleTranscriptRow, time: TimeInterval) -> Bool {
        row.startTime <= time && time <= row.endTime
    }

    private func abLoopMarkerButton(
        _ label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                .background {
                    Circle()
                        .fill(isActive ? Color.accentColor : Color.primary.opacity(0.08))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label == "A" ? "Set A Point" : "Set B Point")
        .accessibilityLabel(Text(label == "A" ? "Set A Point" : "Set B Point"))
    }

    private func resetWindowForCurrentTime() {
        guard let index = transcript.nearestRowIndex(at: currentTime) else {
            rowWindow.reset(rowCount: 0, focusing: 0)
            focusedRowID = nil
            return
        }
        rowWindow.reset(rowCount: transcript.rows.count, focusing: index)
        focusedRowID = transcript.rows[index].id
    }

    /// Waits for the windowed rows to lay out, then centers the row under the playhead.
    private func scrollToCurrentRow(using proxy: ScrollViewProxy) async {
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled,
              let index = transcript.nearestRowIndex(at: currentTime) else { return }
        let rowID = transcript.rows[index].id
        focusedRowID = rowID
        proxy.scrollTo(rowID, anchor: .center)
    }

    private func extendWindowIfNeeded(forVisibleOffset offset: Int) {
        let absoluteIndex = rowWindow.visibleRange.lowerBound + offset
        if absoluteIndex <= rowWindow.visibleRange.lowerBound + 4 {
            rowWindow.extendBefore(rowCount: transcript.rows.count)
        }
        if absoluteIndex >= rowWindow.visibleRange.upperBound - 5 {
            rowWindow.extendAfter(rowCount: transcript.rows.count)
        }
    }

    private func followPlayback(
        _ time: TimeInterval,
        using proxy: ScrollViewProxy
    ) {
        guard isFollowingPlayback,
              let rowIndex = transcript.nearestRowIndex(at: time) else { return }
        let previousRange = rowWindow.visibleRange
        rowWindow.followPlayback(
            rowCount: transcript.rows.count,
            focusing: rowIndex
        )
        let row = transcript.rows[rowIndex]
        guard row.id != focusedRowID || rowWindow.visibleRange != previousRange else {
            return
        }
        focusedRowID = row.id
        proxy.scrollTo(row.id, anchor: .center)
    }

    private var currentRowID: String? {
        transcript.nearestRowIndex(at: currentTime).map { transcript.rows[$0].id }
    }
}

extension SubtitleTranscriptView: Equatable {
    static func == (lhs: SubtitleTranscriptView, rhs: SubtitleTranscriptView) -> Bool {
        lhs.transcript.changeToken == rhs.transcript.changeToken
            && lhs.currentRowID == rhs.currentRowID
            && lhs.pendingABLoopStart == rhs.pendingABLoopStart
            && lhs.abLoop == rhs.abLoop
            && lhs.isLoading == rhs.isLoading
            && lhs.errorMessage == rhs.errorMessage
            && lhs.query == rhs.query
    }
}
