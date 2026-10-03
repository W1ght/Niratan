import AppKit
import OSLog
import SwiftUI

private let readerWindowPersistenceLogger = Logger(subsystem: "moe.shishamo.hoshi", category: "ReaderPersistence")

@MainActor
final class ReaderWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = ReaderWindowPresenter()
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("HoshiReader.ReaderWindowFrame")
    private static let frameAutosaveMigrationKey = "HoshiReader.ReaderWindowFrameLegacyMigrationComplete"

    private var window: NSWindow?
    private weak var coordinator: ReaderWindowCoordinator?

    func closeWindow() {
        window?.performClose(nil)
    }

    func open(
        book: BookMetadata,
        coordinator: ReaderWindowCoordinator,
        userConfig: UserConfig
    ) {
        self.coordinator = coordinator
        coordinator.requestOpen(book)
        let window = window ?? makeWindow(coordinator: coordinator, userConfig: userConfig)
        window.title = book.displayTitle
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow(
        coordinator: ReaderWindowCoordinator,
        userConfig: UserConfig
    ) -> NSWindow {
        let rootView = ReaderWindowRootView()
            .environment(userConfig)
            .environment(coordinator)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(ReaderWindowCoordinator.windowID)
        configureReaderWindowChrome(window)
        window.minSize = ReaderWindowGeometry.minimumSize
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentViewController = hostingController
        restoreSavedFrameOrApplyDefault(to: window)
        window.delegate = self
        self.window = window
        return window
    }

    private func configureReaderWindowChrome(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
    }

    private func currentReaderWindowVisibleFrame() -> NSRect? {
        NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    private func defaultReaderWindowFrame(visibleFrame: NSRect? = nil) -> NSRect {
        let visibleFrame = visibleFrame ?? currentReaderWindowVisibleFrame()
        return ReaderWindowGeometry.defaultFrame(visibleFrame: visibleFrame)
    }

    private func applyDefaultFrame(to window: NSWindow, visibleFrame: NSRect? = nil) {
        let defaultFrame = defaultReaderWindowFrame(visibleFrame: visibleFrame)
        window.setFrame(defaultFrame, display: true)
    }

    private func restoreSavedFrameOrApplyDefault(to window: NSWindow) {
        let visibleFrame = currentReaderWindowVisibleFrame()
        let hasCompletedLegacyMigration = UserDefaults.standard.bool(forKey: Self.frameAutosaveMigrationKey)
        if window.setFrameUsingName(Self.frameAutosaveName),
           ReaderWindowGeometry.shouldUseSavedFrame(
                window.frame,
                visibleFrame: visibleFrame,
                hasCompletedLegacyMigration: hasCompletedLegacyMigration
           ) {
            UserDefaults.standard.set(true, forKey: Self.frameAutosaveMigrationKey)
            return
        }

        applyDefaultFrame(to: window, visibleFrame: visibleFrame)
        window.saveFrame(usingName: Self.frameAutosaveName)
        UserDefaults.standard.set(true, forKey: Self.frameAutosaveMigrationKey)
    }

    func persistFrameForApplicationTermination() {
        guard let window else { return }
        persistWindowedFrameIfNeeded(window)
    }

    private func persistWindowedFrameIfNeeded(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        readerWindowPersistenceLogger.notice(
            "reader.windowFrame.save frame=\(NSStringFromRect(window.frame), privacy: .public)"
        )
        window.saveFrame(usingName: Self.frameAutosaveName)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else {
            return
        }
        readerWindowPersistenceLogger.notice(
            "reader.windowWillClose.beforeCoordinatorReset window=\(String(describing: notification.object), privacy: .public)"
        )
        persistWindowedFrameIfNeeded(closingWindow)
        if let requestID = coordinator?.currentRequest?.id {
            NotificationCenter.default.post(
                name: .readerWindowWillClose,
                object: closingWindow,
                userInfo: [ReaderWindowCoordinator.closeRequestIDUserInfoKey: requestID]
            )
        } else {
            NotificationCenter.default.post(name: .readerWindowWillClose, object: closingWindow)
        }
        coordinator?.windowDidDisappear()
        coordinator = nil
        scheduleWindowRelease(closingWindow)
    }

    private func scheduleWindowRelease(_ closingWindow: NSWindow) {
        let closingWindowID = ObjectIdentifier(closingWindow)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let closingWindow = self.window,
                  ObjectIdentifier(closingWindow) == closingWindowID else {
                return
            }
            closingWindow.delegate = nil
            self.window = nil
        }
    }
}

private struct ReaderWindowRootView: View {
    @Environment(UserConfig.self) private var userConfig
    @Environment(ReaderWindowCoordinator.self) private var readerWindowCoordinator
    @State private var shortcutManager = ShortcutManager(registry: .application)
    @State private var readerWindowChrome = ReaderWindowChromeController()
    @State private var isKeyWindow = false

    var body: some View {
        Group {
            if let request = readerWindowCoordinator.currentRequest,
               let model = readerWindowCoordinator.currentModel {
                NativeReaderLoader(
                    book: request.book,
                    model: model,
                    requestID: request.id,
                    isActive: isKeyWindow,
                    onFocusModeChanged: readerWindowChrome.setFocusModeEnabled,
                    onClose: {
                        closeReaderWindow()
                    }
                )
                .id(readerWindowCoordinator.sessionID)
            } else {
                EmptyView()
            }
        }
        .environment(shortcutManager)
        .background {
            NativeWindowActivityReader { window, isKey in
                shortcutManager.manageEvents(for: window)
                readerWindowChrome.attach(window)
                isKeyWindow = isKey
            }
        }
        .onAppear {
            readerWindowCoordinator.windowDidAppear()
            shortcutManager.configure(userConfig: userConfig)
            shortcutManager.install()
            consumePendingReaderRequestIfNeeded()
        }
        .onChange(of: readerWindowCoordinator.pendingRequest, initial: true) { _, _ in
            consumePendingReaderRequestIfNeeded()
        }
        .onDisappear {
            readerWindowCoordinator.windowDidDisappear()
            readerWindowChrome.attach(nil)
            shortcutManager.uninstall()
        }
    }

    private func consumePendingReaderRequestIfNeeded() {
        guard let request = readerWindowCoordinator.pendingRequest else { return }
        readerWindowCoordinator.consume(request.id)
    }

    private func closeReaderWindow() {
        readerWindowChrome.performClose()
    }
}

@MainActor
private final class ReaderWindowChromeController {
    private weak var window: NSWindow?
    private var focusModeEnabled = false

    func attach(_ window: NSWindow?) {
        guard self.window !== window else {
            applyTrafficLightVisibility()
            return
        }
        restoreAttachedWindowButtons()
        self.window = window
        applyTrafficLightVisibility()
    }

    func setFocusModeEnabled(_ enabled: Bool) {
        focusModeEnabled = enabled
        applyTrafficLightVisibility()
    }

    func performClose() {
        window?.performClose(nil)
    }

    private func applyTrafficLightVisibility() {
        guard let window else { return }
        for button in trafficLightButtons(in: window) {
            button.isHidden = focusModeEnabled
        }
    }

    private func restoreAttachedWindowButtons() {
        guard let window else { return }
        for button in trafficLightButtons(in: window) {
            button.isHidden = false
        }
    }

    private func trafficLightButtons(in window: NSWindow) -> [NSButton] {
        [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton),
        ].compactMap { $0 }
    }
}
