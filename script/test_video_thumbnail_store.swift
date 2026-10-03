import Foundation

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

private func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let libraryView = try source("Features/Video/VideoLibraryView.swift")
let thumbnailStore = try source("Features/Video/VideoThumbnailStore.swift")
let clientHeader = try source("Features/Video/Playback/HSMpvClient.h")
let clientImplementation = try source("Features/Video/Playback/HSMpvClient.mm")
let playerScreen = try source("Features/Video/VideoPlayerScreen.swift")
    + source("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + source("Features/Video/VideoPlayerScreen+Chrome.swift")
    + source("Features/Video/VideoPlayerScreen+OSD.swift")
    + source("Features/Video/VideoPlayerScreen+Mining.swift")
    + source("Features/Video/VideoPlayerScreen+Opening.swift")
    + source("Features/Video/VideoPlayerScreen+Shortcuts.swift")
let miningCoordinator = try source("Features/Video/VideoMiningCoordinator.swift")
let lookupCoordinator = try source("Features/Video/VideoLookupCoordinator.swift")
let project = try source("Niratan.xcodeproj/project.pbxproj")

expect(
    !thumbnailStore.contains("HOSHI_VIDEO")
        && thumbnailStore.contains("actor VideoThumbnailScheduler")
        && thumbnailStore.contains("final class VideoThumbnailStore")
        && thumbnailStore.contains("static let maximumConcurrentJobs = 1")
        && thumbnailStore.contains("static let maximumDimension = 384"),
    "video thumbnails should compile in the full build with a single-concurrency scheduler"
)

expect(
    thumbnailStore.contains("VideoThumbnailRequestMode")
        && thumbnailStore.contains("case cacheOnly")
        && thumbnailStore.contains("case generateIfMissing")
        && thumbnailStore.contains("VideoThumbnailSuspendReason")
        && thumbnailStore.contains("case playback")
        && thumbnailStore.contains("case lookup")
        && thumbnailStore.contains("case mining"),
    "thumbnail requests should expose cache-only/generate modes and playback/lookup/mining suspension reasons"
)

expect(
    thumbnailStore.contains("let identity = \"\\(request.path)|\\(request.fileSize)|\\(modified)\"")
        && thumbnailStore.contains("VideoThumbnails")
        && thumbnailStore.contains("try data.write(to: url, options: .atomic)")
        && thumbnailStore.contains("cachedThumbnailURL(for:")
        && thumbnailStore.contains("generateThumbnailURL(for:"),
    "thumbnail cache should key path, file size, and modified date, store PNGs under Application Support/VideoThumbnails, and write atomically"
)

if let thumbnailURLRange = thumbnailStore.range(of: "func thumbnailURL("),
   let thumbnailURLEnd = thumbnailStore[thumbnailURLRange.lowerBound...].range(of: "func suspend(reason:")?.lowerBound {
    let thumbnailURL = thumbnailStore[thumbnailURLRange.lowerBound..<thumbnailURLEnd]
    let cachedIndex = thumbnailURL.range(of: "if let cached = store.cachedThumbnailURL(for: request)")?.lowerBound
    let suspendedIndex = thumbnailURL.range(of: "guard requestMode == .generateIfMissing, !isSuspended else")?.lowerBound
    expect(
        cachedIndex != nil
            && suspendedIndex != nil
            && cachedIndex! < suspendedIndex!,
        "video thumbnail scheduler should return cached thumbnails even while video-session generation is suspended"
    )
} else {
    expect(false, "video thumbnail scheduler thumbnailURL implementation should be inspectable")
}

expect(
    thumbnailStore.contains("pendingOrder")
        && thumbnailStore.contains("pendingJobs")
        && thumbnailStore.contains("runningTask")
        && thumbnailStore.contains("if var existing = pendingJobs[key]")
        && thumbnailStore.contains("existing.continuations.append")
        && thumbnailStore.contains("guard runningTask == nil")
        && thumbnailStore.contains("cancelPending()")
        && thumbnailStore.contains("func suspend(reason:")
        && thumbnailStore.contains("func resume(reason:")
        && thumbnailStore.contains("runningTask?.cancel()")
        && thumbnailStore.contains("cancelPendingRequest"),
    "scheduler should merge duplicate requests, run only one job, cancel running and pending work on suspend, and support request cancellation"
)

expect(
    clientHeader.contains("HSMpvThumbnailGenerator")
        && clientHeader.contains("HSMpvCancellationHandler")
        && clientHeader.contains("isCancelled:(HSMpvCancellationHandler)isCancelled")
        && clientImplementation.contains("@implementation HSMpvThumbnailGenerator")
        && clientImplementation.contains("HSMpvRenderThumbnailPNGData")
        && clientImplementation.contains("HSMpvThumbnailIsCancelled")
        && clientImplementation.contains("mpv_wait_event(thumbnailer, 0.1)")
        && clientImplementation.contains("!HSMpvThumbnailIsCancelled(isCancelled)")
        && clientImplementation.contains("vo-image-format")
        && clientImplementation.contains("HSMpvPNGDataByLimitingMaximumDimension"),
    "mpv thumbnail bridge should be restored as an isolated native thumbnail generator with cancellation-aware polling and fallback guard"
)

expect(
    thumbnailStore.contains("HSMpvThumbnailGenerator.thumbnailPNGData")
        && thumbnailStore.contains("withTaskCancellationHandler")
        && thumbnailStore.contains("task.cancel()")
        && thumbnailStore.contains("isCancelled: { Task.isCancelled }")
        && !libraryView.contains("HSMpvThumbnailGenerator")
        && !libraryView.contains("Task.detached")
        && !playerScreen.contains("HSMpvThumbnailGenerator")
        && !miningCoordinator.contains("HSMpvThumbnailGenerator"),
    "mpv thumbnail generation should only be invoked by the thumbnail store/generator, never directly by views or player/mining code"
)

expect(
    libraryView.contains("VideoThumbnailScheduler.shared")
        && libraryView.contains("VideoThumbnailImageView(")
        && libraryView.contains("thumbnailRequestMode: .generateIfMissing")
        && libraryView.contains("requestMode: .generateIfMissing")
        && libraryView.contains("requestMode.taskIdentity")
        && libraryView.contains("var thumbnailTaskID: String")
        && libraryView.contains("await scheduler.thumbnailURL(")
        && !libraryView.contains("globallyGeneratedThumbnailItemIDs")
        && !libraryView.contains("sections.flatMap(\\.rows).prefix(8)")
        && !libraryView.contains("index < 8")
        && !libraryView.contains("generatesMissingThumbnail"),
    "VideoLibraryView should use scheduler-backed visible thumbnails that generate when missing in list and poster layouts"
)

expect(
    playerScreen.contains("suspendVideoThumbnailsForVideoSession()")
        && playerScreen.contains("resumeVideoThumbnailsForVideoSession()")
        && playerScreen.contains("await VideoThumbnailScheduler.shared.suspend(reason: .playback)")
        && playerScreen.contains("await VideoThumbnailScheduler.shared.resume(reason: .playback)")
        && miningCoordinator.contains("suspendVideoThumbnailsForMining()")
        && miningCoordinator.contains("resumeVideoThumbnailsForMining()")
        && miningCoordinator.contains("await VideoThumbnailScheduler.shared.suspend(reason: .mining)")
        && miningCoordinator.contains("await VideoThumbnailScheduler.shared.resume(reason: .mining)")
        && lookupCoordinator.contains("suspendVideoThumbnailsForLookupIfNeeded()")
        && lookupCoordinator.contains("resumeVideoThumbnailsForLookupIfNeeded()")
        && lookupCoordinator.contains("await VideoThumbnailScheduler.shared.suspend(reason: .lookup)")
        && lookupCoordinator.contains("await VideoThumbnailScheduler.shared.resume(reason: .lookup)")
        && lookupCoordinator.contains("guard self.presentation.popups.isEmpty else"),
    "playback, video lookup popups, and video mining should pause thumbnail work while user-facing video actions have priority"
)

expect(
    project.contains("Video/VideoThumbnailStore.swift"),
    "project membership exceptions should include the restored thumbnail store"
)

print("Video thumbnail scheduler contract passed")
