import Foundation

private let shelfView = try String(contentsOfFile: "Features/Bookshelf/ShelfView.swift", encoding: .utf8)
private let bookView = try String(contentsOfFile: "Features/Bookshelf/BookView.swift", encoding: .utf8)
private let bookCell = try String(contentsOfFile: "Features/Bookshelf/BookCell.swift", encoding: .utf8)
private let bookshelfModel = try String(contentsOfFile: "Features/Bookshelf/BookshelfViewModel.swift", encoding: .utf8)
private let nativeBookshelf = try String(contentsOfFile: "NativeMac/NativeReuseViews.swift", encoding: .utf8)
private let nativeRoot = try String(contentsOfFile: "NativeMac/NativeMacRootView.swift", encoding: .utf8)
private let coverImage = try String(contentsOfFile: "Util/CoverImage.swift", encoding: .utf8)
private let shelfSidebar = try String(contentsOfFile: "Features/Bookshelf/LibraryShelfSidebar.swift", encoding: .utf8)
private let mangaLibrary = try String(contentsOfFile: "Features/Manga/MangaLibraryView.swift", encoding: .utf8)
private let nativeDetail = try String(contentsOfFile: "NativeMac/NativeMacDetailView.swift", encoding: .utf8)
private let nativeGlassSurface = try String(contentsOfFile: "NativeMac/NativeGlassSurface.swift", encoding: .utf8)
private let bookshelfDropSupport = (try? String(contentsOfFile: "Features/Bookshelf/BookshelfDropSupport.swift", encoding: .utf8)) ?? ""
private let extensions = try String(contentsOfFile: "Util/Extensions.swift", encoding: .utf8)
private let aboutView = try String(contentsOfFile: "Features/Settings/AboutView.swift", encoding: .utf8)
private let updatePresentation = try String(contentsOfFile: "NativeMac/NativeUpdatePresentation.swift", encoding: .utf8)
private let project = try String(contentsOfFile: "Niratan.xcodeproj/project.pbxproj", encoding: .utf8)

assertContains(
    nativeRoot,
    "var bookshelfViewModel = BookshelfViewModel()",
    "The main window should retain one novel Bookshelf model across sidebar switches"
)

assertContains(
    nativeBookshelf,
    "@Bindable var viewModel: BookshelfViewModel",
    "The novel Bookshelf view should consume the retained root model instead of recreating it"
)

assertContains(
    nativeBookshelf,
    "if !viewModel.isInitialPresentationReady {\n            Color.clear",
    "The novel Bookshelf should keep only its page background until the first visible covers are prepared"
)

assertContains(
    bookshelfModel,
    "await CoverThumbnailCache.preheat(",
    "The novel Bookshelf should prepare its initial cover batch before revealing book cards"
)

assertNotContains(
    nativeBookshelf,
    "@State private var viewModel = BookshelfViewModel()",
    "The novel Bookshelf view must not discard its catalog state whenever the sidebar section changes"
)

assertContains(
    coverImage,
    "let displayedImage = (imageKey == key ? image : nil)",
    "Book covers should reuse decoded thumbnails without showing a stale image after their URL changes"
)

assertContains(
    coverImage,
    "?? CoverImageMemoryCache.shared.image(for: key)",
    "Book covers should synchronously reuse decoded thumbnails when a shelf view is reconstructed"
)

assertContains(
    coverImage,
    "cache.countLimit = 256",
    "Decoded cover reuse should remain bounded"
)

assertContains(
    coverImage,
    "limit: Int = 32",
    "Initial cover preparation should stay bounded instead of decoding an entire large library"
)

private func assertContains(_ source: String, _ needle: String, _ message: String) {
    guard source.contains(needle) else {
        fatalError("FAIL: \(message)\nMissing: \(needle)")
    }
}

private func assertNotContains(_ source: String, _ needle: String, _ message: String) {
    guard !source.contains(needle) else {
        fatalError("FAIL: \(message)\nUnexpected: \(needle)")
    }
}

