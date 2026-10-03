//
//  Anki.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

struct AnkiResponse: Decodable {
    let profiles: [NameItem]
    let decks: [NameItem]
    let notetypes: [NoteTypeItem]
    
    struct NameItem: Decodable { let name: String }
    struct NoteTypeItem: Decodable {
        let name: String
        let fields: [NameItem]
    }
}

struct AnkiNoteType: Codable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let fields: [String]
}

struct AnkiConfig: Codable {
    let selectedDeck: String?
    let selectedNoteType: String?
    let allowDupes: Bool
    let compactGlossaries: Bool?
    let embedMedia: Bool?
    let fieldMappings: [String: String]
    var tags: String?
    let availableDecks: [String]
    let availableNoteTypes: [AnkiNoteType]
    let useAnkiConnect: Bool?
    let ankiConnectConfig: AnkiConnectConfig?
    var compressVideoScreenshots: Bool? = nil
    var compressImages: Bool? = nil
    var imageCompressionQuality: Double? = nil
    var imageCompressionFormat: AnkiImageCompressionFormat? = nil
    var animatedAVIFMaximumHeight: Int? = nil
    var animatedAVIFFramesPerSecond: Int? = nil
    var audioCompressionFormat: AnkiAudioCompressionFormat? = nil
    var audioCompressionBitrateKbps: Int? = nil

    var effectiveCompressVideoScreenshots: Bool {
        effectiveCompressImages
    }

    var effectiveCompressImages: Bool {
        compressImages ?? compressVideoScreenshots ?? true
    }

    var effectiveAudioCompressionFormat: AnkiAudioCompressionFormat {
        audioCompressionFormat ?? .aac
    }

    var effectiveImageCompressionQuality: Double {
        min(0.95, max(0.40, imageCompressionQuality ?? 0.80))
    }

    var effectiveImageCompressionFormat: AnkiImageCompressionFormat {
        imageCompressionFormat ?? .jpeg
    }

    var effectiveAnimatedAVIFMaximumHeight: Int {
        AnkiAnimatedAVIFConfiguration.clampedMaximumHeight(animatedAVIFMaximumHeight)
    }

    var effectiveAnimatedAVIFFramesPerSecond: Int {
        AnkiAnimatedAVIFConfiguration.clampedFramesPerSecond(animatedAVIFFramesPerSecond)
    }

    var effectiveAudioCompressionBitrateKbps: Int {
        min(192, max(32, audioCompressionBitrateKbps ?? 64))
    }

    func updatingSharedState(
        availableDecks: [String],
        availableNoteTypes: [AnkiNoteType],
        ankiConnectConfig: AnkiConnectConfig?
    ) -> AnkiConfig {
        let mergedAnkiConnectConfig = ankiConnectConfig.map { shared in
            AnkiConnectConfig(
                url: shared.url,
                timeout: shared.timeout,
                duplicateScope: self.ankiConnectConfig?.duplicateScope ?? .collection,
                checkAllModels: self.ankiConnectConfig?.checkAllModels ?? false,
                forceSync: shared.forceSync,
                apiKey: shared.apiKey
            )
        }
        return AnkiConfig(
            selectedDeck: selectedDeck,
            selectedNoteType: selectedNoteType,
            allowDupes: allowDupes,
            compactGlossaries: compactGlossaries,
            embedMedia: embedMedia,
            fieldMappings: fieldMappings,
            tags: tags,
            availableDecks: availableDecks,
            availableNoteTypes: availableNoteTypes,
            useAnkiConnect: useAnkiConnect,
            ankiConnectConfig: mergedAnkiConnectConfig,
            compressVideoScreenshots: compressVideoScreenshots,
            compressImages: compressImages,
            imageCompressionQuality: imageCompressionQuality,
            imageCompressionFormat: imageCompressionFormat,
            animatedAVIFMaximumHeight: animatedAVIFMaximumHeight,
            animatedAVIFFramesPerSecond: animatedAVIFFramesPerSecond,
            audioCompressionFormat: audioCompressionFormat,
            audioCompressionBitrateKbps: audioCompressionBitrateKbps
        )
    }
}

