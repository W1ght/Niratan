// test-sources: NativeMac/ReaderWindowGeometry.swift
import AppKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum ReaderWindowGeometryTests {
    static func main() {
        let visibleFrame = NSRect(x: 12, y: 40, width: 1512, height: 934)
        expect(
            ReaderWindowGeometry.defaultFrame(visibleFrame: visibleFrame) == visibleFrame,
            "Reader default frame should fill the current screen visible area"
        )

        expect(
            ReaderWindowGeometry.defaultFrame(visibleFrame: nil) == NSRect(x: 0, y: 0, width: 1100, height: 760),
            "Reader default frame should keep a stable fallback when no screen is available"
        )

        let largeVisibleFrame = NSRect(x: -990, y: 956, width: 2560, height: 1410)
        let legacyCompactFrame = NSRect(x: -445, y: 1500, width: 1470, height: 866)
        expect(
            !ReaderWindowGeometry.shouldUseSavedFrame(
                legacyCompactFrame,
                visibleFrame: largeVisibleFrame,
                hasCompletedLegacyMigration: false
            ),
            "Reader should migrate old compact autosaved frames on large displays"
        )

        expect(
            ReaderWindowGeometry.shouldUseSavedFrame(
                legacyCompactFrame,
                visibleFrame: largeVisibleFrame,
                hasCompletedLegacyMigration: true
            ),
            "Reader should preserve user-resized compact frames after the one-time migration"
        )

        let offscreenFrame = NSRect(x: 5000, y: 5000, width: 900, height: 700)
        expect(
            !ReaderWindowGeometry.shouldUseSavedFrame(
                offscreenFrame,
                visibleFrame: largeVisibleFrame,
                hasCompletedLegacyMigration: true
            ),
            "Reader should reject saved frames that are not mostly visible on the current display"
        )

        print("Reader window geometry tests passed")
    }
}
