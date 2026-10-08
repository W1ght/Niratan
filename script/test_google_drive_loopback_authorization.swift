// test-sources: Features/Sync/GoogleDriveLoopbackAuthorization.swift
import Foundation
import Network

@MainActor
private final class HTTPProbe {
    private let connection: NWConnection
    private let request: Data
    private var continuation: CheckedContinuation<String, Error>?
    private var timer: Task<Void, Never>?
    private var sent = false
    private var response = Data()

    init(port: UInt16, request: Data, continuation: CheckedContinuation<String, Error>) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.request = request
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    guard !sent else { return }
                    sent = true
                    connection.send(content: request, completion: .contentProcessed { [self] error in
                        Task { @MainActor in
                            if let error { finish(.failure(error)) }
                            else { receive() }
                        }
                    })
                case .failed(let error), .waiting(let error): finish(.failure(error))
                default: break
                }
            }
        }
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            self?.finish(.failure(TestFailure(message: "local HTTP probe timed out")))
        }
        connection.start(queue: .main)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            Task { @MainActor in
                if let data { response.append(data) }
                if let error { finish(.failure(error)) }
                else if complete { finish(.success(String(decoding: response, as: UTF8.self))) }
                else { receive() }
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}

nonisolated private struct TestFailure: Error { let message: String }

@main
@MainActor
private enum GoogleDriveLoopbackAuthorizationTests {
    private static let clientID = "fixture.apps.googleusercontent.com"
    private static let scope = "https://www.googleapis.com/auth/drive.file"
    private static var checks = 0

    static func main() async {
        do { try await run() }
        catch {
            print("FAIL: native Google Drive loopback after \(checks) checks: \(error)")
            exit(1)
        }
    }