struct AnkiProfileConfig: Codable, Equatable {
    let selectedDeck: String?
    let selectedNoteType: String?
    let allowDupes: Bool
    let compactGlossaries: Bool
    let embedMedia: Bool
    let fieldMappings: [String: String]
    let tags: String
    let duplicateScope: DuplicateScope
    let checkAllModels: Bool
    var compressVideoScreenshots: Bool? = nil
    var compressImages: Bool? = nil
    var imageCompressionQuality: Double? = nil
    var imageCompressionFormat: AnkiImageCompressionFormat? = nil
    var animatedAVIFMaximumHeight: Int? = nil
    var animatedAVIFFramesPerSecond: Int? = nil
    var audioCompressionFormat: AnkiAudioCompressionFormat? = nil
    var audioCompressionBitrateKbps: Int? = nil

    var effectiveCompressVideoScreenshots: Bool {
        effectiveCompressImages
    }

    var effectiveCompressImages: Bool {
        compressImages ?? compressVideoScreenshots ?? true
    }

    var effectiveAudioCompressionFormat: AnkiAudioCompressionFormat {
        audioCompressionFormat ?? .aac
    }

    var effectiveImageCompressionQuality: Double {
        min(0.95, max(0.40, imageCompressionQuality ?? 0.80))
    }

    var effectiveImageCompressionFormat: AnkiImageCompressionFormat {
        imageCompressionFormat ?? .jpeg
    }

    var effectiveAnimatedAVIFMaximumHeight: Int {
        AnkiAnimatedAVIFConfiguration.clampedMaximumHeight(animatedAVIFMaximumHeight)
    }

    var effectiveAnimatedAVIFFramesPerSecond: Int {
        AnkiAnimatedAVIFConfiguration.clampedFramesPerSecond(animatedAVIFFramesPerSecond)
    }

    var effectiveAudioCompressionBitrateKbps: Int {
        min(192, max(32, audioCompressionBitrateKbps ?? 64))
    }
}

enum AnkiAnimatedAVIFConfiguration {
    static let defaultMaximumHeight = 350
    static let maximumHeightRange = 100...1080
    static let maximumHeightSliderRange = Double(maximumHeightRange.lowerBound)...Double(maximumHeightRange.upperBound)
    static let defaultFramesPerSecond = 10
    static let framesPerSecondRange = 1...30
    static let framesPerSecondSliderRange = Double(framesPerSecondRange.lowerBound)...Double(framesPerSecondRange.upperBound)

    static func clampedMaximumHeight(_ value: Int?) -> Int {
        min(
            maximumHeightRange.upperBound,
            max(maximumHeightRange.lowerBound, value ?? defaultMaximumHeight)
        )
    }

    static func clampedFramesPerSecond(_ value: Int?) -> Int {
        min(
            framesPerSecondRange.upperBound,
            max(framesPerSecondRange.lowerBound, value ?? defaultFramesPerSecond)
        )
    }
}

enum AnkiAudioCompressionFormat: String, Codable, CaseIterable, Identifiable {
    case aac
    case mp3

    var id: Self { self }

    var fileExtension: String {
        switch self {
        case .aac: "m4a"
        case .mp3: "mp3"
        }
    }

    var displayName: String {
        switch self {
        case .aac: "AAC (.m4a)"
        case .mp3: "MP3 (.mp3)"
        }
    }
}

enum AnkiImageCompressionFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg
    case avif

    var id: Self { self }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .avif: "avif"
        }
    }

    var displayName: String {
        switch self {
        case .jpeg: String(localized: "JPEG (.jpg)")
        case .avif: String(localized: "AVIF (.avif)")
        }
    }
}

enum VideoScreenshotFormat: String, Equatable {
    case png
    case jpeg
    case avif

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .avif: "avif"
        }
    }

    init(_ format: AnkiImageCompressionFormat) {
        switch format {
        case .jpeg: self = .jpeg
        case .avif: self = .avif
        }
    }
}

enum DuplicateScope: String, Codable, CaseIterable {
    case collection
    case deck
    case deckroot

