// test-sources: Features/Popup/PopupShortcutActions.swift Features/Reader/ReaderShortcutActions.swift Core/Shortcuts/ShortcutRegistry.swift Features/Video/VideoShortcutActions.swift Core/Shortcuts/ShortcutAction.swift Core/Shortcuts/KeyboardShortcutBinding.swift Features/Settings/ApplicationShortcutRegistry.swift Features/Dictionary/DictionaryShortcutActions.swift Features/Sasayaki/SasayakiShortcutActions.swift Features/Manga/MangaShortcutActions.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum ShortcutRegistryTests {
    static func main() {
        let registry = ShortcutRegistry.application
        let ids = registry.actions.map(\.id)

        expect(Set(ids).count == ids.count, "action identifiers must be unique")
        expect(
            registry.action(id: ReaderShortcutActions.previousPage.id)?.category == .reader,
            "Reader actions should be registered in the Reader category"
        )
        expect(
            registry.action(id: PopupShortcutActions.dismiss.id)?.scopes == [.popup],
            "Popup dismissal should be limited to Popup scope"
        )

        expect(
            registry.action(id: VideoShortcutActions.playPause.id)?.category == .video,
            "Video actions should be registered in Video builds"
        )
        expect(
            registry.action(id: VideoShortcutActions.toggleSubtitleGapFastForward.id)?.scopes == [.video],
            "Video subtitle gap fast-forward should be registered in Video scope"
        )
        expect(
            registry.action(id: MangaShortcutActions.pageLeft.id)?.category == .manga
                && registry.action(id: MangaShortcutActions.pageLeft.id)?.scopes == [.manga]
                && registry.action(id: MangaShortcutActions.toggleInterface.id)?.defaultBinding
                    == KeyboardShortcutBinding(key: "m"),
            "Manga reader actions should be rebindable in their own Manga scope"
        )

        print("Shortcut registry tests passed")
    }
}
