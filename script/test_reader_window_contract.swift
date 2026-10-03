import Foundation

private func read(_ path: String) -> String {
    guard let value = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("FAIL: unable to read \(path)\n", stderr)
        exit(1)
    }
    return value
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func requireNotContains(_ source: String, _ needle: String, _ message: String) {
    guard !source.contains(needle) else {
        fputs("FAIL: \(message)\nUnexpected: \(needle)\n", stderr)
        exit(1)
    }
}

let app = read("NativeMac/HoshiNativeMacApp.swift")
let root = read("NativeMac/NativeMacRootView.swift")
let detail = read("NativeMac/NativeMacDetailView.swift")
let placeholders = read("NativeMac/NativeMacPlaceholderViews.swift")
let nativeReuse = read("NativeMac/NativeReuseViews.swift")
let shelf = read("Features/Bookshelf/ShelfView.swift")
let bookshelf = read("Features/Bookshelf/BookshelfView.swift")
let dictionaryManager = read("Core/DictionaryManager.swift")
let reader = read("NativeMac/NativeReaderView.swift")
let coordinator = read("NativeMac/ReaderWindowCoordinator.swift")
let presenter = read("NativeMac/ReaderWindowPresenter.swift")

require(
    !root.contains(".id(selectedSection)"),
    "Main module switching should keep one stable detail host instead of forcing full identity replacement"
)
require(
    dictionaryManager.contains("guard activeProfileID != profileID else { return }"),
    "Dictionary profile activation should skip same-profile reloads and lookup-query rebuilds"
)

require(
    coordinator.contains("struct ReaderWindowOpenRequest: Identifiable, Equatable")
        && coordinator.contains("static let windowID = \"reader\"")
        && coordinator.contains("private(set) var pendingRequest: ReaderWindowOpenRequest?")
        && (coordinator.contains("private(set) var currentRequest: ReaderWindowOpenRequest?")
            || coordinator.contains("private(set) var currentBook: BookMetadata?"))
        && coordinator.contains("private(set) var sessionID = UUID()")
        && coordinator.contains("private(set) var isWindowPresented = false")
        && coordinator.contains("func requestOpen(_ book: BookMetadata)")
        && coordinator.contains("func consume(_ requestID: UUID)")
        && coordinator.contains("func windowDidAppear()")
        && coordinator.contains("func windowDidDisappear()"),
    "ReaderWindowCoordinator should mirror the dedicated Video window coordinator shape for book requests"
)

require(
    coordinator.contains("pendingRequest = request")
        && (coordinator.contains("currentRequest = request") || coordinator.contains("currentBook = book"))
        && coordinator.contains("pendingRequest = nil")
        && coordinator.contains("isWindowPresented = true")
        && coordinator.contains("isWindowPresented = false")
        && coordinator.contains("Notification.Name")
        && coordinator.contains("closeRequestIDUserInfoKey")
        && coordinator.contains("readerWindowWillClose")
        && coordinator.contains("readerWindowProgressDidChange"),
    "ReaderWindowCoordinator should retain current book state, consume pending requests and define Reader window lifecycle signals"
)

require(
    coordinator.contains("currentBook != book")
        && !coordinator.contains("currentBook?.id != book.id"),
    "ReaderWindowCoordinator should invalidate Reader model identity when full BookMetadata changes, not only when id changes"
)

require(
    coordinator.contains("if isWindowPresented,")
        && coordinator.contains("currentRequest.book == book")
        && coordinator.contains("return currentRequest"),
    "reopening the already presented book should reuse its existing Reader request and model"
)

require(
    coordinator.contains("@ObservationIgnored private(set) var currentModel: NativeReaderModel?")
        && coordinator.contains("let model = NativeReaderModel(book: book)")
        && coordinator.contains("currentModel = model")
        && coordinator.contains("currentModel = nil")
        && presenter.contains("let model = readerWindowCoordinator.currentModel")
        && presenter.contains("model: model")
        && reader.contains("let model: NativeReaderModel")
        && !reader.contains("_model = State(initialValue: NativeReaderModel(book: book))"),
    "the Reader coordinator should own one stable model per request instead of letting duplicate SwiftUI loaders create stale models"
)

