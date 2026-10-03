import Foundation

enum MpvPlayerEngineError: LocalizedError {
    case initializationFailed(String)
    case mediaExportFailed(String)
    case videoShaderFailed(String)

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let message):
            message
        case .mediaExportFailed(let message):
            message
        case .videoShaderFailed(let message):
            message
        }
    }
}

@MainActor
final class MpvPlayerEngine: PlaybackEngine {
    private let client: HSMpvClient?
    private let initializationError: String?
    private weak var attachedRenderView: HSMpvOpenGLView?
    private var renderDetachGeneration: UInt64 = 0
    private var pendingRenderDetachTask: Task<Void, Never>?
    private var loadedSource: VideoPlaybackSource?
    private var subtitleRenderingMode: VideoSubtitleRenderingMode = .overlayOnly
    private var appliedVideoShaderPreset: VideoShaderPreset?
    private(set) var snapshot = VideoPlaybackSnapshot()
    var onSnapshotChanged: ((VideoPlaybackSnapshot) -> Void)?
    var onError: ((String) -> Void)?
    var onRemotePlaybackFailure: ((RemotePlaybackFailure) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onEmbeddedSubtitleCuesChanged: (([VideoEmbeddedSubtitleCue]) -> Void)?

    init() {
        var errorMessage: NSString?
        client = HSMpvClient.make(errorMessage: &errorMessage)
        initializationError = errorMessage as String?
        client?.stateHandler = {
            [weak self] currentTime,
            duration,
            playing,
            loaded,
            speed,
            volume,
            muted,
            subtitleDelay,
            audioDelay,
            loopMode,
            abLoopStart,
            abLoopEnd,
            aspectRatio,
            rotation,
            videoWidth,
            videoHeight,
            errorMessage in
            guard let self else { return }
            snapshot = VideoPlaybackSnapshot(
                currentTime: currentTime,
                duration: duration,
                isPlaying: playing,
                isLoaded: loaded,
                speed: speed,
                volume: volume,
                isMuted: muted,
                subtitleDelay: subtitleDelay,
                audioDelay: audioDelay,
                loopMode: VideoLoopMode(rawValue: loopMode) ?? .none,
                abLoop: abLoopStart.isFinite && abLoopEnd.isFinite
                    ? VideoABLoop(start: abLoopStart, end: abLoopEnd)
                    : nil,
                aspectRatio: VideoAspectRatio(rawValue: aspectRatio) ?? .automatic,
                rotation: rotation,
                videoDisplaySize: videoWidth > 0 && videoHeight > 0
                    ? CGSize(width: videoWidth, height: videoHeight)
                    : nil,
                videoRenderGeometry: snapshot.videoRenderGeometry,
                tracks: snapshot.tracks,
                chapters: snapshot.chapters
            )
            onSnapshotChanged?(snapshot)
            if errorMessage != nil {
                if isRemoteSourceLoaded {
                    onRemotePlaybackFailure?(.remoteLoadFailed)
                } else if let errorMessage {
                    onError?(errorMessage)
                }
            }
        }
        client?.videoGeometryHandler = {
            [weak self] osdWidth,
            osdHeight,
            topMargin,
            bottomMargin,
            leftMargin,
            rightMargin in
            guard let self else { return }
            snapshot.videoRenderGeometry = VideoRenderGeometry(
                osdSize: CGSize(width: osdWidth, height: osdHeight),
                topMargin: topMargin,
                bottomMargin: bottomMargin,
                leftMargin: leftMargin,
                rightMargin: rightMargin
            )
            onSnapshotChanged?(snapshot)
        }
        client?.trackHandler = { [weak self] tracks in
            guard let self else { return }
            snapshot.tracks = tracks.compactMap { track in
                let rawType = track.type == "sub" ? "subtitle" : track.type
                guard let type = VideoTrackType(rawValue: rawType) else {
                    return nil
                }
                return VideoTrack(
                    id: track.trackID,
                    type: type,
                    title: track.title,
                    language: track.language,
                    codec: track.codec,
                    ffIndex: track.ffIndex >= 0 ? track.ffIndex : nil,
                    externalFilename: track.externalFilename,
                    isImage: track.isImage,
                    isSelected: track.isSelected
                )
            }
            onSnapshotChanged?(snapshot)
        }
        client?.chapterHandler = { [weak self] chapters in
            guard let self else { return }
            snapshot.chapters = chapters.map {
                VideoChapter(
                    id: $0.chapterID,
                    title: $0.title,
                    startTime: $0.startTime
                )
            }
            onSnapshotChanged?(snapshot)
        }
        client?.subtitleCueHandler = { [weak self] cues in
            self?.onEmbeddedSubtitleCuesChanged?(cues.map {
                VideoEmbeddedSubtitleCue(
                    id: $0.cueID,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text
                )
            })
        }
        client?.playbackEndedHandler = { [weak self] in
            self?.onPlaybackEnded?()
        }
        client?.remoteAudioStateHandler = { [weak self] attached, _ in
            guard let self, !attached, isRemoteSourceLoaded else { return }
            onRemotePlaybackFailure?(.externalAudioUnavailable)
        }
    }

    isolated deinit {
        pendingRenderDetachTask?.cancel()
        client?.shutdown()
    }

    @discardableResult
    func attach(to view: HSMpvOpenGLView) -> Bool {
        if attachedRenderView === view { return true }
        guard let client, client.attach(to: view) else { return false }
        pendingRenderDetachTask?.cancel()
        pendingRenderDetachTask = nil
        renderDetachGeneration &+= 1
        attachedRenderView = view
        return true
    }

    func detachRenderView(ifAttachedTo view: HSMpvOpenGLView) {
        guard attachedRenderView === view else { return }
        attachedRenderView = nil
        pendingRenderDetachTask?.cancel()
        renderDetachGeneration &+= 1
        let generation = renderDetachGeneration
        pendingRenderDetachTask = Task { @MainActor [weak self] in
            // Give SwiftUI/AppKit a short, cancellable reconciliation window
            // to install a replacement representable before tearing down mpv.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled,
                  let self,
                  self.renderDetachGeneration == generation,
                  self.attachedRenderView == nil else {
                return
            }
            self.pendingRenderDetachTask = nil
            self.client?.detachFromView()
        }
    }

    func load(source: VideoPlaybackSource) throws {
        guard let client else {
            throw MpvPlayerEngineError.initializationFailed(
                initializationError ?? String(localized: "Unable to initialize video playback.")
            )
        }
        // A new mpv load removes any internal effects track. Invalidate the
        // Swift-side mode cache as part of the same boundary so a preserved
        // ASS overlay will reinstall its effects track after the new source
        // publishes tracks.
        client.setNativeSubtitleRenderingEnabled(false)
        client.clearASSSubtitleEffects()
        subtitleRenderingMode = .overlayOnly
        loadedSource = source
        snapshot.currentTime = 0
        snapshot.duration = 0
        snapshot.isPlaying = false
        snapshot.isLoaded = false
        snapshot.videoRenderGeometry = nil
        snapshot.tracks = []
        snapshot.chapters = []
        onSnapshotChanged?(snapshot)
        switch source {
        case .localFile(let url):
            client.loadFile(url)
        case .remoteStream(let remote):
            client.loadSourceURLString(
                remote.playbackStream.url.absoluteString,
                headers: remote.playbackStream.httpHeaders,
                audioURLString: remote.audioStream?.url.absoluteString,
                audioHeaders: remote.audioStream?.httpHeaders ?? [:]
            )
        }
    }

    func load(url: URL) throws {
        try load(source: .localFile(url))
    }

    func play() {
        client?.setPaused(false)
    }

    func pause() {
        client?.setPaused(true)
    }

    func seek(to time: TimeInterval) {
        client?.seek(to: time)
    }

    func setSpeed(_ speed: Double) {
        client?.setSpeed(speed)
    }

    func setVolume(_ volume: Double) {
        client?.setVolume(volume)
    }

    func setMuted(_ muted: Bool) {
        client?.setMuted(muted)
    }

    func setSubtitleDelay(_ delay: TimeInterval) {
        client?.setSubtitleDelay(delay)
    }

    func setAudioDelay(_ delay: TimeInterval) {
        client?.setAudioDelay(delay)
    }

    func setLoopMode(_ mode: VideoLoopMode) {
        client?.setLoopMode(mode.rawValue)
    }

    func setABLoop(_ loop: VideoABLoop?) {
        client?.setABLoopStart(
            loop.map { NSNumber(value: $0.start) },
            end: loop.map { NSNumber(value: $0.end) }
        )
    }

    func setAspectRatio(_ aspectRatio: VideoAspectRatio) {
        client?.setAspectRatio(aspectRatio.rawValue)
    }

    func setRotation(_ degrees: Int) {
        client?.setRotation(degrees)
    }

    func setHardwareDecodingEnabled(_ enabled: Bool) {
        client?.setHardwareDecodingEnabled(enabled)
    }

    func setDeinterlacingEnabled(_ enabled: Bool) {
        client?.setDeinterlacingEnabled(enabled)
    }

    func setHDREnhancementEnabled(_ enabled: Bool) {
        client?.setHDREnhancementEnabled(enabled)
    }

    func setVideoShaderPreset(_ preset: VideoShaderPreset) throws {
        guard appliedVideoShaderPreset != preset else { return }
        let shaderURLs = Anime4KShaderManager.shared.installedShaderURLs(for: preset)
        guard preset == .off || !shaderURLs.isEmpty else {
            throw MpvPlayerEngineError.videoShaderFailed(
                String(localized: "The selected Anime4K preset is not installed.")
            )
        }
        var errorMessage: NSString?
        guard client?.setVideoShaderURLs(shaderURLs, errorMessage: &errorMessage) == true else {
            throw MpvPlayerEngineError.videoShaderFailed(
                errorMessage as String? ?? String(localized: "Unable to apply Anime4K shaders.")
            )
        }
        appliedVideoShaderPreset = preset
    }

    func setVideoEqualizer(_ adjustment: VideoEqualizerAdjustment, value: Double) {
        client?.setVideoEqualizer(adjustment.rawValue, value: value)
    }

    func seekToChapter(_ index: Int) {
        client?.seek(toChapter: index)
    }

    func captureAmbientPreview(maximumDimension: Int) async -> VideoAmbientPreview? {
        guard let client else { return nil }
        return await withCheckedContinuation { continuation in
            client.captureAmbientPreview(withMaximumDimension: maximumDimension) { image, generation in
                guard let image else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: VideoAmbientPreview(
                        image: image,
                        generation: generation
                    )
                )
            }
        }
    }

