import CoreGraphics
import Foundation

/// Line-level geometry for OCR blocks (Fushi `ocr_line_layout.dart`):
/// length-weighted orientation voting, furigana line removal, fragment
/// merging, reading order and splitting whole-block text over the detected
/// columns/rows so a click lands on the right column.
nonisolated enum MangaOCRLineLayout {
    static let orientationRatio: CGFloat = 1.5

    static func thickness(_ rect: CGRect, vertical: Bool) -> CGFloat {
        vertical ? rect.width : rect.height
    }

    static func length(_ rect: CGRect, vertical: Bool) -> CGFloat {
        vertical ? rect.height : rect.width
    }

    /// Clear vertical lines vote with their height, clear horizontal lines
    /// with their width; nil when no line is clearly oriented.
    static func voteOrientation(_ lines: [CGRect]) -> Bool? {
        var vertical: CGFloat = 0
        var horizontal: CGFloat = 0
        for line in lines {
            if line.height >= orientationRatio * line.width {
                vertical += line.height
            } else if line.width >= orientationRatio * line.height {
                horizontal += line.width
            }
        }
        if vertical == 0 && horizontal == 0 { return nil }
        return vertical >= horizontal
    }

    /// Furigana: thinner than `thinRatio` × the p75 thickness, or thinner than
    /// `sideRatio` × p75 while hugging the annotation side of a line at least
    /// 1.25× thicker (right of vertical text, above horizontal text).
    static func dropRubyLines(
        _ lines: [CGRect],
        vertical: Bool,
        thinRatio: CGFloat = 0.6,
        sideRatio: CGFloat = 0.82
    ) -> [CGRect] {
        nonRubyIndices(lines, vertical: vertical, thinRatio: thinRatio, sideRatio: sideRatio).map { lines[$0] }
    }

    /// Indices of `lines` that survive `dropRubyLines`, in input order.
    static func nonRubyIndices(
        _ lines: [CGRect],
        vertical: Bool,
        thinRatio: CGFloat = 0.6,
        sideRatio: CGFloat = 0.82
    ) -> [Int] {
        guard lines.count >= 2 else { return Array(lines.indices) }
        let sorted = lines.map { thickness($0, vertical: vertical) }.sorted()
        let p75 = sorted[min(sorted.count - 1, (3 * sorted.count) / 4)]
        func besideThickerLine(_ index: Int) -> Bool {
            let line = lines[index]
            let own = thickness(line, vertical: vertical)
            for (otherIndex, other) in lines.enumerated() where otherIndex != index {
                let base = thickness(other, vertical: vertical)
                if base < own * 1.25 { continue }
                let gap = vertical ? line.minX - other.maxX : other.minY - line.maxY
                let along = vertical
                    ? min(line.maxY, other.maxY) - max(line.minY, other.minY)
                    : min(line.maxX, other.maxX) - max(line.minX, other.minX)
                if gap >= -0.35 * base && gap <= 0.35 * base && along > 0 { return true }
            }
            return false
        }
        return lines.indices.filter { index in
            let own = thickness(lines[index], vertical: vertical)
            if own < thinRatio * p75 { return false }
            return !(own < sideRatio * p75 && besideThickerLine(index))
        }
    }

    /// Merge fragments of one column/row whose cross-axis overlap reaches
    /// `overlapRatio` of the thinner piece.
    static func mergeFragments(_ rects: [CGRect], vertical: Bool, overlapRatio: CGFloat = 0.5) -> [CGRect] {
        guard !rects.isEmpty else { return [] }
        func crossStart(_ r: CGRect) -> CGFloat { vertical ? r.minX : r.minY }
        func crossEnd(_ r: CGRect) -> CGFloat { vertical ? r.maxX : r.maxY }
        let sorted = rects.sorted { crossStart($0) + crossEnd($0) < crossStart($1) + crossEnd($1) }
        var merged = [sorted[0]]
        for rect in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            let overlap = min(crossEnd(last), crossEnd(rect)) - max(crossStart(last), crossStart(rect))
            let thinner = min(thickness(last, vertical: vertical), thickness(rect, vertical: vertical))
            if thinner > 0 && overlap >= overlapRatio * thinner {
                merged[merged.count - 1] = last.union(rect)
            } else {
                merged.append(rect)
            }
        }
        return merged
    }

    /// Vertical: columns right to left; horizontal: rows top to bottom.
    static func orderForReading(_ rects: [CGRect], vertical: Bool) -> [CGRect] {
        if vertical {
            return rects.sorted { $0.minX + $0.maxX > $1.minX + $1.maxX }
        }
        return rects.sorted { $0.minY + $0.maxY < $1.minY + $1.maxY }
    }

    /// Ruby removal → fragment merge → reading order, the shared column plan.
    static func readingLines(_ detected: [CGRect], vertical: Bool) -> [CGRect] {
        orderForReading(
            mergeFragments(dropRubyLines(detected, vertical: vertical), vertical: vertical),
            vertical: vertical
        )
    }

    private static func isDotRun(_ cluster: Character) -> Bool {
        ".．・…‥".contains(cluster)
    }

    private static func isMarkRun(_ cluster: Character) -> Bool {
        "!！?？".contains(cluster)
    }

    /// Cells per grapheme: dot runs share one cell; `!?` runs take one cell
    /// per pair; whitespace takes none.
    private static func cellWeights(_ clusters: [Character]) -> [Double] {
        var weights = clusters.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.0 : 1.0 }
        var index = 0
        while index < clusters.count {
            let dot = isDotRun(clusters[index])
            let mark = isMarkRun(clusters[index])
            guard dot || mark else {
                index += 1
                continue
            }
            var end = index + 1
            while end < clusters.count && (dot ? isDotRun(clusters[end]) : isMarkRun(clusters[end])) {
                end += 1
            }
            let run = end - index
            if run >= 2 {
                let cells = dot ? 1.0 : (Double(run) / 2).rounded(.up)
                for k in index..<end { weights[k] = cells / Double(run) }
            }
            index = end
        }
        return weights
    }

    /// Split `text` across `lines` (already in reading order) by each line's
    /// cell capacity (`length / thickness`). Returns nil when no geometry can
    /// be produced. `lines.joined() == text` always holds for the result.
    static func layoutText(_ text: String, on lines: [CGRect], vertical: Bool) -> (lines: [String], boxes: [CGRect])? {
        let usable = lines.filter { $0.width > 0 && $0.height > 0 }
        guard !usable.isEmpty else { return nil }
        let clusters = Array(text)
        let weights = cellWeights(clusters)
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return nil }
        let capacities = usable.map { line in
            max(0.5, Double(length(line, vertical: vertical)) / max(1e-6, Double(thickness(line, vertical: vertical))))
        }
        let totalCapacity = capacities.reduce(0, +)
        var ends: [Double] = []
        var accumulated = 0.0
        for capacity in capacities {
            accumulated += capacity / totalCapacity * totalWeight
            ends.append(accumulated)
        }
        var buffers = Array(repeating: "", count: usable.count)
        var hasVisible = Array(repeating: false, count: usable.count)
        var line = 0
        var position = 0.0
        for (index, cluster) in clusters.enumerated() {
            let weight = weights[index]
            if weight > 0 {
                let middle = position + weight / 2
                position += weight
                while line < usable.count - 1 && middle > ends[line] { line += 1 }
                hasVisible[line] = true
            }
            buffers[line].append(cluster)
        }
        var outLines: [String] = []
        var outBoxes: [CGRect] = []
        var pending = ""
        for index in usable.indices {
            let content = buffers[index]
            if !hasVisible[index] {
                if outLines.isEmpty {
                    pending += content
                } else {
                    outLines[outLines.count - 1] += content
                }
                continue
            }
            outLines.append(pending + content)
            pending = ""
            outBoxes.append(usable[index])
        }
        guard !outLines.isEmpty else { return nil }
        return (outLines, outBoxes)
    }
}
