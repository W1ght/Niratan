//
//  Dictionary.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum DictionaryType: String, Codable, Sendable {
    case term = "Term"
    case frequency = "Frequency"
    case pitch = "Pitch"
    case kanji = "Kanji"
}

enum DictionaryCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, monolingual, bilingual, exclude

    var id: String { rawValue }
}

enum DictionaryReorder {
    private static let payloadPrefix = "hoshi-dictionary:"

    static func payload(for dictionaryID: UUID) -> String {
        payloadPrefix + dictionaryID.uuidString
    }

    static func dictionaryID(from payload: String) -> UUID? {
        guard payload.hasPrefix(payloadPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(payloadPrefix.count)))
    }

    static func destinationOffset(
        sourceIndex: Int,
        targetIndex: Int
    ) -> Int? {
        guard sourceIndex != targetIndex else { return nil }
        return targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
    }
}

nonisolated enum DictionaryUpdateAvailability {
    static func shouldOfferUpdate(localRevision: String, remoteRevision: String) -> Bool {
        localRevision != remoteRevision
    }
}

nonisolated enum DictionaryUpdateSourceResolver {
    static func updateCapableIndex(
        for index: DictionaryIndex,
        type: DictionaryType,
        recommendations: [DictionaryRecommendation] = DictionaryRecommendation.all
    ) -> DictionaryIndex? {
        let localIndexURL = index.indexUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localIndexURL.isEmpty {
            return index.withUpdateSource(indexURL: localIndexURL, downloadURL: index.downloadUrl)
        }

        guard let recommendation = recommendations.first(where: { recommendation in
            recommendation.type == type
                && recommendation.indexURL != nil
                && title(index.title, matchesRecommendationName: recommendation.name)
        }), let indexURL = recommendation.indexURL else {
            return nil
        }

        return index.withUpdateSource(indexURL: indexURL, downloadURL: recommendation.downloadURL ?? "")
    }

    private static func title(_ title: String, matchesRecommendationName recommendationName: String) -> Bool {
        let titleVariants = normalizedTitleVariants(for: title)
        let normalizedRecommendationName = normalizedTitle(recommendationName)
        return titleVariants.contains(normalizedRecommendationName)
    }

    private static func normalizedTitleVariants(for title: String) -> Set<String> {
        let normalized = normalizedTitle(title)
        var variants: Set<String> = [normalized]

        let bracketSuffixPattern = #"\s*\[[^\]]+\]\s*$"#
        if let range = normalized.range(of: bracketSuffixPattern, options: .regularExpression) {
            var trimmed = normalized
            trimmed.removeSubrange(range)
            variants.insert(trimmed.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return variants
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

nonisolated struct DictionaryRecommendation: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: DictionaryType
    let indexURL: String?
    let downloadURL: String?
    let language: ContentLanguageProfile

    static func forLanguage(_ language: ContentLanguageProfile) -> [DictionaryRecommendation] {
        all.filter { $0.language == language }
    }

    static let all: [DictionaryRecommendation] = [
        .init(id: "jmdict", name: "JMdict", type: .term, indexURL: "https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/JMdict_english_without_proper_names.json", downloadURL: nil, language: .japanese),
        .init(id: "jmnedict", name: "JMnedict", type: .term, indexURL: "https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/JMnedict.json", downloadURL: nil, language: .japanese),
        .init(id: "jiten", name: "Jiten", type: .frequency, indexURL: "https://api.jiten.moe/api/frequency-list/index", downloadURL: nil, language: .japanese),
        .init(id: "jitendex", name: "Jitendex", type: .term, indexURL: "https://jitendex.org/static/yomitan.json", downloadURL: nil, language: .japanese),
        .init(id: "kanjidic", name: "KANJIDIC", type: .kanji, indexURL: "https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/KANJIDIC_english.json", downloadURL: nil, language: .japanese),
        .init(id: "wty-en-en", name: "Wiktionary English-English", type: .term, indexURL: "https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/index/wty-en-en-index.json?download=true", downloadURL: nil, language: .english),
        .init(id: "wty-en-en-ipa", name: "Wiktionary English-English IPA", type: .pitch, indexURL: "https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/index/wty-en-en-ipa-index.json?download=true", downloadURL: nil, language: .english),
        .init(id: "wty-simple-simple", name: "Wiktionary Simple English-Simple English", type: .term, indexURL: "https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/index/wty-simple-simple-index.json?download=true", downloadURL: nil, language: .english),
        .init(id: "wty-en-ja", name: "Wiktionary English-Japanese", type: .term, indexURL: "https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/index/wty-en-ja-index.json?download=true", downloadURL: nil, language: .english),
        .init(id: "wty-en-ja-gloss", name: "Wiktionary English-Japanese Glossary", type: .term, indexURL: "https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/index/wty-en-ja-gloss-index.json?download=true", downloadURL: nil, language: .english),
        .init(id: "leipzig-english-web-rank", name: "Leipzig English Web", type: .frequency, indexURL: nil, downloadURL: "https://github.com/StefanVukovic99/leipzig-to-yomitan/releases/latest/download/Leipzig.English.Web.Rank.zip", language: .english),
        .init(id: "leipzig-english-wikipedia-rank", name: "Leipzig English Wikipedia", type: .frequency, indexURL: nil, downloadURL: "https://github.com/StefanVukovic99/leipzig-to-yomitan/releases/latest/download/Leipzig.English.Wikipedia.Rank.zip", language: .english),
    ]
}

struct DictionaryInfo: Identifiable, Codable {
    let id: UUID
    let index: DictionaryIndex
    let path: URL
    var isEnabled: Bool
    var order: Int
    var category: DictionaryCategory
    
    init(id: UUID = UUID(), index: DictionaryIndex, path: URL, isEnabled: Bool = true, order: Int = 0, category: DictionaryCategory = .none) {
        self.id = id
        self.index = index
        self.path = path
        self.isEnabled = isEnabled
        self.order = order
        self.category = category
    }
}

struct DictionaryConfig: Codable {
    var termDictionaries: [DictionaryEntry]
    var frequencyDictionaries: [DictionaryEntry]
    var pitchDictionaries: [DictionaryEntry]
    var kanjiDictionaries: [DictionaryEntry]?
    
    struct DictionaryEntry: Codable {
        let fileName: String
        var isEnabled: Bool
        var order: Int
        var category: DictionaryCategory? = nil
    }
}

nonisolated struct DictionaryIndex: Codable {
    let title: String
    let format: Int
    let revision: String
    let isUpdatable: Bool
    let indexUrl: String
    let downloadUrl: String

    func withUpdateSource(indexURL: String, downloadURL: String) -> DictionaryIndex {
        DictionaryIndex(
            title: title,
            format: format,
            revision: revision,
            isUpdatable: true,
            indexUrl: indexURL,
            downloadUrl: downloadURL
        )
    }
}

struct AudioSource: Codable, Identifiable {
    var id: String { url }
    var name: String
    let url: String
    var isEnabled: Bool
    let isDefault: Bool
    
    init(name: String = "", url: String, isEnabled: Bool = true, isDefault: Bool = false) {
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.isDefault = isDefault
    }
}

enum AudioSourceReorder {
    private static let payloadPrefix = "hoshi-audio-source:"

    static func payload(for audioSourceID: String) -> String {
        payloadPrefix + audioSourceID
    }

    static func audioSourceID(from payload: String) -> String? {
        guard payload.hasPrefix(payloadPrefix) else { return nil }
        let id = String(payload.dropFirst(payloadPrefix.count))
        return id.isEmpty ? nil : id
    }

    static func destinationOffset(sourceIndex: Int, targetIndex: Int) -> Int? {
        guard sourceIndex != targetIndex else { return nil }
        return targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
    }

    static func synchronizingLocalSource(
        _ sources: [AudioSource],
        enabled: Bool,
        canonicalSource: AudioSource,
        legacyURLs: Set<String>
    ) -> [AudioSource] {
        let localURLs = legacyURLs.union([canonicalSource.url])
        let existingIndex = sources.firstIndex { localURLs.contains($0.url) }
        let existingSource = existingIndex.map { sources[$0] }
        var synchronized = sources.filter { !localURLs.contains($0.url) }

        guard enabled else { return synchronized }

        var localSource = canonicalSource
        if let existingSource {
            localSource.isEnabled = existingSource.isEnabled
        }
        synchronized.insert(
            localSource,
            at: min(existingIndex ?? 0, synchronized.endIndex)
        )
        return synchronized
    }
}
