import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoLibraryView: View {
    let onOpenVideo: (VideoPlaybackSource, URL?, Bool) -> Void
    let onOpenRemoteVideo: (RemoteVideoWindowOpenRequest) -> Void
    private let thumbnailScheduler = VideoThumbnailScheduler.shared

    @State private var viewModel = VideoLibraryViewModel()
    @State private var isReadyForSourceActions = false
    @State private var isManagingSources = false
    @State private var isAddingLink = false
    @State private var pendingResolvedRemoteSource: ResolvedRemoteVideoSource?
    @State private var collapsedSectionIDs: Set<String> = []
    @State private var pendingCollectionDeletion: VideoLibraryCollection?
    @State private var openTask: Task<Void, Never>?
    @State private var availableContentWidth: CGFloat = .infinity
    @State private var mediaServers = MediaServerAccountStore.shared
    @State private var selectedMediaServerID: UUID?
    @State private var mediaServerBrowsers: [UUID: MediaServerBrowserModel] = [:]
    @State private var isAddingMediaServer = false
    @State private var mediaServerNeedingSignIn: MediaServerAccount?
    @State private var pendingMediaServerRemoval: MediaServerAccount?
    @AppStorage("videoLibraryLayoutMode") private var storedLayoutMode = VideoLibraryLayoutMode.posters.rawValue
    @AppStorage("videoLibraryPosterWidth") private var posterSize = Double(BookshelfLayout.v050CoverWidth)

    var body: some View {
        content
            .toolbar {
                videoToolbarContent
            }
            .searchable(
                text: searchTextBinding,
                placement: .toolbar,
                prompt: selectedMediaServerBrowser == nil ? Text("Search Videos") : Text("Search Server")
            )
            .sheet(isPresented: $isAddingMediaServer) {
                MediaServerSignInSheet { account in
                    selectMediaServer(account.id)
                }
            }
            .sheet(item: $mediaServerNeedingSignIn) { account in
                MediaServerSignInSheet(existingAccount: account) { account in
                    mediaServerBrowsers[account.id] = nil
                    selectMediaServer(account.id)
                }
            }
            .confirmationDialog(
                "Remove Media Server?",
                isPresented: mediaServerRemovalBinding,
                titleVisibility: .visible,
                presenting: pendingMediaServerRemoval
            ) { account in
                Button("Remove", role: .destructive) {
                    Task { await mediaServers.remove(account.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { account in
                Text("Niratan signs out of \(account.displayName). Media on the server is not changed.")
            }
            .onChange(of: mediaServers.accounts) { _, accounts in
                pruneMediaServerBrowsers(accounts: accounts)
            }
            .alert("Error", isPresented: $viewModel.shouldShowError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .alert("Delete Collection?", isPresented: collectionDeletionAlertBinding) {
                Button("Delete Collection", role: .destructive) {
                    if let collection = pendingCollectionDeletion {
                        deleteCollection(collection)
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingCollectionDeletion = nil
                }
            } message: {
                Text("This removes the collection but keeps its videos in your library.")
            }
            .overlay {
                if viewModel.isScanning {
                    LoadingOverlay(String(localized: "Scanning Video Folders..."))
                }
            }
            .sheet(isPresented: $isManagingSources) {
                VideoLibrarySourceManagementView(viewModel: viewModel)
            }
            .sheet(
                isPresented: $isAddingLink,
                onDismiss: openResolvedRemoteSourceAfterSheetDismissal
            ) {
                RemoteVideoLinkSheet { resolvedSource in
                    _ = viewModel.addRemoteItem(resolvedSource)
                    pendingResolvedRemoteSource = resolvedSource
                }
            }
            .onAppear {
                viewModel.layoutMode = VideoLibraryLayoutMode(rawValue: storedLayoutMode) ?? .posters
                viewModel.load()
                viewModel.refreshPlaybackHistory()
                armSourceActions()
            }
            .onChange(of: viewModel.layoutMode) { _, layoutMode in
                storedLayoutMode = layoutMode.rawValue
            }
            .onDisappear {
                openTask?.cancel()
                openTask = nil
                viewModel.cancelPendingOpen()
                isReadyForSourceActions = false
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: VideoPlaybackHistoryStore.didChangeNotification
                )
            ) { notification in
                viewModel.refreshPlaybackHistory(
                    changedIdentityPersistenceKey: VideoPlaybackHistoryStore
                        .changedIdentityPersistenceKey(from: notification)
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: VideoLibraryStore.remoteItemDidResolveNotification
                )
            ) { _ in
                viewModel.load()
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                availableContentWidth = width
            }
    }

    /// Mirrors the Bookshelf and Manga toolbars: one system group, with source
    /// actions folded into the trailing add menu.
    @ToolbarContentBuilder
    private var videoToolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let browser = selectedMediaServerBrowser {
                if !showsLibrarySidebar {
                    mediaServerMenu
                }

                LibraryCoverSizeButton(width: $posterSize)

                Button {
                    Task { await browser.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(browser.state == .loading)
                .help("Refresh")

                Button {
                    isAddingMediaServer = true
                } label: {
                    Label("Add Media Server…", systemImage: "plus")
                }
                .help("Add Media Server…")
            } else {
                if !showsLibrarySidebar, !mediaServers.accounts.isEmpty {
                    mediaServerMenu
                }

                VideoLibrarySortMenu(viewModel: viewModel)

                VideoLibraryLayoutPicker(viewModel: viewModel)

                if viewModel.layoutMode == .posters {
                    LibraryCoverSizeButton(width: $posterSize)
                }

                VideoLibrarySourceToolbarButtons(
                    viewModel: viewModel,
                    onAddFolder: presentFolderImporter,
                    onAddLink: { isAddingLink = true },
                    onAddMediaServer: { isAddingMediaServer = true },
                    onManageSources: { isManagingSources = true },
                    isReadyForSourceActions: isReadyForSourceActions
                )
            }
        }
    }

    /// Narrow windows hide the sidebar, so servers are reached from here.
    private var mediaServerMenu: some View {
        Menu {
            Button {
                selectedMediaServerID = nil
            } label: {
                Label("Video Library", systemImage: "film.stack")
            }
            Section("Media Servers") {
                ForEach(mediaServers.accounts) { account in
                    Button {
                        selectMediaServer(account.id)
                    } label: {
                        Label(account.displayName, systemImage: account.kind.systemImage)
                    }
                }
            }
            Divider()
            Button("Add Media Server…") {
                isAddingMediaServer = true
            }
        } label: {
            Label("Media Servers", systemImage: "server.rack")
        }
        .help("Media Servers")
    }

    private var selectedMediaServerBrowser: MediaServerBrowserModel? {
        selectedMediaServerID.flatMap { mediaServerBrowsers[$0] }
    }

    private var searchTextBinding: Binding<String> {
        if let browser = selectedMediaServerBrowser {
            return Binding(
                get: { browser.searchText },
                set: { browser.searchText = $0 }
            )
        }
        return $viewModel.searchText
    }

    private func selectMediaServer(_ id: UUID) {
        guard let account = mediaServers.account(id: id) else { return }
        if mediaServerBrowsers[id]?.account != account {
            mediaServerBrowsers[id] = MediaServerBrowserModel(account: account)
        }
        selectedMediaServerID = id
        viewModel.selectedItemID = nil
    }

    private func pruneMediaServerBrowsers(accounts: [MediaServerAccount]) {
        let current = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        for (id, browser) in mediaServerBrowsers where current[id] != browser.account {
            mediaServerBrowsers[id] = nil
        }
        if let selectedMediaServerID {
            if current[selectedMediaServerID] == nil {
                self.selectedMediaServerID = nil
            } else if mediaServerBrowsers[selectedMediaServerID] == nil {
                selectMediaServer(selectedMediaServerID)
            }
        }
    }

    private var mediaServerRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingMediaServerRemoval != nil },
            set: { if !$0 { pendingMediaServerRemoval = nil } }
        )
    }

    @ViewBuilder
    private var content: some View {
        let sections = viewModel.sections()
        HStack(spacing: 0) {
            if showsLibrarySidebar {
                VideoLibrarySidebarView(
                    viewModel: viewModel,
                    mediaServers: mediaServers.accounts,
                    selectedMediaServerID: selectedMediaServerID,
                    onSelectMode: { mode in
                        selectedMediaServerID = nil
                        viewModel.displayMode = mode
                    },
                    onSelectMediaServer: selectMediaServer,
                    onAddMediaServer: { isAddingMediaServer = true },
                    onSignInAgain: { mediaServerNeedingSignIn = $0 },
                    onRemoveMediaServer: { pendingMediaServerRemoval = $0 }
                )
                    .frame(width: LibraryShelfLayout.sidebarWidth(for: availableContentWidth))
                    .background {
                        NativeGlassPageBackground()
                            .ignoresSafeArea(.container, edges: .top)
                    }
            }

            if let browser = selectedMediaServerBrowser {
                MediaServerBrowserView(
                    model: browser,
                    posterWidth: BookshelfLayout.clampedCoverWidth(posterSize),
                    onPlay: onOpenRemoteVideo,
                    onSignInAgain: { mediaServerNeedingSignIn = browser.account }
                )
                .id(browser.account.id)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.hasSources {
                        VideoLibraryContentHeader(
                            viewModel: viewModel,
                            count: sections.reduce(0) { $0 + $1.rows.count }
                        )
                            .environment(\.videoLibraryUsesModeMenu, !showsLibrarySidebar)
                    }

                    libraryContent(sections: sections)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if viewModel.selectedRow != nil {
                    Divider()

                    VideoLibraryInspectorView(
                        viewModel: viewModel,
                        thumbnailScheduler: thumbnailScheduler,
                        onOpen: { item in open(item, fromBeginning: false) },
                        onOpenFromBeginning: { item in open(item, fromBeginning: true) }
                    )
                    .frame(width: 300)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            NativeGlassPageBackground()
        }
    }

    /// Narrow windows already spend width on the app sidebar; the library
    /// filters then move into the header menu.
    private var showsLibrarySidebar: Bool {
        availableContentWidth >= 760
    }

    private func armSourceActions() {
        isReadyForSourceActions = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            isReadyForSourceActions = true
        }
    }

    private func presentFolderImporter() {
        guard isReadyForSourceActions else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        let response = panel.runModal()
        guard response == .OK else { return }
        viewModel.addFolders(.success(panel.urls))
    }

    @ViewBuilder
    private func libraryContent(sections: [VideoLibrarySection]) -> some View {
        if !viewModel.hasSources {
            ContentUnavailableView {
                Label("No Video Folders", systemImage: "film.stack")
            } description: {
                Text("Add a local folder to build your video bookshelf.")
            } actions: {
                Button {
                    presentFolderImporter()
                } label: {
                    Label("Add Video Folder", systemImage: "folder.badge.plus")
                }
                .disabled(!isReadyForSourceActions)

                Button {
                    isAddingMediaServer = true
                } label: {
                    Label("Add Media Server…", systemImage: "server.rack")
                }
                .disabled(!isReadyForSourceActions)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty {
            ContentUnavailableView {
                Label(LocalizedStringKey(viewModel.emptyTitleKey), systemImage: viewModel.displayMode.sidebarSystemImage)
            } description: {
                Text(LocalizedStringKey(viewModel.emptyDescriptionKey))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.layoutMode == .list {
            List {
                ForEach(sections) { section in
                    if viewModel.displayMode.usesCollapsibleSections {
                        VideoLibraryCollapsibleSectionHeader(
                            title: section.title,
                            count: section.rows.count,
                            isExpanded: sectionExpansionBinding(for: section),
                            onDeleteCollection: deleteCollectionAction(for: section)
                        )
                        .listRowSeparator(.hidden)

                        if !collapsedSectionIDs.contains(section.id) {
                            ForEach(section.rows) { row in
                                libraryListRow(row)
                            }
                        }
                    } else if shouldHideSingleSectionHeader(for: sections) {
                        ForEach(section.rows) { row in
                            libraryListRow(row)
                        }
                    } else {
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                libraryListRow(row)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(.clear)
        } else {
            VideoLibraryPosterGridView(
                sections: sections,
                selectedItemID: viewModel.selectedItemID,
                posterWidth: VideoLibraryPosterLayout.posterWidth(forCoverSize: posterSize),
                thumbnailScheduler: thumbnailScheduler,
                hidesSingleSectionHeader: shouldHideSingleSectionHeader(for: sections),
                usesCollapsibleSections: viewModel.displayMode.usesCollapsibleSections,
                collapsedSectionIDs: $collapsedSectionIDs,
                onOpen: { item in
                    viewModel.select(item: item)
                    open(item, fromBeginning: false)
                },
                onOpenFromBeginning: { item in
                    viewModel.select(item: item)
                    open(item, fromBeginning: true)
                },
                onSelect: viewModel.select,
                onMarkWatched: viewModel.markWatched,
                onClearProgress: viewModel.clearProgress,
                onRemoveRemote: viewModel.removeRemoteItem,
                onDeleteCollection: { collection in
                    pendingCollectionDeletion = collection
                }
            )
        }
    }

    private func libraryListRow(_ row: VideoLibraryRow) -> some View {
        VideoLibraryRowView(
            row: row,
            isSelected: row.item.id == viewModel.selectedItemID,
            thumbnailScheduler: thumbnailScheduler,
            onOpen: {
                viewModel.select(item: row.item)
                open(row.item, fromBeginning: false)
            },
            onOpenFromBeginning: {
                viewModel.select(item: row.item)
                open(row.item, fromBeginning: true)
            },
            onSelect: {
                viewModel.select(item: row.item)
            },
            onMarkWatched: {
                viewModel.markWatched(row.item)
            },
            onClearProgress: {
                viewModel.clearProgress(row.item)
            },
            onRemoveRemote: {
                viewModel.removeRemoteItem(row.item)
            }
        )
    }

    private func open(_ item: VideoLibraryItem, fromBeginning: Bool) {
        openTask?.cancel()
        viewModel.cancelPendingOpen()
        if let request = viewModel.remoteWindowOpenRequest(
            for: item,
            startsFromBeginning: fromBeginning
        ) {
            onOpenRemoteVideo(request)
            return
        }
        openTask = Task { @MainActor in
            let source = if fromBeginning {
                await viewModel.openFromBeginningPlaybackSource(for: item)
            } else {
                await viewModel.openPlaybackSource(for: item)
            }
            guard !Task.isCancelled, let source else { return }
            onOpenVideo(
                source,
                viewModel.subtitleURLForOpening(item),
                fromBeginning
            )
        }
    }

    private func openResolvedRemoteSourceAfterSheetDismissal() {
        guard let resolvedSource = pendingResolvedRemoteSource else { return }
        pendingResolvedRemoteSource = nil
        onOpenVideo(.remoteStream(resolvedSource), nil, false)
    }

    /// Grouped sections start expanded so Series, Folders, and Collections
    /// open on their videos instead of a list of closed headers.
    private func sectionExpansionBinding(for section: VideoLibrarySection) -> Binding<Bool> {
        Binding(
            get: { !collapsedSectionIDs.contains(section.id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedSectionIDs.remove(section.id)
                } else {
                    collapsedSectionIDs.insert(section.id)
                }
            }
        )
    }

    private func shouldHideSingleSectionHeader(for sections: [VideoLibrarySection]) -> Bool {
        guard sections.count == 1 else { return false }
        return sections.first?.id == duplicateSectionHeaderID
    }

    private var duplicateSectionHeaderID: String? {
        switch viewModel.displayMode {
        case .continueWatching: "continue"
        case .favorites: "favorites"
        case .unwatched: "unwatched"
        case .finished: "finished"
        case .missing: "missing"
        case .recent: "recent"
        case .all: "all"
        case .needsReview: "needs-review"
        case .series, .folders, .collections: nil
        }
    }

    private var collectionDeletionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingCollectionDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingCollectionDeletion = nil
                }
            }
        )
    }

    private func deleteCollectionAction(for section: VideoLibrarySection) -> (() -> Void)? {
        guard let collection = section.collection else { return nil }
        return {
            pendingCollectionDeletion = collection
        }
    }

    private func deleteCollection(_ collection: VideoLibraryCollection) {
        viewModel.removeCollection(id: collection.id)
        collapsedSectionIDs.remove("collection-\(collection.id.uuidString)")
        pendingCollectionDeletion = nil
    }
}

nonisolated enum VideoLibraryPosterLayout {
    static let columnSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 26
    static let sectionSpacing: CGFloat = 30
    static let artworkCornerRadius: CGFloat = 10

    /// Shares the library cover size control; 16:9 posters are wider than book covers.
    static func posterWidth(forCoverSize coverSize: Double) -> CGFloat {
        BookshelfLayout.clampedCoverWidth(coverSize) * 1.45
    }
}

/// Inner mode column styled like the Bookshelf and Manga shelf columns.
private enum VideoLibrarySidebarSelection: Hashable {
    case mode(VideoLibraryDisplayMode)
    case mediaServer(UUID)
}

private struct VideoLibrarySidebarView: View {
    @Bindable var viewModel: VideoLibraryViewModel
    let mediaServers: [MediaServerAccount]
    let selectedMediaServerID: UUID?
    let onSelectMode: (VideoLibraryDisplayMode) -> Void
    let onSelectMediaServer: (UUID) -> Void
    let onAddMediaServer: () -> Void
    let onSignInAgain: (MediaServerAccount) -> Void
    let onRemoveMediaServer: (MediaServerAccount) -> Void

    var body: some View {
        let counts = viewModel.modeCounts()
        List(selection: sidebarSelection) {
            Section {
                ForEach(VideoLibraryDisplayMode.libraryModes) { mode in
                    sidebarRow(mode, count: counts[mode])
                }
                if (counts[.missing] ?? 0) > 0 || viewModel.displayMode == .missing {
                    sidebarRow(.missing, count: counts[.missing])
                }
            }

            Section("Organization") {
                ForEach(VideoLibraryDisplayMode.organizationModes) { mode in
                    sidebarRow(mode, count: counts[mode])
                }
            }

            Section("Media Servers") {
                ForEach(mediaServers) { account in
                    Label(account.displayName, systemImage: account.kind.systemImage)
                        .help("\(account.kind.displayName) · \(account.accountSummary)")
                        .tag(VideoLibrarySidebarSelection.mediaServer(account.id))
                        .contextMenu {
                            Button("Sign In Again…") {
                                onSignInAgain(account)
                            }
                            Button("Remove", role: .destructive) {
                                onRemoveMediaServer(account)
                            }
                        }
                }

                Button(action: onAddMediaServer) {
                    Label("Add Media Server…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.clear)
    }

    private var sidebarSelection: Binding<VideoLibrarySidebarSelection?> {
        Binding(
            get: {
                selectedMediaServerID.map(VideoLibrarySidebarSelection.mediaServer)
                    ?? .mode(viewModel.displayMode)
            },
            set: { selection in
                switch selection {
                case .mode(let mode):
                    onSelectMode(mode)
                case .mediaServer(let id):
                    onSelectMediaServer(id)
                case nil:
                    break
                }
            }
        )
    }

    private func sidebarRow(_ mode: VideoLibraryDisplayMode, count: Int?) -> some View {
        Label(LocalizedStringKey(mode.titleKey), systemImage: mode.sidebarSystemImage)
            .badge(count ?? 0)
            .tag(VideoLibrarySidebarSelection.mode(mode))
    }
}

private extension VideoLibraryDisplayMode {
    static let libraryModes: [VideoLibraryDisplayMode] = [
        .continueWatching, .recent, .all, .unwatched, .finished, .favorites,
    ]
    static let organizationModes: [VideoLibraryDisplayMode] = [
        .series, .folders, .collections, .needsReview,
    ]

    var sidebarSystemImage: String {
        switch self {
        case .continueWatching: "play.circle"
        case .unwatched: "circle.dashed"
        case .finished: "checkmark.circle"
        case .missing: "exclamationmark.triangle"
        case .recent: "clock"
        case .all: "film.stack"
        case .needsReview: "tray"
        case .favorites: "star"
        case .series: "rectangle.stack"
        case .collections: "square.stack"
        case .folders: "folder"
        }
    }
}

private extension VideoLibrarySortOption {
    var systemImageName: String {
        switch self {
        case .recentPlayback: "clock"
        case .title: "textformat"
        case .modifiedDate: "calendar"
        case .folder: "folder"
        }
    }
}

private extension EnvironmentValues {
    @Entry var videoLibraryUsesModeMenu = false
}

private struct VideoLibrarySortMenu: View {
    @Bindable var viewModel: VideoLibraryViewModel

    var body: some View {
        Menu {
            Picker("Sort Videos", selection: $viewModel.sortOption) {
                ForEach(VideoLibrarySortOption.allCases) { option in
                    Label(LocalizedStringKey(option.titleKey), systemImage: option.systemImageName)
                        .tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort Videos", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort Videos")
    }
}

private struct VideoLibraryLayoutPicker: View {
    @Bindable var viewModel: VideoLibraryViewModel

    var body: some View {
        Picker("Video Library View", selection: $viewModel.layoutMode) {
            ForEach(VideoLibraryLayoutMode.allCases) { layoutMode in
                Image(systemName: layoutMode.systemImageName)
                    .accessibilityLabel(Text(LocalizedStringKey(layoutMode.titleKey)))
                    .tag(layoutMode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Video Library View")
    }
}

private struct VideoLibrarySourceToolbarButtons: View {
    @Bindable var viewModel: VideoLibraryViewModel
    let onAddFolder: () -> Void
    let onAddLink: () -> Void
    let onAddMediaServer: () -> Void
    let onManageSources: () -> Void
    let isReadyForSourceActions: Bool

    var body: some View {
        Button {
            viewModel.refreshAllSources()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(!viewModel.hasSources || viewModel.isScanning)
        .help("Refresh")

        Button {
            onManageSources()
        } label: {
            Label("Manage Sources", systemImage: "folder.badge.gearshape")
        }
        .disabled(!viewModel.hasSources)
        .help("Manage Sources")

        Menu {
            Button {
                onAddFolder()
            } label: {
                Label("Add Video Folder", systemImage: "folder.badge.plus")
            }

            Button {
                onAddLink()
            } label: {
                Label("Add Link", systemImage: "link.badge.plus")
            }

            Button {
                onAddMediaServer()
            } label: {
                Label("Add Media Server…", systemImage: "server.rack")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .disabled(!isReadyForSourceActions)
        .help("Add")
    }
}

/// Title row above the videos, matching the shelf detail header. Narrow
/// windows hide the mode column, so the title becomes the mode menu.
private struct VideoLibraryContentHeader: View {
    @Bindable var viewModel: VideoLibraryViewModel
    let count: Int
    @Environment(\.videoLibraryUsesModeMenu) private var usesModeMenu

    var body: some View {
        Group {
            if usesModeMenu {
                Menu {
                    Picker("Video Library", selection: $viewModel.displayMode) {
                        modeItems(VideoLibraryDisplayMode.libraryModes + [.missing])
                    }
                    .pickerStyle(.inline)
                    Picker("Organization", selection: $viewModel.displayMode) {
                        modeItems(VideoLibraryDisplayMode.organizationModes)
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        header
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing)
            } else {
                header
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var header: some View {
        LibraryShelfDetailHeader(
            title: Text(LocalizedStringKey(viewModel.displayMode.titleKey)),
            count: count
        )
    }

    private func modeItems(_ modes: [VideoLibraryDisplayMode]) -> some View {
        ForEach(modes) { mode in
            Label(LocalizedStringKey(mode.titleKey), systemImage: mode.sidebarSystemImage)
                .tag(mode)
        }
    }
}

struct RemoteVideoLinkSheet: View {
    let onResolved: (ResolvedRemoteVideoSource) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rawURL = ""
    @State private var isResolving = false
    @State private var errorMessage: String?
    @State private var resolutionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("YouTube Video")
                    .font(.headline)

                Text("Experimental")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.14), in: Capsule())
            }

            Text("YouTube playback is experimental and may stop working when YouTube changes its service.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Open Link", text: $rawURL)
                .textFieldStyle(.roundedBorder)
                .disabled(isResolving)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    resolutionTask?.cancel()
                    dismiss()
                }

                Button {
                    resolve()
                } label: {
                    if isResolving {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Resolving Link...")
                        }
                    } else {
                        Text("Add Link")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isResolving || URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear {
            resolutionTask?.cancel()
            resolutionTask = nil
        }
    }

    private func resolve() {
        let cleaned = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned) else { return }
        isResolving = true
        errorMessage = nil
        resolutionTask?.cancel()
        resolutionTask = Task { @MainActor in
            do {
                let resolved = try await RemoteVideoResolverRegistry().resolve(url: url)
                guard !Task.isCancelled else { return }
                onResolved(resolved)
                dismiss()
            } catch {
                guard !Task.isCancelled,
                      !(error is CancellationError) else {
                    return
                }
                if let resolverError = error as? RemoteVideoResolverError,
                   case .cancelled = resolverError {
                    return
                }
                errorMessage = error.localizedDescription
                isResolving = false
            }
        }
    }
}

private struct VideoLibraryPosterGridView: View {
    let sections: [VideoLibrarySection]
    let selectedItemID: String?
    let posterWidth: CGFloat
    let thumbnailScheduler: VideoThumbnailScheduler
    let hidesSingleSectionHeader: Bool
    let usesCollapsibleSections: Bool
    @Binding var collapsedSectionIDs: Set<String>
    let onOpen: (VideoLibraryItem) -> Void
    let onOpenFromBeginning: (VideoLibraryItem) -> Void
    let onSelect: (VideoLibraryItem) -> Void
    let onMarkWatched: (VideoLibraryItem) -> Void
    let onClearProgress: (VideoLibraryItem) -> Void
    let onRemoveRemote: (VideoLibraryItem) -> Void
    let onDeleteCollection: (VideoLibraryCollection) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: VideoLibraryPosterLayout.sectionSpacing) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if usesCollapsibleSections {
                            VideoLibraryCollapsibleSectionHeader(
                                title: section.title,
                                count: section.rows.count,
                                isExpanded: sectionExpansionBinding(for: section),
                                onDeleteCollection: deleteCollectionAction(for: section)
                            )
                        } else if !hidesSingleSectionHeader {
                            VideoLibraryPosterSectionHeader(title: section.title)
                        }

                        if !collapsedSectionIDs.contains(section.id) {
                            posterGrid(for: section)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: posterWidth, maximum: posterWidth * 1.5),
                spacing: VideoLibraryPosterLayout.columnSpacing,
                alignment: .top
            )
        ]
    }

    private func posterGrid(for section: VideoLibrarySection) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: VideoLibraryPosterLayout.rowSpacing) {
            ForEach(section.rows) { row in
                VideoLibraryPosterCardView(
                    row: row,
                    isSelected: row.item.id == selectedItemID,
                    thumbnailScheduler: thumbnailScheduler,
                    thumbnailRequestMode: .generateIfMissing,
                    onOpen: { onOpen(row.item) },
                    onOpenFromBeginning: { onOpenFromBeginning(row.item) },
                    onSelect: { onSelect(row.item) },
                    onMarkWatched: { onMarkWatched(row.item) },
                    onClearProgress: { onClearProgress(row.item) },
                    onRemoveRemote: { onRemoveRemote(row.item) }
                )
            }
        }
    }

    private func sectionExpansionBinding(for section: VideoLibrarySection) -> Binding<Bool> {
        Binding(
            get: { !collapsedSectionIDs.contains(section.id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedSectionIDs.remove(section.id)
                } else {
                    collapsedSectionIDs.insert(section.id)
                }
            }
        )
    }

    private func deleteCollectionAction(for section: VideoLibrarySection) -> (() -> Void)? {
        guard let collection = section.collection else { return nil }
        return {
            onDeleteCollection(collection)
        }
    }
}

private struct VideoLibraryPosterSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }
}

private struct VideoLibraryCollapsibleSectionHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    let onDeleteCollection: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)

                    Text(count, format: .number)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(Self.videoCountText(count)))
            .accessibilityHint(Text(isExpanded ? "Collapse" : "Expand"))

            if let onDeleteCollection {
                VideoLibraryCollectionActionsMenu(onDeleteCollection: onDeleteCollection)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private static func videoCountText(_ count: Int) -> String {
        String(format: String(localized: "%d videos"), count)
    }
}

private struct VideoLibraryCollectionActionsMenu: View {
    let onDeleteCollection: () -> Void

    var body: some View {
        Menu {
            Button(role: .destructive, action: onDeleteCollection) {
                Label("Delete Collection", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
                .modifier(VideoLibraryCollectionActionsGlassEffect())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Collection Actions")
        .accessibilityLabel(Text("Collection Actions"))
    }
}

private struct VideoLibraryCollectionActionsGlassEffect: ViewModifier {
    func body(content: Content) -> some View {
        GlassEffectContainer(spacing: 0) {
            content
                .foregroundStyle(.secondary)
                .glassEffect(.regular.interactive(), in: Circle())
        }
    }
}

/// Playback wording shared by poster badges, list rows, and the inspector.
private enum VideoLibraryPlaybackText {
    static func state(for row: VideoLibraryRow) -> String? {
        guard let state = row.playbackState else { return nil }
        if state.isFinished {
            return String(localized: "Watched")
        }
        if let remaining = state.remainingTime {
            return String(
                format: String(localized: "%@ left"),
                VideoTimeFormatter.string(from: remaining)
            )
        }
        return VideoTimeFormatter.string(from: state.position)
    }

    /// Where the video lives, without repeating the library source for local folders.
    static func location(for row: VideoLibraryRow) -> String {
        guard row.item.localURL != nil else { return row.sourceName }
        return [
            row.item.parentFolder,
            fileSizeFormatter.string(fromByteCount: row.item.fileSize),
        ]
        .joined(separator: " · ")
    }

    static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

private struct VideoLibraryPosterCardView: View {
    let row: VideoLibraryRow
    let isSelected: Bool
    let thumbnailScheduler: VideoThumbnailScheduler
    let thumbnailRequestMode: VideoThumbnailRequestMode
    let onOpen: () -> Void
    let onOpenFromBeginning: () -> Void
    let onSelect: () -> Void
    let onMarkWatched: () -> Void
    let onClearProgress: () -> Void
    let onRemoveRemote: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 9) {
                    VideoLibraryPosterArtworkView(
                        row: row,
                        thumbnailScheduler: thumbnailScheduler,
                        requestMode: thumbnailRequestMode,
                        isHovered: isHovered,
                        isSelected: isSelected
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .help(row.displayTitle)

                        Text(VideoLibraryPlaybackText.location(for: row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Hover reveals it; selection keeps it reachable without a pointer.
            if isHovered || isSelected {
                VideoLibraryDetailsButton(onSelect: onSelect, isArtworkOverlay: true)
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: isHovered || isSelected)
        .onHover { isHovered = $0 }
        .contextMenu {
            VideoLibraryItemContextMenu(
                row: row,
                onSelect: onSelect,
                onOpenFromBeginning: onOpenFromBeginning,
                onMarkWatched: onMarkWatched,
                onClearProgress: onClearProgress,
                onRemoveRemote: onRemoveRemote
            )
        }
    }
}

private struct VideoLibraryItemContextMenu: View {
    let row: VideoLibraryRow
    let onSelect: () -> Void
    let onOpenFromBeginning: () -> Void
    let onMarkWatched: () -> Void
    let onClearProgress: () -> Void
    let onRemoveRemote: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Label("Details", systemImage: "info.circle")
        }

        Divider()

        Button(action: onOpenFromBeginning) {
            Label("Play from Beginning", systemImage: "backward.end")
        }

        Button(action: onMarkWatched) {
            Label("Mark as Watched", systemImage: "checkmark.circle")
        }

        Button(action: onClearProgress) {
            Label("Clear Progress", systemImage: "xmark.circle")
        }
        .disabled(row.playbackState == nil)

        if let localURL = row.item.localURL {
            Divider()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([localURL])
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }
        } else {
            Divider()

            Button(role: .destructive, action: onRemoveRemote) {
                Label("Remove from Library", systemImage: "trash")
            }
        }
    }
}

/// 16:9 artwork with playback state drawn on the frame itself, so the card
/// needs no surrounding box.
private struct VideoLibraryPosterArtworkView: View {
    let row: VideoLibraryRow
    let thumbnailScheduler: VideoThumbnailScheduler
    let requestMode: VideoThumbnailRequestMode
    let isHovered: Bool
    let isSelected: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: VideoLibraryPosterLayout.artworkCornerRadius, style: .continuous)
    }

    var body: some View {
        VideoThumbnailImageView(
            item: row.item,
            remoteThumbnailURL: row.remoteThumbnailURL,
            parentFolder: row.item.parentFolder,
            scheduler: thumbnailScheduler,
            requestMode: requestMode,
            cornerRadius: VideoLibraryPosterLayout.artworkCornerRadius
        )
        .overlay {
            if hasPlaybackOverlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.62)],
                    startPoint: UnitPoint(x: 0.5, y: 0.45),
                    endPoint: .bottom
                )
            }
        }
        .overlay(alignment: .topLeading) {
            if row.metadata.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.yellow)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(8)
                    .accessibilityLabel(Text("Favorite"))
            }
        }
        .overlay(alignment: .bottom) {
            playbackOverlay
        }
        .overlay {
            if isHovered {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .glassEffect(.regular.tint(.black.opacity(0.25)), in: Circle())
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(
                    cornerRadius: VideoLibraryPosterLayout.artworkCornerRadius + 3,
                    style: .continuous
                )
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                .padding(-4)
            }
        }
        .shadow(color: .black.opacity(isHovered ? 0.32 : 0.16), radius: isHovered ? 12 : 4, y: isHovered ? 6 : 2)
        .scaleEffect(isHovered ? 1.015 : 1)
        .animation(.snappy(duration: 0.18), value: isHovered)
    }

    private var hasPlaybackOverlay: Bool {
        row.playbackState != nil
    }

    @ViewBuilder
    private var playbackOverlay: some View {
        if let state = row.playbackState {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if state.isFinished {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                    }
                    if let text = VideoLibraryPlaybackText.state(for: row) {
                        Text(text)
                            .monospacedDigit()
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)

                if !state.isFinished, let progress = state.progress {
                    VideoLibraryProgressTrack(progress: progress)
                }
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 8)
        }
    }
}

private struct VideoThumbnailImageView: View {
    let item: VideoLibraryItem
    let remoteThumbnailURL: URL?
    let parentFolder: String
    let scheduler: VideoThumbnailScheduler
    let requestMode: VideoThumbnailRequestMode
    let cornerRadius: CGFloat

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            VideoThumbnailPlaceholderView(parentFolder: parentFolder, cornerRadius: cornerRadius)

            if let remoteThumbnailURL {
                AsyncImage(url: remoteThumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: thumbnailTaskID) {
            image = nil
            guard remoteThumbnailURL == nil, item.localURL != nil else { return }
            guard let url = await scheduler.thumbnailURL(
                for: item,
                requestMode: requestMode
            ) else {
                return
            }
            image = NSImage(contentsOf: url)
        }
    }

    private var thumbnailTaskID: String {
        "\(remoteThumbnailURL?.absoluteString ?? VideoThumbnailStore.cacheKey(for: item))-\(requestMode.taskIdentity)"
    }
}

private struct VideoThumbnailPlaceholderView: View {
    let parentFolder: String
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary)

            Image(systemName: "film")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .accessibilityLabel(Text(parentFolder))
    }
}

