// test-sources: Features/Video/Remote/RemoteSubtitleLoader.swift Features/Video/Remote/RemoteVideoSource.swift Models/Subtitle.swift Features/Video/Remote/BoundedURLSessionData.swift Features/Video/Remote/YouTubeURLParser.swift
import Foundation

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let data: Data
        let delay: TimeInterval
        let chunkSize: Int?
        let interChunkDelay: TimeInterval

        init(
            statusCode: Int,
            data: Data,
            delay: TimeInterval,
            chunkSize: Int? = nil,
            interChunkDelay: TimeInterval = 0
        ) {
            self.statusCode = statusCode
            self.data = data
            self.delay = delay
            self.chunkSize = chunkSize
            self.interChunkDelay = interChunkDelay
        }
    }

    private static let lock = NSLock()
    private static var responses: [String: Response] = [:]
    private static var capturedRequests: [URLRequest] = []
    private static var stoppedPaths: Set<String> = []
    private static var deliveredByteCounts: [String: Int] = [:]

    private let stateLock = NSLock()
    private var stopped = false

    static func reset(responses: [String: Response]) {
        lock.lock()
        self.responses = responses
        capturedRequests = []
        stoppedPaths = []
        deliveredByteCounts = [:]
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    static func wasStopped(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedPaths.contains(path)
    }

    static func deliveredByteCount(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveredByteCounts[path] ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let response = request.url.flatMap { Self.responses[$0.path] }
        Self.lock.unlock()

        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + response.delay) { [weak self] in
            guard let self, !isStopped else { return }
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/vtt"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            send(response: response, offset: 0)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        Self.lock.lock()
        if let path = request.url?.path {
            Self.stoppedPaths.insert(path)
        }
        Self.lock.unlock()
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func send(response: Response, offset: Int) {
        guard !isStopped else { return }
        guard offset < response.data.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let requestedChunkSize = response.chunkSize ?? response.data.count
        let end = min(response.data.count, offset + max(1, requestedChunkSize))
        let chunk = response.data.subdata(in: offset..<end)
        Self.lock.lock()
        if let path = request.url?.path {
            Self.deliveredByteCounts[path, default: 0] += chunk.count
        }
        Self.lock.unlock()
        client?.urlProtocol(self, didLoad: chunk)

        guard end < response.data.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + response.interChunkDelay
        ) { [weak self] in
            self?.send(response: response, offset: end)
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func option(
    path: String,
    format: SubtitleFormat = .webVTT,
    headers: [String: String] = [:]
) -> RemoteVideoSubtitleOption {
    RemoteVideoSubtitleOption(
        id: path,
        language: "ja",
        name: "Japanese",
        url: URL(string: "https://subtitle.example\(path)")!,
        format: format,
        isAutomatic: false,
        httpHeaders: headers
    )
}

@main
private enum VideoRemoteSubtitleLoaderTests {
    @MainActor
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-remote-subtitle-tests-\(UUID().uuidString)", isDirectory: true)
        let loader = RemoteSubtitleLoader(session: session, temporaryDirectory: directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        StubURLProtocol.reset(responses: [
            "/first": .init(statusCode: 200, data: Data("WEBVTT\n\n".utf8), delay: 0),
            "/second": .init(statusCode: 200, data: Data("1\n00:00:00,000 --> 00:00:01,000\n星\n".utf8), delay: 0),
        ])
        let first = try await loader.load(
            option: option(path: "/first", headers: ["Referer": "https://video.example/"]),
            headers: ["User-Agent": "HoshiTests"],
            generation: 1
        )
        expect(first?.pathExtension == "vtt", "WebVTT should use a .vtt temporary file")
        expect(first.map { FileManager.default.fileExists(atPath: $0.path) } == true, "loaded subtitle should exist")
        let request = StubURLProtocol.requests().first
        expect(request?.value(forHTTPHeaderField: "Referer") == "https://video.example/", "option headers should be sent")
        expect(request?.value(forHTTPHeaderField: "User-Agent") == "HoshiTests", "additional headers should be sent")

        let second = try await loader.load(
            option: option(path: "/second", format: .srt),
            headers: [:],
            generation: 2
        )
        expect(second?.pathExtension == "srt", "explicit SRT should use a .srt temporary file")
        expect(first.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "replacement should delete the previous temporary file")

        StubURLProtocol.reset(responses: [
            "/styled": .init(statusCode: 200, data: Data("[Script Info]\n".utf8), delay: 0),
        ])
        let styled = try await loader.load(
            option: option(path: "/styled", format: .ass),
            headers: [:],
            generation: 3
        )
        expect(styled?.pathExtension == "ass", "remote ASS should retain its format for interactive ownership preparation")
        expect(second.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "ASS replacement should delete the previous subtitle")

        StubURLProtocol.reset(responses: [
            "/forbidden": .init(statusCode: 403, data: Data(), delay: 0),
        ])
        do {
            _ = try await loader.load(
                option: option(path: "/forbidden"),
                headers: [:],
                generation: 4
            )
            expect(false, "HTTP 403 should be rejected")
        } catch RemoteSubtitleLoaderError.httpStatus(403) {
        }

        do {
            _ = try await loader.load(
                option: option(path: "/untrusted"),
                allowedDownloadHosts: ["raw.githubusercontent.com"],
                generation: 5
            )
            expect(false, "provider host policies should reject an untrusted initial download URL")
        } catch RemoteSubtitleLoaderError.untrustedDownloadURL {
        }

        StubURLProtocol.reset(responses: [
            "/oversized": .init(statusCode: 200, data: Data("12345".utf8), delay: 0),
        ])
        do {
            _ = try await loader.load(
                option: option(path: "/oversized"),
                maximumResponseSize: 4,
                generation: 5
            )
            expect(false, "remote subtitle payloads should respect their byte limit")
        } catch RemoteSubtitleLoaderError.responseTooLarge {
        }

        StubURLProtocol.reset(responses: [
            "/streaming-oversized": .init(
                statusCode: 200,
                data: Data("1234567890".utf8),
                delay: 0,
                chunkSize: 2,
                interChunkDelay: 0.05
            ),
        ])
        do {
            _ = try await loader.load(
                option: option(path: "/streaming-oversized"),
                maximumResponseSize: 4,
                generation: 6
            )
            expect(false, "streamed remote subtitle payloads should stop at their byte limit")
        } catch RemoteSubtitleLoaderError.responseTooLarge {
        }
        try await Task.sleep(for: .milliseconds(80))
        expect(StubURLProtocol.wasStopped(path: "/streaming-oversized"), "the network task should be cancelled immediately after the streaming limit is exceeded")
        expect(StubURLProtocol.deliveredByteCount(path: "/streaming-oversized") < 10, "streaming cancellation should stop later chunks from being delivered")

        StubURLProtocol.reset(responses: [
            "/slow": .init(statusCode: 200, data: Data("WEBVTT\n\nslow".utf8), delay: 0.3),
            "/new": .init(statusCode: 200, data: Data("WEBVTT\n\nnew".utf8), delay: 0),
        ])
        let staleTask = Task {
            try await loader.load(
                option: option(path: "/slow"),
                headers: [:],
                generation: 7
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let newest = try await loader.load(
            option: option(path: "/new"),
            headers: [:],
            generation: 8
        )
        let stale = try? await staleTask.value
        expect(stale == nil, "a cancelled stale generation must not install its subtitle")
        expect(newest.map { FileManager.default.fileExists(atPath: $0.path) } == true, "newest subtitle should remain installed")

        loader.cancelAndCleanup()
        expect(second.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "cleanup should remove replaced subtitle files")
        expect(styled.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "cleanup should remove replaced ASS files")
        expect(newest.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "cleanup should remove the active subtitle file")
        print("Video remote subtitle loader tests passed")
    }
}