if let modelAssignment = coordinator.range(of: "currentModel = model"),
   let requestPublication = coordinator.range(of: "pendingRequest = request") {
    require(
        modelAssignment.lowerBound < requestPublication.lowerBound,
        "the ignored current model must be installed before publishing the observed request"
    )
} else {
    require(false, "Reader model/request assignment order should be inspectable")
}

require(
    app.contains("var readerWindowCoordinator = ReaderWindowCoordinator()")
        && app.contains(".environment(readerWindowCoordinator)")
        && app.contains("func applicationWillTerminate(_ notification: Notification)")
        && app.contains("ReaderWindowPresenter.shared.persistFrameForApplicationTermination()")
        && !app.contains("Window(\"Reader\"")
        && !app.contains("WindowGroup(\"Reader\""),
    "App should provide the shared Reader coordinator, persist its frame on app termination and avoid a SwiftUI Reader scene that can replace the main window"
)

require(
    presenter.contains("final class ReaderWindowPresenter: NSObject, NSWindowDelegate")
        && presenter.contains("static let shared = ReaderWindowPresenter()")
        && presenter.contains("weak var coordinator: ReaderWindowCoordinator?")
        && presenter.contains("NSWindow(")
        && presenter.contains("styleMask: [.titled, .closable, .miniaturizable, .resizable]")
        && presenter.contains("window.identifier = NSUserInterfaceItemIdentifier(ReaderWindowCoordinator.windowID)")
        && presenter.contains("window.minSize = ReaderWindowGeometry.minimumSize")
        && presenter.contains("window.isReleasedWhenClosed = false")
        && presenter.contains("static let frameAutosaveName")
        && presenter.contains("static let frameAutosaveMigrationKey")
        && presenter.contains("restoreSavedFrameOrApplyDefault(to: window)")
        && presenter.contains("window.setFrameUsingName(Self.frameAutosaveName)")
        && presenter.contains("ReaderWindowGeometry.shouldUseSavedFrame(")
        && !presenter.contains("window.setFrameAutosaveName")
        && presenter.contains("window.saveFrame(usingName: Self.frameAutosaveName)")
        && presenter.contains("func persistFrameForApplicationTermination()")
        && presenter.contains("func persistWindowedFrameIfNeeded(_ window: NSWindow)")
        && presenter.contains("guard !window.styleMask.contains(.fullScreen) else { return }")
        && presenter.contains("reader.windowFrame.save")
        && presenter.contains("persistWindowedFrameIfNeeded(closingWindow)")
        && presenter.contains("UserDefaults.standard.set(true, forKey: Self.frameAutosaveMigrationKey)")
        && presenter.contains("window.setFrame(defaultFrame, display: true)")
        && presenter.contains("ReaderWindowGeometry.defaultFrame(visibleFrame: visibleFrame)")
        && !presenter.contains("visibleFrame.width * 2 / 3")
        && !presenter.contains("visibleFrame.height * 2 / 3")
        && presenter.contains("window.isRestorable = false")
        && presenter.contains("window.collectionBehavior.insert(.fullScreenPrimary)")
        && presenter.contains("window.styleMask.insert(.fullSizeContentView)")
        && presenter.contains("window.titleVisibility = .hidden")
        && presenter.contains("window.titlebarAppearsTransparent = true")
        && presenter.contains("window.isMovableByWindowBackground = true")
        && presenter.contains("NSApp.keyWindow?.screen?.visibleFrame")
        && presenter.contains("window.deminiaturize(nil)")
        && presenter.contains("window.makeKeyAndOrderFront(nil)")
        && presenter.contains("NSApp.activate()")
        && presenter.contains("Logger(subsystem: \"moe.shishamo.hoshi\", category: \"ReaderPersistence\")")
        && presenter.contains("reader.windowWillClose.beforeCoordinatorReset")
        && presenter.contains("coordinator?.currentRequest?.id")
        && presenter.contains("userInfo: [ReaderWindowCoordinator.closeRequestIDUserInfoKey: requestID]")
        && presenter.contains("NotificationCenter.default.post(")
        && presenter.contains("name: .readerWindowWillClose")
        && presenter.contains("object: closingWindow")
        && presenter.contains("coordinator?.windowDidDisappear()"),
    "ReaderWindowPresenter should create and foreground one ordinary AppKit Reader window with transparent title chrome, use explicit saved-frame restoration across window close and app termination without late AppKit autosave overwrites, apply a full visible-screen default size, notify Reader content before close and reset coordinator on close"
)

