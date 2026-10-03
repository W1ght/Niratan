import Foundation
import Observation
import Security

/// Access tokens for signed-in media servers, one Keychain item per account.
/// Read only when the user browses or plays from a server, never at launch.
actor MediaServerCredentialStore {
    static let shared = MediaServerCredentialStore()

    private let service: String

    init(service: String = "moe.shishamo.hoshi.media-servers") {
        self.service = DevelopmentDataIsolation.keychainName(service)
    }

    func token(for accountID: UUID) throws -> String? {
        var query = baseQuery(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw MediaServerError.missingCredentials
        }
        return value
    }

    func save(token: String, for accountID: UUID) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(
            baseQuery(accountID) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = baseQuery(accountID)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw MediaServerError.missingCredentials
            }
            return
        }
        guard status == errSecSuccess else {
            throw MediaServerError.missingCredentials
        }
    }

    func removeToken(for accountID: UUID) {
        SecItemDelete(baseQuery(accountID) as CFDictionary)
    }

    private func baseQuery(_ accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
    }
}

/// Signed-in media servers, persisted without secrets in
/// `Application Support/media_servers.json`.
@Observable
@MainActor
final class MediaServerAccountStore {
    static let shared = MediaServerAccountStore()

    static let didChangeNotification = Notification.Name(
        "moe.shishamo.hoshi.media-servers.did-change"
    )

    private(set) var accounts: [MediaServerAccount] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let credentials: MediaServerCredentialStore

    init(
        fileURL: URL? = nil,
        credentials: MediaServerCredentialStore = .shared
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.credentials = credentials
        accounts = Self.load(from: self.fileURL)
    }

    func account(id: UUID) -> MediaServerAccount? {
        accounts.first { $0.id == id }
    }

    /// Adds the account, or replaces the existing sign-in for the same server
    /// and user so a repeated login only refreshes its token.
    @discardableResult
    func upsert(_ account: MediaServerAccount, token: String) async throws -> MediaServerAccount {
        var stored = account
        if let existing = accounts.first(where: {
            $0.kind == account.kind
                && $0.serverURL == account.serverURL
                && $0.userID == account.userID
        }) {
            stored = MediaServerAccount(
                id: existing.id,
                kind: account.kind,
                serverURL: account.serverURL,
                serverName: account.serverName,
                serverID: account.serverID,
                username: account.username,
                userID: account.userID,
                deviceID: account.deviceID,
                addedAt: existing.addedAt
            )
        }
        try await credentials.save(token: token, for: stored.id)
        await MediaServerClientFactory.shared.invalidate(accountID: stored.id)
        if let index = accounts.firstIndex(where: { $0.id == stored.id }) {
            accounts[index] = stored
        } else {
            accounts.append(stored)
        }
        save()
        return stored
    }

    func remove(_ accountID: UUID) async {
        accounts.removeAll { $0.id == accountID }
        save()
        await credentials.removeToken(for: accountID)
        await MediaServerClientFactory.shared.invalidate(accountID: accountID)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(accounts).write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Unable to save media servers: \(error)")
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    nonisolated private static func load(from url: URL) -> [MediaServerAccount] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MediaServerAccount].self, from: data)) ?? []
    }

    nonisolated static func loadAccount(id: UUID) -> MediaServerAccount? {
        load(from: defaultFileURL()).first { $0.id == id }
    }

    nonisolated private static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("media_servers.json")
    }
}
