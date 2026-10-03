import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeBookshelfReuseView: View {
    @Environment(UserConfig.self) private var userConfig
    @Bindable var viewModel: BookshelfViewModel
    let onOpenBook: (BookMetadata) -> Void
    @Binding var pendingImportURL: URL?
    @Binding var pendingRemoteImportURL: URL?
    @State private var isSelecting = false
    @State private var selectedBooks = Set<BookMetadata>()
    @State private var showBulkDeleteConfirmation = false
    @State private var pendingLookup: String?
    @State private var pendingTab: Int?
    @State private var searchText = ""
    @AppStorage("bookshelfCoverWidth") private var coverWidth = Double(BookshelfLayout.v050CoverWidth)
    @State private var showStatisticsDashboard = false
    @State private var showZLibrary = false

    var body: some View {
        bookshelfContent
        .onChange(of: pendingTab) { _, tab in
            guard tab != nil else { return }
            pendingTab = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerWindowProgressDidChange)) { _ in
            viewModel.loadBooks()
        }
        .onReceive(NotificationCenter.default.publisher(for: SyncStorage.booksChangedNotification)) { _ in
            viewModel.loadBooks()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var bookshelfContent: some View {
        if !viewModel.isInitialPresentationReady {
            Color.clear
        } else if showStatisticsDashboard {
            StatisticsDashboardView(books: viewModel.books, shelves: viewModel.shelves)
            .toolbar {
                toolbarContent
            }
            .onAppear {
                viewModel.loadBooks()
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerWindowProgressDidChange)) { _ in
                viewModel.loadBooks()
            }
        } else {
        BookshelfFileDropTarget(onDrop: viewModel.importDroppedEPUBs) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    shelfSidebar
                        .frame(width: LibraryShelfLayout.sidebarWidth(for: proxy.size.width))

                    shelfDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .toolbar {
            toolbarContent
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search Books"))
        .fileImporter(
            isPresented: $viewModel.isImporting,
            allowedContentTypes: [.epub],
            allowsMultipleSelection: true,
            onCompletion: viewModel.importBooks
        )
        .sheet(isPresented: $showZLibrary) {
            ZLibraryView(
                isBookAlreadyImported: { book in
                    viewModel.containsImportedBook(
                        sourceID: "zlibrary:\(book.id)",
                        isbn: book.isbn,
                        title: book.title
                    )
                },
                onImportEPUB: { url, book, details in
                    let detailsISBN = details?.isbn.trimmingCharacters(in: .whitespacesAndNewlines)
                    let searchISBN = book.isbn.trimmingCharacters(in: .whitespacesAndNewlines)
                    return try viewModel.importDownloadedBook(
                        from: url,
                        sourceID: "zlibrary:\(book.id)",
                        isbn: detailsISBN?.isEmpty == false
                            ? detailsISBN
                            : (searchISBN.isEmpty ? nil : searchISBN)
                    )
                }
            )
        }
        .alert(
            "Delete \(selectedBooks.count) book(s)?",
            isPresented: $showBulkDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                viewModel.deleteBooks(selectedBooks)
                clearSelection()
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Error", isPresented: $viewModel.shouldShowError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage)
        }
        .alert("Done", isPresented: $viewModel.shouldShowSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.successMessage)
        }
        .overlay {
            if viewModel.isSyncing {
                LoadingOverlay(String(localized: "Syncing..."))
            }
            if viewModel.isDownloading {
                LoadingOverlay(String(localized: "Downloading EPUB..."))
            }
            if let importBooksProgress = viewModel.importBooksProgress {
                LoadingOverlay(importBooksProgress)
            }
            if viewModel.isLoadingGoogleDriveBooks {
                LoadingOverlay(String(localized: "Loading Google Drive Books..."))
            }
        }
        .onAppear {
            viewModel.loadBooks()
        }
        .onChange(of: pendingImportURL, initial: true) { _, url in
            guard let url else { return }
            if ["colpkg", "apkg"].contains(url.pathExtension.lowercased()) {
                do {
                    try AnkiManager.shared.importAnkiBackup(from: url)
                } catch {
                    viewModel.errorMessage = error.localizedDescription
                    viewModel.shouldShowError = true
                }
            } else {
                viewModel.importBook(result: .success(url))
            }
            viewModel.clearInbox()
            pendingImportURL = nil
        }
        .onChange(of: pendingRemoteImportURL, initial: true) { _, url in
            guard let url else { return }
            viewModel.importRemoteBook(from: url)
            pendingRemoteImportURL = nil
        }
        .onChange(of: isSelecting) { _, selecting in
            if !selecting {
                selectedBooks.removeAll()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var shelfSidebar: some View {
        LibraryShelfSidebar(
            selection: shelfSelection,
            smartRows: shelfSmartRows,
            shelves: viewModel.shelves.map { shelf in
                LibraryShelfEntry(
                    id: shelf.name,
                    name: shelf.name,
                    count: viewModel.bookCount(for: .shelf(shelf.name))
                )
            },
            onCreate: { name in
                viewModel.createShelf(name: name)
            },
            onRename: { shelfName, newName in
                viewModel.renameShelf(shelfName, to: newName)
            },
            onDelete: { shelfName in
                viewModel.deleteShelf(name: shelfName)
            },
            onMove: viewModel.moveShelves
        )
    }

    private var shelfSelection: Binding<LibraryShelfSelection> {
        Binding {
            viewModel.resolvedShelfSelection
        } set: { selection in
            viewModel.shelfSelection = selection
        }
    }

    private var shelfSmartRows: [LibraryShelfSmartRow] {
        var rows = [
            LibraryShelfSmartRow(
                selection: .all,
                title: "All Books",
                systemImage: "books.vertical",
                count: viewModel.bookCount(for: .all)
            ),
            LibraryShelfSmartRow(
                selection: .reading,
                title: "Currently Reading",
                systemImage: "book",
                count: viewModel.bookCount(for: .reading)
            ),
            LibraryShelfSmartRow(
                selection: .unshelved,
                title: "Unshelved",
                systemImage: "tray",
                count: viewModel.bookCount(for: .unshelved)
            ),
        ]
        if !viewModel.googleDriveBooks.isEmpty {
            rows.append(LibraryShelfSmartRow(
                selection: .googleDrive,
                title: "Google Drive",
                systemImage: "icloud",
                count: viewModel.bookCount(for: .googleDrive)
            ))
        }
        return rows
    }

    @ViewBuilder
    private var shelfDetail: some View {
        if viewModel.books.isEmpty && viewModel.googleDriveBooks.isEmpty {
            ContentUnavailableView {
                Label("No Books", systemImage: "books.vertical")
            } description: {
                Text("Import an EPUB using the toolbar button to start reading.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let selection = viewModel.resolvedShelfSelection
            let section = displayedSection(for: selection)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LibraryShelfDetailHeader(
                        title: shelfTitle(for: selection),
                        count: section.books.count
                    )

                    if section.books.isEmpty, section.isFiltered {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else if section.books.isEmpty {
                        LibraryShelfEmptyView(selection: selection)
                    } else {
                        ShelfView(
                            viewModel: viewModel,
                            section: section,
                            showTitle: false,
                            isSelecting: isSelecting,
                            allowsCollapse: false,
                            selectedBooks: $selectedBooks,
                            pendingLookup: $pendingLookup,
                            pendingTab: $pendingTab,
                            onOpenBook: onOpenBook
                        )
                        .id(section.id)
                        .environment(\.shelfCoverWidth, BookshelfLayout.clampedCoverWidth(coverWidth))
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    /// The selected shelf, narrowed to titles matching the toolbar search field.
    private func displayedSection(for selection: LibraryShelfSelection) -> ShelfSection {
        var section = viewModel.shelfSection(
            for: selection,
            sortedBy: userConfig.bookshelfSortOption
        )
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return section }
        section.books = section.books.filter {
            $0.displayTitle.localizedStandardContains(query)
                || $0.title.localizedStandardContains(query)
        }
        section.isFiltered = true
        return section
    }

    private func shelfTitle(for selection: LibraryShelfSelection) -> Text {
        switch selection {
        case .all:
            Text("All Books")
        case .reading:
            Text("Currently Reading")
        case .unshelved:
            Text("Unshelved")
        case .googleDrive:
            Text("Google Drive")
        case .shelf(let name):
            Text(verbatim: name)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showStatisticsDashboard {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        showStatisticsDashboard = false
                    }
                } label: {
                    Label("Bookshelf", systemImage: "books.vertical")
                }
                .help("Bookshelf")
            }
        } else if isSelecting {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    clearSelection()
                }
                .fontWeight(.semibold)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button {
                        viewModel.moveBooks(selectedBooks, to: nil)
                        clearSelection()
                    } label: {
                        Label("None", systemImage: "tray")
                    }
                    ForEach(viewModel.shelves, id: \.name) { shelf in
                        Button {
                            viewModel.moveBooks(selectedBooks, to: shelf.name)
                            clearSelection()
                        } label: {
                            Label(shelf.name, systemImage: "folder")
                        }
                    }
                } label: {
                    Label("Move to Shelf", systemImage: "folder")
                }
                .disabled(selectedBooks.isEmpty)

                Button(role: .destructive) {
                    showBulkDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedBooks.isEmpty)
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: Bindable(userConfig).bookshelfSortOption) {
                        ForEach(SortOption.allCases) { option in
                            label(for: option)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort Books")

                Button {
                    withAnimation(.default.speed(2)) {
                        isSelecting = true
                    }
                } label: {
                    Label("Select Books", systemImage: "checklist")
                }
                .help("Select Books")

                LibraryCoverSizeButton(width: $coverWidth)

                if userConfig.enableSync && GoogleDriveAuth.shared.isAuthenticated {
                    Button {
                        Task {
                            await viewModel.loadGoogleDriveBooks()
                        }
                    } label: {
                        if viewModel.isLoadingGoogleDriveBooks {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Refresh Google Drive Books", systemImage: "icloud.and.arrow.down")
                        }
                    }
                    .disabled(viewModel.isLoadingGoogleDriveBooks)
                    .help("Refresh Google Drive Books")
                }

                if userConfig.enableStatistics {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            showStatisticsDashboard = true
                        }
                    } label: {
                        Label("Statistics", systemImage: "chart.xyaxis.line")
                    }
                    .help("Statistics")
                }

                Button {
                    showZLibrary = true
                } label: {
                    Label("Z-Library", systemImage: "books.vertical.fill")
                }
                .help("Search Z-Library")

                Button {
                    viewModel.isImporting = true
                } label: {
                    Label("Import EPUB", systemImage: "plus")
                }
                .help("Import EPUB")
            }
        }
    }

    private func clearSelection() {
        withAnimation(.default.speed(2)) {
            isSelecting = false
            selectedBooks.removeAll()
        }
    }

    private func label(for sortOption: SortOption) -> some View {
        switch sortOption {
        case .manual:
            Label(LocalizedStringKey("Sort Option Manual"), systemImage: sortOption.icon)
        case .recent:
            Label(LocalizedStringKey("Sort Option Recent"), systemImage: sortOption.icon)
        case .title:
            Label(LocalizedStringKey("Sort Option Title"), systemImage: sortOption.icon)
        }
    }
}

struct NativeDictionaryReuseView: View {
    let request: NativeDictionaryOpenRequest?

    var body: some View {
        DictionarySearchView(
            initialQuery: request?.query ?? "",
            initialAutofocus: false,
            shouldFocus: false
        )
        .id(request?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NativeSettingsReuseView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var selection: NativeSettingsSection? = .appearance

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                settingsSidebar
                    .frame(width: Self.sidebarWidth(for: proxy.size.width))
                    .background {
                        NativeGlassPageBackground()
                            .ignoresSafeArea(.container, edges: .top)
                    }

                NativeSettingsDetailView(section: selection ?? .appearance, userConfig: userConfig)
                    .id(selection ?? .appearance)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            NativeGlassPageBackground()
        }
        .navigationTitle(selection?.title ?? "Settings")
        .toolbar {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }

    /// Narrow hosts (the main window's Settings section) shrink the sidebar so the detail cards keep enough width.
    private static func sidebarWidth(for totalWidth: CGFloat) -> CGFloat {
        min(240, max(180, totalWidth * 0.28))
    }

    private var settingsSidebar: some View {
        List(selection: $selection) {
            Section("Library") {
                nativeSettingsRow(.profiles)
                nativeSettingsRow(.appearance)
                nativeSettingsRow(.dictionaries)
                nativeSettingsRow(.anki)
            }

            Section("Reader") {
                nativeSettingsRow(.audio)
                nativeSettingsRow(.statistics)
                nativeSettingsRow(.sasayaki)
            }

            Section("Video") {
                nativeSettingsRow(.video)
            }

            Section("Shortcuts & Controls") {
                nativeSettingsRow(.keyboardShortcuts)
                nativeSettingsRow(.gameController)
            }

            Section("Sync & Data") {
                nativeSettingsRow(.sync)
                nativeSettingsRow(.backup)
            }

            Section {
                nativeSettingsRow(.about)

                Link(destination: URL(string: "https://github.com/W1ght/Niratan/issues")!) {
                    Label("Report an Issue", systemImage: "exclamationmark.bubble")
                }
                .foregroundStyle(.primary)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.clear)
    }

    private func nativeSettingsRow(_ section: NativeSettingsSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }
}

enum NativeSettingsSection: String, CaseIterable, Identifiable {
    case profiles
    case appearance
    case dictionaries
    case anki
    case audio
    case statistics
    case sasayaki
    case video
    case keyboardShortcuts
    case gameController
    case sync
    case backup
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .profiles:
            "Profiles"
        case .appearance:
            "Appearance"
        case .dictionaries:
            "Dictionaries"
        case .anki:
            "Anki"
        case .audio:
            "Audio"
        case .statistics:
            "Statistics"
        case .sasayaki:
            "Sasayaki (Audiobooks)"
        case .video:
            "Video"
        case .keyboardShortcuts:
            "Keyboard Shortcuts"
        case .gameController:
            "Game Controller"
        case .sync:
            "Syncing"
        case .backup:
            "Backup"
        case .about:
            "About"
        }
    }

    var systemImage: String {
        switch self {
        case .profiles:
            "person.crop.circle.badge.checkmark"
        case .appearance:
            "paintpalette"
        case .dictionaries:
            "character.book.closed.ja"
        case .anki:
            "tray.full"
        case .audio:
            "speaker.wave.2"
        case .statistics:
            "chart.xyaxis.line"
        case .sasayaki:
            "waveform"
        case .video:
            "play.rectangle"
        case .keyboardShortcuts:
            "keyboard"
        case .gameController:
            "gamecontroller"
        case .sync:
            "cloud"
        case .backup:
            "externaldrive"
        case .about:
            "info.circle"
        }
    }
}

struct NativeGlassSegmentedPicker<SelectionValue: Hashable, SegmentLabel: View>: View {
    @Binding var selection: SelectionValue
    let values: [SelectionValue]
    var minSegmentWidth: CGFloat = 76
    var fillsWidth = false
    var isEnabled: (SelectionValue) -> Bool = { _ in true }
    @ViewBuilder var label: (SelectionValue) -> SegmentLabel
    @Namespace private var selectedSegmentNamespace

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            segmentedContent
        }
    }

    private var segmentedContent: some View {
        HStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.element) { index, value in
                segmentButton(value)
                    .layoutPriority(!fillsWidth && selection == value ? 1 : 0)

                if index < values.count - 1 {
                    Divider()
                        .frame(height: 16)
                        .padding(.vertical, 3)
                        .opacity(selection == value || selection == values[index + 1] ? 0 : 0.42)
                }
            }
        }
        .padding(2)
        .nativeGlassSegmentContainer()
        .animation(.smooth(duration: 0.20), value: selection)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
    }

    private func segmentButton(_ value: SelectionValue) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                selection = value
            }
        } label: {
            label(value)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .frame(minWidth: minSegmentWidth, maxWidth: fillsWidth ? .infinity : nil)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled(value))
        .foregroundStyle(selection == value ? .primary : .secondary)
        .opacity(isEnabled(value) ? 1 : 0.45)
        .background {
            if selection == value {
                selectedSegmentBackground
            }
        }
    }

    @ViewBuilder
    private var selectedSegmentBackground: some View {
        Color.clear
            .clipShape(Capsule())
            .matchedGeometryEffect(id: "native-glass-segment", in: selectedSegmentNamespace)
            .nativeGlassSelectedSegment()
            .transition(.identity)
    }
}

