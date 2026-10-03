//
//  LookupEngine.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CHoshiDicts

/// Upstream's `LookupFrequencyOrder` without `Disabled`: the pinned hoshidicts fork always
/// applies its automatic frequency ranking, so only an explicit dictionary order is added on top.
enum LookupFrequencySortOrder: String, CaseIterable, Codable, Sendable {
    case auto = "Auto"
    case ascending = "Ascending"
    case descending = "Descending"
}

@Observable
class LookupEngine {
    static let shared = LookupEngine()

    private nonisolated struct QueryConfiguration: Equatable, Sendable {
        let termPaths: [URL]
        let freqPaths: [URL]
        let pitchPaths: [URL]
        let kanjiPaths: [URL]
        let languageID: String
        let contentGeneration: UInt64
    }

    private nonisolated final class QueryBundle: @unchecked Sendable {
        let configuration: QueryConfiguration
        var dictQuery: DictionaryQuery
        var lookup: Lookup!

        init(configuration: QueryConfiguration) {
            self.configuration = configuration

            var query = DictionaryQuery()
            for path in configuration.termPaths {
                query.add_term_dict(std.string(path.path(percentEncoded: false)))
            }
            for path in configuration.freqPaths {
                query.add_freq_dict(std.string(path.path(percentEncoded: false)))
            }
            for path in configuration.pitchPaths {
                query.add_pitch_dict(std.string(path.path(percentEncoded: false)))
            }
            for path in configuration.kanjiPaths {
                query.add_kanji_dict(std.string(path.path(percentEncoded: false)))
            }

            let processor = configuration.languageID.withCString {
                language.get(std.string_view($0))
            }
            dictQuery = consume query
            lookup = Lookup(&dictQuery, processor.pointee)
        }
    }

    private var bundle: QueryBundle?
    private var activeConfiguration: QueryConfiguration?
    private var requestedConfiguration: QueryConfiguration?
    private var buildGeneration: UInt64 = 0
    private(set) var languageID = ContentLanguageProfile.japanese.rawValue
    private(set) var isReadyForLookup = false
    @ObservationIgnored var frequencySortOrder: LookupFrequencySortOrder = .auto
    @ObservationIgnored var frequencySortDictionary = ""
    
    private init() {}
    
    func buildQuery(
        termPaths: [URL],
        freqPaths: [URL],
        pitchPaths: [URL],
        kanjiPaths: [URL] = [],
        languageID: String = ContentLanguageProfile.japanese.rawValue,
        contentGeneration: UInt64
    ) {
        let normalizedLanguageID = ContentLanguageProfile(rawValue: languageID)?.rawValue
            ?? ContentLanguageProfile.japanese.rawValue
        let configuration = QueryConfiguration(
            termPaths: termPaths,
            freqPaths: freqPaths,
            pitchPaths: pitchPaths,
            kanjiPaths: kanjiPaths,
            languageID: normalizedLanguageID,
            contentGeneration: contentGeneration
        )
        if configuration == activeConfiguration {
            if requestedConfiguration != activeConfiguration {
                buildGeneration &+= 1
                requestedConfiguration = activeConfiguration
            }
            isReadyForLookup = true
            return
        }
        guard configuration != requestedConfiguration else { return }

        buildGeneration &+= 1
        let generation = buildGeneration
        requestedConfiguration = configuration
        isReadyForLookup = false
        Task.detached(priority: .userInitiated) {
            let newBundle = QueryBundle(configuration: configuration)
            await MainActor.run {
                guard generation == self.buildGeneration,
                      configuration == self.requestedConfiguration else {
                    return
                }
                self.bundle = newBundle
                self.activeConfiguration = configuration
                self.languageID = configuration.languageID
                self.isReadyForLookup = true
            }
        }
    }
    
    func lookup(_ str: String, maxResults: Int = 16, scanLength: Int = 16) -> [LookupResult] {
        guard isReadyForLookup, let bundle, activeConfiguration == requestedConfiguration else { return [] }
        let results = Array(bundle.lookup.lookup(std.string(str), Int32(maxResults), scanLength))
        return sortedByFrequencyDictionary(results)
    }

