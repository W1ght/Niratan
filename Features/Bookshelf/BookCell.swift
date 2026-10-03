//
//  BookCell.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
import SwiftUI

struct BookCell: View {
    @Environment(UserConfig.self) var userConfig
    @State private var showDeleteConfirmation = false
    @State private var markReadConfirmation = false
    @State private var renameDraft: BookRenameDraft?
    let book: BookMetadata
    var viewModel: BookshelfViewModel
    var currentShelf: String?
    var hideMove: Bool = false
    var onSelect: () -> Void
    var onExport: (URL) -> Void
    var isSelecting: Bool = false
    @Binding var selectedBooks: Set<BookMetadata>
    @Binding var presentedExportURL: URL?
    var dragCoordinateSpaceName: String?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    
    private var isSelected: Bool {
        selectedBooks.contains(book)
    }

    private var bookExportURL: URL? {
        guard let epub = book.epub,
              let booksDir = try? BookStorage.getBooksDirectory() else {
            return nil
        }
        return booksDir.appendingPathComponent(book.folder).appendingPathComponent(epub)
    }
    
    var body: some View {
        Button {
            if isSelecting {
                withAnimation(.default.speed(2)) {
                    if isSelected {
                        selectedBooks.remove(book)
                    } else {
                        selectedBooks.insert(book)
                    }
                }
            } else {
                onSelect()
            }
        } label: {
            labelContent
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            BookExportShareAnchor(fileURL: $presentedExportURL)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .contextMenu(isSelecting ? nil : ContextMenu {
            if !hideMove {
                Menu {
                    Button {
                        viewModel.moveBook(book.id, to: nil)
                    } label: {
                        Label("None", systemImage: "tray")
                    }
                    .disabled(currentShelf == nil)
                    ForEach(viewModel.shelves, id: \.name) { shelf in
                        Button {
                            viewModel.moveBook(book.id, to: shelf.name)
                        } label: {
                            Label(shelf.name, systemImage: "folder")
                        }
                        .disabled(shelf.name == currentShelf)
                    }
                } label: {
                    Label("Move", systemImage: "folder")
                }
            }
            
            if userConfig.enableSync && userConfig.syncProvider == .gdrive && GoogleDriveSyncManager.shared.enabled {
                Button {
                    viewModel.syncLibraryBook(book)
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            } else if userConfig.enableSync && userConfig.syncProvider == .ttu {
                if userConfig.syncMode == .manual {
                    Menu {
                        Button {
                            viewModel.syncBook(book: book, direction: .importFromTtu, syncBookData: userConfig.enableSync && userConfig.syncUploadBooks, syncStats: userConfig.enableSync && userConfig.statisticsEnableSync, statsSyncMode: userConfig.statisticsSyncMode, syncAudioBook: userConfig.enableSasayaki && userConfig.sasayakiEnableSync)
                        } label: {
                            Label("Import", systemImage: "arrow.down")
                        }
                        Button {
                            viewModel.syncBook(book: book, direction: .exportToTtu, syncBookData: userConfig.enableSync && userConfig.syncUploadBooks, syncStats: userConfig.enableSync && userConfig.statisticsEnableSync, statsSyncMode: userConfig.statisticsSyncMode, syncAudioBook: userConfig.enableSasayaki && userConfig.sasayakiEnableSync)
                        } label: {
                            Label("Export", systemImage: "arrow.up")
                        }
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                } else {
                    Button {
                        viewModel.syncBook(book: book, direction: nil, syncBookData: userConfig.enableSync && userConfig.syncUploadBooks, syncStats: userConfig.enableSync && userConfig.statisticsEnableSync, statsSyncMode: userConfig.statisticsSyncMode, syncAudioBook: userConfig.enableSasayaki && userConfig.sasayakiEnableSync)
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            
            if FushiInterconnectStore.shared.isPaired {
                Button {
                    viewModel.syncBookWithFushi(book)
                } label: {
                    Label("Sync with Fushi", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Button {
                markReadConfirmation = true
            } label: {
                Label("Mark Read", systemImage: "checkmark")
            }
            .disabled(book.epub == nil)
            
            Button {
                renameDraft = BookRenameDraft(book: book, title: book.displayTitle)
            } label: {
                Label("Rename", systemImage: "character.cursor.ibeam.ja")
            }
            
            if let exportURL = bookExportURL {
                Button {
                    onExport(exportURL)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        })
        .sheet(item: $renameDraft) { _ in
            BookRenameSheet(
                title: renameTitleBinding,
                onSave: saveRenameDraft,
                onCancel: { renameDraft = nil }
            )
        }
        .confirmationDialog(
            "Delete \"\(book.displayTitle)\"?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if viewModel.usesLibrarySync {
                if viewModel.canDeleteLocally(book) {
                    Button("Delete Local Copy") {
                        viewModel.deleteLocalBook(book)
                    }
                }
                Button("Delete Everywhere", role: .destructive) {
                    viewModel.deleteBook(book)
                }
            } else {
                Button("Delete", role: .destructive) {
                    viewModel.deleteBook(book)
                }
            }
        } message: {
            if viewModel.usesLibrarySync {
                Text("Deleting everywhere removes the book from Google Drive and your other devices. Reading statistics are kept.")
            }
        }
        .confirmationDialog(
            "Mark \"\(book.displayTitle)\" as read?",
            isPresented: $markReadConfirmation,
            titleVisibility: .visible
        ) {
            Button("Confirm") {
                viewModel.markRead(book: book)
            }
        }
    }

    private var renameTitleBinding: Binding<String> {
        Binding {
            renameDraft?.title ?? ""
        } set: { title in
            renameDraft?.title = title
        }
    }

    private func saveRenameDraft() {
        guard let renameDraft else { return }
        viewModel.renameBook(renameDraft.book, title: renameDraft.title.trimmingCharacters(in: .whitespaces))
        self.renameDraft = nil
    }

    @ViewBuilder
    private var labelContent: some View {
        let content = BookView(
            book: book,
            progress: viewModel.progress(for: book),
            isSelected: isSelecting && isSelected,
            downloadProgress: viewModel.downloadingBooks[book.id]
        )

        if let dragCoordinateSpaceName,
           let onDragChanged,
           let onDragEnded {
            content
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named(dragCoordinateSpaceName))
                        .onChanged { value in
                            onDragChanged(value.location)
                        }
                        .onEnded { value in
                            onDragEnded(value.location)
                        }
                )
        } else {
            content
        }
    }
}

private struct BookRenameDraft: Identifiable {
    let id = UUID()
    let book: BookMetadata
    var title: String
}

private struct BookRenameSheet: View {
    @Binding var title: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename")
                .font(.title2.bold())

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct BookExportShareAnchor: NSViewRepresentable {
    @Binding var fileURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let fileURL else {
            context.coordinator.presentedURL = nil
            return
        }
        guard context.coordinator.presentedURL != fileURL else { return }

        context.coordinator.presentedURL = fileURL
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard coordinator.presentedURL == fileURL else { return }
            guard view.window != nil, !view.bounds.isEmpty else {
                coordinator.presentedURL = nil
                return
            }

            let picker = NSSharingServicePicker(items: [fileURL])
            coordinator.picker = picker
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            self.fileURL = nil
        }
    }

    final class Coordinator {
        var picker: NSSharingServicePicker?
        var presentedURL: URL?
    }
}