    /// AnkiConnect `addNote` options for this duplicate policy.
    func ankiConnectOptions(deck: String, allowDuplicates: Bool, checkAllModels: Bool) -> [String: Any] {
        var options: [String: Any] = ["allowDuplicate": allowDuplicates]
        var scopeOptions: [String: Any] = [:]
        switch self {
        case .collection:
            options["duplicateScope"] = "collection"
        case .deck:
            options["duplicateScope"] = "deck"
        case .deckroot:
            options["duplicateScope"] = "deck"
            let rootDeck = deck.split(separator: "::", maxSplits: 1).first.map(String.init) ?? deck
            scopeOptions["deckName"] = rootDeck
            scopeOptions["checkChildren"] = true
        }
        if checkAllModels {
            scopeOptions["checkAllModels"] = true
        }
        if !scopeOptions.isEmpty {
            options["duplicateScopeOptions"] = scopeOptions
        }
        return options
    }
}

struct AnkiConnectConfig: Codable {
    var url: String?
    var timeout: Int
    var duplicateScope: DuplicateScope
    var checkAllModels: Bool? = false
    var forceSync: Bool
    var apiKey: String?
}

struct MiningContext {
    let sentence: String
    let documentTitle: String?
    let coverURL: URL?
    var profileID: String? = nil
    var sasayakiAudioData: Data? = nil
    var sasayakiAudioFormat: AnkiAudioCompressionFormat = .aac
    var manga: MangaMiningContext? = nil
    var video: VideoMiningContext? = nil
}

struct MangaMiningContext {
    let pageIndex: Int
    let imageData: Data
    let imageExtension: String
}

struct VideoMiningContext: Equatable {
    let fileName: String
    let cueText: String
    let cueStart: TimeInterval
    let cueEnd: TimeInterval
    let previousCueText: String?
    let nextCueText: String?
    var screenshotFilename: String? = nil
    var audioClipFilename: String? = nil
    var screenshotURL: URL? = nil
    var audioClipURL: URL? = nil
    var screenshotErrorMessage: String? = nil
    var audioClipErrorMessage: String? = nil

    var timestamp: String {
        Self.formatTimestamp(cueStart)
    }

    func value(for handlebar: Handlebars) -> String {
        switch handlebar {
        case .videoFileName:
            fileName
        case .videoTimestamp:
            timestamp
        case .videoCueStart:
            Self.formatTimestamp(cueStart)
        case .videoCueEnd:
            Self.formatTimestamp(cueEnd)
        case .videoSubtitle:
            cueText
        case .videoPreviousSubtitle:
            previousCueText ?? ""
        case .videoNextSubtitle:
            nextCueText ?? ""
        case .videoScreenshot:
            screenshotFilename ?? screenshotURL?.path ?? ""
        case .videoAudioClip:
            audioClipFilename ?? audioClipURL?.path ?? ""
        default:
            ""
        }
    }

    static func deterministicMediaFilenames(
        videoURL: URL,
        cueStart: TimeInterval,
        cueEnd: TimeInterval,
        audioStart: TimeInterval,
        audioEnd: TimeInterval,
        screenshotFormat: VideoScreenshotFormat,
        screenshotStart: TimeInterval? = nil,
        screenshotEnd: TimeInterval? = nil,
        screenshotQuality: Double = 0.80,
        animatedAVIFMaximumHeight: Int = AnkiAnimatedAVIFConfiguration.defaultMaximumHeight,
        animatedAVIFFramesPerSecond: Int = AnkiAnimatedAVIFConfiguration.defaultFramesPerSecond,
        audioFormat: AnkiAudioCompressionFormat = .aac,
        audioBitrateKbps: Int = 64
    ) -> VideoMiningMediaFilenames {
        deterministicMediaFilenames(
            identityKey: videoURL.standardizedFileURL.path(percentEncoded: false),
            cueStart: cueStart,
            cueEnd: cueEnd,
            audioStart: audioStart,
            audioEnd: audioEnd,
            screenshotFormat: screenshotFormat,
            screenshotStart: screenshotStart,
            screenshotEnd: screenshotEnd,
            screenshotQuality: screenshotQuality,
            animatedAVIFMaximumHeight: animatedAVIFMaximumHeight,
            animatedAVIFFramesPerSecond: animatedAVIFFramesPerSecond,
            audioFormat: audioFormat,
            audioBitrateKbps: audioBitrateKbps
        )
    }