assertContains(
    bookView,
    "static let v050CoverWidth: CGFloat = 160",
    "Bookshelf should keep the v0.5.0 Catalyst visual card width as an explicit layout token"
)

assertContains(
    shelfView,
    "minimum: coverWidth,\n                maximum: coverWidth",
    "Shelf grid should pin adaptive columns to the user-adjustable cover width instead of letting SwiftUI stretch them"
)

assertContains(
    shelfView,
    "LazyVGrid(\n                    columns: columns,\n                    alignment: .leading,\n                    spacing: BookshelfLayout.rowSpacing\n                ) {",
    "Expanded bookshelf grids should align their first card with the leading edge of the section title"
)

assertContains(
    bookView,
    ".frame(width: coverWidth)",
    "Book cards should pin the cover/title stack to the adjustable cover width instead of stretching with the grid cell"
)

assertContains(
    bookView,
    "@Entry var shelfCoverWidth: CGFloat = BookshelfLayout.v050CoverWidth",
    "Book covers should default to the v0.5.0 visual width until the user adjusts the cover size"
)

assertContains(
    bookView,
    """
    .frame(
                        width: contentWidth,
                        height: contentWidth / 0.709
                    )
                    .clipped()
    """,
    "Shelf glass cards must explicitly constrain and clip cover content so intrinsic image sizes cannot overflow the card"
)

assertContains(
    bookView,
    "static let progressTrackHeight: CGFloat = 3",
    "Bookshelf progress should use the compact v0.5.0-style track height instead of the native macOS ProgressView size"
)

assertContains(
    bookView,
    "ShelfProgressStrip(progress: progress)",
    "Book covers should render the compact Bookshelf progress strip"
)

assertNotContains(
    bookView,
    "ProgressView(value: progress)",
    "Bookshelf covers should not use the oversized native macOS ProgressView"
)

assertNotContains(
    bookCell,
    "Label(\"Profile\", systemImage: \"person.crop.circle\")",
    "Bookshelf rows must not expose a per-book Profile menu"
)

assertNotContains(
    bookCell,
    "ShareLink(item:",
    "Local book export should not present the macOS share picker from a transient context-menu item"
)

assertNotContains(
    bookCell,
    "@State private var pendingExportURL: URL?",
    "Local book export should not keep presentation state inside BookCell because context-menu state can drift away from the current grid cell"
)

assertContains(
    bookCell,
    "var onExport: (URL) -> Void",
    "Local book export should route the selected file URL to the owning ShelfView"
)

assertContains(
    bookCell,
    "@Binding var presentedExportURL: URL?",
    "BookCell should receive export presentation state from ShelfView instead of owning context-menu state"
)

assertContains(
    bookCell,
    "onExport(exportURL)",
    "Local book export should ask ShelfView to present from the current book frame"
)

assertContains(
    bookCell,
    "BookExportShareAnchor(fileURL: $presentedExportURL)",
    "Local book export should keep the AppKit share anchor inside the current BookCell card"
)

assertContains(
    bookCell,
    "BookRenameDraft(book: book, title: book.displayTitle)",
    "Book rename should create a fresh draft from the current display title each time the rename action opens"
)

assertContains(
    bookCell,
    ".sheet(item: $renameDraft)",
    "Book rename should use item-driven sheet presentation so Cancel/Esc resets presentation state before reopening"
)

assertNotContains(
    bookCell,
    "@State private var showRenameAlert = false",
    "Book rename should not key the alert only by a Bool because macOS SwiftUI alert text fields can reuse stale field state"
)

assertNotContains(
    bookCell,
    ".alert(\"Rename\", isPresented:",
    "Book rename should not use a context-menu-triggered alert because it can fail to re-present after Cancel/Esc on macOS"
)

assertContains(
    bookCell,
    ".buttonStyle(.plain)\n        .overlay(alignment: .bottom) {\n            BookExportShareAnchor(fileURL: $presentedExportURL)\n                .frame(width: 1, height: 1)\n                .allowsHitTesting(false)\n        }\n        .contextMenu",
    "Local book export should attach a deterministic 1x1 AppKit share anchor to the bottom center of the current BookCell root"
)

