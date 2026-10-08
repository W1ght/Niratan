import EPUBKit
import SwiftUI

private enum ReaderGoToTab: String, CaseIterable, Identifiable {
    case search
    case chapters
    case highlights

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .search: "Search"
        case .chapters: "Chapters"
        case .highlights: "Highlights"
        }
    }

    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .chapters: "list.bullet"
        case .highlights: "highlighter"
        }
    }
}

struct ReaderGoToView: View {
    let displayTitle: String
    let document: EPUBDocument
    let bookInfo: BookInfo
    let currentCharacter: Int
    let contentLanguage: ContentLanguageProfile
    let coverURL: URL?
    let highlights: [Highlight]
    let onChapterJump: (Int, String?) -> Void
    let onCharacterJump: (Int) -> Void
    let onSearchResultJump: (ReaderSearchResult) -> Void
    let onHighlightJump: (Highlight) -> Void
    let onHighlightDelete: (Highlight) -> Void
    let onDismiss: () -> Void
    var highlightSpineIndex: ((Highlight) -> Int?)? = nil

    @State private var selectedTab: ReaderGoToTab = .chapters
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var searchResults: [ReaderSearchResult] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var searchTask: Task<Void, Never>?
    @State private var chapterRows: [ChapterRow] = []
    @State private var showJumpAlert = false
    @State private var showInvalidJumpAlert = false
    @State private var jumpInput = ""

    private var searchDocument: ReaderSearchDocument {
        ReaderSearchDocument(epubDocument: document, bookInfo: bookInfo)
    }

    private var chapterIndexRevision: Int {
        bookInfo.fragmentOffsetsRevision
    }

    var body: some View {
        VStack(spacing: 0) {
            NativeReaderInspectorHeader(title: "Go to", onClose: onDismiss)

            bookSummary
                .padding(.horizontal, 18)
                .padding(.bottom, 14)

            NativeReaderInspectorTabBar(
                tabs: ReaderGoToTab.allCases,
                selection: $selectedTab,
                title: \.title,
                systemImage: \.systemImage
            )
            .padding(.bottom, 10)

            selectedContent
        }
        .onAppear {
            refreshChapterRows()
        }
        .onChange(of: chapterIndexRevision) { _, _ in
            refreshChapterRows()
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .alert("Jump to", isPresented: $showJumpAlert) {
            TextField(contentLanguage == .english ? "Word count" : "Character count", text: $jumpInput)
            Button("Cancel", role: .cancel) {}
            Button("Go") {
                if let count = Int(jumpInput), count >= 0 {
                    onCharacterJump(contentLanguage.rawCharacters(forDisplayCount: count))
                } else {
                    showInvalidJumpAlert = true
                }
            }
        } message: {
            Text(progressText(rawCharacter: currentCharacter))
        }
        .alert("Invalid input", isPresented: $showInvalidJumpAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(contentLanguage == .english ? "Please enter a valid word count" : "Please enter a valid character count")
        }
    }

    private var bookSummary: some View {
        let progress = bookInfo.characterCount > 0
            ? min(max(Double(currentCharacter) / Double(bookInfo.characterCount), 0), 1)
            : 0
        return HStack(alignment: .top, spacing: 12) {
            CoverImage(url: coverURL, maxPixelSize: 256) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.secondary.opacity(0.18))
            }
            .frame(width: 46, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                ProgressView(value: progress)
                    .controlSize(.small)
                HStack(spacing: 8) {
                    Text(progressText(rawCharacter: currentCharacter))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        jumpInput = ""
                        showJumpAlert = true
                    } label: {
                        Label("Jump to", systemImage: "arrow.right.to.line")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .search:
            searchTab
        case .chapters:
            chaptersTab
        case .highlights:
            highlightsTab
        }
    }

    private var searchTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search in this book", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(runSearch)
                    .onChange(of: query) { _, value in
                        if !ReaderSearchTextFilter.hasMatchableText(value) {
                            clearSearch()
                        }
                    }
                Button {
                    runSearch()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .disabled(!ReaderSearchTextFilter.hasMatchableText(query) || isSearching)
                .help("Search")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            searchResultsContent
        }
    }

