import SwiftUI

/// Rebindable manga reader shortcuts. Defaults follow Fushi's manga scope:
/// the arrow keys turn pages in the book's reading direction, Space and the
/// vertical keys move forward or back, M toggles the interface, Control-arrows
/// pan an enlarged page, and Escape steps back out of the reader.
enum MangaShortcutActions {
    static let pageLeft = ShortcutAction(
        id: "manga.pageLeft",
        titleKey: "Turn Page Left",
        category: .manga,
        scopes: [.manga],
        defaultBinding: .leftArrow
    )

    static let pageRight = ShortcutAction(
        id: "manga.pageRight",
        titleKey: "Turn Page Right",
        category: .manga,
        scopes: [.manga],
        defaultBinding: .rightArrow
    )

    static let nextPage = ShortcutAction(
        id: "manga.nextPage",
        titleKey: "Next Page",
        category: .manga,
        scopes: [.manga],
        defaultBinding: .downArrow
    )

    static let previousPage = ShortcutAction(
        id: "manga.previousPage",
        titleKey: "Previous Page",
        category: .manga,
        scopes: [.manga],
        defaultBinding: .upArrow
    )

    static let pageDown = ShortcutAction(
        id: "manga.pageDown",
        titleKey: "Page Down",
        category: .manga,
        scopes: [.manga],
        defaultBinding: KeyboardShortcutBinding(key: "pageDown")
    )

    static let pageUp = ShortcutAction(
        id: "manga.pageUp",
        titleKey: "Page Up",
        category: .manga,
        scopes: [.manga],
        defaultBinding: KeyboardShortcutBinding(key: "pageUp")
    )

    static let advance = ShortcutAction(
        id: "manga.advance",
        titleKey: "Advance",
        category: .manga,
        scopes: [.manga],
        defaultBinding: .space
    )

    static let toggleInterface = ShortcutAction(
        id: "manga.toggleInterface",
        titleKey: "Toggle Interface",
        category: .manga,
        scopes: [.manga],
        defaultBinding: KeyboardShortcutBinding(key: "m")
    )

    static let toggleFullScreen = ShortcutAction(
        id: "manga.toggleFullScreen",
        titleKey: "Toggle Full Screen",
        category: .manga,
        scopes: [.manga],
        defaultBinding: KeyboardShortcutBinding(key: "f")
    )

    static let toggleSettings = ShortcutAction(
        id: "manga.toggleSettings",
        titleKey: "Reader Settings",
        category: .manga,
        scopes: [.manga],
        defaultBinding: KeyboardShortcutBinding(key: "s")
    )

    static let panLeft = ShortcutAction(
        id: "manga.panLeft",
        titleKey: "Pan Left",
        category: .manga,
        scopes: [.manga],
        defaultBinding: KeyboardShortcutBinding(
            key: "leftArrow",
            modifiers: EventModifiers.control.rawValue
        )
    )

    static let panRight = ShortcutAction(
        id: "manga.panRight",
        titleKey: "Pan Right",
        category: .manga,
        scopes: [.manga],
        defaultBinding: KeyboardShortcutBinding(
            key: "rightArrow",
            modifiers: EventModifiers.control.rawValue
        )
    )

    static let panUp = ShortcutAction(
        id: "manga.panUp",
        titleKey: "Pan Up",
        category: .manga,
        scopes: [.manga],
        defaultBinding: KeyboardShortcutBinding(
            key: "upArrow",
            modifiers: EventModifiers.control.rawValue
        )
    )

    static let panDown = ShortcutAction(
        id: "manga.panDown",
        titleKey: "Pan Down",
        category: .manga,
        scopes: [.manga],
        defaultBinding: KeyboardShortcutBinding(
            key: "downArrow",
            modifiers: EventModifiers.control.rawValue
        )
    )

    static let back = ShortcutAction(
        id: "manga.back",
        titleKey: "Back",
        category: .manga,
        scopes: [.manga],
        defaultBinding: .escape
    )

    static let all = [
        pageLeft,
        pageRight,
        nextPage,
        previousPage,
        pageDown,
        pageUp,
        advance,
        toggleInterface,
        toggleFullScreen,
        toggleSettings,
        panLeft,
        panRight,
        panUp,
        panDown,
        back,
    ]
}
