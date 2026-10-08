// test-sources: Features/Sync/GoogleDriveAuthorizationPolicy.swift
import Foundation

@main
private enum GoogleDriveAuthorizationScopeTests {
    static func main() {
        let policy = GoogleDriveAuthorizationPolicy.self
        let shared = policy.requestedScope
        let ttu = policy.fileScope

        require(shared == "https://www.googleapis.com/auth/drive.file", "Shared libraries retain Hoshi's per-file scope and require a compatible OAuth project")
        require(ttu == "https://www.googleapis.com/auth/drive.file", "TTU must retain its existing per-file authorization")
        require(policy.permitsStoredScope(nil), "Legacy compatible per-file connections remain usable without a recorded scope")
        require(policy.includes(ttu, required: shared), "Both providers request the same least-privilege scope")
        require(!policy.includes("https://www.googleapis.com/auth/drive.readonly", required: shared), "Read-only access cannot authorize two-way sync")
        require(policy.includes("openid \(shared)\nemail", required: shared), "Granted scopes are whitespace-separated tokens")
        require(!policy.includes("\(shared).metadata", required: shared), "A scope prefix must not count as a complete Drive grant")
        require(policy.includes(policy.libraryScope, required: ttu), "An existing broader grant includes per-file operations without requesting broader access")

        require(policy.grantedScope(response: "https://www.googleapis.com/auth/drive.readonly", requested: shared) == nil, "A read-only authorization response must be rejected")
        require(policy.grantedScope(response: "", requested: shared) == nil, "An empty authorization response must not be mistaken for omitted scope")
        require(policy.grantedScope(response: nil, requested: shared) == shared, "OAuth can omit scope when it equals the requested scope")
        require(policy.grantedScope(response: "\(shared) openid", requested: shared) != nil, "Additional scopes do not invalidate a sufficient grant")
        require(policy.grantedScope(response: policy.libraryScope, requested: ttu) == policy.libraryScope, "A stronger existing grant remains usable without requesting full Drive access")

        let revoked = Data(#"{"error":"invalid_grant","error_description":"Token has been revoked."}"#.utf8)
        let invalidClient = Data(#"{"error":"invalid_client"}"#.utf8)
        let malformed = Data("<html>Service unavailable</html>".utf8)
        require(!policy.invalidatesStoredCredentials(statusCode: 429, responseBody: revoked), "Rate limiting must preserve stored credentials even when the body resembles a token rejection")
        require(!policy.invalidatesStoredCredentials(statusCode: 503, responseBody: revoked), "A temporary server failure must preserve the refresh token")
        require(policy.invalidatesStoredCredentials(statusCode: 400, responseBody: revoked), "An explicit OAuth invalid_grant must invalidate revoked credentials")
        require(!policy.invalidatesStoredCredentials(statusCode: 400, responseBody: invalidClient), "A client configuration error must not destroy the previous authorization")
        require(!policy.invalidatesStoredCredentials(statusCode: 400, responseBody: malformed), "A malformed non-OAuth response must preserve stored credentials")
        require(!policy.invalidatesStoredCredentials(statusCode: 400, responseBody: Data(#"{"error":{"message":"invalid_grant"}}"#.utf8)), "An unrelated nested API error must not invalidate OAuth credentials")
        require(!policy.invalidatesStoredCredentials(statusCode: 200, responseBody: revoked), "Successful responses must never invalidate stored credentials")
        require(!policy.invalidatesStoredCredentials(statusCode: nil, responseBody: revoked), "A non-HTTP response must preserve stored credentials")

        let auth = try! String(contentsOfFile: "Features/Sync/GoogleDriveAuth.swift", encoding: .utf8)
        let storage = try! String(contentsOfFile: "Features/Sync/TokenStorage.swift", encoding: .utf8)
        require(auth.contains("HoshiReaderGoogleClientID") && !auth.contains("hoshiReaderGoogleClientId") && !auth.contains("NiratanGoogleClientID"), "Shared libraries must use their bundled client configuration without asking users for an OAuth client")
        require(auth.contains("return bundledSharedClientId ?? \"\""), "Shared libraries must never fall back to the TTU client")
        require(auth.contains("if provider == .gdrive") && auth.contains("loopbackAuthorization.authorize") && auth.contains("params[\"code_verifier\"] = codeVerifier"), "Shared-library sign-in must use the desktop loopback and PKCE flow")
        require(auth.contains("connected == configured") && auth.contains("Self.hasSharedLibraryClient"), "Shared sync must wait for a configured compatible-client connection")
        require(auth.contains("let requestedScope = GoogleDriveAuthorizationPolicy.requestedScope"), "Authorization must request the least-privilege shared policy")
        require(storage.contains("SecItemUpdate") && !storage.contains("SecItemDelete(query as CFDictionary)\n        let status = SecItemAdd"), "Reconnection must preserve the old Keychain authorization when saving fails")
        for (account, name) in [("legacyAccessTokenAccount", "accessToken"), ("legacyRefreshTokenAccount", "refreshToken"), ("legacyClientIdAccount", "clientId")] {
            require(storage.contains("private static let \(account) = DevelopmentDataIsolation.keychainName(\"\(name)\")"), "Legacy credential accounts must follow the Debug data isolation scope")
            require(storage.contains("getString(for: \(account))") && !storage.contains("getString(for: \"\(name)\")"), "Legacy migration must read the scoped account rather than the installed app's credentials")
        }
        require(storage.contains("legacyCredentialAccounts = [legacyAccessTokenAccount, legacyRefreshTokenAccount, legacyClientIdAccount]") && storage.contains("legacyCredentialAccounts.allSatisfy(accountExists)") && storage.contains("legacyCredentialAccounts.forEach(deleteAccount)"), "Legacy presence checks and deletion must use the same scoped names as migration reads")
        print("PASS: Google Drive shared-library authorization scope")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
