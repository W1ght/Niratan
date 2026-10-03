import CoreGraphics
import Foundation

/// The on-device recognizer used for whole text blocks.
nonisolated enum MangaLocalOCRModel: String, CaseIterable, Codable, Sendable {
    /// Fushi "manga CTC (fast)": per-column CTC with the manga-tuned
    /// PP-OCRv6 recognizer (Kellenok/PP-OCRv6_manga v0.2). ~42 MB.
    case mangaCTC
    /// Classic manga-ocr (ViT encoder + BERT decoder, 4-beam search) with the
    /// KV-cache decoder export. ~484 MB.
    case mangaOCR

    var modelSet: MangaOCRModelSet {
        switch self {
        case .mangaCTC: .mangaCTC
        case .mangaOCR: .mangaOCR
        }
    }
}

/// Recognition result for one block before it becomes a `MangaOCRBlock`.
nonisolated struct MangaOCRRecognition: Sendable {
    var text: String
    var isVertical: Bool
    var lines: [String]?
    var lineBoxes: [CGRect]?
}

/// On-device manga OCR ported from Fushi's local ONNX pipeline (v5, line
/// geometry): RT-DETR text detection → reading order → per-block routing.
///
/// Routing (Fushi `routing_ocr_recognizer.dart`): blocks at least as wide as
/// they are tall are split into lines by PP-OCRv6 det; a strict vertical
/// majority (multi-column vertical speech) goes back to the primary
/// recognizer, otherwise each horizontal line is read by the CTC line
/// recognizer and stray vertical lines by the primary recognizer. Taller
/// blocks go straight to the primary recognizer:
/// - `.mangaCTC`: column-by-column CTC (`ctc_column_ocr_recognizer.dart`) with
///   length-weighted orientation voting, furigana removal and fragment
///   merging; each column's text and box are returned directly.
/// - `.mangaOCR`: whole-block manga-ocr, then the text is split over the
///   detected columns by cell capacity (`ocr_line_layout.dart`).
actor MangaLocalOCREngine {
    static let shared = MangaLocalOCREngine()

    /// Display threshold for vertical blocks (`kVerticalAspectThreshold`).
    static let verticalAspectThreshold: CGFloat = 1.25
    /// Padding around vertical lines found inside horizontal blocks.
    static let routingLinePadding: CGFloat = 4

    private let store: MangaOCRModelStore
    private var detector: MangaTextDetector?
    private var lineDetector: MangaPPLineDetector?
    private var ppLineRecognizer: MangaPPLineRecognizer?
    private var ctcRecognizer: MangaPPLineRecognizer?
    private var mangaOCRRecognizer: MangaOCRRecognizer?

    init(store: MangaOCRModelStore = .shared) {
        self.store = store
    }

    /// Cache identity for results produced with `model`.
    nonisolated func engineSignature(for model: MangaLocalOCRModel) -> String {
        switch model {
        case .mangaCTC:
            "local-onnx-ctc-kellenok-v0.2-v5-line-geometry-\(store.fingerprint(for: .mangaCTC))"
        case .mangaOCR:
            "local-onnx-manga-ocr-v5-line-geometry-\(store.fingerprint(for: .mangaOCR))"
        }
    }

    func isReady(_ model: MangaLocalOCRModel) async -> Bool {
        await store.isReady(model.modelSet)
    }

    func unload() {
        detector = nil
        lineDetector = nil
        ppLineRecognizer = nil
        ctcRecognizer = nil
        mangaOCRRecognizer = nil
    }

    func recognize(
        _ image: CGImage,
        model: MangaLocalOCRModel = .mangaCTC,
        rightToLeft: Bool = true
    ) async throws -> MangaOCRPageResult {
        let components = try await load(model)
        guard let page = MangaOCRBitmap(image: image) else { throw MangaOCREngineError.imageUnavailable }
        return try Self.recognize(page: page, components: components, rightToLeft: rightToLeft)
    }

    /// Detector-only pass, reused by the Vision engine to guide its crops.
    func detectTextRegions(_ image: CGImage) async throws -> [MangaDetectedTextRegion] {
        guard await store.isReady(.textDetector) else { throw MangaOCREngineError.modelsMissing }
        if detector == nil {
            detector = try MangaTextDetector(modelURL: store.url(for: MangaOCRModelSet.detectorFile))
        }
        guard let detector, let page = MangaOCRBitmap(image: image) else { throw MangaOCREngineError.imageUnavailable }
        return try detector.detect(page)
    }

    // MARK: - Components

    struct Components: @unchecked Sendable {
        let detector: MangaTextDetector
        let lineDetector: MangaPPLineDetector
        /// Reads horizontal lines inside horizontal blocks.
        let lineRecognizer: MangaPPLineRecognizer
        let primary: Primary
    }

    enum Primary: @unchecked Sendable {
        case ctcColumns(MangaPPLineRecognizer)
        case mangaOCR(MangaOCRRecognizer)
    }

    private func load(_ model: MangaLocalOCRModel) async throws -> Components {
        guard await store.isReady(model.modelSet) else { throw MangaOCREngineError.modelsMissing }
        let url = { (file: MangaOCRModelFile) in self.store.url(for: file) }
        if detector == nil {
            detector = try MangaTextDetector(modelURL: url(MangaOCRModelSet.detectorFile))
        }
        if lineDetector == nil {
            lineDetector = try MangaPPLineDetector(modelURL: url(MangaOCRModelSet.lineDetectorFile))
        }
        guard let detector, let lineDetector else { throw MangaOCREngineError.modelsMissing }
        switch model {
        case .mangaCTC:
            if ctcRecognizer == nil {
                ctcRecognizer = try MangaPPLineRecognizer(
                    modelURL: url(MangaOCRModelSet.mangaCTCRecognizerFile),
                    dictionaryURL: url(MangaOCRModelSet.lineDictionaryFile)
                )
            }
            guard let ctcRecognizer else { throw MangaOCREngineError.modelsMissing }
            // The manga-tuned recognizer also reads horizontal lines.
            return Components(
                detector: detector,
                lineDetector: lineDetector,
                lineRecognizer: ctcRecognizer,
                primary: .ctcColumns(ctcRecognizer)
            )
        case .mangaOCR:
            if ppLineRecognizer == nil {
                ppLineRecognizer = try MangaPPLineRecognizer(
                    modelURL: url(MangaOCRModelSet.lineRecognizerFile),
                    dictionaryURL: url(MangaOCRModelSet.lineDictionaryFile)
                )
            }
            if mangaOCRRecognizer == nil {
                mangaOCRRecognizer = try MangaOCRRecognizer(
                    encoderURL: url(MangaOCRModelSet.encoderFile),
                    crossKVURL: url(MangaOCRModelSet.crossKVFile),
                    decoderKVURL: url(MangaOCRModelSet.decoderKVFile),
                    vocabURL: url(MangaOCRModelSet.vocabFile)
                )
            }
            guard let ppLineRecognizer, let mangaOCRRecognizer else { throw MangaOCREngineError.modelsMissing }
            return Components(
                detector: detector,
                lineDetector: lineDetector,
                lineRecognizer: ppLineRecognizer,
                primary: .mangaOCR(mangaOCRRecognizer)
            )
        }
    }

    /// Test/harness entry: build components from explicit files.
    static func components(
        detector: MangaTextDetector,
        lineDetector: MangaPPLineDetector,
        lineRecognizer: MangaPPLineRecognizer,
        primary: Primary
    ) -> Components {
        Components(detector: detector, lineDetector: lineDetector, lineRecognizer: lineRecognizer, primary: primary)
    }

    nonisolated static func recognize(
        page: MangaOCRBitmap,
        components: Components,
        rightToLeft: Bool = true
    ) throws -> MangaOCRPageResult {
        try Task.checkCancellation()
        let regions = try components.detector.detect(page)
        let order = MangaOCRReadingOrder.order(regions.map(\.rect), rightToLeft: rightToLeft)
        var blocks: [MangaOCRBlock] = []
        for index in order {
            try Task.checkCancellation()
            let region = regions[index]
            let recognition = try recognizeRouted(page: page, box: region.rect, components: components)
            guard !recognition.text.isEmpty else { continue }
            // Line geometry is only used when it reassembles the exact text.
            let lines = recognition.lines
            let hasLayout = lines.map { !$0.isEmpty && $0.joined() == recognition.text } ?? false
            blocks.append(MangaOCRBlock(
                box: region.rect,
                isVertical: recognition.isVertical,
                text: recognition.text,
                lineBoxes: hasLayout ? recognition.lineBoxes : nil,
                lineTexts: hasLayout ? lines : nil,
                score: region.score,
                insideBubble: region.insideBubble
            ))
        }
        return MangaOCRPageResult(imageSize: CGSize(width: page.width, height: page.height), blocks: suppressContainedBlocks(blocks))
    }

    // MARK: - Routing

    nonisolated static func isVerticalBlock(_ box: CGRect) -> Bool {
        box.height > box.width * verticalAspectThreshold
    }

    /// Horizontal path when the block is at least as wide as it is tall.
    nonisolated static func routesToHorizontalPath(_ box: CGRect) -> Bool {
        box.width >= box.height
    }

    nonisolated static func recognizeRouted(
        page: MangaOCRBitmap,
        box: CGRect,
        components: Components
    ) throws -> MangaOCRRecognition {
        let routed = try route(page: page, box: box, components: components)
        if !routed.recognition.text.isEmpty { return routed.recognition }
        switch components.primary {
        case .ctcColumns(let recognizer):
            return try recognizeColumns(
                page: page,
                box: box,
                vertical: routed.recognition.isVertical,
                lineHints: routed.lineHints,
                lineDetector: components.lineDetector,
                recognizer: recognizer
            )
        case .mangaOCR(let recognizer):
            return try layoutRecognized(
                page: page,
                box: box,
                text: try recognizer.recognize(page, box: box),
                vertical: routed.recognition.isVertical,
                lineHints: routed.lineHints,
                lineDetector: components.lineDetector
            )
        }
    }

    /// Primary recognizer for a single box (used for vertical lines found
    /// inside horizontal blocks).
    nonisolated static func recognizePrimary(page: MangaOCRBitmap, box: CGRect, components: Components) throws -> String {
        switch components.primary {
        case .ctcColumns(let recognizer):
            try recognizeColumns(
                page: page,
                box: box,
                vertical: isVerticalBlock(box),
                lineHints: nil,
                lineDetector: components.lineDetector,
                recognizer: recognizer
            ).text
        case .mangaOCR(let recognizer):
            try recognizer.recognize(page, box: box)
        }
    }

    /// Decide the block orientation; horizontal blocks are read line by line
    /// here. An empty `text` means "hand the whole block to the primary".
    nonisolated static func route(
        page: MangaOCRBitmap,
        box: CGRect,
        components: Components
    ) throws -> (recognition: MangaOCRRecognition, lineHints: [CGRect]?) {
        guard routesToHorizontalPath(box) else {
            return (MangaOCRRecognition(text: "", isVertical: isVerticalBlock(box)), nil)
        }
        guard let crop = page.blockCrop(box) else {
            return (MangaOCRRecognition(text: "", isVertical: false), nil)
        }
        let offsetX = CGFloat(crop.x)
        let offsetY = CGFloat(crop.y)
        let w = crop.bitmap.width
        let h = crop.bitmap.height
        let raw = try components.lineDetector.detect(crop.bitmap)
        let detected = MangaPPLineDetector.filterThinLines(raw)
        let lineHints = raw.map { $0.rect.offsetBy(dx: offsetX, dy: offsetY) }
        if MangaPPLineDetector.linesAreVerticalMajority(detected) {
            return (MangaOCRRecognition(text: "", isVertical: true), lineHints)
        }
        var texts: [String] = []
        var boxes: [CGRect] = []
        for line in MangaPPLineDetector.orderForReading(detected) {
            try Task.checkCancellation()
            let rect = line.rect.ocrClamped(width: CGFloat(w), height: CGFloat(h))
            if rect.width < 1 || rect.height < 1 { continue }
            let text: String
            if line.isVertical {
                text = try recognizePrimary(page: page, box: CGRect.ocr(
                    left: offsetX + rect.minX - routingLinePadding,
                    top: offsetY + rect.minY - routingLinePadding,
                    right: offsetX + rect.maxX + routingLinePadding,
                    bottom: offsetY + rect.maxY + routingLinePadding
                ), components: components)
            } else {
                let lx = Int(floor(rect.minX))
                let ly = Int(floor(rect.minY))
                text = try components.lineRecognizer.recognizeLine(crop.bitmap.cropped(
                    x: lx,
                    y: ly,
                    width: min(max(1, Int(ceil(rect.width))), w - lx),
                    height: min(max(1, Int(ceil(rect.height))), h - ly)
                ))
            }
            if text.isEmpty { continue }
            texts.append(text)
            boxes.append(rect.offsetBy(dx: offsetX, dy: offsetY))
        }
        let joined = texts.joined()
        return (
            MangaOCRRecognition(
                text: joined,
                isVertical: false,
                lines: joined.isEmpty ? nil : texts,
                lineBoxes: joined.isEmpty ? nil : boxes
            ),
            lineHints
        )
    }

    /// Column-by-column CTC (`CtcColumnOcrRecognizer.recognizeWithLines`).
    nonisolated static func recognizeColumns(
        page: MangaOCRBitmap,
        box: CGRect,
        vertical: Bool,
        lineHints: [CGRect]?,
        lineDetector: MangaPPLineDetector,
        recognizer: MangaPPLineRecognizer
    ) throws -> MangaOCRRecognition {
        let detected = try lineHints ?? lineDetector.detectInBlock(page, box: box)
        let blockVertical = MangaOCRLineLayout.voteOrientation(detected) ?? vertical
        let lines = MangaOCRLineLayout.readingLines(detected, vertical: blockVertical)
        if lines.isEmpty {
            return MangaOCRRecognition(
                text: try readRegion(page: page, region: box, vertical: blockVertical, recognizer: recognizer),
                isVertical: blockVertical
            )
        }
        var texts: [String] = []
        var boxes: [CGRect] = []
        for line in lines {
            try Task.checkCancellation()
            let region = line.ocrClamped(width: CGFloat(page.width), height: CGFloat(page.height))
            if region.width < 1 || region.height < 1 { continue }
            let text = try readRegion(page: page, region: region, vertical: blockVertical, recognizer: recognizer)
            if text.isEmpty { continue }
            texts.append(text)
            boxes.append(region)
        }
        guard !texts.isEmpty else { return MangaOCRRecognition(text: "", isVertical: blockVertical) }
        return MangaOCRRecognition(text: texts.joined(), isVertical: blockVertical, lines: texts, lineBoxes: boxes)
    }

    /// Crop a page region and read it as one line; vertical columns are
    /// rotated 90° counter-clockwise first (PaddleOCR `np.rot90`).
    nonisolated static func readRegion(
        page: MangaOCRBitmap,
        region: CGRect,
        vertical: Bool,
        recognizer: MangaPPLineRecognizer
    ) throws -> String {
        guard let crop = page.blockCrop(region) else { return "" }
        return try recognizer.recognizeLine(vertical ? crop.bitmap.rotatedCounterClockwise() : crop.bitmap)
    }

    /// Split whole-block text over the block's detected columns/rows.
    nonisolated static func layoutRecognized(
        page: MangaOCRBitmap,
        box: CGRect,
        text: String,
        vertical: Bool,
        lineHints: [CGRect]?,
        lineDetector: MangaPPLineDetector
    ) throws -> MangaOCRRecognition {
        guard !text.isEmpty else { return MangaOCRRecognition(text: text, isVertical: vertical) }
        let rects = try lineHints ?? lineDetector.detectInBlock(page, box: box)
        let layoutVertical = MangaOCRLineLayout.voteOrientation(rects) ?? vertical
        guard let layout = MangaOCRLineLayout.layoutText(
            text,
            on: MangaOCRLineLayout.readingLines(rects, vertical: layoutVertical),
            vertical: layoutVertical
        ) else {
            return MangaOCRRecognition(text: text, isVertical: vertical)
        }
        return MangaOCRRecognition(text: text, isVertical: layoutVertical, lines: layout.lines, lineBoxes: layout.boxes)
    }

    /// Drop a horizontal child block whose exact text is already read by a
    /// higher-scoring horizontal parent box that fully contains it.
    nonisolated static func suppressContainedBlocks(_ blocks: [MangaOCRBlock]) -> [MangaOCRBlock] {
        blocks.filter { child in
            let inner = child.box
            if child.text.isEmpty || inner.width * inner.height <= 0 || inner.width < inner.height { return true }
            return !blocks.contains { parent in
                let outer = parent.box
                return parent.score > child.score
                    && outer.width >= outer.height
                    && outer.minX <= inner.minX && outer.minY <= inner.minY
                    && outer.maxX >= inner.maxX && outer.maxY >= inner.maxY
                    && parent.text.contains(child.text)
            }
        }
    }
}