    private static func run() async throws {
        require(
            GoogleDriveLoopbackAuthorization.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "PKCE S256 matches the RFC 7636 test vector"
        )
        let authorization = GoogleDriveLoopbackAuthorization()
        var captured: URL?
        let task = Task {
            try await authorization.authorize(clientID: clientID, scope: scope, browserOpener: { captured = $0; return true })
        }
        try await waitForURL { captured }
        let url = captured!
        let parameters = query(url)
        let redirect = URL(string: parameters["redirect_uri"]!)!
        let state = parameters["state"]!
        require(url.scheme == "https" && url.host == "accounts.google.com", "only the Google authorization endpoint is passed to the browser")
        require(parameters["client_id"] == clientID && parameters["scope"] == scope, "client and least-privilege scope are preserved")
        require(parameters["response_type"] == "code" && parameters["code_challenge_method"] == "S256", "authorization uses a code and S256")
        require(parameters["access_type"] == "offline" && parameters["prompt"] == "consent", "refresh-token authorization is requested")
        require(redirect.scheme == "http" && redirect.host == "127.0.0.1" && redirect.port != nil && redirect.path == "/", "redirect uses an ephemeral IPv4 loopback root")
        require(state.count >= 32 && parameters["code_challenge"]?.count == 43, "state and challenge have strong random entropy")
        require(parameters["code_verifier"] == nil, "the verifier is never sent in the authorization URL")
        let invalidRequests: [(String, String)] = [
            ("/?code=fixture&state=wrong", "403"),
            ("/?error=access_denied&state=wrong", "403"),
            ("/favicon.ico?code=fixture&state=\(state)", "400"),
            ("/?code=fixture&state=\(state)#fragment", "400"),
            ("/?code=fixture&state=\(state)&state=\(state)", "403"),
            ("/?code=one&code=two&state=\(state)", "400"),
            ("/?code=fixture&error=access_denied&state=\(state)", "400"),
            ("/?code=&state=\(state)", "400"),
        ]
        for (target, status) in invalidRequests {
            let response = try await rawHTTP(redirect: redirect, target: target)
            require(response.hasPrefix("HTTP/1.1 \(status)"), "an invalid local callback receives an HTTP rejection")
            require(authorization.isAuthorizing, "an invalid callback cannot finish or consume the real authorization")
            require(!response.contains(state) && !response.contains("code=fixture"), "callback HTML never echoes secret query values")
        }
        let post = try await rawHTTP(redirect: redirect, target: "/?code=fixture&state=\(state)", method: "POST")
        require(post.hasPrefix("HTTP/1.1 400"), "only GET can return an authorization code")
        do {
            let oversized = try await rawHTTP(redirect: redirect, target: "/", extraHeader: "X-Fill: " + String(repeating: "A", count: 100_001))
            require(oversized.hasPrefix("HTTP/1.1 431"), "the callback header limit rejects oversized requests")
        } catch let error as NWError {
            require(error == .posix(.ECONNRESET), "an oversized request may be reset after its bounded header is rejected")
        }
        require(authorization.isAuthorizing, "an oversized request cannot consume authorization")
        do {
            _ = try await authorization.authorize(clientID: clientID, scope: scope, browserOpener: { _ in fatalError("overlapping authorization must not open a browser") })
            throw TestFailure(message: "overlapping authorization was accepted")
        } catch GoogleDriveLoopbackAuthorizationError.alreadyInProgress { checks += 1 }

        let response = try await rawHTTP(redirect: redirect, target: "/?code=fixture-code&state=\(state)", extraHeader: "X-Fill: " + String(repeating: "A", count: 95_000))
        let code = try await task.value
        require(response.hasPrefix("HTTP/1.1 200") && response.contains("Return to Niratan"), "the accepted callback responds before closing its connection")
        require(code.code == "fixture-code" && code.redirectURI == redirect.absoluteString, "the returned code and exact redirect belong to the successful callback")
        require(code.codeVerifier.count == 43 && GoogleDriveLoopbackAuthorization.codeChallenge(for: code.codeVerifier) == parameters["code_challenge"], "the returned verifier matches the authorization challenge")
        require(!authorization.isAuthorizing, "success completes the authorization exactly once")
        authorization.cancel()
        try await requireClosed(redirect)

        var deniedURL: URL?
        let denied = Task { try await authorization.authorize(clientID: clientID, scope: scope, browserOpener: { deniedURL = $0; return true }) }
        try await waitForURL { deniedURL }
        let deniedParameters = query(deniedURL!)
        let deniedRedirect = URL(string: deniedParameters["redirect_uri"]!)!
        require(deniedParameters["state"] != state && deniedParameters["code_challenge"] != parameters["code_challenge"], "each authorization gets fresh state and PKCE")
        _ = try await rawHTTP(redirect: deniedRedirect, target: "/?error=access_denied&state=\(deniedParameters["state"]!)")
        do { _ = try await denied.value; throw TestFailure(message: "denial returned an authorization code") }
        catch GoogleDriveLoopbackAuthorizationError.authorizationDenied { checks += 1 }
        try await requireClosed(deniedRedirect)

        var cancelURL: URL?
        let cancelled = Task { try await authorization.authorize(clientID: clientID, scope: scope, browserOpener: { cancelURL = $0; return true }) }
        try await waitForURL { cancelURL }
        let cancelRedirect = URL(string: query(cancelURL!)["redirect_uri"]!)!
        authorization.cancel()
        authorization.cancel()
        do { _ = try await cancelled.value; throw TestFailure(message: "explicit cancellation returned a code") }
        catch is CancellationError { checks += 1 }
        try await requireClosed(cancelRedirect)

        var taskCancelURL: URL?
        let taskCancelled = Task { try await authorization.authorize(clientID: clientID, scope: scope, browserOpener: { taskCancelURL = $0; return true }) }
        try await waitForURL { taskCancelURL }
        let taskCancelRedirect = URL(string: query(taskCancelURL!)["redirect_uri"]!)!
        taskCancelled.cancel()
        do { _ = try await taskCancelled.value; throw TestFailure(message: "task cancellation returned a code") }
        catch is CancellationError { checks += 1 }
        try await requireClosed(taskCancelRedirect)

        var timeoutURL: URL?
        let timeout = Task { try await authorization.authorize(clientID: clientID, scope: scope, timeout: .milliseconds(100), browserOpener: { timeoutURL = $0; return true }) }
        try await waitForURL { timeoutURL }
        let timeoutRedirect = URL(string: query(timeoutURL!)["redirect_uri"]!)!
        do { _ = try await timeout.value; throw TestFailure(message: "timeout returned a code") }
        catch GoogleDriveLoopbackAuthorizationError.timedOut { checks += 1 }
        try await requireClosed(timeoutRedirect)

        var unavailableURL: URL?
        do {
            _ = try await authorization.authorize(clientID: clientID, scope: scope, browserOpener: { unavailableURL = $0; return false })
            throw TestFailure(message: "failed browser launch returned a code")
        } catch GoogleDriveLoopbackAuthorizationError.browserUnavailable { checks += 1 }
        try await requireClosed(URL(string: query(unavailableURL!)["redirect_uri"]!)!)

        let earlyCancelled = Task {
            try await authorization.authorize(clientID: clientID, scope: scope, browserOpener: { _ in fatalError("an already cancelled task must not open the browser") })
        }
        earlyCancelled.cancel()
        do { _ = try await earlyCancelled.value; throw TestFailure(message: "an already cancelled task returned a code") }
        catch is CancellationError { checks += 1 }
        require(!authorization.isAuthorizing, "all failed/cancelled flows release their session")
        print("PASS: native Google Drive loopback + PKCE (\(checks) checks; local sockets only; browser and Google requests disabled)")
    }

    private static func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }

    private static func waitForURL(_ value: () -> URL?) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while value() == nil {
            guard ContinuousClock.now < deadline else { throw TestFailure(message: "listener did not become ready") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func rawHTTP(redirect: URL, target: String, method: String = "GET", extraHeader: String = "") async throws -> String {
        let request = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(redirect.port!)\r\n\(extraHeader.isEmpty ? "" : extraHeader + "\r\n")Connection: close\r\n\r\n"
        return try await withCheckedThrowingContinuation { continuation in
            HTTPProbe(port: UInt16(redirect.port!), request: Data(request.utf8), continuation: continuation).start()
        }
    }

    private static func requireClosed(_ redirect: URL) async throws {
        do {
            _ = try await rawHTTP(redirect: redirect, target: "/")
            throw TestFailure(message: "authorization listener stayed open after completion")
        } catch is TestFailure { throw TestFailure(message: "authorization listener stayed open or stalled after completion") }
        catch let error as NWError {
            require(error == .posix(.ECONNREFUSED), "a completed authorization must refuse new connections on its exact loopback port")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        checks += 1
    }
}
