//
//  SasayakiParser.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct SasayakiParser {
    static func parseCues(from data: Data) -> [SasayakiCue] {
        /*
         1
         00:00:19,124 --> 00:00:22,016
         ＊シックスイヤーザー号、
         
         2
         00:00:24,148 --> 00:00:28,468
         渚　それはある日の、あたし達にとっては日常の光景だった。
         */
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n[\\t ]*\n", with: "\n\n", options: .regularExpression)
            .components(separatedBy: "\n\n")
            .enumerated()
            .compactMap { index, block in
                let lines = block.components(separatedBy: "\n")
                guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                      timingIndex + 1 < lines.count else {
                    return nil
                }
                
                let times = lines[timingIndex].components(separatedBy: "-->")
                guard times.count == 2,
                      let start = parseTimestamp(times[0]), let end = parseTimestamp(times[1]),
                      end > start else { return nil }
                let text = lines.dropFirst(timingIndex + 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return SasayakiCue(
                    id: String(index),
                    startTime: start,
                    endTime: end,
                    text: text
                )
            }
    }
    
    private static func parseTimestamp(_ timestamp: String) -> Double? {
        guard let value = timestamp.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let parts = value
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]),
              let seconds = Double(parts[2]), hours.isFinite, minutes.isFinite, seconds.isFinite,
              hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { return nil }
        let total = hours * 3600 + minutes * 60 + seconds
        return total.isFinite ? total : nil
    }
}
