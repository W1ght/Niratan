import AppKit
@preconcurrency import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// On-screen feedback for playback adjustments.
extension VideoPlayerScreen {
    func setSpeedWithOSD(_ speed: Double) {
        let normalizedSpeed = VideoPlaybackSpeed.normalized(speed)
        model.setSpeed(normalizedSpeed)
        showSpeedOSD(normalizedSpeed)
    }

    func setVolumeWithOSD(_ volume: Double) {
        let clampedVolume = min(max(volume, 0), 100)
        model.setVolume(clampedVolume)
        showVolumeOSD(clampedVolume)
    }

    func toggleMuteWithOSD() {
        let isMuted = !model.snapshot.isMuted
        model.toggleMuted()
        showMuteOSD(isMuted: isMuted)
    }

    func setSubtitleDelayWithOSD(_ delay: TimeInterval) {
        let clampedDelay = VideoSubtitleTiming.clampedDelay(delay)
        model.setSubtitleDelay(clampedDelay)
        showSubtitleDelayOSD(clampedDelay)
    }

    func adjustSubtitleDelayWithOSD(by delta: TimeInterval) {
        setSubtitleDelayWithOSD(model.snapshot.subtitleDelay + delta)
    }

    func subtitleAlignmentDelay(
        _ direction: SubtitleOffsetAlignmentDirection
    ) -> TimeInterval? {
        subtitles.delayAligningAdjacentCue(
            atPlaybackTime: model.snapshot.currentTime,
            subtitleDelay: model.snapshot.subtitleDelay,
            direction: direction
        )
    }

    @discardableResult
    func alignAdjacentSubtitleToCurrentTime(
        _ direction: SubtitleOffsetAlignmentDirection
    ) -> Bool {
        guard let delay = subtitleAlignmentDelay(direction) else { return false }
        dismissVideoPopupsIfNeeded()
        setSubtitleDelayWithOSD(delay)
        return true
    }

    func setAudioDelayWithOSD(_ delay: TimeInterval) {
        let clampedDelay = min(
            max(delay, Self.audioDelayRange.lowerBound),
            Self.audioDelayRange.upperBound
        )
        model.setAudioDelay(clampedDelay)
        showAudioDelayOSD(clampedDelay)
    }

    func adjustAudioDelayWithOSD(by delta: TimeInterval) {
        setAudioDelayWithOSD(model.snapshot.audioDelay + delta)
    }

    func showVideoOSD(_ item: VideoOnScreenDisplayItem) {
        videoOSDTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            videoOSD = item
        }
        videoOSDTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.35))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                videoOSD = nil
            }
            videoOSDTask = nil
        }
    }

    func showSpeedOSD(_ speed: Double) {
        showVideoOSD(
            VideoOnScreenDisplayItem(
                title: "Speed",
                value: VideoPlaybackSpeed.label(speed)
            )
        )
    }

    func showVolumeOSD(_ volume: Double) {
        let clampedVolume = min(max(volume, 0), 100)
        showVideoOSD(
            VideoOnScreenDisplayItem(
                title: "Volume",
                value: String(Int(clampedVolume.rounded())),
                meterProgress: clampedVolume / 100
            )
        )
    }

    func showMuteOSD(isMuted: Bool) {
        showVideoOSD(
            VideoOnScreenDisplayItem(
                title: "Volume",
                value: isMuted ? String(localized: "Muted") : String(localized: "Unmuted"),
                meterProgress: isMuted ? 0 : min(max(model.snapshot.volume, 0), 100) / 100
            )
        )
    }

    func showSubtitleVisibilityOSD(isVisible: Bool) {
        showVideoOSD(
            VideoOnScreenDisplayItem(
                title: "Subtitles",
                value: isVisible ? String(localized: "On") : String(localized: "Off")
            )
        )
    }

    func showSubtitleTrackOSD(track: VideoTrack?) {
        showVideoOSD(
            VideoOnScreenDisplayItem(
                title: "Subtitle Track",
                value: track?.displayName ?? String(localized: "Off"),
                detail: track?.externalFilename.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                }
            )
        )
    }

    func showSubtitleDelayOSD(_ delay: TimeInterval) {
        showVideoOSD(
            VideoOnScreenDisplayItem(
                title: "Subtitle Delay",
                value: Self.delayOSDValue(delay)
            )
        )
    }

    func showAudioDelayOSD(_ delay: TimeInterval) {
        showVideoOSD(
            VideoOnScreenDisplayItem(
                title: "Audio Delay",
                value: Self.delayOSDValue(delay)
            )
        )
    }

    static func delayOSDValue(_ delay: TimeInterval) -> String {
        guard abs(delay) >= 0.005 else { return "0.00s" }
        return String(format: "%+.2fs", delay)
    }
}
