// test-sources:
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func source(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

@main
private enum CrossAppSelectionLookupContractTests {
    static func main() throws {
        let panel = try source("NativeMac/QuickLookupPanelController.swift")
        let reader = try source("Core/SelectionLookup/AccessibilitySelectionReader.swift")
        let coordinator = try source("Core/SelectionLookup/SelectionLookupCoordinator.swift")
        let app = try source("NativeMac/HoshiNativeMacApp.swift")
        let settings = try source("Features/Settings/KeyboardShortcutsView.swift")
        let config = try source("Core/UserConfig.swift")

        expect(panel.contains(".nonactivatingPanel"), "quick lookup must use a non-activating panel")
        expect(panel.contains("visibleFrame"), "quick lookup placement must respect the usable display frame")
        expect(panel.contains("anchorRect:"), "quick lookup panels must be positioned from selected-text bounds")
        expect(coordinator.contains("snapshot.screenBounds"), "quick lookup should prefer accessibility selected-text bounds over the mouse location")
        expect(panel.contains("PopupView("), "quick lookup must reuse the shared popup result surface")
        expect(panel.contains("placement: .panelSurface"), "quick lookup panels must fill their transient window instead of using fake anchored popup geometry")
        expect(panel.contains("PopupPanelEntry"), "quick lookup must track one transient panel per popup stack entry")
        expect(panel.contains("presentChild"), "quick lookup nested selections must open a separate transient panel")
        expect(panel.contains("QuickLookupPanelGeometry.screenRect("), "quick lookup child popups must anchor to selected text inside the parent panel")
        expect(panel.contains("func handleMouseDown(at point: CGPoint)"), "quick lookup should centralize mouse-down dismissal behavior")
        expect(panel.contains("popupID(containing: point)"), "quick lookup should identify which popup panel was clicked")
        expect(panel.contains("closePanels(after: popupID)"), "clicking a parent quick lookup popup should remove only its child popup stack")
        expect(panel.contains("coordinator?.handleTapInsidePopup(id: popupID)"), "parent-panel clicks should also trim the shared popup coordinator stack")
        expect(panel.contains("guard let popupID = popupID(containing: point) else {\n            close()"), "clicking blank screen space outside every quick lookup panel should clear the whole popup stack")
        expect(!panel.contains("ForEach(coordinator.popups)"), "quick lookup must not render nested popup stack entries inside one panel")
        expect(!panel.contains("CGRect(x: 8, y: 0"), "quick lookup root panels must not depend on a fake selection rect for layout")
        expect(panel.contains("profileID: profileID"), "quick lookup mining must carry the resolved profile ID")
        expect(panel.contains("ShortcutManager(registry: .application)"), "quick lookup must create a shortcut manager for the shared popup surface")
        expect(panel.contains(".environment(shortcutManager)"), "quick lookup must inject ShortcutManager before hosting PopupView")
        expect(panel.contains("shortcutManager.manageEvents(for: panel)"), "quick lookup shortcuts must be scoped to the transient panel window")
        expect(panel.contains("shortcutManager.uninstall()"), "quick lookup must remove popup shortcut registrations when panels close")
        expect(panel.contains("orderFrontRegardless"), "quick lookup should show without activating the main app")
        expect(panel.contains(".canJoinAllSpaces"), "quick lookup should remain available in the current Space")
        expect(!panel.contains(".moveToActiveSpace"), "quick lookup must not combine mutually exclusive Space behaviors")

        expect(coordinator.contains("AccessibilitySelectionReader"), "coordinator must read selection through accessibility")
        expect(coordinator.contains("SystemHotKeyRegistrar"), "coordinator must use the unified system hot key registrar")
        expect(coordinator.contains("ProfileRepository.shared.activeProfile"), "coordinator must resolve lookup context from the globally active Profile")
        expect(!coordinator.contains("ProfileActivationCoordinator"), "cross-app lookup must not reactivate Profile services")
        expect(!coordinator.contains("NSPasteboard"), "cross-app lookup must not read the clipboard")
        expect(!coordinator.contains("CGEvent"), "cross-app lookup must not synthesize copy events")
        expect(reader.contains("kAXSelectedTextAttribute"), "reader must prefer direct accessibility selected-text reads")
        expect(reader.contains("CopyShortcutSelectionFallback"), "reader must fall back to the copy shortcut for apps without AX selected text")
        expect(reader.contains("fallbackBounds = selectedTextScreenBounds(focusedElement: focusedElement)"), "reader must capture selected-text bounds before deciding whether AX text requires fallback")
        expect(reader.contains("screenBounds: selectedTextScreenBounds(focusedElement: element)"), "reader tree search should anchor snapshots to the selected descendant element")
        expect(reader.contains("copyFallback.readSelectedText(screenBounds: fallbackBounds)"), "copy fallback snapshots should keep AX selected-text bounds so panels anchor to the highlighted word")
        expect(reader.contains("NSPasteboard"), "copy fallback must read selected text from the pasteboard")
        expect(reader.contains("CGEvent"), "copy fallback must synthesize the standard copy shortcut")
        expect(reader.contains("snapshot.restore"), "copy fallback must restore the previous pasteboard contents")

        expect(app.contains("SelectionLookupCoordinator"), "app lifecycle must own one selection lookup coordinator")
        expect(settings.contains("crossAppSelectionLookupEnabled"), "shortcut settings must expose the opt-in switch")
        expect(config.contains("crossAppSelectionLookupEnabled"), "selection lookup opt-in must persist in UserConfig")

        print("Cross-app selection lookup contract tests passed")
    }
}