    static func deterministicMediaFilenames(
        identityKey: String,
        cueStart: TimeInterval,
        cueEnd: TimeInterval,
        audioStart: TimeInterval,
        audioEnd: TimeInterval,
        screenshotFormat: VideoScreenshotFormat,
        screenshotStart: TimeInterval? = nil,
        screenshotEnd: TimeInterval? = nil,
        screenshotQuality: Double = 0.80,
        animatedAVIFMaximumHeight: Int = AnkiAnimatedAVIFConfiguration.defaultMaximumHeight,
        animatedAVIFFramesPerSecond: Int = AnkiAnimatedAVIFConfiguration.defaultFramesPerSecond,
        audioFormat: AnkiAudioCompressionFormat = .aac,
        audioBitrateKbps: Int = 64
    ) -> VideoMiningMediaFilenames {
        let sourceHash = sha1Hex(identityKey)
        let cueRange = millisecondRange(start: cueStart, end: cueEnd)
        let animatedScreenshotRange = millisecondRange(
            start: screenshotStart ?? cueStart,
            end: screenshotEnd ?? cueEnd
        )
        let audioRange = millisecondRange(start: audioStart, end: audioEnd)
        let qualityPercent = Int((min(0.95, max(0.40, screenshotQuality)) * 100).rounded())
        let maximumHeight = AnkiAnimatedAVIFConfiguration.clampedMaximumHeight(
            animatedAVIFMaximumHeight
        )
        let framesPerSecond = AnkiAnimatedAVIFConfiguration.clampedFramesPerSecond(
            animatedAVIFFramesPerSecond
        )
        let screenshotQualityToken: String
        if screenshotFormat == .avif {
            // Version the mpvacious-style animation profile and fold the user's
            // Image Quality setting into the name so retuned AVIF media is
            // regenerated and different quality choices never collide.
            let resolutionToken = maximumHeight == AnkiAnimatedAVIFConfiguration.defaultMaximumHeight
                ? ""
                : "_h\(maximumHeight)"
            let frameRateToken = framesPerSecond == AnkiAnimatedAVIFConfiguration.defaultFramesPerSecond
                ? ""
                : "_fps\(framesPerSecond)"
            screenshotQualityToken = "_avif5"
                + (qualityPercent != 80 ? "_q\(qualityPercent)" : "")
                + resolutionToken
                + frameRateToken
        } else {
            screenshotQualityToken = screenshotFormat != .png && qualityPercent != 80
                ? "_q\(qualityPercent)"
                : ""
        }
        let clampedBitrate = min(192, max(32, audioBitrateKbps))
        let audioBitrateToken = clampedBitrate == 64 ? "" : "_\(clampedBitrate)k"
        let screenshotRange = screenshotFormat == .avif ? animatedScreenshotRange : cueRange
        return VideoMiningMediaFilenames(
            screenshot: "hoshi_video_frame_\(sourceHash)_\(screenshotRange)\(screenshotQualityToken).\(screenshotFormat.fileExtension)",
            audioClip: "hoshi_video_audio_\(sourceHash)_\(audioRange)\(audioBitrateToken).\(audioFormat.fileExtension)"
        )
    }