assertContains(
    shelfView,
    "var pendingExport: BookExportPresentation?",
    "ShelfView should own local export presentation state for the exact grid cell that invoked export"
)

assertContains(
    shelfView,
    "pendingExport = BookExportPresentation(bookID: book.id, fileURL: url)",
    "ShelfView should remember the exact book id whose context menu requested export"
)

assertContains(
    shelfView,
    "presentedExportURL: exportBinding(for: book.id),",
    "ShelfView should pass export presentation state only to the BookCell for the current book id"
)

assertContains(
    shelfView,
    "func exportBinding(for bookID: UUID) -> Binding<URL?>",
    "ShelfView should clear the pending export when the current cell's share picker has opened"
)

assertContains(
    bookCell,
    "context.coordinator.presentedURL = fileURL\n        let coordinator = context.coordinator\n        DispatchQueue.main.async {",
    "Local book export should defer NSSharingServicePicker presentation until after the context menu action has unwound"
)

assertContains(
    shelfView,
    "private struct BookExportPresentation: Identifiable",
    "Local book export should carry a stable presentation id while the share picker opens"
)

assertContains(
    bookCell,
    "struct BookExportShareAnchor: NSViewRepresentable",
    "Local book export should use an AppKit NSViewRepresentable anchor for reliable macOS popover placement"
)

assertNotContains(
    bookshelfModel,
    "func setProfile(_ profileID: String?, for book: BookMetadata)",
    "Bookshelf state must not mutate legacy per-book Profile overrides"
)

assertNotContains(
    shelfView,
    "GridItem(.adaptive(minimum: 190)",
    "Bookshelf should not keep the oversized native-only adaptive minimum"
)

assertContains(
    shelfView,
    ".adaptive(minimum: BookshelfLayout.compactCoverWidth)",
    "Collapsed shelves should use the upstream compact cover preview width"
)

assertContains(
    shelfView,
    "self._isCollapsed = State(initialValue: allowsCollapse && !section.isReading)",
    "Stacked bookshelf folders may start collapsed, but the single shelf shown beside the shelf column stays expanded"
)

assertContains(
    shelfView,
    "if isCollapsed && section.shelf != nil",
    "Collapsed folders should render compact previews instead of the full book grid"
)

assertContains(
    shelfView,
    "BookCover(book: book, width: BookshelfLayout.compactCoverWidth)",
    "Collapsed folder previews should render compact covers"
)

assertContains(
    shelfView,
    "isCollapsed = false",
    "Clicking a collapsed folder preview should expand the shelf"
)

assertContains(
    nativeBookshelf,
    "if userConfig.enableSync && GoogleDriveAuth.shared.isAuthenticated",
    "Native Bookshelf should expose Google Drive refresh only when sync is enabled and authenticated"
)

assertContains(
    nativeBookshelf,
    "await viewModel.loadGoogleDriveBooks()",
    "Native Bookshelf Google Drive refresh should reuse the existing remote book loader"
)

assertContains(
    nativeBookshelf,
    "Label(\"Refresh Google Drive Books\", systemImage: \"icloud.and.arrow.down\")",
    "Native Bookshelf toolbar should include a visible Google Drive refresh action"
)

assertNotContains(
    nativeBookshelf,
    "updateChecker",
    "Update checks belong to Settings > About and the main window's background checks, not the Bookshelf toolbar"
)

assertNotContains(
    nativeBookshelf,
    "bookshelfHeaderActions",
    "Native Bookshelf actions should stay in the top-right toolbar instead of adding custom in-content chrome"
)

assertContains(
    nativeRoot,
    ".nativeUpdatePresentation()",
    "The main window should run the automatic GitHub release checks"
)

assertContains(
    updatePresentation,
    "await updateChecker.runAutomaticChecks()",
    "Automatic update checks should run for the lifetime of the main window"
)

