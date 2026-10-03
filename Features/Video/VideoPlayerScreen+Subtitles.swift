import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Subtitle source loading, restore and track selection for the player.
// Rendering and on-screen chrome stay in VideoPlayerScreen.swift.
extension VideoPlayerScreen {
    func loadRemoteSubtitle(
        _ subtitle: RemoteVideoSubtitleOption,
        rememberSelection: Bool
    ) {
        selectedJimakuSubtitleID = nil
        selectedJimakuSubtitleName = nil
        selectedAJATTSubtitleID = nil
        selectedAJATTSubtitleName = nil
        invalidatePrimarySubtitleLoad()
        configureSubtitleRendering(.overlayOnly)
        subtitles.discardTemporaryASSEffects()
        subtitles.clearPrimary()
        model.selectTrack(type: .subtitle, id: nil)
        lastSelectedSubtitleTrackID = nil
        remoteSubtitleGeneration &+= 1
        let generation = remoteSubtitleGeneration
        Task { @MainActor in
            do {
                guard let tempURL = try await remoteSubtitleLoader.load(
                    option: subtitle,
                    generation: generation
                ), generation == remoteSubtitleGeneration else { return }
                await loadPrimarySubtitle(
                    from: tempURL,
                    loadIntoMpv: false,
                    rememberSelection: false
                ).value
                guard generation == remoteSubtitleGeneration,
                      subtitles.document?.sourceURL.standardizedFileURL
                        == tempURL.standardizedFileURL else { return }
                selectedRemoteSubtitleID = subtitle.id
                if rememberSelection {
                    model.rememberSubtitleSelection(
                        .remoteOption(subtitle.selectionIdentity)
                    )
                }
            } catch {
                guard !Task.isCancelled,
                      generation == remoteSubtitleGeneration else { return }
                subtitles.errorMessage = String(localized: "Unable to load the remote subtitle.")
            }
        }
    }

    func loadJimakuSubtitle(_ file: JimakuSubtitleFile) {
        loadCatalogSubtitle(
            option: file.remoteSubtitleOption,
            id: file.id,
            name: file.name,
            source: .jimaku
        )
    }

    func loadAJATTSubtitle(_ file: AJATTSubtitleFile) {
        loadCatalogSubtitle(
            option: file.remoteSubtitleOption,
            id: file.id,
            name: file.name,
            source: .ajatt
        )
    }

    func loadCatalogSubtitle(
        option: RemoteVideoSubtitleOption,
        id: String,
        name: String,
        source: CatalogSubtitleSource
    ) {
        invalidatePrimarySubtitleLoad()
        configureSubtitleRendering(.overlayOnly)
        subtitles.discardTemporaryASSEffects()
        subtitles.clearPrimary()
        model.selectTrack(type: .subtitle, id: nil)
        lastSelectedSubtitleTrackID = nil
        selectedRemoteSubtitleID = nil
        selectedJimakuSubtitleID = nil
        selectedJimakuSubtitleName = nil
        selectedAJATTSubtitleID = nil
        selectedAJATTSubtitleName = nil
        remoteSubtitleGeneration &+= 1
        let generation = remoteSubtitleGeneration
        guard let videoKey = model.currentMediaIdentity?.persistenceKey else { return }
        Task { @MainActor in
            do {
                guard let tempURL = try await remoteSubtitleLoader.load(
                    option: option,
                    allowedDownloadHosts: source.allowedDownloadHosts
                        ?? (source == .openSubtitles ? Set([option.url.host ?? ""]) : nil),
                    maximumResponseSize: source.maximumResponseSize,
                    generation: generation
                ), generation == remoteSubtitleGeneration,
                   model.currentMediaIdentity?.persistenceKey == videoKey else { return }
                // Keep a durable copy so the selection survives cleanup of the
                // remote loader's temporary directory and later sessions.
                let archivedURL = try CatalogSubtitleStore.archive(
                    fileAt: tempURL,
                    videoKey: videoKey,
                    fileName: name
                )
                model.rememberExternalSubtitlePath(archivedURL)
                await loadPrimarySubtitle(
                    from: archivedURL,
                    loadIntoMpv: false,
                    rememberSelection: false
                ).value
                guard generation == remoteSubtitleGeneration,
                      model.currentMediaIdentity?.persistenceKey == videoKey,
                      subtitles.document?.sourceURL.standardizedFileURL
                        == archivedURL.standardizedFileURL else { return }
                switch source {
                case .jimaku:
                    selectedJimakuSubtitleID = id
                    selectedJimakuSubtitleName = name
                case .ajatt:
                    selectedAJATTSubtitleID = id
                    selectedAJATTSubtitleName = name
                case .openSubtitles:
                    break // Restored through the shared durable external-subtitle selection.
                }
                model.rememberSubtitleSelection(
                    .external(path: archivedURL.standardizedFileURL.path)
                )
            } catch {
                guard !Task.isCancelled,
                      generation == remoteSubtitleGeneration else { return }
                subtitles.errorMessage = source.errorMessage
            }
        }
    }

