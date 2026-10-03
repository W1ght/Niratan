//
//  FushiProgressSync.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A novel's live reading position as a Fushi interconnect host stores it
/// (`GET|PUT /api/library/books/<bookKey>/progress`).
///
/// `sectionIndex` counts Fushi's chapter list, which is the spine filtered to
/// readable HTML documents (see `FushiSectionTable`); `normCharOffset` is the
/// position inside that chapter on a 0...10000 scale. `charOffset` is Fushi's
/// own exact anchor; Niratan cannot measure it and always sends -1.
nonisolated struct FushiRemoteProgress: Codable, Equatable, Sendable {
    var sectionIndex: Int
    var normCharOffset: Int
    var charOffset: Int
    var updatedAtMs: Int

    static let empty = FushiRemoteProgress(sectionIndex: 0, normCharOffset: 0, charOffset: -1, updatedAtMs: 0)

    /// The host has no reading position for the book.
    var isEmpty: Bool { updatedAtMs <= 0 }

    init(sectionIndex: Int, normCharOffset: Int, charOffset: Int, updatedAtMs: Int) {
        self.sectionIndex = sectionIndex
        self.normCharOffset = normCharOffset
        self.charOffset = charOffset
        self.updatedAtMs = updatedAtMs
    }

    // Fushi decodes these fields tolerantly (an int may arrive as a float or null);
    // mirror that so a slightly different host build never aborts the sync.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys, _ fallback: Int) -> Int {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite {
                return Int(value)
            }
            return fallback
        }
        sectionIndex = int(.sectionIndex, 0)
        normCharOffset = int(.normCharOffset, 0)
        charOffset = int(.charOffset, -1)
        updatedAtMs = int(.updatedAtMs, 0)
    }
}

/// Fushi's chapter list expressed in Niratan spine indices.
///
/// Fushi keeps a spine itemref only when it names a manifest item whose media type
/// is HTML and whose file exists, so its `sectionIndex` drifts from Niratan's
/// `Bookmark.chapterIndex` (the EPUBKit spine index) whenever a book has image,
/// SVG or missing spine items.
struct FushiSectionTable: Equatable {
    /// Niratan spine index of each Fushi section, in reading order.
    let spineIndices: [Int]

    var isEmpty: Bool { spineIndices.isEmpty }

    func spineIndex(forSection section: Int) -> Int? {
        spineIndices.indices.contains(section) ? spineIndices[section] : nil
    }

    /// The Fushi section holding `spineIndex`. A spine item Fushi does not count
    /// maps to the start of the next section it does count, or to the end of the
    /// last one.
    func section(forSpineIndex spineIndex: Int) -> (section: Int, exact: Bool)? {
        guard !spineIndices.isEmpty else { return nil }
        if let exact = spineIndices.firstIndex(of: spineIndex) {
            return (exact, true)
        }
        if let next = spineIndices.firstIndex(where: { $0 > spineIndex }) {
            return (next, false)
        }
        return (spineIndices.count - 1, false)
    }
}

/// Converts between Niratan bookmarks and Fushi live positions.
enum FushiProgressMapping {
    static let normScale = 10_000

    /// Niratan's bookmark expressed as a Fushi position. The in-chapter fraction
    /// uses character offsets (both apps count characters the ッツ way), falling
    /// back to the stored chapter progress when the bookmark lies outside the
    /// chapter's character range.
    static func remotePosition(
        for bookmark: Bookmark,
        bookInfo: BookInfo,
        sections: FushiSectionTable
    ) -> (sectionIndex: Int, normCharOffset: Int)? {
        guard let mapped = sections.section(forSpineIndex: bookmark.chapterIndex) else {
            return nil
        }
        guard mapped.exact else {
            let atEnd = sections.spineIndices[mapped.section] < bookmark.chapterIndex
            return (mapped.section, atEnd ? normScale : 0)
        }
        var fraction = bookmark.progress
        if let chapter = chapter(atSpineIndex: bookmark.chapterIndex, in: bookInfo),
           chapter.chapterCount > 0 {
            let within = bookmark.characterCount - chapter.currentTotal
            if within >= 0 && within <= chapter.chapterCount {
                fraction = Double(within) / Double(chapter.chapterCount)
            }
        }
        return (mapped.section, norm(fraction))
    }

