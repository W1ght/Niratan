import AppKit
@preconcurrency import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Opening local, remote, dropped and playlist media.
extension VideoPlayerScreen {
    func handleFileImport(
        _ result: Result<[URL], any Error>,
        kind: VideoFileImportKind
    ) {
        switch kind {
        case .video:
            handleVideoImport(result)
        case .primarySubtitle:
            handleSubtitleImport(result)
        }
    }

    func handleVideoImport(
        _ result: Result<[URL], any Error>
    ) {
        if let url = try? result.get().first {
            openVideo(url)
        }
    }

    func openVideo(
        _ url: URL,
        subtitleURL: URL? = nil,
        startsFromBeginning: Bool = false
    ) {
        openVideo(
            .localFile(url),
            subtitleURL: subtitleURL,
            startsFromBeginning: startsFromBeginning
        )
    }

    func openVideo(
        _ source: VideoPlaybackSource,
        subtitleURL: URL? = nil,
        startsFromBeginning: Bool = false
    ) {
        cancelPendingRemoteVideoOpen()
        remoteVideoOpenErrorMessage = nil
        lookup.closeAll(player: model)
        invalidatePrimarySubtitleLoad()
        configureSubtitleRendering(.overlayOnly)
        subtitles.clear()
        selectedRemoteSubtitleID = nil
        selectedJimakuSubtitleID = nil
        selectedJimakuSubtitleName = nil
        selectedAJATTSubtitleID = nil
        selectedAJATTSubtitleName = nil
        remoteSubtitleGeneration &+= 1
        remoteSubtitleLoader.cancelAndCleanup()
        // Media server streams without server-side text subtitles carry their
        // tracks in the container, so they restore and default like local files.
        let usesRemoteSubtitleOptions: Bool
        if case .remoteStream(let remoteSource) = source {
            usesRemoteSubtitleOptions = !remoteSource.identity.isMediaServer
                || !remoteSource.subtitleOptions.isEmpty
        } else {
            usesRemoteSubtitleOptions = false
        }
        shouldSkipNextAutomaticSubtitleRestore = subtitleURL != nil || usesRemoteSubtitleOptions
        model.open(source, startsFromBeginning: startsFromBeginning)
        guard model.errorMessage == nil else {
            shouldSkipNextAutomaticSubtitleRestore = false
            return
        }
        if let subtitleURL {
            loadPrimarySubtitle(from: subtitleURL, loadIntoMpv: true)
        } else if usesRemoteSubtitleOptions, case .remoteStream(let remoteSource) = source {
            let rememberedSelection = model.consumePendingSubtitleSelection()
            if case .off = rememberedSelection {
                applySubtitlesOff(clearPrimary: true, rememberSelection: false)
                return
            }
            if case .externalDisabled = rememberedSelection {
                applySubtitlesOff(clearPrimary: true, rememberSelection: false)
                return
            }
            if case .external(let path) = rememberedSelection {
                let externalURL = URL(fileURLWithPath: path).standardizedFileURL
                if FileManager.default.fileExists(atPath: externalURL.path) {
                    loadPrimarySubtitle(
                        from: externalURL,
                        loadIntoMpv: !CatalogSubtitleStore.isManagedURL(externalURL),
                        rememberSelection: false
                    )
                    return
                }
            }
            let subtitle = rememberedSelection
                .flatMap { remoteSubtitle(selection: $0, in: remoteSource) }
                ?? preferredRemoteSubtitle(in: remoteSource)
            if let subtitle {
                loadRemoteSubtitle(subtitle, rememberSelection: false)
            }
        }
    }

    func selectRemoteQuality(_ option: RemoteVideoQualityOption) {
        guard case .remoteStream(let source) = model.currentSource,
              source.identity.supportsQualitySelection,
              option.id != selectedRemoteQualityID,
              let selectedSource = source.selectingQuality(id: option.id) else {
            return
        }
        shouldSkipNextAutomaticSubtitleRestore = true
        if !model.switchRemoteQuality(to: selectedSource) {
            shouldSkipNextAutomaticSubtitleRestore = false
        }
    }

