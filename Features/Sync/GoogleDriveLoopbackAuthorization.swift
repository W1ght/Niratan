//
//  GoogleDriveLoopbackAuthorization.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import CryptoKit
import Foundation
import Network
import Security

nonisolated struct GoogleDriveLoopbackAuthorizationCode: Sendable {
    let code: String
    let redirectURI: String
    let codeVerifier: String
}

nonisolated enum GoogleDriveLoopbackAuthorizationError: LocalizedError {
    case alreadyInProgress
    case listenerUnavailable
    case browserUnavailable
    case timedOut
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            String(localized: "Google Drive sign-in is already in progress.")
        case .listenerUnavailable:
            String(localized: "Could not start Google Drive sign-in. Please try again.")
        case .browserUnavailable:
            String(localized: "Could not open the browser for Google Drive sign-in.")
        case .timedOut:
            String(localized: "Google Drive sign-in timed out. Please try again.")
        case .authorizationDenied:
            String(localized: "Google Drive sign-in was not completed. Please try again.")
        }
    }
}

/// Public desktop clients use a random loopback port and PKCE in the system browser.
/// This object never exchanges or persists tokens, and never logs callback values.
@MainActor
final class GoogleDriveLoopbackAuthorization {
    typealias AuthorizationCode = GoogleDriveLoopbackAuthorizationCode
    typealias BrowserOpener = @MainActor (URL) -> Bool

    private var session: Session?

    var isAuthorizing: Bool { session != nil }

    func authorize(
        clientID: String,
        scope: String,
        timeout: Duration = .seconds(180),
        browserOpener: @escaping BrowserOpener = { NSWorkspace.shared.open($0) }
    ) async throws -> AuthorizationCode {
        try Task.checkCancellation()
        guard session == nil else { throw GoogleDriveLoopbackAuthorizationError.alreadyInProgress }
        let sessionID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let newSession = try Session(
                        clientID: clientID, scope: scope, timeout: timeout,
                        browserOpener: browserOpener, continuation: continuation,
                        onFinish: { [weak self] in
                            if self?.session?.id == sessionID { self?.session = nil }
                        }, id: sessionID
                    )
                    session = newSession
                    newSession.start()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.session?.id == sessionID else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        session?.finish(.failure(CancellationError()))
    }

