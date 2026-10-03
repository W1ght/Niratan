import AppKit
import SwiftUI

extension Notification.Name {
    static let videoWindowFullScreenTransitionDidFail = Notification.Name(
        "moe.shishamo.hoshi.video.fullScreenTransitionDidFail"
    )
}

enum VideoWindowGeometry {
    // Match IINA's main-window envelope. The active video aspect ratio can make
    // the effective minimum taller or wider, but ordinary edge dragging is not
    // otherwise capped to the visible screen.
    static let minimumSize = NSSize(width: 285, height: 120)
    static let defaultSize = NSSize(width: 1132, height: 637)
}

@MainActor
final class VideoWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = VideoWindowPresenter()

    private var window: NSWindow?
    private var videoWindowChrome: VideoWindowChromeController?
    private weak var coordinator: VideoWindowCoordinator?

    func open(
        url: URL,
        subtitleURL: URL? = nil,
        startsFromBeginning: Bool = false,
        coordinator: VideoWindowCoordinator,
        userConfig: UserConfig
    ) {
        open(
            source: .localFile(url),
            subtitleURL: subtitleURL,
            startsFromBeginning: startsFromBeginning,
            coordinator: coordinator,
            userConfig: userConfig
        )
    }

    func open(
        source: VideoPlaybackSource,
        subtitleURL: URL? = nil,
        startsFromBeginning: Bool = false,
        coordinator: VideoWindowCoordinator,
        userConfig: UserConfig
    ) {
        self.coordinator = coordinator
        coordinator.requestOpen(
            source,
            subtitleURL: subtitleURL,
            startsFromBeginning: startsFromBeginning
        )
        let window = window ?? makeWindow(
            coordinator: coordinator,
            userConfig: userConfig
        )
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func open(
        remoteRequest: RemoteVideoWindowOpenRequest,
        coordinator: VideoWindowCoordinator,
        userConfig: UserConfig
    ) {
        self.coordinator = coordinator
        coordinator.requestOpen(remoteRequest: remoteRequest)
        let window = window ?? makeWindow(
            coordinator: coordinator,
            userConfig: userConfig
        )
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow(
        coordinator: VideoWindowCoordinator,
        userConfig: UserConfig
    ) -> NSWindow {
        let videoWindowChrome = VideoWindowChromeController()
        let rootView = VideoWindowRootView(videoWindowChrome: videoWindowChrome)
            .environment(userConfig)
            .environment(coordinator)
        let hostingController = NSHostingController(rootView: rootView)
        let defaultFrame = defaultVideoWindowFrame()
        let window = NSWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(VideoWindowCoordinator.windowID)
        window.title = String(localized: "Video")
        configureVideoWindowChrome(window)
        window.minSize = VideoWindowGeometry.minimumSize
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentViewController = hostingController
        window.setFrame(defaultFrame, display: false)
        window.delegate = self
        self.videoWindowChrome = videoWindowChrome
        self.window = window
        return window
    }

    private func configureVideoWindowChrome(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.acceptsMouseMovedEvents = true
    }

    private func defaultVideoWindowFrame() -> NSRect {
        let visibleFrame = NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let visibleFrame else {
            return NSRect(origin: .zero, size: VideoWindowGeometry.defaultSize)
        }
        let defaultSize = VideoWindowGeometry.defaultSize
        let scale = min(
            1,
            visibleFrame.width / defaultSize.width,
            visibleFrame.height / defaultSize.height
        )
        let size = NSSize(
            width: defaultSize.width * scale,
            height: defaultSize.height * scale
        )
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === window else { return frameSize }
        return videoWindowChrome?.constrainedFrameSize(for: frameSize) ?? frameSize
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let resizingWindow = notification.object as? NSWindow,
              resizingWindow === window else {
            return
        }
        videoWindowChrome?.beginLiveResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizingWindow = notification.object as? NSWindow,
              resizingWindow === window else {
            return
        }
        videoWindowChrome?.endLiveResize()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard window === self.window else { return }
        videoWindowChrome?.fullScreenTransitionDidFail()
        NotificationCenter.default.post(
            name: .videoWindowFullScreenTransitionDidFail,
            object: window
        )
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard window === self.window else { return }
        videoWindowChrome?.fullScreenTransitionDidFail()
        NotificationCenter.default.post(
            name: .videoWindowFullScreenTransitionDidFail,
            object: window
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else {
            return
        }
        coordinator?.windowDidDisappear()
        coordinator = nil
        scheduleWindowTeardown(closingWindow)
    }

    private func scheduleWindowTeardown(_ closingWindow: NSWindow) {
        DispatchQueue.main.async { [weak self, closingWindow] in
            closingWindow.contentViewController = nil
            closingWindow.delegate = nil
            if self?.window === closingWindow {
                self?.videoWindowChrome = nil
                self?.window = nil
            }
        }
    }
}

private struct VideoWindowRootView: View {
    @Environment(UserConfig.self) private var userConfig
    @Environment(VideoWindowCoordinator.self) private var videoWindowCoordinator
    @State private var shortcutManager = ShortcutManager(registry: .application)
    @State private var isKeyWindow = false
    @State private var videoWindowChrome: VideoWindowChromeController

    init(videoWindowChrome: VideoWindowChromeController) {
        _videoWindowChrome = State(initialValue: videoWindowChrome)
    }

    var body: some View {
        VideoPlayerScreen(
            isActive: isKeyWindow,
            openRequest: videoWindowCoordinator.pendingRequest,
            onConsumeOpenRequest: videoWindowCoordinator.consume,
            windowChrome: videoWindowChrome
        )
        .id(videoWindowCoordinator.sessionID)
        .frame(
            minWidth: VideoWindowGeometry.minimumSize.width,
            minHeight: VideoWindowGeometry.minimumSize.height
        )
        .environment(shortcutManager)
        .preferredColorScheme(preferredColorScheme)
        .background {
            NativeWindowActivityReader { window, isKey in
                shortcutManager.manageEvents(for: window)
                videoWindowChrome.attach(window)
                isKeyWindow = isKey
            }
        }
        .onAppear {
            videoWindowCoordinator.windowDidAppear()
            shortcutManager.configure(userConfig: userConfig)
            shortcutManager.install()
        }
        .onDisappear {
            videoWindowCoordinator.windowDidDisappear()
            videoWindowChrome.attach(nil)
            shortcutManager.uninstall()
        }
    }

    private var preferredColorScheme: ColorScheme? {
        userConfig.preferredColorScheme ?? NativeSystemAppearance.shared.colorScheme
    }

}
