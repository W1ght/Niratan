import Foundation

enum SasayakiPlaybackLifecycleTest {
    static func assertContains(_ haystack: String, _ needle: String, _ message: String) {
        if !haystack.contains(needle) {
            fputs("FAIL: \(message)\nMissing: \(needle)\n", stderr)
            exit(1)
        }
    }

    static func assertNotContains(_ haystack: String, _ needle: String, _ message: String) {
        if haystack.contains(needle) {
            fputs("FAIL: \(message)\nUnexpected: \(needle)\n", stderr)
            exit(1)
        }
    }

    static func sourceSection(
        _ source: String,
        from start: String,
        to end: String,
        _ message: String
    ) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            fputs("FAIL: \(message)\nMissing section boundary: \(start) ... \(end)\n", stderr)
            exit(1)
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let nativeReader = try String(
            contentsOf: root.appendingPathComponent("NativeMac/NativeReaderView.swift"),
            encoding: .utf8
        )
        let sasayakiPlayer = try String(
            contentsOf: root.appendingPathComponent("Features/Sasayaki/SasayakiPlayer.swift"),
            encoding: .utf8
        )
        let sasayakiShortcutActions = try String(
            contentsOf: root.appendingPathComponent("Features/Sasayaki/SasayakiShortcutActions.swift"),
            encoding: .utf8
        )
        let popupView = try String(
            contentsOf: root.appendingPathComponent("Features/Popup/PopupView.swift"),
            encoding: .utf8
        )

        assertContains(
            sasayakiPlayer,
            "Logger(subsystem: \"moe.shishamo.hoshi\", category: \"SasayakiPersistence\")",
            "Sasayaki playback should expose structured persistence logs"
        )
        assertContains(
            nativeReader,
            "Logger(subsystem: \"moe.shishamo.hoshi\", category: \"ReaderPersistence\")",
            "Reader bookmark and lifecycle persistence should expose structured logs"
        )
        assertContains(
            nativeReader,
            "private enum NativeReaderLifecycleRegistry",
            "Reader close filtering should track the currently active Reader model instance"
        )
        assertContains(
            nativeReader,
            "let instanceID = UUID()",
            "each Reader model should carry a stable instance identifier for close filtering"
        )
        assertContains(
            nativeReader,
            "var statisticsTimerTask: Task<Void, Never>?",
            "each Reader model should own at most one statistics timer"
        )
        assertContains(
            nativeReader,
            "var didSyncOnOpen = false",
            "duplicate SwiftUI views should not start the same Reader open-sync more than once"
        )
        assertContains(
            nativeReader,
            "ReaderStatisticsPersistencePolicy.shouldPersist(",
            "statistics persistence should reject a model whose bookmark no longer owns the persisted position"
        )
        assertContains(
            nativeReader,
            "reader.statistics.save.skippedStaleModel",
            "a rejected stale statistics write should leave a structured diagnostic"
        )
        assertNotContains(
            nativeReader,
            ".task(id: model.isTracking)",
            "Reader statistics timing should be model-owned instead of duplicated by SwiftUI view tasks"
        )

        let lifecycleClose = sourceSection(
            nativeReader,
            from: "func prepareForReaderLifecycleClose()",
            to: "func nextChapter() -> Bool",
            "native Reader should expose a close/lifecycle persistence boundary"
        )
        assertContains(
            lifecycleClose,
            "flushStats()",
            "Reader close/lifecycle cleanup should keep the existing statistics flush"
        )
        assertContains(
            lifecycleClose,
            "sasayakiPlayer?.teardown()",
            "Reader close/lifecycle cleanup should flush the latest Sasayaki playback position"
        )
        assertContains(
            lifecycleClose,
            "guard !didPrepareForReaderLifecycleClose else",
            "Reader close/lifecycle cleanup should be idempotent across window close and SwiftUI disappear"
        )
        assertContains(
            lifecycleClose,
            "reader.prepareForClose.skip",
            "Reader close/lifecycle cleanup should log duplicate close attempts"
        )
        assertContains(
            lifecycleClose,
            "reader.prepareForClose.start",
            "Reader close/lifecycle cleanup should log before flushing Sasayaki playback"
        )

