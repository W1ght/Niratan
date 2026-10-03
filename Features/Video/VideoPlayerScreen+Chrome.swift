import AppKit
@preconcurrency import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Playback chrome placement, visibility, pointer handling and full screen.
extension VideoPlayerScreen {
    func toggleFullScreen() {
        if windowChrome.isFullScreen {
            exitFullScreen()
            return
        }
        windowChrome.toggleFullScreen()
    }

    func exitFullScreen() {
        guard windowChrome.isFullScreen else { return }
        windowChrome.exitFullScreen()
    }

    func toggleFullScreenFromPointer() {
        guard model.currentURL != nil,
              lookup.presentation.popups.isEmpty else {
            return
        }
        revealPlaybackChrome(scheduleHide: true)
        toggleFullScreen()
    }

    func togglePlaybackFromPointer() {
        guard model.currentURL != nil,
              lookup.presentation.popups.isEmpty else {
            return
        }
        model.togglePlayback()
        revealPlaybackChrome(scheduleHide: true)
    }

    func playbackChromeBasePosition(in size: CGSize) -> CGPoint {
        let chromeSize = playbackChromeSize(in: size)
        let halfHeight = chromeSize.height / 2
        let y = max(
            Self.playbackChromeEdgeInset + halfHeight,
            size.height - playbackChromeBottomEdgeInset - videoControlsMetrics.bottomInset - halfHeight
        )
        return CGPoint(x: size.width / 2, y: y)
    }

    var playbackChromeBottomEdgeInset: CGFloat {
        switch userConfig.videoControlBarLayout {
        case .floating:
            Self.playbackChromeEdgeInset
        case .compactBottom:
            0
        }
    }

    func playbackChromeCurrentOffset(in size: CGSize) -> CGSize {
        switch userConfig.videoControlBarLayout {
        case .floating:
            clampedPlaybackChromeOffset(
                CGSize(
                    width: playbackChromeStoredOffset.width + playbackChromeDragOffset.width,
                    height: playbackChromeStoredOffset.height + playbackChromeDragOffset.height
                ),
                in: size
            )
        case .compactBottom:
            .zero
        }
    }

    func playbackChromeFrame(in size: CGSize) -> CGRect {
        let center = playbackChromeBasePosition(in: size)
        let offset = playbackChromeCurrentOffset(in: size)
        let chromeSize = playbackChromeSize(in: size)
        return CGRect(
            x: center.x + offset.width - chromeSize.width / 2,
            y: center.y + offset.height - chromeSize.height / 2,
            width: chromeSize.width,
            height: chromeSize.height
        )
    }

    func playbackChromeSize(in size: CGSize) -> CGSize {
        VideoControlsView.chromeSize(
            for: userConfig.videoControlBarLayout,
            availableWidth: size.width
        )
    }

    func videoSurfaceVolumeScrollExcludedRects(in size: CGSize) -> [CGRect] {
        var rects: [CGRect] = []
        if shouldShowPlaybackChrome {
            rects.append(playbackChromeFrame(in: size))
        }
        if isInspectorVisible {
            let inspectorFrame = inspectorOverlayFrame.isEmpty
                ? inspectorOverlayFallbackFrame(in: size)
                : inspectorOverlayFrame
            let visibleInspectorFrame = inspectorFrame.intersection(
                CGRect(origin: .zero, size: size)
            )
            if !visibleInspectorFrame.isNull,
               visibleInspectorFrame.width > 0,
               visibleInspectorFrame.height > 0 {
                rects.append(visibleInspectorFrame)
            }
        }
        return rects
    }

    func inspectorOverlayFallbackFrame(in size: CGSize) -> CGRect {
        let width = min(
            size.width,
            VideoInspectorView.maximumWidth + Self.inspectorOverlayTrailingInset
        )
        return CGRect(
            x: max(0, size.width - width),
            y: 0,
            width: width,
            height: size.height
        )
    }