struct NativeGlassMenuPicker<SelectionValue: Hashable, Label: View>: View {
    @Binding var selection: SelectionValue
    let values: [SelectionValue]
    var minWidth: CGFloat = 96
    var fillsWidth = false
    @ViewBuilder var label: (SelectionValue) -> Label

    var body: some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        selection = value
                    }
                } label: {
                    HStack(spacing: 8) {
                        label(value)
                        Spacer()
                        if selection == value {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                label(selection)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .imageScale(.small)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(minWidth: minWidth, maxWidth: fillsWidth ? .infinity : nil)
            .frame(minHeight: 30)
            .contentShape(Capsule())
            .modifier(NativeGlassMenuPickerSurface())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
    }
}

private struct NativeGlassMenuPickerSurface: ViewModifier {
    func body(content: Content) -> some View {
        GlassEffectContainer(spacing: 0) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        }
    }
}

private extension View {
    @ViewBuilder
    func nativeGlassSegmentContainer() -> some View {
        self.glassEffect(.regular.interactive(), in: Capsule())
    }

    @ViewBuilder
    func nativeGlassSelectedSegment() -> some View {
        self.glassEffect(.regular.interactive(), in: Capsule())
    }
}

struct NativeSettingsDetailView: View {
    let section: NativeSettingsSection
    let userConfig: UserConfig

