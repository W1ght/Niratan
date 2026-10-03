import CoreGraphics
import Foundation

/// ogkalu/comic-text-and-bubble-detector (RT-DETR-v2) port of Fushi's
/// `text_detector.dart`: squish-resize to 640×640, RGB/255 CHW without
/// mean/std, sigmoid score threshold 0.3, text-group NMS at IoU 0.7.
nonisolated struct MangaDetectedTextRegion: Sendable {
    let rect: CGRect
    let score: Double
    /// 1 = text inside bubble, 2 = free text.
    let classID: Int
    let insideBubble: Bool
}

nonisolated final class MangaTextDetector: @unchecked Sendable {
    static let inputSize = 640
    static let scoreThreshold = 0.3
    static let nmsIoUThreshold: CGFloat = 0.7
    static let classBubble = 0
    static let classTextBubble = 1
    static let classTextFree = 2

    private let session: MangaOCRSession

    init(modelURL: URL) throws {
        session = try MangaOCRSession(modelURL: modelURL)
    }

    struct RawDetection {
        let rect: CGRect
        let score: Double
        let classID: Int
    }

    /// RGB / 255, CHW, after the `package:image` linear point-sample resize.
    static func preprocess(_ bitmap: MangaOCRBitmap, size: Int = inputSize) -> [Float] {
        let resized = bitmap.resizedLinear(width: size, height: size)
        let plane = size * size
        var chw = [Float](repeating: 0, count: 3 * plane)
        resized.pixels.withUnsafeBufferPointer { pixels in
            chw.withUnsafeMutableBufferPointer { output in
                for index in 0..<plane {
                    output[index] = Float(Double(pixels[index * 3]) / 255.0)
                    output[plane + index] = Float(Double(pixels[index * 3 + 1]) / 255.0)
                    output[2 * plane + index] = Float(Double(pixels[index * 3 + 2]) / 255.0)
                }
            }
        }
        return chw
    }

    func detect(_ bitmap: MangaOCRBitmap) throws -> [MangaDetectedTextRegion] {
        let size = Self.inputSize
        let input = Self.preprocess(bitmap)
        let inputName = session.resolvedInputName("pixel_values", alternates: ["images"])
        var feeds = [inputName: try MangaOCRSession.floatValue(input, shape: [1, 3, size, size])]
        if session.inputNames.contains("orig_target_sizes") {
            feeds["orig_target_sizes"] = try MangaOCRSession.int64Value([Int64(size), Int64(size)], shape: [1, 2])
        }
        let outputs = try session.run(feeds)
        let scaleX = CGFloat(size) / CGFloat(bitmap.width)
        let scaleY = CGFloat(size) / CGFloat(bitmap.height)
        let width = CGFloat(bitmap.width)
        let height = CGFloat(bitmap.height)
        var raw: [RawDetection] = []
        if let logits = outputs["logits"], let boxes = outputs["pred_boxes"] {
            let queries = logits.shape.count > 1 ? logits.shape[1] : 0
            let classes = logits.shape.count > 2 ? logits.shape[2] : 0
            let logitValues = logits.floats
            let boxValues = boxes.floats
            for query in 0..<queries {
                for classIndex in 0..<classes {
                    let score = 1 / (1 + exp(-Double(logitValues[query * classes + classIndex])))
                    if score < Self.scoreThreshold { continue }
                    let cx = CGFloat(boxValues[query * 4]) * CGFloat(size)
                    let cy = CGFloat(boxValues[query * 4 + 1]) * CGFloat(size)
                    let w = CGFloat(boxValues[query * 4 + 2]) * CGFloat(size)
                    let h = CGFloat(boxValues[query * 4 + 3]) * CGFloat(size)
                    let rect = CGRect.ocr(
                        left: (cx - w / 2) / scaleX,
                        top: (cy - h / 2) / scaleY,
                        right: (cx + w / 2) / scaleX,
                        bottom: (cy + h / 2) / scaleY
                    ).ocrClamped(width: width, height: height)
                    if rect.width * rect.height <= 0 { continue }
                    raw.append(RawDetection(rect: rect, score: score, classID: classIndex))
                }
            }
        } else if let scores = outputs["scores"], let labels = outputs["labels"], let boxes = outputs["boxes"] {
            let scoreValues = scores.floats
            let labelValues = labels.floats
            let boxValues = boxes.floats
            guard scoreValues.count == labelValues.count, boxValues.count == scoreValues.count * 4 else {
                throw MangaOCREngineError.inferenceFailed("detector output shapes disagree")
            }
            for index in scoreValues.indices {
                let score = Double(scoreValues[index])
                if score < Self.scoreThreshold { continue }
                let rect = CGRect.ocr(
                    left: CGFloat(boxValues[index * 4]) / scaleX,
                    top: CGFloat(boxValues[index * 4 + 1]) / scaleY,
                    right: CGFloat(boxValues[index * 4 + 2]) / scaleX,
                    bottom: CGFloat(boxValues[index * 4 + 3]) / scaleY
                ).ocrClamped(width: width, height: height)
                if rect.width * rect.height <= 0 { continue }
                raw.append(RawDetection(rect: rect, score: score, classID: Int(labelValues[index].rounded())))
            }
        } else {
            throw MangaOCREngineError.inferenceFailed("detector outputs missing: \(outputs.keys.sorted())")
        }
        return Self.buildRegions(Self.nms(raw))
    }

    /// Bubbles (class 0) form one NMS group; both text classes share another.
    static func nms(_ detections: [RawDetection]) -> [RawDetection] {
        let sorted = detections.enumerated().sorted {
            $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset
        }.map(\.element)
        var kept: [RawDetection] = []
        for candidate in sorted {
            let group = candidate.classID == classBubble ? 0 : 1
            let suppressed = kept.contains { keep in
                (keep.classID == classBubble ? 0 : 1) == group
                    && keep.rect.ocrIoU(candidate.rect) >= nmsIoUThreshold
            }
            if !suppressed { kept.append(candidate) }
        }
        return kept
    }

    static func buildRegions(_ detections: [RawDetection]) -> [MangaDetectedTextRegion] {
        let bubbles = detections.filter { $0.classID == classBubble }.map(\.rect)
        return detections.compactMap { detection in
            guard detection.classID == classTextBubble || detection.classID == classTextFree else { return nil }
            let inside = bubbles.contains { $0.ocrContains(x: detection.rect.midX, y: detection.rect.midY) }
            return MangaDetectedTextRegion(
                rect: detection.rect,
                score: detection.score,
                classID: detection.classID,
                insideBubble: inside
            )
        }
    }
}
