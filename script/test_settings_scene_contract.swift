import Foundation

private let appSource = try String(contentsOfFile: "NativeMac/HoshiNativeMacApp.swift", encoding: .utf8)
private let nativeReuseViews = try String(contentsOfFile: "NativeMac/NativeReuseViews.swift", encoding: .utf8)
private let videoWindowPresenter = try String(contentsOfFile: "NativeMac/VideoWindowPresenter.swift", encoding: .utf8)
private let userConfigSource = try String(contentsOfFile: "Core/UserConfig.swift", encoding: .utf8)

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

private func expectContains(_ source: String, _ needle: String, _ message: String) {
    expect(source.contains(needle), "\(message)\nMissing: \(needle)")
}

private func expectNotContains(_ source: String, _ needle: String, _ message: String) {
    expect(!source.contains(needle), "\(message)\nUnexpected: \(needle)")
}

private func substring(after needle: String, in source: String) -> String {
    guard let range = source.range(of: needle) else {
        return ""
    }
    return String(source[range.lowerBound...])
}

private let settingsSceneSource = substring(after: "Settings {", in: appSource)

expectContains(
    appSource,
    "Settings {",
    "The app should declare a native macOS Settings scene so Niratan > Settings opens a compact preferences window"
)

expectContains(
    appSource,
    "NativeSettingsWindowRoot()",
    "The Settings scene should delegate to a dedicated settings window root"
)

expectContains(
    appSource,
    "struct NativeSettingsWindowRoot: View",
    "The settings window root should stay thin and local to the app scene wiring"
)

expectContains(
    appSource,
    "NativeSettingsReuseView()",
    "The settings window root should reuse the existing native Settings sidebar/detail surface"
)

expectContains(
    appSource,
    ".environment(userConfig)",
    "The Settings scene should receive the same shared UserConfig environment as the main window"
)

expectContains(
    settingsSceneSource,
    ".environment(selectionLookupCoordinator)",
    "The Settings scene should receive SelectionLookupCoordinator because Keyboard Shortcuts reads it from the environment"
)

expectContains(
    settingsSceneSource,
    "selectionLookupCoordinator.configure(userConfig: userConfig)",
    "The Settings scene should configure SelectionLookupCoordinator when opened without the main window"
)

expectContains(
    appSource,
    ".preferredColorScheme(preferredColorScheme)",
    "The Settings scene should follow the same app theme resolution as the main window"
)

expectContains(
    userConfigSource,
    "case .system, .sepia: nil",
    "System and Sepia themes should inherit the live macOS appearance instead of forcing a color scheme"
)

expectContains(
    userConfigSource,
    "theme == .sepia && colorScheme == .dark",
    "Sepia should switch to its dark variant whenever macOS is in Dark Mode"
)

expectContains(
    appSource,
    "userConfig.preferredColorScheme",
    "The app should resolve its forced appearance from the shared UserConfig rule"
)

expectContains(
    videoWindowPresenter,
    "userConfig.preferredColorScheme ?? NativeSystemAppearance.shared.colorScheme",
    "Video windows should resolve their forced appearance from the shared UserConfig rule"
)

expectContains(
    appSource,
    "userConfig.preferredColorScheme ?? NativeSystemAppearance.shared.colorScheme",
    "Follow-system themes should hand SwiftUI the live macOS scheme because a nil preference keeps the last forced scheme"
)

expectContains(
    appSource,
    "NSApp.observe(\\.effectiveAppearance)",
    "The live macOS scheme should track NSApp.effectiveAppearance"
)

expectContains(
    appSource,
    "switch userConfig.preferredColorScheme {",
    "Only forced themes may pin NSApp.appearance; follow-system must leave AppKit live"
)

expectNotContains(
    appSource,
    "MainActor.assumeIsolated",
    "Window KVO callbacks must not trap when AppKit reports style changes off the main thread"
)

expectNotContains(
    appSource,
    "AppleInterfaceStyle",
    "The app should not infer the live macOS appearance from the cached AppleInterfaceStyle preference"
)

expectNotContains(
    videoWindowPresenter,
    "AppleInterfaceStyle",
    "The independent Video window should inherit the same live macOS appearance"
)

expectContains(
    settingsSceneSource,
    ".onChange(of: userConfig.readerProfileSettings())",
    "The Settings scene should persist Reader profile settings even when the main window is closed"
)

expectContains(
    settingsSceneSource,
    "ProfileSettingsStore.shared.persistReaderSettings(settings)",
    "Reader profile settings changes from the Settings scene should be written to the active profile store"
)

expectContains(
    settingsSceneSource,
    ".onChange(of: userConfig.dictionaryProfileSettings())",
    "The Settings scene should persist Dictionary profile settings even when the main window is closed"
)

expectContains(
    settingsSceneSource,
    "ProfileSettingsStore.shared.persistDictionarySettings(settings)",
    "Dictionary profile settings changes from the Settings scene should be written to the active profile store"
)

expectContains(
    nativeReuseViews,
    "struct NativeSettingsReuseView: View",
    "The reusable Settings surface should remain available to both the main section and the Settings scene"
)

print("Settings scene contract passed")