    func preferredRemoteSubtitle(
        in source: ResolvedRemoteVideoSource
    ) -> RemoteVideoSubtitleOption? {
        source.preferredSubtitle(
            preferredLanguages: [source.selectedSubtitleLanguage].compactMap { $0 },
            fallbackLanguages: ["ja", "en"]
        )
    }

    func performCatalogSubtitleMaintenance() {
        let referencedFilePaths = model.rememberedExternalSubtitlePaths()
        Task.detached(priority: .utility) {
            CatalogSubtitleStore.performMaintenanceIfNeeded(
                referencedFilePaths: referencedFilePaths
            )
        }
    }

    func restoreRememberedExternalSubtitle() {
        let currentExternalURL = subtitles.document.flatMap {
            $0.format == .embedded ? nil : $0.sourceURL
        }
        guard let subtitleURL = currentExternalURL ?? model.rememberedExternalSubtitleURL,
              FileManager.default.fileExists(atPath: subtitleURL.path) else {
            return
        }
        loadPrimarySubtitle(
            from: subtitleURL,
            loadIntoMpv: !CatalogSubtitleStore.isManagedURL(subtitleURL),
            rememberSelection: true
        )
    }

    func remoteSubtitle(
        selection: VideoSubtitleSelection,
        in source: ResolvedRemoteVideoSource
    ) -> RemoteVideoSubtitleOption? {
        switch selection {
        case .remoteOption(let identity):
            source.subtitleOption(matching: identity)
        case .remote(let language):
            source.preferredSubtitle(language: language)
        default:
            nil
        }
    }

    func autoloadSubtitleIfAvailable(for mediaURL: URL) {
        guard let subtitleURL = VideoSubtitleAutoloadCandidate.bestCandidate(for: mediaURL) else {
            isAwaitingEmbeddedSubtitleDefault = true
            applyEmbeddedSubtitleDefaultIfReady()
            return
        }
        // Load the sidecar the same way as a remembered external selection so
        // mpv selects it (reusing its own `sub-auto` track) and the inspector
        // shows the active track on first open.
        loadPrimarySubtitle(from: subtitleURL, loadIntoMpv: true)
    }

    /// Without a remembered choice or sidecar, enables the Japanese embedded
    /// track once mpv has published the complete track list.
    func applyEmbeddedSubtitleDefaultIfReady() {
        guard isAwaitingEmbeddedSubtitleDefault, model.snapshot.isLoaded else { return }
        isAwaitingEmbeddedSubtitleDefault = false
        guard subtitles.document == nil,
              !model.snapshot.tracks.contains(where: { $0.type == .subtitle && $0.isSelected }),
              let track = VideoEmbeddedSubtitleDefault.preferredTrack(in: model.snapshot.tracks) else {
            return
        }
        selectSubtitleTrack(track.id, rememberSelection: false, showOSD: false)
    }

    func handleSubtitleImport(
        _ result: Result<[URL], any Error>
    ) {
        if let url = try? result.get().first {
            lookup.closeAll(player: model)
            loadPrimarySubtitle(from: url, loadIntoMpv: true)
        }
    }