        let disappearLifecycle = sourceSection(
            nativeReader,
            from: ".onDisappear {",
            to: ".onReceive(NotificationCenter.default.publisher(for: .readerWindowWillClose))",
            "native Reader should expose its disappear lifecycle handler"
        )
        assertContains(
            disappearLifecycle,
            "model.prepareForReaderLifecycleClose()",
            "Reader disappear should persist the final Sasayaki playback position through the shared lifecycle boundary"
        )
        assertContains(
            disappearLifecycle,
            "reader.lifecycle.onDisappear",
            "Reader disappear should log its lifecycle boundary before persistence"
        )
        assertContains(
            disappearLifecycle,
            "guard !suppressReaderLifecycleCloseOnDisappear else",
            "stale Reader views that ignored a different close request should not flush old Sasayaki state on disappear"
        )

        let windowCloseLifecycle = sourceSection(
            nativeReader,
            from: ".onReceive(NotificationCenter.default.publisher(for: .readerWindowWillClose))",
            to: ".onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification))",
            "native Reader should expose its AppKit window-close lifecycle handler"
        )
        assertContains(
            windowCloseLifecycle,
            "model.prepareForReaderLifecycleClose()",
            "AppKit Reader window close should synchronously persist the final Sasayaki playback position"
        )
        assertContains(
            windowCloseLifecycle,
            "reader.lifecycle.windowWillClose.received",
            "AppKit Reader window close should log before invoking the shared persistence boundary"
        )
        assertContains(
            windowCloseLifecycle,
            "closeRequestID == requestID",
            "AppKit Reader window close should only be handled by the matching Reader request"
        )
        assertContains(
            windowCloseLifecycle,
            "NativeReaderLifecycleRegistry.isActive(requestID: requestID, modelID: model.instanceID)",
            "AppKit Reader window close should only be handled by the latest active model for that request"
        )
        assertContains(
            windowCloseLifecycle,
            "reader.lifecycle.windowWillClose.ignoredInactive",
            "stale Reader models with the same request should be logged and skipped during close"
        )
        assertContains(
            windowCloseLifecycle,
            "suppressReaderLifecycleCloseOnDisappear = true",
            "stale Reader views should mark their later disappear as non-persistent during a different window close"
        )
        assertContains(
            windowCloseLifecycle,
            "NotificationCenter.default.post(name: .readerWindowProgressDidChange, object: model.book)",
            "AppKit Reader window close should refresh bookshelf progress after persistence"
        )
        assertContains(
            windowCloseLifecycle,
            "await model.flushAutoSync()",
            "AppKit Reader window close should schedule the same auto-sync flush as SwiftUI disappear"
        )

        let terminationLifecycle = sourceSection(
            nativeReader,
            from: ".onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification))",
            to: "if activeSheet == .gallery {",
            "native Reader should expose its app-termination lifecycle handler"
        )
        assertContains(
            terminationLifecycle,
            "NSApplication.willTerminateNotification",
            "app termination should persist the final Sasayaki playback position even if SwiftUI disappear is bypassed"
        )
        assertContains(
            terminationLifecycle,
            "model.prepareForReaderLifecycleClose()",
            "app termination should use the same Sasayaki persistence path as Reader close"
        )

        let jumpCueAction = sourceSection(
            sasayakiShortcutActions,
            from: "static let jumpCue = ShortcutAction(",
            to: "static let all =",
            "Sasayaki shortcut actions should expose the jump-cue action"
        )
        assertContains(
            jumpCueAction,
            "defaultBinding: .j",
            "Sasayaki jump cue should keep the default j shortcut"
        )

