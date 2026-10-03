// test-sources: Models/Anki.swift
import Foundation

@main
private enum AnkiFieldTemplateTests {
    static func main() {
        let lapis = AnkiFieldTemplate.autofilledMappings(
            noteType: "Lapis",
            availableFields: ["Expression", "MainDefinition", "Sentence", "SentenceAudio", "Picture", "UnknownField"],
            existing: [:]
        )
        precondition(lapis["Expression"] == Handlebars.expression.rawValue)
        precondition(lapis["MainDefinition"] == Handlebars.glossaryFirst.rawValue)
        precondition(lapis["Sentence"] == Handlebars.sentence.rawValue)
        precondition(lapis["SentenceAudio"] == Handlebars.sasayakiAudio.rawValue)
        precondition(lapis["Picture"] == Handlebars.bookCover.rawValue)
        precondition(lapis["UnknownField"] == nil)

        let custom = AnkiFieldTemplate.autofilledMappings(
            noteType: "Lapis",
            availableFields: ["Expression", "MainDefinition"],
            existing: [
                "Expression": "{custom-expression}",
                "MainDefinition": "   ",
                "RemovedField": "{sentence}"
            ]
        )
        precondition(custom["Expression"] == "{custom-expression}")
        precondition(custom["MainDefinition"] == Handlebars.glossaryFirst.rawValue)
        precondition(custom["RemovedField"] == nil)

        let explicitlyDisabled = AnkiFieldTemplate.autofilledMappings(
            noteType: "Lapis",
            availableFields: ["Expression", "SentenceAudio", "Picture"],
            existing: [
                "Expression": Handlebars.expression.rawValue,
                "SentenceAudio": "",
                "Picture": ""
            ]
        )
        precondition(explicitlyDisabled["SentenceAudio"] == "")
        precondition(explicitlyDisabled["Picture"] == "")

        let kiku = AnkiFieldTemplate.autofilledMappings(
            noteType: "Kiku",
            availableFields: ["ExpressionAudio", "SentenceAudio", "Picture"],
            existing: [:]
        )
        precondition(kiku["ExpressionAudio"] == Handlebars.audio.rawValue)
        precondition(kiku["SentenceAudio"] == Handlebars.sasayakiAudio.rawValue)
        precondition(kiku["Picture"] == Handlebars.bookCover.rawValue)

        let senren = AnkiFieldTemplate.autofilledMappings(
            noteType: "Senren",
            availableFields: ["word", "definition", "wordAudio", "sentenceAudio", "picture"],
            existing: [:]
        )
        precondition(senren["word"] == Handlebars.expression.rawValue)
        precondition(senren["definition"] == Handlebars.glossaryFirst.rawValue)
        precondition(senren["wordAudio"] == Handlebars.audio.rawValue)
        precondition(senren["sentenceAudio"] == Handlebars.sasayakiAudio.rawValue)
        precondition(senren["picture"] == Handlebars.bookCover.rawValue)

        let unknown = ["Front": "{expression}"]
        precondition(AnkiFieldTemplate.autofilledMappings(
            noteType: "Custom",
            availableFields: ["Front"],
            existing: unknown
        ) == unknown)

        let restoredLapis = AnkiFieldTemplate.appliedDefaultMappings(
            noteType: "Lapis",
            availableFields: ["Expression", "Sentence", "SentenceAudio", "Picture", "ExtraField"],
            existing: [
                "Expression": "{custom-expression}",
                "Sentence": Handlebars.videoSubtitle.rawValue,
                "Picture": Handlebars.videoScreenshot.rawValue,
                "ExtraField": "{custom-extra}",
                "RemovedField": "{removed}"
            ]
        )
        precondition(restoredLapis["Expression"] == Handlebars.expression.rawValue)
        precondition(restoredLapis["Sentence"] == Handlebars.sentence.rawValue)
        precondition(restoredLapis["SentenceAudio"] == Handlebars.sasayakiAudio.rawValue)
        precondition(restoredLapis["Picture"] == Handlebars.bookCover.rawValue)
        precondition(restoredLapis["ExtraField"] == "{custom-extra}")
        precondition(restoredLapis["RemovedField"] == nil)

        let restoredUnified = AnkiFieldTemplate.appliedDefaultMappings(
            noteType: "Lapis",
            availableFields: ["Expression", "SentenceAudio", "Picture", "ExtraField"],
            existing: [
                "Expression": "{custom-expression}",
                "SentenceAudio": Handlebars.sasayakiAudio.rawValue,
                "Picture": Handlebars.bookCover.rawValue,
                "ExtraField": "{custom-extra}"
            ]
        )
        precondition(restoredUnified["Expression"] == Handlebars.expression.rawValue)
        precondition(restoredUnified["SentenceAudio"] == Handlebars.sasayakiAudio.rawValue)
        precondition(restoredUnified["Picture"] == Handlebars.bookCover.rawValue)
        precondition(restoredUnified["ExtraField"] == "{custom-extra}")

        let definitionPictureRegression = AnkiFieldTemplate.appliedDefaultMappings(
            noteType: "Lapis",
            availableFields: ["Expression", "DefinitionPicture", "CustomField"],
            existing: [
                "DefinitionPicture": Handlebars.glossary.rawValue,
                "CustomField": "{custom-extra}"
            ]
        )
        precondition(definitionPictureRegression["Expression"] == Handlebars.expression.rawValue)
        precondition(definitionPictureRegression["DefinitionPicture"] == nil)
        precondition(definitionPictureRegression["CustomField"] == "{custom-extra}")
        precondition(AnkiFieldTemplate.clearsMapping(noteType: "Lapis", field: "DefinitionPicture"))
        precondition(!AnkiFieldTemplate.clearsMapping(noteType: "Lapis", field: "CustomField"))
        precondition(!AnkiFieldTemplate.clearsMapping(noteType: "Kiku", field: "DefinitionPicture"))

        precondition(AnkiFieldTemplate.appliedDefaultMappings(
            noteType: "Custom",
            availableFields: ["Front"],
            existing: unknown
        ) == unknown)
        precondition(AnkiFieldTemplate.hasDefaults(noteType: "Lapis"))
        precondition(!AnkiFieldTemplate.hasDefaults(noteType: "Custom"))

        precondition(Handlebars.phoneticTranscriptions.rawValue == "{phonetic-transcriptions}")

        let profileConfig = AnkiProfileConfig(
            selectedDeck: "English Mining",
            selectedNoteType: "Lapis",
            allowDupes: false,
            compactGlossaries: true,
            embedMedia: true,
            fieldMappings: ["Pronunciation": Handlebars.phoneticTranscriptions.rawValue],
            tags: "english",
            duplicateScope: .deck,
            checkAllModels: true
        )
        let profileData = try! JSONEncoder().encode(profileConfig)
        let profileJSON = String(decoding: profileData, as: UTF8.self)
        precondition(!profileJSON.contains("url"))
        precondition(!profileJSON.contains("timeout"))
        precondition(!profileJSON.contains("forceSync"))
        let decodedProfileConfig = try! JSONDecoder().decode(AnkiProfileConfig.self, from: profileData)
        precondition(decodedProfileConfig == profileConfig)

        let manager = try! String(contentsOfFile: "Core/AnkiManager.swift", encoding: .utf8)
        let popup = try! String(contentsOfFile: "Features/Popup/popup.js", encoding: .utf8)
        precondition(manager.contains("case .phoneticTranscriptions:"))
        precondition(manager.contains("content[\"phoneticTranscriptions\"]"))
        precondition(popup.contains("constructPhoneticTranscriptionsHtml"))
        precondition(popup.contains("function escapeHtml(value)"))
        precondition(popup.contains("escapeHtml(transcription)"))
        precondition(popup.contains("phoneticTranscriptions,"))
        let settings = try! String(contentsOfFile: "Features/Settings/AnkiView.swift", encoding: .utf8)
        precondition(manager.contains("func autofillFieldMappings() -> Bool"))
        precondition(manager.contains("if autofillFieldMappings() {"))
        precondition(manager.contains("pruneFieldMappings(availableFields: noteType.fields)\n            autofillFieldMappings()"))
        precondition(manager.contains("func applyDefaultFieldMappings() -> Bool"))
        precondition(settings.contains("ankiManager.autofillFieldMappings()\n                            ankiManager.save()"))
        precondition(settings.contains("Apply Defaults"))
        precondition(!settings.contains("Apply Novel Defaults"))
        precondition(!settings.contains("Apply Anime Defaults"))
        precondition(settings.contains("ankiManager.applyDefaultFieldMappings()"))
        precondition(settings.contains("ankiManager.setFieldMapping(\"\", for: field)"))
        precondition(manager.contains("fieldMappings[field] = \"\""))

        print("Anki field template tests passed")
    }
}