    @discardableResult
    func loadPrimarySubtitle(
        from url: URL,
        loadIntoMpv: Bool,
        rememberSelection: Bool = true
    ) -> Task<Void, Never> {
        isAwaitingEmbeddedSubtitleDefault = false
        if rememberSelection {
            selectedRemoteSubtitleID = nil
            selectedJimakuSubtitleID = nil
            selectedJimakuSubtitleName = nil
            selectedAJATTSubtitleID = nil
            selectedAJATTSubtitleName = nil
        }
        cancelSubtitleTrackExtraction()
        primarySubtitleLoadGeneration &+= 1
        let loadGeneration = primarySubtitleLoadGeneration
        isLoadingPrimarySubtitle = true
        let selectedTrack = model.snapshot.tracks.first {
            $0.type == .subtitle && $0.isSelected
        }
        let initialMode: VideoSubtitleRenderingMode = loadIntoMpv
            ? VideoSubtitleRenderingPolicy.initialMode(forSubtitleURL: url)
            : .overlayOnly
        configureSubtitleRendering(initialMode)
        subtitles.clearPrimary()
        if CatalogSubtitleStore.isManagedURL(url), !loadIntoMpv {
            model.selectTrack(type: .subtitle, id: nil)
        }
        if loadIntoMpv {
            model.loadExternalSubtitle(url)
        }
        let loadTask = subtitles.load(url)
        return Task { @MainActor in
            await loadTask.value
            guard loadGeneration == primarySubtitleLoadGeneration else { return }
            isLoadingPrimarySubtitle = false
            if subtitles.document?.sourceURL.standardizedFileURL
                == url.standardizedFileURL {
                areSubtitlesVisible = true
                if CatalogSubtitleStore.isManagedURL(url), !loadIntoMpv {
                    // Keep the parsed, interactive document authoritative before
                    // registering the selectable track and ASS effects renderer.
                    model.loadExternalSubtitle(url)
                }
                let logicalTrackID: Int?
                if loadIntoMpv || CatalogSubtitleStore.isManagedURL(url) {
                    logicalTrackID = nil
                } else {
                    logicalTrackID = model.snapshot.tracks.first {
                        $0.type == .subtitle && $0.isSelected
                    }?.id ?? selectedTrack?.id
                }
                applyPreparedSubtitleRendering(logicalTrackID: logicalTrackID)
                if CatalogSubtitleStore.isManagedURL(url) {
                    model.rememberExternalSubtitlePath(url)
                }
                if rememberSelection {
                    model.rememberSubtitleSelection(
                        .external(path: url.standardizedFileURL.path)
                    )
                }
            } else if initialMode == .preparingASS {
                // Preparation owns the transition: keep the original ASS
                // hidden until parsing completes, then atomically fall back
                // to libass if no interactive document was produced.
                configureSubtitleRendering(.nativeOnly)
            }
            subtitles.update(
                time: model.snapshot.currentTime,
                subtitleDelay: model.snapshot.subtitleDelay
            )
        }
    }

    func loadDroppedSubtitle(_ subtitleURL: URL) {
        guard model.currentURL != nil else { return }
        lookup.closeAll(player: model)
        loadPrimarySubtitle(from: subtitleURL, loadIntoMpv: true)
    }

    func isSubtitleFile(_ url: URL) -> Bool {
        Self.subtitleFileExtensions.contains(url.pathExtension.lowercased())
    }

    func restorePendingHistorySubtitleTrackIfAvailable() {
        guard let trackID = pendingHistoryEmbeddedSubtitleTrackID,
              model.snapshot.tracks.contains(where: {
                  $0.type == .subtitle && $0.id == trackID
              }) else {
            return
        }
        pendingHistoryEmbeddedSubtitleTrackID = nil
        selectSubtitleTrack(trackID, rememberSelection: true, showOSD: false)
    }

    func restoreRememberedSubtitleSelectionOrAutoload() {
        guard model.pendingSubtitleSelection != nil,
              let mediaURL = model.currentURL else {
            return
        }
        restoreRememberedSubtitleSelectionOrAutoload(for: mediaURL)
    }

