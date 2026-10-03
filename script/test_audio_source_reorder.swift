// test-sources: Models/Dictionary.swift Models/Profile.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum AudioSourceReorderTests {
    static func main() {
        let id = "https://example.test/audio?term={term}"
        let payload = AudioSourceReorder.payload(for: id)

        expect(
            AudioSourceReorder.audioSourceID(from: payload) == id,
            "audio source drag payload should round-trip its identifier"
        )
        expect(
            AudioSourceReorder.audioSourceID(from: id) == nil,
            "unscoped text drops should not reorder audio sources"
        )
        expect(
            AudioSourceReorder.audioSourceID(from: "hoshi-audio-source:") == nil,
            "empty audio source payloads should be ignored"
        )
        expect(
            AudioSourceReorder.destinationOffset(sourceIndex: 0, targetIndex: 2) == 3,
            "dragging downward should insert after the target row"
        )
        expect(
            AudioSourceReorder.destinationOffset(sourceIndex: 2, targetIndex: 0) == 0,
            "dragging upward should insert before the target row"
        )
        expect(
            AudioSourceReorder.destinationOffset(sourceIndex: 1, targetIndex: 1) == nil,
            "dropping on the same row should not persist a redundant reorder"
        )

        let canonicalLocal = AudioSource(name: "Local", url: "http://127.0.0.1/audio")
        let legacyLocalURL = "http://localhost/audio"
        let customA = AudioSource(name: "A", url: "https://a.example")
        let customB = AudioSource(name: "B", url: "https://b.example")
        let disabledLegacyLocal = AudioSource(
            name: "Legacy Local",
            url: legacyLocalURL,
            isEnabled: false
        )

        let preserved = AudioSourceReorder.synchronizingLocalSource(
            [customA, customB, disabledLegacyLocal],
            enabled: true,
            canonicalSource: canonicalLocal,
            legacyURLs: [legacyLocalURL]
        )
        expect(
            preserved.map(\.url) == [customA.url, customB.url, canonicalLocal.url],
            "local audio normalization should preserve the user's reordered position"
        )
        expect(
            preserved.last?.isEnabled == false,
            "local audio normalization should preserve its enabled state"
        )

        let inserted = AudioSourceReorder.synchronizingLocalSource(
            [customA, customB],
            enabled: true,
            canonicalSource: canonicalLocal,
            legacyURLs: [legacyLocalURL]
        )
        expect(
            inserted.first?.url == canonicalLocal.url,
            "newly enabled local audio should start at the top"
        )

        let removed = AudioSourceReorder.synchronizingLocalSource(
            [customA, disabledLegacyLocal, canonicalLocal, customB],
            enabled: false,
            canonicalSource: canonicalLocal,
            legacyURLs: [legacyLocalURL]
        )
        expect(
            removed.map(\.url) == [customA.url, customB.url],
            "disabling local audio should remove canonical and legacy local sources"
        )

        print("Audio source reorder tests passed")
    }
}