    var body: some View {
        content
            .toggleStyle(.switch)
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .background {
                NativeGlassPageBackground()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .profiles:
            ProfilesView()
        case .appearance:
            AppearanceView(userConfig: userConfig, showDismiss: false)
        case .dictionaries:
            DictionaryView()
        case .anki:
            AnkiView()
        case .audio:
            AudioView()
        case .statistics:
            StatisticsSettingsView()
        case .sasayaki:
            SasayakiSettingsView()
        case .video:
            VideoSettingsView()
        case .keyboardShortcuts:
            KeyboardShortcutsView()
        case .gameController:
            XboxControllerView()
        case .sync:
            SyncView()
        case .backup:
            BackupView()
        case .about:
            AboutView()
        }
    }
}

/// Settings content renders as cards in the Settings window and as a compact
/// desktop inspector (grouped rows, no cards) inside Reader side panels.
enum NativeSettingsPresentation {
    case cards
    case inspector
}

extension EnvironmentValues {
    @Entry var nativeSettingsPresentation: NativeSettingsPresentation = .cards
}

enum NativeSettingsPalette {
    static func separator(_ colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            Color.white.opacity(0.105)
        } else {
            Color(nsColor: .separatorColor).opacity(0.42)
        }
    }
}

struct NativeSettingsForm<Content: View>: View {
    var horizontalPadding: CGFloat = 24
    var verticalPadding: CGFloat = 18
    var spacing: CGFloat = 22
    var maxContentWidth: CGFloat = 840
    @ViewBuilder var content: () -> Content
    @Environment(\.nativeSettingsPresentation) private var presentation

