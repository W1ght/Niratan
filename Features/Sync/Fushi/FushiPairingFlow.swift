//
//  FushiPairingFlow.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Observation

/// Pairs Niratan with a Fushi host using Fushi's pairing v2 handshake: the host
/// approves the request on its own screen, and when it asks for a PIN Niratan
/// proves knowledge of it with an HMAC instead of sending it.
@Observable
final class FushiPairingFlow {
    enum State: Equatable {
        case idle
        case checking
        /// The request is open on the host; someone has to accept it there.
        case waitingForHost(String)
        case needsPIN(String)
        case failed(String)
    }

    private struct PendingPIN {
        let client: FushiInterconnectClient
        let baseURL: URL
        let info: FushiHostInfo
        let fingerprint: String?
        let sessionID: String
        let clientNonce: String
        let hostNonce: String
    }

    private(set) var state: State = .idle
    /// Shown while pairing over TLS so the user can compare it with Fushi's screen.
    private(set) var certificateFingerprint: String?
    private var pendingPIN: PendingPIN?
    private var task: Task<Void, Never>?

    private let store = FushiInterconnectStore.shared

    var isBusy: Bool {
        switch state {
        case .checking, .waitingForHost:
            return true
        default:
            return false
        }
    }

    func pair(address: String) {
        task?.cancel()
        task = Task { await run(address: address) }
    }