assertContains(
    updatePresentation,
    "await updateChecker.downloadAndOpenAvailableUpdate()",
    "The available-update alert should download and open the matching DMG instead of sending users to GitHub"
)

assertContains(
    aboutView,
    "await updateChecker.check(manual: true)",
    "Settings > About should offer the manual update check"
)

assertContains(
    aboutView,
    "isOn: $updateChecker.automaticChecksEnabled",
    "Settings > About should let users turn automatic update checks off"
)

assertContains(
    extensions,
    "static let shared = UpdateChecker()",
    "The main window and Settings should share one update checker"
)

assertNotContains(
    nativeBookshelf,
    "ToolbarItemGroup(placement: .navigation)",
    "Native Bookshelf should keep every toolbar action on the top-right"
)

assertContains(
    nativeBookshelf,
    ".searchable(text: $searchText, placement: .toolbar",
    "Native Bookshelf should search books from the toolbar"
)

assertContains(
    nativeBookshelf,
    ".pickerStyle(.inline)",
    "The Bookshelf sort menu should list its options directly instead of a nested submenu"
)

assertContains(
    nativeBookshelf,
    "LibraryCoverSizeButton(width: $coverWidth)",
    "Native Bookshelf should let users adjust the cover size from the toolbar"
)

assertContains(
    extensions,
    "struct AppReleaseAsset: Equatable",
    "UpdateChecker should model GitHub release assets so it can select the matching DMG and checksum"
)

assertContains(
    extensions,
    "downloadAndOpenAvailableUpdate() async",
    "UpdateChecker should expose an Anki-style download-and-open flow for available updates"
)

assertNotContains(
    extensions,
    "HoshiBuildVariant",
    "UpdateChecker should use the one full-build DMG without a retired build-variant key"
)

assertContains(
    extensions,
    "SHA256",
    "UpdateChecker should verify the downloaded DMG against the release checksum before opening it"
)

assertNotContains(
    extensions,
    "AppPlatform.isMacCatalyst",
    "UpdateChecker must not gate native macOS update checks behind the retired Catalyst path"
)

assertContains(
    nativeBookshelf,
    ".disabled(viewModel.isLoadingGoogleDriveBooks)",
    "Native Bookshelf should prevent duplicate Google Drive refresh requests"
)

assertContains(
    bookshelfModel,
    "func moveBook(_ sourceID: UUID, in section: ShelfSection, before targetID: UUID)",
    "Bookshelf view model should expose a section-scoped drag reorder command"
)

assertContains(
    bookshelfModel,
    "BookStorage.saveBookOrder(manualBookOrder)",
    "Unshelved manual order should be persisted outside shelf membership"
)

assertContains(
    project,
    "Bookshelf/BookshelfDropSupport.swift",
    "Bookshelf AppKit file drop bridge must be included in the Xcode synchronized root target membership"
)

assertContains(
    shelfView,
    "BookshelfBookFramePreferenceKey",
    "Shelf should record book card frames for direct drag-reorder gestures"
)

assertContains(
    bookCell,
    "DragGesture(minimumDistance: 8, coordinateSpace: .named(dragCoordinateSpaceName))",
    "Book sorting should include a direct drag gesture on the book button label"
)

assertContains(
    bookCell,
    ".highPriorityGesture(",
    "Book sorting drag should take priority over the book button tap gesture once movement starts"
)

assertContains(
    bookCell,
    ".onChanged { value in\n                            onDragChanged(value.location)",
    "Book drag gestures should reorder while dragging, not only on mouse-up"
)

assertContains(
    shelfView,
    "dragCoordinateSpaceName: section.allowsReordering ? coordinateSpaceName : nil",
    "Shelf should pass its named coordinate space into local book card drag gestures"
)

assertContains(
    shelfView,
    "onDragChanged: section.allowsReordering ? { location in\n                                reorderBook(book.id, draggedTo: location)",
    "Book drag gestures should route reorder drops through the same view-model command"
)

