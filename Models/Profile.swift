//
//  Profile.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum ContentLanguageProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }

    static func normalize(_ language: String?) -> ContentLanguageProfile? {
        guard let language else { return nil }
        let primary = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)
        return primary.flatMap(ContentLanguageProfile.init(rawValue:))
    }

    func displayCount(forRawCharacters count: Int) -> Int {
        let count = max(0, count)
        switch self {
        case .japanese:
            return count
        case .english:
            guard count > 0 else { return 0 }
            return Int(ceil(Double(count) / 5.0))
        }
    }

    func rawCharacters(forDisplayCount count: Int) -> Int {
        switch self {
        case .japanese:
            return max(0, count)
        case .english:
            return max(0, count) * 5
        }
    }
}

struct HoshiProfile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    let dictionaryLanguageId: String
    var isDefault: Bool

    init(id: String, name: String, dictionaryLanguageId: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.dictionaryLanguageId = dictionaryLanguageId
        self.isDefault = isDefault
    }

    var language: ContentLanguageProfile {
        ContentLanguageProfile(rawValue: dictionaryLanguageId) ?? .japanese
    }

    var displayName: String {
        if id == Self.defaultJapanese.id, ["Japanese", "Japanese EPUB"].contains(name) {
            return String(localized: "Japanese")
        }
        return name
    }

    static let defaultJapanese = HoshiProfile(
        id: "default-ja",
        name: "Japanese",
        dictionaryLanguageId: ContentLanguageProfile.japanese.rawValue,
        isDefault: true
    )

}

struct ProfileIndex: Codable, Equatable, Sendable {
    var profiles: [HoshiProfile]
    var defaultProfileId: String
    var globalActiveProfileId: String
    var primaryProfileIdsByLanguage: [String: String]

    static let initial = ProfileIndex(
        profiles: [.defaultJapanese],
        defaultProfileId: HoshiProfile.defaultJapanese.id,
        globalActiveProfileId: HoshiProfile.defaultJapanese.id,
        primaryProfileIdsByLanguage: [
            ContentLanguageProfile.japanese.rawValue: HoshiProfile.defaultJapanese.id
        ]
    )
}

enum ProfileContext: Equatable, Sendable {
    case global
    case book(profileID: String?, bookLanguage: String?)
    case video(profileID: String?)
}

enum ProfileResolver {
    static func resolve(_ context: ProfileContext, in index: ProfileIndex) -> HoshiProfile {
        // Legacy book/video contexts remain representable, but runtime selection is global.
        let byID = Dictionary(uniqueKeysWithValues: index.profiles.map { ($0.id, $0) })
        return byID[index.globalActiveProfileId]
            ?? byID[index.defaultProfileId]
            ?? index.profiles.first
            ?? .defaultJapanese
    }
}

struct ReaderProfileSettings: Codable, Equatable, Sendable {
    var theme: String
    var uiTheme: String
    var systemLightSepia: Bool
    var sepiaInvertInDark: Bool
    var customBackgroundColor: String
    var customTextColor: String
    var customInfoColor: String
    var verticalWriting: Bool
    var selectedFont: String
    var fontSize: Int
    var hideFurigana: Bool
    var furiganaMode: String? = nil
    var continuousMode: Bool
    var twoColumnHorizontalPages: Bool? = nil
    var paragraphMode: Bool? = nil
    var textAnimation: Bool? = nil
    var textSpeed: Int? = nil
    var horizontalPadding: Int
    var verticalPadding: Int
    var avoidPageBreak: Bool
    var justifyText: Bool
    var blurImages: Bool
    var layoutAdvanced: Bool
    var lineHeight: Double
    var characterSpacing: Double
    var paragraphSpacing: Double
    var showTitle: Bool
    var showCharacters: Bool
    var showProgress: Bool? = nil
    var showChapterProgress: Bool? = nil
    var progressCount: String? = nil
    var showPercentage: Bool
    var showProgressTop: Bool
    var showStatisticsToggle: Bool
    var showReadingSpeed: Bool
    var showReadingTime: Bool
    var showSasayakiToggle: Bool

    static let defaults = ReaderProfileSettings(
        theme: "System",
        uiTheme: "System",
        systemLightSepia: false,
        sepiaInvertInDark: false,
        customBackgroundColor: "#FFFFFFFF",
        customTextColor: "#000000FF",
        customInfoColor: "#999999FF",
        verticalWriting: true,
        selectedFont: "Hiragino Mincho ProN",
        fontSize: 22,
        hideFurigana: false,
        furiganaMode: "Off",
        continuousMode: false,
        twoColumnHorizontalPages: false,
        paragraphMode: false,
        textAnimation: false,
        textSpeed: 35,
        horizontalPadding: 5,
        verticalPadding: 0,
        avoidPageBreak: false,
        justifyText: false,
        blurImages: false,
        layoutAdvanced: false,
        lineHeight: 1.65,
        characterSpacing: 0,
        paragraphSpacing: 0,
        showTitle: true,
        showCharacters: true,
        showProgress: true,
        showChapterProgress: false,
        progressCount: "Characters",
        showPercentage: true,
        showProgressTop: true,
        showStatisticsToggle: false,
        showReadingSpeed: false,
        showReadingTime: false,
        showSasayakiToggle: false
    )
}

struct DictionaryProfileSettings: Codable, Equatable, Sendable {
    var dictionaryTabDefault: Bool
    var scanNonJapaneseText: Bool
    var maxResults: Int
    var scanLength: Int
    var collapseMode: String
    var expandFirstDictionary: Bool
    var twoColumnLayout: Bool? = nil
    var compactGlossaries: Bool
    var showExpressionTags: Bool
    var harmonicFrequency: Bool
    var deduplicatePitchAccents: Bool
    var compactPitchAccents: Bool
    var customCSS: String
    var frequencySortOrder: String? = nil
    var frequencySortDictionary: String? = nil
    var searchTextSize: Int? = nil

    static let defaults = DictionaryProfileSettings(
        dictionaryTabDefault: false,
        scanNonJapaneseText: true,
        maxResults: 16,
        scanLength: 16,
        collapseMode: "Expand All",
        expandFirstDictionary: false,
        twoColumnLayout: false,
        compactGlossaries: true,
        showExpressionTags: false,
        harmonicFrequency: false,
        deduplicatePitchAccents: false,
        compactPitchAccents: true,
        customCSS: "",
        frequencySortOrder: "Auto",
        frequencySortDictionary: "",
        searchTextSize: 26
    )
}