    func submitPIN(_ pin: String) {
        guard let pending = pendingPIN else { return }
        let digits = pin.filter(\.isNumber)
        task?.cancel()
        task = Task {
            state = .waitingForHost(pending.info.deviceName ?? pending.baseURL.host() ?? "Fushi")
            do {
                let proof = FushiInterconnectClient.pinProof(pin: digits, clientNonce: pending.clientNonce, hostNonce: pending.hostNonce)
                let grant = try await pending.client.confirmPairing(sessionID: pending.sessionID, pinProof: proof)
                finish(grant: grant, baseURL: pending.baseURL, info: pending.info, fingerprint: pending.fingerprint)
            } catch {
                fail(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingPIN = nil
        certificateFingerprint = nil
        state = .idle
    }

    private func run(address: String) async {
        pendingPIN = nil
        certificateFingerprint = nil
        state = .checking
        let hasScheme = address.contains("://")
        guard let baseURL = FushiInterconnectClient.normalizedBaseURL(address) else {
            fail(FushiInterconnectError.invalidAddress)
            return
        }
        do {
            // A host with TLS turned on only answers HTTPS on the same port.
            var (url, info, fingerprint) = try await retrying(
                { try await self.probe(baseURL) },
                retry: !hasScheme && baseURL.scheme == "http",
                { try await self.probe(Self.withScheme("https", baseURL)) }
            )
            if Task.isCancelled { return }
            if info.tls?.enabled == true, url.scheme == "http" {
                (url, info, fingerprint) = try await probe(Self.withScheme("https", url))
            }
            certificateFingerprint = fingerprint
            let hostName = info.deviceName ?? url.host() ?? "Fushi"
            let client = FushiInterconnectClient(baseURL: url, token: nil, pinnedFingerprint: fingerprint)
            let clientNonce = FushiInterconnectClient.makeNonce()
            state = .waitingForHost(hostName)
            let session = try await client.startPairing(
                deviceName: Self.deviceName,
                clientNonce: clientNonce,
                clientDeviceID: store.clientDeviceID
            )
            if Task.isCancelled { return }
            if session.pinRequired {
                pendingPIN = PendingPIN(
                    client: client,
                    baseURL: url,
                    info: info,
                    fingerprint: fingerprint,
                    sessionID: session.sessionId,
                    clientNonce: clientNonce,
                    hostNonce: session.hostNonce
                )
                state = .needsPIN(hostName)
                return
            }
            let grant = try await client.confirmPairing(sessionID: session.sessionId, pinProof: nil)
            finish(grant: grant, baseURL: url, info: info, fingerprint: fingerprint)
        } catch {
            if !Task.isCancelled {
                fail(error)
            }
        }
    }

    private func probe(_ url: URL) async throws -> (URL, FushiHostInfo, String?) {
        let client = FushiInterconnectClient(baseURL: url, token: nil, pinnedFingerprint: nil)
        let info = try await client.ping()
        guard url.scheme == "https" else {
            return (url, info, nil)
        }
        guard let reported = info.tls?.fingerprint, let observed = client.observedFingerprint else {
            throw FushiInterconnectError.tlsFingerprintUnavailable
        }
        guard FushiInterconnectClient.normalizedFingerprint(reported) == FushiInterconnectClient.normalizedFingerprint(observed) else {
            throw FushiInterconnectError.tlsFingerprintMismatch
        }
        return (url, info, observed)
    }

    private func finish(grant: FushiPairingGrant, baseURL: URL, info: FushiHostInfo, fingerprint: String?) {
        pendingPIN = nil
        if let granted = grant.hostFingerprint, let fingerprint,
           FushiInterconnectClient.normalizedFingerprint(granted) != FushiInterconnectClient.normalizedFingerprint(fingerprint) {
            fail(FushiInterconnectError.tlsFingerprintMismatch)
            return
        }
        guard store.savePairing(hostURL: baseURL, info: info, token: grant.token, fingerprint: fingerprint) else {
            state = .failed(String(localized: "Could not save the pairing to the Keychain."))
            return
        }
        FushiProgressCoordinator.shared.forgetHost()
        certificateFingerprint = nil
        state = .idle
    }

    private func fail(_ error: Error) {
        pendingPIN = nil
        state = .failed(error.localizedDescription)
    }

    private static func withScheme(_ scheme: String, _ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url ?? url
    }

    private static var deviceName: String {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return "Niratan · \(name)"
        }
        return "Niratan (Mac)"
    }
}

private func retrying<T>(_ first: () async throws -> T, retry: Bool, _ second: () async throws -> T) async throws -> T {
    do {
        return try await first()
    } catch FushiInterconnectError.unreachable(let message) where retry {
        do {
            return try await second()
        } catch {
            throw FushiInterconnectError.unreachable(message)
        }
    }
}

/// Finds Fushi hosts on the local network through the Bonjour service Fushi
/// advertises (`_fushi-sync._tcp`).
@Observable
final class FushiBonjourBrowser {
    struct DiscoveredHost: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        let usesTLS: Bool
    }

    private(set) var hosts: [DiscoveredHost] = []
    private(set) var isBrowsing = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_fushi-sync._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap(Self.host(from:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                self?.hosts = hosts
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let browsing: Bool
            switch state {
            case .ready, .setup:
                browsing = true
            default:
                browsing = false
            }
            Task { @MainActor in
                self?.isBrowsing = browsing
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        hosts = []
    }

    /// The host's `http(s)://address:port`, resolved over IPv4 because Fushi's
    /// plain-HTTP listener is IPv4 only.
    func address(of host: DiscoveredHost) async -> String? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: host.endpoint, using: parameters)
        let scheme = host.usesTLS ? "https" : "http"
        return await withCheckedContinuation { continuation in
            let resolver = FushiEndpointResolution(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var address: String?
                    if case .hostPort(let endpointHost, let port)? = connection.currentPath?.remoteEndpoint {
                        address = Self.address(host: endpointHost, port: port, scheme: scheme)
                    }
                    connection.cancel()
                    resolver.finish(address)
                case .failed, .cancelled:
                    connection.cancel()
                    resolver.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                connection.cancel()
                resolver.finish(nil)
            }
        }
    }

    private nonisolated static func host(from result: NWBrowser.Result) -> DiscoveredHost? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var usesTLS = false
        var id = name
        if case .bonjour(let txt) = result.metadata {
            usesTLS = txt["tls"] == "1"
            if let deviceID = txt["id"], !deviceID.isEmpty {
                id = deviceID
            }
        }
        return DiscoveredHost(id: id, name: name, endpoint: result.endpoint, usesTLS: usesTLS)
    }

    private nonisolated static func address(host: NWEndpoint.Host, port: NWEndpoint.Port, scheme: String) -> String? {
        let text: String
        switch host {
        case .ipv4(let address):
            text = "\(address)"
        case .ipv6(let address):
            text = "[\("\(address)".split(separator: "%").first ?? "")]"
        case .name(let name, _):
            text = name
        @unknown default:
            return nil
        }
        return "\(scheme)://\(text):\(port.rawValue)"
    }
}

/// Resumes a continuation exactly once from Network.framework callbacks.
nonisolated private final class FushiEndpointResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func finish(_ address: String?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: address)
    }
}
