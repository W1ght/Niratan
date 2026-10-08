// test-sources: Features/Sync/TokenStorage.swift Features/Sync/GoogleDriveAuthorizationPolicy.swift Features/Sync/GoogleDriveAuth.swift
import AppKit
import AuthenticationServices
import Foundation
import Security

// Compile the real credential codec, Keychain save flow and Auth orchestration. Every
// Keychain operation is intercepted in memory, and every URLSession request is intercepted
// by URLProtocol. A disposable app bundle supplies synthetic desktop-client metadata.
nonisolated enum SyncProvider: String { case gdrive, ttu }
nonisolated enum DevelopmentDataIsolation {
    static func keychainName(_ name: String) -> String { "niratan-credential-fixture-" + name }
}

nonisolated private enum FixtureKeychain {
    nonisolated(unsafe) static var items: [String: Data] = [:]
    nonisolated(unsafe) static var nextUpdateStatus: OSStatus = errSecSuccess
    nonisolated(unsafe) static var updateCalls = 0
    nonisolated(unsafe) static var addCalls = 0
    nonisolated(unsafe) static var deleteCalls = 0

    static func account(_ query: CFDictionary) -> String? {
        let account = (query as NSDictionary)[kSecAttrAccount as String] as? String
        return account?.hasPrefix("niratan-credential-fixture-") == true ? account : nil
    }
}

// Local Swift declarations intentionally shadow the imported Security functions. None of
// these tests can read, update or delete a real user's Keychain item.
nonisolated func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    FixtureKeychain.updateCalls += 1
    guard let account = FixtureKeychain.account(query) else { return errSecParam }
    let forced = FixtureKeychain.nextUpdateStatus
    FixtureKeychain.nextUpdateStatus = errSecSuccess
    guard forced == errSecSuccess else { return forced }
    guard FixtureKeychain.items[account] != nil else { return errSecItemNotFound }
    guard let data = (attributes as NSDictionary)[kSecValueData as String] as? Data else { return errSecParam }
    FixtureKeychain.items[account] = data
    return errSecSuccess
}

nonisolated func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    FixtureKeychain.addCalls += 1
    guard let account = FixtureKeychain.account(attributes),
          let data = (attributes as NSDictionary)[kSecValueData as String] as? Data else { return errSecParam }
    guard FixtureKeychain.items[account] == nil else { return errSecDuplicateItem }
    FixtureKeychain.items[account] = data
    return errSecSuccess
}

nonisolated func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    guard let account = FixtureKeychain.account(query), let data = FixtureKeychain.items[account] else { return errSecItemNotFound }
    if (query as NSDictionary)[kSecReturnData as String] as? Bool == true { result?.pointee = data as NSData }
    else { result?.pointee = NSDictionary() }
    return errSecSuccess
}

nonisolated func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    FixtureKeychain.deleteCalls += 1
    guard let account = FixtureKeychain.account(query) else { return errSecParam }
    return FixtureKeychain.items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
}

@MainActor enum GoogleDriveHandler {
    static var clearCalls = 0
    static func clearCache() { clearCalls += 1 }
}

@MainActor final class GoogleDriveClient {
    static let shared = GoogleDriveClient()
    var connectionId = 0
    func checkConnection(_ connection: Int) throws {
        if connection != connectionId { throw CancellationError() }
    }
}

@MainActor final class GoogleDriveSyncManager {
    static let shared = GoogleDriveSyncManager()
    var stopCalls = 0
    var startCalls = 0
    var resetCalls = 0
    func stop() async { stopCalls += 1; GoogleDriveClient.shared.connectionId += 1 }
    func start() { startCalls += 1 }
    func resetConnection() throws { resetCalls += 1 }
}

@MainActor enum GoogleDrivePresentationAnchor {
    static func current() -> ASPresentationAnchor { ASPresentationAnchor() }
}

nonisolated enum GoogleDriveLoopbackAuthorizationError: Error { case alreadyInProgress }

@MainActor final class GoogleDriveLoopbackAuthorization {
    struct AuthorizationCode {
        let code: String
        let redirectURI: String
        let codeVerifier: String
    }
    enum Behavior { case cancel, code }
    static var behavior = Behavior.code
    static var authorizeCalls = 0
    func authorize(clientID: String, scope: String) async throws -> AuthorizationCode {
        Self.authorizeCalls += 1
        if Self.behavior == .cancel { throw CancellationError() }
        return AuthorizationCode(code: "synthetic-code", redirectURI: "http://127.0.0.1:54321/", codeVerifier: "synthetic-pkce-verifier")
    }
    func cancel() {}
}

nonisolated private struct FixtureFailure: Error { let message: String }

