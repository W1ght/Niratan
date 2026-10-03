import CoreGraphics
import Foundation

/// Converts block-level OCR output into Niratan's per-character hit regions.
///
/// Sentence grouping follows Fushi's `manga_overlay_html.dart`: neighbouring
/// columns/rows of the same orientation join into one sentence until a strong
/// terminator, and narrow kana-only runs on the annotation side of a kanji run
/// are treated as furigana and left out of the joined sentence.
nonisolated enum MangaOCRRegionBuilder {
    static func regions(
        from page: MangaOCRPageResult,
        pageIndex: Int,
        idPrefix: String
    ) -> [MangaOCRTextRegion] {
        let width = page.imageSize.width
        let height = page.imageSize.height
        guard width > 0, height > 0, !page.blocks.isEmpty else { return [] }
        let assignments = sentenceAssignments(page.blocks)
        var regions: [MangaOCRTextRegion] = []
        for (blockIndex, block) in page.blocks.enumerated() {
            let assignment = assignments[blockIndex]
            let blockID = "\(idPrefix)-\(pageIndex)-\(blockIndex)"
            let lines = resolvedLines(block)
            var lineOffset = 0
            for (lineIndex, line) in lines.enumerated() {
                defer { lineOffset += line.text.utf16.count }
                let rect = normalized(line.rect, width: width, height: height)
                regions += characterRegions(
                    line: line.text,
                    sentence: assignment.sentence,
                    baseOffset: assignment.offset + lineOffset,
                    rect: rect,
                    pageIndex: pageIndex,
                    blockID: blockID,
                    lineID: "\(blockID)-\(lineIndex)",
                    isVertical: block.isVertical
                )
            }
        }
        return regions
    }

    // MARK: - Lines and characters

    private static func resolvedLines(_ block: MangaOCRBlock) -> [(text: String, rect: CGRect)] {
        if let boxes = block.lineBoxes, let texts = block.lineTexts,
           boxes.count == texts.count, !boxes.isEmpty,
           texts.joined() == block.text {
            return zip(texts, boxes).map { ($0, $1) }
        }
        return [(block.text, block.box)]
    }

    private static func normalized(_ rect: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        let left = min(max(0, rect.minX / width), 1)
        let top = min(max(0, rect.minY / height), 1)
        let right = min(max(0, rect.maxX / width), 1)
        let bottom = min(max(0, rect.maxY / height), 1)
        return CGRect(x: left, y: 1 - bottom, width: max(0, right - left), height: max(0, bottom - top))
    }

    /// Mirrors `MangaMokuroParser.makeCharacterRegions`: whitespace skipped,
    /// characters spread evenly along the reading axis (bottom-left origin).
    private static func characterRegions(
        line: String,
        sentence: String,
        baseOffset: Int,
        rect: CGRect,
        pageIndex: Int,
        blockID: String,
        lineID: String,
        isVertical: Bool
    ) -> [MangaOCRTextRegion] {
        let characters = line.indices.map { index in
            (offset: baseOffset + line[..<index].utf16.count, character: line[index])
        }.filter { !$0.character.isWhitespace }
        guard !characters.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let count = CGFloat(characters.count)
        return characters.enumerated().map { index, character in
            let characterRect: CGRect
            if isVertical {
                let step = rect.height / count
                characterRect = CGRect(x: rect.minX, y: rect.maxY - CGFloat(index + 1) * step, width: rect.width, height: step)
            } else {
                let step = rect.width / count
                characterRect = CGRect(x: rect.minX + CGFloat(index) * step, y: rect.minY, width: step, height: rect.height)
            }
            return MangaOCRTextRegion(
                id: "\(lineID)-\(character.offset)",
                pageIndex: pageIndex,
                blockID: blockID,
                lineID: lineID,
                sentence: sentence,
                utf16Offset: character.offset,
                isVertical: isVertical,
                normalizedBounds: characterRect
            )
        }
    }

    // MARK: - Sentence grouping

    /// Per block: the grouped sentence and this block's UTF-16 offset in it.
    /// Furigana blocks keep their own text as the sentence so a click on the
    /// reading still looks up the reading itself.
    static func sentenceAssignments(_ blocks: [MangaOCRBlock]) -> [(sentence: String, offset: Int)] {
        guard !blocks.isEmpty else { return [] }
        var parents = Array(blocks.indices)
        func root(_ value: Int) -> Int {
            var current = value
            while parents[current] != current { current = parents[current] }
            var cursor = value
            while parents[cursor] != cursor {
                let next = parents[cursor]
                parents[cursor] = current
                cursor = next
            }
            return current
        }
        func join(_ a: Int, _ b: Int) {
            let rootA = root(a)
            let rootB = root(b)
            if rootA != rootB { parents[rootB] = rootA }
        }

        var rubyBlocks: Set<Int> = []
        for candidateIndex in blocks.indices where isKanaOnly(blocks[candidateIndex].text) {
            var closestBase: Int?
            var closestGap = CGFloat.infinity
            for baseIndex in blocks.indices where baseIndex != candidateIndex {
                if let gap = rubyGap(candidate: blocks[candidateIndex], base: blocks[baseIndex]), gap < closestGap {
                    closestGap = gap
                    closestBase = baseIndex
                }
            }
            if let closestBase {
                rubyBlocks.insert(candidateIndex)
                join(candidateIndex, closestBase)
            }
        }

        for i in blocks.indices where !rubyBlocks.contains(i) {
            for j in blocks.indices where j > i && !rubyBlocks.contains(j) {
                guard areAdjacent(blocks[i], blocks[j]) else { continue }
                let earlier = compareReadingOrder(blocks[i], blocks[j]) <= 0 ? blocks[i] : blocks[j]
                if endsSentence(earlier.text) { continue }
                join(i, j)
            }
        }

        var groupOrder: [Int] = []
        var groups: [Int: [Int]] = [:]
        for index in blocks.indices {
            let groupRoot = root(index)
            if groups[groupRoot] == nil { groupOrder.append(groupRoot) }
            groups[groupRoot, default: []].append(index)
        }
        var result = Array(repeating: (sentence: "", offset: 0), count: blocks.count)
        for groupRoot in groupOrder {
            let indices = (groups[groupRoot] ?? []).enumerated().sorted { lhs, rhs in
                let order = compareReadingOrder(blocks[lhs.element], blocks[rhs.element])
                return order != 0 ? order < 0 : lhs.offset < rhs.offset
            }.map(\.element)
            var members = indices.filter { !rubyBlocks.contains($0) }
            if members.isEmpty { members = indices }
            var sentence = ""
            for index in members {
                result[index] = (sentence: "", offset: sentence.utf16.count)
                sentence += blocks[index].text
            }
            for index in members { result[index].sentence = sentence }
            for index in indices where !members.contains(index) {
                result[index] = (sentence: blocks[index].text, offset: 0)
            }
        }
        return result
    }

    private static let kanaOnlyPattern = try? NSRegularExpression(pattern: "^[\\u3040-\\u30ff\\u31f0-\\u31ff\\uff66-\\uff9dー]+$")
    private static let kanjiPattern = try? NSRegularExpression(pattern: "[\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff]")
    private static let terminatorPattern = try? NSRegularExpression(pattern: "[。！？.!?‼⁉][」』）)\\]】〉》〕｝}］”’]*$")

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func isKanaOnly(_ text: String) -> Bool { !text.isEmpty && matches(kanaOnlyPattern, text) }
    static func containsKanji(_ text: String) -> Bool { matches(kanjiPattern, text) }
    static func endsSentence(_ text: String) -> Bool { matches(terminatorPattern, text) }

    private static func axisOverlap(_ a: CGRect, _ b: CGRect, vertical: Bool) -> CGFloat {
        vertical
            ? max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
            : max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }

    private static func axisLength(_ rect: CGRect, vertical: Bool) -> CGFloat {
        vertical ? rect.height : rect.width
    }

    private static func crossThickness(_ rect: CGRect, vertical: Bool) -> CGFloat {
        vertical ? rect.width : rect.height
    }

    private static func crossGap(_ a: CGRect, _ b: CGRect, vertical: Bool) -> CGFloat {
        vertical
            ? max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
            : max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
    }

    private static func rubyGap(candidate: MangaOCRBlock, base: MangaOCRBlock) -> CGFloat? {
        guard candidate.isVertical == base.isVertical, containsKanji(base.text) else { return nil }
        let vertical = candidate.isVertical
        let candidateThickness = crossThickness(candidate.box, vertical: vertical)
        let baseThickness = crossThickness(base.box, vertical: vertical)
        guard candidateThickness > 0, baseThickness > 0, candidateThickness <= baseThickness * 0.68 else { return nil }
        let annotationSide = vertical ? candidate.box.midX > base.box.midX : candidate.box.midY < base.box.midY
        guard annotationSide else { return nil }
        let candidateLength = axisLength(candidate.box, vertical: vertical)
        let baseLength = axisLength(base.box, vertical: vertical)
        let overlap = axisOverlap(candidate.box, base.box, vertical: vertical)
        guard candidateLength > 0, baseLength > 0, overlap / min(candidateLength, baseLength) >= 0.45 else { return nil }
        let gap = crossGap(candidate.box, base.box, vertical: vertical)
        return gap <= max(6, CGFloat(base.estimatedFontSize) * 0.45) ? gap : nil
    }

    private static func areAdjacent(_ a: MangaOCRBlock, _ b: MangaOCRBlock) -> Bool {
        guard a.isVertical == b.isVertical else { return false }
        let vertical = a.isVertical
        let aLength = axisLength(a.box, vertical: vertical)
        let bLength = axisLength(b.box, vertical: vertical)
        guard aLength > 0, bLength > 0 else { return false }
        guard axisOverlap(a.box, b.box, vertical: vertical) / min(aLength, bLength) >= 0.30 else { return false }
        let gap = crossGap(a.box, b.box, vertical: vertical)
        return gap <= max(8, CGFloat(max(a.estimatedFontSize, b.estimatedFontSize)) * 0.90)
    }

    /// Negative when `a` reads before `b`.
    private static func compareReadingOrder(_ a: MangaOCRBlock, _ b: MangaOCRBlock) -> Int {
        if a.isVertical && b.isVertical {
            let delta = b.box.midX - a.box.midX
            if abs(delta) > 1 { return delta > 0 ? 1 : -1 }
            return a.box.minY < b.box.minY ? -1 : (a.box.minY > b.box.minY ? 1 : 0)
        }
        let delta = a.box.midY - b.box.midY
        if abs(delta) > 1 { return delta > 0 ? 1 : -1 }
        return a.box.minX < b.box.minX ? -1 : (a.box.minX > b.box.minX ? 1 : 0)
    }
}