    private static func formatTimestamp(_ time: TimeInterval) -> String {
        let milliseconds = max(0, Int((time * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1000) % 60
        let remainder = milliseconds % 1000
        return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, remainder)
    }

    private static func millisecondRange(start: TimeInterval, end: TimeInterval) -> String {
        "\(milliseconds(start))-\(milliseconds(end))"
    }

    private static func milliseconds(_ time: TimeInterval) -> Int {
        max(0, Int((time * 1000).rounded()))
    }

    private static func sha1Hex(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct VideoMiningMediaFilenames: Equatable {
    let screenshot: String
    let audioClip: String
}

struct DictionaryMedia: Decodable {
    let dictionary: String
    let path: String
    let filename: String
}

enum Handlebars: String, CaseIterable {
    case expression = "{expression}"
    case reading = "{reading}"
    case furiganaPlain = "{furigana-plain}"
    case audio = "{audio}"
    case glossary = "{glossary}"
    case glossaryBrief = "{glossary-brief}"
    case glossaryNoDictionary = "{glossary-no-dictionary}"
    case glossaryFirst = "{glossary-first}"
    case glossaryFirstBrief = "{glossary-first-brief}"
    case glossaryFirstNoDictionary = "{glossary-first-no-dictionary}"
    case monolingualDefinition = "{monolingual-definition}"
    case monolingualDefinitionBrief = "{monolingual-definition-brief}"
    case monolingualDefinitionNoDictionary = "{monolingual-definition-no-dictionary}"
    case bilingualDefinition = "{bilingual-definition}"
    case bilingualDefinitionBrief = "{bilingual-definition-brief}"
    case bilingualDefinitionNoDictionary = "{bilingual-definition-no-dictionary}"
    case monolingualDefinitionFallback = "{monolingual-definition-fallback}"
    case monolingualDefinitionFallbackBrief = "{monolingual-definition-fallback-brief}"
    case monolingualDefinitionFallbackNoDictionary = "{monolingual-definition-fallback-no-dictionary}"
    case bilingualDefinitionFallback = "{bilingual-definition-fallback}"
    case bilingualDefinitionFallbackBrief = "{bilingual-definition-fallback-brief}"
    case bilingualDefinitionFallbackNoDictionary = "{bilingual-definition-fallback-no-dictionary}"
    case selectedGlossary = "{selected-glossary}"
    case selectedGlossaryFallback = "{selected-glossary-fallback}"
    case selectedGlossaryBrief = "{selected-glossary-brief}"
    case selectedGlossaryBriefFallback = "{selected-glossary-brief-fallback}"
    case selectedGlossaryNoDictionary = "{selected-glossary-no-dictionary}"
    case selectedGlossaryNoDictionaryFallback = "{selected-glossary-no-dictionary-fallback}"
    case popupSelectionText = "{popup-selection-text}"
    case sentence = "{sentence}"
    case frequencies = "{frequencies}"
    case frequencyHarmonicRank = "{frequency-harmonic-rank}"
    case pitchPositions = "{pitch-accent-positions}"
    case pitchCategories = "{pitch-accent-categories}"
    case phoneticTranscriptions = "{phonetic-transcriptions}"
    case documentTitle = "{document-title}"
    case bookCover = "{book-cover}"
    case sasayakiAudio = "{sasayaki-audio}"
    case videoFileName = "{video-file-name}"
    case videoTimestamp = "{video-timestamp}"
    case videoCueStart = "{video-cue-start}"
    case videoCueEnd = "{video-cue-end}"
    case videoSubtitle = "{video-subtitle}"
    case videoPreviousSubtitle = "{video-previous-subtitle}"
    case videoNextSubtitle = "{video-next-subtitle}"
    case videoScreenshot = "{video-screenshot}"
    case videoAudioClip = "{video-audio-clip}"
    
    static let singleGlossaryPrefix = "{single-glossary-"

    var isVideoSpecific: Bool {
        switch self {
        case .videoFileName, .videoTimestamp, .videoCueStart, .videoCueEnd,
             .videoSubtitle, .videoPreviousSubtitle, .videoNextSubtitle,
             .videoScreenshot, .videoAudioClip:
            true
        default:
            false
        }
    }
}

struct AnkiFieldTemplate {
    let noteType: String
    let mappings: [String: String]

    static let templates: [AnkiFieldTemplate] = [
        AnkiFieldTemplate(noteType: "Lapis", mappings: [
            "Expression": Handlebars.expression.rawValue,
            "ExpressionFurigana": Handlebars.furiganaPlain.rawValue,
            "ExpressionReading": Handlebars.reading.rawValue,
            "ExpressionAudio": Handlebars.audio.rawValue,
            "SelectionText": Handlebars.popupSelectionText.rawValue,
            "MainDefinition": Handlebars.glossaryFirst.rawValue,
            "Sentence": Handlebars.sentence.rawValue,
            "SentenceAudio": Handlebars.sasayakiAudio.rawValue,
            "Picture": Handlebars.bookCover.rawValue,
            "Glossary": Handlebars.glossary.rawValue,
            "PitchPosition": Handlebars.pitchPositions.rawValue,
            "PitchCategories": Handlebars.pitchCategories.rawValue,
            "Frequency": Handlebars.frequencies.rawValue,
            "FreqSort": Handlebars.frequencyHarmonicRank.rawValue,
            "MiscInfo": Handlebars.documentTitle.rawValue,
        ]),
        AnkiFieldTemplate(noteType: "Kiku", mappings: [
            "Expression": Handlebars.expression.rawValue,
            "ExpressionFurigana": Handlebars.furiganaPlain.rawValue,
            "ExpressionReading": Handlebars.reading.rawValue,
            "ExpressionAudio": Handlebars.audio.rawValue,
            "SelectionText": Handlebars.popupSelectionText.rawValue,
            "MainDefinition": Handlebars.glossaryFirst.rawValue,
            "Sentence": Handlebars.sentence.rawValue,
            "Picture": Handlebars.bookCover.rawValue,
            "Glossary": Handlebars.glossary.rawValue,
            "PitchPosition": Handlebars.pitchPositions.rawValue,
            "PitchCategories": Handlebars.pitchCategories.rawValue,
            "Frequency": Handlebars.frequencies.rawValue,
            "FreqSort": Handlebars.frequencyHarmonicRank.rawValue,
            "MiscInfo": Handlebars.documentTitle.rawValue,
        ]),
        AnkiFieldTemplate(noteType: "Senren", mappings: [
            "word": Handlebars.expression.rawValue,
            "reading": Handlebars.reading.rawValue,
            "sentence": Handlebars.sentence.rawValue,
            "selectionText": Handlebars.popupSelectionText.rawValue,
            "definition": Handlebars.glossaryFirst.rawValue,
            "wordAudio": Handlebars.audio.rawValue,
            "picture": Handlebars.bookCover.rawValue,
            "glossary": Handlebars.glossary.rawValue,
            "pitchPositions": Handlebars.pitchPositions.rawValue,
            "pitchCategories": Handlebars.pitchCategories.rawValue,
            "frequencies": Handlebars.frequencies.rawValue,
            "freqSort": Handlebars.frequencyHarmonicRank.rawValue,
            "miscInfo": Handlebars.documentTitle.rawValue,
        ]),
    ]

    static func autofilledMappings(
        noteType: String,
        availableFields: [String],
        existing: [String: String]
    ) -> [String: String] {
        guard let template = templates.first(where: { $0.noteType == noteType }) else {
            return existing
        }

        let available = Set(availableFields)
        var result = existing.filter { available.contains($0.key) }
        for field in availableFields {
            guard let defaultValue = defaultMapping(field: field, template: template) else { continue }
            if let existingValue = result[field] {
                if existingValue.isEmpty
                    || !existingValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
            }
            result[field] = defaultValue
        }
        return result
    }

    static func appliedDefaultMappings(
        noteType: String,
        availableFields: [String],
        existing: [String: String]
    ) -> [String: String] {
        guard let template = templates.first(where: { $0.noteType == noteType }) else {
            return existing
        }

        let available = Set(availableFields)
        var result = existing.filter { available.contains($0.key) }
        for field in availableFields {
            guard let defaultValue = defaultMapping(field: field, template: template) else { continue }
            result[field] = defaultValue
        }
        for field in availableFields where clearsMapping(noteType: noteType, field: field) {
            result.removeValue(forKey: field)
        }
        return result
    }

    static func hasDefaults(noteType: String) -> Bool {
        templates.contains { $0.noteType == noteType }
    }

    static func clearsMapping(noteType: String, field: String) -> Bool {
        noteType == "Lapis" && field == "DefinitionPicture"
    }

    private static func defaultMapping(
        field: String,
        template: AnkiFieldTemplate
    ) -> String? {
        switch field.lowercased() {
        case "sentenceaudio":
            Handlebars.sasayakiAudio.rawValue
        case "picture":
            Handlebars.bookCover.rawValue
        default:
            template.mappings[field]
        }
    }
}