    func restorePreservedSubtitleRenderingAfterMediaReload() {
        guard let document = subtitles.document else {
            configureSubtitleRendering(.overlayOnly)
            return
        }
        guard document.assRenderPlan != nil else {
            configureSubtitleRendering(.overlayOnly)
            return
        }

        // A source reload removes mpv's external/internal subtitle tracks.
        // Keep ASS hit targets disabled until the original logical track is
        // back, then the next track snapshot reinstalls the filtered effects
        // track through `synchronizeSelectedSubtitleTrack()`.
        configureSubtitleRendering(.nativeOnly)
        if document.format == .ass || document.format == .ssa {
            model.loadExternalSubtitle(document.sourceURL)
        }
    }

    func restoreRememberedSubtitleSelectionOrAutoload(
        for mediaURL: URL
    ) {
        guard let selection = model.pendingSubtitleSelection else {
            autoloadSubtitleIfAvailable(for: mediaURL)
            return
        }
        let resolution = VideoSubtitleRestoreResolver.resolve(
            selection: selection,
            tracks: model.snapshot.tracks,
            isLoaded: model.snapshot.isLoaded
        )
        switch resolution {
        case .off:
            _ = model.consumePendingSubtitleSelection()
            applySubtitlesOff(clearPrimary: true, rememberSelection: false)
        case .external(let subtitleURL):
            _ = model.consumePendingSubtitleSelection()
            loadPrimarySubtitle(
                from: subtitleURL,
                loadIntoMpv: !CatalogSubtitleStore.isManagedURL(subtitleURL),
                rememberSelection: false
            )
        case .externalDisabled:
            _ = model.consumePendingSubtitleSelection()
            applySubtitlesOff(clearPrimary: true, rememberSelection: false)
        case .embeddedTrack(let trackID):
            _ = model.consumePendingSubtitleSelection()
            selectSubtitleTrack(trackID, rememberSelection: false, showOSD: false)
        case .remoteLanguage(let language):
            _ = model.consumePendingSubtitleSelection()
            guard case .remoteStream(let source) = model.currentSource,
                  let subtitle = source.preferredSubtitle(language: language) else {
                autoloadSubtitleIfAvailable(for: mediaURL)
                return
            }
            loadRemoteSubtitle(subtitle, rememberSelection: false)
        case .remoteOption(let identity):
            _ = model.consumePendingSubtitleSelection()
            guard case .remoteStream(let source) = model.currentSource,
                  let subtitle = source.subtitleOption(matching: identity) else {
                autoloadSubtitleIfAvailable(for: mediaURL)
                return
            }
            loadRemoteSubtitle(subtitle, rememberSelection: false)
        case .waitingForTracks:
            break
        case .unavailable:
            _ = model.consumePendingSubtitleSelection()
            autoloadSubtitleIfAvailable(for: mediaURL)
        }
    }

    func selectSubtitleTrack(
        _ trackID: Int,
        rememberSelection: Bool,
        showOSD: Bool = true
    ) {
        isAwaitingEmbeddedSubtitleDefault = false
        guard let track = model.snapshot.tracks.first(where: {
            $0.type == .subtitle && $0.id == trackID
        }) else {
            return
        }
        lastSelectedSubtitleTrackID = trackID
        if let filename = track.externalFilename, !filename.isEmpty {
            loadPrimarySubtitle(
                from: URL(fileURLWithPath: filename),
                loadIntoMpv: true,
                rememberSelection: rememberSelection
            )
            if showOSD { showSubtitleTrackOSD(track: track) }
            return
        }
        if track.isSelected && areSubtitlesVisible && subtitles.document?.format == .embedded {
            synchronizeSelectedSubtitleTrack()
        } else {
            areSubtitlesVisible = true
            cancelSubtitleTrackExtraction()
            invalidatePrimarySubtitleLoad()
            selectedRemoteSubtitleID = nil
            selectedJimakuSubtitleID = nil
            selectedJimakuSubtitleName = nil
            selectedAJATTSubtitleID = nil
            selectedAJATTSubtitleName = nil
            configureSubtitleRendering(VideoSubtitleRenderingPolicy.initialMode(for: track))
            subtitles.clearPrimary()
            model.selectTrack(type: .subtitle, id: trackID)
        }
        if showOSD {
            showSubtitleTrackOSD(track: track)
        }
        guard rememberSelection else { return }
        if let filename = track.externalFilename, !filename.isEmpty {
            model.rememberSubtitleSelection(
                .external(path: URL(fileURLWithPath: filename).standardizedFileURL.path)
            )
        } else {
            model.rememberSubtitleSelection(
                .embedded(VideoSubtitleTrackIdentity(track: track))
            )
        }
    }

