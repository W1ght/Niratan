//
//  EPUBSyncCoordinates.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import EPUBKit
import Foundation
import SwiftSoup
import ZIPFoundation

/// Google Drive format 1 uses the Hoshi Swift character basis. Keep that wire
/// contract separate from the existing local BookInfo and Reader normalizer.
nonisolated enum HoshiSyncCharacterNormalizer {
    static let revision = "hoshi-swift-fb707c7a-format1"
    private static let excluded = #"[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ가-힣ㄱ-ㆎ\p{Radical}\p{Unified_Ideograph}]"#

    static func filteredText(from markup: String) -> String {
        var text = markup
        if let body = text.range(of: "(?s)<body.*?</body>", options: .regularExpression) {
            text = String(text[body])
        }
        text = text.replacingOccurrences(of: "(?s)<(rt|rp)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&#[xX]?[0-9A-Fa-f]+;", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return text.replacingOccurrences(of: excluded, with: "", options: .regularExpression)
    }

    /// DOM text is already decoded; applying the markup normalizer again would
    /// interpret literal text such as "&quot;" a second time.
    static func domCount(_ text: String, canonical: Bool) -> Int {
        let pattern = canonical ? excluded : excluded.replacingOccurrences(of: "가-힣ㄱ-ㆎ", with: "")
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression).unicodeScalars.count
    }
}