require(
    presenter.contains("func scheduleWindowRelease(_ closingWindow: NSWindow)")
        && presenter.contains("let closingWindowID = ObjectIdentifier(closingWindow)")
        && presenter.contains("DispatchQueue.main.async { [weak self] in")
        && !presenter.contains("[weak self, closingWindow]")
        && presenter.contains("ObjectIdentifier(closingWindow) == closingWindowID")
        && presenter.contains("closingWindow.delegate = nil")
        && presenter.contains("self.window = nil"),
    "Reader window close should release the presenter-owned window after AppKit finishes close notification delivery"
)

require(
    !presenter.contains("closingWindow.contentViewController = nil")
        && !presenter.contains("@State private var readerWindow: NSWindow?")
        && presenter.contains("readerWindowChrome.performClose()")
        && presenter.contains("func performClose()"),
    "Reader close must break the window cycle through weak chrome ownership without forcibly destroying a live SwiftUI hosting tree"
)

require(
    !presenter.contains("window.title = book.displayTitle\n        applyDefaultFrame(to: window)"),
    "ReaderWindowPresenter should not reset the Reader window to the default frame every time a book opens"
)

require(
    presenter.contains("final class ReaderWindowChromeController")
        && presenter.contains("func setFocusModeEnabled(_ enabled: Bool)")
        && presenter.contains("button.isHidden = focusModeEnabled")
        && presenter.contains("window.standardWindowButton(.closeButton)")
        && presenter.contains("window.standardWindowButton(.miniaturizeButton)")
        && presenter.contains("window.standardWindowButton(.zoomButton)"),
    "Reader window chrome controller should hide only the traffic-light controls while focus mode is enabled"
)

require(
    presenter.contains("struct ReaderWindowRootView: View")
        && presenter.contains("@Environment(ReaderWindowCoordinator.self) private var readerWindowCoordinator")
        && presenter.contains("var shortcutManager = ShortcutManager(registry: .application)")
        && presenter.contains("var isKeyWindow = false")
        && presenter.contains("NativeWindowActivityReader { window, isKey in")
        && presenter.contains("shortcutManager.manageEvents(for: window)")
        && presenter.contains("readerWindowCoordinator.windowDidAppear()")
        && presenter.contains("readerWindowCoordinator.windowDidDisappear()")
        && presenter.contains("onFocusModeChanged: readerWindowChrome.setFocusModeEnabled")
        && presenter.contains("requestID: request.id")
        && presenter.contains(".id(readerWindowCoordinator.sessionID)")
        && presenter.contains("readerWindowCoordinator.consume(request.id)")
        && presenter.contains("isActive: isKeyWindow")
        && !presenter.contains("ProfileActivationCoordinator")
        && !presenter.contains("ProfileRepository")
        && !presenter.contains(".book(profileID:"),
    "Reader window root should use key-window state only for shortcuts/activity and never switch Profile"
)

require(
    root.contains("@Environment(ReaderWindowCoordinator.self) private var readerWindowCoordinator")
        && root.contains("ReaderWindowPresenter.shared.open(")
        && root.contains("coordinator: readerWindowCoordinator")
        && root.contains("userConfig: userConfig")
        && !root.contains("openWindow(id: ReaderWindowCoordinator.windowID")
        && root.contains("BookStorage.backfillBookLanguageIfNeeded")
        && !root.contains("pendingEnglishProfileBook")
        && !root.contains("ProfileActivationCoordinator")
        && !root.contains("setGlobalActiveProfile")
        && !root.contains("setPrimaryProfile")
        && !root.contains("@State private var selectedReaderBook")
        && !root.contains("NativeReaderLoader(book: book)"),
    "NativeMacRootView should backfill language metadata and open Reader without prompting for or switching Profile"
)

