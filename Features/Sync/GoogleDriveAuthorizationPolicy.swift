//
//  GoogleDriveAuthorizationPolicy.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Both platforms must use OAuth clients from the same logical Google Cloud app.
/// Broad Drive access on the Mac alone does not let Hoshi see files the Mac creates.
nonisolated enum GoogleDriveAuthorizationPolicy {
    static let fileScope = "https://www.googleapis.com/auth/drive.file"
    static let libraryScope = "https://www.googleapis.com/auth/drive"

    static let requestedScope = fileScope

    static func permitsStoredScope(_ scope: String?) -> Bool {
        // Compatible older clients already requested drive.file without recording it.
        scope == nil || includes(scope, required: fileScope)
    }

    static func includes(_ scope: String?, required: String) -> Bool {
        let granted = Set((scope ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        return granted.contains(required) || (required == fileScope && granted.contains(libraryScope))
    }

    /// OAuth permits omitting `scope` when it exactly matches the requested scope.
    /// A returned scope is always checked rather than assuming the request was granted.
    static func grantedScope(response: String?, requested: String) -> String? {
        let granted = response ?? requested
        return includes(granted, required: requested) ? granted : nil
    }

    /// Only an explicit OAuth rejection of this refresh token invalidates stored
    /// credentials. Rate limits, server failures and client configuration errors
    /// must leave the previous authorization available for a later retry.
    static func invalidatesStoredCredentials(statusCode: Int?, responseBody: Data) -> Bool {
        guard statusCode == 400,
              let response = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] else {
            return false
        }
        return response["error"] as? String == "invalid_grant"
    }
}
