//
//  GoogleDriveAuth.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import AuthenticationServices
import OSLog

enum GoogleDriveAuthError: LocalizedError {
    case invalidClientId
    case invalidAuthURL
    case noCallbackURL
    case missingAuthorizationCode
    case tokenExchangeFailed(statusCode: Int)
    case notAuthenticated
    case tokenRefreshFailed
    case tokenRefreshUnavailable
    case missingRefreshToken
    case missingLibraryAccess
    case credentialsSaveFailed
    case sharedClientNotConfigured
    
    var errorDescription: String? {
        switch self {
        case .invalidClientId:
            return String(localized: "Invalid Client ID format")
        case .invalidAuthURL:
            return String(localized: "Failed to construct authentication URL")
        case .noCallbackURL:
            return String(localized: "No callback URL received")
        case .missingAuthorizationCode:
            return String(localized: "Authorization code missing from callback")
        case .tokenExchangeFailed(let statusCode):
            return String(localized: "Token exchange failed: \(statusCode)")
        case .notAuthenticated:
            return String(localized: "Not authenticated\nPlease sign in")
        case .tokenRefreshFailed:
            return String(localized: "Failed to refresh token\nPlease sign in again")
        case .tokenRefreshUnavailable:
            return String(localized: "Google Drive could not refresh authorization. Your saved connection was kept. Please try again.")
        case .missingRefreshToken:
            return String(localized: "Google did not return a refresh token\nPlease try connecting again")
        case .missingLibraryAccess:
            return String(localized: "Google Drive file access was not granted. Reconnect and allow access to sync.")
        case .credentialsSaveFailed:
            return String(localized: "Could not save Google Drive authorization. Please try connecting again.")
        case .sharedClientNotConfigured:
            return String(localized: "This build is missing Hoshi Reader's Google sign-in configuration. Please use a build with shared-library sign-in configured.")
        }
    }
}

@MainActor
@Observable
class GoogleDriveAuth: NSObject {
    static let shared = GoogleDriveAuth()
    private static let logger = Logger(subsystem: "moe.shishamo.hoshi", category: "Sync")
    private let authorizationSession = GoogleDriveAuthorizationSession()
    private let loopbackAuthorization = GoogleDriveLoopbackAuthorization()
    private var authenticationAttempt: UUID?
    private var cachedCredentials: GoogleDriveCredentials?
    private override init() {}
    
    var isAuthenticated: Bool {
        cachedCredentials != nil || TokenStorage.hasStoredCredentials
    }

