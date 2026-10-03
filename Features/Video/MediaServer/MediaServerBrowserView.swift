import AppKit
import SwiftUI

/// Content pane for one media server inside the video library.
struct MediaServerBrowserView: View {
    @Bindable var model: MediaServerBrowserModel
    let posterWidth: CGFloat
    let onPlay: (RemoteVideoWindowOpenRequest) -> Void
    let onSignInAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MediaServerBrowserHeader(model: model)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: model.account.id) {
            await model.loadIfNeeded()
        }
        .onAppear {
            Task { await model.refreshContinueWatching() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where model.libraries.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where model.libraries.isEmpty:
            ContentUnavailableView {
                Label("Unable to Load Server", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await model.reload() }
                }
                Button("Sign In Again", action: onSignInAgain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if model.isSearching {
                MediaServerSearchResultsView(model: model, posterWidth: posterWidth, actions: actions)
            } else {
                switch model.routes.last {
                case nil:
                    MediaServerHomeView(model: model, actions: actions)
                case .library, .folder:
                    if let route = model.routes.last, let grid = model.grid(for: route) {
                        MediaServerGridView(model: model, grid: grid, posterWidth: posterWidth, actions: actions)
                            .id(grid.parentID)
                    }
                case .series(let series):
                    MediaServerSeriesView(
                        model: model,
                        detail: model.seriesDetail(for: series),
                        actions: actions
                    )
                    .id(series.id)
                }
            }
        }
    }

    private var actions: MediaServerItemActions {
        MediaServerItemActions(
            open: { item in
                if item.isPlayable {
                    play(item, fromBeginning: false)
                } else {
                    model.open(item)
                }
            },
            play: { item, fromBeginning in
                play(item, fromBeginning: fromBeginning)
            },
            setPlayed: { item, played in
                Task { await model.setPlayed(played, item: item) }
            },
            openInBrowser: { item in
                if let url = model.webURL(for: item) {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }

    private func play(_ item: MediaServerItem, fromBeginning: Bool) {
        guard let request = model.playbackRequest(for: item, startsFromBeginning: fromBeginning) else {
            return
        }
        onPlay(request)
    }
}

struct MediaServerItemActions {
    let open: (MediaServerItem) -> Void
    let play: (MediaServerItem, Bool) -> Void
    let setPlayed: (MediaServerItem, Bool) -> Void
    let openInBrowser: (MediaServerItem) -> Void
}

private enum MediaServerLayout {
    static let wideCardWidth: CGFloat = 248
    static let rowSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 28
    static let cornerRadius: CGFloat = 10
}

// MARK: Header

private struct MediaServerBrowserHeader: View {
    @Bindable var model: MediaServerBrowserModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if !model.routes.isEmpty, !model.isSearching {
                Button {
                    model.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Back")
                .keyboardShortcut("[", modifiers: .command)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.isSearching ? String(localized: "Search Results") : model.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                if !model.routes.isEmpty || model.isSearching {
                    Button(model.account.displayName) {
                        model.searchText = ""
                        model.goHome()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } else {
                    Text("\(model.account.kind.displayName) · \(model.account.accountSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if case .library = model.routes.last, !model.isSearching {
                sortMenu
            } else if case .folder = model.routes.last, !model.isSearching {
                sortMenu
            }
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: sortBinding) {
                ForEach(MediaServerSort.allCases) { sort in
                    Text(LocalizedStringKey(sort.titleKey)).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Sort")
    }

    private var sortBinding: Binding<MediaServerSort> {
        Binding(
            get: { model.sort },
            set: { sort in
                guard let route = model.routes.last, let grid = model.grid(for: route) else { return }
                Task { await model.setSort(sort, for: grid) }
            }
        )
    }
}

// MARK: Home

private struct MediaServerHomeView: View {
    @Bindable var model: MediaServerBrowserModel
    let actions: MediaServerItemActions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MediaServerLayout.sectionSpacing) {
                if !model.continueWatching.isEmpty {
                    MediaServerRow(title: Text("Continue Watching")) {
                        ForEach(model.continueWatching) { item in
                            MediaServerWideCard(item: item, actions: actions)
                        }
                    }
                }

                if !model.libraries.isEmpty {
                    MediaServerRow(title: Text("Libraries")) {
                        ForEach(model.libraries) { library in
                            MediaServerLibraryTile(library: library) {
                                model.open(library)
                            }
                        }
                    }
                } else if model.state == .loaded {
                    ContentUnavailableView(
                        "No Video Libraries",
                        systemImage: "film.stack",
                        description: Text("This account has no movie or TV libraries.")
                    )
                }

                ForEach(model.libraries) { library in
                    MediaServerLatestRow(model: model, library: library, actions: actions)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct MediaServerLatestRow: View {
    @Bindable var model: MediaServerBrowserModel
    let library: MediaServerLibrary
    let actions: MediaServerItemActions

    var body: some View {
        Group {
            if let items = model.latestByLibrary[library.id] {
                if !items.isEmpty {
                    MediaServerRow(
                        title: Text("Recently Added in \(library.name)"),
                        onShowAll: { model.open(library) }
                    ) {
                        ForEach(items) { item in
                            MediaServerPosterCard(item: item, width: 132, actions: actions)
                        }
                    }
                }
            } else {
                Color.clear
                    .frame(height: 1)
                    .task { await model.loadLatest(for: library) }
            }
        }
    }
}

private struct MediaServerRow<Content: View>: View {
    let title: Text
    var onShowAll: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                title
                    .font(.headline)
                Spacer(minLength: 0)
                if let onShowAll {
                    Button("Show All", action: onShowAll)
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MediaServerLayout.rowSpacing) {
                    content
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)
        }
    }
}

// MARK: Grid

private struct MediaServerGridView: View {
    @Bindable var model: MediaServerBrowserModel
    @Bindable var grid: MediaServerBrowserModel.Grid
    let posterWidth: CGFloat
    let actions: MediaServerItemActions

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: posterWidth, maximum: posterWidth * 1.25), spacing: 20, alignment: .top)],
                alignment: .leading,
                spacing: 26
            ) {
                ForEach(grid.items) { item in
                    MediaServerPosterCard(item: item, width: nil, actions: actions)
                        .onAppear {
                            if item.id == grid.items.last?.id, let client = model.client {
                                Task { await grid.loadMore(client: client) }
                            }
                        }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)

            footer
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if grid.items.isEmpty, grid.state == .loaded {
                ContentUnavailableView("Nothing Here", systemImage: "film.stack")
            }
        }
        .task(id: grid.parentID) {
            if grid.state == .idle, let client = model.client {
                await grid.reload(client: client)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch grid.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    guard let client = model.client else { return }
                    Task { await grid.loadMore(client: client, isReload: grid.items.isEmpty) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        default:
            EmptyView()
        }
    }
}

private struct MediaServerSearchResultsView: View {
    @Bindable var model: MediaServerBrowserModel
    let posterWidth: CGFloat
    let actions: MediaServerItemActions

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: posterWidth, maximum: posterWidth * 1.25), spacing: 20, alignment: .top)],
                alignment: .leading,
                spacing: 26
            ) {
                ForEach(model.searchResults) { item in
                    MediaServerPosterCard(item: item, width: nil, actions: actions)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .overlay {
            switch model.searchState {
            case .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(message))
            case .loaded where model.searchResults.isEmpty:
                ContentUnavailableView.search(text: model.searchText)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: Series

private struct MediaServerSeriesView: View {
    @Bindable var model: MediaServerBrowserModel
    @Bindable var detail: MediaServerBrowserModel.SeriesDetail
    let actions: MediaServerItemActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if detail.seasons.count > 1 {
                    Picker("Season", selection: seasonBinding) {
                        ForEach(detail.seasons) { season in
                            Text(season.name).tag(Optional(season.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .padding(.horizontal)
                }

                episodes
            }
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .task(id: detail.series.id) {
            if detail.state == .idle, let client = model.client {
                await detail.load(client: client)
            }
        }
    }

    private var series: MediaServerItem {
        detail.detail ?? detail.series
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            MediaServerArtwork(url: series.posterURL, aspectRatio: 2 / 3, systemImage: "tv")
                .frame(width: 168)

            VStack(alignment: .leading, spacing: 8) {
                Text(series.name)
                    .font(.title.weight(.semibold))
                    .textSelection(.enabled)
                if let originalTitle = series.originalTitle, originalTitle != series.name {
                    Text(originalTitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    if let year = series.year {
                        Text(String(year))
                    }
                    if let count = series.childCount {
                        Text("\(count) episodes")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if let overview = series.overview {
                    Text(overview)
                        .font(.callout)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let next = detail.nextEpisode {
                    Button {
                        actions.play(next, false)
                    } label: {
                        Label(playTitle(for: next), systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
        .padding(.horizontal)
    }

    private func playTitle(for episode: MediaServerItem) -> String {
        let code = episode.episodeCode ?? episode.name
        if (episode.playbackPosition ?? 0) > 0, !episode.isPlayed {
            return String(localized: "Resume \(code)")
        }
        return String(localized: "Play \(code)")
    }

    @ViewBuilder
    private var episodes: some View {
        switch detail.episodesState {
        case .loading where detail.episodes.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        default:
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(detail.episodes) { episode in
                    MediaServerEpisodeRow(episode: episode, actions: actions)
                }
            }
            .padding(.horizontal)
        }
    }

    private var seasonBinding: Binding<String?> {
        Binding(
            get: { detail.selectedSeasonID },
            set: { seasonID in
                detail.selectedSeasonID = seasonID
                guard let client = model.client else { return }
                Task { await detail.loadEpisodes(client: client) }
            }
        )
    }
}

private struct MediaServerEpisodeRow: View {
    let episode: MediaServerItem
    let actions: MediaServerItemActions
    @State private var isHovered = false

    var body: some View {
        Button {
            actions.play(episode, false)
        } label: {
            HStack(alignment: .top, spacing: 16) {
                MediaServerArtwork(
                    url: episode.thumbnailURL ?? episode.posterURL,
                    aspectRatio: 16 / 9,
                    systemImage: "film",
                    progress: episode.isPlayed ? nil : episode.progress,
                    isPlayed: episode.isPlayed,
                    isHovered: isHovered
                )
                .frame(width: 208)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                    if let runtime = episode.runtime {
                        Text(Duration.seconds(runtime).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let overview = episode.overview {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            MediaServerItemContextMenu(item: episode, actions: actions)
        }
    }

    private var title: String {
        if let number = episode.episodeNumber {
            return "\(number). \(episode.name)"
        }
        return episode.name
    }
}

// MARK: Cards

private struct MediaServerPosterCard: View {
    let item: MediaServerItem
    let width: CGFloat?
    let actions: MediaServerItemActions
    @State private var isHovered = false

    var body: some View {
        Button {
            actions.open(item)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                MediaServerArtwork(
                    url: item.kind == .episode ? (item.thumbnailURL ?? item.posterURL) : item.posterURL,
                    aspectRatio: item.kind == .episode ? 16 / 9 : 2 / 3,
                    systemImage: placeholderImage,
                    progress: item.isPlayed ? nil : item.progress,
                    isPlayed: item.isPlayed,
                    badge: badge,
                    isHovered: isHovered,
                    showsPlayGlyph: item.isPlayable
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.kind == .episode ? (item.seriesName ?? item.name) : item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(item.name)
        .contextMenu {
            MediaServerItemContextMenu(item: item, actions: actions)
        }
    }

    private var placeholderImage: String {
        switch item.kind {
        case .series, .season: "tv"
        case .folder: "folder"
        default: "film"
        }
    }

    private var badge: String? {
        guard item.kind == .series || item.kind == .season,
              let unplayed = item.unplayedCount, unplayed > 0 else { return nil }
        return String(unplayed)
    }

    private var subtitle: String? {
        switch item.kind {
        case .episode:
            [item.episodeCode, item.name].compactMap { $0 }.joined(separator: " · ")
        case .series:
            item.year.map(String.init)
        case .folder:
            item.childCount.map { String(localized: "\($0) items") }
        default:
            item.year.map(String.init)
        }
    }
}

private struct MediaServerWideCard: View {
    let item: MediaServerItem
    let actions: MediaServerItemActions
    @State private var isHovered = false

    var body: some View {
        Button {
            actions.open(item)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                MediaServerArtwork(
                    url: item.thumbnailURL ?? item.posterURL,
                    aspectRatio: 16 / 9,
                    systemImage: "film",
                    progress: item.isPlayed ? nil : item.progress,
                    isPlayed: item.isPlayed,
                    isHovered: isHovered,
                    showsPlayGlyph: true
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.kind == .episode ? (item.seriesName ?? item.name) : item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if item.kind == .episode {
                        Text([item.episodeCode, item.name].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(width: MediaServerLayout.wideCardWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(item.playbackTitle)
        .contextMenu {
            MediaServerItemContextMenu(item: item, actions: actions)
        }
    }
}

private struct MediaServerLibraryTile: View {
    let library: MediaServerLibrary
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                MediaServerArtwork(
                    url: library.imageURL,
                    aspectRatio: 16 / 9,
                    systemImage: library.kind == .shows ? "tv" : "film.stack",
                    isHovered: isHovered
                )
                Text(library.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
            .frame(width: 200, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MediaServerItemContextMenu: View {
    let item: MediaServerItem
    let actions: MediaServerItemActions

    var body: some View {
        if item.isPlayable {
            Button {
                actions.play(item, false)
            } label: {
                Label("Play", systemImage: "play")
            }
            Button {
                actions.play(item, true)
            } label: {
                Label("Play from Beginning", systemImage: "backward.end")
            }
        } else {
            Button {
                actions.open(item)
            } label: {
                Label("Open", systemImage: "arrow.right.circle")
            }
        }

        Divider()

        if item.isPlayed {
            Button {
                actions.setPlayed(item, false)
            } label: {
                Label("Mark as Unwatched", systemImage: "circle")
            }
        } else {
            Button {
                actions.setPlayed(item, true)
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
        }

        Button {
            actions.openInBrowser(item)
        } label: {
            Label("Open in Browser", systemImage: "safari")
        }
    }
}

/// Remote artwork with a placeholder, playback progress and watched state.
private struct MediaServerArtwork: View {
    let url: URL?
    let aspectRatio: CGFloat
    let systemImage: String
    var progress: Double?
    var isPlayed = false
    var badge: String?
    var isHovered = false
    var showsPlayGlyph = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MediaServerLayout.cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape.fill(.quaternary)
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tertiary)
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(shape)
        .overlay(alignment: .bottom) {
            if let progress, progress > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.35))
                        Capsule().fill(Color.accentColor)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 8)
                .padding(.bottom, 7)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isPlayed {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor, in: Circle())
                    .padding(7)
                    .accessibilityLabel(Text("Watched"))
            } else if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Color.accentColor, in: Capsule())
                    .padding(7)
            }
        }
        .overlay {
            if isHovered, showsPlayGlyph {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .glassEffect(.regular.tint(.black.opacity(0.25)), in: Circle())
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .overlay {
            shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(isHovered ? 0.3 : 0.14), radius: isHovered ? 10 : 4, y: isHovered ? 5 : 2)
        .scaleEffect(isHovered ? 1.015 : 1)
        .animation(.snappy(duration: 0.18), value: isHovered)
    }
}
