import AppKit
@preconcurrency import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Card mining, mining history navigation and the study sidebar.
extension VideoPlayerScreen {
    func mineCurrentSubtitle() {
        guard userConfig.videoMiningHistoryLimit > 0 else {
            showMiningHistoryNotice(.disabled)
            return
        }
        guard let videoURL = model.currentURL,
              let document = subtitles.document,
              !subtitles.currentCues.isEmpty else {
            showMiningHistoryNotice(.noSubtitle)
            return
        }

        let embeddedTrackID = document.format == .embedded
            ? model.snapshot.tracks.first {
                $0.type == .subtitle && $0.isSelected
            }?.id
            : nil
        let remoteIdentity: RemoteVideoIdentity? = {
            guard case .remoteStream(let source) = model.currentSource else { return nil }
            return source.identity
        }()
        guard miningHistory.record(
            cues: subtitles.currentCues,
            document: document,
            videoURL: videoURL,
            videoTitle: model.currentTitle ?? videoURL.lastPathComponent,
            mediaIdentity: model.currentMediaIdentity,
            remoteVideoIdentity: remoteIdentity,
            embeddedSubtitleTrackID: embeddedTrackID
        ) != nil else {
            showMiningHistoryNotice(.disabled)
            return
        }
        showMiningHistoryNotice(.saved)
    }

    func navigateToHistoryItem(_ item: VideoMiningHistoryItem) {
        let resolution = VideoMiningHistoryNavigationResolver.resolve(
            item: item,
            currentVideoURL: model.currentURL,
            subtitleDelay: model.snapshot.subtitleDelay
        )
        switch resolution {
        case .missingVideo:
            model.errorMessage = String(
                localized: "The saved video file is no longer available. Open it again to continue."
            )
        case .missingSubtitle:
            model.errorMessage = String(
                localized: "The saved subtitle file is no longer available. Open it again to continue."
            )
        case .legacySourceUnavailable:
            model.errorMessage = String(
                localized: "Open the matching video before using this older Mining History item."
            )
        case .ready(let destination):
            restoreHistoryDestination(destination)
        }
    }

    func restoreHistoryDestination(_ destination: VideoMiningHistoryDestination) {
        let wasPlaying = model.snapshot.isPlaying
        dismissVideoPopupsIfNeeded()
        miningHistoryNavigationTask?.cancel()
        miningHistoryNavigationGeneration &+= 1
        let generation = miningHistoryNavigationGeneration
        miningHistoryNavigationTask = Task { @MainActor in
            let destinationIdentity: VideoMediaIdentity
            let playbackSource: VideoPlaybackSource?
            switch destination.media {
            case .localFile(let url):
                destinationIdentity = .localFile(path: url.standardizedFileURL.path)
                playbackSource = .localFile(url)
            case .remote(let identity):
                destinationIdentity = identity.mediaIdentity
                if model.currentMediaIdentity == identity.mediaIdentity {
                    playbackSource = model.currentSource
                } else {
                    do {
                        let resolved = try await RemoteVideoResolverRegistry().resolve(
                            identity: identity
                        )
                        guard !Task.isCancelled,
                              generation == miningHistoryNavigationGeneration else { return }
                        playbackSource = .remoteStream(resolved)
                    } catch {
                        guard !Task.isCancelled,
                              generation == miningHistoryNavigationGeneration else { return }
                        model.errorMessage = error.localizedDescription
                        return
                    }
                }
            }
            let isChangingVideo = model.currentMediaIdentity != destinationIdentity
            if isChangingVideo {
                guard let playbackSource else { return }
                shouldSkipNextAutomaticSubtitleRestore = true
                openVideo(playbackSource, subtitleURL: destination.subtitleURL)
                guard model.errorMessage == nil else {
                    shouldSkipNextAutomaticSubtitleRestore = false
                    return
                }
                for _ in 0..<100 where !model.snapshot.isLoaded {
                    try? await Task.sleep(for: .milliseconds(10))
                    guard !Task.isCancelled,
                          generation == miningHistoryNavigationGeneration else { return }
                }
            }

            if let trackID = destination.embeddedSubtitleTrackID {
                pendingHistoryEmbeddedSubtitleTrackID = trackID
                restorePendingHistorySubtitleTrackIfAvailable()
            }

            if let subtitleURL = destination.subtitleURL,
               subtitles.document?.sourceURL.standardizedFileURL != subtitleURL {
                await loadPrimarySubtitle(
                    from: subtitleURL,
                    loadIntoMpv: true
                ).value
            }

            model.seek(to: destination.seekTime)
            subtitles.update(
                time: destination.seekTime,
                subtitleDelay: model.snapshot.subtitleDelay
            )
            areSubtitlesVisible = true

            if wasPlaying {
                model.engine.play()
            } else {
                model.engine.pause()
            }
        }
    }

    func copyMiningHistorySubtitle(_ item: VideoMiningHistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.subtitleText, forType: .string)
        showMiningHistoryNotice(.copied)
    }

    func showMiningHistoryNotice(_ notice: VideoMiningHistoryNotice) {
        miningHistoryNoticeTask?.cancel()
        withAnimation(.smooth(duration: 0.18)) {
            miningHistoryNotice = notice
        }
        miningHistoryNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.18)) {
                miningHistoryNotice = nil
            }
        }
    }

    func videoMiningHistoryNotice(
        _ notice: VideoMiningHistoryNotice
    ) -> some View {
        Label(notice.title, systemImage: notice.systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: Capsule())
    }

    func seekRelativeSubtitleCue(offset: Int) -> Bool {
        guard let targetIndex = subtitles.transcript.relativeRowIndex(
            atPlaybackTime: model.snapshot.currentTime,
            subtitleDelay: model.snapshot.subtitleDelay,
            offset: offset
        ) else {
            return false
        }
        model.seek(
            to: subtitles.transcript.rows[targetIndex].startTime
                + model.snapshot.subtitleDelay
        )
        return true
    }

    func toggleMiningHistory() {
        videoScreenLog.info(
            "Toggling video mining history visible=\(self.isMiningHistoryVisible)"
        )
        if isMiningHistoryVisible, selectedStudySidebarTab == .history {
            isMiningHistoryVisible = false
        } else {
            selectedStudySidebarTab = .history
            isMiningHistoryVisible = true
        }
    }

    func toggleTranscriptSidebar() {
        dismissVideoPopupsThen {
            if isMiningHistoryVisible, selectedStudySidebarTab == .transcript {
                isMiningHistoryVisible = false
            } else {
                selectedStudySidebarTab = .transcript
                isMiningHistoryVisible = true
                isInspectorVisible = false
            }
        }
    }
}
