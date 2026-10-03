import Foundation
import Security

actor SuwayomiConnectionStore {
    static let shared = SuwayomiConnectionStore()

    private let configurationFileName = "suwayomi.json"
    private let keychainService = DevelopmentDataIsolation.keychainName("moe.shishamo.hoshi.suwayomi")

    func configuration(
        profileID: String
    ) async -> SuwayomiServerConfiguration {
        await storedConfiguration(profileID: profileID) ?? .defaultValue
    }

    func credentials(
        profileID: String,
        configuration: SuwayomiServerConfiguration
    ) async -> SuwayomiCredentials? {
        guard configuration.authMode != .none,
              let requestedIdentity =
                try? SuwayomiClient.credentialIdentity(
                    for: configuration
                ),
              let persistedConfiguration =
                await storedConfiguration(profileID: profileID),
              let persistedIdentity =
                try? SuwayomiClient.credentialIdentity(
                    for: persistedConfiguration
                ),
              persistedIdentity == requestedIdentity else {
            return nil
        }
        let resolvedSecret: String?
        if let credentialID = persistedConfiguration.credentialID {
            resolvedSecret = secret(
                account: versionedAccount(
                    profileID: profileID,
                    credentialID: credentialID
                )
            )
        } else {
            resolvedSecret = secret(account: profileID)
        }
        guard let resolvedSecret else {
            return nil
        }
        return SuwayomiCredentials(secret: resolvedSecret)
    }

    func save(
        profileID: String,
        configuration: SuwayomiServerConfiguration,
        secret: String?
    ) async throws -> SuwayomiServerConfiguration {
        let previousConfiguration = await storedConfiguration(
            profileID: profileID
        )
        let credentialIdentity = try SuwayomiClient.credentialIdentity(
            for: configuration
        )
        let previousCredentialIdentity = previousConfiguration.flatMap {
            try? SuwayomiClient.credentialIdentity(for: $0)
        }
        let retainsCredentialIdentity =
            previousCredentialIdentity == credentialIdentity

        let replacementSecret = secret.flatMap {
            $0.isEmpty ? nil : $0
        }
        let previousCredentialID =
            previousConfiguration?.credentialID
        let legacySecret =
            previousConfiguration != nil
                && previousCredentialID == nil
                ? self.secret(account: profileID)
                : nil
        let reusesCredentialSlot =
            configuration.authMode != .none
            && replacementSecret == nil
            && retainsCredentialIdentity
            && previousCredentialID != nil
        let nextCredentialID: String? =
            configuration.authMode == .none
                ? nil
                : reusesCredentialSlot
                    ? previousCredentialID
                    : UUID().uuidString
        var storedConfiguration = configuration
        storedConfiguration.credentialID = nextCredentialID

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(storedConfiguration)
        let url = try await configurationURL(profileID: profileID)
        try Task.checkCancellation()
        let nextAccount = nextCredentialID.map {
            versionedAccount(
                profileID: profileID,
                credentialID: $0
            )
        }
        let stagedSecret =
            replacementSecret
            ?? (
                retainsCredentialIdentity
                    && previousCredentialID == nil
                    ? legacySecret
                    : nil
            )
        if let stagedSecret, let nextAccount {
            try saveSecret(
                stagedSecret,
                account: nextAccount,
                profileID: profileID
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            if stagedSecret != nil, let nextAccount {
                try? deleteSecret(account: nextAccount)
            }
            throw error
        }

        try? deleteSecret(account: profileID)
        if let nextAccount {
            try? pruneVersionedSecrets(
                profileID: profileID,
                keeping: nextAccount
            )
        } else {
            try? deleteVersionedSecrets(profileID: profileID)
        }
        return storedConfiguration
    }

    func clear(profileID: String) async throws {
        let url = try await configurationURL(profileID: profileID)
        try Task.checkCancellation()
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile {
            // An already-absent configuration still needs Keychain cleanup.
        }
        var deletionError: Error?
        do {
            try deleteSecret(account: profileID)
        } catch {
            deletionError = error
        }
        do {
            try deleteVersionedSecrets(profileID: profileID)
        } catch {
            deletionError = deletionError ?? error
        }
        if let deletionError {
            throw deletionError
        }
    }

    private func configurationURL(profileID: String) async throws -> URL {
        let fileName = configurationFileName
        return try await MainActor.run {
            try ProfileRepository.shared
                .profileDirectory(for: profileID)
                .appendingPathComponent(fileName)
        }
    }

    private func storedConfiguration(
        profileID: String
    ) async -> SuwayomiServerConfiguration? {
        guard let url = try? await configurationURL(
                  profileID: profileID
              ),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(
            SuwayomiServerConfiguration.self,
            from: data
        )
    }

    private func saveSecret(
        _ secret: String,
        account: String,
        profileID: String
    ) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrGeneric as String: Data(profileID.utf8),
        ]
        let status = SecItemUpdate(
            lookup as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = lookup
            for (key, value) in attributes {
                item[key] = value
            }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw SuwayomiConnectorError.unexpectedResponse
            }
        } else if status != errSecSuccess {
            throw SuwayomiConnectorError.unexpectedResponse
        }
    }

    private func secret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(
            query as CFDictionary,
            &result
        ) == errSecSuccess,
        let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func versionedAccount(
        profileID: String,
        credentialID: String
    ) -> String {
        "v2." + SuwayomiIdentity.sha256(
            "\(profileID)\u{1f}\(credentialID)"
        )
    }

    private func deleteSecret(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess
                || status == errSecItemNotFound else {
            throw SuwayomiConnectorError.unexpectedResponse
        }
    }

    private func deleteVersionedSecrets(profileID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrGeneric as String: Data(profileID.utf8),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess
                || status == errSecItemNotFound else {
            throw SuwayomiConnectorError.unexpectedResponse
        }
    }

    private func pruneVersionedSecrets(
        profileID: String,
        keeping retainedAccount: String
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrGeneric as String: Data(profileID.utf8),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        guard status != errSecItemNotFound else { return }
        guard status == errSecSuccess else {
            throw SuwayomiConnectorError.unexpectedResponse
        }
        let items: [[String: Any]]
        if let values = result as? [[String: Any]] {
            items = values
        } else if let value = result as? [String: Any] {
            items = [value]
        } else {
            throw SuwayomiConnectorError.unexpectedResponse
        }
        for item in items {
            guard let account =
                    item[kSecAttrAccount as String] as? String,
                  account != retainedAccount else {
                continue
            }
            try deleteSecret(account: account)
        }
    }
}