    nonisolated static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GoogleDriveLoopbackAuthorizationError.listenerUnavailable
        }
        return base64URL(Data(bytes))
    }

    @MainActor
    private final class Session {
        let id: UUID
        private let clientID: String
        private let scope: String
        private let state: String
        private let verifier: String
        private let timeout: Duration
        private let browserOpener: BrowserOpener
        private let onFinish: @MainActor () -> Void
        private var continuation: CheckedContinuation<AuthorizationCode, Error>?
        private var listener: NWListener?
        private var timer: Task<Void, Never>?
        private var redirectURI: String?
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private var connectionTimers: [ObjectIdentifier: Task<Void, Never>] = [:]
        private static let maximumHeaderBytes = 100_000

        init(
            clientID: String, scope: String, timeout: Duration,
            browserOpener: @escaping BrowserOpener,
            continuation: CheckedContinuation<AuthorizationCode, Error>,
            onFinish: @escaping @MainActor () -> Void, id: UUID
        ) throws {
            self.id = id
            self.clientID = clientID
            self.scope = scope
            self.timeout = timeout
            self.browserOpener = browserOpener
            self.continuation = continuation
            self.onFinish = onFinish
            state = try GoogleDriveLoopbackAuthorization.randomValue()
            verifier = try GoogleDriveLoopbackAuthorization.randomValue()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            do {
                listener = try NWListener(using: parameters)
            } catch {
                throw GoogleDriveLoopbackAuthorizationError.listenerUnavailable
            }
        }

        func start() {
            guard let listener else { return }
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { @MainActor in
                    guard let self, self.continuation != nil else { return }
                    switch listenerState {
                    case .ready: self.openBrowser()
                    case .failed: self.finish(.failure(GoogleDriveLoopbackAuthorizationError.listenerUnavailable))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.continuation != nil else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: .main)
            timer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: self?.timeout ?? .zero) }
                catch { return }
                self?.finish(.failure(GoogleDriveLoopbackAuthorizationError.timedOut))
            }
        }

        private func openBrowser() {
            guard redirectURI == nil, let port = listener?.port else { return }
            let redirect = "http://127.0.0.1:\(port.rawValue)/"
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: GoogleDriveLoopbackAuthorization.codeChallenge(for: verifier)),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            guard let url = components.url else {
                finish(.failure(GoogleDriveLoopbackAuthorizationError.listenerUnavailable))
                return
            }
            redirectURI = redirect
            if !browserOpener(url) { finish(.failure(GoogleDriveLoopbackAuthorizationError.browserUnavailable)) }
        }

        private func accept(_ connection: NWConnection) {
            // Bound stalled browser/probe connections as well as their request bytes.
            guard connections.count < 8 else { connection.cancel(); return }
            let key = ObjectIdentifier(connection)
            connections[key] = connection
            connection.start(queue: .main)
            connectionTimers[key] = Task { @MainActor [weak self, weak connection] in
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                if let connection { self?.close(connection) }
            }
            receive(connection, accumulated: Data())
        }

        private func receive(_ connection: NWConnection, accumulated: Data) {
            guard continuation != nil, connections[ObjectIdentifier(connection)] != nil else { close(connection); return }
            let remaining = Self.maximumHeaderBytes + 1 - accumulated.count
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(8192, remaining)) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self, self.continuation != nil,
                          self.connections[ObjectIdentifier(connection)] != nil else { connection.cancel(); return }
                    var request = accumulated
                    if let data { request.append(data) }
                    if request.count > Self.maximumHeaderBytes {
                        self.respond(connection, status: "431 Request Header Fields Too Large", accepted: false)
                    } else if let end = request.range(of: Data("\r\n\r\n".utf8)) {
                        self.handle(connection, header: request.subdata(in: 0..<end.upperBound))
                    } else if complete || error != nil {
                        self.close(connection)
                    } else {
                        self.receive(connection, accumulated: request)
                    }
                }
            }
        }

        private func handle(_ connection: NWConnection, header: Data) {
            guard let request = String(data: header, encoding: .utf8), let redirectURI,
                  let redirect = URLComponents(string: redirectURI) else {
                respond(connection, status: "400 Bad Request", accepted: false); return
            }
            let lines = request.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
            let expectedHost = "127.0.0.1:\(redirect.port!)"
            let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
            guard first.count == 3, first[0] == "GET", ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])),
                  hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == expectedHost,
                  first[1].hasPrefix("/"),
                  let callback = URLComponents(string: "http://\(expectedHost)\(first[1])"),
                  callback.path == "/", callback.fragment == nil else {
                respond(connection, status: "400 Bad Request", accepted: false); return
            }
            let query = callback.queryItems ?? []
            let states = query.filter { $0.name == "state" }
            guard states.count == 1, states[0].value == state else {
                respond(connection, status: "403 Forbidden", accepted: false); return
            }
            let codes = query.filter { $0.name == "code" }
            let errors = query.filter { $0.name == "error" }
            if codes.count == 1, errors.isEmpty, let code = codes[0].value, !code.isEmpty {
                respond(connection, status: "200 OK", accepted: true)
                finish(.success(AuthorizationCode(code: code, redirectURI: redirectURI, codeVerifier: verifier)), keeping: connection)
            } else if errors.count == 1, codes.isEmpty, let error = errors[0].value, !error.isEmpty {
                respond(connection, status: "200 OK", accepted: false)
                finish(.failure(GoogleDriveLoopbackAuthorizationError.authorizationDenied), keeping: connection)
            } else {
                respond(connection, status: "400 Bad Request", accepted: false)
            }
        }

        private func respond(_ connection: NWConnection, status: String, accepted: Bool) {
            let title = String(localized: "Google Drive sign-in")
            let message = accepted
                ? String(localized: "Google Drive authorization received. Return to Niratan to finish connecting.")
                : String(localized: "This Google Drive callback could not be accepted. Return to Niratan to continue sign-in.")
            let html = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"referrer\" content=\"no-referrer\"><title>\(Self.escapeHTML(title))</title></head><body><h1>\(Self.escapeHTML(title))</h1><p>\(Self.escapeHTML(message))</p></body></html>"
            let body = Data(html.utf8)
            var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                Task { @MainActor in self?.close(connection); connection.cancel() }
            })
        }

        private static func escapeHTML(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }

        private func close(_ connection: NWConnection) {
            let key = ObjectIdentifier(connection)
            connectionTimers.removeValue(forKey: key)?.cancel()
            connections.removeValue(forKey: key)
            connection.cancel()
        }

        func finish(_ result: Result<AuthorizationCode, Error>, keeping responseConnection: NWConnection? = nil) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            timer = nil
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            for connection in connections.values where connection !== responseConnection { connection.cancel() }
            connections.removeAll()
            for connectionTimer in connectionTimers.values { connectionTimer.cancel() }
            connectionTimers.removeAll()
            // A kept HTTP response owns no authorization state and still has a finite lifetime.
            if let responseConnection {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    responseConnection.cancel()
                }
            }
            onFinish()
            continuation.resume(with: result)
        }
    }
}
