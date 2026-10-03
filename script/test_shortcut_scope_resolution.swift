// test-sources: Core/Shortcuts/KeyboardShortcutBinding.swift Core/Shortcuts/ShortcutAction.swift Core/Shortcuts/ShortcutConflictChecker.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum ShortcutScopeResolutionTests {
    static func main() {
        let leftArrow = KeyboardShortcutBinding(key: "leftArrow")
        let reader = ShortcutAction(
            id: "reader.previousPage",
            titleKey: "Previous Page",
            category: .reader,
            scopes: [.reader],
            defaultBinding: leftArrow
        )
        let video = ShortcutAction(
            id: "video.seekBackward",
            titleKey: "Seek Backward",
            category: .video,
            scopes: [.video],
            defaultBinding: leftArrow
        )
        let popup = ShortcutAction(
            id: "popup.dismiss",
            titleKey: "Close Popup",
            category: .dictionaryPopup,
            scopes: [.popup],
            defaultBinding: .escape
        )
        let readerEscape = ShortcutAction(
            id: "reader.close",
            titleKey: "Close Reader",
            category: .reader,
            scopes: [.reader],
            defaultBinding: .escape
        )

        expect(
            ShortcutConflictChecker.relationship(between: reader, and: video) == .none,
            "mutually exclusive Reader and Video scopes should reuse bindings"
        )
        expect(
            ShortcutConflictChecker.relationship(between: popup, and: readerEscape) == .shadowed,
            "Popup should shadow the underlying Reader action"
        )

        let global = ShortcutAction(
            id: "global.open",
            titleKey: "Open",
            category: .global,
            scopes: [.global],
            defaultBinding: leftArrow
        )
        expect(
            ShortcutConflictChecker.relationship(between: global, and: reader) == .conflict,
            "Global and Reader bindings should conflict"
        )

        let sasayaki = ShortcutAction(
            id: "sasayaki.previousCue",
            titleKey: "Previous Cue",
            category: .sasayaki,
            scopes: [.sasayaki],
            defaultBinding: leftArrow
        )
        expect(
            ShortcutConflictChecker.relationship(between: sasayaki, and: reader) == .conflict,
            "Sasayaki and Reader scopes can be active together"
        )

        print("Shortcut scope resolution tests passed")
    }
}
