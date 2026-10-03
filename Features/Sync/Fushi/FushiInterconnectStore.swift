//
//  FushiInterconnectStore.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import Security

/// The paired Fushi host. Like AnkiConnect, the connection is global transport
/// state rather than Profile configuration; the pairing token lives in its own
/// Keychain service and never in UserDefaults.
@Observable
final class FushiInterconnectStore {
    static let shared = FushiInterconnectStore()

    private enum Keys {
        static let hostURL = "fushiInterconnect.hostURL"
        static let hostName = "fushiInterconnect.hostName"
        static let hostID = "fushiInterconnect.hostID"
        static let fingerprint = "fushiInterconnect.tlsFingerprint"
        static let autoSync = "fushiInterconnect.autoSyncProgress"
        static let clientDeviceID = "fushiInterconnect.clientDeviceID"
    }

    private nonisolated static let keychainService = DevelopmentDataIsolation.keychainName("moe.shishamo.hoshi.fushi-interconnect")
    private nonisolated static let tokenAccount = "pairingToken"

    private let defaults: UserDefaults

    private(set) var hostURL: URL?
    private(set) var hostName: String?
    private(set) var hostID: String?
    private(set) var tlsFingerprint: String?
    private(set) var hasToken: Bool

    var autoSyncProgress: Bool {
        didSet { defaults.set(autoSyncProgress, forKey: Keys.autoSync) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hostURL = defaults.string(forKey: Keys.hostURL).flatMap(URL.init(string:))
        hostName = defaults.string(forKey: Keys.hostName)
        hostID = defaults.string(forKey: Keys.hostID)
        tlsFingerprint = defaults.string(forKey: Keys.fingerprint)
        autoSyncProgress = defaults.object(forKey: Keys.autoSync) as? Bool ?? true
        // Presence only: reading the secret here could raise a Keychain prompt and
        // block the first window.
        hasToken = Self.tokenExists()
    }

    var isPaired: Bool {
        hostURL != nil && hasToken
    }

    /// Identifies the host for progress baselines; falls back to the address for
    /// hosts that do not report a host id.
    var baselineHostKey: String? {
        guard let hostURL else { return nil }
        if let hostID, !hostID.isEmpty { return hostID }
        return hostURL.absoluteString
    }

    var displayName: String {
        if let hostName, !hostName.isEmpty { return hostName }
        return hostURL?.host() ?? "Fushi"
    }

    /// Stable per-installation id so re-pairing replaces this Mac's peer entry on
    /// the host instead of adding another one.
    var clientDeviceID: String {
        if let existing = defaults.string(forKey: Keys.clientDeviceID), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: Keys.clientDeviceID)
        return created
    }

    /// Reads the token off the main thread, only when a sync actually needs it.
    func makeClient() async -> FushiInterconnectClient? {
        guard let hostURL, hasToken else { return nil }
        guard let token = await Task.detached(priority: .userInitiated, operation: { Self.readToken() }).value else {
            return nil
        }
        return FushiInterconnectClient(baseURL: hostURL, token: token, pinnedFingerprint: tlsFingerprint)
    }

    func savePairing(hostURL: URL, info: FushiHostInfo, token: String, fingerprint: String?) -> Bool {
        guard Self.writeToken(token) else { return false }
        self.hostURL = hostURL
        hostName = info.deviceName
        hostID = info.hostId
        tlsFingerprint = fingerprint
        hasToken = true
        defaults.set(hostURL.absoluteString, forKey: Keys.hostURL)
        set(info.deviceName, forKey: Keys.hostName)
        set(info.hostId, forKey: Keys.hostID)
        set(fingerprint, forKey: Keys.fingerprint)
        return true
    }

    /// Forgets the host and its token. Reading progress, bookmarks and baselines
    /// stay untouched.
    func unpair() {
        Self.deleteToken()
        hasToken = false
        hostURL = nil
        hostName = nil
        hostID = nil
        tlsFingerprint = nil
        for key in [Keys.hostURL, Keys.hostName, Keys.hostID, Keys.fingerprint] {
            defaults.removeObject(forKey: key)
        }
    }

    private func set(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Keychain

    private nonisolated static func tokenExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private nonisolated static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func writeToken(_ token: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount
        ]
        let update: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Per-host progress baselines. They describe this Mac's agreement with one
/// host, so they live outside the book folders: a book restored or copied to
/// another device must not carry them along.
final class FushiProgressBaselineStore {
    static let shared = FushiProgressBaselineStore()

    private var cache: [String: [String: FushiProgressBaseline]]?

    private init() {}

    func baseline(hostKey: String, bookKey: String) -> FushiProgressBaseline? {
        load()[hostKey]?[bookKey]
    }

    func setBaseline(_ baseline: FushiProgressBaseline, hostKey: String, bookKey: String) {
        var all = load()
        all[hostKey, default: [:]][bookKey] = baseline
        cache = all
        save(all)
    }

    private func fileURL() throws -> URL {
        let directory = try BookStorage.getAppDirectory().appendingPathComponent("FushiInterconnect", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("progress_baselines.json")
    }

    private func load() -> [String: [String: FushiProgressBaseline]] {
        if let cache { return cache }
        let loaded = (try? fileURL())
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: [String: FushiProgressBaseline]].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    private func save(_ all: [String: [String: FushiProgressBaseline]]) {
        guard let url = try? fileURL(), let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