    func captureScreenshot(to url: URL) async throws {
        var errorMessage: NSString?
        guard client?.captureScreenshot(to: url, errorMessage: &errorMessage) == true else {
            throw MpvPlayerEngineError.mediaExportFailed(
                errorMessage as String? ?? String(localized: "Unable to capture the video frame.")
            )
        }
    }

    func captureAnimatedScreenshot(
        from start: TimeInterval,
        to end: TimeInterval,
        quality: Double,
        fps: Int,
        maximumHeight: Int,
        rotation: Int,
        to url: URL
    ) async throws {
        guard let loadedSource else {
            throw MpvPlayerEngineError.mediaExportFailed(
                String(localized: "Unable to determine the video source for animated AVIF capture.")
            )
        }
        let sourceURL: URL
        let headers: [String: String]
        switch loadedSource {
        case .localFile(let url):
            sourceURL = url
            headers = [:]
        case .remoteStream(let source):
            sourceURL = source.playbackStream.url
            headers = source.playbackStream.httpHeaders
        }
        let displayRotation = rotation + Int(client?.sourceVideoRotation ?? 0)
        let result: (Bool, String?) = await Task.detached(priority: .userInitiated) {
            var errorMessage: NSString?
            let succeeded = HSMpvAnimatedAVIFExporter.exportAnimatedAVIF(
                from: sourceURL,
                headers: headers,
                startTime: start,
                endTime: end,
                fps: fps,
                maximumHeight: maximumHeight,
                rotation: displayRotation,
                quality: quality,
                to: url,
                errorMessage: &errorMessage
            )
            return (succeeded, errorMessage as String?)
        }.value
        guard result.0 else {
            throw MpvPlayerEngineError.mediaExportFailed(
                result.1 ?? String(localized: "The bundled animated AVIF encoder could not export this subtitle range.")
            )
        }
    }

