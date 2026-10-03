// test-sources: Core/Shortcuts/KeyboardShortcutBinding.swift Core/Shortcuts/ShortcutAction.swift Core/Shortcuts/ShortcutDispatchResolver.swift
import Foundation

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
private enum ShortcutDispatchResolutionTests {
    static func main() {
        let escape = KeyboardShortcutBinding.escape
        let popup = ShortcutAction(
            id: "popup.dismiss",
            titleKey: "Close Popup",
            category: .dictionaryPopup,
            scopes: [.popup],
            defaultBinding: escape
        )
        let reader = ShortcutAction(
            id: "reader.close",
            titleKey: "Close Reader",
            category: .reader,
            scopes: [.reader],
            defaultBinding: escape
        )
        let actions = [popup, reader]
        let bindings = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0.defaultBinding) })

        expectEqual(
            ShortcutDispatchResolver.resolve(
                binding: escape,
                actions: actions,
                bindings: bindings,
                activeScopes: [.popup, .reader],
                handledActionIDs: Set(actions.map(\.id))
            ),
            popup.id,
            "Popup should resolve before Reader"
        )
        expectEqual(
            ShortcutDispatchResolver.resolve(
                binding: escape,
                actions: actions,
                bindings: bindings,
                activeScopes: [.reader],
                handledActionIDs: Set(actions.map(\.id))
            ),
            reader.id,
            "Reader should resolve after Popup is inactive"
        )
        expectEqual(
            ShortcutDispatchResolver.resolve(
                binding: .leftArrow,
                actions: actions,
                bindings: bindings,
                activeScopes: [.reader],
                handledActionIDs: Set(actions.map(\.id))
            ),
            nil,
            "Unbound keys should pass through"
        )

        print("Shortcut dispatch resolution tests passed")
    }
}
