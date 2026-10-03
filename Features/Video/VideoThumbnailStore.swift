import AppKit
import Foundation

nonisolated enum VideoThumbnailRequestMode: Sendable {
    case cacheOnly
    case generateIfMissing

    var taskIdentity: String {
        switch self {
        case .cacheOnly:
            "cacheOnly"
        case .generateIfMissing:
            "generateIfMissing"
        }
    }
}

nonisolated enum VideoThumbnailSuspendReason: Hashable, Sendable {
    case playback
    case lookup
    case mining
}

nonisolated protocol VideoThumbnailGenerating: Sendable {
    nonisolated func thumbnailPNGData(
        for url: URL,
        maximumDimension: Int
    ) async throws -> Data
}

nonisolated struct MpvVideoThumbnailGenerator: VideoThumbnailGenerating {
    private nonisolated static let defaultCaptureTime: TimeInterval = 5

    nonisolated func thumbnailPNGData(
        for url: URL,
        maximumDimension: Int
    ) async throws -> Data {
        let task = Task.detached(priority: .utility) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            var errorMessage: NSString?
            guard let data = HSMpvThumbnailGenerator.thumbnailPNGData(
                for: url,
                maximumDimension: maximumDimension,
                time: Self.defaultCaptureTime,
                isCancelled: { Task.isCancelled },
                errorMessage: &errorMessage
            ) else {
                throw VideoThumbnailStoreError.mpvUnavailable(errorMessage as String?)
            }
            return data
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

nonisolated enum VideoThumbnailStoreError: LocalizedError {
    case mpvUnavailable(String?)

    var errorDescription: String? {
        switch self {
        case .mpvUnavailable(let message):
            message ?? String(localized: "The bundled video thumbnailer did not return an image.")
        }
    }
}

nonisolated struct VideoThumbnailRequest: Hashable, Sendable {
    let path: String
    let fileSize: Int64
    let modifiedAt: Date?

    init(item: VideoLibraryItem) {
        path = item.path
        fileSize = item.fileSize
        modifiedAt = item.modifiedAt
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }
}

nonisolated final class VideoThumbnailStore: @unchecked Sendable {
    static let maximumDimension = 384

    private let cacheDirectory: URL
    private let generator: any VideoThumbnailGenerating
    private let fileManager: FileManager

    init(
        cacheDirectory: URL? = nil,
        generator: any VideoThumbnailGenerating = MpvVideoThumbnailGenerator(),
        fileManager: FileManager = .default
    ) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory(fileManager: fileManager)
        self.generator = generator
        self.fileManager = fileManager
    }

    func cachedThumbnailURL(for request: VideoThumbnailRequest) -> URL? {
        let url = cacheURL(for: request)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func generateThumbnailURL(for request: VideoThumbnailRequest) async -> URL? {
        if let cached = cachedThumbnailURL(for: request) {
            return cached
        }
        guard fileManager.fileExists(atPath: request.path) else {
            return nil
        }

        do {
            let data = try await generator.thumbnailPNGData(
                for: request.url,
                maximumDimension: Self.maximumDimension
            )
            try fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let url = cacheURL(for: request)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func invalidateThumbnail(for item: VideoLibraryItem) {
        try? fileManager.removeItem(at: cacheURL(for: VideoThumbnailRequest(item: item)))
    }

    func cacheURL(for request: VideoThumbnailRequest) -> URL {
        cacheDirectory.appendingPathComponent("\(Self.cacheKey(for: request)).png")
    }

    static func cacheKey(for item: VideoLibraryItem) -> String {
        cacheKey(for: VideoThumbnailRequest(item: item))
    }

    static func cacheKey(for request: VideoThumbnailRequest) -> String {
        let modified = request.modifiedAt?.timeIntervalSince1970 ?? 0
        let identity = "\(request.path)|\(request.fileSize)|\(modified)"
        return fnv1a64(identity)
    }

    private static func defaultCacheDirectory(fileManager: FileManager) -> URL {
        let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return directory.appendingPathComponent("VideoThumbnails", isDirectory: true)
    }

    private static func fnv1a64(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

actor VideoThumbnailScheduler {
    static let shared = VideoThumbnailScheduler(store: VideoThumbnailStore())
    static let maximumConcurrentJobs = 1

    private struct ContinuationBox {
        let id: UUID
        let continuation: CheckedContinuation<URL?, Never>
    }

    private struct PendingJob {
        let request: VideoThumbnailRequest
        var continuations: [ContinuationBox]
    }

    private let store: VideoThumbnailStore
    private var suspensionCounts: [VideoThumbnailSuspendReason: Int] = [:]
    private var pendingOrder: [String] = []
    private var pendingJobs: [String: PendingJob] = [:]
    private var runningKey: String?
    private var runningTask: Task<Void, Never>?

    init(store: VideoThumbnailStore) {
        self.store = store
    }

    func thumbnailURL(
        for item: VideoLibraryItem,
        requestMode: VideoThumbnailRequestMode
    ) async -> URL? {
        let request = VideoThumbnailRequest(item: item)
        let key = VideoThumbnailStore.cacheKey(for: request)
        if let cached = store.cachedThumbnailURL(for: request) {
            return cached
        }
        guard requestMode == .generateIfMissing, !isSuspended else {
            return nil
        }

        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(
                    request,
                    key: key,
                    requestID: requestID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelPendingRequest(key: key, requestID: requestID)
            }
        }
    }

    func suspend(reason: VideoThumbnailSuspendReason) {
        if reason == .playback {
            suspensionCounts[reason] = 1
        } else {
            suspensionCounts[reason, default: 0] += 1
        }
        runningTask?.cancel()
        cancelPending()
    }

    func resume(reason: VideoThumbnailSuspendReason) {
        guard let count = suspensionCounts[reason] else {
            return
        }
        if count <= 1 {
            suspensionCounts.removeValue(forKey: reason)
        } else {
            suspensionCounts[reason] = count - 1
        }
        startNextIfNeeded()
    }

    func cancelPending() {
        let jobs = pendingJobs.values
        pendingOrder.removeAll()
        pendingJobs.removeAll()
        for job in jobs {
            for box in job.continuations {
                box.continuation.resume(returning: nil)
            }
        }
    }

    private var isSuspended: Bool {
        suspensionCounts.values.contains { $0 > 0 }
    }

    private func enqueue(
        _ request: VideoThumbnailRequest,
        key: String,
        requestID: UUID,
        continuation: CheckedContinuation<URL?, Never>
    ) {
        if isSuspended {
            continuation.resume(returning: nil)
            return
        }

        if var existing = pendingJobs[key] {
            existing.continuations.append(
                ContinuationBox(id: requestID, continuation: continuation)
            )
            pendingJobs[key] = existing
        } else {
            pendingJobs[key] = PendingJob(
                request: request,
                continuations: [
                    ContinuationBox(id: requestID, continuation: continuation)
                ]
            )
            pendingOrder.append(key)
        }
        startNextIfNeeded()
    }

    private func cancelPendingRequest(key: String, requestID: UUID) {
        guard var job = pendingJobs[key],
              let index = job.continuations.firstIndex(where: { $0.id == requestID }) else {
            return
        }
        let box = job.continuations.remove(at: index)
        box.continuation.resume(returning: nil)
        if job.continuations.isEmpty {
            pendingJobs.removeValue(forKey: key)
            pendingOrder.removeAll { $0 == key }
        } else {
            pendingJobs[key] = job
        }
    }

    private func startNextIfNeeded() {
        guard runningTask == nil,
              !isSuspended,
              let key = pendingOrder.first,
              let job = pendingJobs.removeValue(forKey: key) else {
            return
        }
        pendingOrder.removeFirst()
        runningKey = key
        runningTask = Task {
            let url = await store.generateThumbnailURL(for: job.request)
            finishRunningJob(key: key, continuations: job.continuations, url: url)
        }
    }

    private func finishRunningJob(
        key: String,
        continuations: [ContinuationBox],
        url: URL?
    ) {
        guard runningKey == key else {
            return
        }
        runningKey = nil
        runningTask = nil
        for box in continuations {
            box.continuation.resume(returning: url)
        }
        startNextIfNeeded()
    }
}