require(
    detail.contains("let onOpenBook: (BookMetadata) -> Void")
        && detail.contains("onOpenBook: onOpenBook")
        && !detail.contains("selectedReaderBook"),
    "NativeMacDetailView should pass an onOpenBook API instead of a selectedReaderBook binding"
)

require(
    placeholders.contains("let onOpenBook: (BookMetadata) -> Void")
        && placeholders.contains("onOpenBook: onOpenBook")
        && !placeholders.contains("selectedReaderBook"),
    "Native bookshelf placeholder should expose onOpenBook instead of selectedReaderBook"
)

require(
    nativeReuse.contains("let onOpenBook: (BookMetadata) -> Void")
        && nativeReuse.contains("onOpenBook: onOpenBook")
        && nativeReuse.contains("NotificationCenter.default.publisher(for: .readerWindowProgressDidChange)")
        && !nativeReuse.contains("selectedReaderBook"),
    "NativeBookshelfReuseView should open books through onOpenBook and refresh progress from an explicit Reader window signal"
)

require(
    shelf.contains("let onOpenBook: (BookMetadata) -> Void")
        && shelf.contains("onOpenBook(book)")
        && !shelf.contains("selectedReaderBook"),
    "ShelfView should expose onOpenBook(BookMetadata) instead of mutating selectedReaderBook directly"
)

require(
    bookshelf.contains("onOpenBook: { selectedReaderBook = $0 }")
        && !bookshelf.contains("selectedReaderBook: $selectedReaderBook"),
    "Legacy BookshelfView should adapt its local Reader state through ShelfView's onOpenBook API"
)

require(
    reader.contains("let isActive: Bool")
        && reader.contains("var onFocusModeChanged: (Bool) -> Void")
        && reader.contains("NativeReaderView(\n                    model: model,\n                    requestID: requestID,\n                    isActive: isActive,\n                    onFocusModeChanged: onFocusModeChanged,")
        && reader.contains("onFocusModeChanged(focusMode)")
        && reader.contains("onFocusModeChanged(false)")
        && reader.contains(".onChange(of: isActive")
        && reader.contains(".onChange(of: focusMode, initial: true)")
        && reader.contains("updateKeyboardShortcutRegistration(isActive: isActive)")
        && reader.contains("func updateKeyboardShortcutRegistration(isActive: Bool)")
        && reader.contains("NotificationCenter.default.post(name: .readerWindowProgressDidChange"),
    "NativeReaderView should register shortcut handlers only while active, drive window traffic lights from focus mode and post an explicit progress refresh signal on teardown"
)

require(
    reader.contains("} else if model.isLoading {")
        && reader.contains("ProgressView()\n                    .controlSize(.regular)")
        && reader.contains(".frame(minWidth: ReaderWindowGeometry.minimumSize.width, minHeight: ReaderWindowGeometry.minimumSize.height)")
        && reader.contains("reader.loader.loading")
        && reader.contains("ContentUnavailableView")
        && reader.contains("reader.loader.failed"),
    "NativeReaderLoader should show and log a full-size loading state before EPUB parsing finishes, and log a distinct failure state without shrinking the Reader window"
)

require(
    !reader.contains("NativeGlassCircleButton(systemName: \"chevron.left\", diameter: 34, fontSize: 18)"),
    "NativeReaderView should not render a bottom-left close/back button because the Reader window already has traffic-light close controls"
)

requireNotContains(
    reader,
    ".ignoresSafeArea(edges: .top)",
    "Reader top layout should be driven by the transparent full-size window chrome instead of a separate top safe-area override"
)

if let notificationRange = reader.range(of: "NotificationCenter.default.post(name: .readerWindowProgressDidChange"),
   let autoSyncRange = reader.range(of: "await model.flushAutoSync()") {
    require(
        notificationRange.lowerBound < autoSyncRange.lowerBound,
        "Reader progress refresh notification should be posted before and independently of network auto-sync flush"
    )
} else {
    require(false, "Reader teardown should contain both progress refresh notification and auto-sync flush")
}

print("Reader window contract tests passed")
