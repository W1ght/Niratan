import AppKit
import SwiftUI

final class HoshiNativeMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        VideoPlaybackMenuVisibilityController.shared.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ReaderWindowPresenter.shared.persistFrameForApplicationTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.sendAction(#selector(NSWindowController.newWindowForTab(_:)), to: nil, from: nil)
        }
        return true
    }
}

@main
struct HoshiNativeMacApp: App {
    // Declared first: stored properties initialize in order, and the ones
    // below already read defaults.
    private let dataIsolation: Void = DevelopmentDataIsolation.activation
    @NSApplicationDelegateAdaptor(HoshiNativeMacAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var userConfig = UserConfig()
    @State private var selectionLookupCoordinator = SelectionLookupCoordinator()
    @State private var readerWindowCoordinator = ReaderWindowCoordinator()
    @State private var mangaWindowCoordinator = MangaWindowCoordinator()
    @State private var videoWindowCoordinator = VideoWindowCoordinator()

    init() {
        BookStorage.migrateFromDocuments()
        BookStorage.migrateBooks()
        _ = ProfileRepository.shared
        _ = DictionaryManager.shared
        MediaServerRemoteVideoResolver.registerWithRemotePlayback()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                    ShortcutManagedRootView()
                    .environment(readerWindowCoordinator)
                    .environment(mangaWindowCoordinator)
                    .environment(videoWindowCoordinator)
            }
                .frame(minWidth: 900, minHeight: 620)
                .environment(userConfig)
                .environment(selectionLookupCoordinator)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    ProfileSettingsStore.shared.bootstrap(userConfig: userConfig)
                    selectionLookupCoordinator.configure(userConfig: userConfig)
                    XboxControllerManager.shared.configure(userConfig: userConfig)
                    NativeSystemAppearance.shared.start()
                    syncApplicationAppearance()
                }
                .onChange(of: userConfig.theme) { _, _ in
                    syncApplicationAppearance()
                }
                .onChange(of: userConfig.uiTheme) { _, _ in
                    syncApplicationAppearance()
                }
                .onChange(of: userConfig.readerProfileSettings()) { _, settings in
                    ProfileSettingsStore.shared.persistReaderSettings(settings)
                }
                .onChange(of: userConfig.dictionaryProfileSettings()) { _, settings in
                    ProfileSettingsStore.shared.persistDictionarySettings(settings)
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        selectionLookupCoordinator.refresh()
                        LocalFileServer.shared.setAudioServer(enabled: userConfig.enableLocalAudio)
                        AnkiManager.shared.handleAppBecameActive()
                        if userConfig.autoUpdateDictionaries {
                            DictionaryManager.shared.autoUpdateDictionaries()
                        }
                        GoogleDriveSyncManager.shared.resumeIfNeeded()
                    } else {
                        ProfileSettingsStore.shared.persistCurrent(userConfig: userConfig)
                        AnkiManager.shared.save()
                        Task {
                            await GoogleDriveSyncManager.shared.pause()
                        }
                    }
                }
                .onChange(of: userConfig.enableLocalAudio) { _, _ in
                    LocalFileServer.shared.setAudioServer(enabled: userConfig.enableLocalAudio)
                }
                .onChange(of: userConfig.shortcutBinding(for: GlobalShortcutActions.lookupSelectedText)) { _, _ in
                    selectionLookupCoordinator.refresh()
                }
        }
        .commands {
            VideoPlaybackCommands()
        }

        Settings {
            NativeSettingsWindowRoot()
                .environment(userConfig)
                .environment(selectionLookupCoordinator)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    ProfileSettingsStore.shared.bootstrap(userConfig: userConfig)
                    selectionLookupCoordinator.configure(userConfig: userConfig)
                    NativeSystemAppearance.shared.start()
                    syncApplicationAppearance()
                }
                .onChange(of: userConfig.theme) { _, _ in
                    syncApplicationAppearance()
                }
                .onChange(of: userConfig.uiTheme) { _, _ in
                    syncApplicationAppearance()
                }
                .onChange(of: userConfig.readerProfileSettings()) { _, settings in
                    ProfileSettingsStore.shared.persistReaderSettings(settings)
                }
                .onChange(of: userConfig.dictionaryProfileSettings()) { _, settings in
                    ProfileSettingsStore.shared.persistDictionarySettings(settings)
                }
        }
        .windowResizability(.contentMinSize)

    }

    /// Follow-system themes resolve to the live macOS scheme instead of `nil`.
    private var preferredColorScheme: ColorScheme? {
        userConfig.preferredColorScheme ?? NativeSystemAppearance.shared.colorScheme
    }

    private func syncApplicationAppearance() {
        // Only forced themes pin the app; follow-system leaves AppKit live.
        switch userConfig.preferredColorScheme {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case nil:
            NSApp.appearance = Self.debugSystemAppearanceOverride
        @unknown default:
            NSApp.appearance = Self.debugSystemAppearanceOverride
        }
    }

    /// Debug builds can stand in for the Mac's appearance with
    /// `HOSHI_DEBUG_SYSTEM_APPEARANCE=dark|light`, so follow-system themes
    /// (including sepia's dark inversion) can be verified without changing
    /// the system setting.
    private static var debugSystemAppearanceOverride: NSAppearance? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["HOSHI_DEBUG_SYSTEM_APPEARANCE"] {
        case "dark":
            return NSAppearance(named: .darkAqua)
        case "light":
            return NSAppearance(named: .aqua)
        default:
            return nil
        }
        #else
        return nil
        #endif
    }

}

