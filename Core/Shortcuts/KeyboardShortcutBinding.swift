import SwiftUI

struct KeyboardShortcutBinding: Codable, Equatable, Hashable, Identifiable {
    var key: String
    var modifiers: Int = 0
    var keyCode: UInt16? = nil

    var id: String { "\(modifiers)-\(key)" }

    static func == (lhs: KeyboardShortcutBinding, rhs: KeyboardShortcutBinding) -> Bool {
        lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers)
    }

    var eventModifiers: EventModifiers {
        EventModifiers(rawValue: modifiers)
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "escape": .escape
        case "leftArrow": .leftArrow
        case "rightArrow": .rightArrow
        case "upArrow": .upArrow
        case "downArrow": .downArrow
        case "pageUp": .pageUp
        case "pageDown": .pageDown
        case "space": .space
        default:
            KeyEquivalent(Character(key.lowercased()))
        }
    }

    var label: String {
        let modifierLabels: [(EventModifiers, String)] = [
            (.command, "⌘"),
            (.shift, "⇧"),
            (.option, "⌥"),
            (.control, "⌃")
        ]
        let prefix = modifierLabels
            .filter { eventModifiers.contains($0.0) }
            .map(\.1)
            .joined()
        return prefix + keyLabel
    }

    private var keyLabel: String {
        switch key {
        case "escape": "Esc"
        case "leftArrow": "←"
        case "rightArrow": "→"
        case "upArrow": "↑"
        case "downArrow": "↓"
        case "pageUp": String(localized: "Page Up")
        case "pageDown": String(localized: "Page Down")
        case "space": String(localized: "Space")
        default: key.uppercased()
        }
    }

    static let escape = KeyboardShortcutBinding(key: "escape")
    static let leftArrow = KeyboardShortcutBinding(key: "leftArrow")
    static let rightArrow = KeyboardShortcutBinding(key: "rightArrow")
    static let upArrow = KeyboardShortcutBinding(key: "upArrow")
    static let downArrow = KeyboardShortcutBinding(key: "downArrow")
    static let bracketLeft = KeyboardShortcutBinding(key: "[")
    static let bracketRight = KeyboardShortcutBinding(key: "]")
    static let j = KeyboardShortcutBinding(key: "j")
    static let p = KeyboardShortcutBinding(key: "p")
    static let r = KeyboardShortcutBinding(key: "r")
    static let space = KeyboardShortcutBinding(key: "space")
}

typealias ReaderKeyboardShortcut = KeyboardShortcutBinding