private struct VideoLibraryProgressTrack: View {
    let progress: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.32))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(height, proxy.size.width * clampedProgress))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text(clampedProgress, format: .percent.precision(.fractionLength(0))))
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
}

private struct VideoLibraryRowView: View {
    let row: VideoLibraryRow
    let isSelected: Bool
    let thumbnailScheduler: VideoThumbnailScheduler
    let onOpen: () -> Void
    let onOpenFromBeginning: () -> Void
    let onSelect: () -> Void
    let onMarkWatched: () -> Void
    let onClearProgress: () -> Void
    let onRemoveRemote: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    VideoThumbnailImageView(
                        item: row.item,
                        remoteThumbnailURL: row.remoteThumbnailURL,
                        parentFolder: row.item.parentFolder,
                        scheduler: thumbnailScheduler,
                        requestMode: .generateIfMissing,
                        cornerRadius: 7
                    )
                    .overlay(alignment: .bottom) {
                        if let state = row.playbackState, !state.isFinished, let progress = state.progress {
                            VideoLibraryProgressTrack(progress: progress, height: 3)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 5)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
                    }
                    .frame(width: 120, height: 67.5)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            if row.metadata.isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                                    .accessibilityLabel(Text("Favorite"))
                            }

                            Text(row.displayTitle)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.body.weight(.medium))
                                .help(row.displayTitle)
                        }

                        ViewThatFits(in: .horizontal) {
                            metadataLine(includesDetails: true)
                            metadataLine(includesDetails: false)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    stateLabel
                        .frame(minWidth: 84, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            VideoLibraryDetailsButton(onSelect: onSelect)
                .opacity(isHovered || isSelected ? 1 : 0)
        }
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .padding(.horizontal, 6)
                : nil
        )
        .contextMenu {
            VideoLibraryItemContextMenu(
                row: row,
                onSelect: onSelect,
                onOpenFromBeginning: onOpenFromBeginning,
                onMarkWatched: onMarkWatched,
                onClearProgress: onClearProgress,
                onRemoveRemote: onRemoveRemote
            )
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        if let state = row.playbackState, let text = VideoLibraryPlaybackText.state(for: row) {
            if state.isFinished {
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(VideoLibraryTrailingIconLabelStyle())
            } else {
                Text(text)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// Drops the folder and date first so narrow rows keep the source and size readable.
    private func metadataLine(includesDetails: Bool) -> some View {
        HStack(spacing: 5) {
            Text(row.sourceName)
            if row.item.localURL != nil {
                if includesDetails {
                    separator
                    Text(row.item.parentFolder)
                }
                separator
                Text(VideoLibraryPlaybackText.fileSizeFormatter.string(fromByteCount: row.item.fileSize))
                if includesDetails, let modifiedAt = row.item.modifiedAt {
                    separator
                    Text(modifiedAt, style: .date)
                }
            }
        }
    }

    private var separator: some View {
        Text(verbatim: "·")
            .foregroundStyle(.tertiary)
    }
}

private struct VideoLibraryTrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

private struct VideoLibraryDetailsButton: View {
    let onSelect: () -> Void
    var isArtworkOverlay = false

    var body: some View {
        if isArtworkOverlay {
            Button(action: onSelect) {
                Image(systemName: "info")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(VideoLibraryInspectorIconButtonStyle())
            .help("Details")
            .accessibilityLabel(Text("Details"))
        } else {
            Button(action: onSelect) {
                Label("Details", systemImage: "info.circle")
                    .font(.body)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Details")
            .accessibilityLabel(Text("Details"))
        }
    }
}

private struct VideoLibraryInspectorView: View {
    @Bindable var viewModel: VideoLibraryViewModel
    let thumbnailScheduler: VideoThumbnailScheduler
    let onOpen: (VideoLibraryItem) -> Void
    let onOpenFromBeginning: (VideoLibraryItem) -> Void

    @State private var titleDraft = ""
    @State private var tagsDraft = ""
    @State private var collectionNameDraft = ""
    @State private var smartCollectionNameDraft = ""
    @State private var smartCollectionRuleField: VideoLibrarySmartRuleField = .fileName
    @State private var smartCollectionRuleDraft = ""
    @State private var isBindingSubtitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Video Details")
                    .font(.headline)

                Spacer()

                Button {
                    viewModel.clearSelection()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .help("Close")
                .accessibilityLabel(Text("Close"))
                .buttonStyle(VideoLibraryInspectorIconButtonStyle())
            }

            if let row = viewModel.selectedRow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summary(row)
                        inspectorSections(row)
                    }
                }
                .scrollIndicators(.automatic)
            } else {
                ContentUnavailableView {
                    Label("Details", systemImage: "sidebar.right")
                } description: {
                    Text("Select a video to edit its local metadata.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .fileImporter(
            isPresented: $isBindingSubtitle,
            allowedContentTypes: Self.subtitleContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard let item = viewModel.selectedRow?.item,
                  let subtitleURL = try? result.get().first else {
                return
            }
            viewModel.bindSubtitle(subtitleURL, for: item)
        }
        .onChange(of: viewModel.selectedItemID, initial: true) { _, _ in
            syncDrafts()
        }
    }

    /// Artwork, title, and play actions for the selected video.
    private func summary(_ row: VideoLibraryRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoThumbnailImageView(
                item: row.item,
                remoteThumbnailURL: row.remoteThumbnailURL,
                parentFolder: row.item.parentFolder,
                scheduler: thumbnailScheduler,
                requestMode: .generateIfMissing,
                cornerRadius: VideoLibraryPosterLayout.artworkCornerRadius
            )
            .overlay(alignment: .bottom) {
                if let state = row.playbackState, !state.isFinished, let progress = state.progress {
                    VideoLibraryProgressTrack(progress: progress)
                        .padding(8)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: VideoLibraryPosterLayout.artworkCornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(row.displayTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)

                Text(VideoLibraryPlaybackText.location(for: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let stateText = VideoLibraryPlaybackText.state(for: row) {
                    Text(stateText)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(row.playbackState?.isFinished == true ? Color.secondary : Color.accentColor)
                }
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        onOpen(row.item)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    Button {
                        onOpenFromBeginning(row.item)
                    } label: {
                        Label("Play from Beginning", systemImage: "backward.end.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Play from Beginning")
                    .disabled(row.playbackState == nil)
                }
            }
        }
    }

    @ViewBuilder
    private func inspectorSections(_ row: VideoLibraryRow) -> some View {
        GlassEffectContainer(spacing: 12) {
            inspectorSectionStack(row)
        }
    }

    private func inspectorSectionStack(_ row: VideoLibraryRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            metadataSection(row)
            subtitleSection(row)
            collectionsSection(row)
            smartCollectionsSection(row)
            batchSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataSection(_ row: VideoLibraryRow) -> some View {
        VideoLibraryInspectorCard {
            TextField("Display Title", text: $titleDraft)
                .videoLibraryInspectorInput()

            HStack(spacing: 8) {
                Label("Favorite", systemImage: "star")
                Spacer(minLength: 8)
                Toggle("Favorite", isOn: Binding(
                    get: { viewModel.selectedRow?.metadata.isFavorite ?? false },
                    set: { isFavorite in
                        viewModel.setFavorite(isFavorite, for: row.item)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 4)

            TextField("Tags", text: $tagsDraft)
                .videoLibraryInspectorInput()
                .help("Tags")

            Button {
                viewModel.setDisplayTitle(titleDraft, for: row.item)
                viewModel.setTags(Self.tags(from: tagsDraft), for: row.item)
                syncDrafts()
            } label: {
                Label("Save Metadata", systemImage: "checkmark")
            }
            .buttonStyle(VideoLibraryInspectorActionButtonStyle())
        }
    }

    private func subtitleSection(_ row: VideoLibraryRow) -> some View {
        VideoLibraryInspectorCard {
            Text("Bound Subtitle")
                .font(.subheadline.weight(.semibold))

            if let boundSubtitleURL = row.boundSubtitleURL {
                Text(boundSubtitleURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    viewModel.bindSubtitle(nil, for: row.item)
                } label: {
                    Label("Clear Subtitle", systemImage: "xmark.circle")
                }
                .buttonStyle(VideoLibraryInspectorActionButtonStyle())
            } else if let subtitleCandidateURL = row.subtitleCandidateURL {
                Label(
                    "\(String(localized: "Auto Subtitle")): \(subtitleCandidateURL.lastPathComponent)",
                    systemImage: "captions.bubble"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else {
                Text("Auto Subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                isBindingSubtitle = true
            } label: {
                Label("Bind Subtitle", systemImage: "captions.bubble")
            }
            .buttonStyle(VideoLibraryInspectorActionButtonStyle())
        }
    }

    private func collectionsSection(_ row: VideoLibraryRow) -> some View {
        VideoLibraryInspectorCard {
            Text("Collections")
                .font(.subheadline.weight(.semibold))

            ForEach(viewModel.catalog.collections.filter { $0.kind == .manual }) { collection in
                Toggle(collection.name, isOn: Binding(
                    get: {
                        viewModel.selectedRow?.metadata.collectionIDs.contains(collection.id) ?? false
                    },
                    set: { isIncluded in
                        viewModel.setCollectionMembership(
                            isIncluded,
                            collectionID: collection.id,
                            for: row.item
                        )
                    }
                ))
            }

            HStack(spacing: 8) {
                TextField("New Collection", text: $collectionNameDraft)
                    .videoLibraryInspectorInput()

                Button {
                    _ = viewModel.createCollection(name: collectionNameDraft, items: [row.item])
                    collectionNameDraft = ""
                } label: {
                    Label("Add Collection", systemImage: "plus")
                }
                .buttonStyle(VideoLibraryInspectorActionButtonStyle())
                .disabled(collectionNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func smartCollectionsSection(_ row: VideoLibraryRow) -> some View {
        VideoLibraryInspectorCard {
            Text("Smart Collections")
                .font(.subheadline.weight(.semibold))

            ForEach(viewModel.catalog.collections.filter { $0.kind == .smart }) { collection in
                HStack(spacing: 8) {
                    Label(collection.name, systemImage: "line.3.horizontal.decrease.circle")
                        .lineLimit(1)
                    Spacer()
                    Text("Smart")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Label("New Smart Collection", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("New Smart Collection", text: $smartCollectionNameDraft)
                .videoLibraryInspectorInput()

            HStack(spacing: 8) {
                Text("Rule Field")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                NativeGlassMenuPicker(
                    selection: $smartCollectionRuleField,
                    values: VideoLibrarySmartRuleField.smartCollectionEditorFields,
                    minWidth: 96
                ) { field in
                    Text(LocalizedStringKey(field.smartCollectionTitleKey))
                }
            }
            .padding(.leading, 4)

            TextField("Rule Text", text: $smartCollectionRuleDraft)
                .videoLibraryInspectorInput()

            if !smartCollectionDraftRules.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Preview Matches")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    let previewRows = viewModel.smartCollectionPreviewRows(
                        rules: smartCollectionDraftRules,
                        limit: 5
                    )
                    if previewRows.isEmpty {
                        Text("No Matching Videos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(previewRows) { previewRow in
                            Text(previewRow.displayTitle)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Button {
                _ = viewModel.createSmartCollection(
                    name: smartCollectionNameDraft,
                    rules: smartCollectionDraftRules
                )
                smartCollectionNameDraft = ""
                smartCollectionRuleDraft = ""
            } label: {
                Label("Add Smart Collection", systemImage: "plus")
            }
            .buttonStyle(VideoLibraryInspectorActionButtonStyle())
            .disabled(
                smartCollectionNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || smartCollectionDraftRules.isEmpty
            )
        }
    }

    private var smartCollectionDraftRules: [VideoLibrarySmartRule] {
        let value = smartCollectionRuleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        return [
            VideoLibrarySmartRule(
                field: smartCollectionRuleField,
                match: .contains,
                value: value
            )
        ]
    }

    private var batchSection: some View {
        VideoLibraryInspectorCard {
            Button {
                viewModel.markSelectedWatched()
            } label: {
                Label("Mark Selected Watched", systemImage: "checkmark.circle")
            }
            .buttonStyle(VideoLibraryInspectorActionButtonStyle())

            Button {
                viewModel.clearSelectedProgress()
            } label: {
                Label("Clear Selected Progress", systemImage: "xmark.circle")
            }
            .buttonStyle(VideoLibraryInspectorActionButtonStyle())

            Button(role: .destructive) {
                _ = viewModel.removeMissingItems()
            } label: {
                Label("Remove Missing", systemImage: "trash")
            }
            .buttonStyle(VideoLibraryInspectorActionButtonStyle(role: .destructive))
        }
    }

    private func syncDrafts() {
        guard let row = viewModel.selectedRow else {
            titleDraft = ""
            tagsDraft = ""
            return
        }
        titleDraft = row.metadata.displayTitle ?? row.item.title
        tagsDraft = row.metadata.tags.joined(separator: ", ")
    }

    private static func tags(from value: String) -> [String] {
        value
            .split { character in
                character == "," || character == "\n"
            }
            .map(String.init)
    }

    private static let subtitleContentTypes: [UTType] = {
        let explicitTypes = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
        return explicitTypes + [.plainText, .text]
    }()
}

private struct VideoLibraryInspectorCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .videoLibraryNeutralCardSurface(cornerRadius: 14)
    }
}

private struct VideoLibraryNeutralCardSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background {
                shape
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.035 : 0.34))
                    .overlay {
                        shape.strokeBorder(.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.7)
                    }
            }
            .clipShape(shape)
    }
}

private extension View {
    func videoLibraryNeutralCardSurface(cornerRadius: CGFloat) -> some View {
        modifier(VideoLibraryNeutralCardSurface(cornerRadius: cornerRadius))
    }
}

private struct VideoLibraryInspectorActionButtonStyle: ButtonStyle {
    enum Role {
        case standard
        case destructive
    }

    var role: Role = .standard
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .frame(minHeight: 30)
            .contentShape(Capsule())
            .modifier(
                VideoLibraryInspectorButtonSurface(
                    isPressed: configuration.isPressed,
                    isEnabled: isEnabled
                )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }

    private var foregroundStyle: Color {
        guard isEnabled else { return .secondary }
        switch role {
        case .standard:
            return .primary
        case .destructive:
            return .red
        }
    }
}

private struct VideoLibraryInspectorButtonSurface: ViewModifier {
    let isPressed: Bool
    let isEnabled: Bool
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? 1 : 0.56)
            .background {
                if isPressed {
                    Capsule()
                        .fill(NativeGlassPalette.cardTint(for: userConfig, colorScheme: colorScheme))
                }
            }
            .glassEffect(.regular.interactive(), in: Capsule())
    }
}

private struct VideoLibraryInspectorIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? .secondary : .tertiary)
            .modifier(
                VideoLibraryInspectorIconButtonSurface(
                    isPressed: configuration.isPressed,
                    isEnabled: isEnabled
                )
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

private struct VideoLibraryInspectorIconButtonSurface: ViewModifier {
    let isPressed: Bool
    let isEnabled: Bool
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? 1 : 0.56)
            .background {
                if isPressed {
                    Circle()
                        .fill(NativeGlassPalette.cardTint(for: userConfig, colorScheme: colorScheme))
                }
            }
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

private struct VideoLibraryInspectorInputSurface: ViewModifier {
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background {
                shape
                    .fill(NativeGlassPalette.cardTint(for: userConfig, colorScheme: colorScheme))
                    .overlay {
                        shape.strokeBorder(NativeGlassPalette.stroke(for: colorScheme), lineWidth: 0.7)
                    }
            }
            .clipShape(shape)
            .nativeGlassInspectorInputEffect()
    }
}

private extension View {
    func videoLibraryInspectorInput() -> some View {
        modifier(VideoLibraryInspectorInputSurface())
    }

    @ViewBuilder
    func nativeGlassInspectorInputEffect() -> some View {
        self.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private extension VideoLibrarySmartRuleField {
    static let smartCollectionEditorFields: [VideoLibrarySmartRuleField] = [
        .fileName,
        .parentFolder,
        .path,
        .tag,
    ]

    var smartCollectionTitleKey: String {
        switch self {
        case .fileName:
            return "File Name"
        case .parentFolder:
            return "Parent Folder"
        case .path:
            return "Path"
        case .tag:
            return "Tag"
        case .hasBoundSubtitle:
            return "Bound Subtitle"
        case .playbackState:
            return "Watched"
        }
    }
}

private struct VideoLibrarySourceManagementView: View {
    @Bindable var viewModel: VideoLibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NativeReaderSheetPanel("Manage Sources", onClose: { dismiss() }) {
            ScrollView {
                NativeSettingsSectionCard {
                    EmptyView()
                } content: {
                    ForEach(Array(viewModel.sourceSummaries.enumerated()), id: \.element.id) { index, summary in
                        if index > 0 {
                            NativeSettingsSeparator()
                        }
                        VideoLibrarySourceRowView(
                            summary: summary,
                            isScanning: viewModel.isScanning,
                            onRefresh: {
                                viewModel.refreshSource(id: summary.id)
                            },
                            onRemove: {
                                viewModel.removeSource(id: summary.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 620, height: 420)
    }
}

private struct VideoLibrarySourceRowView: View {
    let summary: VideoLibrarySourceSummary
    let isScanning: Bool
    let onRefresh: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: summary.source.lastError == nil ? "folder" : "folder.badge.questionmark")
                .font(.title3)
                .foregroundStyle(summary.source.lastError == nil ? Color.secondary : Color.red)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.source.name)
                    .font(.body.weight(.medium))
                Text(summary.source.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(summary.source.path)

                HStack(spacing: 8) {
                    Text(Self.localizedCount("%d videos", summary.itemCount))
                    Text(Self.localizedCount("%d in progress", summary.inProgressCount))
                    if summary.missingCount > 0 {
                        Text(Self.localizedCount("%d missing", summary.missingCount))
                            .foregroundStyle(.red)
                    }
                    Text(lastScannedText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let lastError = summary.source.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button(action: onRefresh) {
                        Label("Refresh Source", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh Source")
                    .disabled(isScanning)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: summary.source.path)
                        ])
                    } label: {
                        Label("Reveal Source in Finder", systemImage: "folder")
                    }
                    .help("Reveal Source in Finder")

                    Button(role: .destructive, action: onRemove) {
                        Label("Remove", systemImage: "minus.circle")
                    }
                    .help("Remove")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(NativeSettingsActionButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var lastScannedText: String {
        guard let lastScannedAt = summary.source.lastScannedAt else {
            return String(localized: "Never scanned")
        }
        return "\(String(localized: "Last Scanned")) \(Self.scanDateFormatter.string(from: lastScannedAt))"
    }

    private static func localizedCount(_ key: String, _ count: Int) -> String {
        String(format: NSLocalizedString(key, comment: ""), count)
    }

    private static let scanDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
