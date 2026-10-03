import Foundation
import Security

nonisolated enum JimakuCredentialStoreError: Error, Equatable, Sendable {
    case invalidAPIKey
    case keychain(OSStatus)
}

actor JimakuCredentialStore {
    static let shared = JimakuCredentialStore()

    static let openSubtitles = JimakuCredentialStore(service: "moe.shishamo.hoshi.opensubtitles")

    private let service: String

    init(service: String = "moe.shishamo.hoshi.jimaku") {
        self.service = DevelopmentDataIsolation.keychainName(service)
    }
    private let account = "api-key"

    func hasAPIKey() throws -> Bool {
        try apiKey() != nil
    }

    func apiKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw JimakuCredentialStoreError.keychain(status)
        }
        return value
    }

    func save(apiKey: String) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw JimakuCredentialStoreError.invalidAPIKey
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalized.utf8),
        ]
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = Data(normalized.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw JimakuCredentialStoreError.keychain(addStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw JimakuCredentialStoreError.keychain(status)
        }
    }

    func removeAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw JimakuCredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

extension Notification.Name {
    static let jimakuCredentialDidChange = Notification.Name(
        "moe.shishamo.hoshi.jimakuCredentialDidChange"
    )
}