        let shortcutHandlers = sourceSection(
            nativeReader,
            from: "var sasayakiShortcutHandlers:",
            to: "func handleReaderPreviousPageShortcut()",
            "native Reader should map Sasayaki shortcut actions to handlers"
        )
        assertContains(
            shortcutHandlers,
            "SasayakiShortcutActions.jumpCue.id: handleSasayakiJumpCueShortcut",
            "the j Sasayaki shortcut should dispatch to the jump-cue handler"
        )

        let jumpCueHandler = sourceSection(
            nativeReader,
            from: "func handleSasayakiJumpCueShortcut()",
            to: "func registerKeyboardShortcuts()",
            "native Reader should expose its Sasayaki jump shortcut handler"
        )
        assertContains(
            jumpCueHandler,
            "jumpToSasayakiCue()",
            "the j Sasayaki shortcut should use the shared popup jump path"
        )

        let jumpToCue = sourceSection(
            nativeReader,
            from: "func jumpToSasayakiCue()",
            to: "var body: some View",
            "native Reader should expose the popup Sasayaki jump path"
        )
        assertContains(
            jumpToCue,
            "model.sasayakiPlayer?.playCue(from: cue, stop: false)",
            "the j Sasayaki shortcut should jump by playing the popup cue without a stop boundary"
        )
        assertContains(
            jumpToCue,
            "NativeReaderLifecycleRegistry.markActive(requestID: requestID, modelID: model.instanceID)",
            "the j Sasayaki shortcut should mark its model as the active close owner"
        )
        assertContains(
            jumpToCue,
            "model.closePopup(resumePausedPlayback: false)",
            "the j Sasayaki shortcut should close the lookup popup without resuming the old paused position"
        )
        assertContains(
            jumpToCue,
            "reader.sasayakiJumpShortcut",
            "the j Sasayaki shortcut should log the cue jump persistence point"
        )

        let dismissPopupSection = sourceSection(
            nativeReader,
            from: "func dismissPopup(id: UUID",
            to: "func navigateBackward()",
            "native Reader should expose targeted popup dismissal"
        )
        assertContains(
            dismissPopupSection,
            "resumePausedPlayback: Bool = true",
            "targeted popup dismissal should let Sasayaki jumps opt out of resuming old playback"
        )
        assertContains(
            dismissPopupSection,
            "closePopup(resumePausedPlayback: resumePausedPlayback)",
            "root popup dismissal should pass through the requested Sasayaki resume behavior"
        )

        let popupLayerSection = sourceSection(
            nativeReader,
            from: "func popupLayer(screenSize: CGSize)",
            to: "var nativeTopInfoOverlay",
            "native Reader should wire popup dismissal callbacks"
        )
        assertContains(
            popupLayerSection,
            "onSasayakiJumpDismiss",
            "Reader popups should provide a Sasayaki-specific dismissal path"
        )
        assertContains(
            popupLayerSection,
            "model.dismissPopup(id: popupId, resumePausedPlayback: false)",
            "Reader popup Sasayaki controls should not resume the old auto-paused playback position"
        )

        let closePopupSection = sourceSection(
            nativeReader,
            from: "func closePopup(resumePausedPlayback: Bool = true)",
            to: "func closeChildPopups(parent index: Int)",
            "native Reader should expose popup close behavior"
        )
        assertContains(
            closePopupSection,
            "if resumePausedPlayback, wasPaused, sasayakiPlayer?.isPlaying == false",
            "regular popup close should keep the existing auto-resume behavior while allowing Sasayaki jumps to opt out"
        )