    func applySubtitlesOff(
        clearPrimary: Bool,
        rememberSelection: Bool
    ) {
        isAwaitingEmbeddedSubtitleDefault = false
        remoteSubtitleGeneration &+= 1
        if let selectedID = model.snapshot.tracks.first(where: {
            $0.type == .subtitle && $0.isSelected
        })?.id {
            lastSelectedSubtitleTrackID = selectedID
        }
        let catalogSubtitlePath = subtitles.document
            .flatMap { document -> String? in
                guard document.format != .embedded,
                      CatalogSubtitleStore.isManagedURL(document.sourceURL) else {
                    return nil
                }
                return document.sourceURL.standardizedFileURL.path
            }
        cancelSubtitleTrackExtraction()
        invalidatePrimarySubtitleLoad()
        subtitles.cancelPendingPrimaryLoad()
        configureSubtitleRendering(.overlayOnly)
        if clearPrimary {
            subtitles.clearPrimary()
            selectedRemoteSubtitleID = nil
            selectedJimakuSubtitleID = nil
            selectedJimakuSubtitleName = nil
            selectedAJATTSubtitleID = nil
            selectedAJATTSubtitleName = nil
        }
        subtitles.discardTemporaryASSEffects()
        model.selectTrack(type: .subtitle, id: nil)
        areSubtitlesVisible = false
        if rememberSelection {
            if let catalogSubtitlePath {
                model.rememberSubtitleSelection(
                    .externalDisabled(path: catalogSubtitlePath)
                )
            } else {
                model.rememberSubtitleSelection(.off)
            }
        }
    }

    func toggleSubtitlesVisible() {
        if areSubtitlesVisible {
            lastSelectedSubtitleTrackID = model.snapshot.tracks
                .first { $0.type == .subtitle && $0.isSelected }?
                .id
            applySubtitlesOff(clearPrimary: false, rememberSelection: true)
            showSubtitleVisibilityOSD(isVisible: areSubtitlesVisible)
        } else {
            if subtitles.document == nil,
               model.rememberedExternalSubtitleURL != nil,
               lastSelectedSubtitleTrackID == nil {
                restoreRememberedExternalSubtitle()
                return
            }
            if let document = subtitles.document,
               document.format != .embedded {
                areSubtitlesVisible = true
                if let trackID = lastSelectedSubtitleTrackID,
                   model.snapshot.tracks.contains(where: {
                       $0.type == .subtitle && $0.id == trackID
                   }) {
                    model.selectTrack(type: .subtitle, id: trackID)
                }
                applyPreparedSubtitleRendering(
                    logicalTrackID: lastSelectedSubtitleTrackID
                )
                if let selectedRemoteSubtitleID,
                   let option = currentRemoteSubtitleOptions.first(where: {
                       $0.id == selectedRemoteSubtitleID
                   }) {
                    model.rememberSubtitleSelection(
                        .remoteOption(option.selectionIdentity)
                    )
                } else {
                    model.rememberSubtitleSelection(
                        .external(path: document.sourceURL.standardizedFileURL.path)
                    )
                }
                showSubtitleVisibilityOSD(isVisible: areSubtitlesVisible)
                return
            }
            let subtitleTracks = model.snapshot.tracks.filter { $0.type == .subtitle }
            let trackID = lastSelectedSubtitleTrackID
                .flatMap { id in subtitleTracks.first { $0.id == id }?.id }
                ?? subtitleTracks.first?.id
            if let trackID {
                selectSubtitleTrack(trackID, rememberSelection: true, showOSD: false)
                showSubtitleVisibilityOSD(isVisible: areSubtitlesVisible)
            }
        }
    }

