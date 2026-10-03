// test-sources: Core/SelectionLookup/SelectionLookupModels.swift Core/SelectionLookup/AccessibilitySelectionReader.swift
import AppKit
import CoreGraphics
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum SelectionLookupModelTests {
    static func main() {
        expect(
            SelectionTextValidator.validate("  星を見る\n") == .success(SelectionSnapshot(text: "星を見る")),
            "selection text should trim surrounding whitespace"
        )
        expect(
            SelectionTextValidator.validate(
                "星を見る",
                screenBounds: CGRect(x: 320, y: 680, width: 72, height: 22)
            ) == .success(SelectionSnapshot(
                text: "星を見る",
                screenBounds: CGRect(x: 320, y: 680, width: 72, height: 22)
            )),
            "selection snapshots should carry selected-text screen bounds when accessibility exposes them"
        )
        expect(
            SelectionTextValidator.validate("  \n") == .failure(.noSelection),
            "blank selection text should report no selection"
        )
        expect(
            SelectionTextValidator.validate(nil) == .failure(.unsupported),
            "missing selected-text attributes should report unsupported"
        )
        expect(
            SelectionLookupFallbackDecision.shouldAttemptCopyShortcut(after: .unsupported),
            "unsupported accessibility selection should allow copy-shortcut fallback"
        )
        expect(
            SelectionLookupFallbackDecision.shouldAttemptCopyShortcut(after: .readFailed),
            "failed accessibility reads should allow copy-shortcut fallback"
        )
        expect(
            SelectionLookupFallbackDecision.shouldAttemptCopyShortcut(after: .noSelection),
            "empty accessibility selection should allow copy-shortcut fallback for non-editable surfaces"
        )
        expect(
            !SelectionLookupFallbackDecision.shouldAttemptCopyShortcut(after: .permissionRequired),
            "missing accessibility permission should not synthesize a copy shortcut"
        )

        struct MockSelectionElement: Hashable {
            let id: String
        }
        let selectionTree: [MockSelectionElement: [MockSelectionElement]] = [
            MockSelectionElement(id: "focused-window"): [MockSelectionElement(id: "web-area")],
            MockSelectionElement(id: "web-area"): [MockSelectionElement(id: "static-text")],
            MockSelectionElement(id: "static-text"): []
        ]
        let selectedText: [MockSelectionElement: Result<SelectionSnapshot, SelectionLookupError>] = [
            MockSelectionElement(id: "focused-window"): .failure(.unsupported),
            MockSelectionElement(id: "web-area"): .success(SelectionSnapshot(text: "星を見る")),
            MockSelectionElement(id: "static-text"): .failure(.noSelection)
        ]
        let treeSelection = AccessibilitySelectionTreeSearch.firstSelectedText(
            from: MockSelectionElement(id: "focused-window"),
            selectedText: { selectedText[$0] ?? .failure(.unsupported) },
            children: { selectionTree[$0] ?? [] }
        )
        expect(
            treeSelection == .success(SelectionSnapshot(text: "星を見る")),
            "selection lookup should inspect descendants when browser focus containers do not expose selected text directly"
        )

        let pasteboardName = NSPasteboard.Name("moe.shishamo.hoshi.selection-lookup-test")
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()
        let originalItem = NSPasteboardItem()
        originalItem.setString("original clipboard", forType: .string)
        originalItem.setData(Data([0x48, 0x53]), forType: NSPasteboard.PasteboardType("moe.shishamo.hoshi.test-data"))
        pasteboard.writeObjects([originalItem])
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("temporary lookup", forType: .string)
        snapshot.restore(to: pasteboard)
        expect(
            pasteboard.string(forType: .string) == "original clipboard",
            "pasteboard snapshot should restore string data after fallback lookup"
        )
        expect(
            pasteboard.data(forType: NSPasteboard.PasteboardType("moe.shishamo.hoshi.test-data")) == Data([0x48, 0x53]),
            "pasteboard snapshot should restore non-string item data after fallback lookup"
        )

        let visible = CGRect(x: 100, y: 50, width: 1000, height: 700)
        let size = CGSize(width: 360, height: 420)
        let gap: CGFloat = 12

        let lowerRight = QuickLookupPanelGeometry.frame(
            anchor: CGPoint(x: 1080, y: 70),
            size: size,
            visibleFrame: visible,
            gap: gap
        )
        expect(lowerRight.maxX <= visible.maxX, "panel should flip left at the right screen edge")
        expect(lowerRight.minY >= visible.minY, "panel should flip above at the bottom screen edge")

        let upperLeft = QuickLookupPanelGeometry.frame(
            anchor: CGPoint(x: 110, y: 730),
            size: size,
            visibleFrame: visible,
            gap: gap
        )
        expect(upperLeft.minX >= visible.minX, "panel should stay within a screen with a non-zero origin")
        expect(upperLeft.maxY <= visible.maxY, "panel should stay below a top-edge anchor")

        let oversized = QuickLookupPanelGeometry.frame(
            anchor: CGPoint(x: 200, y: 200),
            size: CGSize(width: 2000, height: 1200),
            visibleFrame: visible,
            gap: gap
        )
        expect(oversized == visible, "oversized panels should clamp to the usable screen")

        let parentPanelFrame = CGRect(x: 200, y: 100, width: 420, height: 320)
        let childSelectionRect = CGRect(x: 48, y: 70, width: 132, height: 24)
        let childScreenRect = QuickLookupPanelGeometry.screenRect(
            parentFrame: parentPanelFrame,
            localRect: childSelectionRect
        )
        expect(
            childScreenRect == CGRect(x: 248, y: 326, width: 132, height: 24),
            "child selection rect should convert from panel-local top-left coordinates into screen coordinates"
        )
        let childAnchor = QuickLookupPanelGeometry.screenAnchor(
            parentFrame: parentPanelFrame,
            localRect: childSelectionRect
        )
        expect(childAnchor.x == 380, "child panel anchor should use the selected text trailing edge in screen coordinates")
        expect(childAnchor.y == 338, "child panel anchor should convert top-left SwiftUI y into bottom-left screen coordinates")

        let axBounds = CGRect(x: 320, y: 100, width: 80, height: 22)
        let convertedBounds = QuickLookupPanelGeometry.appKitScreenRect(
            accessibilityBounds: axBounds,
            screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )
        expect(
            convertedBounds == CGRect(x: 320, y: 678, width: 80, height: 22),
            "accessibility text bounds should convert from top-left AX coordinates to AppKit bottom-left screen coordinates"
        )

        let aboveSelectionFrame = QuickLookupPanelGeometry.frame(
            anchorRect: CGRect(x: 480, y: 80, width: 80, height: 22),
            size: CGSize(width: 360, height: 240),
            visibleFrame: visible,
            gap: gap
        )
        expect(
            aboveSelectionFrame.minY == 114,
            "panel should flip above the selected text when there is not enough room below"
        )
        expect(
            aboveSelectionFrame.midX == 520,
            "panel should center horizontally on the selected text bounds"
        )

        let belowSelectionFrame = QuickLookupPanelGeometry.frame(
            anchorRect: CGRect(x: 480, y: 420, width: 80, height: 22),
            size: CGSize(width: 360, height: 240),
            visibleFrame: visible,
            gap: gap
        )
        expect(
            belowSelectionFrame.maxY == 408,
            "panel should appear directly below the selected text when there is room"
        )
        expect(
            belowSelectionFrame.midX == 520,
            "below-selection panel should stay centered on the selected text bounds"
        )

        let croppedAboveFrame = QuickLookupPanelGeometry.frame(
            anchorRect: CGRect(x: 480, y: 320, width: 80, height: 22),
            size: CGSize(width: 360, height: 600),
            visibleFrame: visible,
            gap: gap
        )
        expect(
            croppedAboveFrame.minY == 354,
            "oversized panels should keep their bottom edge directly above the selected text when the upper side has more room"
        )
        expect(
            croppedAboveFrame.maxY == visible.maxY,
            "oversized panels above selected text should crop to the usable screen instead of being pushed down"
        )

        let croppedBelowFrame = QuickLookupPanelGeometry.frame(
            anchorRect: CGRect(x: 480, y: 520, width: 80, height: 22),
            size: CGSize(width: 360, height: 600),
            visibleFrame: visible,
            gap: gap
        )
        expect(
            croppedBelowFrame.maxY == 508,
            "oversized panels should keep their top edge directly below the selected text when the lower side has more room"
        )
        expect(
            croppedBelowFrame.minY == visible.minY,
            "oversized panels below selected text should crop to the usable screen instead of being pushed up"
        )

        print("Selection lookup model tests passed")
    }
}
