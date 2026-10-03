import Foundation
import ObjectiveC

/// Debug-only isolation of every user-data store, so development builds can be
/// exercised without touching the installed app's library, settings or
/// credentials (both share the `moe.shishamo.hoshi` bundle identifier).
///
/// Launch with `HOSHI_DATA_ROOT=<dir>` plus `CFFIXED_USER_HOME=<dir>/Home`
/// (`script/build_and_run.sh --data-root <dir>` sets both):
/// - `UserDefaults.standard` (including `@AppStorage`) reads and writes
///   `<dir>/Preferences/defaults.plist`;
/// - Application Support, Documents and Caches resolve under `<dir>/Home`;
/// - Keychain items use an `.isolated` service/account suffix.
///
/// Release builds ignore the variables entirely.
nonisolated enum DevelopmentDataIsolation {
    static let rootEnvironmentKey = "HOSHI_DATA_ROOT"

    /// The isolated data root, or `nil` when the app uses the real user data.
    static let root: URL? = {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment[rootEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        #else
        return nil
        #endif
    }()

    static var isActive: Bool { root != nil }

    /// Redirects `UserDefaults.standard` and verifies the file-system redirect,
    /// once per process. Must be evaluated before anything reads defaults or
    /// resolves data directories.
    static let activation: Void = {
        guard let root else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        guard home.hasPrefix(root.path + "/") else {
            // Refuse to run half-isolated: the file stores would hit real data.
            fatalError(
                "\(rootEnvironmentKey) is set but CFFIXED_USER_HOME does not point inside it (home: \(home))."
            )
        }
        let preferences = root.appendingPathComponent("Preferences", isDirectory: true)
        try? FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: preferences.appendingPathComponent("defaults").path) else {
            fatalError("Could not open isolated defaults under \(preferences.path).")
        }
        IsolatedUserDefaultsProvider.defaults = defaults
        guard let original = class_getClassMethod(
            UserDefaults.self,
            #selector(getter: UserDefaults.standard)
        ), let replacement = class_getClassMethod(
            IsolatedUserDefaultsProvider.self,
            #selector(IsolatedUserDefaultsProvider.isolatedStandard)
        ) else {
            fatalError("Could not redirect UserDefaults.standard.")
        }
        method_exchangeImplementations(original, replacement)
    }()

    /// Keychain service or account name for the current data scope.
    static func keychainName(_ name: String) -> String {
        isActive ? "\(name).isolated" : name
    }
}

nonisolated private final class IsolatedUserDefaultsProvider: NSObject {
    nonisolated(unsafe) static var defaults: UserDefaults?

    @objc class func isolatedStandard() -> UserDefaults {
        defaults!
    }
}
