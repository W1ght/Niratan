//
//  LibraryShelfSidebar.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import SwiftUI

struct LibraryShelfSmartRow: Identifiable {
    let selection: LibraryShelfSelection
    let title: LocalizedStringKey
    let systemImage: String
    let count: Int

    var id: LibraryShelfSelection { selection }
}

struct LibraryShelfEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let count: Int
}

nonisolated enum LibraryShelfLayout {
    static let minimumSidebarWidth: CGFloat = 176
    static let maximumSidebarWidth: CGFloat = 230

    static func sidebarWidth(for totalWidth: CGFloat) -> CGFloat {
        min(maximumSidebarWidth, max(minimumSidebarWidth, totalWidth * 0.24))
    }
}

/// Inner shelf column shared by the novel Bookshelf and the local manga library.
/// Shelves are created, renamed inline, reordered and deleted directly in the column.
struct LibraryShelfSidebar: View {
    @Binding var selection: LibraryShelfSelection
    let smartRows: [LibraryShelfSmartRow]
    let shelves: [LibraryShelfEntry]
    /// Creates a shelf and returns its key, or nil when the name was rejected.
    let onCreate: (String) -> String?
    /// Renames the shelf with the given key and returns its new key, or nil when the name was rejected.
    let onRename: (String, String) -> String?
    let onDelete: (String) -> Void
    let onMove: (IndexSet, Int) -> Void

    @State private var editingShelfID: String?
    @State private var draftName = ""
    @State private var pendingDeletion: LibraryShelfEntry?
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            List(selection: listSelection) {
                Section {
                    ForEach(smartRows) { row in
                        Label(row.title, systemImage: row.systemImage)
                            .badge(row.count)
                            .tag(row.selection)
                    }
                }

                Section("Shelves") {
                    ForEach(shelves) { shelf in
                        shelfRow(shelf)
                            .tag(LibraryShelfSelection.shelf(shelf.id))
                    }
                    .onMove(perform: editingShelfID == nil ? onMove : nil)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: LibraryShelfSelection.self) { items in
                if let shelf = shelfEntry(for: items) {
                    Button {
                        beginRename(shelf)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        pendingDeletion = shelf
                    } label: {
                        Label("Delete Shelf", systemImage: "trash")
                    }
                }
            } primaryAction: { items in
                if let shelf = shelfEntry(for: items) {
                    beginRename(shelf)
                }
            }

            HStack {
                Button(action: createShelf) {
                    Label("New Shelf", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Shelf")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background {
            NativeGlassPageBackground()
                .ignoresSafeArea(.container, edges: .top)
        }
        .onChange(of: isNameFieldFocused) { _, isFocused in
            if !isFocused, editingShelfID != nil {
                commitRename()
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { shelf in
            Button("Delete Shelf", role: .destructive) {
                deleteShelf(shelf)
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Everything on this shelf stays in the library.")
        }
    }

    @ViewBuilder
    private func shelfRow(_ shelf: LibraryShelfEntry) -> some View {
        if editingShelfID == shelf.id {
            Label {
                TextField("Shelf name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($isNameFieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .onAppear {
                        DispatchQueue.main.async {
                            isNameFieldFocused = true
                        }
                    }
            } icon: {
                Image(systemName: "folder")
            }
        } else {
            Label(shelf.name, systemImage: "folder")
                .badge(shelf.count)
        }
    }

    private var listSelection: Binding<LibraryShelfSelection?> {
        Binding {
            selection
        } set: { newValue in
            if let newValue {
                selection = newValue
            }
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding {
            pendingDeletion != nil
        } set: { isPresented in
            if !isPresented {
                pendingDeletion = nil
            }
        }
    }

    private var deletionTitle: String {
        String(
            format: String(localized: "Delete shelf “%@”?"),
            pendingDeletion?.name ?? ""
        )
    }

    private func shelfEntry(for items: Set<LibraryShelfSelection>) -> LibraryShelfEntry? {
        guard items.count == 1, case .shelf(let id) = items.first else {
            return nil
        }
        return shelves.first { $0.id == id }
    }

    private func createShelf() {
        if editingShelfID != nil {
            commitRename()
        }
        let name = LibraryShelfNaming.uniqueName(
            base: String(localized: "New Shelf"),
            among: shelves.map(\.name)
        )
        guard let key = onCreate(name) else {
            NSSound.beep()
            return
        }
        selection = .shelf(key)
        draftName = name
        editingShelfID = key
    }

    private func beginRename(_ shelf: LibraryShelfEntry) {
        draftName = shelf.name
        editingShelfID = shelf.id
    }

    private func commitRename() {
        guard let shelfID = editingShelfID else { return }
        editingShelfID = nil
        guard let shelf = shelves.first(where: { $0.id == shelfID }),
              let name = LibraryShelfNaming.normalized(draftName),
              name != shelf.name else {
            return
        }
        guard let newKey = onRename(shelfID, name) else {
            NSSound.beep()
            return
        }
        if selection == .shelf(shelfID) {
            selection = .shelf(newKey)
        }
    }

    private func cancelRename() {
        editingShelfID = nil
    }

    private func deleteShelf(_ shelf: LibraryShelfEntry) {
        if editingShelfID == shelf.id {
            editingShelfID = nil
        }
        onDelete(shelf.id)
        if selection == .shelf(shelf.id) {
            selection = .all
        }
        pendingDeletion = nil
    }
}

/// Title row above the grid of the shelf selected in the shelf column.
struct LibraryShelfDetailHeader: View {
    let title: Text
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            title
                .font(.title2.weight(.semibold))
                .lineLimit(1)

            Text(count, format: .number)
                .font(.title3)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
    }
}

struct LibraryShelfEmptyView: View {
    let selection: LibraryShelfSelection

    var body: some View {
        ContentUnavailableView {
            Label("This Shelf Is Empty", systemImage: systemImage)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var systemImage: String {
        switch selection {
        case .reading:
            "book"
        case .unshelved:
            "tray"
        default:
            "folder"
        }
    }

    private var message: LocalizedStringKey {
        switch selection {
        case .reading:
            "Titles you've started but not finished appear here."
        case .unshelved:
            "Everything in the library is on a shelf."
        default:
            "Right-click a cover and choose Move, or use Select to move several at once."
        }
    }
}

/// Toolbar button that opens a slider for the library cover width.
struct LibraryCoverSizeButton: View {
    @Binding var width: Double
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Cover Size", systemImage: "square.resize")
        }
        .help("Cover Size")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            HStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(
                    value: $width,
                    in: BookshelfLayout.coverWidthRange,
                    step: BookshelfLayout.coverWidthStep
                )
                .frame(width: 180)

                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}