    func exportAudioClip(
        from start: TimeInterval,
        to end: TimeInterval,
        to url: URL
    ) async throws {
        guard let loadedSource,
              let exportSource = loadedSource.audioExportSource(
                selectedAudioTrackID: snapshot.tracks.first(where: {
                    $0.type == .audio && $0.isSelected
                })?.id
              ) else {
            throw MpvPlayerEngineError.mediaExportFailed(
                String(localized: "Unable to determine the video audio range.")
            )
        }
        try await VideoAudioClipExporter.export(
            source: exportSource,
            from: start,
            to: end,
            outputURL: url
        )
    }

    private var isRemoteSourceLoaded: Bool {
        guard case .remoteStream = loadedSource else { return false }
        return true
    }

    func selectTrack(type: VideoTrackType, id: Int?) {
        client?.selectTrackType(type.rawValue, trackID: id.map(NSNumber.init(value:)))
    }

    func loadExternalSubtitle(url: URL) {
        client?.loadExternalSubtitle(url)
    }

    @discardableResult
    func configureSubtitleRendering(_ mode: VideoSubtitleRenderingMode) -> Bool {
        guard subtitleRenderingMode != mode else { return true }
        switch mode {
        case .overlayOnly, .preparingASS:
            client?.setNativeSubtitleRenderingEnabled(false)
            client?.clearASSSubtitleEffects()
            subtitleRenderingMode = mode
            return true
        case .nativeOnly:
            client?.setNativeSubtitleRenderingEnabled(false)
            client?.clearASSSubtitleEffects()
            client?.setNativeSubtitleRenderingEnabled(true)
            subtitleRenderingMode = mode
            return true
        case .splitASS(let effectsURL, let logicalTrackID):
            client?.setNativeSubtitleRenderingEnabled(false)
            var errorMessage: NSString?
            guard client?.installASSSubtitleEffects(
                from: effectsURL,
                logicalTrackID: logicalTrackID.map(NSNumber.init(value:)),
                errorMessage: &errorMessage
            ) == true else {
                client?.clearASSSubtitleEffects()
                client?.setNativeSubtitleRenderingEnabled(true)
                return false
            }
            client?.setNativeSubtitleRenderingEnabled(true)
            subtitleRenderingMode = mode
            return true
        }
    }

    func shutdown() {
        loadedSource = nil
        client?.shutdown()
    }
}
