import AppKit
import SwiftUI

private final class QuickLookupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct QuickLookupStatusView: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

private struct QuickLookupPanelContent: View {
    @Environment(UserConfig.self) private var userConfig
    @Bindable var coordinator: PopupPresentationCoordinator
    let popupID: UUID
    let profileID: String
    let onTextSelected: (UUID, SelectionData) -> Int?
    let onTapInside: (UUID) -> Void
    let onDismiss: (UUID) -> Void

    var body: some View {
        GeometryReader { geometry in
            if let popup = coordinator.popups.first(where: { $0.id == popupID }) {
                PopupView(
                    userConfig: userConfig,
                    isVisible: Binding(
                        get: {
                            coordinator.popups.first(where: { $0.id == popupID })?.showPopup ?? false
                        },
                        set: { coordinator.setVisibility(id: popupID, visible: $0) }
                    ),
                    selectionData: popup.currentSelection,
                    lookupResults: popup.lookupResults,
                    dictionaryStyles: popup.dictionaryStyles,
                    screenSize: geometry.size,
                    isVertical: false,
                    isFullWidth: false,
                    placement: .panelSurface,
                    coverURL: nil,
                    documentTitle: nil,
                    profileID: profileID,
                    clearSelection: popup.clearSelection,
                    onTextSelected: { selection in
                        onTextSelected(popupID, selection)
                    },
                    onTapOutside: {
                        onTapInside(popupID)
                    },
                    onSwipeDismiss: {
                        onDismiss(popupID)
                    }
                )
                .id(popupID)
            }
        }
    }
}

@MainActor
final class QuickLookupPanelController {
    static let shared = QuickLookupPanelController()

    private struct PopupPanelEntry {
        let id: UUID
        let panel: QuickLookupPanel
        let shortcutManager: ShortcutManager
    }

    private var coordinator: PopupPresentationCoordinator?
    private var panelEntries: [UUID: PopupPanelEntry] = [:]
    private var popupOrder: [UUID] = []
    private var statusPanel: QuickLookupPanel?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var statusDismissTask: Task<Void, Never>?

    private init() {}

    @discardableResult
    func present(
        text: String,
        profileID: String,
        anchorRect: CGRect,
        userConfig: UserConfig
    ) -> Bool {
        close()
        let coordinator = PopupPresentationCoordinator()
        self.coordinator = coordinator
        let rootSelection = SelectionData(
            text: text,
            sentence: text,
            rect: .zero,
            normalizedOffset: nil
        )
        guard coordinator.present(
            selection: rootSelection,
            userConfig: userConfig,
            replacingExisting: true
        ) != nil,
              let popup = coordinator.popups.last else {
            presentStatus(
                String(localized: "No dictionary result found."),
                anchor: CGPoint(x: anchorRect.midX, y: anchorRect.midY)
            )
            return false
        }

        presentPanel(
            for: popup.id,
            coordinator: coordinator,
            profileID: profileID,
            userConfig: userConfig,
            anchorRect: anchorRect
        )
        installDismissMonitors()
        return true
    }

    func present(error: SelectionLookupError, anchor: CGPoint) {
        let message = switch error {
        case .permissionRequired: String(localized: "Accessibility permission is required for cross-app lookup.")
        case .noSelection: String(localized: "No selected text was found.")
        case .unsupported: String(localized: "The current app does not expose its selected text.")
        case .readFailed: String(localized: "Selected text could not be read.")
        }
        presentStatus(message, anchor: anchor)
    }

    func close() {
        statusDismissTask?.cancel()
        statusDismissTask = nil
        coordinator = nil
        for popupID in popupOrder.reversed() {
            closePanel(id: popupID)
        }
        popupOrder.removeAll()
        statusPanel?.orderOut(nil)
        statusPanel = nil
        removeDismissMonitors()
    }

    private func presentChild(
        parentID: UUID,
        selection: SelectionData,
        coordinator: PopupPresentationCoordinator,
        profileID: String,
        userConfig: UserConfig
    ) -> Int? {
        guard let parentEntry = panelEntries[parentID] else { return nil }
        closePanels(after: parentID)
        coordinator.closeChildren(of: parentID)

        guard let matchedCount = coordinator.present(selection: selection, userConfig: userConfig),
              let popup = coordinator.popups.last else {
            return nil
        }

        let anchorRect = QuickLookupPanelGeometry.screenRect(
            parentFrame: parentEntry.panel.frame,
            localRect: selection.rect
        )
        presentPanel(
            for: popup.id,
            coordinator: coordinator,
            profileID: profileID,
            userConfig: userConfig,
            anchorRect: anchorRect
        )
        installDismissMonitors()
        return matchedCount
    }

