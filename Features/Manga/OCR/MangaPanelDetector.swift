import CoreGraphics
import Foundation

/// Manga panel detector (YOLO26n, Fushi `panel_detection.dart`): 640×640
/// squish RGB input, `[x1,y1,x2,y2,score,class]` output (class 0 = panel,
/// 1 = text), score ≥ 0.25, NMS IoU 0.5, row-banded reading order and
/// splitting of near-full-page panels along their text rows/columns.
actor MangaPanelDetector {
    static let shared = MangaPanelDetector()

    static let panelClass = 0
    static let textClass = 1
    static let confidenceThreshold = 0.25
    static let nmsIoUThreshold: CGFloat = 0.5

    struct Panel {
        var rect: CGRect
        var score: Double
    }

    private let store: MangaOCRModelStore
    private var session: MangaOCRSession?
    private var cache: [String: [CGRect]] = [:]
    private var cacheOrder: [String] = []

    init(store: MangaOCRModelStore = .shared) {
        self.store = store
    }

    func isReady() async -> Bool {
        await store.isReady(.panelDetector)
    }

    func unload() {
        session = nil
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Panels as 0–1 normalized rectangles (top-left origin) in reading order.
    /// `cacheKey` identifies the page for an in-memory LRU of 32 results.
    func detectPanels(in image: CGImage, rightToLeft: Bool, cacheKey: String? = nil) async throws -> [CGRect] {
        let key = cacheKey.map { "\($0)|\(rightToLeft ? "rtl" : "ltr")" }
        if let key, let cached = cache[key] {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            return cached
        }
        if session == nil {
            guard await store.isReady(.panelDetector) else { throw MangaOCREngineError.modelsMissing }
            session = try MangaOCRSession(modelURL: store.url(for: MangaOCRModelSet.panelFile))
        }
        guard let session, let bitmap = MangaOCRBitmap(image: image) else { throw MangaOCREngineError.imageUnavailable }
        try Task.checkCancellation()
        let size = MangaTextDetector.inputSize
        let input = MangaTextDetector.preprocess(bitmap, size: size)
        let outputs = try session.run([
            session.resolvedInputName("images"): try MangaOCRSession.floatValue(input, shape: [1, 3, size, size]),
        ])
        let detections = try Self.decode(outputs, inputSize: CGFloat(size))
        let panels = detections.filter { $0.classID == Self.panelClass }.map { Panel(rect: $0.rect, score: $0.score) }
        let text = detections.filter { $0.classID == Self.textClass }.map { Panel(rect: $0.rect, score: $0.score) }
        var expanded: [Panel] = []
        for panel in Self.orderPanels(panels, rightToLeft: rightToLeft) {
            expanded += Self.splitLargePanel(panel, textBoxes: text, rightToLeft: rightToLeft)
        }
        let ordered = Self.orderPanels(expanded, rightToLeft: rightToLeft).map(\.rect)
        if let key {
            cache[key] = ordered
            cacheOrder.append(key)
            while cacheOrder.count > 32 { cache[cacheOrder.removeFirst()] = nil }
        }
        return ordered
    }

    private struct Detection {
        let rect: CGRect
        let score: Double
        let classID: Int
    }

    private static func decode(_ outputs: [String: MangaOCRTensor], inputSize: CGFloat) throws -> [Detection] {
        func normalizedRect(_ values: [Float], _ offset: Int) -> CGRect {
            let raw = (0..<4).map { CGFloat(values[offset + $0]) }
            let isNormalized = raw.allSatisfy { abs($0) <= 1 }
            let scale: CGFloat = isNormalized ? 1 : 1 / inputSize
            return clamp(CGRect.ocr(left: raw[0] * scale, top: raw[1] * scale, right: raw[2] * scale, bottom: raw[3] * scale))
        }
        if let scores = outputs["scores"], let labels = outputs["labels"], let boxes = outputs["boxes"] {
            let scoreValues = scores.floats
            let labelValues = labels.floats
            let boxValues = boxes.floats
            guard scoreValues.count == labelValues.count, boxValues.count == scoreValues.count * 4 else {
                throw MangaOCREngineError.inferenceFailed("invalid processed panel output")
            }
            return scoreValues.indices.compactMap { index in
                guard Double(scoreValues[index]) >= confidenceThreshold else { return nil }
                return Detection(rect: normalizedRect(boxValues, index * 4), score: Double(scoreValues[index]), classID: Int(labelValues[index].rounded()))
            }
        }
        guard let tensor = outputs["output0"] ?? outputs.values.first,
              (tensor.shape.count == 2 && tensor.shape[1] == 6) || (tensor.shape.count == 3 && tensor.shape[0] == 1 && tensor.shape[2] == 6) else {
            throw MangaOCREngineError.inferenceFailed("panel detector output must be Nx6")
        }
        let values = tensor.floats
        return stride(from: 0, to: values.count - 5, by: 6).compactMap { offset in
            guard Double(values[offset + 4]) >= confidenceThreshold else { return nil }
            return Detection(rect: normalizedRect(values, offset), score: Double(values[offset + 4]), classID: Int(values[offset + 5].rounded()))
        }
    }

    private static func clamp(_ rect: CGRect) -> CGRect {
        rect.ocrClamped(width: 1, height: 1)
    }

    /// Greedy NMS by confidence, then rows by center-Y tolerance, rows top to
    /// bottom and panels within a row in reading direction.
    static func orderPanels(_ input: [Panel], rightToLeft: Bool) -> [Panel] {
        // Swift's sort is stable, so ties keep their input order.
        let clamped: [Panel] = input.map { Panel(rect: clamp($0.rect), score: $0.score) }
        let candidates = clamped
            .filter { $0.rect.width * $0.rect.height > 0 }
            .sorted { $0.score > $1.score }
        var kept: [Panel] = []
        for candidate in candidates where !kept.contains(where: { $0.rect.ocrIoU(candidate.rect) >= nmsIoUThreshold }) {
            kept.append(candidate)
        }
        kept.sort { $0.rect.midY < $1.rect.midY }
        var rows: [[Panel]] = []
        for panel in kept {
            var placed = false
            for rowIndex in rows.indices {
                let row = rows[rowIndex]
                let rowY = row.reduce(0) { $0 + $1.rect.midY } / CGFloat(row.count)
                let tallest = row.map(\.rect.height).max() ?? 0
                let tolerance = max(0.035, max(panel.rect.height, tallest) * 0.5)
                if abs(rowY - panel.rect.midY) <= tolerance {
                    rows[rowIndex].append(panel)
                    placed = true
                    break
                }
            }
            if !placed { rows.append([panel]) }
        }
        func rowCenter(_ row: [Panel]) -> CGFloat { row.reduce(0) { $0 + $1.rect.midY } / CGFloat(row.count) }
        rows.sort { rowCenter($0) < rowCenter($1) }
        return rows.flatMap { row in
            row.sorted { rightToLeft ? $0.rect.midX > $1.rect.midX : $0.rect.midX < $1.rect.midX }
        }
    }

    /// Split a panel covering > 75% of the page into reading anchors along
    /// its text rows (or columns when the text forms a single row).
    static func splitLargePanel(_ panel: Panel, textBoxes: [Panel], rightToLeft: Bool) -> [Panel] {
        let bounded = Panel(rect: clamp(panel.rect), score: panel.score)
        let box = bounded.rect
        guard box.width * box.height > 0.75 else { return [bounded] }
        var inside = textBoxes.map { Panel(rect: clamp($0.rect), score: $0.score) }.filter {
            $0.rect.width * $0.rect.height > 0
                && $0.rect.midX >= box.minX && $0.rect.midX <= box.maxX
                && $0.rect.midY >= box.minY && $0.rect.midY <= box.maxY
        }
        guard inside.count >= 2 else { return [bounded] }
        inside.sort { $0.rect.midY < $1.rect.midY }
        var rows: [[Panel]] = []
        for text in inside {
            if let index = rows.firstIndex(where: { abs($0[0].rect.midY - text.rect.midY) <= max(0.025, text.rect.height * 0.75) }) {
                rows[index].append(text)
            } else {
                rows.append([text])
            }
        }
        func center(_ row: [Panel]) -> CGFloat { row.reduce(0) { $0 + $1.rect.midY } / CGFloat(row.count) }
        if rows.count >= 2 {
            rows.sort { center($0) < center($1) }
            var strips: [Panel] = []
            for index in rows.indices {
                let current = center(rows[index])
                let previous = index == 0 ? box.minY : (center(rows[index - 1]) + current) / 2
                let next = index + 1 == rows.count ? box.maxY : (current + center(rows[index + 1])) / 2
                if next - previous > 0.01 {
                    strips.append(Panel(rect: CGRect.ocr(left: box.minX, top: previous, right: box.maxX, bottom: next), score: bounded.score))
                }
            }
            return strips.count >= 2 ? strips : [bounded]
        }
        // Build the column strips left to right (Fushi builds them in reading
        // order, which yields inverted boundaries for right-to-left pages),
        // then reverse for right-to-left reading.
        inside.sort { $0.rect.midX < $1.rect.midX }
        var columns: [Panel] = []
        for index in inside.indices {
            let current = inside[index].rect.midX
            let previous = index == 0 ? box.minX : (inside[index - 1].rect.midX + current) / 2
            let next = index + 1 == inside.count ? box.maxX : (current + inside[index + 1].rect.midX) / 2
            if next - previous > 0.01 {
                columns.append(Panel(rect: CGRect.ocr(left: previous, top: box.minY, right: next, bottom: box.maxY), score: bounded.score))
            }
        }
        guard columns.count >= 2 else { return [bounded] }
        return rightToLeft ? columns.reversed() : columns
    }
}
