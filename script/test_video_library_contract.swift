import Foundation

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

private func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private let rootView = try source("NativeMac/NativeMacRootView.swift")
private let sidebarView = try source("NativeMac/NativeMacSidebarView.swift")
private let detailView = try source("NativeMac/NativeMacDetailView.swift")
private let project = try source("Niratan.xcodeproj/project.pbxproj")
private let localization = try source("Localizable.xcstrings")
private let store = try source("Features/Video/VideoLibraryStore.swift")
private let remoteSource = try source("Features/Video/Remote/RemoteVideoSource.swift")
private let thumbnailStore = try? source("Features/Video/VideoThumbnailStore.swift")
private let viewModel = try source("Features/Video/VideoLibraryViewModel.swift")
private let playerScreen = try source("Features/Video/VideoPlayerScreen.swift")
    + source("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + source("Features/Video/VideoPlayerScreen+Chrome.swift")
    + source("Features/Video/VideoPlayerScreen+OSD.swift")
    + source("Features/Video/VideoPlayerScreen+Mining.swift")
    + source("Features/Video/VideoPlayerScreen+Opening.swift")
    + source("Features/Video/VideoPlayerScreen+Shortcuts.swift")
private let buildScript = try source("script/build_and_run_native.sh")
private let manualFixtureScript = try? source("script/verify_video_library_manual_fixture.sh")

require(
    !rootView.contains("isSelectingVideoFile")
        && !rootView.contains("lastNonVideoSection")
        && !rootView.contains("handleVideoFileImport")
        && !rootView.contains("VideoMediaTypes.contentTypes")
        && !rootView.contains("selection = lastNonVideoSection")
        && !rootView.contains("return lastNonVideoSection"),
    "Video sidebar selection should render the library page instead of immediately opening the file picker"
)
require(
    !rootView.contains("ProfileActivationCoordinator")
        && !rootView.contains("profileRepository")
        && !rootView.contains(".video(profileID:"),
    "Browsing the Video library must not activate or switch Profile state"
)
require(
    sidebarView.contains("List(selection: $selection)")
        && sidebarView.contains("ForEach(NativeMacSection.allCases)")
        && sidebarView.contains("HStack(spacing: 10)")
        && sidebarView.contains(".tag(section)")
        && sidebarView.contains(".listStyle(.sidebar)")
        && !sidebarView.contains("private func sidebarButton")
        && !sidebarView.contains(".buttonStyle(.plain)")
        && !sidebarView.contains(".accessibilityAction"),
    "Native main sidebar should keep the system List sidebar style from v0.6.0beta7 while Video selection renders the detail page"
)
require(
    detailView.contains("case .video:")
        && detailView.contains("VideoLibraryView(")
        && !detailView.contains("case .video:\n                EmptyView()"),
    "Native detail should render VideoLibraryView for the Video section"
)
require(
    detailView.contains("let onOpenVideo: (VideoPlaybackSource, URL?, Bool) -> Void")
        && detailView.contains("let onOpenRemoteVideo: (RemoteVideoWindowOpenRequest) -> Void")
        && rootView.contains("startsFromBeginning: Bool")
        && rootView.contains("func openRemoteVideoWindow(_ request: RemoteVideoWindowOpenRequest)")
        && rootView.contains("VideoWindowPresenter.shared.open(")
        && rootView.contains("subtitleURL: subtitleURL")
        && rootView.contains("startsFromBeginning: startsFromBeginning")
        && rootView.contains("remoteRequest: request")
        && rootView.contains("coordinator: videoWindowCoordinator"),
    "Native Video library routing should carry local subtitles, from-beginning intent, and unresolved remote requests into the dedicated player window"
)
require(
    rootView.contains(".toolbar(.visible, for: .windowToolbar)")
        && !rootView.contains(".toolbar(.hidden, for: .windowToolbar)")
        && !rootView.contains("isWindowToolbarVisible ? .visible : .hidden")
        && !rootView.contains("if selectedSection == .video {\n            return false\n        }"),
    "Video library should keep the native window toolbar visible so traffic lights and the sidebar toggle remain available"
)
require(
    buildScript.contains("INSTANCE_ID=\"${HOSHI_APP_INSTANCE_ID:-}\"")
        && buildScript.contains("DERIVED_DATA_PATH=\"${HOSHI_DERIVED_DATA_PATH:-}\"")
        && buildScript.contains("DERIVED_DATA_PATH=\"$ROOT_DIR/.build/xcode-derived-data-$INSTANCE_ID\"")
        && buildScript.contains("DERIVED_DATA_PATH=\"$ROOT_DIR/.build/xcode-derived-data\"")
        && buildScript.contains("-scheme \"$SCHEME_NAME\"")
        && buildScript.contains("-sdk macosx")
        && buildScript.contains("-derivedDataPath \"$DERIVED_DATA_PATH\"")
        && buildScript.contains("APP_BUNDLE=\"$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app\"")
        && buildScript.contains("matching_app_pids()")
        && !buildScript.contains("pkill -x \"$APP_NAME\"")
        && !buildScript.contains("-showBuildSettings")
        && !buildScript.contains("-destination \"generic/platform=macOS\"")
        && !buildScript.contains("simctl")
        && !buildScript.contains("DERIVED_DATA_GLOB")
        && !buildScript.contains("ls -dt $DERIVED_DATA_GLOB"),
    "build_and_run_native.sh should build macOS natively without simulator/device enumeration and launch the current project build product"
)
for file in [
    "Video/VideoLibraryStore.swift",
    "Video/VideoLibraryViewModel.swift",
    "Video/VideoLibraryView.swift",
] {
    require(project.contains(file), "project membership exceptions should include \(file)")
}
require(
    project.contains("Video/VideoThumbnailStore.swift"),
    "project membership exceptions should include the restored thumbnail store"
)
for key in [
    "Add Video Folder",
    "Add Smart Collection",
    "%@ left",
    "Clear Progress",
    "Continue Watching",
    "No Videos in Progress",
    "No Video Folders",
    "Partially watched videos will appear here.",
    "Play from Beginning",
    "Recent",
    "All Videos",
    "Folders",
    "Finished",
    "Loading Video...",
    "Mark as Watched",
    "Manage Sources",
    "Manual",
    "Missing",
    "Needs Review",
    "New Smart Collection",
    "No Videos Need Review",
    "Parent Folder",
    "Path",
    "Preview Matches",
    "Reveal in Finder",
    "Reveal Source in Finder",
    "Rule Field",
    "Rule Text",
    "Search Videos",
    "Smart",
    "Smart Collections",
    "Sort Videos",
    "Tag",
    "Unfinished",
    "Unwatched",
    "Watched",
    "%d in progress",
    "%d missing",
    "%d videos",
    "Last Scanned",
    "Add Collection",
    "Auto Subtitle",
    "Bind Subtitle",
    "Bound Subtitle",
    "Clear Selected Progress",
    "Clear Subtitle",
    "Collection Actions",
    "Collections",
    "Delete Collection",
    "Delete Collection?",
    "Details",
    "Display Title",
    "Favorite",
    "Favorite videos will appear here.",
    "Favorites",
    "List",
    "Mark Selected Watched",
    "Missing videos will appear here until their source is refreshed.",
    "Never scanned",
    "New Collection",
    "No Favorite Videos",
    "No Finished Videos",
    "No Missing Videos",
    "No Matching Videos",
    "No Unwatched Videos",
    "Organization",
    "Posters",
    "Remove Missing",
    "Save Metadata",
    "Refresh Source",
    "Refresh",
    "Remove",
    "Select a video to edit its local metadata.",
    "Series",
    "Untitled Collection",
    "Video Library",
    "Video Sources",
    "Video Library View",
    "Video Details",
    "Try a different search or filter.",
    "This removes the collection but keeps its videos in your library.",
    "Videos marked watched will appear here.",
    "Videos without playback progress will appear here.",
    "Videos outside manual and smart collections will appear here.",
] {
    require(localization.contains("\"\(key)\""), "Localizable.xcstrings should include \(key)")
}

let libraryView = try source("Features/Video/VideoLibraryView.swift")
require(
    libraryView.contains("var pendingResolvedRemoteSource: ResolvedRemoteVideoSource?")
        && libraryView.contains("isPresented: $isAddingLink,")
        && libraryView.contains("onDismiss: openResolvedRemoteSourceAfterSheetDismissal")
        && libraryView.contains("pendingResolvedRemoteSource = resolvedSource")
        && libraryView.contains("func openResolvedRemoteSourceAfterSheetDismissal()")
        && libraryView.contains("onOpenVideo(.remoteStream(resolvedSource), nil, false)"),
    "Add Link should finish dismissing its sheet before ordering the dedicated player window"
)
if let contentRange = libraryView.range(of: "private var content: some View"),
   let contentEnd = libraryView[contentRange.lowerBound...].range(of: "private func libraryContent(sections: [VideoLibrarySection]) -> some View")?.lowerBound {
    let contentBlock = libraryView[contentRange.lowerBound..<contentEnd]
    require(
        contentBlock.contains("let sections = viewModel.sections()")
            && contentBlock.contains("VideoLibrarySidebarView(")
            && contentBlock.contains("viewModel: viewModel,")
            && contentBlock.contains("mediaServers: mediaServers.accounts,")
            && contentBlock.contains("MediaServerBrowserView(")
            && contentBlock.contains(".frame(width: LibraryShelfLayout.sidebarWidth(for: availableContentWidth))")
            && contentBlock.contains("VideoLibraryContentHeader(")
            && contentBlock.contains("libraryContent(sections: sections)")
            && contentBlock.contains("NativeGlassPageBackground()")
            && !contentBlock.contains("VideoLibraryContentTitleBar")
            && !contentBlock.contains(".frame(width: 240)")
            && !contentBlock.contains("onAddFolder: presentFolderImporter")
            && !contentBlock.contains("ContentUnavailableView")
            && !contentBlock.contains("viewModel.isSelectingFolder = true"),
        "Video library shell should share the Bookshelf shelf-column width and compute sections once for the header and content"
    )
} else {
    require(false, "Video library content shell should be present before libraryContent")
}
require(
    libraryView.contains("var isReadyForSourceActions = false")
        && libraryView.contains("var isManagingSources = false")
        && libraryView.contains("armSourceActions()")
        && libraryView.contains("onAddFolder: presentFolderImporter")
        && libraryView.contains("onManageSources: { isManagingSources = true }")
        && libraryView.contains(".sheet(isPresented: $isManagingSources)")
        && libraryView.contains("func presentFolderImporter()")
        && libraryView.contains("guard isReadyForSourceActions else { return }")
        && libraryView.contains("NSOpenPanel()")
        && libraryView.contains("panel.canChooseDirectories = true")
        && libraryView.contains("panel.canChooseFiles = false")
        && libraryView.contains("panel.allowsMultipleSelection = true")
        && libraryView.contains("viewModel.addFolders(.success(panel.urls))")
        && !libraryView.contains("isPresented: $viewModel.isSelectingFolder")
        && !libraryView.contains("allowedContentTypes: [.folder]")
        && !viewModel.contains("var isSelectingFolder"),
    "Video folder import should go through one guarded NSOpenPanel path"
)
if let sidebarRange = libraryView.range(of: "private struct VideoLibrarySidebarView"),
   let sidebarEnd = libraryView[sidebarRange.lowerBound...].range(of: "private extension VideoLibraryDisplayMode")?.lowerBound {
    let sidebar = libraryView[sidebarRange.lowerBound..<sidebarEnd]
    require(
        sidebar.contains("let counts = viewModel.modeCounts()")
            && sidebar.contains("List(selection: sidebarSelection)")
            && sidebar.contains("Section(\"Media Servers\")")
            && sidebar.contains(".listStyle(.sidebar)\n        .scrollContentBackground(.hidden)\n        .background(.clear)")
            && sidebar.contains("ForEach(VideoLibraryDisplayMode.libraryModes)")
            && sidebar.contains("Section(\"Organization\")")
            && sidebar.contains("ForEach(VideoLibraryDisplayMode.organizationModes)")
            && sidebar.contains("(counts[.missing] ?? 0) > 0 || viewModel.displayMode == .missing")
            && sidebar.contains(".badge(count ?? 0)")
            && !sidebar.contains("Toggle(isOn: $viewModel.showUnfinishedOnly)")
            && !sidebar.contains(".safeAreaInset(edge: .bottom)")
            && !sidebar.contains("Section(\"Video Sources\")"),
        "Video library modes should use a shelf-style column with counts and only surface Missing when it has videos"
    )
} else {
    require(false, "Video library sidebar should be present before its display mode helpers")
}
require(
    libraryView.contains(".continueWatching, .recent, .all, .unwatched, .finished, .favorites,")
        && libraryView.contains(".series, .folders, .collections, .needsReview,")
        && viewModel.contains("func modeCounts() -> [VideoLibraryDisplayMode: Int]")
        && viewModel.contains("counts[.collections] = catalog.collections.count"),
    "Video library mode column should order playback modes before organization modes and read counts from the view model"
)
if let sourceActionsRange = libraryView.range(of: "private struct VideoLibrarySourceToolbarButtons"),
   let sourceActionsEnd = libraryView[sourceActionsRange.lowerBound...].range(of: "private struct VideoLibraryContentHeader")?.lowerBound {
    let sourceActions = libraryView[sourceActionsRange.lowerBound..<sourceActionsEnd]
    require(
        sourceActions.contains("Label(\"Refresh\", systemImage: \"arrow.clockwise\")")
            && sourceActions.contains("Label(\"Manage Sources\", systemImage: \"folder.badge.gearshape\")")
            && sourceActions.contains("Label(\"Add Video Folder\", systemImage: \"folder.badge.plus\")")
            && sourceActions.contains("Label(\"Add Link\", systemImage: \"link.badge.plus\")")
            && sourceActions.contains("Label(\"Add\", systemImage: \"plus\")")
            && sourceActions.contains("viewModel.refreshAllSources()")
            && sourceActions.contains("onAddFolder()")
            && sourceActions.contains("onAddLink()")
            && sourceActions.contains("onManageSources()")
            && sourceActions.contains(".disabled(!viewModel.hasSources || viewModel.isScanning)")
            && sourceActions.contains(".disabled(!isReadyForSourceActions)")
            && sourceActions.contains(".disabled(!viewModel.hasSources)")
            && !sourceActions.contains(".buttonBorderShape(.circle)")
            && !sourceActions.contains(".background(.thinMaterial)"),
        "Video source actions should be plain system toolbar items, with folder and link imports behind the Add menu"
    )
} else {
    require(false, "Video library source toolbar buttons should be present before the content header")
}
require(
    store.contains("enum VideoLibraryCollectionKind")
        && store.contains("struct VideoLibrarySmartRule")
        && store.contains("func createSmartCollection")
        && viewModel.contains("case needsReview")
        && viewModel.contains("func smartCollectionPreviewRows")
        && viewModel.contains("func createSmartCollection"),
    "Video library should include a lightweight smart collection model and Needs Review view-model support"
)
require(
    libraryView.contains("smartCollectionsSection")
        && libraryView.contains("Label(\"New Smart Collection\"")
        && libraryView.contains("Label(\"Add Smart Collection\"")
        && libraryView.contains("Text(\"Preview Matches\")")
        && libraryView.contains("VideoLibrarySmartRuleField"),
    "Video library UI should expose Needs Review and a first-pass smart collection editor"
)
require(
    viewModel.contains("var usesCollapsibleSections")
        && viewModel.contains("case .series, .folders, .collections:")
        && viewModel.contains("organization.folderPath")
        && libraryView.contains("var collapsedSectionIDs: Set<String> = []")
        && !libraryView.contains("expandedSectionIDs")
        && libraryView.contains("VideoLibraryCollapsibleSectionHeader(")
        && libraryView.contains("isExpanded: sectionExpansionBinding(for: section)")
        && libraryView.contains("get: { !collapsedSectionIDs.contains(section.id) }")
        && libraryView.contains("if !collapsedSectionIDs.contains(section.id)")
        && libraryView.contains("count: section.rows.count"),
    "Grouped Series, Folders, and Collections sections should start expanded and stay individually collapsible"
)
if let listRange = libraryView.range(of: "else if viewModel.layoutMode == .list"),
   let listEnd = libraryView[listRange.lowerBound...].range(of: "} else {\n            VideoLibraryPosterGridView(")?.lowerBound {
    let listLayout = libraryView[listRange.lowerBound..<listEnd]
    require(
        listLayout.contains("VideoLibraryCollapsibleSectionHeader(")
            && listLayout.contains("shouldHideSingleSectionHeader(for: sections)")
            && listLayout.contains("ForEach(section.rows)")
            && listLayout.contains("Section(section.title)")
            && listLayout.contains(".scrollContentBackground(.hidden)")
            && listLayout.contains(".background(.clear)")
            && !listLayout.contains("DisclosureGroup("),
        "Video list layout should share the collapsible header, hide duplicate single-filter titles, and reveal the native page background"
    )
} else {
    require(false, "Video list layout should be inspectable before the poster layout")
}
if let collapsibleHeaderRange = libraryView.range(of: "private struct VideoLibraryCollapsibleSectionHeader"),
   let collapsibleHeaderEnd = libraryView[collapsibleHeaderRange.lowerBound...].range(of: "private struct VideoLibraryCollectionActionsMenu")?.lowerBound {
    let collapsibleHeader = libraryView[collapsibleHeaderRange.lowerBound..<collapsibleHeaderEnd]
    require(
        collapsibleHeader.contains("Button {")
            && collapsibleHeader.contains("isExpanded.toggle()")
            && collapsibleHeader.contains("Image(systemName: \"chevron.right\")")
            && collapsibleHeader.contains(".rotationEffect(.degrees(isExpanded ? 90 : 0))")
            && collapsibleHeader.contains(".font(.title3.weight(.semibold))")
            && collapsibleHeader.contains(".frame(maxWidth: .infinity, minHeight: 28")
            && collapsibleHeader.contains(".contentShape(Rectangle())")
            && collapsibleHeader.contains(".buttonStyle(.plain)"),
        "Collapsible video section titles should use one full-width button in both list and poster layouts"
    )
} else {
    require(false, "Shared collapsible video section header should be present before collection actions")
}
for forbidden in [
    "PythonKit",
    "import Python",
    "import JavaScriptCore",
    "node_modules",
    "Anitomy",
    "TMDb",
    "TVDb",
] {
    require(
        !store.contains(forbidden)
            && !viewModel.contains(forbidden)
            && !libraryView.contains(forbidden),
        "Video library smart collections should not introduce heavy parser or metadata dependencies: \(forbidden)"
    )
}
require(
    libraryView.contains(".toolbar {")
        && libraryView.contains("videoToolbarContent")
        && libraryView.contains("@ToolbarContentBuilder")
        && libraryView.contains("var videoToolbarContent: some ToolbarContent")
        && libraryView.components(separatedBy: "ToolbarItemGroup(placement: .primaryAction)").count == 2
        && libraryView.contains("text: searchTextBinding,\n                placement: .toolbar,")
        && libraryView.contains("prompt: selectedMediaServerBrowser == nil ? Text(\"Search Videos\") : Text(\"Search Server\")")
        && libraryView.contains("return $viewModel.searchText")
        && libraryView.contains("var availableContentWidth: CGFloat = .infinity")
        && libraryView.contains(".onGeometryChange(for: CGFloat.self)")
        && libraryView.contains("availableContentWidth >= 760")
        && libraryView.contains("Picker(\"Sort Videos\", selection: $viewModel.sortOption)")
        && libraryView.contains("Label(\"Sort Videos\", systemImage: \"arrow.up.arrow.down\")")
        && libraryView.contains("Picker(\"Video Library View\", selection: $viewModel.layoutMode)")
        && libraryView.contains(".pickerStyle(.segmented)")
        && libraryView.contains("LibraryCoverSizeButton(width: $posterSize)")
        && !libraryView.contains("NSPopUpButton")
        && !libraryView.contains("NSSegmentedControl")
        && !libraryView.contains("VideoLibraryCompactToolbarMenu")
        && !libraryView.contains("VideoLibrarySearchField")
        && !libraryView.contains("ToolbarSpacer")
        && !libraryView.contains("VideoLibraryToolbarControlSurface"),
    "Video library toolbar should mirror the Bookshelf toolbar: sort menu, layout, cover size, source actions, and native toolbar search"
)
if let toolbarRange = libraryView.range(of: "private var videoToolbarContent: some ToolbarContent"),
   let toolbarEnd = libraryView[toolbarRange.lowerBound...].range(of: "@ViewBuilder\n    private var content")?.lowerBound {
    let toolbar = libraryView[toolbarRange.lowerBound..<toolbarEnd]
    let sortIndex = toolbar.range(of: "VideoLibrarySortMenu(viewModel: viewModel)")?.lowerBound
    let layoutIndex = toolbar.range(of: "VideoLibraryLayoutPicker(viewModel: viewModel)")?.lowerBound
    // The media server branch has its own size button; check the library branch.
    let sizeIndex = sortIndex.flatMap {
        toolbar[$0...].range(of: "LibraryCoverSizeButton(width: $posterSize)")?.lowerBound
    }
    let sourceIndex = toolbar.range(of: "VideoLibrarySourceToolbarButtons(")?.lowerBound
    require(
        sortIndex != nil
            && layoutIndex != nil
            && sizeIndex != nil
            && sourceIndex != nil
            && sortIndex! < layoutIndex!
            && layoutIndex! < sizeIndex!
            && sizeIndex! < sourceIndex!
            && toolbar.contains("if viewModel.layoutMode == .posters {"),
        "Video library toolbar should order sort, layout, poster size (posters only), then source actions"
    )
    require(
        !toolbar.contains("HStack(")
            && !toolbar.contains("ScrollView(.horizontal")
            && !toolbar.contains("GlassEffectContainer")
            && !toolbar.contains(".background(Color("),
        "Video library toolbar should use one system group without a custom strip"
    )
} else {
    require(false, "Video library toolbar should be present before the content shell")
}
require(
    libraryView.contains("@AppStorage(\"videoLibraryLayoutMode\")")
        && libraryView.contains("@AppStorage(\"videoLibraryPosterWidth\")")
        && libraryView.contains("viewModel.layoutMode = VideoLibraryLayoutMode(rawValue: storedLayoutMode) ?? .posters")
        && libraryView.contains("storedLayoutMode = layoutMode.rawValue"),
    "Video library should remember the chosen layout and poster size"
)
if let headerRange = libraryView.range(of: "private struct VideoLibraryContentHeader"),
   let headerEnd = libraryView[headerRange.lowerBound...].range(of: "struct RemoteVideoLinkSheet")?.lowerBound {
    let header = libraryView[headerRange.lowerBound..<headerEnd]
    require(
        header.contains("LibraryShelfDetailHeader(")
            && header.contains("title: Text(LocalizedStringKey(viewModel.displayMode.titleKey))")
            && header.contains("count: count")
            && header.contains("if usesModeMenu {")
            && header.contains("Picker(\"Video Library\", selection: $viewModel.displayMode)")
            && header.contains("Picker(\"Organization\", selection: $viewModel.displayMode)")
            && !header.contains(".background(.bar)"),
        "Video library header should reuse the shelf detail header and turn into the mode menu when the column is hidden"
    )
} else {
    require(false, "Video library content header should be present before the remote link sheet")
}
require(
    libraryView.contains("if viewModel.selectedRow != nil {")
        && libraryView.contains("VideoLibraryInspectorView(")
        && libraryView.contains("onOpen: { item in open(item, fromBeginning: false) }")
        && libraryView.contains("onOpenFromBeginning: { item in open(item, fromBeginning: true) }"),
    "Video library details inspector should appear only after a video is selected and play through the shared open path"
)
require(
    thumbnailStore != nil
        && thumbnailStore!.contains("actor VideoThumbnailScheduler")
        && libraryView.contains("VideoThumbnailScheduler.shared")
        && libraryView.contains("VideoThumbnailImageView")
        && libraryView.contains("VideoLibraryPosterGridView")
        && libraryView.contains("VideoLibraryPosterCardView")
        && libraryView.contains("VideoLibraryPosterArtworkView")
        && libraryView.contains("VideoLibraryProgressTrack")
        && libraryView.contains("thumbnailRequestMode: .generateIfMissing")
        && libraryView.contains("requestMode: .generateIfMissing")
        && !libraryView.contains("globallyGeneratedThumbnailItemIDs")
        && !libraryView.contains("sections.flatMap(\\.rows).prefix(8)")
        && libraryView.contains("requestMode.taskIdentity")
        && libraryView.contains("var thumbnailTaskID: String")
        && !libraryView.contains("index < 8")
        && !libraryView.contains("generatesMissingThumbnail")
        && libraryView.contains("LazyVStack(alignment: .leading, spacing: VideoLibraryPosterLayout.sectionSpacing)")
        && libraryView.contains("LazyVGrid"),
    "Video library should keep visible thumbnails that generate when missing, with mode-aware thumbnail tasks and lazy sections"
)
if let posterCardRange = libraryView.range(of: "private struct VideoLibraryPosterCardView"),
   let posterCardEnd = libraryView[posterCardRange.lowerBound...].range(of: "private struct VideoLibraryItemContextMenu")?.lowerBound {
    let posterCard = libraryView[posterCardRange.lowerBound..<posterCardEnd]
    require(
        posterCard.contains("VideoLibraryPosterArtworkView(")
            && posterCard.contains("Text(row.displayTitle)")
            && posterCard.contains("VideoLibraryPlaybackText.location(for: row)")
            && posterCard.contains("VideoLibraryDetailsButton(onSelect: onSelect, isArtworkOverlay: true)")
            && posterCard.contains("VideoLibraryItemContextMenu(")
            && !posterCard.contains(".videoLibraryNeutralCardSurface")
            && !posterCard.contains(".nativeGlassCardSurface"),
        "Video poster cards should be borderless artwork plus title, without a surrounding card surface"
    )
} else {
    require(false, "Video poster card should be inspectable before the shared item context menu")
}
if let artworkRange = libraryView.range(of: "private struct VideoLibraryPosterArtworkView"),
   let artworkEnd = libraryView[artworkRange.lowerBound...].range(of: "private struct VideoThumbnailImageView")?.lowerBound {
    let artwork = libraryView[artworkRange.lowerBound..<artworkEnd]
    require(
        artwork.contains("VideoLibraryPlaybackText.state(for: row)")
            && artwork.contains("VideoLibraryProgressTrack(progress: progress)")
            && artwork.contains("row.metadata.isFavorite")
            && artwork.contains(".glassEffect(.regular.tint(.black.opacity(0.25)), in: Circle())")
            && artwork.contains(".strokeBorder(Color.accentColor, lineWidth: 2.5)")
            && !artwork.contains("Material"),
        "Video poster artwork should carry playback state, favorite, hover play, and selection on the frame itself"
    )
} else {
    require(false, "Video poster artwork should be inspectable before the thumbnail view")
}
if let rowRange = libraryView.range(of: "private struct VideoLibraryRowView"),
   let rowEnd = libraryView[rowRange.lowerBound...].range(of: "private struct VideoLibraryDetailsButton")?.lowerBound {
    let rowView = libraryView[rowRange.lowerBound..<rowEnd]
    require(
        rowView.contains("VideoThumbnailImageView(")
            && rowView.contains("requestMode: .generateIfMissing")
            && rowView.contains("Text(row.sourceName)")
            && rowView.contains("Text(row.item.parentFolder)")
            && rowView.contains("VideoLibraryPlaybackText.fileSizeFormatter.string(fromByteCount: row.item.fileSize)")
            && rowView.contains("Text(modifiedAt, style: .date)")
            && rowView.contains("VideoLibraryProgressTrack(progress: progress, height: 3)")
            && rowView.contains("VideoLibraryPlaybackText.state(for: row)")
            && rowView.contains("Text(row.displayTitle)")
            && !rowView.contains("Text(row.item.title)")
            && rowView.contains("VideoLibraryDetailsButton(onSelect: onSelect)")
            && rowView.contains(".opacity(isHovered || isSelected ? 1 : 0)")
            && rowView.contains(".listRowBackground("),
        "Video library list rows should show display titles, source, folder, size, modified date, progress/state, and a hover Details control"
    )
} else {
    require(false, "Video library row view should be present before details button")
}
require(
    libraryView.contains("Label(\"Mark as Watched\"")
        && libraryView.contains("Label(\"Clear Progress\"")
        && libraryView.contains("Label(\"Play from Beginning\""),
    "Video library row context menu should expose playback state actions"
)
require(
    libraryView.contains("VideoLibraryInspectorView")
        && libraryView.contains("TextField(\"Display Title\"")
        && libraryView.contains("Toggle(\"Favorite\"")
        && libraryView.contains("TextField(\"Tags\"")
        && libraryView.contains("Label(\"Bind Subtitle\"")
        && libraryView.contains("Label(\"Clear Subtitle\"")
        && libraryView.contains("TextField(\"New Collection\"")
        && libraryView.contains("Label(\"Add Collection\"")
        && libraryView.contains("Label(\"Mark Selected Watched\"")
        && libraryView.contains("Label(\"Clear Selected Progress\"")
        && libraryView.contains("Label(\"Remove Missing\""),
    "Video library should expose a detail inspector for V3 metadata, subtitles, collections, and batch actions"
)
require(
    libraryView.contains("VideoLibraryInspectorCard")
        && libraryView.contains("VideoLibraryInspectorActionButtonStyle")
        && libraryView.contains("VideoLibraryInspectorInputSurface")
        && libraryView.contains(".videoLibraryInspectorInput()")
        && libraryView.contains(".videoLibraryNeutralCardSurface(cornerRadius: 14)")
        && libraryView.contains("GlassEffectContainer(spacing: 12)")
        && libraryView.contains("NativeGlassMenuPicker(")
        && libraryView.contains("selection: $smartCollectionRuleField")
        && !libraryView.contains("Picker(\"Rule Field\", selection: $smartCollectionRuleField)"),
    "Video library inspector should use neutral cards with macOS 26 inputs, action buttons, and menu picker instead of default material controls"
)
if let inspectorCardRange = libraryView.range(of: "private struct VideoLibraryInspectorCard"),
   let inspectorCardEnd = libraryView[inspectorCardRange.lowerBound...].range(of: "private struct VideoLibraryNeutralCardSurface")?.lowerBound {
    let inspectorCard = libraryView[inspectorCardRange.lowerBound..<inspectorCardEnd]
    require(
        inspectorCard.contains(".videoLibraryNeutralCardSurface(cornerRadius: 14)")
            && !inspectorCard.contains(".nativeGlassCardSurface"),
        "Video inspector cards should use the neutral card surface instead of a material glass background"
    )
} else {
    require(false, "Video inspector card should be inspectable before neutral card surface")
}
require(
    libraryView.contains("VideoLibraryDetailsButton(onSelect: onSelect)")
        && libraryView.contains("struct VideoLibraryDetailsButton")
        && libraryView.contains("Button(action: onSelect)")
        && libraryView.contains(".help(\"Details\")")
        && libraryView.contains(".accessibilityLabel(Text(\"Details\"))"),
    "Video library rows should expose a visible Details control that selects without opening playback"
)
require(
    libraryView.contains("let onOpenVideo: (VideoPlaybackSource, URL?, Bool) -> Void")
        && libraryView.contains("let onOpenRemoteVideo: (RemoteVideoWindowOpenRequest) -> Void")
        && libraryView.contains("viewModel.remoteWindowOpenRequest(")
        && libraryView.contains("onOpenRemoteVideo(request)")
        && libraryView.contains("viewModel.openPlaybackSource(for: item)")
        && libraryView.contains("open(row.item, fromBeginning: false)")
        && libraryView.contains("open(row.item, fromBeginning: true)")
        && libraryView.contains("viewModel.subtitleURLForOpening(item)")
        && libraryView.contains("fromBeginning\n            )"),
    "Video library items should open unresolved remote videos immediately while preserving local subtitles and from-beginning intent"
)
require(
    libraryView.contains("viewModel.sourceSummaries")
        && libraryView.contains("summary.itemCount")
        && libraryView.contains("summary.inProgressCount")
        && libraryView.contains("summary.missingCount")
        && libraryView.contains("Label(\"Refresh Source\"")
        && libraryView.contains("Label(\"Reveal Source in Finder\""),
    "Video source management should show source status counts and per-source actions"
)
require(
    libraryView.contains("VideoPlaybackHistoryStore.didChangeNotification")
        && libraryView.contains("changedIdentityPersistenceKey:")
        && !libraryView.contains("UserDefaults.didChangeNotification"),
    "Video library should refresh only the changed playback-history identity"
)
require(
    viewModel.contains("playbackHistoryRevision")
        && viewModel.contains("func refreshPlaybackHistory(")
        && viewModel.contains("playbackStatesByIdentity")
        && viewModel.contains("_ = playbackHistoryRevision"),
    "Video library view model should cache playback state behind an observable refresh revision"
)
require(
    viewModel.contains("case continueWatching")
        && viewModel.contains("case unwatched")
        && viewModel.contains("case finished")
        && viewModel.contains("case missing")
        && viewModel.contains("enum VideoLibraryLayoutMode")
        && viewModel.contains("layoutMode")
        && viewModel.contains("VideoLibrarySourceSummary")
        && viewModel.contains("sourceSummaries")
        && viewModel.contains("func refreshSource")
        && viewModel.contains("func markWatched")
        && viewModel.contains("func clearProgress")
        && viewModel.contains("func openFromBeginningURL"),
    "Video library view model should support smart filters, source summaries, and playback state actions without layout mode state"
)
require(
    viewModel.contains("func setCollectionMembership")
        && viewModel.contains("func removeCollection"),
    "Video library view model should support editing collection membership from the V3 inspector"
)
require(
    libraryView.contains("var pendingCollectionDeletion: VideoLibraryCollection?")
        && libraryView.contains("VideoLibraryCollapsibleSectionHeader(")
        && libraryView.contains("onDeleteCollection:")
        && libraryView.contains("VideoLibraryCollectionActionsMenu(onDeleteCollection: onDeleteCollection)")
        && libraryView.contains("struct VideoLibraryCollectionActionsGlassEffect")
        && libraryView.contains(".menuStyle(.borderlessButton)")
        && libraryView.contains("Image(systemName: \"ellipsis\")")
        && libraryView.contains("GlassEffectContainer(spacing: 0)")
        && libraryView.contains(".glassEffect(.regular.interactive(), in: Circle())")
        && libraryView.contains("Label(\"Delete Collection\", systemImage: \"trash\")")
        && libraryView.contains(".alert(\"Delete Collection?\"")
        && libraryView.contains("This removes the collection but keeps its videos in your library."),
    "Video library collections view should expose a macOS 26 glass delete collection action with a no-video-deletion confirmation"
)
if let removeRange = store.range(of: "func removeCollection"),
   let removeEnd = store[removeRange.lowerBound...].range(of: "@discardableResult\n    func removeMissingItems")?.lowerBound {
    let removeBlock = store[removeRange.lowerBound..<removeEnd]
    require(
        !removeBlock.contains("removeItem(")
            && !removeBlock.contains("fileManager.remove")
            && !removeBlock.contains("catalog.items.removeAll"),
        "Video library collection deletion should not delete files or remove catalog video items"
    )
} else {
    require(false, "Video library store should keep an inspectable removeCollection implementation")
}
require(
    thumbnailStore?.contains("case cacheOnly") == true
        && thumbnailStore?.contains("case generateIfMissing") == true
        && thumbnailStore?.contains("var taskIdentity: String") == true
        && thumbnailStore?.contains("runningTask?.cancel()") == true
        && thumbnailStore?.contains("isCancelled: { Task.isCancelled }") == true
        && thumbnailStore?.contains("static let maximumConcurrentJobs = 1") == true
        && thumbnailStore?.contains("static let maximumDimension = 384") == true,
    "Video thumbnail store should enforce cache/generate request modes, mode identities, cancellable single concurrency, and 384px maximum thumbnails"
)
require(
    viewModel.contains("No Matching Videos")
        && viewModel.contains("Try a different search or filter."),
    "Video library view model should expose filtered empty-state copy"
)
require(
    playerScreen.contains("switch request.source")
        && playerScreen.contains("case .playback(let source):")
        && playerScreen.contains("startsFromBeginning: request.startsFromBeginning")
        && playerScreen.contains("case .unresolvedRemote(let remoteRequest):")
        && playerScreen.contains("openRemoteVideo(remoteRequest)")
        && playerScreen.contains("isResolvingRemoteVideo")
        && playerScreen.contains("Text(\"Loading Video...\")")
        && playerScreen.contains("VideoLibraryStore.shared.addRemoteItem(resolvedSource)")
        && playerScreen.contains("remoteVideoOpenTask = nil")
        && !playerScreen.contains("VideoLibraryStore().addRemoteItem(resolvedSource)")
        && !playerScreen.contains(
            """
            if model.snapshot.isPlaying {
                        model.togglePlayback()
                    }
            """
        ),
    "Video player should preserve active playback while resolving, share resolved catalog metadata, and carry from-beginning intent into playback"
)
require(
    store.contains("HOSHI_VIDEO_LIBRARY_CATALOG_URL")
        && store.contains("ProcessInfo.processInfo.environment")
        && store.contains("@MainActor static let shared = VideoLibraryStore()")
        && viewModel.contains("let resolvedStore = store ?? .shared"),
    "Video library store should support a catalog override for disposable UI validation and share the live catalog between library and player"
)
require(
    store.contains("item.localURL")
        && remoteSource.contains("fileURLWithPath: path,")
        && remoteSource.contains("isDirectory: false")
        && viewModel.contains("fileURLWithPath: source.path,")
        && viewModel.contains("isDirectory: true"),
    "Video library row construction should use explicit file and directory URL hints without filesystem probing"
)
require(
    buildScript.contains("HOSHI_VIDEO_LIBRARY_CATALOG_URL")
        && buildScript.contains("--env"),
    "native launch script should pass the disposable Video library catalog override into the launched app"
)
require(
    manualFixtureScript?.contains("HOSHI_VIDEO_LIBRARY_CATALOG_URL") == true
        && manualFixtureScript?.contains("mktemp -d") == true
        && manualFixtureScript?.contains("./script/build_and_run.sh --verify") == true,
    "Video library manual fixture script should launch the full build with a disposable catalog"
)

print("Video library contract tests passed")
