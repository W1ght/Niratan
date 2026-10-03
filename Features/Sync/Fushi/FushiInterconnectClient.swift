//
//  FushiInterconnectClient.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

nonisolated enum FushiInterconnectError: LocalizedError, Equatable {
    case invalidAddress
    case notFushi
    case unreachable(String)
    case tlsFingerprintUnavailable
    case tlsFingerprintMismatch
    case pairingDeclined
    case pairingExpired
    case pairingUnavailable
    case pairingUpgradeRequired
    case pinRejected
    case rateLimited
    case unauthorized
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return String(localized: "Enter the address shown in Fushi's interconnect settings, for example 192.168.1.10:38765.")
        case .notFushi:
            return String(localized: "The address did not answer like a Fushi interconnect host.")
        case .unreachable(let message):
            return String(localized: "Could not reach Fushi: \(message)")
        case .tlsFingerprintUnavailable:
            return String(localized: "Fushi uses TLS but did not report its certificate fingerprint.")
        case .tlsFingerprintMismatch:
            return String(localized: "Fushi's certificate does not match the paired fingerprint. Pair again if the host certificate was regenerated.")
        case .pairingDeclined:
            return String(localized: "Pairing was declined on the Fushi device.")
        case .pairingExpired:
            return String(localized: "The pairing request expired. Try again.")
        case .pairingUnavailable:
            return String(localized: "Fushi is not accepting pairing requests. Turn on hosting in Fushi's interconnect settings.")
        case .pairingUpgradeRequired:
            return String(localized: "This Fushi version requires a newer pairing method.")
        case .pinRejected:
            return String(localized: "The PIN was not accepted.")
        case .rateLimited:
            return String(localized: "Too many wrong PINs. Wait 15 minutes before pairing again.")
        case .unauthorized:
            return String(localized: "Fushi rejected Niratan's pairing. Pair again.")
        case .httpStatus(let status):
            return String(localized: "Fushi returned HTTP \(status).")
        case .invalidResponse:
            return String(localized: "Fushi returned an unexpected response.")
        }
    }
}

nonisolated struct FushiHostInfo: Decodable, Equatable, Sendable {
    struct TLS: Decodable, Equatable, Sendable {
        let enabled: Bool?
        let fingerprint: String?
    }

    let app: String?
    let deviceName: String?
    let hostId: String?
    let tls: TLS?
}

nonisolated struct FushiPairingSession: Decodable, Equatable, Sendable {
    let sessionId: String
    let pinRequired: Bool
    let hostNonce: String
}

nonisolated struct FushiPairingGrant: Decodable, Equatable, Sendable {
    let token: String
    let hostFingerprint: String?
}

/// One entry of `GET /api/library/books`; only the fields used to match local
/// novels are decoded.
nonisolated struct FushiRemoteBook: Decodable, Equatable, Sendable {
    let title: String
    let bookKey: String?
    let kind: String?
    let format: String?

    /// Fushi's wire key for the book: `bookKey`, or the ッツ-sanitized title for hosts
    /// that omit it.
    var key: String {
        if let bookKey, !bookKey.isEmpty { return bookKey }
        return TtuSyncNaming.sanitize(title)
    }

    var isNovel: Bool {
        (kind == nil || kind == "epub") && (format == nil || format == "epub")
    }
}

