import AppKit
@preconcurrency import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Player keyboard shortcut registration.
extension VideoPlayerScreen {
    func registerKeyboardShortcuts() {
        guard shortcutRegistrationIDs.isEmpty else { return }

        shortcutRegistrationIDs = [
            shortcutManager.register(
                scope: .popup,
                handlers: [
                    PopupShortcutActions.dismiss.id: {
                        guard let popup = lookup.presentation.popups.last else {
                            return false
                        }
                        lookup.dismiss(id: popup.id, player: model)
                        return true
                    }
                ]
            ),
            shortcutManager.register(
                scope: .video,
                handlers: [
                    VideoShortcutActions.playPause.id: {
                        guard model.currentURL != nil else { return false }
                        model.togglePlayback()
                        return true
                    },
                    VideoShortcutActions.seekBackward.id: {
                        guard model.currentURL != nil else { return false }
                        model.skip(by: -userConfig.videoSeekInterval)
                        return true
                    },
                    VideoShortcutActions.seekForward.id: {
                        guard model.currentURL != nil else { return false }
                        model.skip(by: userConfig.videoSeekInterval)
                        return true
                    },
                    VideoShortcutActions.previousEpisode.id: {
                        guard model.playlist.previousURL != nil else { return false }
                        model.playPrevious()
                        return true
                    },
                    VideoShortcutActions.nextEpisode.id: {
                        guard model.playlist.nextURL != nil else { return false }
                        model.playNext()
                        return true
                    },
                    VideoShortcutActions.decreaseSpeed.id: {
                        setSpeedWithOSD(model.snapshot.speed - VideoPlaybackSpeed.customStep)
                        return true
                    },
                    VideoShortcutActions.increaseSpeed.id: {
                        setSpeedWithOSD(model.snapshot.speed + VideoPlaybackSpeed.customStep)
                        return true
                    },
                    VideoShortcutActions.resetSpeed.id: {
                        setSpeedWithOSD(1)
                        return true
                    },
                    VideoShortcutActions.toggleMute.id: {
                        toggleMuteWithOSD()
                        return true
                    },
                    VideoShortcutActions.volumeDown.id: {
                        adjustVolume(by: -5)
                        return true
                    },
                    VideoShortcutActions.volumeUp.id: {
                        adjustVolume(by: 5)
                        return true
                    },
                    VideoShortcutActions.mineCurrentSubtitle.id: {
                        mineCurrentSubtitle()
                        return true
                    },
                    VideoShortcutActions.previousSubtitleCue.id: {
                        seekRelativeSubtitleCue(offset: -1)
                    },
                    VideoShortcutActions.nextSubtitleCue.id: {
                        seekRelativeSubtitleCue(offset: 1)
                    },
                    VideoShortcutActions.toggleSubtitlesVisible.id: {
                        toggleSubtitlesVisible()
                        return true
                    },
                    VideoShortcutActions.toggleSubtitleGapFastForward.id: {
                        toggleSubtitleGapFastForward()
                        return true
                    },
                    VideoShortcutActions.cycleSubtitleTrack.id: {
                        cycleSubtitleTrack()
                    },
                    VideoShortcutActions.subtitleEarlier.id: {
                        adjustSubtitleDelayWithOSD(by: -0.05)
                        return true
                    },
                    VideoShortcutActions.subtitleLater.id: {
                        adjustSubtitleDelayWithOSD(by: 0.05)
                        return true
                    },
                    VideoShortcutActions.resetSubtitleTiming.id: {
                        setSubtitleDelayWithOSD(0)
                        return true
                    },
                    VideoShortcutActions.alignPreviousSubtitleToCurrentTime.id: {
                        alignAdjacentSubtitleToCurrentTime(.previous)
                    },
                    VideoShortcutActions.alignNextSubtitleToCurrentTime.id: {
                        alignAdjacentSubtitleToCurrentTime(.next)
                    },
                    VideoShortcutActions.audioEarlier.id: {
                        adjustAudioDelayWithOSD(by: -0.5)
                        return true
                    },
                    VideoShortcutActions.audioLater.id: {
                        adjustAudioDelayWithOSD(by: 0.5)
                        return true
                    },
                    VideoShortcutActions.toggleFileLoop.id: {
                        model.setLoopMode(
                            model.snapshot.loopMode == .file ? .none : .file
                        )
                        return true
                    },
                    VideoShortcutActions.setABLoopStart.id: {
                        model.setABLoopStart()
                        return true
                    },
                    VideoShortcutActions.setABLoopEnd.id: {
                        model.setABLoopEnd()
                        return true
                    },
                    VideoShortcutActions.toggleTranscript.id: {
                        toggleTranscriptSidebar()
                        return true
                    },
                    VideoShortcutActions.rotateClockwise.id: {
                        model.rotateClockwise()
                        return true
                    },
                    VideoShortcutActions.toggleFullScreen.id: {
                        guard windowChrome.hasWindow else { return false }
                        if windowChrome.isFullScreen {
                            exitFullScreen()
                            return true
                        }
                        dismissVideoPopupsThen {
                            toggleFullScreen()
                        }
                        return true
                    },
                    VideoShortcutActions.exitFocusMode.id: {
                        guard windowChrome.isFullScreen else {
                            return false
                        }
                        exitFullScreen()
                        return true
                    }
                ]
            ),
            shortcutManager.register(
                scope: .global,
                handlers: [
                    GlobalShortcutActions.open.id: {
                        dismissVideoPopupsThen {
                            presentFileImporter(.video)
                        }
                        return true
                    }
                ]
            )
        ]
    }

    func unregisterKeyboardShortcuts() {
        shortcutRegistrationIDs.forEach(shortcutManager.unregister)
        shortcutRegistrationIDs.removeAll()
    }
}
