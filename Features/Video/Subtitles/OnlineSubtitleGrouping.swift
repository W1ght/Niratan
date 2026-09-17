import Foundation

/// A downloadable choice; provider-specific entry traversal stays behind this boundary.
nonisolated struct OnlineSubtitleCandidate: Identifiable, Sendable {
    let file: OnlineSubtitleFile
    let collectionID: String
    let collectionName: String
    var id: String { file.id }
    var name: String { file.name }
    var provider: OnlineSubtitleProvider {
        switch file {
        case .ajatt: .ajatt
        case .jimaku: .jimaku
        case .openSubtitles: .openSubtitles
        }
    }
    var language: String {
        if case .openSubtitles(let file) = file { return file.language }
        let tokens = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if tokens.contains(where: { ["chs", "sc", "zh", "zho", "chi"].contains($0) }) || name.contains("简体") { return "zh-cn" }
        if tokens.contains(where: { ["cht", "tc"].contains($0) }) || name.contains("繁體") { return "zh-tw" }
        if tokens.contains(where: { ["en", "eng"].contains($0) }) { return "en" }
        if tokens.contains(where: { ["ko", "kor"].contains($0) }) { return "ko" }
        return "ja" // Jimaku and AJATT are Japanese subtitle catalogs.
    }
    var format: String { URL(fileURLWithPath: name).pathExtension.lowercased() }
    var version: String {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*[\[【]([^\]】]{2,30})[\]】]"#),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return "" }
        let tag = String(name[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = tag.lowercased()
        if ["ja", "jp", "jpn", "en", "eng", "zh", "chs", "cht", "sc", "tc", "ko", "kor"].contains(lower)
            || lower.range(of: #"^(?:[0-9a-f]{8}|\d{3,4}p)$"#, options: .regularExpression) != nil { return "" }
        return tag
    }
    var episode: Int? { JimakuMediaTitleParser.suggestion(from: name).episode }
}

nonisolated struct OnlineSubtitleGroup: Identifiable, Sendable {
    let id: String
    let candidates: [OnlineSubtitleCandidate]
    var representative: OnlineSubtitleCandidate { candidates[0] }

    static func build(_ candidates: [OnlineSubtitleCandidate], language: String = "", version: String = "", filter: String = "") -> [Self] {
        var seen = Set<String>()
        let filtered = candidates.filter { candidate in
            seen.insert(candidate.id).inserted
                && (language.isEmpty || candidate.language == language)
                && (version.isEmpty || candidate.version == version)
                && (filter.isEmpty || candidate.name.localizedStandardContains(filter)
                    || candidate.collectionName.localizedStandardContains(filter))
        }
        let groups = Dictionary(grouping: filtered) { candidate in
            [candidate.provider.rawValue, candidate.collectionID, candidate.language, candidate.format, candidate.version].joined(separator: "\u{1F}")
        }
        return groups.map { key, values in
            Self(id: key, candidates: values.sorted {
                if $0.episode != $1.episode { return ($0.episode ?? Int.max) < ($1.episode ?? Int.max) }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
        }.sorted {
            let lhs = $0.representative, rhs = $1.representative
            if (lhs.language == "ja") != (rhs.language == "ja") { return lhs.language == "ja" }
            if lhs.collectionName != rhs.collectionName { return lhs.collectionName.localizedStandardCompare(rhs.collectionName) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}