    func cycleSubtitleTrack() -> Bool {
        let subtitleTracks = model.snapshot.tracks.filter { $0.type == .subtitle }
        guard !subtitleTracks.isEmpty else { return false }
        guard areSubtitlesVisible else {
            let trackID = lastSelectedSubtitleTrackID
                .flatMap { id in subtitleTracks.first { $0.id == id }?.id }
                ?? subtitleTracks.first?.id
            if let trackID {
                selectSubtitleTrack(trackID, rememberSelection: true)
            }
            return true
        }
        if let selectedIndex = subtitleTracks.firstIndex(where: \.isSelected) {
            let nextIndex = subtitleTracks.index(after: selectedIndex)
            if nextIndex < subtitleTracks.endIndex {
                let id = subtitleTracks[nextIndex].id
                selectSubtitleTrack(id, rememberSelection: true)
            } else {
                lastSelectedSubtitleTrackID = subtitleTracks[selectedIndex].id
                applySubtitlesOff(clearPrimary: false, rememberSelection: true)
                showSubtitleTrackOSD(track: nil)
            }
        } else {
            let id = subtitleTracks[0].id
            selectSubtitleTrack(id, rememberSelection: true)
        }
        return true
    }

    func installEmbeddedSubtitleHandler() {
        model.engine.onEmbeddedSubtitleCuesChanged = { cues in
            guard let sourceURL = model.currentURL else { return }
            subtitles.loadEmbedded(cues, sourceURL: sourceURL)
            subtitles.update(
                time: model.snapshot.currentTime,
                subtitleDelay: model.snapshot.subtitleDelay
            )
        }
    }

