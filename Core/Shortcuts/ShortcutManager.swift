import AppKit
import Observation

protocol ShortcutEventCaptureResponder: AnyObject {}

typealias ShortcutHandler = @MainActor () -> Bool

private enum ShortcutDispatchSource {
    case localMonitor
    case responder
}

@Observable
@MainActor
final class ShortcutManager {
    private struct Registration {
        let scope: ShortcutScope
        let handlers: [String: ShortcutHandler]
        let order: Int
    }

    private struct InstalledManager {
        weak var manager: ShortcutManager?
    }

    private let registry: ShortcutRegistry
    private weak var userConfig: UserConfig?
    private var registrations: [UUID: Registration] = [:]
    private var nextRegistrationOrder = 0
    private var isInstalled = false
    private weak var managedWindow: NSWindow?
    private static var installedManagers: [InstalledManager] = []
    private static var sharedMonitor: Any?

    init(registry: ShortcutRegistry) {
        self.registry = registry
    }

    func configure(userConfig: UserConfig) {
        self.userConfig = userConfig
    }

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        Self.installedManagers.append(InstalledManager(manager: self))
        Self.installSharedMonitorIfNeeded()
    }

    private static func installSharedMonitorIfNeeded() {
        guard sharedMonitor == nil else { return }
        sharedMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return Self.dispatchLocalMonitorEvent(event)
        }
    }

    private static func dispatchLocalMonitorEvent(_ event: NSEvent) -> NSEvent? {
        installedManagers.removeAll { $0.manager == nil }
        for entry in installedManagers.reversed() {
            guard let manager = entry.manager,
                  manager.managedWindow === event.window else {
                continue
            }
            if manager.handle(event, source: .localMonitor) == nil {
                return nil
            }
        }
        return event
    }

    @discardableResult
    static func dispatchActionIDs(_ actionIDs: [String]) -> Bool {
        guard !actionIDs.isEmpty else { return false }
        installedManagers.removeAll { $0.manager == nil }

        for entry in installedManagers.reversed() {
            guard let manager = entry.manager,
                  manager.managedWindow?.isKeyWindow == true else {
                continue
            }
            if manager.handleActionIDs(actionIDs) {
                return true
            }
        }
        return false
    }

    func manageEvents(for window: NSWindow?) {
        managedWindow = window
    }

    func uninstall() {
        if isInstalled {
            isInstalled = false
            Self.installedManagers.removeAll { $0.manager == nil || $0.manager === self }
        }
        if Self.installedManagers.isEmpty, let sharedMonitor = Self.sharedMonitor {
            NSEvent.removeMonitor(sharedMonitor)
            Self.sharedMonitor = nil
        }
        registrations.removeAll()
    }

    @discardableResult
    func register(
        scope: ShortcutScope,
        handlers: [String: ShortcutHandler]
    ) -> UUID {
        let id = UUID()
        registrations[id] = Registration(
            scope: scope,
            handlers: handlers,
            order: nextRegistrationOrder
        )
        nextRegistrationOrder += 1
        return id
    }

    func unregister(_ id: UUID?) {
        guard let id else { return }
        registrations.removeValue(forKey: id)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        return handle(event, source: .responder) == nil
    }

    private func handleActionIDs(_ actionIDs: [String]) -> Bool {
        for registration in orderedRegistrations {
            for actionID in actionIDs {
                if registration.handlers[actionID]?() == true {
                    return true
                }
            }
        }
        return false
    }

    private func handle(
        _ event: NSEvent,
        source: ShortcutDispatchSource
    ) -> NSEvent? {
        guard shouldHandle(event, source: source),
              let binding = KeyboardShortcutBinding(nsEvent: event),
              let userConfig else {
            return event
        }

        let activeRegistrations = orderedRegistrations
        let activeScopes = activeRegistrations.map(\.scope)
        let handledActionIDs = Set(
            activeRegistrations.flatMap { $0.handlers.keys }
        )
        let bindings = Dictionary(
            uniqueKeysWithValues: registry.actions.map {
                ($0.id, userConfig.shortcutBinding(for: $0))
            }
        )
        let candidates = ShortcutDispatchResolver.candidates(
            binding: binding,
            actions: registry.actions,
            bindings: bindings,
            activeScopes: activeScopes,
            handledActionIDs: handledActionIDs
        )

        for actionID in candidates {
            for registration in activeRegistrations {
                if registration.handlers[actionID]?() == true {
                    return nil
                }
            }
        }
        return event
    }

    private var orderedRegistrations: [Registration] {
        registrations.values.sorted {
            let firstPriority = Self.priority(for: $0.scope)
            let secondPriority = Self.priority(for: $1.scope)
            if firstPriority == secondPriority {
                return $0.order > $1.order
            }
            return firstPriority > secondPriority
        }
    }

    private func shouldHandle(
        _ event: NSEvent,
        source: ShortcutDispatchSource
    ) -> Bool {
        guard let managedWindow,
              event.window === managedWindow,
              !event.isARepeat else {
            return false
        }
        let responder = event.window?.firstResponder
        if responder is ShortcutEventCaptureResponder {
            return false
        }
        if let textView = responder as? NSTextView {
            return !textView.isEditable
        }
        if responder is NSTextField {
            return false
        }
        return true
    }

    private static func priority(for scope: ShortcutScope) -> Int {
        switch scope {
        case .popup: 500
        case .sasayaki: 400
        case .reader, .dictionary, .video, .manga: 300
        case .global: 100
        }
    }

}
