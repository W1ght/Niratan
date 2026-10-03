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
    case missingRefreshToken
    
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
        case .missingRefreshToken:
            return String(localized: "Google did not return a refresh token\nPlease try connecting again")
        }
    }
}

@MainActor
@Observable
class GoogleDriveAuth: NSObject {
    static let shared = GoogleDriveAuth()
    private static let logger = Logger(subsystem: "moe.shishamo.hoshi", category: "Sync")
    private let authorizationSession = GoogleDriveAuthorizationSession()
    private var cachedCredentials: GoogleDriveCredentials?
    private override init() {}
    
    var isAuthenticated: Bool {
        cachedCredentials != nil || TokenStorage.hasStoredCredentials
    }

    /// OAuth client bundled with this build for the Google Drive provider
    /// (`NIRATAN_GOOGLE_CLIENT_ID` build setting); empty in builds without one.
    static var bundledClientId: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "NiratanGoogleClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isValidGoogleClientId(value) ? value : nil
    }

    /// The Google Drive provider prefers the bundled client and otherwise uses the client ID
    /// entered in Settings; the ッツ/ttu provider always needs the user's own client.
    static func clientId(for provider: SyncProvider) -> String {
        let userClientId = (UserDefaults.standard.string(forKey: "googleClientId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .gdrive:
            return bundledClientId ?? userClientId
        case .ttu:
            return userClientId
        }
    }

    private static let connectedClientIdKey = "googleDriveConnectedClientId"

    /// Whether the stored authorization belongs to the client the provider uses. Compares the
    /// non-secret client id recorded at sign-in instead of reading the Keychain item.
    func isAuthenticated(for provider: SyncProvider) -> Bool {
        guard isAuthenticated else { return false }
        let connected = UserDefaults.standard.string(forKey: Self.connectedClientIdKey)
            ?? UserDefaults.standard.string(forKey: "googleClientId")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = Self.clientId(for: provider)
        return !configured.isEmpty && connected == configured
    }

    func authenticate(provider: SyncProvider) async throws {
        let clientId = Self.clientId(for: provider)
        guard Self.isValidGoogleClientId(clientId) else {
            throw GoogleDriveAuthError.invalidClientId
        }
        let previousClientId = UserDefaults.standard.string(forKey: Self.connectedClientIdKey)

        let manager = GoogleDriveSyncManager.shared
        await manager.stop()
        defer {
            manager.start()
        }

        _ = previousClientId
        try await authenticate(clientId: clientId)
        // Any new authorization may belong to another Google account.
        try manager.resetConnection()
        GoogleDriveHandler.clearCache()
    }
    
    func getAccessToken() throws -> String {
        try credentials().accessToken
    }
    
    func authenticate(clientId: String) async throws {
        let clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidGoogleClientId(clientId) else {
            throw GoogleDriveAuthError.invalidClientId
        }
        let scheme = clientId.components(separatedBy: ".").reversed().joined(separator: ".")
        let redirectUri = "\(scheme):/oauth2callback"
        
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        
        guard let authURL = components.url else {
            throw GoogleDriveAuthError.invalidAuthURL
        }
        
        let code = try await getAuthorizationCode(from: authURL, callbackScheme: scheme)
        let credentials = try await exchangeCode(code: code, clientId: clientId, redirectUri: redirectUri)
        storeCredentials(credentials)
        UserDefaults.standard.set(clientId, forKey: Self.connectedClientIdKey)
        Self.logger.info("Google Drive authentication completed; stored credentials available: \(self.isAuthenticated, privacy: .public)")
    }
    
    func refreshAccessToken() async throws -> String {
        let credentials = try credentials()
        
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "client_id": credentials.clientId,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken
        ]
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        Self.logTokenEndpointResponse(data: data, response: response, context: "refresh")
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            clearCredentials()
            throw GoogleDriveAuthError.tokenRefreshFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let updatedCredentials = GoogleDriveCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: credentials.refreshToken,
            clientId: credentials.clientId
        )
        storeCredentials(updatedCredentials)
        
        return tokenResponse.accessToken
    }

    func signOut() {
        clearCredentials()
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
    
    private func exchangeCode(code: String, clientId: String, redirectUri: String) async throws -> GoogleDriveCredentials {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "code": code,
            "client_id": clientId,
            "redirect_uri": redirectUri,
            "grant_type": "authorization_code"
        ]
        
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
        guard let refresh = tokenResponse.refreshToken else {
            clearCredentials()
            throw GoogleDriveAuthError.missingRefreshToken
        }

        return GoogleDriveCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: refresh,
            clientId: clientId
        )
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

    private func storeCredentials(_ credentials: GoogleDriveCredentials) {
        cachedCredentials = credentials
        TokenStorage.saveCredentials(credentials)
    }

    private func clearCredentials() {
        cachedCredentials = nil
        TokenStorage.clear()
        UserDefaults.standard.removeObject(forKey: Self.connectedClientIdKey)
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
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}
