import CoreGraphics
import Foundation
import Vision

/// Apple Vision manga OCR configuration.
nonisolated struct MangaVisionOCRConfiguration: Sendable, Equatable {
    enum Request: Sendable, Equatable {
        /// `RecognizeTextRequest` (does not read vertical Japanese).
        case text
        /// `RecognizeDocumentsRequest` (macOS 26; reads vertical columns).
        case documents
    }

    enum Layout: Sendable, Equatable {
        /// Whole page in one request.
        case wholePage
        /// Overlapping horizontal strips (Fushi BUG-2767 tiling).
        case tiles
        /// One request per detected text block (needs the text detector).
        case detectorCrops
    }

    var request: Request = .documents
    var layout: Layout = .detectorCrops
    var usesLanguageCorrection = true
    var languages = ["ja-JP"]
    /// Upscale crops so their short side reaches at least this many pixels.
    var minimumCropShortSide: CGFloat = 128
    /// Padding around detector crops, as a fraction of the short side.
    var cropPaddingRatio: CGFloat = 0.08
}

/// Apple Vision manga OCR.
///
/// Fushi sends the whole page (or three overlapping strips) to Vision. With
/// the text detector installed this engine instead reads every detected
/// block on its own, which keeps small bubble text above Vision's internal
/// detection floor and gives every block its own column geometry.
actor MangaVisionOCREngine {
    static let shared = MangaVisionOCREngine()

    private let configuration: MangaVisionOCRConfiguration
    private let localEngine: MangaLocalOCREngine

    init(configuration: MangaVisionOCRConfiguration = .init(), localEngine: MangaLocalOCREngine = .shared) {
        self.configuration = configuration
        self.localEngine = localEngine
    }

    nonisolated var engineSignature: String {
        "apple-vision-v1"
    }

    func recognize(_ image: CGImage, rightToLeft: Bool = true) async throws -> MangaOCRPageResult {
        let size = CGSize(width: image.width, height: image.height)
        if configuration.layout == .detectorCrops,
           let regions = try? await localEngine.detectTextRegions(image) {
            return try await recognizeCrops(image, regions: regions, rightToLeft: rightToLeft)
        }
        var lines: [Line]
        if configuration.layout == .tiles {
            let tiles = MangaOCRPageTiling.plan(width: image.width, height: image.height)
            if tiles.isEmpty {
                lines = try await Self.recognizeLines(in: image, configuration: configuration)
            } else {
                var tiled: [MangaOCRPageTiling.Line] = []
                for (index, tile) in tiles.enumerated() {
                    try Task.checkCancellation()
                    guard let crop = image.cropping(to: tile.integral) else { continue }
                    for line in try await Self.recognizeLines(in: crop, configuration: configuration) {
                        tiled.append(.init(text: line.text, rect: line.rect.offsetBy(dx: tile.minX, dy: tile.minY), tile: index))
                    }
                }
                lines = MangaOCRPageTiling.merge(tiled, tiles: tiles).map { Line(text: $0.text, rect: $0.rect, confidence: 1) }
            }
        } else {
            lines = try await Self.recognizeLines(in: image, configuration: configuration)
        }
        let blocks = lines.map { line in
            MangaOCRBlock(
                box: line.rect,
                isVertical: line.rect.height > line.rect.width * 1.6,
                text: line.text,
                score: Double(line.confidence)
            )
        }
        return MangaOCRPageResult(imageSize: size, blocks: blocks)
    }

    private func recognizeCrops(
        _ image: CGImage,
        regions: [MangaDetectedTextRegion],
        rightToLeft: Bool
    ) async throws -> MangaOCRPageResult {
        let size = CGSize(width: image.width, height: image.height)
        let order = MangaOCRReadingOrder.order(regions.map(\.rect), rightToLeft: rightToLeft)
        var blocks: [MangaOCRBlock] = []
        for index in order {
            try Task.checkCancellation()
            guard let block = try await recognizeBlock(image, region: regions[index]) else { continue }
            blocks.append(block)
        }
        return MangaOCRPageResult(imageSize: size, blocks: blocks)
    }

    private func recognizeBlock(_ image: CGImage, region: MangaDetectedTextRegion) async throws -> MangaOCRBlock? {
        let box = region.rect
        let padding = max(4, min(box.width, box.height) * configuration.cropPaddingRatio)
        let padded = box.insetBy(dx: -padding, dy: -padding)
            .ocrClamped(width: CGFloat(image.width), height: CGFloat(image.height))
            .integral
        guard padded.width >= 2, padded.height >= 2, let crop = image.cropping(to: padded) else { return nil }
        var source = crop
        if configuration.minimumCropShortSide > 0 {
            let scale = configuration.minimumCropShortSide / min(padded.width, padded.height)
            if scale > 1.01, let scaled = Self.scaled(crop, by: min(scale, 4)) { source = scaled }
        }
        let recognized = try await Self.recognizeLines(in: source, configuration: configuration)
        guard !recognized.isEmpty else { return nil }
        let factorX = padded.width / CGFloat(source.width)
        let factorY = padded.height / CGFloat(source.height)
        let lines = recognized.map { line in
            Line(
                text: line.text,
                rect: CGRect(
                    x: padded.minX + line.rect.minX * factorX,
                    y: padded.minY + line.rect.minY * factorY,
                    width: line.rect.width * factorX,
                    height: line.rect.height * factorY
                ),
                confidence: line.confidence
            )
        }
        let vertical = MangaOCRLineLayout.voteOrientation(lines.map(\.rect))
            ?? MangaLocalOCREngine.isVerticalBlock(box)
        // Drop furigana columns/rows, then read in column/row order.
        let ordered = MangaOCRLineLayout.nonRubyIndices(lines.map(\.rect), vertical: vertical)
            .map { lines[$0] }
            .sorted { lhs, rhs in
                vertical
                    ? lhs.rect.midX > rhs.rect.midX
                    : lhs.rect.midY < rhs.rect.midY
            }
        let text = ordered.map(\.text).joined()
        guard !text.isEmpty else { return nil }
        return MangaOCRBlock(
            box: box,
            isVertical: vertical,
            text: text,
            lineBoxes: ordered.map(\.rect),
            lineTexts: ordered.map(\.text),
            score: region.score,
            insideBubble: region.insideBubble
        )
    }

    struct Line {
        var text: String
        /// Pixel rect, top-left origin.
        var rect: CGRect
        var confidence: Float
    }

    static func recognizeLines(in image: CGImage, configuration: MangaVisionOCRConfiguration) async throws -> [Line] {
        let languages = configuration.languages.map { Locale.Language(identifier: $0) }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        func pixelRect(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        }
        func clean(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\n", with: "")
        }
        switch configuration.request {
        case .text:
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = configuration.usesLanguageCorrection
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = languages
            let observations = try await request.perform(on: image, orientation: .up)
            return observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = clean(candidate.string)
                let rect = pixelRect(observation.boundingBox.cgRect)
                guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return nil }
                return Line(text: text, rect: rect, confidence: candidate.confidence)
            }
        case .documents:
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.recognitionLanguages = languages
            request.textRecognitionOptions.useLanguageCorrection = configuration.usesLanguageCorrection
            request.textRecognitionOptions.automaticallyDetectLanguage = false
            let observations = try await request.perform(on: image, orientation: .up)
            var lines: [Line] = []
            for observation in observations {
                for paragraph in observation.document.paragraphs {
                    for line in paragraph.lines {
                        let text = clean(line.transcript)
                        let rect = pixelRect(line.boundingRegion.boundingBox.cgRect)
                        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { continue }
                        lines.append(Line(text: text, rect: rect, confidence: 1))
                    }
                }
            }
            return lines
        }
    }

    static func scaled(_ image: CGImage, by scale: CGFloat) -> CGImage? {
        let width = Int((CGFloat(image.width) * scale).rounded())
        let height = Int((CGFloat(image.height) * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
