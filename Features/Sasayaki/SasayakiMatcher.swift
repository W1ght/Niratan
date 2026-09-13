//
//  SasayakiMatcher.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

#if canImport(EPUBKit)
import EPUBKit
#endif

/// Aligns transcription text without changing the Reader's character coordinate system.
/// Full-book anchors recover after introductions, omitted passages and recognition errors;
/// short or ambiguous phrases can only match near the last reliable position.
nonisolated enum SasayakiTextMatcher {
    struct ChapterText: Sendable {
        let chapterIndex: Int
        let markup: String
    }

    private struct Chapter {
        let index: Int
        let range: Range<Int>
    }

    private struct Source {
        var characters: [Character] = []
        var readerOffsets: [Int] = []
        var chapters: [Chapter] = []
        var anchors: [String: [Int]] = [:]

        init(chapters: [ChapterText]) {
            for chapter in chapters {
                let start = characters.count
                let readable = ReaderCharacterNormalizer.filteredText(from: chapter.markup)
                for (offset, character) in readable.enumerated() {
                    let folded = SasayakiTextMatcher.fold(String(character))
                    characters.append(contentsOf: folded)
                    readerOffsets.append(contentsOf: repeatElement(offset, count: folded.count))
                }
                let range = start..<characters.count
                self.chapters.append(.init(index: chapter.chapterIndex, range: range))
                if range.count >= 5 {
                    for position in start...(range.upperBound - 5) {
                        anchors[String(characters[position..<(position + 5)]), default: []].append(position)
                    }
                }
            }
        }

        func chapter(at position: Int) -> Chapter? {
            chapters.first { $0.range.contains(position) }
        }

        func exact(_ text: [Character], from start: Int, through end: Int) -> [Range<Int>] {
            guard !text.isEmpty, end - start >= text.count else { return [] }
            let positions: [Int]
            if text.count >= 5 {
                positions = anchors[String(text.prefix(5))] ?? []
            } else {
                positions = Array(start...(end - text.count))
            }
            return positions.compactMap { position in
                let upper = position + text.count
                guard position >= start, upper <= end,
                      characters[position..<upper].elementsEqual(text),
                      let chapter = chapter(at: position), upper <= chapter.range.upperBound else { return nil }
                return position..<upper
            }
        }
    }

    private struct Alignment {
        let range: Range<Int>
        let edits: Int
    }

    static func match(chapters: [ChapterText], cues: [SasayakiCue], searchWindow: Int) -> SasayakiMatchData {
        let source = Source(chapters: chapters)
        var cursor = 0
        var anchored = false
        let pieces = cues.flatMap(splitLongCue)
        let texts = pieces.map { Array(fold(ReaderCharacterNormalizer.filteredText(from: $0.text))) }
        var ranges = [Range<Int>?](repeating: nil, count: pieces.count)

        for (cueIndex, cue) in pieces.enumerated() {
            if Task.isCancelled { break }
            let text = texts[cueIndex]
            guard !text.isEmpty, cue.startTime.isFinite, cue.endTime.isFinite,
                  cue.startTime >= 0, cue.endTime > cue.startTime,
                  !(cue.text.hasPrefix("＊") && text.count < 5) else {
                continue
            }

            let window = text.count < 6 ? min(30, max(0, searchWindow)) : max(0, searchWindow)
            let localEnd = min(source.characters.count, cursor + text.count + window)
            var range: Range<Int>?
            if anchored || text.count >= 6 {
                range = source.exact(text, from: cursor, through: localEnd).first
            }

            if range == nil, text.count >= 10, anchored {
                range = approximate(text, source: source, from: cursor, through: localEnd, global: false)?.range
            }

            // A repeated short line is not a trustworthy way to jump across a book.
            if range == nil, text.count >= 12 {
                let exact = source.exact(text, from: cursor, through: source.characters.count)
                if exact.count == 1 {
                    if confirmsJump(exact[0], after: cueIndex, cues: pieces, source: source) { range = exact[0] }
                } else if exact.isEmpty, text.count >= 16 {
                    if let candidate = approximate(text, source: source, from: cursor, through: source.characters.count, global: true)?.range,
                       confirmsJump(candidate, after: cueIndex, cues: pieces, source: source) {
                        range = candidate
                    }
                }
            }

            guard let range else { continue }
            cursor = range.upperBound
            anchored = true
            ranges[cueIndex] = range
        }
        let inferred = fillGaps(ranges: &ranges, texts: texts, cues: pieces, source: source)
        let matches: [SasayakiMatch] = pieces.enumerated().compactMap { index, cue in
            guard let range = ranges[index], let chapter = source.chapter(at: range.lowerBound) else { return nil }
            let start = source.readerOffsets[range.lowerBound]
            let end = source.readerOffsets[range.upperBound - 1] + 1
            return .init(
                id: cue.id, startTime: cue.startTime, endTime: cue.endTime, text: cue.text,
                chapterIndex: chapter.index, start: start, length: end - start,
                contextInferred: inferred.contains(index) ? true : nil
            )
        }
        return .init(matches: matches, unmatched: pieces.count - matches.count)
    }

    private static func fold(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(String.UnicodeScalarView(folded.unicodeScalars.map { scalar in
            (0x30A1...0x30F6).contains(scalar.value) ? UnicodeScalar(scalar.value - 0x60)! : scalar
        }))
    }

    /// Second pass, following Fushi's anchor-gap approach: long located phrases bound
    /// a small region, so kana/kanji substitutions no longer require a full-book guess.
    /// Exact long anchors stay fixed. Short interjections may move only if the region
    /// gains matches. Proportional fills are recorded separately from text evidence.
    private static func fillGaps(
        ranges: inout [Range<Int>?], texts: [[Character]], cues: [SasayakiCue], source: Source
    ) -> Set<Int> {
        let anchors = ranges.indices.filter { ranges[$0] != nil && texts[$0].count > 2 }
        var inferred = Set<Int>()
        var remainingWork = 30_000_000
        for (left, right) in zip(anchors, anchors.dropFirst()) {
            if Task.isCancelled { break }
            guard right > left + 1,
                  (left + 1..<right).contains(where: { ranges[$0] == nil }),
                  let before = ranges[left], let after = ranges[right],
                  let chapter = source.chapter(at: before.lowerBound),
                  chapter.range.contains(after.lowerBound), before.upperBound < after.lowerBound else { continue }
            let region = before.upperBound..<after.lowerBound
            let indices = Array(left + 1..<right)
            let count = indices.reduce(0) { $0 + texts[$1].count }
            guard region.count <= 2_000, indices.count <= 40, count > 0,
                  cues[right].startTime >= cues[left].endTime,
                  cues[right].startTime - cues[left].endTime <= 180,
                  (left + 1...right).allSatisfy({ cues[$0].startTime >= cues[$0 - 1].startTime }),
                  indices.allSatisfy({ validForGap(cues[$0], text: texts[$0]) }) else { continue }
            let work = region.count * count
            guard work <= remainingWork else { continue }
            remainingWork -= work
            let original = indices.map { ranges[$0] }
            var proposed: [Int: Range<Int>] = [:]
            // Resolve longer phrases first; each following phrase can use only the
            // space left by already placed neighbors in subtitle order.
            for index in indices.sorted(by: { texts[$0].count == texts[$1].count ? $0 < $1 : texts[$0].count > texts[$1].count }) {
                let lower = proposed.keys.filter { $0 < index }.max().flatMap { proposed[$0]?.upperBound } ?? region.lowerBound
                let upper = proposed.keys.filter { $0 > index }.min().flatMap { proposed[$0]?.lowerBound } ?? region.upperBound
                guard lower < upper, !texts[index].isEmpty else { continue }
                let text = texts[index]
                let edits = text.count >= 3 ? Int(Double(text.count) * 0.55) : 0
                if let aligned = align(text, against: source.characters, in: lower..<upper, maximumEdits: edits) {
                    proposed[index] = aligned.range
                }
            }
            // Pure spelling substitutions can share no characters (e.g. たぶん/多分).
            // Only a short, fully bounded, continuous narration gap may be inferred.
            var regionInferred = Set<Int>()
            var index = left + 1
            while index < right {
                if proposed[index] != nil { index += 1; continue }
                let start = index
                while index < right && proposed[index] == nil { index += 1 }
                let lower = start == left + 1 ? region.lowerBound : proposed[start - 1]!.upperBound
                let upper = index == right ? region.upperBound : proposed[index]!.lowerBound
                let span = lower..<max(lower, upper)
                let cueIndices = Array(start..<index)
                let total = cueIndices.reduce(0) { $0 + texts[$1].count }
                guard span.count >= cueIndices.count, span.count <= 160, cueIndices.count <= 8, total > 0,
                      Double(span.count) / Double(total) >= 0.3,
                      Double(span.count) / Double(total) <= 2.5,
                      compatibleScripts(texts: cueIndices.flatMap { texts[$0] }, source: Array(source.characters[span])),
                      (start...index).allSatisfy({ cues[$0].startTime - cues[$0 - 1].endTime <= 10 }) else { continue }
                var position = lower
                var weight = 0
                for (offset, cueIndex) in cueIndices.enumerated() {
                    weight += texts[cueIndex].count
                    let estimated = lower + Int((Double(span.count) * Double(weight) / Double(total)).rounded())
                    let end = min(upper - (cueIndices.count - offset - 1), max(position + 1, estimated))
                    proposed[cueIndex] = position..<end
                    regionInferred.insert(cueIndex)
                    position = end
                }
            }
            let previousCount = original.compactMap { $0 }.count
            guard proposed.count > previousCount else { continue }
            for index in indices { ranges[index] = proposed[index] }
            inferred.formUnion(regionInferred)
        }
        return inferred
    }

    private static func validForGap(_ cue: SasayakiCue, text: [Character]) -> Bool {
        !text.isEmpty && cue.startTime.isFinite && cue.endTime.isFinite
            && cue.startTime >= 0 && cue.endTime > cue.startTime && !cue.text.hasPrefix("＊")
    }

    private static func compatibleScripts(texts: [Character], source: [Character]) -> Bool {
        func japanese(_ text: [Character]) -> Bool {
            text.contains { character in character.unicodeScalars.contains { $0.value >= 0x3000 && $0.value <= 0x9FFF } }
        }
        // Do not infer an unrelated Latin-language announcement into Japanese prose.
        return japanese(texts) == japanese(source)
    }

    private static func confirmsJump(_ range: Range<Int>, after index: Int, cues: [SasayakiCue], source: Source) -> Bool {
        guard index + 1 < cues.count else { return true }
        var confirmedCharacters = 0
        var cursor = range.upperBound
        let end = min(source.characters.count, cursor + 600)
        // Publisher/performer credits at the start of an audiobook can occur only in
        // the book's final colophon. Require subsequent narration in the same region
        // before allowing a global jump, otherwise a single credit strands the cursor.
        for cue in cues[(index + 1)..<min(cues.count, index + 9)] {
            let text = Array(fold(ReaderCharacterNormalizer.filteredText(from: cue.text)))
            guard text.count >= 6 else { continue }
            let candidate = source.exact(text, from: cursor, through: end).first
                ?? (text.count >= 12 ? approximate(text, source: source, from: cursor, through: end, global: false)?.range : nil)
            if let candidate {
                confirmedCharacters += text.count
                cursor = candidate.upperBound
                if confirmedCharacters >= 16 { return true }
            }
        }
        return false
    }

    private static func approximate(
        _ text: [Character], source: Source, from start: Int, through end: Int, global: Bool
    ) -> Alignment? {
        let maximumEdits = Int(Double(text.count) * (global ? 0.14 : 0.2))
        guard maximumEdits > 0 else { return nil }
        var windows: [Range<Int>] = []
        if global {
            // Vote for an approximate starting position using distinct five-character seeds.
            // Bounding the candidates keeps failed recognition linear in book size at indexing time.
            var votes: [Int: Set<Int>] = [:]
            let stride = max(1, (text.count - 5) / 20)
            for offset in Swift.stride(from: 0, through: text.count - 5, by: stride) {
                let seed = String(text[offset..<(offset + 5)])
                let positions = source.anchors[seed] ?? []
                guard positions.count <= 200 else { continue }
                for position in positions where position >= start && position < end {
                    let proposed = position - offset
                    guard proposed + maximumEdits >= start else { continue }
                    votes[max(0, proposed) / 8, default: []].insert(offset)
                }
            }
            let candidates = votes.filter { $0.value.count >= 2 }.sorted {
                $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
            }.prefix(12)
            for candidate in candidates {
                let estimate = candidate.key * 8
                let lower = max(start, estimate - maximumEdits - 8)
                let upper = min(end, estimate + text.count + maximumEdits + 16)
                if lower < upper { windows.append(lower..<upper) }
            }
        } else if start < end {
            windows = [start..<end]
        }

        var results: [Range<Int>: Alignment] = [:]
        for window in windows {
            for chapter in source.chapters where chapter.range.overlaps(window) {
                let range = max(window.lowerBound, chapter.range.lowerBound)..<min(window.upperBound, chapter.range.upperBound)
                guard range.count >= text.count - maximumEdits else { continue }
                if let result = align(text, against: source.characters, in: range, maximumEdits: maximumEdits) {
                    results[result.range] = result
                }
            }
        }
        let ranked = results.values.sorted {
            $0.edits == $1.edits ? $0.range.lowerBound < $1.range.lowerBound : $0.edits < $1.edits
        }
        guard let best = ranked.first else { return nil }
        // Competing distant passages need a clear winner; nearby candidates often describe
        // the same passage with one extra/deleted boundary character.
        if global, ranked.dropFirst().contains(where: {
            !$0.range.overlaps(best.range) && $0.edits <= best.edits + 1
        }) { return nil }
        return best
    }

    /// Semi-global Levenshtein alignment: all cue characters must be accounted for,
    /// while source characters before/after the passage are free. Reader offsets come
    /// from the selected source span, never from the recognition string's length.
    private static func align(
        _ text: [Character], against source: [Character], in range: Range<Int>, maximumEdits: Int
    ) -> Alignment? {
        let width = range.count
        var previous = Array(repeating: 0, count: width + 1)
        var previousStarts = Array(0...width)
        for row in 1...text.count {
            if Task.isCancelled { return nil }
            var current = Array(repeating: row, count: width + 1)
            var starts = Array(repeating: 0, count: width + 1)
            for column in 1...width {
                let substitution = previous[column - 1] + (text[row - 1] == source[range.lowerBound + column - 1] ? 0 : 1)
                let deletion = previous[column] + 1
                let insertion = current[column - 1] + 1
                if substitution <= deletion && substitution <= insertion {
                    current[column] = substitution
                    starts[column] = previousStarts[column - 1]
                } else if deletion <= insertion {
                    current[column] = deletion
                    starts[column] = previousStarts[column]
                } else {
                    current[column] = insertion
                    starts[column] = starts[column - 1]
                }
            }
            previous = current
            previousStarts = starts
        }
        guard let end = (1...width).min(by: { previous[$0] < previous[$1] }),
              previous[end] <= maximumEdits, previousStarts[end] < end else { return nil }
        return .init(range: (range.lowerBound + previousStarts[end])..<(range.lowerBound + end), edits: previous[end])
    }

    /// Older exports may contain minutes of speech in a single cue. Keep already
    /// timed short cues intact; only legacy long cues use proportional timing between
    /// sentence boundaries because those files contain no word timestamps.
    private static func splitLongCue(_ cue: SasayakiCue) -> [SasayakiCue] {
        guard ReaderCharacterNormalizer.readableCharacterCount(in: cue.text) > 120 else { return [cue] }
        let characters = Array(cue.text)
        var ranges: [Range<Int>] = []
        var start = 0
        var readable = 0
        for index in characters.indices {
            let character = characters[index]
            if !ReaderCharacterNormalizer.filteredText(from: String(character)).isEmpty { readable += 1 }
            let sentenceEnd = "。！？!?\n".contains(character)
                || (character == "." && (index + 1 == characters.count || characters[index + 1].isWhitespace))
            if (sentenceEnd && readable >= 20) || readable >= 100 {
                ranges.append(start..<(index + 1))
                start = index + 1
                readable = 0
            }
        }
        if start < characters.count {
            if readable < 8, let previous = ranges.popLast() {
                ranges.append(previous.lowerBound..<characters.count)
            } else {
                ranges.append(start..<characters.count)
            }
        }
        let duration = cue.endTime - cue.startTime
        return ranges.enumerated().map { index, range in
            .init(
                id: "\(cue.id)-part-\(index)",
                startTime: cue.startTime + duration * Double(range.lowerBound) / Double(characters.count),
                endTime: cue.startTime + duration * Double(range.upperBound) / Double(characters.count),
                text: String(characters[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

#if canImport(EPUBKit)
struct SasayakiMatcher {
    private enum MatchError: Error {
        case missingEpub
    }
    
    static func match(rootURL: URL, cues: [SasayakiCue], searchWindow: Int) async throws -> SasayakiMatchData {
        guard let epub = BookStorage.loadMetadata(root: rootURL)?.epub else {
            throw MatchError.missingEpub
        }
        
        let document = try BookStorage.loadEpub(rootURL.appendingPathComponent(epub))
        let guideTocPaths: Set<String> = Set(
            (document.guide?.references ?? [])
                .filter { $0.type.lowercased() == "toc" }
                .map { $0.href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? $0.href }
        )
        var chapters: [SasayakiTextMatcher.ChapterText] = []
        for (spineIndex, item) in document.spine.items.enumerated() {
            guard item.linear, let manifestItem = document.manifest.items[item.idref] else {
                continue
            }
            if manifestItem.property?.contains("nav") == true {
                continue
            }
            if guideTocPaths.contains(manifestItem.path) {
                continue
            }

            let url = document.contentDirectory.appendingPathComponent(manifestItem.path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            
            chapters.append(.init(chapterIndex: spineIndex, markup: content))
        }
        let task = Task.detached(priority: .userInitiated) {
            SasayakiTextMatcher.match(chapters: chapters, cues: cues, searchWindow: searchWindow)
        }
        return try await withTaskCancellationHandler {
            let result = await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }
}
#endif
