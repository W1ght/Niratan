// test-sources: Models/Anki.swift
import Foundation

@main
private enum AnkiSettingsPersistenceTests {
    static func main() throws {
        testSharedTransportMergePreservesDefaultProfileProjection()
        try testProfileRoundTripPreservesFieldMappings()
        try testTextBindingsPersistEveryEdit()
        print("Anki settings persistence tests passed")
    }

    private static func testSharedTransportMergePreservesDefaultProfileProjection() {
        let original = AnkiConfig(
            selectedDeck: "Default Profile Deck",
            selectedNoteType: "Default Profile Model",
            allowDupes: false,
            compactGlossaries: true,
            embedMedia: true,
            fieldMappings: ["Expression": Handlebars.expression.rawValue],
            tags: "default-profile",
            availableDecks: ["Old Deck"],
            availableNoteTypes: [AnkiNoteType(name: "Old Model", fields: ["Expression"])],
            useAnkiConnect: true,
            ankiConnectConfig: AnkiConnectConfig(
                url: "http://127.0.0.1:8765",
                timeout: 10,
                duplicateScope: .collection,
                forceSync: false
            ),
            compressVideoScreenshots: true,
            imageCompressionFormat: .avif
        )
        let updatedTransport = AnkiConnectConfig(
            url: "http://anki.example:8765",
            timeout: 25,
            duplicateScope: .deckroot,
            checkAllModels: true,
            forceSync: true,
            apiKey: "secret"
        )

        let merged = original.updatingSharedState(
            availableDecks: ["Fresh Deck"],
            availableNoteTypes: [AnkiNoteType(name: "Fresh Model", fields: ["Front"])],
            ankiConnectConfig: updatedTransport
        )

        precondition(merged.selectedDeck == original.selectedDeck)
        precondition(merged.selectedNoteType == original.selectedNoteType)
        precondition(merged.allowDupes == original.allowDupes)
        precondition(merged.compactGlossaries == original.compactGlossaries)
        precondition(merged.fieldMappings == original.fieldMappings)
        precondition(merged.tags == original.tags)
        precondition(merged.compressVideoScreenshots == original.compressVideoScreenshots)
        precondition(merged.effectiveCompressImages)
        precondition(merged.effectiveImageCompressionQuality == 0.80)
        precondition(merged.effectiveImageCompressionFormat == .avif)
        precondition(merged.effectiveAudioCompressionFormat == .aac)
        precondition(merged.effectiveAudioCompressionBitrateKbps == 64)
        precondition(merged.availableDecks == ["Fresh Deck"])
        precondition(merged.availableNoteTypes == [AnkiNoteType(name: "Fresh Model", fields: ["Front"])])
        precondition(merged.ankiConnectConfig?.url == updatedTransport.url)
        precondition(merged.ankiConnectConfig?.timeout == updatedTransport.timeout)
        precondition(merged.ankiConnectConfig?.duplicateScope == .collection)
        precondition(merged.ankiConnectConfig?.checkAllModels == false)
        precondition(merged.ankiConnectConfig?.forceSync == true)
        precondition(merged.ankiConnectConfig?.apiKey == "secret")
    }

    private static func testTextBindingsPersistEveryEdit() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ankiView = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Features/Settings/AnkiView.swift"),
            encoding: .utf8
        )
        let ankiConnectView = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Features/Settings/AnkiConnectView.swift"),
            encoding: .utf8
        )

        precondition(
            ankiView.contains("set: { ankiManager.setAnkiConnectURL($0) }"),
            "Anki address edits must persist without requiring Return or view disappearance"
        )
        precondition(
            ankiView.contains("ankiManager.setFieldMapping(value, for: field)"),
            "Anki field mapping edits must persist on every edit"
        )
        precondition(
            ankiView.contains("set: { ankiManager.setTags($0) }"),
            "Anki tag edits must persist on every edit"
        )
        precondition(
            ankiConnectView.contains("set: { ankiManager.setAnkiConnectURL($0) }"),
            "The standalone AnkiConnect address editor must persist on every edit"
        )
        precondition(
            ankiConnectView.contains("set: { ankiManager.setAnkiConnectAPIKey($0) }"),
            "The AnkiConnect API key editor must persist on every edit"
        )
    }

    private static func testProfileRoundTripPreservesFieldMappings() throws {
        let original = AnkiProfileConfig(
            selectedDeck: "Mining",
            selectedNoteType: "Lapis",
            allowDupes: false,
            compactGlossaries: true,
            embedMedia: true,
            fieldMappings: [
                "Expression": "{custom-expression}",
                "SentenceAudio": ""
            ],
            tags: "custom-tag",
            duplicateScope: .collection,
            checkAllModels: false,
            compressVideoScreenshots: nil,
            compressImages: false,
            imageCompressionQuality: 0.55,
            imageCompressionFormat: .avif,
            audioCompressionFormat: .mp3,
            audioCompressionBitrateKbps: 96
        )

        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(AnkiProfileConfig.self, from: encoded)

        precondition(restored.fieldMappings["Expression"] == "{custom-expression}")
        precondition(restored.fieldMappings["SentenceAudio"] == "")
        precondition(!restored.effectiveCompressImages)
        precondition(restored.effectiveImageCompressionQuality == 0.55)
        precondition(restored.effectiveImageCompressionFormat == .avif)
        precondition(restored.effectiveAudioCompressionFormat == .mp3)
        precondition(restored.effectiveAudioCompressionBitrateKbps == 96)
        precondition(restored == original)
    }
}