    @ViewBuilder
    private var searchResultsContent: some View {
        if !ReaderSearchTextFilter.hasMatchableText(submittedQuery) {
            ContentUnavailableView("Enter text to search this book", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSearching {
            VStack(spacing: 10) {
                ProgressView()
                Text("Searching...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchFailed {
            ContentUnavailableView("Could not search this book", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groupedSearchResults) { section in
                        HStack(alignment: .firstTextBaseline) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(resultCountText(section.results.count))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                        ForEach(section.results) { result in
                            Button {
                                onSearchResultJump(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(highlightedSnippet(for: result))
                                        .font(.callout)
                                        .lineLimit(3)
                                    Text(progressText(rawCharacter: result.character))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(NativeReaderInspectorRowButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
        }
    }

    private var chaptersTab: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(chapterRows) { row in
                        Button {
                            onChapterJump(row.spineIndex, row.fragment)
                        } label: {
                            HStack(spacing: 8) {
                                Text(row.label)
                                    .font(row.indentLevel > 0 ? .callout : .callout.weight(.medium))
                                    .foregroundStyle(row.indentLevel > 0 ? .secondary : .primary)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                if let count = row.characterCount {
                                    Text("\(contentLanguage.displayCount(forRawCharacters: count))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.leading, CGFloat(row.indentLevel) * 14)
                        }
                        .buttonStyle(NativeReaderInspectorRowButtonStyle(isSelected: row.isCurrent))
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            .onAppear {
                scrollToCurrentChapter(proxy)
            }
            .onChange(of: chapterRows.map(\.id)) { _, _ in
                scrollToCurrentChapter(proxy)
            }
        }
        .overlay {
            if chapterRows.isEmpty {
                ContentUnavailableView("No Chapters", systemImage: "list.bullet")
            }
        }
    }

    private func scrollToCurrentChapter(_ proxy: ScrollViewProxy) {
        guard let current = chapterRows.last(where: \.isCurrent) else { return }
        proxy.scrollTo(current.id, anchor: .center)
    }

    private var highlightsTab: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(highlightSections) { section in
                    if !section.label.isEmpty {
                        Text(section.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                    }
                    ForEach(section.highlights) { highlight in
                        Button {
                            onHighlightJump(highlight)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(highlight.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.callout)
                                    .lineLimit(4)
                                Text("\(highlight.createdAt.formatted(date: .abbreviated, time: .shortened)) (\(contentLanguage.displayCount(forRawCharacters: highlight.character)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(highlight.color.swatch)
                                    .frame(width: 3)
                            }
                        }
                        .buttonStyle(NativeReaderInspectorRowButtonStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                onHighlightDelete(highlight)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
        .overlay {
            if highlights.isEmpty {
                ContentUnavailableView("No Highlights", systemImage: "highlighter")
            }
        }
    }

    private var groupedSearchResults: [SearchResultSection] {
        let grouped = Dictionary(grouping: searchResults, by: \.chapterIndex)
        return grouped.keys.sorted().compactMap { chapterIndex in
            guard let results = grouped[chapterIndex] else { return nil }
            return SearchResultSection(
                id: chapterIndex,
                title: results.first?.chapterLabel.isEmpty == false ? results[0].chapterLabel : String(localized: "Untitled Chapter"),
                results: results
            )
        }
    }

    private var highlightSections: [HighlightSection] {
        let labels = chapterLabelBySpineIndex
        let grouped = Dictionary(grouping: highlights) { highlight in
            var spine: Int
            if let highlightSpineIndex {
                // An unresolved shared DOM anchor stays ungrouped. Its native
                // integer may also belong to another zero-count chapter.
                guard let resolved = highlightSpineIndex(highlight) else { return -1 }
                spine = resolved
            } else {
                spine = bookInfo.resolveCharacterPosition(highlight.character)?.spineIndex ?? -1
            }
            while spine > 0, labels[spine] == nil {
                spine -= 1
            }
            return spine
        }
        return grouped.map { spineIndex, list in
            HighlightSection(
                id: spineIndex,
                label: labels[spineIndex] ?? "",
                highlights: list.sorted { $0.character < $1.character }
            )
        }
        .sorted { $0.id < $1.id }
    }

    private var chapterLabelBySpineIndex: [Int: String] {
        var labels: [Int: String] = [:]
        for row in chapterRows where !row.label.isEmpty {
            if labels[row.spineIndex] == nil {
                labels[row.spineIndex] = row.label
            }
        }
        return labels
    }

    private func runSearch() {
        guard ReaderSearchTextFilter.hasMatchableText(query) else {
            clearSearch()
            return
        }

        searchTask?.cancel()
        submittedQuery = query
        isSearching = true
        searchFailed = false
        let capturedQuery = query
        let document = searchDocument

        searchTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                ReaderSearchEngine(document: document).search(capturedQuery)
            }.result

            guard !Task.isCancelled else { return }
            switch result {
            case .success(let results):
                searchResults = results
                searchFailed = false
            case .failure:
                searchResults = []
                searchFailed = true
            }
            isSearching = false
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        submittedQuery = ""
        searchResults = []
        isSearching = false
        searchFailed = false
    }

    private func refreshChapterRows() {
        chapterRows = ChapterListViewModel(
            document: document,
            bookInfo: bookInfo,
            currentCharacter: currentCharacter
        ).rows
    }

    private func progressText(rawCharacter: Int) -> String {
        let current = contentLanguage.displayCount(forRawCharacters: rawCharacter)
        let total = contentLanguage.displayCount(forRawCharacters: bookInfo.characterCount)
        let percent = bookInfo.characterCount > 0 ? Double(rawCharacter) / Double(bookInfo.characterCount) * 100 : 0
        return "\(current) / \(total) (\(String(format: "%.1f%%", percent)))"
    }

    private func resultCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 result")
            : String.localizedStringWithFormat(String(localized: "%d results"), count)
    }

    private func highlightedSnippet(for result: ReaderSearchResult) -> AttributedString {
        let characters = Array(result.snippet)
        let lower = max(0, min(result.snippetMatchStart, characters.count))
        let upper = max(lower, min(result.snippetMatchEnd, characters.count))
        var attributed = AttributedString(String(characters[..<lower]))
        var match = AttributedString(String(characters[lower..<upper]))
        match.backgroundColor = .accentColor.opacity(0.22)
        attributed += match
        attributed += AttributedString(String(characters[upper...]))
        return attributed
    }
}

private struct SearchResultSection: Identifiable {
    let id: Int
    let title: String
    let results: [ReaderSearchResult]
}
