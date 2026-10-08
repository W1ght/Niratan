// test-sources: Features/Reader/ReaderBookmarkPersistencePolicy.swift
import Foundation

@main
enum ReaderBookmarkSyncTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() throws {
        let original = Date(timeIntervalSince1970: 100)
        let remoteRead = Date(timeIntervalSince1970: 200)
        let callback = Date(timeIntervalSince1970: 300)

        let unchanged = ReaderBookmarkPersistencePolicy.modificationDate(
            currentCharacterCount: 1420,
            previousCharacterCount: 1420,
            previousModifiedDate: original,
            now: callback
        )
        require(unchanged == original, "opening or re-laying out an unchanged page preserves its modification time")
        require(unchanged! < remoteRead, "an unchanged 14.2% page cannot outrank a newer remote 57.6% bookmark")

        let restored = ReaderBookmarkPersistencePolicy.modificationDate(
            currentCharacterCount: 5760,
            previousCharacterCount: 5760,
            previousModifiedDate: remoteRead,
            now: callback
        )
        require(restored == remoteRead, "restoring the synced position preserves the remote timestamp")

        for destination in [6000, 1000] {
            let moved = ReaderBookmarkPersistencePolicy.modificationDate(
                currentCharacterCount: destination,
                previousCharacterCount: 5760,
                previousModifiedDate: remoteRead,
                now: callback
            )
            require(moved == callback, "intentional forward and backward reading both create a newer bookmark")
        }

        require(
            ReaderBookmarkPersistencePolicy.modificationDate(
                currentCharacterCount: 0,
                previousCharacterCount: nil,
                previousModifiedDate: nil,
                now: callback
            ) == callback,
            "the first bookmark, including at character zero, receives a timestamp"
        )
        require(
            ReaderBookmarkPersistencePolicy.modificationDate(
                currentCharacterCount: 1420,
                previousCharacterCount: 1420,
                previousModifiedDate: nil,
                now: callback
            ) == nil,
            "re-saving a legacy bookmark with no timestamp must not claim new reading"
        )

        let restore = ReaderRestoreIdentity(token: "current-document", loadRevision: 2, reloadID: "same-chapter-new-position")
        require(restore.accepts(token: "current-document", loadRevision: 2, reloadID: "same-chapter-new-position"), "the current visible document may finish restoring")
        require(!restore.accepts(token: "previous-document", loadRevision: 2, reloadID: "same-chapter-new-position"), "a queued completion from the previous document cannot release the new restore")
        require(!restore.accepts(token: "current-document", loadRevision: 3, reloadID: "same-chapter-new-position"), "a newer synced model revision invalidates an older completion before SwiftUI updates")
        require(!restore.accepts(token: "current-document", loadRevision: 2, reloadID: "resized-reader"), "a layout reload invalidates the previous injection timeout")
        require(!restore.accepts(token: nil, loadRevision: 2, reloadID: "same-chapter-new-position"), "an untagged or measurement completion cannot release a native restore")

        // The native model must wire the policy and restore barrier into its real callbacks;
        // otherwise the pure policy would not protect bookmarks arriving during an open Reader.
        let model = try String(contentsOfFile: "NativeMac/NativeReaderView.swift", encoding: .utf8)
        require(!model.contains("acceptsSyncedPosition"), "the native Reader accepts newer positions after its open-time sync")
        require(model.contains("lastModified: ReaderBookmarkPersistencePolicy.modificationDate("), "the live Reader uses the timestamp policy")
        require(model.contains("guard !applyingSyncedBookmark, !didPrepareForReaderLifecycleClose else { return }"), "restore and closed-window callbacks cannot write local bookmarks")
        require(model.contains("guard enableStatistics, !applyingSyncedBookmark else { return }"), "a sync jump cannot be counted as locally read characters")
        require(model.contains("if applyingSyncedBookmark {\n            applyingSyncedBookmark = false\n            resetTrackingBaseline()"), "tracking resumes from the restored position")
        require(model.contains("guard restoredLoadRevision == loadRevision, !didPrepareForReaderLifecycleClose else { return }"), "the model rechecks the revision after queued completions")
        require(model.contains("guard message.webView === webView,\n                      let restore = visibleRestore"), "the measuring WebView cannot finish the visible Reader restore")
        require(model.contains("navigation === visibleNavigation"), "only the requested visible navigation may inject a new restore token")
        require(model.contains("self.visibleRestore == restore,"), "delayed injection errors and fallback timeouts keep their original document identity")
        require(model.contains("parent.onRestoreCompleted(restore.loadRevision)"), "completion carries the injected document revision back to the model")

        for path in ["Features/Reader/ReaderWebView/reader.js", "Features/Reader/ScrollReaderWebView/scrollreader.js"] {
            let script = try String(contentsOfFile: path, encoding: .utf8)
            require(script.contains("postMessage(window.hoshiReaderRestoreToken ?? null)"), "paged and scroll restores carry their native injection token")
        }

        let sasayaki = try String(contentsOfFile: "Features/Sasayaki/SasayakiPlayer.swift", encoding: .utf8)
        let reload = sasayaki.components(separatedBy: "func reloadPlayback() {")[1]
            .components(separatedBy: "func updateMatchData")[0]
        require(reload.contains("player.defaultRate = rate") && reload.contains("player.rate = rate"), "synced audiobook rate reaches the running audio player")
        require(reload.contains("CMTime(seconds: target, preferredTimescale: 600)"), "synced audiobook time reaches the running audio player")
        require(reload.contains("self.seekGeneration == generation"), "an obsolete remote seek cannot complete after another seek or teardown")
        require(sasayaki.contains("private func tick(_ seconds: Double) {\n        guard !isRestoring else { return }"), "audio ticks cannot replace remote playback while it restores")

        print("Reader bookmark sync tests passed")
    }
}
