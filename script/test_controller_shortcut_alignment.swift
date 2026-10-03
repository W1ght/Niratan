import Foundation

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

private func read(_ path: String) -> String {
    let url = root.appendingPathComponent(path)
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
        fatalError("Unable to read \(path)")
    }
    return contents
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

private func expectContains(_ source: String, _ needle: String, _ message: String) {
    expect(source.contains(needle), message)
}

let controllerManager = read("Core/XboxControllerManager.swift")
let shortcutManager = read("Core/Shortcuts/ShortcutManager.swift")
let userConfig = read("Core/UserConfig.swift")
let controllerSettings = read("Features/Settings/XboxControllerView.swift")
let registry = read("Features/Settings/ApplicationShortcutRegistry.swift")
let app = read("NativeMac/HoshiNativeMacApp.swift")
let nativeReader = read("NativeMac/NativeReaderView.swift")

expectContains(
    controllerSettings,
    "let registry = ShortcutRegistry.application",
    "Controller settings should use the same registry as keyboard shortcuts"
)
expectContains(
    controllerSettings,
    "ForEach(visibleCategories)",
    "Controller settings should render every visible shortcut category"
)
expectContains(
    controllerSettings,
    "let actions = registry.actions(in: category)",
    "Controller settings should render every registered action in each category"
)
expectContains(
    registry,
    "actions += VideoShortcutActions.all",
    "The shared registry should include every Video action in Video builds"
)
expectContains(
    controllerSettings,
    ".disabled(binding == action.defaultControllerBinding)",
    "Controller settings should provide per-action reset buttons"
)
expectContains(
    controllerSettings,
    "Label(\"Controller Conflict\", systemImage: \"exclamationmark.triangle.fill\")",
    "Controller settings should surface overlapping duplicate bindings"
)
expectContains(
    controllerSettings,
    "Label(\"Context Priority\", systemImage: \"square.stack.3d.up\")",
    "Controller settings should explain intentional popup priority"
)

expectContains(
    userConfig,
    "struct ControllerConfiguration: Codable, Equatable",
    "Controller bindings should use versioned action-id storage"
)
expectContains(
    userConfig,
    "storedData: defaults.data(forKey: \"controllerConfiguration\")",
    "Controller bindings should load their shared configuration"
)
expectContains(
    userConfig,
    "return ControllerConfiguration(bindings: legacyBindings)",
    "Legacy controller bindings should only seed the first unified configuration"
)
for legacyKey in [
    "readerPreviousPageControllerBinding",
    "readerNextPageControllerBinding",
    "sasayakiPreviousCueControllerBinding",
    "sasayakiPlayPauseControllerBinding",
    "sasayakiNextCueControllerBinding",
    "sasayakiReplayCueControllerBinding",
    "sasayakiJumpCueControllerBinding",
    "statisticsToggleControllerBinding"
] {
    expectContains(
        userConfig,
        "\"\(legacyKey)\"",
        "Controller configuration should migrate \(legacyKey)"
    )
}

expectContains(
    controllerManager,
    "let registry = ShortcutRegistry.application",
    "Controller input should resolve actions through the shared registry"
)
expectContains(
    controllerManager,
    "_ = ShortcutManager.dispatchActionIDs(actionIDs)",
    "Controller input should use the shared scoped shortcut handlers"
)
expectContains(
    shortcutManager,
    "static func dispatchActionIDs(_ actionIDs: [String]) -> Bool",
    "ShortcutManager should expose scoped action-id dispatch for controllers"
)
expectContains(
    app,
    "XboxControllerManager.shared.configure(userConfig: userConfig)",
    "The app should start controller handling without requiring the settings or Reader window"
)
expect(
    !nativeReader.contains("XboxControllerManager.actionNotification")
        && !nativeReader.contains("handleControllerShortcut"),
    "Reader should rely on shared shortcut dispatch instead of a controller-only path"
)

print("Controller shortcut alignment tests passed")
