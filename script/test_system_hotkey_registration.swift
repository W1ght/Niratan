// test-sources: Core/Shortcuts/KeyboardShortcutBinding.swift Core/Shortcuts/SystemHotKeyRegistrar.swift
import Carbon
import Foundation
import SwiftUI

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum SystemHotKeyRegistrationTests {
    static func main() throws {
        let legacy = Data(#"{"key":"d","modifiers":9}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(KeyboardShortcutBinding.self, from: legacy)
        expect(decodedLegacy.key == "d", "legacy shortcut should retain its logical key")
        expect(decodedLegacy.keyCode == nil, "legacy shortcut should decode without a physical key code")

        let binding = KeyboardShortcutBinding(
            key: "d",
            modifiers: EventModifiers.command.rawValue | EventModifiers.control.rawValue,
            keyCode: 2
        )
        let roundTrip = try JSONDecoder().decode(
            KeyboardShortcutBinding.self,
            from: JSONEncoder().encode(binding)
        )
        expect(roundTrip.keyCode == 2, "recorded shortcut should preserve its physical key code")

        let descriptor = SystemHotKeyDescriptor(binding: binding)
        expect(descriptor?.keyCode == 2, "system hot key should use the recorded physical key code")
        expect(descriptor?.modifiers == UInt32(cmdKey | controlKey), "system hot key should map command and control modifiers")

        let inferred = SystemHotKeyDescriptor(
            binding: KeyboardShortcutBinding(
                key: "d",
                modifiers: EventModifiers.command.rawValue | EventModifiers.control.rawValue
            )
        )
        expect(inferred?.keyCode == 2, "default shortcut should infer the ANSI D key code")

        let unsupported = SystemHotKeyDescriptor(
            binding: KeyboardShortcutBinding(key: "🙂", modifiers: EventModifiers.command.rawValue)
        )
        expect(unsupported == nil, "unsupported logical keys should not register an arbitrary hot key")

        print("System hot key registration tests passed")
    }
}
