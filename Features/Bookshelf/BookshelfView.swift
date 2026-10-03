//
//  BookshelfView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import EPUBKit
import UniformTypeIdentifiers

struct BookshelfView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(UserConfig.self) private var userConfig
    @State private var viewModel = BookshelfViewModel()
    @State private var showShelfManagement = false
    @State private var selectedTab = 0
    @State private var focusDictionarySearch = false
    @State private var setInitialTab = false
    @State private var navigationPath = NavigationPath()
    @State private var dictionaryRoute = DictionaryRoute()
    @State private var isSelecting = false
    @State private var selectedBooks = Set<BookMetadata>()
    @State private var showBulkDeleteConfirmation = false
    @State private var selectedReaderBook: BookMetadata?
    @State private var updateChecker = UpdateChecker()
    @Binding var pendingImportURL: URL?
    @Binding var pendingRemoteImportURL: URL?
    @Binding var pendingLookup: String?
    @Binding var pendingTab: Int?

    private var sepiaInverted: Bool {
        userConfig.usesDarkSepia(in: systemColorScheme)
    }

    private var readerChromeBackground: Color {
        if sepiaInverted {
            return Color(red: 0.094, green: 0.082, blue: 0.047)
        }
        if userConfig.theme == .sepia || (userConfig.theme == .system && userConfig.systemLightSepia && systemColorScheme == .light) {
            return Color(red: 0.949, green: 0.886, blue: 0.788)
        }
        return userConfig.theme == .custom ? userConfig.customBackgroundColor : Color(.systemBackground)
    }

    var body: some View {
        ZStack {
            if selectedTab == 0, let selectedReaderBook {
                ReaderLoader(book: selectedReaderBook)
                    .environment(userConfig)
                    .environment(\.dismissReader) {
                        self.selectedReaderBook = nil
                        selectedTab = 0
                        viewModel.loadBooks()
                    }
                    .environment(\.openReaderTab) { tab in
                        selectedTab = tab
                    }
                    .transition(.opacity)
            } else {
                TabView(selection: Binding(get: { selectedTab }, set: { newTab in
                    if newTab == 1 && selectedTab == 1 {
                        focusDictionarySearch.toggle()
                    }
                    selectedTab = newTab
                })) {
                    NavigationStack(path: $navigationPath) {
                        BookshelfFileDropTarget(onDrop: viewModel.importDroppedEPUBs) {
                            ScrollView {
                                let sections = viewModel.shelfSections(sortedBy: userConfig.bookshelfSortOption, showReading: userConfig.bookshelfShowReading)
                                if viewModel.books.isEmpty && viewModel.googleDriveBooks.isEmpty {
                                    ContentUnavailableView {
                                        Label("No Books", systemImage: "books.vertical")
                                    } description: {
                                        Text("Import an EPUB using the \(Image(systemName: "plus")) button to start reading.")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 160)
                                } else {
                                    ForEach(sections) { section in
                                        if section.books.count > 0 {
                                            ShelfView(
                                                viewModel: viewModel,
                                                section: section,
                                                showTitle: sections.count > 1,
                                                isSelecting: isSelecting,
                                                selectedBooks: $selectedBooks,
                                                pendingLookup: $pendingLookup,
                                                pendingTab: $pendingTab,
                                                onOpenBook: { selectedReaderBook = $0 }
                                            )
                                        }
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("Books")
                        .toolbar {
                            toolbarContent
                        }
                        .onAppear {
                            viewModel.loadBooks()
                        }
                        .fileImporter(
                            isPresented: $viewModel.isImporting,
                            allowedContentTypes: [.epub],
                            allowsMultipleSelection: true,
                            onCompletion: viewModel.importBooks
                        )
                        .sheet(isPresented: $showShelfManagement) {
                            ShelfManagementView(viewModel: viewModel)
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
                    }
                    .tabItem {
                        Label("Books", systemImage: "books.vertical")
                    }
                    .tag(0)
                    .onChange(of: selectedTab) {
                        clearSelection()
                    }

                    NavigationStack {
                        DictionarySearchView(
                            initialQuery: dictionaryRoute.query,
                            initialAutofocus: dictionaryRoute.autofocus,
                            shouldFocus: focusDictionarySearch
                        )
                        .id(dictionaryRoute.id)
                    }
                    .tabItem {
                        Label("Dictionary", systemImage: "character.magnify.ja")
                    }
                    .tag(1)

                    NavigationStack {
                        SettingsHomeView()
                    }
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(2)
                }
            }
        }
        .background {
            ReaderChromeBackgroundSync(
                isActive: selectedReaderBook != nil && selectedTab == 0,
                backgroundColor: readerChromeBackground
            )
            .frame(width: 0, height: 0)
        }
        .onChange(of: pendingTab) { _, tab in
            if let tab {
                selectedReaderBook = nil
                selectedTab = tab
                pendingTab = nil
            }
        }
        .onChange(of: pendingLookup) { _, text in
            if let text {
                selectedReaderBook = nil
                selectedTab = 1
                dictionaryRoute = DictionaryRoute(
                    query: text,
                    autofocus: text.isEmpty
                )
                pendingLookup = nil
            }
        }
        .onChange(of: pendingImportURL) { _, url in
            if let url {
                navigationPath = NavigationPath()
                if url.pathExtension == "colpkg" || url.pathExtension == "apkg" {
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
        }
        .onChange(of: pendingRemoteImportURL) { _, url in
            if let url {
                navigationPath = NavigationPath()
                viewModel.importRemoteBook(from: url)
                pendingRemoteImportURL = nil
            }
        }
        .alert("Error", isPresented: $viewModel.shouldShowError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage)
        }
        .alert("", isPresented: $viewModel.shouldShowSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.successMessage)
        }
        .alert(updateAlertTitle, isPresented: updateAlertBinding) {
            if case .available = updateChecker.alert {
                Button("Download and Install") {
                    Task {
                        await updateChecker.downloadAndOpenAvailableUpdate()
                    }
                }
                Button("Later", role: .cancel) { }
            } else {
                Button("OK", role: .cancel) { }
            }
        } message: {
            Text(updateAlertMessage)
        }
        .overlay {
            if viewModel.isSyncing {
                LoadingOverlay(String(localized: "Syncing..."))
            }
            if viewModel.isDownloading {
                LoadingOverlay(String(localized: "Downloading EPUB..."))
            }
            if updateChecker.isDownloading {
                LoadingOverlay(updateChecker.downloadStatusText)
            }
            if !viewModel.downloadingBooks.isEmpty {
                LoadingOverlay(String(localized: "Downloading book from Google Drive..."))
            }
            if let importBooksProgress = viewModel.importBooksProgress {
                LoadingOverlay(importBooksProgress)
            }
        }
        .onAppear {
            guard !setInitialTab else {
                return
            }
            selectedTab = userConfig.dictionaryTabDefault ? 1 : 0
            setInitialTab = true
        }
        .task {
            await updateChecker.checkAutomaticallyIfNeeded()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") {
                    clearSelection()
                }
                .fontWeight(.semibold)
            }

            ToolbarItem(placement: .topBarTrailing) {
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
                    Image(systemName: "folder")
                }
                .disabled(selectedBooks.isEmpty)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showBulkDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedBooks.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task {
                        await updateChecker.check(manual: true)
                    }
                } label: {
                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: updateChecker.hasAvailableUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                            .foregroundStyle(updateChecker.hasAvailableUpdate ? .blue : .primary)
                    }
                }
                .disabled(updateChecker.isBusy)
                .help(Text("Check for Updates"))
                .accessibilityLabel(Text("Check for Updates"))
            }

            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Section {
                        Text("Sorting by...")
                            .foregroundStyle(.secondary)
                        Picker("Sort", selection: Bindable(userConfig).bookshelfSortOption) {
                            ForEach(SortOption.allCases) { option in
                                label(for: option)
                                    .tag(option)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }

            if userConfig.enableSync && GoogleDriveAuth.shared.isAuthenticated {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await viewModel.loadGoogleDriveBooks()
                        }
                    } label: {
                        if viewModel.isLoadingGoogleDriveBooks {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "icloud.and.arrow.down")
                        }
                    }
                    .disabled(viewModel.isLoadingGoogleDriveBooks)
                    .help(Text("Refresh Google Drive Books"))
                    .accessibilityLabel(Text("Refresh Google Drive Books"))
                }
            }

            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.default.speed(2)) {
                        isSelecting = true
                    }
                } label: {
                    Image(systemName: "checklist")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showShelfManagement = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
            }
            
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.isImporting = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private var updateAlertBinding: Binding<Bool> {
        Binding {
            updateChecker.alert != nil && selectedReaderBook == nil
        } set: { isPresented in
            if !isPresented {
                updateChecker.alert = nil
            }
        }
    }

    private var updateAlertTitle: String {
        switch updateChecker.alert {
        case .available:
            String(localized: "Update Available")
        case .upToDate:
            String(localized: "You're Up to Date")
        case .failed:
            String(localized: "Update Check Failed")
        case .downloadFailed:
            String(localized: "Update Download Failed")
        case nil:
            ""
        }
    }

    private var updateAlertMessage: String {
        switch updateChecker.alert {
        case .available(let release, let currentVersion):
            String(
                format: String(localized: "Version %@ is available. You are using %@."),
                release.version,
                currentVersion
            )
        case .upToDate(let currentVersion):
            String(
                format: String(localized: "Niratan %@ is the latest version."),
                currentVersion
            )
        case .failed:
            String(localized: "Unable to check for updates. Please try again later.")
        case .downloadFailed:
            String(localized: "Unable to download or verify the update. Please try again later.")
        case nil:
            ""
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

private struct DictionaryRoute {
    let id = UUID()
    let query: String
    let autofocus: Bool

    init(query: String = "", autofocus: Bool = true) {
        self.query = query
        self.autofocus = autofocus
    }
}
