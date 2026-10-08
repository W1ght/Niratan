//
//  ReaderBookmarkPersistencePolicy.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum ReaderBookmarkPersistencePolicy {
    /// Layout and restore callbacks can save the same position repeatedly. Preserve its
    /// timestamp so an untouched local page cannot defeat newer reading on another device.
    static func modificationDate(
        currentCharacterCount: Int,
        previousCharacterCount: Int?,
        previousModifiedDate: Date?,
        now: Date = .now
    ) -> Date? {
        previousCharacterCount == currentCharacterCount ? previousModifiedDate : now
    }
}

/// A completion belongs to one injected document, even when the next restore uses the same
/// WKWebView and chapter URL. Layout changes and synced positions each create a new identity.
struct ReaderRestoreIdentity: Equatable {
    let token: String
    let loadRevision: Int
    let reloadID: String

    func accepts(token: String?, loadRevision: Int, reloadID: String) -> Bool {
        self.token == token && self.loadRevision == loadRevision && self.reloadID == reloadID
    }
}
