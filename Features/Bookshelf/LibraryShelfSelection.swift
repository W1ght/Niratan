//
//  LibraryShelfSelection.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What the shelf column of the novel or manga library is showing.
/// `shelf` carries the shelf key: the shelf name for novels, the shelf UUID string for manga.
nonisolated enum LibraryShelfSelection: Hashable, Sendable {
    case all
    case reading
    case unshelved
    case googleDrive
    case shelf(String)
}

nonisolated enum LibraryShelfNaming {
    static func normalized(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Shelf names are unique case-insensitively; `excluding` skips the shelf being renamed.
    static func isAvailable(_ name: String, among names: [String], excluding: String? = nil) -> Bool {
        !names.contains {
            $0 != excluding && $0.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    static func uniqueName(base: String, among names: [String]) -> String {
        if isAvailable(base, among: names) {
            return base
        }
        var suffix = 2
        while !isAvailable("\(base) \(suffix)", among: names) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }
}