    func synchronizeSelectedSubtitleTrack() {
        guard !isLoadingPrimarySubtitle else { return }
        guard let videoURL = model.currentURL else {
            cancelSubtitleTrackExtraction()
            return
        }
        guard let track = model.snapshot.tracks.first(where: {
            $0.type == .subtitle && $0.isSelected
        }) else {
            cancelSubtitleTrackExtraction()
            if areSubtitlesVisible, let document = subtitles.document,
               document.format != .embedded {
                // Catalog imports own their interactive document independently
                // of mpv's selected track, as in 1.6.4.
                applyPreparedSubtitleRendering(logicalTrackID: nil)
            } else {
                configureSubtitleRendering(.overlayOnly)
            }
            if subtitles.document?.format == .embedded,
               model.subtitlePreservingLoadGeneration != model.loadGeneration {
                subtitles.clearPrimary()
            }
            return
        }
        if let format = subtitles.document?.format, format != .embedded {
            if subtitles.document?.assRenderPlan != nil {
                applyPreparedSubtitleRendering(logicalTrackID: track.id)
            } else {
                configureSubtitleRendering(VideoSubtitleRenderingPolicy.initialMode(for: track))
            }
            return
        }

        let key = [
            videoURL.standardizedFileURL.path,
            String(track.id),
            String(track.ffIndex ?? -1),
            track.externalFilename ?? ""
        ].joined(separator: "|")
        guard key != activeSubtitleTrackExtractionKey else {
            if subtitles.document?.assRenderPlan != nil {
                applyPreparedSubtitleRendering(logicalTrackID: track.id)
            } else if VideoSubtitleRenderingPolicy.initialMode(for: track) == .preparingASS,
                      subtitles.transcriptErrorMessage != nil {
                // Keep a failed extraction on its native fallback instead of
                // re-entering the hidden preparation state on track updates.
                configureSubtitleRendering(.nativeOnly)
            } else {
                configureSubtitleRendering(VideoSubtitleRenderingPolicy.initialMode(for: track))
            }
            return
        }

        // Clear a split effects track before `beginEmbeddedTrack` releases
        // its temporary file. A changed extraction key belongs to the new
        // media/track even when mpv reused the same transient track ID.
        configureSubtitleRendering(VideoSubtitleRenderingPolicy.initialMode(for: track))
        subtitleTrackExtractionTask?.cancel()
        activeSubtitleTrackExtractionKey = key
        subtitles.beginEmbeddedTrack(trackID: track.id, sourceURL: videoURL)

        subtitleTrackExtractionTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    let isCancelled: @Sendable () -> Bool = {
                        withUnsafeCurrentTask { $0?.isCancelled ?? false }
                    }
                    let extractedTrack = try VideoSubtitleTrackExtractor.extract(
                        videoURL: videoURL,
                        track: track,
                        isCancelled: isCancelled
                    )
                    guard !isCancelled() else {
                        return SubtitleTrackExtractionOutcome.cancelled
                    }
                    let load = try VideoSubtitleController.prepareEmbeddedTranscript(
                        extractedTrack,
                        sourceURL: videoURL,
                        isCancelled: isCancelled
                    )
                    guard !isCancelled() else {
                        load.discardTemporaryResources()
                        return SubtitleTrackExtractionOutcome.cancelled
                    }
                    return SubtitleTrackExtractionOutcome.success(load)
                } catch is CancellationError {
                    return SubtitleTrackExtractionOutcome.cancelled
                } catch {
                    return SubtitleTrackExtractionOutcome.failure(
                        error.localizedDescription
                    )
                }
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  activeSubtitleTrackExtractionKey == key else {
                if case .success(let load) = outcome {
                    load.discardTemporaryResources()
                }
                return
            }
            switch outcome {
            case .success(let load):
                subtitles.replaceEmbeddedTranscript(
                    load,
                    trackID: track.id
                )
                applyPreparedSubtitleRendering(logicalTrackID: track.id)
                subtitles.update(
                    time: model.snapshot.currentTime,
                    subtitleDelay: model.snapshot.subtitleDelay
                )
            case .failure(let message):
                subtitles.failEmbeddedTranscript(message, trackID: track.id)
                if let codec = track.codec?.lowercased(),
                   codec == "ass" || codec == "ssa" {
                    configureSubtitleRendering(.nativeOnly)
                    subtitles.errorMessage = String(
                        localized: "Unable to prepare interactive ASS subtitles. The original subtitle will be shown instead."
                    )
                }
            case .cancelled:
                break
            }
        }
    }

    func cancelSubtitleTrackExtraction() {
        subtitleTrackExtractionTask?.cancel()
        subtitleTrackExtractionTask = nil
        activeSubtitleTrackExtractionKey = nil
    }

    func invalidatePrimarySubtitleLoad() {
        primarySubtitleLoadGeneration &+= 1
        isLoadingPrimarySubtitle = false
    }

    func applyPreparedSubtitleRendering(logicalTrackID: Int?) {
        guard areSubtitlesVisible else {
            configureSubtitleRendering(.overlayOnly)
            return
        }
        guard let document = subtitles.document else {
            configureSubtitleRendering(.overlayOnly)
            return
        }
        guard let renderPlan = document.assRenderPlan else {
            let mode: VideoSubtitleRenderingMode
            switch document.format {
            case .ass, .ssa:
                mode = .nativeOnly
            case .srt, .webVTT, .embedded:
                mode = .overlayOnly
            }
            configureSubtitleRendering(mode)
            return
        }
        // As in Fushi, every parsed ASS text event is drawn by the same layer
        // that owns glyph hit testing, including positioned/lyric/KFX text.
        // Never replace it with an unselectable libass primary track.
        if userConfig.videoRespectASSStyle,
           renderPlan.interactiveEffectsOnlyData != nil,
           subtitles.prepareTemporaryASSEffectsIfNeeded(),
           let effectsURL = subtitles.assEffectsURL {
            if !model.configureSubtitleRendering(.splitASS(effectsURL: effectsURL, logicalTrackID: logicalTrackID)) {
                // Non-text effects are best effort; a renderer failure must
                // never take away the visible, selectable text.
                configureSubtitleRendering(.overlayOnly)
            } else {
                subtitleRenderingMode = .splitASS(effectsURL: effectsURL, logicalTrackID: logicalTrackID)
            }
            return
        }
        configureSubtitleRendering(.overlayOnly)
    }

    @discardableResult
    func configureSubtitleRendering(_ mode: VideoSubtitleRenderingMode) -> Bool {
        guard model.configureSubtitleRendering(mode) else {
            if case .splitASS = mode {
                subtitles.markASSEffectsInstallationFailed()
            }
            subtitleRenderingMode = .nativeOnly
            _ = model.configureSubtitleRendering(.nativeOnly)
            subtitles.errorMessage = String(
                localized: "Unable to prepare interactive ASS subtitles. The original subtitle will be shown instead."
            )
            return false
        }
        subtitleRenderingMode = mode
        return true
    }
}