        let popupSasayakiControls = sourceSection(
            popupView,
            from: "func sasayakiControls(",
            to: "func popupContent(",
            "shared popup view should expose Sasayaki controls"
        )
        assertContains(
            popupSasayakiControls,
            "player.playCue(from: cue, stop: false)",
            "popup forward-frame control should keep the existing Sasayaki cue jump behavior"
        )
        assertContains(
            popupSasayakiControls,
            "(onSasayakiJumpDismiss ?? onSwipeDismiss)?()",
            "popup forward-frame control should use the Sasayaki-specific dismissal callback when provided"
        )
        assertContains(
            popupSasayakiControls,
            ".buttonStyle(.plain)",
            "popup Sasayaki controls should remove the default material button background"
        )
        assertContains(
            popupSasayakiControls,
            "func popupControlIcon(_ systemName: String) -> some View",
            "popup Sasayaki controls should centralize their transparent hit target"
        )
        assertContains(
            popupSasayakiControls,
            ".frame(width: 52, height: 32)",
            "popup Sasayaki controls should preserve a roomy click target even without a material background"
        )
        assertContains(
            popupSasayakiControls,
            ".contentShape(Rectangle())",
            "popup Sasayaki controls should make the transparent click target hittable"
        )
        guard let popupDismissRange = popupSasayakiControls.range(of: "(onSasayakiJumpDismiss ?? onSwipeDismiss)?()"),
              let popupPlayCueRange = popupSasayakiControls.range(of: "player.playCue(from: cue, stop: false)"),
              popupDismissRange.lowerBound < popupPlayCueRange.lowerBound else {
            fputs("FAIL: popup forward-frame control should sync/dismiss before playing the target cue\n", stderr)
            exit(1)
        }

        let playCueSection = sourceSection(
            sasayakiPlayer,
            from: "func playCue(from cue: SasayakiMatch, stop: Bool)",
            to: "func flushPlayback()",
            "Sasayaki player should expose popup cue playback"
        )
        assertContains(
            playCueSection,
            "updateCue: false",
            "popup cue jumps should seek without waiting for cue display updates"
        )
        assertContains(
            playCueSection,
            "stopPlaybackTime: stop ? cue.endTime + delay : nil",
            "playCue(stop: false) should keep playback running after the j shortcut jump"
        )
        assertContains(
            playCueSection,
            "sasayaki.playCue.request",
            "Sasayaki cue playback should log the requested cue and stop behavior"
        )

        let flushSection = sourceSection(
            sasayakiPlayer,
            from: "func flushPlayback()",
            to: "func teardown()",
            "Sasayaki player should expose its close-time flush boundary"
        )
        assertContains(
            flushSection,
            "if let pendingSeekPosition",
            "closing immediately after a j cue jump should flush the requested seek target instead of the old AVPlayer time"
        )
        assertContains(
            flushSection,
            "persistPlaybackPosition(pendingSeekPosition)",
            "close-time flush should reuse the immediate Sasayaki persistence path for pending cue jumps"
        )
        assertContains(
            flushSection,
            "sasayaki.flush.start",
            "Sasayaki close-time flush should log the pending/current playback state before writing"
        )
        assertContains(
            flushSection,
            "guard isPlaying else",
            "inactive stale Sasayaki players should not overwrite a newer persisted playback position during close"
        )
        assertContains(
            flushSection,
            "sasayaki.flush.skipInactive",
            "inactive close-time flush skips should be logged for persistence diagnosis"
        )
        guard let pendingFlushRange = flushSection.range(of: "if let pendingSeekPosition"),
              let playerTimeRange = flushSection.range(of: "player?.currentTime().seconds"),
              pendingFlushRange.lowerBound < playerTimeRange.lowerBound else {
            fputs("FAIL: pending cue-jump position should be flushed before reading AVPlayer currentTime\n", stderr)
            exit(1)
        }
        guard let activeFlushRange = flushSection.range(of: "guard isPlaying else"),
              activeFlushRange.lowerBound < playerTimeRange.lowerBound else {
            fputs("FAIL: inactive close-time flush should skip before reading AVPlayer currentTime\n", stderr)
            exit(1)
        }

