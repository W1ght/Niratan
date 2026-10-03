//
//  Book.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum SortOption: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case title = "Title"
    case manual = "Manual"
    
    var id: String { self.rawValue }
    var icon: String {
        switch self {
        case .recent: return "clock"
        case .title: return "textformat.size.larger.ja"
        case .manual: return "line.3.horizontal"
        }
    }
}

enum BookReorder {
    private static let payloadPrefix = "hoshi-book:"

    static func payload(for bookID: UUID) -> String {
        payloadPrefix + bookID.uuidString
    }

    static func bookID(from payload: String) -> UUID? {
        guard payload.hasPrefix(payloadPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(payloadPrefix.count)))
    }

    static func destinationOffset(sourceIndex: Int, targetIndex: Int) -> Int? {
        guard sourceIndex != targetIndex else { return nil }
        return targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
    }
}

struct BookMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
    var epub: String?
    var cover: String?
    let folder: String
    var lastAccess: Date
    var renamedTitle: String?
    var profileId: String?
    var bookLanguage: String?
    var externalSourceID: String?
    var externalISBN: String?
    /// Library sync (Google Drive provider): author and character count of a book that may only
    /// exist remotely, and when its title was last changed.
    var author: String?
    var characterCount: Int?
    var modified: Int64?
    var displayTitle: String { renamedTitle ?? title }
    
    init(
        id: UUID = UUID(),
        title: String,
        epub: String? = nil,
        cover: String?,
        folder: String,
        lastAccess: Date,
        profileId: String? = nil,
        bookLanguage: String? = nil,
        externalSourceID: String? = nil,
        externalISBN: String? = nil
    ) {
        self.id = id
        self.title = title
        self.epub = epub
        self.cover = cover
        self.folder = folder
        self.lastAccess = lastAccess
        self.profileId = profileId
        self.bookLanguage = bookLanguage
        self.externalSourceID = externalSourceID
        self.externalISBN = externalISBN
    }
}

struct Bookmark: Codable {
    let chapterIndex: Int
    let progress: Double
    let characterCount: Int
    var lastModified: Date?
}

struct BookInfo: Codable {
    let characterCount: Int
    let chapterInfo: [String: ChapterInfo]
    let images: [String]?
    let imagePositions: [String: Int]?

    init(
        characterCount: Int,
        chapterInfo: [String: ChapterInfo],
        images: [String]? = nil,
        imagePositions: [String: Int]? = nil
    ) {
        self.characterCount = characterCount
        self.chapterInfo = chapterInfo
        self.images = images
        self.imagePositions = imagePositions
    }
    
    struct ChapterInfo: Codable {
        let spineIndex: Int?
        let currentTotal: Int
        let chapterCount: Int
        var fragmentOffsets: [String: Int]?

        init(
            spineIndex: Int?,
            currentTotal: Int,
            chapterCount: Int,
            fragmentOffsets: [String: Int]? = nil
        ) {
            self.spineIndex = spineIndex
            self.currentTotal = currentTotal
            self.chapterCount = chapterCount
            self.fragmentOffsets = fragmentOffsets
        }
    }

    func mergingMissingFragmentOffsets(_ offsetsByChapterPath: [String: [String: Int]]) -> BookInfo {
        var updatedChapterInfo = chapterInfo
        for (path, offsets) in offsetsByChapterPath {
            guard let chapter = updatedChapterInfo[path] else { continue }
            var mergedOffsets = chapter.fragmentOffsets ?? [:]
            for (fragment, offset) in offsets where mergedOffsets[fragment] == nil {
                mergedOffsets[fragment] = offset
            }
            updatedChapterInfo[path] = ChapterInfo(
                spineIndex: chapter.spineIndex,
                currentTotal: chapter.currentTotal,
                chapterCount: chapter.chapterCount,
                fragmentOffsets: mergedOffsets
            )
        }
        return BookInfo(
            characterCount: characterCount,
            chapterInfo: updatedChapterInfo,
            images: images,
            imagePositions: imagePositions
        )
    }

    var fragmentOffsetsRevision: Int {
        var hasher = Hasher()
        for path in chapterInfo.keys.sorted() {
            hasher.combine(path)
            guard let offsets = chapterInfo[path]?.fragmentOffsets else {
                hasher.combine(false)
                continue
            }
            hasher.combine(true)
            for fragment in offsets.keys.sorted() {
                hasher.combine(fragment)
                hasher.combine(offsets[fragment])
            }
        }
        return hasher.finalize()
    }
    
    func resolveCharacterPosition(_ characterCount: Int) -> (spineIndex: Int, progress: Double)? {
        let clamped = max(0, min(characterCount, self.characterCount - 1))
        for chapter in chapterInfo.values {
            guard let spineIndex = chapter.spineIndex, chapter.chapterCount > 0 else {
                continue
            }
            let start = chapter.currentTotal
            let end = start + chapter.chapterCount
            if clamped >= start && clamped < end {
                let progress = Double(clamped - start) / Double(chapter.chapterCount)
                return (spineIndex, progress)
            }
        }
        return nil
    }
}

struct BookShelf: Codable {
    var name: String
    var bookIds: [UUID]
}