    func clampedPlaybackChromeOffset(_ offset: CGSize, in size: CGSize) -> CGSize {
        let base = playbackChromeBasePosition(in: size)
        let chromeSize = playbackChromeSize(in: size)
        let halfWidth = chromeSize.width / 2
        let halfHeight = chromeSize.height / 2
        let minX = min(Self.playbackChromeEdgeInset + halfWidth, size.width / 2)
        let maxX = max(size.width - Self.playbackChromeEdgeInset - halfWidth, size.width / 2)
        let minY = min(Self.playbackChromeEdgeInset + halfHeight, size.height / 2)
        let maxY = max(size.height - playbackChromeBottomEdgeInset - halfHeight, size.height / 2)
        let x = min(max(base.x + offset.width, minX), maxX)
        let y = min(max(base.y + offset.height, minY), maxY)
        return CGSize(width: x - base.x, height: y - base.y)
    }

    func handleVideoPointerMovement(_ phase: HoverPhase) {
        switch phase {
        case .active(_):
            let pointerLocation = NSEvent.mouseLocation
            guard lastPlaybackChromePointerLocation != pointerLocation else {
                return
            }
            lastPlaybackChromePointerLocation = pointerLocation
            isPointerInsidePlayerSurface = true
            revealPlaybackChrome(scheduleHide: true)
        case .ended:
            schedulePlaybackChromeAutoHide()
        }
    }

    func revealPlaybackChrome(scheduleHide shouldScheduleAutoHide: Bool) {
        windowChrome.restorePlaybackCursor()
        guard model.currentURL != nil else {
            isPlaybackChromeVisible = true
            playbackChromeAutoHideTask?.cancel()
            return
        }
        if !isPlaybackChromeVisible {
            withAnimation(.smooth(duration: 0.18)) {
                isPlaybackChromeVisible = true
            }
        }
        if shouldScheduleAutoHide {
            schedulePlaybackChromeAutoHide()
        } else {
            playbackChromeAutoHideTask?.cancel()
        }
    }

    func hidePlaybackChromeAndCursor() {
        playbackChromeAutoHideTask?.cancel()
        guard model.currentURL != nil,
              !windowChrome.isWindowGeometryTransitioning,
              !hasActiveVideoPopup,
              timelinePreviewRequestedTime == nil,
              !isInspectorVisible,
              !isMiningHistoryVisible else {
            windowChrome.restorePlaybackCursor()
            return
        }
        lastPlaybackChromePointerLocation = NSEvent.mouseLocation
        withAnimation(.smooth(duration: 0.18)) {
            isPlaybackChromeVisible = false
        }
        windowChrome.hidePlaybackCursorUntilMouseMoves()
    }

    func playerSurfaceHoverChanged(_ hovering: Bool) {
        guard model.currentURL != nil else { return }
        isPointerInsidePlayerSurface = hovering
        if hovering {
            revealPlaybackChrome(scheduleHide: true)
        } else {
            hidePlaybackChromeForPointerExit()
        }
    }

    func hidePlaybackChromeForPointerExit() {
        windowChrome.restorePlaybackCursor()
        guard model.currentURL != nil else { return }
        guard !windowChrome.isWindowGeometryTransitioning else { return }
        guard timelinePreviewRequestedTime == nil else { return }
        playbackChromeAutoHideTask?.cancel()
        isPointerInsidePlayerSurface = false
        withAnimation(.smooth(duration: 0.18)) {
            isPlaybackChromeVisible = false
        }
    }

    func playbackChromeHoverChanged(_ hovering: Bool) {
        guard model.currentURL != nil else { return }
        if hovering {
            revealPlaybackChrome(scheduleHide: true)
        } else {
            schedulePlaybackChromeAutoHide()
        }
    }

    func schedulePlaybackChromeAutoHide() {
        playbackChromeAutoHideTask?.cancel()
        guard model.currentURL != nil,
              !windowChrome.isWindowGeometryTransitioning,
              isPlaybackChromeVisible,
              !hasActiveVideoPopup,
              timelinePreviewRequestedTime == nil,
              !isInspectorVisible,
              !isMiningHistoryVisible else {
            return
        }
        playbackChromeAutoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            hidePlaybackChromeAndCursor()
        }
    }
}
