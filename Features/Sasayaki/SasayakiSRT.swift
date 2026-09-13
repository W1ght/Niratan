// Copyright © 2026 Niratan contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Keeps generated subtitles compatible with Sasayaki's existing SRT importer.
enum SasayakiSRT {
    nonisolated static func encode(_ cues: [SasayakiCue]) -> String {
        cues.filter { $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0 && $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
            .enumerated().map { index, cue in
                let text = cue.text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                return "\(index + 1)\n\(timestamp(cue.startTime)) --> \(timestamp(max(cue.endTime, cue.startTime + 0.001)))\n\(text)\n"
            }.joined(separator: "\n")
    }

    private nonisolated static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((min(seconds, 359_999_999) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
