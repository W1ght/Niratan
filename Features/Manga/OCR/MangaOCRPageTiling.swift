import CoreGraphics
import Foundation

/// Tiling plan and cross-tile merging for line-level recognizers that take a
/// whole page (Fushi `ocr_page_tiling.dart`, BUG-2767): Vision downsamples the
/// page internally, so small bubble text is read from overlapping strips and
/// the strips' lines are merged back.
nonisolated enum MangaOCRPageTiling {
    static let targetTileHeight: CGFloat = 768
    static let targetTileWidth: CGFloat = 1536
    static let overlapRatio: CGFloat = 0.1
    static let minimumOverlap: CGFloat = 48
    static let maximumTiles = 12
    private static let stitchEdgeTrim = 2

    struct Line: Equatable {
        var text: String
        var rect: CGRect
        var tile: Int?
    }

    /// Tiles in page pixels (overlap included); empty means "whole page".
    static func plan(width: Int, height: Int) -> [CGRect] {
        guard width > 0, height > 0 else { return [] }
        let w = CGFloat(width)
        let h = CGFloat(height)
        var columns = max(1, Int((w / targetTileWidth).rounded(.up)))
        var rows = max(1, Int((h / targetTileHeight).rounded(.up)))
        while columns * rows > maximumTiles {
            if CGFloat(rows) / (h / targetTileHeight) >= CGFloat(columns) / (w / targetTileWidth) {
                if rows > 1 { rows -= 1 } else { columns -= 1 }
            } else if columns > 1 {
                columns -= 1
            } else {
                rows -= 1
            }
        }
        guard columns * rows > 1 else { return [] }
        let tileWidth = w / CGFloat(columns)
        let tileHeight = h / CGFloat(rows)
        let overlapX = max(minimumOverlap, tileWidth * overlapRatio)
        let overlapY = max(minimumOverlap, tileHeight * overlapRatio)
        var tiles: [CGRect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let left = column == 0 ? 0 : (CGFloat(column) * tileWidth - overlapX).rounded(.down)
                let top = row == 0 ? 0 : (CGFloat(row) * tileHeight - overlapY).rounded(.down)
                let right = column == columns - 1 ? w : min(w, max(0, (CGFloat(column + 1) * tileWidth + overlapX).rounded(.up)))
                let bottom = row == rows - 1 ? h : min(h, max(0, (CGFloat(row + 1) * tileHeight + overlapY).rounded(.up)))
                tiles.append(CGRect.ocr(left: left, top: top, right: right, bottom: bottom))
            }
        }
        return tiles
    }

    private struct TiledLine {
        var line: Line
        var clipTop: Bool
        var clipBottom: Bool
        var clipLeft: Bool
        var clipRight: Bool
        var clipped: Bool { clipTop || clipBottom || clipLeft || clipRight }
    }

    /// Drop clipped lines that another tile read whole, stitch lines cut by a
    /// tile edge, then remove duplicates read twice in the overlap.
    static func merge(_ lines: [Line], tiles: [CGRect]) -> [Line] {
        guard !tiles.isEmpty, lines.contains(where: { $0.tile != nil }) else { return lines }
        let pageRight = tiles.map(\.maxX).max() ?? 0
        let pageBottom = tiles.map(\.maxY).max() ?? 0
        var pending: [TiledLine] = lines.map { line in
            guard let index = line.tile, tiles.indices.contains(index) else {
                return TiledLine(line: line, clipTop: false, clipBottom: false, clipLeft: false, clipRight: false)
            }
            let tile = tiles[index]
            let rect = line.rect
            let margin = max(6, min(rect.width, rect.height))
            return TiledLine(
                line: line,
                clipTop: tile.minY > 0 && rect.minY - tile.minY <= margin,
                clipBottom: tile.maxY < pageBottom && tile.maxY - rect.maxY <= margin,
                clipLeft: tile.minX > 0 && rect.minX - tile.minX <= margin,
                clipRight: tile.maxX < pageRight && tile.maxX - rect.maxX <= margin
            )
        }

        let snapshot = pending
        pending = pending.enumerated().filter { index, candidate in
            guard candidate.clipped else { return true }
            return !snapshot.enumerated().contains { otherIndex, other in
                otherIndex != index && !other.clipped && other.line.tile != candidate.line.tile
                    && intersection(other.line.rect, candidate.line.rect) >= 0.5 * area(candidate.line.rect)
            }
        }.map(\.element)

        var merged = true
        while merged {
            merged = false
            outer: for i in pending.indices {
                for j in pending.indices where i != j {
                    if let stitched = stitch(pending[i], pending[j]) {
                        let (first, second) = (max(i, j), min(i, j))
                        pending.remove(at: first)
                        pending.remove(at: second)
                        pending.append(stitched)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return dedupe(pending.map(\.line))
    }

    private static func stitch(_ first: TiledLine, _ second: TiledLine) -> TiledLine? {
        guard first.line.tile != second.line.tile else { return nil }
        let a = first.line.rect
        let b = second.line.rect
        let alongY = first.clipBottom && second.clipTop
        let alongX = first.clipRight && second.clipLeft
        guard alongY || alongX else { return nil }
        let crossOverlap = alongY
            ? min(a.maxX, b.maxX) - max(a.minX, b.minX)
            : min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let crossMin = alongY ? min(a.width, b.width) : min(a.height, b.height)
        guard crossMin > 0, crossOverlap >= 0.5 * crossMin else { return nil }
        let aStart = alongY ? a.minY : a.minX
        let aEnd = alongY ? a.maxY : a.maxX
        let bStart = alongY ? b.minY : b.minX
        let bEnd = alongY ? b.maxY : b.maxX
        guard aStart < bStart, bStart < aEnd, aEnd < bEnd else { return nil }
        let text = stitchText(first.line.text, second.line.text, firstStart: aStart, firstEnd: aEnd, secondStart: bStart, secondEnd: bEnd)
        return TiledLine(
            line: Line(text: text, rect: a.union(b), tile: first.line.tile),
            clipTop: first.clipTop,
            clipBottom: second.clipBottom,
            clipLeft: first.clipLeft,
            clipRight: second.clipRight
        )
    }

    /// Join two halves of one line read in two tiles: prefer an exact
    /// tail/head overlap whose length matches the pixel overlap, allowing up
    /// to two damaged edge characters per half; else cut at the overlap middle.
    static func stitchText(
        _ first: String,
        _ second: String,
        firstStart: CGFloat,
        firstEnd: CGFloat,
        secondStart: CGFloat,
        secondEnd: CGFloat
    ) -> String {
        let a = Array(first.unicodeScalars)
        let b = Array(second.unicodeScalars)
        if a.isEmpty { return second }
        if b.isEmpty { return first }
        let pitchA = Double(firstEnd - firstStart) / Double(a.count)
        let pitchB = Double(secondEnd - secondStart) / Double(b.count)
        let pitch = (pitchA + pitchB) / 2
        let overlapPixels = Double(firstEnd - secondStart)
        let expected = pitch > 0 ? overlapPixels / pitch : 0
        var best: (trimA: Int, trimB: Int, k: Int)?
        var bestScore = Double.infinity
        for trimA in 0...stitchEdgeTrim {
            for trimB in 0...stitchEdgeTrim {
                let lengthA = a.count - trimA
                let lengthB = b.count - trimB
                let minimum = trimA + trimB == 0 ? 1 : 2
                var k = min(lengthA, lengthB)
                while k >= minimum {
                    defer { k -= 1 }
                    var matches = true
                    for index in 0..<k where a[lengthA - k + index] != b[trimB + index] {
                        matches = false
                        break
                    }
                    guard matches else { continue }
                    let deviation = abs(Double(k + max(trimA, trimB)) - expected)
                    if deviation > max(1.5, expected / 2) { continue }
                    let score = Double(trimA + trimB) * 10 + deviation
                    if score < bestScore {
                        bestScore = score
                        best = (trimA, trimB, k)
                    }
                }
            }
        }
        var scalars = String.UnicodeScalarView()
        if let best {
            scalars.append(contentsOf: a[0..<(a.count - best.trimA)])
            scalars.append(contentsOf: b[(best.trimB + best.k)...])
            return String(scalars)
        }
        let middle = Double(secondStart + firstEnd) / 2
        let keepA = pitchA > 0 ? min(max(Int(((middle - Double(firstStart)) / pitchA).rounded()), 0), a.count) : a.count
        let dropB = pitchB > 0 ? min(max(Int(((middle - Double(secondStart)) / pitchB).rounded()), 0), b.count) : 0
        scalars.append(contentsOf: a[0..<keepA])
        scalars.append(contentsOf: b[dropB...])
        return String(scalars)
    }

    private static func dedupe(_ lines: [Line]) -> [Line] {
        let byLength = lines.indices.sorted { x, y in
            let lx = lines[x].text.unicodeScalars.count
            let ly = lines[y].text.unicodeScalars.count
            return lx != ly ? lx > ly : x < y
        }
        var kept: [Int] = []
        for index in byLength {
            let line = lines[index]
            let duplicate = kept.contains { keptIndex in
                let other = lines[keptIndex]
                let shared = intersection(line.rect, other.rect)
                if shared < 0.5 * min(area(line.rect), area(other.rect)) { return false }
                return other.text.contains(line.text) || shared >= 0.8 * max(area(line.rect), area(other.rect))
            }
            if !duplicate { kept.append(index) }
        }
        return kept.sorted().map { lines[$0] }
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    private static func intersection(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) * max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }
}