/// HTTP client for a Fushi interconnect host. Everything goes through the host's
/// JSON API; Niratan never uses the host's WebDAV mailbox, because the host's own
/// library position only lives behind `/api/library/books/<key>/progress`.
nonisolated final class FushiInterconnectClient: Sendable {
    static let defaultPort = 38765
    private static let requestTimeout: TimeInterval = 15
    /// Pairing requests stay open until someone answers the prompt on the Fushi device.
    private static let pairingTimeout: TimeInterval = 180

    let baseURL: URL
    private let token: String?
    private let session: URLSession
    private let tlsDelegate: FushiTLSDelegate

    init(baseURL: URL, token: String?, pinnedFingerprint: String?) {
        self.baseURL = baseURL
        self.token = token
        let delegate = FushiTLSDelegate(pinnedFingerprint: pinnedFingerprint)
        tlsDelegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.pairingTimeout + 30
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Accepts `host`, `host:port` or a full `http(s)://` URL; the port defaults to
    /// Fushi's 38765.
    static func normalizedBaseURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        components.scheme = scheme
        if components.port == nil {
            components.port = defaultPort
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// The leaf certificate fingerprint seen during the last TLS handshake.
    var observedFingerprint: String? {
        tlsDelegate.observedFingerprint
    }

    func ping() async throws -> FushiHostInfo {
        let info: FushiHostInfo = try await send("GET", path: ["api", "ping"], authenticated: false)
        guard info.app?.lowercased() == "fushi" else {
            throw FushiInterconnectError.notFushi
        }
        return info
    }

    func startPairing(deviceName: String, clientNonce: String, clientDeviceID: String) async throws -> FushiPairingSession {
        try await send(
            "POST",
            path: ["api", "pair", "v2"],
            body: ["name": deviceName, "clientNonce": clientNonce, "clientDeviceId": clientDeviceID],
            authenticated: false,
            timeout: Self.pairingTimeout,
            pairing: true
        )
    }

    func confirmPairing(sessionID: String, pinProof: String?) async throws -> FushiPairingGrant {
        var body = ["sessionId": sessionID]
        if let pinProof {
            body["pinProof"] = pinProof
        }
        return try await send(
            "POST",
            path: ["api", "pair", "v2", "confirm"],
            body: body,
            authenticated: false,
            timeout: Self.pairingTimeout,
            pairing: true
        )
    }

    func books() async throws -> [FushiRemoteBook] {
        try await send("GET", path: ["api", "library", "books"])
    }

    func progress(bookKey: String) async throws -> FushiRemoteProgress {
        try await send("GET", path: ["api", "library", "books", bookKey, "progress"])
    }

    func putProgress(_ progress: FushiRemoteProgress, bookKey: String) async throws {
        let _: EmptyResponse = try await send(
            "PUT",
            path: ["api", "library", "books", bookKey, "progress"],
            body: progress
        )
    }

    // MARK: - Pairing helpers

    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `hex(HMAC-SHA256(key: PIN, message: "<clientNonce>|<hostNonce>"))`, as Fushi
    /// verifies it.
    static func pinProof(pin: String, clientNonce: String, hostNonce: String) -> String {
        let key = SymmetricKey(data: Data(pin.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(clientNonce)|\(hostNonce)".utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedFingerprint(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter { $0 != ":" && !$0.isWhitespace }
    }

    static func fingerprint(ofCertificateData data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // MARK: - Transport

    private struct EmptyResponse: Decodable {}

    private struct PairingFailure: Decodable {
        let reason: String?
    }

    private func url(for path: [String]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        components.percentEncodedPath = "/" + path
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
        return components.url ?? baseURL
    }

    private func send<Response: Decodable>(
        _ method: String,
        path: [String],
        authenticated: Bool = true,
        timeout: TimeInterval? = nil,
        pairing: Bool = false
    ) async throws -> Response {
        try await send(method, path: path, body: Optional<EmptyBody>.none, authenticated: authenticated, timeout: timeout, pairing: pairing)
    }

    private struct EmptyBody: Encodable {}

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String,
        path: [String],
        body: Body?,
        authenticated: Bool = true,
        timeout: TimeInterval? = nil,
        pairing: Bool = false
    ) async throws -> Response {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.timeoutInterval = timeout ?? Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token else { throw FushiInterconnectError.unauthorized }
            // Fushi only checks the password half; the user name is cosmetic.
            let credentials = Data("hibiki:\(token)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if tlsDelegate.didRejectPinnedCertificate {
                throw FushiInterconnectError.tlsFingerprintMismatch
            }
            throw FushiInterconnectError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FushiInterconnectError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300:
            if Response.self == EmptyResponse.self {
                return EmptyResponse() as! Response
            }
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw FushiInterconnectError.invalidResponse
            }
        case 401, 403, 429:
            if pairing {
                throw Self.pairingError(status: http.statusCode, data: data)
            }
            throw FushiInterconnectError.unauthorized
        default:
            throw FushiInterconnectError.httpStatus(http.statusCode)
        }
    }

    private static func pairingError(status: Int, data: Data) -> FushiInterconnectError {
        let reason = (try? JSONDecoder().decode(PairingFailure.self, from: data))?.reason
        switch (status, reason) {
        case (429, _), (_, "rate_limited"):
            return .rateLimited
        case (401, _), (_, "pin"):
            return .pinRejected
        case (_, "expired"):
            return .pairingExpired
        case (_, "unavailable"):
            return .pairingUnavailable
        case (_, "upgrade_required"):
            return .pairingUpgradeRequired
        default:
            return .pairingDeclined
        }
    }
}

/// Accepts Fushi's self-signed certificate only when its SHA-256 fingerprint
/// matches the pinned one. Without a pin (first contact) it records the
/// fingerprint so the caller can compare it with what `/api/ping` reports and
/// what the Fushi screen shows before trusting it.
nonisolated final class FushiTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pinnedFingerprint: String?
    private let lock = NSLock()
    private var observed: String?
    private var rejected = false

    init(pinnedFingerprint: String?) {
        self.pinnedFingerprint = pinnedFingerprint.map(FushiInterconnectClient.normalizedFingerprint)
    }

    var observedFingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    var didRejectPinnedCertificate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = FushiInterconnectClient.fingerprint(ofCertificateData: SecCertificateCopyData(leaf) as Data)
        lock.lock()
        observed = fingerprint
        lock.unlock()

        guard let pinnedFingerprint else {
            // First contact: the caller pins this only after it matches `/api/ping`.
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if FushiInterconnectClient.normalizedFingerprint(fingerprint) == pinnedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.lock()
            rejected = true
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