    var body: some View {
        if presentation == .inspector {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
        } else {
            cardsBody
        }
    }

    private var cardsBody: some View {
        GeometryReader { proxy in
            let contentWidth = min(max(proxy.size.width - horizontalPadding * 2, 0), maxContentWidth)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: spacing) {
                    content()
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct NativeSettingsSectionCard<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.header = header
        self.content = content
        self.footer = footer
    }

    @Environment(\.nativeSettingsPresentation) private var presentation

    var body: some View {
        if presentation == .inspector {
            inspectorBody
        } else {
            cardsBody
        }
    }

    private var inspectorBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            header()
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            footer()
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    private var cardsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .nativeGlassCardSurface(cornerRadius: 18)

            footer()
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension NativeSettingsSectionCard where Header == Text, Footer == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init {
            Text(title)
        } content: {
            content()
        } footer: {
            EmptyView()
        }
    }
}

extension NativeSettingsSectionCard where Header == Text {
    init(
        _ title: LocalizedStringKey,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.init {
            Text(title)
        } content: {
            content()
        } footer: {
            footer()
        }
    }
}

extension NativeSettingsSectionCard where Header == Text, Footer == Text {
    init(
        _ title: LocalizedStringKey,
        footer: LocalizedStringKey,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init {
            Text(title)
        } content: {
            content()
        } footer: {
            Text(footer)
        }
    }
}