/// The live macOS appearance for follow-system themes (System and Sepia).
///
/// SwiftUI keeps a previously forced scheme after `preferredColorScheme`
/// returns to `nil`, so windows stuck on Light after switching back to System.
/// Follow-system themes therefore pass this explicit scheme instead; it tracks
/// `NSApp.effectiveAppearance`, which follows macOS while `NSApp.appearance`
/// is `nil`.
@MainActor
@Observable
final class NativeSystemAppearance {
    static let shared = NativeSystemAppearance()

    /// `nil` until monitoring starts, so the first frame simply inherits macOS.
    private(set) var colorScheme: ColorScheme?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {}

    func start() {
        guard observation == nil else { return }
        update()
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            // KVO may report from any thread; hop to the main actor.
            DispatchQueue.main.async {
                NativeSystemAppearance.shared.update()
            }
        }
    }

    private func update() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let scheme: ColorScheme = isDark ? .dark : .light
        if colorScheme != scheme {
            colorScheme = scheme
        }
    }
}

private struct NativeSettingsWindowRoot: View {
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("Niratan.SettingsWindow")
    @MainActor private static var resizableObservation: NSKeyValueObservation?

    var body: some View {
        NativeSettingsReuseView()
            .frame(
                minWidth: 720, idealWidth: 820, maxWidth: .infinity,
                minHeight: 480, idealHeight: 560, maxHeight: .infinity
            )
            .background {
                NativeWindowActivityReader { window, _ in
                    guard let window, window.frameAutosaveName != Self.frameAutosaveName else { return }
                    // The Settings scene keeps resetting its window to a fixed size;
                    // keep it resizable, then let AppKit restore and save its frame.
                    window.styleMask.insert(.resizable)
                    Self.resizableObservation = window.observe(\.styleMask) { window, _ in
                        // KVO may report from any thread; never trap here.
                        DispatchQueue.main.async {
                            if !window.styleMask.contains(.resizable) {
                                window.styleMask.insert(.resizable)
                            }
                        }
                    }
                    window.contentMinSize = NSSize(width: 720, height: 480)
                    window.setFrameAutosaveName(Self.frameAutosaveName)
                }
            }
    }
}

private struct ShortcutManagedRootView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var shortcutManager = ShortcutManager(registry: .application)

    var body: some View {
        NativeMacRootView()
            .environment(shortcutManager)
            .background {
                NativeWindowActivityReader { window, _ in
                    shortcutManager.manageEvents(for: window)
                }
            }
            .onAppear {
                shortcutManager.configure(userConfig: userConfig)
                shortcutManager.install()
            }
            .onDisappear {
                shortcutManager.uninstall()
            }
    }
}
