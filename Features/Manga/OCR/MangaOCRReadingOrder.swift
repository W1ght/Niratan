import CoreGraphics
import Foundation

/// Text-block reading order (Fushi `reading_order.dart`): cluster blocks into
/// panels, flow panels by horizontal bands top-to-bottom and right-to-left,
/// then order each panel's blocks column-major.
nonisolated enum MangaOCRReadingOrder {
    static func order(_ boxes: [CGRect], rightToLeft: Bool = true, panelGapRatio: CGFloat = 0.75) -> [Int] {
        guard !boxes.isEmpty else { return [] }
        let panels = cluster(boxes.count) { i, j in
            let a = boxes[i]
            let b = boxes[j]
            let threshold = panelGapRatio * min(min(a.width, a.height), min(b.width, b.height))
            return gapX(a, b) <= threshold && gapY(a, b) <= threshold
        }
        let bounds = panels.map { panel in
            panel.dropFirst().reduce(boxes[panel[0]]) { $0.union(boxes[$1]) }
        }
        var bands = cluster(panels.count) { bounds[$0].ocrVerticalOverlaps(bounds[$1]) }
        bands = stableSorted(bands) { band in band.map { bounds[$0].minY }.min() ?? 0 }
        var result: [Int] = []
        for band in bands {
            let ordered = band.enumerated().sorted { lhs, rhs in
                let a = bounds[lhs.element].midX
                let b = bounds[rhs.element].midX
                if a != b { return rightToLeft ? a > b : a < b }
                return lhs.offset < rhs.offset
            }.map(\.element)
            for panelIndex in ordered {
                result.append(contentsOf: orderWithinPanel(boxes, panel: panels[panelIndex], rightToLeft: rightToLeft))
            }
        }
        return result
    }

    static func orderWithinPanel(_ boxes: [CGRect], panel: [Int], rightToLeft: Bool) -> [Int] {
        let local = cluster(panel.count) { boxes[panel[$0]].ocrHorizontalOverlaps(boxes[panel[$1]]) }
        var columns = local.map { column in column.map { panel[$0] } }
        func center(_ column: [Int]) -> CGFloat {
            column.reduce(0) { $0 + boxes[$1].midX } / CGFloat(column.count)
        }
        columns = columns.enumerated().sorted { lhs, rhs in
            let a = center(lhs.element)
            let b = center(rhs.element)
            if a != b { return rightToLeft ? a > b : a < b }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return columns.flatMap { column in
            column.enumerated().sorted { lhs, rhs in
                let a = boxes[lhs.element].minY
                let b = boxes[rhs.element].minY
                return a != b ? a < b : lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    private static func stableSorted(_ groups: [[Int]], key: ([Int]) -> CGFloat) -> [[Int]] {
        groups.enumerated().sorted { lhs, rhs in
            let a = key(lhs.element)
            let b = key(rhs.element)
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func gapX(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
    }

    private static func gapY(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
    }

    /// Union-find clustering; clusters keep first-member insertion order.
    static func cluster(_ count: Int, related: (Int, Int) -> Bool) -> [[Int]] {
        var parent = Array(0..<count)
        func find(_ value: Int) -> Int {
            var x = value
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for i in 0..<count {
            for j in (i + 1)..<max(i + 1, count) where related(i, j) {
                let ri = find(i)
                let rj = find(j)
                if ri != rj { parent[ri] = rj }
            }
        }
        var order: [Int] = []
        var clusters: [Int: [Int]] = [:]
        for index in 0..<count {
            let root = find(index)
            if clusters[root] == nil { order.append(root) }
            clusters[root, default: []].append(index)
        }
        return order.compactMap { clusters[$0] }
    }
}