assertContains(
    bookshelfDropSupport,
    "struct BookshelfFileDropTarget<Content: View>: NSViewRepresentable",
    "Bookshelf file drops should use AppKit pasteboard file URLs from Finder"
)

assertContains(
    bookshelfDropSupport,
    "registerForDraggedTypes([.fileURL])",
    "Bookshelf file drop targets should register Finder file URL pasteboard types"
)

assertContains(
    bookshelfDropSupport,
    "URL(dataRepresentation: data, relativeTo: nil)",
    "Finder file drops should decode file-url pasteboard data into URLs"
)

assertContains(
    nativeBookshelf,
    "BookshelfFileDropTarget(",
    "Native Bookshelf should accept dropped EPUB file URLs through the AppKit file drop bridge"
)

assertContains(
    shelfView,
    "viewModel.moveBook(sourceID, in: section, before: targetID)",
    "Shelf drag gestures should route reorders through the view model"
)

assertContains(
    shelfView,
    "let dragReorderAnimation: Animation = .smooth(duration: 0.22)",
    "Bookshelf drag sorting should use a short SwiftUI animation for grid reflow"
)

assertContains(
    shelfView,
    "withAnimation(dragReorderAnimation) {\n            userConfig.bookshelfSortOption = .manual\n            viewModel.moveBook(sourceID, in: section, before: targetID)",
    "Book drag reorders should animate the sort-option switch and grid item movement together"
)

assertContains(
    shelfView,
    "let visualState = bookDragVisualState(for: book.id)",
    "Shelf book cards should derive visual feedback from the active drag source and target"
)

assertContains(
    bookView,
    "scaleEffect(state.scale)",
    "The dragged book card should scale slightly while a drag reorder is active"
)

assertContains(
    bookView,
    "RoundedRectangle(cornerRadius: 10, style: .continuous)",
    "The current drag target should show a subtle rounded highlight"
)

assertContains(
    bookView,
    ".glassEffect(\n            .regular.interactive(),",
    "Novel and manga covers should share one direct macOS 26 interactive glass surface"
)

for (path, source) in [
    ("Features/Bookshelf/BookView.swift", bookView),
    ("Features/Bookshelf/ShelfView.swift", shelfView),
    ("Features/Bookshelf/LibraryShelfSidebar.swift", shelfSidebar),
    ("Features/Manga/MangaLibraryView.swift", mangaLibrary),
] {
    for forbidden in [".material", "Material", ".formStyle(.grouped)"] {
        assertNotContains(
            source,
            forbidden,
            "\(path) must not place legacy Material or grouped Form chrome inside macOS 26 shelf surfaces"
        )
    }
}

assertContains(
    nativeDetail,
    "case .bookshelf, .manga:\n                    NativeShelfPageBackground()",
    "Novel and manga should use the same material-free shelf page background"
)

guard let shelfBackgroundStart = nativeGlassSurface.range(of: "struct NativeShelfPageBackground: View"),
      let nextBackgroundType = nativeGlassSurface.range(
        of: "struct NativeGlassTopScrim: View",
        range: shelfBackgroundStart.upperBound..<nativeGlassSurface.endIndex
      ) else {
    fatalError("FAIL: NativeShelfPageBackground source boundary is missing")
}
let shelfBackgroundSource = String(
    nativeGlassSurface[shelfBackgroundStart.lowerBound..<nextBackgroundType.lowerBound]
)
assertNotContains(
    shelfBackgroundSource,
    "Material",
    "The shelf page background must not hide Material underneath macOS 26 glass components"
)

for (path, source) in [
    ("NativeMac/NativeReuseViews.swift", nativeBookshelf),
    ("Features/Manga/MangaLibraryView.swift", mangaLibrary),
] {
    assertContains(
        source,
        "LibraryShelfSidebar(",
        "\(path) should show its shelves in the shared shelf column beside the grid"
    )
    assertContains(
        source,
        "LibraryShelfLayout.sidebarWidth(for: proxy.size.width)",
        "\(path) should size the shelf column like the Settings inner sidebar"
    )
    assertNotContains(
        source,
        "Manage Shelves",
        "\(path) should manage shelves directly in the shelf column instead of a separate sheet"
    )
}