    /// Re-ranks results that the library considers equally good match-wise (same matched length and
    /// deinflection trace) by the selected frequency dictionary, keeping the library order otherwise.
    private func sortedByFrequencyDictionary(_ results: [LookupResult]) -> [LookupResult] {
        guard frequencySortOrder != .auto, !frequencySortDictionary.isEmpty, results.count > 1 else {
            return results
        }
        let descending = frequencySortOrder == .descending
        let dictionary = frequencySortDictionary
        let ranked = results.enumerated().map { offset, result in
            (
                offset: offset,
                length: String(result.matched).count,
                trace: Self.traceSortKey(result),
                frequency: Self.frequencyValue(result, dictionary: dictionary, descending: descending),
                result: result
            )
        }
        return ranked.sorted { a, b in
            if a.length != b.length {
                return a.length > b.length
            }
            if a.trace != b.trace {
                return a.trace.lexicographicallyPrecedes(b.trace)
            }
            switch (a.frequency, b.frequency) {
            case let (lhs?, rhs?) where lhs != rhs:
                return descending ? lhs > rhs : lhs < rhs
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return a.offset < b.offset
            }
        }
        .map(\.result)
    }

    private static func traceSortKey(_ result: LookupResult) -> [Int] {
        let expression = String(result.term.expression)
        var best: [Int]?
        for candidate in result.trace_candidates {
            let key = [
                Int(candidate.preprocessor_steps),
                Int(candidate.trace.size()),
                expression != String(candidate.deinflected) ? 1 : 0
            ]
            if best.map({ key.lexicographicallyPrecedes($0) }) ?? true {
                best = key
            }
        }
        return best ?? [Int.max, Int.max, 1]
    }

    private static func frequencyValue(_ result: LookupResult, dictionary: String, descending: Bool) -> Int? {
        var value: Int?
        for entry in result.term.frequencies where String(entry.dict_name) == dictionary {
            for frequency in entry.frequencies where frequency.value >= 0 {
                let candidate = Int(frequency.value)
                value = value.map { descending ? max($0, candidate) : min($0, candidate) } ?? candidate
            }
        }
        return value
    }
    
    var hasKanjiDictionaries: Bool {
        guard let requestedConfiguration else { return false }
        return !requestedConfiguration.kanjiPaths.isEmpty
    }

    func queryKanji(_ kanji: String) -> [String: Any]? {
        guard isReadyForLookup, let bundle, activeConfiguration == requestedConfiguration else { return nil }
        let result = bundle.dictQuery.query_kanji(std.string(kanji))
        var entries: [[String: Any]] = []
        for entry in result.entries {
            var stats: [String: String] = [:]
            for key in Self.kanjiStatKeys {
                if let value = entry.stats[std.string(key)] {
                    stats[key] = String(value)
                }
            }
            entries.append([
                "dictName": String(entry.dict_name),
                "onyomi": String(entry.onyomi),
                "kunyomi": String(entry.kunyomi),
                "tags": Self.kanjiTagLabels(String(entry.tags)),
                "stats": Self.kanjiStatItems(stats),
                "meanings": entry.definitions.map { String($0) },
            ])
        }
        guard !entries.isEmpty else { return nil }
        return [
            "character": String(result.character),
            "entries": entries,
        ]
    }

    private static func kanjiTagLabels(_ tags: String) -> [String] {
        tags.split(separator: " ").map { tag in
            switch tag {
            case "jouyou": "常用漢字"
            case "jinmeiyou": "人名用漢字"
            default: String(tag)
            }
        }
    }

    private static let kanjiStatKeys = ["strokes", "grade", "jlpt", "freq"]

    private static func kanjiStatItems(_ stats: [String: String]) -> [[String: String]] {
        let labels: [(key: String, label: String)] = [
            ("strokes", String(localized: "Strokes")),
            ("grade", String(localized: "Grade")),
            ("jlpt", "JLPT"),
            ("freq", String(localized: "Frequency")),
        ]
        return labels.compactMap { key, label in
            guard let value = stats[key], !value.isEmpty else { return nil }
            return ["label": label, "value": value]
        }
    }

    func getStyles() -> [DictionaryStyle] {
        guard isReadyForLookup, let bundle, activeConfiguration == requestedConfiguration else { return [] }
        return Array(bundle.dictQuery.get_styles())
    }
    
    func withMediaFile<T>(dictName: String, mediaPath: String, _ body: (Data) -> T) -> T {
        guard isReadyForLookup, let bundle, activeConfiguration == requestedConfiguration else {
            return body(Data())
        }
        let view = bundle.dictQuery.get_media_file_view(std.string(dictName), std.string(mediaPath))
        let size = Int(view.size)
        guard size > 0, let ptr = UnsafeMutableRawPointer(mutating: view.data) else {
            return body(Data())
        }
        let data = Data(bytesNoCopy: ptr, count: size, deallocator: .none)
        return body(data)
    }
    
    func getMediaFile(dictName: String, mediaPath: String) -> Data {
        return withMediaFile(dictName: dictName, mediaPath: mediaPath) { Data($0) }
    }
}
