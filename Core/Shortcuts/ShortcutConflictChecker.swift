import Foundation

enum ShortcutConflictRelationship: Equatable {
    case none
    case shadowed
    case conflict
}

enum ShortcutConflictChecker {
    static func relationship(
        between first: ShortcutAction,
        and second: ShortcutAction
    ) -> ShortcutConflictRelationship {
        guard first.defaultBinding == second.defaultBinding else {
            return .none
        }

        if isPopupOverlay(first.scopes, second.scopes) {
            return .shadowed
        }

        return scopesOverlap(first.scopes, second.scopes) ? .conflict : .none
    }

    static func relationship(
        between first: ShortcutAction,
        binding firstBinding: KeyboardShortcutBinding,
        and second: ShortcutAction,
        binding secondBinding: KeyboardShortcutBinding
    ) -> ShortcutConflictRelationship {
        guard firstBinding == secondBinding else {
            return .none
        }

        if isPopupOverlay(first.scopes, second.scopes) {
            return .shadowed
        }

        return scopesOverlap(first.scopes, second.scopes) ? .conflict : .none
    }

    static func relationship(
        between first: ShortcutAction,
        and second: ShortcutAction,
        bindingsMatch: Bool
    ) -> ShortcutConflictRelationship {
        guard bindingsMatch else {
            return .none
        }

        if isPopupOverlay(first.scopes, second.scopes) {
            return .shadowed
        }

        return scopesOverlap(first.scopes, second.scopes) ? .conflict : .none
    }

    private static func scopesOverlap(
        _ first: Set<ShortcutScope>,
        _ second: Set<ShortcutScope>
    ) -> Bool {
        if first.contains(.global) || second.contains(.global) {
            return true
        }
        if !first.isDisjoint(with: second) {
            return true
        }

        let pair = first.union(second)
        return pair.contains(.reader) && pair.contains(.sasayaki)
    }

    private static func isPopupOverlay(
        _ first: Set<ShortcutScope>,
        _ second: Set<ShortcutScope>
    ) -> Bool {
        let firstIsPopup = first.contains(.popup)
        let secondIsPopup = second.contains(.popup)
        guard firstIsPopup != secondIsPopup else {
            return false
        }

        let underlying = firstIsPopup ? second : first
        return !underlying.isDisjoint(with: [.reader, .dictionary, .video, .manga])
    }
}
