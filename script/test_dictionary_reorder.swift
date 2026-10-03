// test-sources: Models/Dictionary.swift Models/Profile.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum DictionaryReorderTests {
    static func main() {
        let id = UUID()
        let payload = DictionaryReorder.payload(for: id)

        expect(
            DictionaryReorder.dictionaryID(from: payload) == id,
            "dictionary drag payload should round-trip its UUID"
        )
        expect(
            DictionaryReorder.dictionaryID(from: id.uuidString) == nil,
            "unscoped text drops should not reorder dictionaries"
        )
        expect(
            DictionaryReorder.destinationOffset(sourceIndex: 0, targetIndex: 2) == 3,
            "dragging downward should insert after the target row"
        )
        expect(
            DictionaryReorder.destinationOffset(sourceIndex: 2, targetIndex: 0) == 0,
            "dragging upward should insert before the target row"
        )
        expect(
            DictionaryReorder.destinationOffset(sourceIndex: 1, targetIndex: 1) == nil,
            "dropping on the same row should not persist a redundant reorder"
        )
        expect(
            !DictionaryUpdateAvailability.shouldOfferUpdate(
                localRevision: "JMdict.2026-07-03",
                remoteRevision: "JMdict.2026-07-03"
            ),
            "dictionary update list should not offer dictionaries whose remote revision already matches the local revision"
        )
        expect(
            DictionaryUpdateAvailability.shouldOfferUpdate(
                localRevision: "JMdict.2026-07-02",
                remoteRevision: "JMdict.2026-07-03"
            ),
            "dictionary update list should offer dictionaries whose remote revision differs from the local revision"
        )
        let importedRecommendedIndex = DictionaryIndex(
            title: "JMdict [2026-07-01]",
            format: 3,
            revision: "JMdict.2026-07-01",
            isUpdatable: false,
            indexUrl: "",
            downloadUrl: ""
        )
        let resolvedRecommendedIndex = DictionaryUpdateSourceResolver.updateCapableIndex(
            for: importedRecommendedIndex,
            type: .term
        )
        expect(
            resolvedRecommendedIndex?.indexUrl == "https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/JMdict_english_without_proper_names.json",
            "manually imported known recommended dictionaries should resolve their update index URL"
        )
        expect(
            resolvedRecommendedIndex?.isUpdatable == true,
            "manually imported known recommended dictionaries should become update-capable in memory"
        )
        let unknownImportedIndex = DictionaryIndex(
            title: "Private Dictionary",
            format: 3,
            revision: "1",
            isUpdatable: false,
            indexUrl: "",
            downloadUrl: ""
        )
        expect(
            DictionaryUpdateSourceResolver.updateCapableIndex(for: unknownImportedIndex, type: .term) == nil,
            "manually imported dictionaries without a known remote source should not be marked update-capable"
        )

        print("Dictionary reorder tests passed")
    }
}