    func openPlaylistEpisode(_ url: URL) {
        lookup.closeAll(player: model)
        invalidatePrimarySubtitleLoad()
        configureSubtitleRendering(.overlayOnly)
        subtitles.clear()
        selectedRemoteSubtitleID = nil
        selectedJimakuSubtitleID = nil
        selectedJimakuSubtitleName = nil
        selectedAJATTSubtitleID = nil
        selectedAJATTSubtitleName = nil
        remoteSubtitleGeneration &+= 1
        remoteSubtitleLoader.cancelAndCleanup()
        model.selectPlaylistItem(url)
    }

    func handleExternalOpenRequest(_ request: VideoWindowOpenRequest?) {
        guard let request,
              let readyRequest = openGate.receive(request) else { return }
        openExternalRequest(readyRequest)
    }

    func openExternalRequest(_ request: VideoWindowOpenRequest) {
        onConsumeOpenRequest(request.id)
        switch request.source {
        case .playback(let source):
            openVideo(
                source,
                subtitleURL: request.subtitleURL,
                startsFromBeginning: request.startsFromBeginning
            )
        case .unresolvedRemote(let remoteRequest):
            openRemoteVideo(remoteRequest)
        }
    }

    func openRemoteVideo(_ request: RemoteVideoWindowOpenRequest) {
        cancelPendingRemoteVideoOpen()
        remoteVideoOpenErrorMessage = nil
        isResolvingRemoteVideo = true
        remoteVideoOpenGeneration &+= 1
        let generation = remoteVideoOpenGeneration
        let resolver = RemoteVideoResolverRegistry()
        remoteVideoOpenTask = Task { @MainActor in
            do {
                let resolvedSource = try await resolver.resolve(
                    identity: request.identity,
                    preferredSubtitleLanguages: request.preferredSubtitleLanguages,
                    forceRefresh: request.forceRefresh
                )
                guard generation == remoteVideoOpenGeneration,
                      !Task.isCancelled else {
                    return
                }
                _ = VideoLibraryStore.shared.addRemoteItem(resolvedSource)
                isResolvingRemoteVideo = false
                remoteVideoOpenTask = nil
                openVideo(
                    .remoteStream(resolvedSource),
                    subtitleURL: nil,
                    startsFromBeginning: request.startsFromBeginning
                )
            } catch {
                guard generation == remoteVideoOpenGeneration else {
                    return
                }
                isResolvingRemoteVideo = false
                remoteVideoOpenTask = nil
                guard !Task.isCancelled,
                      !(error is CancellationError),
                      !Self.isRemoteResolutionCancellation(error) else {
                    return
                }
                remoteVideoOpenErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelPendingRemoteVideoOpen() {
        remoteVideoOpenGeneration &+= 1
        remoteVideoOpenTask?.cancel()
        remoteVideoOpenTask = nil
        isResolvingRemoteVideo = false
    }

    static func isRemoteResolutionCancellation(_ error: any Error) -> Bool {
        guard let resolverError = error as? RemoteVideoResolverError else {
            return false
        }
        if case .cancelled = resolverError {
            return true
        }
        return false
    }

    func handleDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let accumulator = DroppedFileURLAccumulator()

        for provider in fileProviders {
            group.enter()
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                defer { group.leave() }
                guard let url = Self.fileURL(from: item) else { return }
                accumulator.append(url.standardizedFileURL)
            }
        }

        group.notify(queue: .main) {
            Task { @MainActor in
                handleDroppedFileURLs(accumulator.urls())
            }
        }
        return true
    }

    func handleDroppedFileURLs(_ urls: [URL]) {
        let mediaURL = urls.first(where: isMediaFile)
        let subtitleURL = urls.first(where: isSubtitleFile)

        if let mediaURL {
            loadDroppedMedia(mediaURL, subtitleURL: subtitleURL)
        } else if let subtitleURL {
            loadDroppedSubtitle(subtitleURL)
        }
    }

    func presentFileImporter(_ kind: VideoFileImportKind) {
        activeFileImportKind = kind
        pendingFileImportKind = kind
    }
}