        let pauseSection = sourceSection(
            sasayakiPlayer,
            from: "func pausePlayback()",
            to: "func tick(",
            "Sasayaki player should expose its pause persistence boundary"
        )
        assertContains(
            pauseSection,
            "persistPlaybackPosition(seconds)",
            "pausing active Sasayaki playback should persist the sampled position before a later inactive close flush"
        )

        let tickSection = sourceSection(
            sasayakiPlayer,
            from: "func tick(",
            to: "func seek(",
            "Sasayaki player should expose its periodic playback tick"
        )
        assertContains(
            tickSection,
            "if let pendingSeekPosition",
            "periodic ticks should respect pending cue jumps before saving AVPlayer samples"
        )
        assertContains(
            tickSection,
            "guard abs(seconds - pendingSeekPosition) <= seekLandingTolerance else { return }",
            "old AVPlayer time samples should not overwrite a just-persisted cue jump"
        )
        assertContains(
            tickSection,
            "self.pendingSeekPosition = nil",
            "pending cue jumps should only clear once AVPlayer reports time near the requested target"
        )
        assertContains(
            tickSection,
            "sasayaki.tick.persist",
            "Sasayaki periodic tick should log when it records playback position"
        )
        guard let tickPendingRange = tickSection.range(of: "if let pendingSeekPosition"),
              let tickSaveRange = tickSection.range(of: "savePlayback()"),
              tickPendingRange.lowerBound < tickSaveRange.lowerBound else {
            fputs("FAIL: stale tick filtering should happen before periodic playback save\n", stderr)
            exit(1)
        }

        let seekSection = sourceSection(
            sasayakiPlayer,
            from: "func seek(",
            to: "func setupPlayer(url: URL)",
            "Sasayaki player should expose its seek boundary"
        )
        assertContains(
            seekSection,
            "pendingSeekPosition = seconds",
            "Sasayaki cue jumps should remember the requested target until AVPlayer finishes seeking"
        )
        assertContains(
            seekSection,
            "sasayaki.seek.request",
            "Sasayaki seek should log the requested target before writing"
        )
        assertContains(
            seekSection,
            "persistPlaybackPosition(seconds)",
            "cue jumps should persist the target Sasayaki position before waiting for the AVPlayer seek callback"
        )
        assertContains(
            seekSection,
            "seekGeneration += 1",
            "overlapping Sasayaki seeks should have a generation token"
        )
        assertContains(
            seekSection,
            "guard self.seekGeneration == generation else { return }",
            "stale AVPlayer seek completions should not update playback state after a newer seek"
        )
        assertNotContains(
            seekSection,
            "pendingSeekPosition = nil",
            "seek completion should not clear pending cue jumps before AVPlayer emits a matching time sample"
        )
        guard let immediatePersistRange = seekSection.range(of: "persistPlaybackPosition(seconds)"),
              let avSeekRange = seekSection.range(of: "player.seek("),
              immediatePersistRange.lowerBound < avSeekRange.lowerBound else {
            fputs("FAIL: cue jump persistence should happen before AVPlayer seek starts\n", stderr)
            exit(1)
        }

        let persistSection = sourceSection(
            sasayakiPlayer,
            from: "func persistPlaybackPosition(",
            to: "func setupPlayer(url: URL)",
            "Sasayaki player should expose immediate playback position persistence"
        )
        assertContains(
            persistSection,
            "playback.lastPosition = seconds",
            "immediate Sasayaki persistence should update the sidecar playback position"
        )
        assertContains(
            persistSection,
            "savePlayback()",
            "immediate Sasayaki persistence should write the sidecar without waiting for the periodic tick"
        )
        assertContains(
            persistSection,
            "sasayaki.persist.position",
            "immediate Sasayaki persistence should log the target position before disk write"
        )
        assertContains(
            persistSection,
            "onPlayback()",
            "immediate Sasayaki persistence should trigger audiobook auto-export scheduling"
        )

        print("sasayaki playback lifecycle persistence passed")
    }
}

try SasayakiPlaybackLifecycleTest.main()