    /// The bookmark Niratan stores for a Fushi position, or `nil` when the
    /// section does not exist in this copy of the book.
    static func bookmark(
        for remote: FushiRemoteProgress,
        bookInfo: BookInfo,
        sections: FushiSectionTable
    ) -> Bookmark? {
        guard let spineIndex = sections.spineIndex(forSection: remote.sectionIndex) else {
            return nil
        }
        let fraction = Double(min(max(remote.normCharOffset, 0), normScale)) / Double(normScale)
        let characterCount: Int
        if let chapter = chapter(atSpineIndex: spineIndex, in: bookInfo) {
            let within = Int((fraction * Double(chapter.chapterCount)).rounded())
            characterCount = chapter.currentTotal + min(max(within, 0), chapter.chapterCount)
        } else {
            characterCount = bookInfo.chapterInfo.values
                .filter { ($0.spineIndex ?? Int.max) < spineIndex }
                .map { $0.currentTotal + $0.chapterCount }
                .max() ?? 0
        }
        return Bookmark(
            chapterIndex: spineIndex,
            progress: fraction,
            characterCount: characterCount,
            lastModified: Date(timeIntervalSince1970: TimeInterval(remote.updatedAtMs) / 1000)
        )
    }

    static func chapter(atSpineIndex spineIndex: Int, in bookInfo: BookInfo) -> BookInfo.ChapterInfo? {
        bookInfo.chapterInfo.values.first { $0.spineIndex == spineIndex }
    }

    private static func norm(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(max(fraction, 0), 1) * Double(normScale)).rounded())
    }
}

/// The position both sides last agreed on, used to tell a one-sided change
/// (synced silently) from a real divergence (the user decides).
///
/// The local half is stored in Niratan's own coordinates so rounding in the
/// Fushi mapping can never make an untouched bookmark look moved.
struct FushiProgressBaseline: Codable, Equatable {
    var sectionIndex: Int
    var normCharOffset: Int
    var localChapterIndex: Int
    var localCharacterCount: Int

    init(remote: FushiRemoteProgress, local: Bookmark) {
        sectionIndex = remote.sectionIndex
        normCharOffset = remote.normCharOffset
        localChapterIndex = local.chapterIndex
        localCharacterCount = local.characterCount
    }
}

enum FushiProgressAction: Equatable {
    case synced
    case pushLocal
    case applyRemote
    case conflict
}

enum FushiProgressResolver {
    /// Characters a re-saved bookmark may drift (pagination snapping) and still
    /// count as the same reading position.
    static let localTolerance = 50
    /// The same allowance on Fushi's 0...10000 in-chapter scale.
    static let remoteTolerance = 5

    /// Three-way decision with the same rules as Fushi's
    /// `resolveBookProgressThreeWay`: a missing side always loses, identical
    /// positions are synced, a side that left the baseline alone wins, and both
    /// sides moving (or no baseline yet) is a conflict for the user to settle.
    static func resolve(
        local: Bookmark?,
        remote: FushiRemoteProgress,
        remoteAsLocal: Bookmark?,
        localAsRemote: (sectionIndex: Int, normCharOffset: Int)?,
        base: FushiProgressBaseline?
    ) -> FushiProgressAction {
        guard let local else {
            return remote.isEmpty ? .synced : .applyRemote
        }
        if remote.isEmpty {
            return .pushLocal
        }
        if samePosition(local: local, remote: remote, remoteAsLocal: remoteAsLocal, localAsRemote: localAsRemote) {
            return .synced
        }
        guard let base else {
            return .conflict
        }
        let localMoved = !(local.chapterIndex == base.localChapterIndex
            && abs(local.characterCount - base.localCharacterCount) <= localTolerance)
        let remoteMoved = !(remote.sectionIndex == base.sectionIndex
            && abs(remote.normCharOffset - base.normCharOffset) <= remoteTolerance)
        switch (localMoved, remoteMoved) {
        case (true, true):
            return .conflict
        case (true, false):
            return .pushLocal
        case (false, true):
            return .applyRemote
        case (false, false):
            // Neither side matches its stored half yet the positions differ: a stale
            // baseline. Fall back to the newer side rather than asking forever.
            return localMilliseconds(local) > remote.updatedAtMs ? .pushLocal : .applyRemote
        }
    }

    static func samePosition(
        local: Bookmark,
        remote: FushiRemoteProgress,
        remoteAsLocal: Bookmark?,
        localAsRemote: (sectionIndex: Int, normCharOffset: Int)?
    ) -> Bool {
        if let remoteAsLocal {
            return remoteAsLocal.chapterIndex == local.chapterIndex
                && abs(remoteAsLocal.characterCount - local.characterCount) <= localTolerance
        }
        if let localAsRemote {
            return localAsRemote.sectionIndex == remote.sectionIndex
                && abs(localAsRemote.normCharOffset - remote.normCharOffset) <= remoteTolerance
        }
        return false
    }

    /// The host only accepts a position strictly newer than the one it holds, so a
    /// push moves the decision time past the host's timestamp without changing
    /// the position itself.
    static func pushTimestamp(local: Bookmark, remote: FushiRemoteProgress, now: Date = Date()) -> Int {
        let localMs = local.lastModified.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) }
            ?? Int((now.timeIntervalSince1970 * 1000).rounded())
        return max(localMs, remote.updatedAtMs + 1)
    }

    static func localMilliseconds(_ bookmark: Bookmark) -> Int {
        bookmark.lastModified.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
    }
}