    /// A Mac client supplied by Hoshi Reader's Google Cloud project owner. It must
    /// belong to the same project as the Hoshi Reader build on the other device.
    static var bundledSharedClientId: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "HoshiReaderGoogleClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isValidGoogleClientId(value) ? value : nil
    }

    private static func bundledClientSecret(for clientID: String) -> String? {
        guard clientID == bundledSharedClientId else { return nil }
        let value = (Bundle.main.object(forInfoDictionaryKey: "HoshiReaderGoogleClientSecret") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }

    /// Shared-library credentials have their own explicit configuration. Never infer
    /// compatibility from the previous Niratan/TTU client or from a Google account.
    static func clientId(for provider: SyncProvider) -> String {
        let userClientId = (UserDefaults.standard.string(forKey: "googleClientId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .gdrive:
            return bundledSharedClientId ?? ""
        case .ttu:
            return userClientId
        }
    }

    static var hasSharedLibraryClient: Bool {
        isValidGoogleClientId(clientId(for: .gdrive))
    }

    private static let connectedClientIdKey = "googleDriveConnectedClientId"
    /// Non-secret authorization metadata. Missing on older per-file connections.
    private static let grantedScopeKey = "googleDriveGrantedScope"

    var requiresLibraryAuthorization: Bool {
        isAuthenticated && Self.hasSharedLibraryClient && !isAuthenticated(for: .gdrive)
    }

    /// Whether the stored authorization belongs to the client the provider uses. Compares the
    /// non-secret client id recorded at sign-in instead of reading the Keychain item.
    func isAuthenticated(for provider: SyncProvider) -> Bool {
        guard isAuthenticated else { return false }
        let connected = UserDefaults.standard.string(forKey: Self.connectedClientIdKey)
            ?? (provider == .ttu ? UserDefaults.standard.string(forKey: "googleClientId")?.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        let configured = Self.clientId(for: provider)
        guard Self.isValidGoogleClientId(configured), connected == configured else { return false }
        return provider != .gdrive || GoogleDriveAuthorizationPolicy.permitsStoredScope(
            UserDefaults.standard.string(forKey: Self.grantedScopeKey)
        )
    }

    func authenticate(provider: SyncProvider) async throws {
        if provider == .gdrive && !Self.hasSharedLibraryClient {
            throw GoogleDriveAuthError.sharedClientNotConfigured
        }
        let clientId = Self.clientId(for: provider)
        guard Self.isValidGoogleClientId(clientId) else {
            throw GoogleDriveAuthError.invalidClientId
        }
        let manager = GoogleDriveSyncManager.shared
        await manager.stop()
        defer {
            manager.start()
        }

        try await authenticate(clientId: clientId, provider: provider)
        // Any new authorization may belong to another Google account.
        try manager.resetConnection()
        GoogleDriveHandler.clearCache()
    }
    
    func getAccessToken() throws -> String {
        try credentials().accessToken
    }
    
    func authenticate(clientId: String, provider: SyncProvider = .ttu) async throws {
        let clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidGoogleClientId(clientId) else {
            throw GoogleDriveAuthError.invalidClientId
        }
        guard authenticationAttempt == nil else {
            throw GoogleDriveLoopbackAuthorizationError.alreadyInProgress
        }
        let attempt = UUID()
        authenticationAttempt = attempt
        defer {
            if authenticationAttempt == attempt { authenticationAttempt = nil }
        }
        let requestedScope = GoogleDriveAuthorizationPolicy.requestedScope
        let connection = GoogleDriveClient.shared.connectionId
        let code: String
        let redirectUri: String
        let codeVerifier: String?
        if provider == .gdrive {
            let result = try await loopbackAuthorization.authorize(clientID: clientId, scope: requestedScope)
            code = result.code
            redirectUri = result.redirectURI
            codeVerifier = result.codeVerifier
        } else {
            let scheme = clientId.components(separatedBy: ".").reversed().joined(separator: ".")
            redirectUri = "\(scheme):/oauth2callback"
            codeVerifier = nil
        
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientId),
                URLQueryItem(name: "redirect_uri", value: redirectUri),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: requestedScope),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]

            guard let authURL = components.url else {
                throw GoogleDriveAuthError.invalidAuthURL
            }
            code = try await getAuthorizationCode(from: authURL, callbackScheme: scheme)
        }
        try GoogleDriveClient.shared.checkConnection(connection)
        try checkAuthenticationAttempt(attempt)
        let (credentials, grantedScope) = try await exchangeCode(
            code: code, clientId: clientId, redirectUri: redirectUri, requestedScope: requestedScope,
            codeVerifier: codeVerifier, clientSecret: Self.bundledClientSecret(for: clientId)
        )
        try GoogleDriveClient.shared.checkConnection(connection)
        try checkAuthenticationAttempt(attempt)
        try storeCredentials(credentials)
        UserDefaults.standard.set(clientId, forKey: Self.connectedClientIdKey)
        UserDefaults.standard.set(grantedScope, forKey: Self.grantedScopeKey)
        Self.logger.info("Google Drive authentication completed; stored credentials available: \(self.isAuthenticated, privacy: .public)")
    }
    
    func refreshAccessToken() async throws -> String {
        let connection = GoogleDriveClient.shared.connectionId
        let credentials = try credentials()
        
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var params = [
            "client_id": credentials.clientId,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken
        ]
        if let secret = credentials.clientSecret ?? Self.bundledClientSecret(for: credentials.clientId) {
            params["client_secret"] = secret
        }
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        try GoogleDriveClient.shared.checkConnection(connection)
        try Task.checkCancellation()
        Self.logTokenEndpointResponse(data: data, response: response, context: "refresh")
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if GoogleDriveAuthorizationPolicy.invalidatesStoredCredentials(
                statusCode: (response as? HTTPURLResponse)?.statusCode, responseBody: data
            ) {
                clearCredentials()
                throw GoogleDriveAuthError.tokenRefreshFailed
            }
            throw GoogleDriveAuthError.tokenRefreshUnavailable
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        // Refresh responses may omit scope, so keep the known grant in that case.
        if let scope = tokenResponse.scope,
           !GoogleDriveAuthorizationPolicy.includes(scope, required: GoogleDriveAuthorizationPolicy.fileScope) {
            UserDefaults.standard.set(scope, forKey: Self.grantedScopeKey)
            throw GoogleDriveAuthError.missingLibraryAccess
        }
        let updatedCredentials = GoogleDriveCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: credentials.refreshToken,
            clientId: credentials.clientId,
            clientSecret: credentials.clientSecret
        )
        try storeCredentials(updatedCredentials)
        if let scope = tokenResponse.scope {
            UserDefaults.standard.set(scope, forKey: Self.grantedScopeKey)
        }
        
        return tokenResponse.accessToken
    }

    func signOut() {
        cancelAuthentication()
        clearCredentials()
    }

    func cancelAuthentication() {
        authenticationAttempt = nil
        loopbackAuthorization.cancel()
        authorizationSession.cancel()
    }

    private func checkAuthenticationAttempt(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard authenticationAttempt == attempt else { throw CancellationError() }
    }
    
    private func getAuthorizationCode(from url: URL, callbackScheme: String) async throws -> String {
        let callbackURL = try await authorizationSession.callbackURL(from: url, callbackScheme: callbackScheme)
        
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true) else {
            throw GoogleDriveAuthError.missingAuthorizationCode
        }
        let queryNames = components.queryItems?.map(\.name).joined(separator: ",") ?? ""
        Self.logger.info("Google auth callback received with query keys: \(queryNames, privacy: .public)")

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GoogleDriveAuthError.missingAuthorizationCode
        }
        
        return code
    }
    
    private func exchangeCode(
        code: String, clientId: String, redirectUri: String, requestedScope: String,
        codeVerifier: String?, clientSecret: String?
    ) async throws -> (GoogleDriveCredentials, String) {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var params = [
            "code": code,
            "client_id": clientId,
            "redirect_uri": redirectUri,
            "grant_type": "authorization_code"
        ]
        if let codeVerifier { params["code_verifier"] = codeVerifier }
        if let clientSecret { params["client_secret"] = clientSecret }
        
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        Self.logTokenEndpointResponse(data: data, response: response, context: "exchange")
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleDriveAuthError.tokenExchangeFailed(statusCode: statusCode)
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let grantedScope = GoogleDriveAuthorizationPolicy.grantedScope(
            response: tokenResponse.scope, requested: requestedScope
        ) else {
            throw GoogleDriveAuthError.missingLibraryAccess
        }
        guard let refresh = tokenResponse.refreshToken else {
            throw GoogleDriveAuthError.missingRefreshToken
        }

        let credentials = GoogleDriveCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: refresh,
            clientId: clientId,
            clientSecret: clientSecret
        )
        return (credentials, grantedScope)
    }

    private func credentials() throws -> GoogleDriveCredentials {
        if let cachedCredentials {
            return cachedCredentials
        }

        guard let storedCredentials = TokenStorage.getCredentials() else {
            throw GoogleDriveAuthError.notAuthenticated
        }

        cachedCredentials = storedCredentials
        return storedCredentials
    }

    private func storeCredentials(_ credentials: GoogleDriveCredentials) throws {
        guard TokenStorage.saveCredentials(credentials) else {
            throw GoogleDriveAuthError.credentialsSaveFailed
        }
        cachedCredentials = credentials
    }

    private func clearCredentials() {
        cachedCredentials = nil
        TokenStorage.clear()
        UserDefaults.standard.removeObject(forKey: Self.connectedClientIdKey)
        UserDefaults.standard.removeObject(forKey: Self.grantedScopeKey)
    }
    
    private static func isValidGoogleClientId(_ clientId: String) -> Bool {
        clientId.range(of: #"^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil
    }

    private static func logTokenEndpointResponse(data: Data, response: URLResponse, context: String) {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let fields = redactedJSONFieldSummary(from: data)
        logger.info("Google token \(context, privacy: .public) response status \(statusCode, privacy: .public), fields: \(fields, privacy: .public)")
    }

    private static func redactedJSONFieldSummary(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "non-json"
        }
        let keys = json.keys.sorted().joined(separator: ",")
        let hasAccessToken = json["access_token"] != nil
        let hasRefreshToken = json["refresh_token"] != nil
        let error = json["error"] as? String
        if let error {
            return "keys=[\(keys)], error=\(error)"
        }
        return "keys=[\(keys)], has_access_token=\(hasAccessToken), has_refresh_token=\(hasRefreshToken)"
    }
}

private nonisolated final class GoogleDriveAuthorizationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?

    func cancel() {
        activeSession?.cancel()
    }

    func callbackURL(from url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                self?.activeSession = nil
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: GoogleDriveAuthError.noCallbackURL)
                }
            }

            session.presentationContextProvider = self
            activeSession = session
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                GoogleDrivePresentationAnchor.current()
            }
        }

        var anchor: ASPresentationAnchor?
        DispatchQueue.main.sync {
            anchor = MainActor.assumeIsolated {
                GoogleDrivePresentationAnchor.current()
            }
        }
        return anchor ?? ASPresentationAnchor()
    }
}

private struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let scope: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case scope
    }
}
