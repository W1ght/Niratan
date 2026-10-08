//
//  TokenStorage.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security

struct GoogleDriveCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let clientId: String
    let clientSecret: String?

    init(accessToken: String, refreshToken: String, clientId: String, clientSecret: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

class TokenStorage {
    private static let credentialsAccount = DevelopmentDataIsolation.keychainName("googleDriveCredentials")
    private static let credentialsPresenceKey = "GoogleDriveCredentialsStored"
    private static let legacyAccessTokenAccount = DevelopmentDataIsolation.keychainName("accessToken")
    private static let legacyRefreshTokenAccount = DevelopmentDataIsolation.keychainName("refreshToken")
    private static let legacyClientIdAccount = DevelopmentDataIsolation.keychainName("clientId")
    private static let legacyCredentialAccounts = [legacyAccessTokenAccount, legacyRefreshTokenAccount, legacyClientIdAccount]

    static var hasStoredCredentials: Bool {
        if let storedValue = UserDefaults.standard.object(forKey: credentialsPresenceKey) as? Bool {
            return storedValue
        }

        let hasCredentials = accountExists(credentialsAccount) || legacyCredentialAccounts.allSatisfy(accountExists)
        UserDefaults.standard.set(hasCredentials, forKey: credentialsPresenceKey)
        return hasCredentials
    }

    @discardableResult
    static func saveCredentials(_ credentials: GoogleDriveCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: credentialsAccount
        ]
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: credentialsAccount,
            kSecValueData as String: data
        ]
        // A failed reconnect must not delete the still-valid previous authorization.
        // Update the existing item in place, creating it only when none exists.
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status == errSecSuccess {
            UserDefaults.standard.set(true, forKey: credentialsPresenceKey)
            return true
        }
        return false
    }

    static func getCredentials() -> GoogleDriveCredentials? {
        if let credentials = getStoredCredentials() {
            UserDefaults.standard.set(true, forKey: credentialsPresenceKey)
            return credentials
        }

        guard let credentials = getLegacyCredentials() else {
            UserDefaults.standard.set(false, forKey: credentialsPresenceKey)
            return nil
        }

        _ = saveCredentials(credentials)
        return credentials
    }

    static func clear() {
        deleteAccount(credentialsAccount)
        legacyCredentialAccounts.forEach(deleteAccount)
        UserDefaults.standard.removeObject(forKey: credentialsPresenceKey)
        Task { @MainActor in
            GoogleDriveHandler.clearCache()
        }
    }

    private static func getStoredCredentials() -> GoogleDriveCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: credentialsAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        guard let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleDriveCredentials.self, from: data)
    }

    private static func getLegacyCredentials() -> GoogleDriveCredentials? {
        guard
            let accessToken = getString(for: legacyAccessTokenAccount),
            let refreshToken = getString(for: legacyRefreshTokenAccount),
            let clientId = getString(for: legacyClientIdAccount)
        else {
            return nil
        }

        return GoogleDriveCredentials(accessToken: accessToken, refreshToken: refreshToken, clientId: clientId)
    }

    private static func getString(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func accountExists(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private static func deleteAccount(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