/// A map is valid only for one exact EPUB, its ordered spine, and the published
/// sync reference. Zero-native chapters retain their actual spine and progress.
/// Historical session totals are deliberately outside this adapter.
nonisolated struct EPUBSyncCoordinates: Sendable {
    private struct Chapter: Sendable {
        let index: Int
        let path: String
        let nativeStart: Int
        let nativeCount: Int
        let canonicalStart: Int
        let canonicalCount: Int
        let domText: [UnicodeScalar]
    }

    let identity: String
    let canonicalTotal: Int
    let nativeTotal: Int
    private let chapters: [Chapter]

    /// Display-only chapter counts for shared progress/TOC. Navigation and local
    /// sidecars keep their original native BookInfo; native fragment offsets
    /// cannot be copied into this different character basis.
    @MainActor var canonicalBookInfo: BookInfo {
        BookInfo(characterCount: canonicalTotal, chapterInfo: Dictionary(uniqueKeysWithValues: chapters.map {
            ($0.path, BookInfo.ChapterInfo(spineIndex: $0.index, currentTotal: $0.canonicalStart,
                                          chapterCount: $0.canonicalCount))
        }))
    }

    private struct Fingerprint: Equatable {
        let size: UInt64
        let modified: Date
        let fileID: UInt64
    }
    private struct Cached {
        let fingerprint: Fingerprint
        let nativeSignature: String
        let generation: Int
        let reference: String?
        let map: EPUBSyncCoordinates
    }
    @MainActor private static var cache: [String: Cached] = [:]

    @MainActor
    static func map(root: URL, generation: Int, epubReference: String?) throws -> Self? {
        guard let metadata = BookStorage.loadMetadata(root: root), let epub = metadata.epub,
              let info = BookStorage.loadBookInfo(root: root) else { return nil }
        return try load(epubURL: root.appendingPathComponent(epub), nativeInfo: info,
                        generation: generation, epubReference: epubReference)
    }

    /// Reader callbacks use a previously validated map; they never unpack an
    /// archive or alter the Reader's shared temporary directory.
    @MainActor
    static func cached(root: URL) -> Self? {
        guard let epub = BookStorage.loadMetadata(root: root)?.epub else { return nil }
        return cached(epubURL: root.appendingPathComponent(epub))
    }

    @MainActor
    static func cached(epubURL: URL) -> Self? {
        let key = epubURL.standardizedFileURL.path
        guard let entry = cache[key], fingerprint(epubURL) == entry.fingerprint else {
            cache[key] = nil
            return nil
        }
        return entry.map
    }

    /// The caller supplies the published generation/reference, not a display
    /// filename guessed from a remote placeholder. Existing native chapter
    /// counts must match a fresh pass over the exact archive before projection.
    @MainActor
    static func load(
        epubURL: URL, nativeInfo: BookInfo, generation: Int = 1, epubReference: String? = nil
    ) throws -> Self? {
        let key = epubURL.standardizedFileURL.path
        guard generation > 0, let before = fingerprint(epubURL) else {
            cache[key] = nil
            return nil
        }
        let signature = nativeInfo.chapterInfo.keys.sorted().map { path in
            let chapter = nativeInfo.chapterInfo[path]!
            return "\(path.utf8.count):\(path):\(chapter.spineIndex ?? -1):\(chapter.currentTotal):\(chapter.chapterCount)"
        }.joined(separator: "\n") + "\n\(nativeInfo.characterCount)"
        if let entry = cache[key], entry.fingerprint == before,
           entry.nativeSignature == signature, entry.generation == generation, entry.reference == epubReference {
            return entry.map
        }
        cache[key] = nil
        let hash = try streamingSHA256(epubURL)
        let extraction = FileManager.default.temporaryDirectory
            .appendingPathComponent("niratan-sync-coordinates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: extraction) }
        try FileManager.default.unzipItem(at: epubURL, to: extraction)
        let document = try EPUBParser().parse(documentAt: extraction)
        var rows: [Chapter] = []
        var nativeTotal = 0
        var canonicalTotal = 0
        for (index, item) in document.spine.items.enumerated() {
            guard let manifest = document.manifest.items[item.idref] else { return nil }
            let url = document.contentDirectory.appendingPathComponent(manifest.path).standardizedFileURL
            guard url.path.hasPrefix(extraction.standardizedFileURL.path + "/"),
                  let markup = try? String(contentsOf: url, encoding: .utf8),
                  let stored = nativeInfo.chapterInfo[manifest.path], stored.spineIndex == index else { return nil }
            let nativeCount = ReaderCharacterNormalizer.filteredText(from: markup).count
            let canonicalCount = HoshiSyncCharacterNormalizer.filteredText(from: markup).count
            guard stored.currentTotal == nativeTotal, stored.chapterCount == nativeCount else { return nil }
            let nextNative = nativeTotal.addingReportingOverflow(nativeCount)
            let nextCanonical = canonicalTotal.addingReportingOverflow(canonicalCount)
            guard !nextNative.overflow, !nextCanonical.overflow else { return nil }
            rows.append(Chapter(index: index, path: manifest.path, nativeStart: nativeTotal,
                                nativeCount: nativeCount, canonicalStart: canonicalTotal,
                                canonicalCount: canonicalCount, domText: domText(markup)))
            nativeTotal = nextNative.partialValue
            canonicalTotal = nextCanonical.partialValue
        }
        guard !rows.isEmpty, rows.count == nativeInfo.chapterInfo.count,
              nativeTotal == nativeInfo.characterCount, fingerprint(epubURL) == before,
              try streamingSHA256(epubURL) == hash else { return nil }
        let components = [hash, String(generation), epubReference ?? "", HoshiSyncCharacterNormalizer.revision,
                          "niratan-decoded-numeric-rp-v1"] + rows.map { "\($0.index):\($0.path.utf8.count):\($0.path)" }
        let identity = SHA256.hash(data: Data(components.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
        let map = Self(identity: identity, canonicalTotal: canonicalTotal, nativeTotal: nativeTotal, chapters: rows)
        // Bound the retained chapter text; an evicted book can be loaded again by SyncStorage.
        if cache.count >= 8 { cache.removeAll(keepingCapacity: true) }
        cache[key] = Cached(fingerprint: before, nativeSignature: signature,
                            generation: generation, reference: epubReference, map: map)
        return map
    }

    func canonicalChapterCount(spineIndex: Int) -> Int? {
        chapters.first { $0.index == spineIndex }?.canonicalCount
    }

    func canonicalCharacter(spineIndex: Int, progress: Double) -> Int? {
        guard progress.isFinite, (0...1).contains(progress),
              let chapter = chapters.first(where: { $0.index == spineIndex }) else { return nil }
        return chapter.canonicalStart + scaledProgress(progress, count: chapter.canonicalCount)
    }

    func nativeCharacter(spineIndex: Int, progress: Double) -> Int? {
        guard progress.isFinite, (0...1).contains(progress),
              let chapter = chapters.first(where: { $0.index == spineIndex }) else { return nil }
        return chapter.nativeStart + scaledProgress(progress, count: chapter.nativeCount)
    }

    func nativeBookmark(forCanonical character: Int, modified: Int64) -> Bookmark? {
        guard character >= 0, character <= canonicalTotal else { return nil }
        // An all-zero book has only the beginning/end sentinel. No chapter can
        // be inferred from another non-existent canonical character.
        if canonicalTotal == 0 {
            guard character == 0, let chapter = chapters.first else { return nil }
            return Bookmark(chapterIndex: chapter.index, progress: 0, characterCount: chapter.nativeStart,
                            lastModified: Date(syncMilliseconds: modified))
        }
        if character == canonicalTotal {
            guard let chapter = chapters.last(where: { $0.canonicalCount > 0 || $0.nativeCount > 0 }) else { return nil }
            return Bookmark(chapterIndex: chapter.index, progress: 1, characterCount: nativeTotal,
                            lastModified: Date(syncMilliseconds: modified))
        }
        guard let chapter = chapters.first(where: {
            $0.canonicalCount > 0 && character >= $0.canonicalStart && character < $0.canonicalStart + $0.canonicalCount
        }) else { return nil }
        let local = character - chapter.canonicalStart
        let progress = Double(local) / Double(chapter.canonicalCount)
        return Bookmark(chapterIndex: chapter.index, progress: progress,
                        characterCount: chapter.nativeStart + ratio(local, chapter.nativeCount, chapter.canonicalCount),
                        lastModified: Date(syncMilliseconds: modified))
    }

    func canonicalCharacter(forNativeBookmark bookmark: Bookmark) -> Int? {
        canonicalCharacter(spineIndex: bookmark.chapterIndex, progress: bookmark.progress)
    }

    func nativeCharacter(forCanonical character: Int) -> Int? {
        nativeBookmark(forCanonical: character, modified: 0)?.characterCount
    }

    /// Raw-only native positions cannot distinguish multiple zero-count chapters.
    /// Bookmark callers must use its chapterIndex/progress instead.
    func canonicalCharacter(forNative character: Int) -> Int? {
        guard character >= 0, character <= nativeTotal else { return nil }
        if character == nativeTotal { return canonicalTotal }
        guard let chapter = chapters.first(where: {
            $0.nativeCount > 0 && character >= $0.nativeStart && character < $0.nativeStart + $0.nativeCount
        }) else { return nil }
        return chapter.canonicalStart + ratio(character - chapter.nativeStart, chapter.canonicalCount, chapter.nativeCount)
    }

    func projectCanonicalHighlight(_ value: SyncHighlight) -> SyncHighlight? {
        guard let character = highlightCharacter(value, fromCanonical: true) else { return nil }
        var projected = value
        projected.character = character
        return projected
    }

    func exportNativeHighlight(_ value: Highlight) -> SyncHighlight? {
        let wire = SyncHighlight(value)
        guard let character = highlightCharacter(wire, fromCanonical: false) else { return nil }
        var projected = wire
        projected.character = character
        return projected
    }

    /// BookInfo's native range can be empty (Hangul) or shorter than the DOM
    /// prefix (numeric references). Reader filtering uses this verified anchor
    /// instead of assigning such a highlight to an adjacent chapter.
    func nativeHighlightSpineIndex(_ value: Highlight) -> Int? {
        let candidates = highlightCandidates(SyncHighlight(value), fromCanonical: false)
        return candidates.count == 1 ? candidates[0].spineIndex : nil
    }

    /// A highlight has an exact DOM anchor, unlike a wire bookmark's integer.
    /// Its navigation fraction must use the DOM's full filtered character count,
    /// not the Swift markup count (which can omit numeric entities or retain
    /// quote entity letters). The returned bookmark is a navigation request.
    func nativeHighlightBookmark(_ value: Highlight) -> Bookmark? {
        guard let index = nativeHighlightSpineIndex(value),
              let chapter = chapters.first(where: { $0.index == index }) else { return nil }
        let prefix = String(String.UnicodeScalarView(chapter.domText.prefix(value.offset)))
        let fullText = String(String.UnicodeScalarView(chapter.domText))
        let canonical = chapter.canonicalCount > 0
        let total = HoshiSyncCharacterNormalizer.domCount(fullText, canonical: canonical)
        guard total > 0 else { return nil }
        let local = HoshiSyncCharacterNormalizer.domCount(prefix, canonical: canonical)
        let progress = min(1, max(0, Double(local) / Double(total)))
        return Bookmark(chapterIndex: chapter.index, progress: progress,
                        characterCount: chapter.nativeStart + scaledProgress(progress, count: chapter.nativeCount))
    }

    private func highlightCharacter(_ value: SyncHighlight, fromCanonical: Bool) -> Int? {
        let candidates = highlightCandidates(value, fromCanonical: fromCanonical)
        // Identical text at an offset in multiple chapters is not a safe anchor,
        // even when both would happen to produce the same integer.
        return candidates.count == 1 ? candidates[0].character : nil
    }

    private func highlightCandidates(_ value: SyncHighlight, fromCanonical: Bool) -> [(spineIndex: Int, character: Int)] {
        guard value.offset >= 0, !value.text.isEmpty else { return [] }
        let selected = Array(value.text.unicodeScalars)
        var candidates: [(spineIndex: Int, character: Int)] = []
        for chapter in chapters {
            guard value.offset <= chapter.domText.count, selected.count <= chapter.domText.count - value.offset,
                  Array(chapter.domText[value.offset..<(value.offset + selected.count)]) == selected else { continue }
            let prefix = String(String.UnicodeScalarView(chapter.domText.prefix(value.offset)))
            let sourceStart = fromCanonical ? chapter.canonicalStart : chapter.nativeStart
            let expected = sourceStart + HoshiSyncCharacterNormalizer.domCount(prefix, canonical: fromCanonical)
            guard expected == value.character else { continue }
            let targetStart = fromCanonical ? chapter.nativeStart : chapter.canonicalStart
            candidates.append((chapter.index, targetStart + HoshiSyncCharacterNormalizer.domCount(prefix, canonical: !fromCanonical)))
        }
        return candidates
    }

    private func scaledProgress(_ progress: Double, count: Int) -> Int {
        if progress == 1 { return count }
        if count == 0 { return 0 }
        // A serialized exact ratio such as 1/49 can multiply back to one ULP
        // below the integer. Correct only that floating boundary; do not first
        // quantize through the other coordinate space and lose native geometry.
        let value = floor((progress * Double(count)).nextUp)
        return value >= Double(count) ? count - 1 : max(0, Int(value))
    }

    private func ratio(_ value: Int, _ target: Int, _ source: Int) -> Int {
        guard value > 0, target > 0, source > 0 else { return 0 }
        return Int(UInt(source).dividingFullWidth(UInt(value).multipliedFullWidth(by: UInt(target))).quotient)
    }

    private static func domText(_ markup: String) -> [UnicodeScalar] {
        guard let body = try? SwiftSoup.parse(markup).body() else { return [] }
        var text = ""
        func walk(_ node: Node) {
            if let element = node as? Element, ["rt", "rp"].contains(element.tagName().lowercased()) { return }
            if let node = node as? TextNode { text += node.getWholeText() }
            // SwiftSoup represents script/style text as DataNode; WebKit exposes
            // these as text nodes. Keep the same raw offset stream as its walker.
            if let node = node as? DataNode { text += node.getWholeData() }
            for child in node.getChildNodes() { walk(child) }
        }
        walk(body)
        return Array(text.unicodeScalars)
    }

    private static func fingerprint(_ url: URL) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date,
              let fileID = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Fingerprint(size: size.uint64Value, modified: modified, fileID: fileID.uint64Value)
    }

    private static func streamingSHA256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
