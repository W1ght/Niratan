import CoreGraphics
import Foundation

/// One recognized text block in page pixel space (top-left origin).
nonisolated struct MangaOCRBlock: Codable, Equatable, Sendable {
    var box: CGRect
    var isVertical: Bool
    var text: String
    /// Optional per-line rectangles in the same pixel space, in reading order.
    /// When present, `text` is the concatenation of the lines' text and
    /// `lineTexts` holds each line's portion.
    var lineBoxes: [CGRect]?
    var lineTexts: [String]?
    var score: Double
    var insideBubble: Bool

    init(
        box: CGRect,
        isVertical: Bool,
        text: String,
        lineBoxes: [CGRect]? = nil,
        lineTexts: [String]? = nil,
        score: Double = 0,
        insideBubble: Bool = false
    ) {
        self.box = box
        self.isVertical = isVertical
        self.text = text
        self.lineBoxes = lineBoxes
        self.lineTexts = lineTexts
        self.score = score
        self.insideBubble = insideBubble
    }

    /// Mokuro-style font size estimate: `sqrt(area / characters)`.
    var estimatedFontSize: Double {
        let count = text.utf16.count
        guard count > 0 else { return 0 }
        return (Double(box.width * box.height) / Double(count)).squareRoot()
    }
}

/// OCR output for one oriented page image, blocks in reading order.
nonisolated struct MangaOCRPageResult: Codable, Equatable, Sendable {
    var imageSize: CGSize
    var blocks: [MangaOCRBlock]
}

nonisolated enum MangaOCREngineError: LocalizedError, Equatable {
    case modelsMissing
    case modelInvalid(String)
    case inferenceFailed(String)
    case imageUnavailable
    case visionUnavailable

    var errorDescription: String? {
        switch self {
        case .modelsMissing:
            String(localized: "The local OCR models have not been downloaded.")
        case .modelInvalid, .inferenceFailed:
            String(localized: "Local text recognition failed.")
        case .imageUnavailable:
            String(localized: "The manga page could not be prepared for text recognition.")
        case .visionUnavailable:
            String(localized: "Apple text recognition is unavailable on this Mac.")
        }
    }
}

nonisolated extension CGRect {
    /// Fushi `OcrRect.containsPoint`: inclusive on every edge.
    func ocrContains(x: CGFloat, y: CGFloat) -> Bool {
        x >= minX && x <= maxX && y >= minY && y <= maxY
    }

    func ocrIoU(_ other: CGRect) -> CGFloat {
        let ix = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let iy = max(0, min(maxY, other.maxY) - max(minY, other.minY))
        let intersection = ix * iy
        guard intersection > 0 else { return 0 }
        let union = width * height + other.width * other.height - intersection
        return union <= 0 ? 0 : intersection / union
    }

    func ocrVerticalOverlaps(_ other: CGRect) -> Bool {
        min(maxY, other.maxY) > max(minY, other.minY)
    }

    func ocrHorizontalOverlaps(_ other: CGRect) -> Bool {
        min(maxX, other.maxX) > max(minX, other.minX)
    }

    /// Clamp every edge into `0...width` / `0...height` (Fushi `OcrRect.clamp`).
    func ocrClamped(width maxWidth: CGFloat, height maxHeight: CGFloat) -> CGRect {
        let left = Swift.min(Swift.max(minX, 0), maxWidth)
        let top = Swift.min(Swift.max(minY, 0), maxHeight)
        let right = Swift.min(Swift.max(maxX, 0), maxWidth)
        let bottom = Swift.min(Swift.max(maxY, 0), maxHeight)
        return CGRect(x: left, y: top, width: Swift.max(0, right - left), height: Swift.max(0, bottom - top))
    }

    static func ocr(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) -> CGRect {
        CGRect(x: left, y: top, width: Swift.max(0, right - left), height: Swift.max(0, bottom - top))
    }
}
