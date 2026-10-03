// test-sources: Core/Shortcuts/KeyboardShortcutBinding.swift Features/Reader/ReaderShortcutActions.swift Core/Shortcuts/ShortcutConfiguration.swift Core/Shortcuts/ShortcutAction.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum ShortcutConfigurationMigrationTests {
    static func main() throws {
        let encoder = JSONEncoder()
        let customReader = KeyboardShortcutBinding(key: "a", modifiers: 1)
        let customVideo = KeyboardShortcutBinding(key: "v", modifiers: 1)
        let existing = ShortcutConfiguration(
            version: ShortcutConfiguration.currentVersion,
            bindings: [
                ReaderShortcutActions.previousPage.id: customReader,
                "video.playPause": customVideo
            ]
        )
        let existingData = try encoder.encode(existing)
        let legacyNext = KeyboardShortcutBinding(key: "n")
        let legacyData = [
            "readerPreviousPageShortcut": try encoder.encode(KeyboardShortcutBinding.leftArrow),
            "readerNextPageShortcut": try encoder.encode(legacyNext)
        ]

        let migrated = ShortcutConfiguration.migrating(
            storedData: existingData,
            legacyData: legacyData,
            legacyActionIDs: [
                "readerPreviousPageShortcut": ReaderShortcutActions.previousPage.id,
                "readerNextPageShortcut": ReaderShortcutActions.nextPage.id
            ]
        )

        expect(
            migrated.bindings[ReaderShortcutActions.previousPage.id] == customReader,
            "existing unified values must win over legacy values"
        )
        expect(
            migrated.bindings[ReaderShortcutActions.nextPage.id] == legacyNext,
            "missing unified values should import legacy bindings"
        )
        expect(
            migrated.bindings["video.playPause"] == customVideo,
            "unknown or conditionally unavailable action values must be preserved"
        )

        let legacyOnly = ShortcutConfiguration.migrating(
            storedData: nil,
            legacyData: legacyData,
            legacyActionIDs: [
                "readerPreviousPageShortcut": ReaderShortcutActions.previousPage.id,
                "readerNextPageShortcut": ReaderShortcutActions.nextPage.id
            ]
        )
        expect(
            legacyOnly.bindings[ReaderShortcutActions.previousPage.id] == .leftArrow,
            "legacy-only configuration should migrate all recognized values"
        )

        print("Shortcut configuration migration tests passed")
    }
}