struct NativeSettingsRow<Label: View, Accessory: View>: View {
    @ViewBuilder var label: () -> Label
    @ViewBuilder var accessory: () -> Accessory

    init(
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.label = label
        self.accessory = accessory
    }

    @Environment(\.nativeSettingsPresentation) private var presentation

    var body: some View {
        if presentation == .inspector {
            HStack(spacing: 10) {
                label()
                    .font(.callout)
                Spacer(minLength: 12)
                accessory()
                    .controlSize(.small)
            }
            .frame(minHeight: 32)
        } else {
            HStack(spacing: 12) {
                label()
                    .font(.body.weight(.medium))
                Spacer(minLength: 20)
                accessory()
            }
            .frame(minHeight: 46)
            .padding(.horizontal, 16)
        }
    }
}

private struct NativeSettingsTextFieldModifier: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .font(.body)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        isFocused ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.22),
                        lineWidth: isFocused ? 2 : 0.5
                    )
                    .padding(isFocused ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

struct NativeSettingsEditableMenuField<MenuContent: View>: View {
    @Binding var text: String
    let prompt: Text
    let menuAccessibilityLabel: Text
    let onSubmit: () -> Void
    @ViewBuilder var menuContent: () -> MenuContent
    @FocusState private var isFocused: Bool

    init(
        text: Binding<String>,
        prompt: Text,
        menuAccessibilityLabel: Text,
        onSubmit: @escaping () -> Void = {},
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) {
        _text = text
        self.prompt = prompt
        self.menuAccessibilityLabel = menuAccessibilityLabel
        self.onSubmit = onSubmit
        self.menuContent = menuContent
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(text: $text, prompt: prompt) {
                prompt
            }
            .textFieldStyle(.plain)
            .focused($isFocused)
            .submitLabel(.done)
            .onSubmit(onSubmit)

            Menu {
                menuContent()
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(menuAccessibilityLabel)
        }
        .font(.body)
        .padding(.leading, 12)
        .padding(.trailing, 3)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(Capsule())
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay {
            Capsule()
                .stroke(
                    isFocused ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.22),
                    lineWidth: isFocused ? 2 : 0.5
                )
                .padding(isFocused ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

extension View {
    func nativeSettingsTextField() -> some View {
        modifier(NativeSettingsTextFieldModifier())
    }
}

struct NativeSettingsSubtitledLabel: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

extension NativeSettingsRow where Label == Text {
    init(_ title: LocalizedStringKey, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.init {
            Text(title)
        } accessory: {
            accessory()
        }
    }
}

struct NativeSettingsToggle: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        NativeSettingsRow(title) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

struct NativeSettingsButtonRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.nativeSettingsPresentation) private var presentation

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            rowContent
        }
        .frame(minHeight: presentation == .inspector ? 36 : 46)
        .padding(.horizontal, presentation == .inspector ? 0 : 16)
        .buttonStyle(NativeSettingsActionButtonStyle())
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
        }
    }
}

