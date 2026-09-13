//
//  Sasayaki.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct SasayakiCue: Codable, Hashable, Sendable {
    let id: String
    let startTime: Double
    let endTime: Double
    let text: String
}

struct SasayakiAudiobookChapter: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let startTime: Double
    let endTime: Double?
}

struct SasayakiAudiobookMetadata: Equatable, Sendable {
    var title: String?
    var artist: String?
    var artworkData: Data?

    nonisolated static let empty = SasayakiAudiobookMetadata()
}

struct SasayakiMatch: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let startTime: Double
    let endTime: Double
    let text: String
    let chapterIndex: Int
    let start: Int
    let length: Int
    /// Present only when text-free interpolation between nearby narration anchors was used.
    var contextInferred: Bool? = nil
}

extension SasayakiMatch {
    func readerProgress(chapterCharacterCount: Int) -> Double {
        guard chapterCharacterCount > 0 else { return 0 }
        return min(max(Double(start) / Double(chapterCharacterCount), 0), 1)
    }
}

struct SasayakiCueRange: Encodable, Sendable {
    let id: String
    let start: Int
    let length: Int
}

struct SasayakiMatchData: Codable, Sendable {
    let matches: [SasayakiMatch]
    let unmatched: Int
}

struct SasayakiPlaybackData: Codable {
    var lastPosition: Double
    var delay: Double = 0
    var rate: Float = 1
    var audioBookmark: Data?
    
    init(lastPosition: Double) {
        self.lastPosition = lastPosition
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastPosition = try container.decode(Double.self, forKey: .lastPosition)
        delay = try container.decodeIfPresent(Double.self, forKey: .delay) ?? 0
        rate = try container.decodeIfPresent(Float.self, forKey: .rate) ?? 1
        audioBookmark = try container.decodeIfPresent(Data.self, forKey: .audioBookmark)
    }
}
