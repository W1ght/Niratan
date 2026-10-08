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

private func requireContains(_ source: String, _ needle: String, _ message: String) {
    require(source.contains(needle), "\(message)\nMissing: \(needle)")
}

private func requireNotContains(_ source: String, _ needle: String, _ message: String) {
    require(!source.contains(needle), "\(message)\nUnexpected: \(needle)")
}

let fileManager = FileManager.default

require(
    fileManager.fileExists(atPath: root.appendingPathComponent("Niratan.xcodeproj").path),
    "Xcode project should use the Niratan name"
)
require(
    !fileManager.fileExists(atPath: root.appendingPathComponent("Hoshi Reader.xcodeproj").path),
    "legacy Xcode project path should not remain in the working tree"
)

let project = try source("Niratan.xcodeproj/project.pbxproj")
let scheme = try source("Niratan.xcodeproj/xcshareddata/xcschemes/Niratan.xcscheme")
let buildScript = try source("script/build_and_run_native.sh")
let packageScript = try source("script/package_mac.sh")
let releaseScript = try source("script/release_mac.sh")
let releaseWorkflow = try source(".github/workflows/release-mac.yml")
let updateChecker = try source("Util/Extensions.swift")
let readme = try source("README.md")
let syncView = try source("Features/Settings/SyncView.swift")
let libraryCache = try source("Features/Sync/GoogleDriveSync/GoogleDriveSyncCache.swift")
let libraryHandler = try source("Features/Sync/GoogleDriveSync/GoogleDriveSyncHandler.swift")

requireContains(project, "/* Niratan.app */", "build product should be Niratan.app")
requireContains(project, "name = \"Niratan\";", "native target should be named Niratan")
requireContains(project, "productName = \"Niratan\";", "native target product should be named Niratan")
requireContains(project, "INFOPLIST_KEY_CFBundleDisplayName = \"Niratan\";", "display name should be Niratan")
requireNotContains(project, "INFOPLIST_KEY_CFBundleDisplayName = \"Hoshi Reader\";", "the shared library name must not replace the app display name")
requireContains(project, "PRODUCT_BUNDLE_IDENTIFIER = moe.shishamo.hoshi;", "bundle id should remain stable for user data compatibility")
requireNotContains(project, "Hoshi Reader.app", "project file should not refer to the old app bundle name")

requireContains(scheme, "BuildableName = \"Niratan.app\"", "the shared scheme should build Niratan.app")
requireContains(scheme, "BlueprintName = \"Niratan\"", "the shared scheme should target Niratan")
requireContains(scheme, "ReferencedContainer = \"container:Niratan.xcodeproj\"", "the shared scheme should point to Niratan.xcodeproj")
requireContains(scheme, "buildConfiguration = \"Debug\"", "the scheme should use the standard Debug configuration")
requireContains(scheme, "buildConfiguration = \"Release\"", "the scheme should use the standard Release configuration")

requireContains(buildScript, "APP_NAME=\"Niratan\"", "build script should launch Niratan")
requireContains(buildScript, "PROJECT_NAME=\"Niratan.xcodeproj\"", "build script should build the renamed project")
requireContains(buildScript, "SCHEME_NAME=\"Niratan\"", "build script should use the single Niratan scheme")
requireContains(buildScript, "EXPECTED_BUNDLE_ID=\"moe.shishamo.hoshi\"", "build script should verify the compatibility bundle id")

requireContains(packageScript, "APP_NAME=\"Niratan\"", "package script should package Niratan")
requireContains(packageScript, "ARTIFACT_NAME=\"Niratan-Mac-$VERSION\"", "The full-build artifact should use the Niratan brand")
requireNotContains(packageScript, "Niratan-Mac-Video-", "Packaging should not retain a separate Video artifact")
requireContains(packageScript, "hdiutil create -volname \"Niratan $VERSION\"", "DMG volume should use the Niratan brand")

requireContains(releaseScript, "PROJECT_NAME=\"Niratan.xcodeproj\"", "release script should bump the renamed project")
requireContains(releaseScript, "Niratan Mac $VERSION", "release tag message should use the Niratan brand")
requireContains(releaseScript, "https://github.com/W1ght/Niratan/releases/tag/$TAG", "release script should print the renamed release URL")

requireContains(releaseWorkflow, "name: niratan-mac", "release workflow artifact id should use the Niratan brand")
requireContains(releaseWorkflow, "Niratan-Mac-$version.dmg", "release workflow should publish the Niratan full-build DMG")
requireNotContains(releaseWorkflow, "Niratan-Mac-Video-", "release workflow should not publish a separate Video DMG")

requireContains(updateChecker, "https://api.github.com/repos/W1ght/Niratan/releases/latest", "update checker should query the renamed release repo")
requireContains(updateChecker, "Niratan-Mac-\\(version).dmg", "update checker should look for the full-build DMG")
requireNotContains(updateChecker, "Niratan-Mac-Video-", "update checker should not look for retired Video DMGs")
requireContains(updateChecker, "\"Niratan-Mac\"", "update checker should use the renamed user agent")

let localizationData = try Data(contentsOf: root.appendingPathComponent("Localizable.xcstrings"))
guard
    let localizationRoot = try JSONSerialization.jsonObject(with: localizationData) as? [String: Any],
    let localizedStrings = localizationRoot["strings"] as? [String: Any]
else {
    fputs("FAIL: Localizable.xcstrings should be valid JSON with a strings object\n", stderr)
    exit(1)
}
require(localizedStrings["Niratan"] != nil, "Localizable.xcstrings should expose the Niratan app label")
func localizedValue(_ key: String, language: String) -> String? {
    let entry = localizedStrings[key] as? [String: Any]
    let localizations = entry?["localizations"] as? [String: Any]
    let localization = localizations?[language] as? [String: Any]
    let unit = localization?["stringUnit"] as? [String: Any]
    return unit?["value"] as? String
}
for language in ["en", "zh-Hans", "zh-Hant"] {
    require(localizedValue("Niratan", language: language) == "Niratan", "the \(language) app label should remain Niratan")
    require(localizedValue("Hoshi Reader", language: language) == "Hoshi Reader", "the \(language) shared library label should remain Hoshi Reader")
}
requireContains(libraryCache, "static let sharedLibraryName = \"Hoshi Reader\"", "the shared cloud library name should remain compatible with Hoshi Reader")
requireContains(libraryHandler, "static let rootFolderName = GoogleDriveSyncCache.sharedLibraryName", "Drive layout should use the shared library name instead of the app brand")
requireContains(syncView, "NativeSettingsSectionCard(\"Hoshi Reader\")", "Sync Settings should distinguish the Hoshi Reader library from the Niratan app")
require(localizedStrings["Original Hoshi Reader Project"] != nil, "attribution to the original Hoshi Reader project should remain explicit")

requireContains(readme, "# Niratan", "README should present the renamed project")
requireContains(readme, "https://github.com/W1ght/Niratan/releases", "README should link to the renamed release page")

print("Branding contract checks passed")