nonisolated private final class FixtureTokenEndpoint: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [[String: String]] = []
    nonisolated(unsafe) private static var reply: [String: String] = [:]
    nonisolated(unsafe) private static var replyStatus = 200
    nonisolated(unsafe) private static var hold = false
    nonisolated(unsafe) private static var pending: FixtureTokenEndpoint?

    static func configure(_ response: [String: String], status: Int = 200, holdResponse: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        reply = response; replyStatus = status; hold = holdResponse; captured = []
    }
    static var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending != nil
    }
    static var lastParameters: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return captured.last ?? [:]
    }
    static func releasePending() {
        lock.lock()
        let request = pending
        pending = nil
        lock.unlock()
        request?.sendResponse()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.absoluteString == "https://oauth2.googleapis.com/token", request.httpMethod == "POST" else {
            client?.urlProtocol(self, didFailWithError: FixtureFailure(message: "unexpected network request was blocked"))
            return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
        let parameters = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        Self.lock.lock()
        Self.captured.append(parameters)
        let shouldHold = Self.hold
        if shouldHold { Self.pending = self }
        Self.lock.unlock()
        if !shouldHold { sendResponse() }
    }
    private func sendResponse() {
        Self.lock.lock()
        let responseBody = Self.reply
        let status = Self.replyStatus
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(responseBody))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor private enum GoogleDriveCredentialsTests {
    static let clientID = "123-fixture.apps.googleusercontent.com"
    static let bundledSecret = "SYNTHETIC-BUNDLED-SECRET"
    static let storedSecret = "SYNTHETIC-STORED-SECRET"
    private static var checks = 0

    static func main() async {
        do {
            if try runInsideDisposableBundle() { return }
            try await run()
            print("PASS: Google Drive credential codec and actual Auth orchestration (\(checks) checks; in-memory Keychain and intercepted network only)")
        } catch {
            print("FAIL: Google Drive credentials after \(checks) checks: \(error)")
            exit(1)
        }
    }

    private static func runInsideDisposableBundle() throws -> Bool {
        if Bundle.main.bundleIdentifier?.hasPrefix("moe.shishamo.credential-fixture.") == true { return false }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("niratan-credential-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let contents = fixture.appendingPathComponent("CredentialFixture.app/Contents")
        let binary = contents.appendingPathComponent("MacOS/CredentialFixture")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: binary)
        let info: [String: String] = [
            "CFBundleIdentifier": "moe.shishamo.credential-fixture.\(UUID().uuidString)",
            "CFBundleExecutable": "CredentialFixture", "CFBundlePackageType": "APPL",
            "HoshiReaderGoogleClientID": clientID, "HoshiReaderGoogleClientSecret": bundledSecret,
            "HoshiReaderGoogleClientFlow": "loopback"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let home = fixture.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = binary
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureFailure(message: "isolated credential fixture failed") }
        return true
    }

    private static func run() async throws {
        require(URLProtocol.registerClass(FixtureTokenEndpoint.self), "all token requests are intercepted")
        defer { URLProtocol.unregisterClass(FixtureTokenEndpoint.self) }
        let oldJSON = Data(#"{"accessToken":"SYNTHETIC-OLD-ACCESS","refreshToken":"SYNTHETIC-OLD-REFRESH","clientId":"123-fixture.apps.googleusercontent.com"}"#.utf8)
        let legacy = try JSONDecoder().decode(GoogleDriveCredentials.self, from: oldJSON)
        require(legacy.clientSecret == nil, "older credentials decode without a client secret")
        require(GoogleDriveCredentials(accessToken: "a", refreshToken: "r", clientId: "c").clientSecret == nil, "existing initializers remain compatible")
        FixtureKeychain.items[DevelopmentDataIsolation.keychainName("googleDriveCredentials")] = oldJSON
        require(TokenStorage.getCredentials() == legacy, "the actual stored-credential reader accepts legacy JSON")
        let old = GoogleDriveCredentials(accessToken: legacy.accessToken, refreshToken: legacy.refreshToken, clientId: clientID, clientSecret: storedSecret)
        let encoded = try JSONEncoder().encode(old)
        try require(try JSONDecoder().decode(GoogleDriveCredentials.self, from: encoded) == old, "credentials with a client secret round trip")
        require(TokenStorage.saveCredentials(old) && FixtureKeychain.updateCalls == 1 && FixtureKeychain.addCalls == 0, "existing credentials are updated through the intercepted Keychain")
        UserDefaults.standard.set(clientID, forKey: "googleDriveConnectedClientId")
        UserDefaults.standard.set(GoogleDriveAuthorizationPolicy.fileScope, forKey: "googleDriveGrantedScope")
        let auth = GoogleDriveAuth.shared
        let manager = GoogleDriveSyncManager.shared
        try require(try auth.getAccessToken() == old.accessToken && auth.isAuthenticated(for: .gdrive), "the previous connection is cached and valid")

        GoogleDriveLoopbackAuthorization.behavior = .cancel
        do { try await auth.authenticate(provider: .gdrive); throw FixtureFailure(message: "cancelled reconnect succeeded") }
        catch is CancellationError { checks += 1 }
        try require(TokenStorage.getCredentials() == old && (try auth.getAccessToken()) == old.accessToken, "browser cancellation preserves saved and cached credentials")
        require(manager.resetCalls == 0 && manager.stopCalls == 1 && manager.startCalls == 1, "cancelled reconnect resumes the previous library without resetting it")

        GoogleDriveLoopbackAuthorization.behavior = .code
        FixtureTokenEndpoint.configure(["access_token": "SYNTHETIC-NEW-ACCESS", "refresh_token": "SYNTHETIC-NEW-REFRESH", "scope": GoogleDriveAuthorizationPolicy.fileScope])
        FixtureKeychain.nextUpdateStatus = errSecAuthFailed
        do { try await auth.authenticate(provider: .gdrive); throw FixtureFailure(message: "failed credential save succeeded") }
        catch GoogleDriveAuthError.credentialsSaveFailed { checks += 1 }
        try require(TokenStorage.getCredentials() == old && (try auth.getAccessToken()) == old.accessToken && FixtureKeychain.deleteCalls == 0, "failed Keychain save preserves the previous stored and cached connection")
        require(manager.resetCalls == 0, "failed authorization save cannot reset the library")
        let exchange = FixtureTokenEndpoint.lastParameters
        require(exchange["code_verifier"] == "synthetic-pkce-verifier" && exchange["redirect_uri"] == "http://127.0.0.1:54321/", "actual exchange sends the loopback verifier and exact redirect")
        require(exchange["client_secret"] == bundledSecret, "actual exchange sends the configured synthetic desktop secret")

        FixtureTokenEndpoint.configure(["access_token": "SYNTHETIC-REFRESHED-ACCESS"])
        let refreshedAccess = try await auth.refreshAccessToken()
        let refreshed = TokenStorage.getCredentials()!
        require(FixtureTokenEndpoint.lastParameters["client_secret"] == storedSecret, "actual refresh prefers the credential's saved desktop secret")
        require(refreshedAccess == "SYNTHETIC-REFRESHED-ACCESS" && refreshed.clientSecret == storedSecret && refreshed.refreshToken == old.refreshToken, "refresh preserves its original secret and refresh token")

        FixtureTokenEndpoint.configure(["access_token": "SYNTHETIC-UNSAVED-REFRESH"])
        FixtureKeychain.nextUpdateStatus = errSecInteractionNotAllowed
        do { _ = try await auth.refreshAccessToken(); throw FixtureFailure(message: "failed refresh save succeeded") }
        catch GoogleDriveAuthError.credentialsSaveFailed { checks += 1 }
        try require(TokenStorage.getCredentials() == refreshed && (try auth.getAccessToken()) == refreshed.accessToken, "failed refresh save preserves the last valid credentials")

        FixtureTokenEndpoint.configure(["error": "invalid_client"], status: 400)
        do { _ = try await auth.refreshAccessToken(); throw FixtureFailure(message: "invalid client refresh succeeded") }
        catch GoogleDriveAuthError.tokenRefreshUnavailable { checks += 1 }
        require(TokenStorage.getCredentials() == refreshed && auth.isAuthenticated, "a client configuration failure retains the previous authorization")

        // Simulate Cancel after Google returned the code, while token exchange is pending.
        // The UI's actual cancellation API must invalidate the entire attempt, not just the
        // already completed loopback browser session.
        FixtureTokenEndpoint.configure(["access_token": "SYNTHETIC-CANCELLED-ACCESS", "refresh_token": "SYNTHETIC-CANCELLED-REFRESH"], holdResponse: true)
        let reconnect = Task { try await auth.authenticate(provider: .gdrive) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !FixtureTokenEndpoint.hasPending {
            guard ContinuousClock.now < deadline else { throw FixtureFailure(message: "intercepted token exchange did not start") }
            try await Task.sleep(for: .milliseconds(10))
        }
        auth.cancelAuthentication()
        FixtureTokenEndpoint.releasePending()
        do { try await reconnect.value; throw FixtureFailure(message: "Cancel during token exchange still committed the new connection") }
        catch is CancellationError { checks += 1 }
        try require(TokenStorage.getCredentials() == refreshed && (try auth.getAccessToken()) == refreshed.accessToken && manager.resetCalls == 0, "Cancel during exchange preserves the prior credential and library")

        auth.signOut()
        require(TokenStorage.saveCredentials(legacy), "legacy credential can be seeded after clearing only fixture credentials")
        FixtureTokenEndpoint.configure(["access_token": "SYNTHETIC-LEGACY-REFRESH"])
        _ = try await auth.refreshAccessToken()
        require(FixtureTokenEndpoint.lastParameters["client_secret"] == bundledSecret, "a legacy credential without a secret uses its matching bundled desktop secret")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else { fatalError("FAIL: \(message)") }
        checks += 1
    }
}
