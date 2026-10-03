//
//  Sync.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

// Library sync model shared with upstream Hoshi Reader (formatVersion 1). Niratan adds only
// optional fields, so documents written by either side decode on the other.

nonisolated enum SyncFormatError: LocalizedError {
    case unsupportedVersion

    var errorDescription: String? {
        String(localized: "Unsupported sync format.")
    }
}

nonisolated enum SyncFormat {
    static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(Document<T>.self, from: data).value
    }

    static func encode<T: Codable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(Document(value: value))
    }

    private struct Document<Value: Codable>: Codable {
        var value: Value

        enum CodingKeys: String, CodingKey {
            case formatVersion
        }

        init(value: Value) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decodeIfPresent(Int.self, forKey: .formatVersion) == 1 else {
                throw SyncFormatError.unsupportedVersion
            }
            value = try Value(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(1, forKey: .formatVersion)
            try value.encode(to: encoder)
        }
    }
}

nonisolated extension Date {
    var syncMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(syncMilliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(syncMilliseconds) / 1000)
    }
}

// Timestamped and ReadingSession are shared with the session-based statistics model
// (Models/Statistics.swift); library sync only adds its merge helpers.
nonisolated extension Timestamped {
    func replacing<T>(_ value: T) -> Timestamped<T> {
        Timestamped<T>(modified: modified, value: value)
    }

    static func newest(_ first: Self, _ second: Self) -> Self {
        first.modified >= second.modified ? first : second
    }

    static func newest(_ first: Self?, _ second: Self?) -> Self? {
        switch (first, second) {
        case let (first?, second?):
            newest(first, second)
        case let (first?, nil):
            first
        case let (nil, second?):
            second
        case (nil, nil):
            nil
        }
    }

    static func merge<Key>(_ first: [Key: Self], _ second: [Key: Self]) -> [Key: Self] {
        first.merging(second) { newest($0, $1) }
    }
}

enum SyncProvider: String, CaseIterable, Codable {
    /// Whole-library sync between Niratan devices.
    case gdrive
    /// Per-book ッツ/yatsu compatible sync (the original Niratan sync).
    case ttu
}

nonisolated struct SyncMetadata: Codable, Equatable, Sendable {
    var title: String
    var author: String?
    /// Niratan extension: the book's content language, so a remote-only book opens in the right Profile.
    var language: String?
}

nonisolated enum SyncFileType: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case epub
    case cover
    case sasayaki
}

typealias SyncFiles = [SyncFileType: Timestamped<String?>]

nonisolated struct SyncBookmark: Codable, Equatable, Sendable {
    var characterCount: Int
}

nonisolated struct SyncPlayback: Codable, Equatable, Sendable {
    var lastPosition: Double
    var delay: Double
    var rate: Double
}

nonisolated struct SyncHighlight: Codable, Equatable, Sendable {
    var character: Int
    var offset: Int
    var text: String
    var textFurigana: String?
    var color: String
    var createdAt: Int64

    init(_ highlight: Highlight) {
        character = highlight.character
        offset = highlight.offset
        text = highlight.text
        textFurigana = nil
        color = highlight.color.rawValue
        createdAt = highlight.createdAt.syncMilliseconds
    }

    func highlight(id: String) -> Highlight? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return Highlight(
            id: uuid,
            character: character,
            offset: offset,
            text: text,
            color: HighlightColor(rawValue: color) ?? .yellow,
            createdAt: Date(syncMilliseconds: createdAt)
        )
    }
}

nonisolated struct SyncBook: Codable, Equatable, Sendable {
    var generation: Int
    var deleted: Bool
    var metadata: Timestamped<SyncMetadata>
    var characterCount = 0
    var files: SyncFiles = [:]
    var bookmark: Timestamped<SyncBookmark>?
    var audiobook: Timestamped<SyncPlayback>?
    var highlights: [String: Timestamped<SyncHighlight?>] = [:]
    var sessions: [String: Timestamped<ReadingSession?>] = [:]
    var shelves: [String: Timestamped<Bool>] = [:]

    mutating func delete() {
        deleted = true
        files[.epub] = nil
        files[.sasayaki] = nil
        bookmark = nil
        audiobook = nil
        highlights = [:]
        shelves = [:]
    }

    func needsUpload(remote: Self?) -> Bool {
        guard let remote else { return true }
        return Self.merge(remote, self) != remote
    }

    static func merge(_ first: Self, _ second: Self) -> Self {
        var result: Self
        if first.generation != second.generation {
            result = first.generation > second.generation ? first : second
        } else {
            result = first
            result.metadata = .newest(first.metadata, second.metadata)
            result.characterCount = max(first.characterCount, second.characterCount)

            for fileType in SyncFileType.allCases {
                result.files[fileType] = .newest(first.files[fileType], second.files[fileType])
            }

            result.bookmark = .newest(first.bookmark, second.bookmark)
            result.audiobook = .newest(first.audiobook, second.audiobook)
            result.highlights = mergeRecords(first.highlights, second.highlights)
            result.shelves = Timestamped.merge(first.shelves, second.shelves)

            if first.deleted || second.deleted {
                result.delete()
            }
        }

        result.sessions = mergeRecords(first.sessions, second.sessions)
        return result
    }

    /// Records merge by id; a deletion marker always wins over an edit.
    static func mergeRecords<T>(_ first: [String: Timestamped<T?>], _ second: [String: Timestamped<T?>]) -> [String: Timestamped<T?>] {
        first.merging(second) { first, second in
            if first.value == nil && second.value != nil {
                return first
            }
            if second.value == nil && first.value != nil {
                return second
            }
            return .newest(first, second)
        }
    }
}

nonisolated struct SyncShelves: Codable, Equatable, Sendable {
    /// Shelf name to position; `nil` marks a deleted shelf.
    var shelves: [String: Timestamped<Int?>]
    var orders: [String: Timestamped<[String]?>] = [:]

    static func merge(_ first: Self, _ second: Self) -> Self {
        Self(shelves: Timestamped.merge(first.shelves, second.shelves), orders: Timestamped.merge(first.orders, second.orders))
    }
}

nonisolated enum SyncSessionID {
    /// Same derivation as upstream's legacy daily statistics, so the same historic day maps to
    /// one session on every device instead of being counted once per device.
    static func legacy(key: String, dateKey: String) -> String {
        uuid("\(key.precomposedStringWithCanonicalMapping)\n\(dateKey)\nlegacy")
    }

    /// Reading done on one device during one reporting day.
    static func device(_ deviceID: String, key: String, dateKey: String) -> String {
        uuid("\(key.precomposedStringWithCanonicalMapping)\n\(dateKey)\n\(deviceID)")
    }

    private static func uuid(_ seed: String) -> String {
        let hash = SHA256.hash(data: Data(seed.utf8))
        return hash.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }.uuidString
    }
}