struct NativeSettingsActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .frame(minHeight: 30)
            .contentShape(Capsule())
            .modifier(
                NativeSettingsActionButtonGlassSurface(
                    isPressed: configuration.isPressed,
                    isEnabled: isEnabled
                )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

private struct NativeSettingsActionButtonGlassSurface: ViewModifier {
    let isPressed: Bool
    let isEnabled: Bool
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? 1 : 0.58)
            .background {
                if isPressed {
                    Capsule()
                        .fill(NativeGlassPalette.cardTint(for: userConfig, colorScheme: colorScheme))
                }
            }
            .glassEffect(.regular.interactive(), in: Capsule())
    }
}

struct NativeSettingsSliderRow<SliderContent: View>: View {
    let title: LocalizedStringKey
    let value: String
    @ViewBuilder var slider: () -> SliderContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
                Text(value)
                    .fontWeight(.semibold)
            }
            slider()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct NativeSettingsValuePill<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(.body.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.fill.tertiary, in: Capsule())
    }
}

struct NativeGlassCircleButton: View {
    let systemName: String
    var diameter: CGFloat = 38
    var fontSize: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay {
            Circle()
                .strokeBorder(.primary.opacity(0.14), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.12), radius: 9, x: 0, y: 3)
        .nativeGlassCircleButton()
    }
}

struct NativeReaderSheetPanel<Content: View>: View {
    let title: LocalizedStringKey
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        _ title: LocalizedStringKey,
        onClose: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.onClose = onClose
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.headline)

                HStack {
                    Spacer()

                    NativeGlassCircleButton(systemName: "xmark", diameter: 34, fontSize: 13) {
                        onClose()
                    }
                    .accessibilityLabel(Text("Close"))
                    .help(Text("Close"))
                }
            }
            .frame(height: 58)
            .padding(.horizontal, 20)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            NativeShelfPageBackground()
        }
        .onExitCommand(perform: onClose)
    }
}

private extension View {
    @ViewBuilder
    func nativeGlassCircleButton() -> some View {
        self.glassEffect(.regular.interactive(), in: Circle())
    }
}

struct NativeSettingsSeparator: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nativeSettingsPresentation) private var presentation

    var body: some View {
        if presentation != .inspector {
            Divider()
                .overlay(NativeSettingsPalette.separator(colorScheme))
                .padding(.leading, 16)
        }
    }
}