assertContains(
    shelfSidebar,
    "contextMenu(forSelectionType: LibraryShelfSelection.self)",
    "Shelf rows should offer rename and delete from the list context menu"
)

assertContains(
    shelfSidebar,
    "} primaryAction: { items in",
    "Double-clicking a shelf should start renaming it inline"
)

assertContains(
    shelfSidebar,
    "TextField(\"Shelf name\", text: $draftName)",
    "Shelves should be renamed in place inside the shelf column"
)

assertContains(
    shelfSidebar,
    ".onMove(perform: editingShelfID == nil ? onMove : nil)",
    "Shelves should reorder by dragging in the shelf column"
)

assertContains(
    shelfSidebar,
    "Label(\"New Shelf\", systemImage: \"plus\")",
    "The shelf column should create shelves directly"
)

assertContains(
    bookshelfModel,
    "shelves[index].name = name",
    "Renaming a novel shelf should keep its books and order in the existing shelves.json structure"
)

guard let nativeBookshelfStart = nativeBookshelf.range(of: "struct NativeBookshelfReuseView: View"),
      let nativeDictionaryStart = nativeBookshelf.range(
        of: "struct NativeDictionaryReuseView: View",
        range: nativeBookshelfStart.upperBound..<nativeBookshelf.endIndex
      ) else {
    fatalError("FAIL: NativeBookshelfReuseView source boundary is missing")
}
let nativeBookshelfSource = String(
    nativeBookshelf[nativeBookshelfStart.lowerBound..<nativeDictionaryStart.lowerBound]
)
assertNotContains(
    nativeBookshelfSource,
    "NativeGlassPageBackground",
    "Native Bookshelf must not add a second material page background inside the shared detail surface"
)
assertNotContains(
    nativeBookshelfSource,
    "ToolbarSpacer(",
    "Native Bookshelf toolbar should not show a standalone separator before its primary actions"
)

guard let circleButtonStart = nativeBookshelf.range(of: "struct NativeGlassCircleButton: View"),
      let readerPanelStart = nativeBookshelf.range(
        of: "struct NativeReaderSheetPanel<Content: View>: View",
        range: circleButtonStart.upperBound..<nativeBookshelf.endIndex
      ) else {
    fatalError("FAIL: NativeGlassCircleButton source boundary is missing")
}
let circleButtonSource = String(
    nativeBookshelf[circleButtonStart.lowerBound..<readerPanelStart.lowerBound]
)
assertNotContains(
    circleButtonSource,
    "Material",
    "The Sasayaki-style close button must use direct glass without a Material backing"
)

assertContains(
    nativeBookshelf,
    "NativeShelfPageBackground()",
    "The shared Reader-style panel should use the material-free shelf background"
)

assertContains(
    bookshelfModel,
    "case .manual:",
    "Bookshelf sorting should include a manual order path"
)

assertNotContains(
    nativeBookshelf,
    "if !viewModel.downloadingBooks.isEmpty",
    "Google Drive book downloads should not place a blocking overlay over the native Bookshelf"
)

assertContains(
    nativeBookshelf,
    "NotificationCenter.default.publisher(for: .readerWindowProgressDidChange)",
    "Native Bookshelf should listen for the dedicated Reader window progress refresh signal"
)

assertContains(
    nativeBookshelf,
    ".onReceive(NotificationCenter.default.publisher(for: .readerWindowProgressDidChange)) { _ in\n            viewModel.loadBooks()\n        }",
    "Native Bookshelf should reload saved reading progress after the Reader window closes or replaces its book"
)

assertContains(
    bookshelfModel,
    "var downloadingBooks: [UUID: Double] = [:]",
    "Google Drive downloads should track progress independently for multiple books"
)

assertContains(
    bookshelfModel,
    "downloadingBooks[book.id] = 0\n        Task {",
    "Each Google Drive book download should launch its own asynchronous task"
)

print("Bookshelf layout contract passed")
