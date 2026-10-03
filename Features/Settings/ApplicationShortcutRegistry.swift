import SwiftUI

enum GlobalShortcutActions {
    static let open = ShortcutAction(
        id: "global.open",
        titleKey: "Open",
        category: .global,
        scopes: [.global],
        defaultBinding: KeyboardShortcutBinding(
            key: "o",
            modifiers: EventModifiers.command.rawValue
        )
    )

    static let lookupSelectedText = ShortcutAction(
        id: "global.lookupSelectedText",
        titleKey: "Lookup Selected Text",
        category: .global,
        scopes: [.global],
        defaultBinding: KeyboardShortcutBinding(
            key: "d",
            modifiers: EventModifiers.command.rawValue
                | EventModifiers.control.rawValue,
            keyCode: 2
        )
    )

    static let all = [open, lookupSelectedText]
}

extension ShortcutRegistry {
    static var application: ShortcutRegistry {
        var actions =
            GlobalShortcutActions.all
            + ReaderShortcutActions.all
            + DictionaryShortcutActions.all
            + PopupShortcutActions.all
            + SasayakiShortcutActions.all
        actions += VideoShortcutActions.all
        actions += MangaShortcutActions.all
        return ShortcutRegistry(actions: actions)
    }
}