    private func presentPanel(
        for popupID: UUID,
        coordinator: PopupPresentationCoordinator,
        profileID: String,
        userConfig: UserConfig,
        anchorRect: CGRect
    ) {
        let panel = configuredPanel(size: Self.popupSize(userConfig: userConfig), anchorRect: anchorRect)
        let shortcutManager = ShortcutManager(registry: .application)
        shortcutManager.configure(userConfig: userConfig)
        shortcutManager.manageEvents(for: panel)
        shortcutManager.install()
        panel.contentView = NSHostingView(
            rootView: QuickLookupPanelContent(
                coordinator: coordinator,
                popupID: popupID,
                profileID: profileID,
                onTextSelected: { popupID, selection in
                    QuickLookupPanelController.shared.presentChild(
                        parentID: popupID,
                        selection: selection,
                        coordinator: coordinator,
                        profileID: profileID,
                        userConfig: userConfig
                    )
                },
                onTapInside: { popupID in
                    QuickLookupPanelController.shared.closePanels(after: popupID)
                    coordinator.handleTapInsidePopup(id: popupID)
                },
                onDismiss: { popupID in
                    QuickLookupPanelController.shared.dismissPopup(id: popupID, coordinator: coordinator)
                }
            )
            .environment(userConfig)
            .environment(shortcutManager)
        )
        panel.orderFrontRegardless()
        panelEntries[popupID] = PopupPanelEntry(
            id: popupID,
            panel: panel,
            shortcutManager: shortcutManager
        )
        popupOrder.append(popupID)
    }

    private func presentStatus(_ message: String, anchor: CGPoint) {
        close()
        let panel = configuredPanel(size: CGSize(width: 360, height: 92), anchor: anchor)
        statusPanel = panel
        panel.contentView = NSHostingView(rootView: QuickLookupStatusView(message: message))
        panel.orderFrontRegardless()
        installDismissMonitors()
        statusDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func configuredPanel(size: CGSize, anchor: CGPoint) -> QuickLookupPanel {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let frame = QuickLookupPanelGeometry.frame(anchor: anchor, size: size, visibleFrame: visibleFrame)
        return configuredPanel(frame: frame)
    }

    private func configuredPanel(size: CGSize, anchorRect: CGRect) -> QuickLookupPanel {
        let anchorPoint = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) || $0.frame.contains(anchorPoint) })
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let frame = QuickLookupPanelGeometry.frame(anchorRect: anchorRect, size: size, visibleFrame: visibleFrame)
        return configuredPanel(frame: frame)
    }

    private func configuredPanel(frame: CGRect) -> QuickLookupPanel {
        let panel = QuickLookupPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func popupSize(userConfig: UserConfig) -> CGSize {
        CGSize(
            width: max(280, CGFloat(userConfig.popupWidth)),
            height: max(240, CGFloat(userConfig.popupHeight))
        )
    }

    private func dismissPopup(id: UUID, coordinator: PopupPresentationCoordinator) {
        guard popupOrder.first != id else {
            close()
            return
        }
        closePanels(from: id)
        coordinator.dismiss(id: id)
    }

    private func dismissTopmostPanel() {
        guard let topmostID = popupOrder.last else {
            close()
            return
        }
        if let coordinator {
            dismissPopup(id: topmostID, coordinator: coordinator)
        } else {
            close()
        }
    }

    private func closePanels(after popupID: UUID) {
        guard let index = popupOrder.firstIndex(of: popupID) else { return }
        let ids = Array(popupOrder.dropFirst(index + 1))
        for id in ids {
            closePanel(id: id)
        }
        popupOrder.removeSubrange((index + 1)..<popupOrder.endIndex)
    }

    private func closePanels(from popupID: UUID) {
        guard let index = popupOrder.firstIndex(of: popupID) else { return }
        let ids = Array(popupOrder.dropFirst(index))
        for id in ids {
            closePanel(id: id)
        }
        popupOrder.removeSubrange(index..<popupOrder.endIndex)
    }

    private func closePanel(id: UUID) {
        guard let entry = panelEntries.removeValue(forKey: id) else { return }
        _ = entry.id
        entry.shortcutManager.uninstall()
        entry.panel.orderOut(nil)
    }

    private func popupID(containing point: CGPoint) -> UUID? {
        popupOrder.reversed().first { popupID in
            panelEntries[popupID]?.panel.frame.contains(point) == true
        }
    }

    private func handleMouseDown(at point: CGPoint) {
        if statusPanel?.frame.contains(point) == true {
            return
        }
        guard let popupID = popupID(containing: point) else {
            close()
            return
        }
        guard popupID != popupOrder.last else { return }
        closePanels(after: popupID)
        coordinator?.handleTapInsidePopup(id: popupID)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.dismissTopmostPanel()
                } else if event.type != .keyDown {
                    self.handleMouseDown(at: NSEvent.mouseLocation)
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                dismissTopmostPanel()
                return nil
            }
            if event.type != .keyDown {
                handleMouseDown(at: NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
            self.outsideMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}
