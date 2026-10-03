import CoreGraphics
import Foundation
import OnnxRuntimeBindings

/// manga-ocr (mayocream/manga-ocr-onnx) port of Fushi's
/// `manga_ocr_recognizer.dart`, `manga_ocr_tokenizer.dart` and
/// `beam_search.dart`.
nonisolated struct MangaOCRTokenizer: Sendable {
    let tokens: [String]
    let clsID: Int
    let sepID: Int
    let specialIDs: Set<Int>

    init(vocabText: String) throws {
        var tokens = vocabText.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        while tokens.last?.isEmpty == true { tokens.removeLast() }
        func require(_ token: String) throws -> Int {
            guard let index = tokens.firstIndex(of: token) else {
                throw MangaOCREngineError.modelInvalid("vocab.txt missing \(token)")
            }
            return index
        }
        let cls = try require("[CLS]")
        let sep = try require("[SEP]")
        var special: Set<Int> = [cls, sep, try require("[PAD]"), try require("[UNK]")]
        if let mask = tokens.firstIndex(of: "[MASK]") { special.insert(mask) }
        self.tokens = tokens
        clsID = cls
        sepID = sep
        specialIDs = special
    }

    func decode(_ ids: [Int]) -> String {
        var text = ""
        for id in ids where id >= 0 && id < tokens.count && !specialIDs.contains(id) {
            let token = tokens[id]
            text += token.hasPrefix("##") ? String(token.dropFirst(2)) : token
        }
        return Self.postProcess(text)
    }

    /// manga-ocr `post_process`: drop whitespace, `…` → `...`, runs of
    /// `[・.]{2,}` → the same number of `.`, then `jaconv.h2z(ascii, digit)`.
    static func postProcess(_ text: String) -> String {
        var result = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
        result = result.replacingOccurrences(of: "…", with: "...")
        if let regex = try? NSRegularExpression(pattern: "[・.]{2,}") {
            let source = result as NSString
            var output = ""
            var cursor = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)) {
                output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                output += String(repeating: ".", count: match.range.length)
                cursor = match.range.location + match.range.length
            }
            output += source.substring(from: cursor)
            result = output
        }
        return halfwidthASCIIToFullwidth(result)
    }

    /// `jaconv.h2z(text, kana=True, ascii=True, digit=True)` for the ASCII
    /// printable range (manga-ocr's final normalization step).
    static func halfwidthASCIIToFullwidth(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x21 && scalar.value <= 0x7E, let wide = Unicode.Scalar(scalar.value + 0xFEE0) {
                scalars.append(wide)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

nonisolated enum MangaOCRBeamSearch {
    struct Configuration {
        var startTokenID: Int
        var eosTokenID: Int
        var numBeams = 4
        var lengthPenalty = 2.0
        var noRepeatNgramSize = 3
        var maxLength = 300
        var earlyStopping = true
    }

    static func bannedTokens(_ sequence: [Int], ngramSize: Int) -> Set<Int> {
        guard ngramSize > 0, sequence.count + 1 >= ngramSize else { return [] }
        let prefixLength = ngramSize - 1
        let prefix = Array(sequence.suffix(prefixLength))
        var banned: Set<Int> = []
        var index = 0
        while index + ngramSize <= sequence.count {
            var matches = true
            for offset in 0..<prefixLength where sequence[index + offset] != prefix[offset] {
                matches = false
                break
            }
            if matches { banned.insert(sequence[index + prefixLength]) }
            index += 1
        }
        return banned
    }

    /// Returns the best hypothesis' tokens without the start token.
    /// `stepLogits` gets every live beam sequence plus, per beam, the index of
    /// the previous-step beam it extends (all 0 on the first step, used by KV
    /// caches to reorder `past`), and returns the last position's logits.
    static func decode(
        configuration: Configuration,
        stepLogits: ([[Int]], [Int]) throws -> [[Float]]
    ) throws -> [Int] {
        let numBeams = configuration.numBeams
        var sequences = Array(repeating: [configuration.startTokenID], count: numBeams)
        var beamScores = Array(repeating: -Double.infinity, count: numBeams)
        beamScores[0] = 0
        var sourceBeams = Array(repeating: 0, count: numBeams)
        var finished: [(tokens: [Int], score: Double)] = []

        func addHypothesis(_ tokens: [Int], _ sumLogProbs: Double) {
            let score = sumLogProbs / pow(Double(tokens.count), configuration.lengthPenalty)
            if finished.count < numBeams {
                finished.append((tokens, score))
                return
            }
            var worst = 0
            for index in 1..<finished.count where finished[index].score < finished[worst].score {
                worst = index
            }
            if score > finished[worst].score { finished[worst] = (tokens, score) }
        }

        var searchDone = false
        var currentLength = 1
        while currentLength < configuration.maxLength && !searchDone {
            try Task.checkCancellation()
            let logitsPerBeam = try stepLogits(sequences, sourceBeams)
            let vocabSize = logitsPerBeam[0].count
            let candidateCount = min(2 * numBeams, numBeams * vocabSize)
            var topBeam = Array(repeating: 0, count: candidateCount)
            var topToken = Array(repeating: 0, count: candidateCount)
            var topScore = Array(repeating: -Double.infinity, count: candidateCount)
            for beam in 0..<numBeams {
                let beamScore = beamScores[beam]
                if beamScore == -.infinity { continue }
                let logits = logitsPerBeam[beam]
                let logSumExp = logSumExp(logits)
                let banned = bannedTokens(sequences[beam], ngramSize: configuration.noRepeatNgramSize)
                logits.withUnsafeBufferPointer { values in
                    for token in 0..<vocabSize {
                        let score = (Double(values[token]) - logSumExp) + beamScore
                        if score <= topScore[candidateCount - 1] { continue }
                        if banned.contains(token) { continue }
                        var position = candidateCount - 1
                        while position > 0 && topScore[position - 1] < score {
                            topScore[position] = topScore[position - 1]
                            topBeam[position] = topBeam[position - 1]
                            topToken[position] = topToken[position - 1]
                            position -= 1
                        }
                        topScore[position] = score
                        topBeam[position] = beam
                        topToken[position] = token
                    }
                }
            }

            var nextSequences: [[Int]] = []
            var nextScores: [Double] = []
            var nextSources: [Int] = []
            for rank in 0..<candidateCount {
                if topScore[rank] == -.infinity { break }
                let beam = topBeam[rank]
                let token = topToken[rank]
                if token == configuration.eosTokenID {
                    if rank < numBeams { addHypothesis(sequences[beam], topScore[rank]) }
                    continue
                }
                nextSequences.append(sequences[beam] + [token])
                nextScores.append(topScore[rank])
                nextSources.append(beam)
                if nextSequences.count == numBeams { break }
            }
            if nextSequences.isEmpty {
                searchDone = true
                break
            }
            while nextSequences.count < numBeams {
                nextSequences.append(nextSequences[nextSequences.count - 1])
                nextScores.append(-.infinity)
                nextSources.append(nextSources[nextSources.count - 1])
            }
            sequences = nextSequences
            beamScores = nextScores
            sourceBeams = nextSources
            currentLength += 1

            if finished.count >= numBeams && configuration.earlyStopping {
                searchDone = true
            } else if finished.count >= numBeams {
                let bestAlive = beamScores.max() ?? -.infinity
                let highest = bestAlive / pow(Double(currentLength), configuration.lengthPenalty)
                if (finished.map(\.score).min() ?? .infinity) >= highest { searchDone = true }
            }
        }

        if !searchDone || finished.count < numBeams {
            for beam in 0..<numBeams where beamScores[beam] != -.infinity {
                addHypothesis(sequences[beam], beamScores[beam])
            }
        }
        var best: (tokens: [Int], score: Double)?
        for hypothesis in finished where best == nil || hypothesis.score > best!.score {
            best = hypothesis
        }
        return Array((best?.tokens ?? [configuration.startTokenID]).dropFirst())
    }

    private static func logSumExp(_ logits: [Float]) -> Double {
        var maximum = -Double.infinity
        for value in logits where Double(value) > maximum { maximum = Double(value) }
        var sum = 0.0
        for value in logits { sum += exp(Double(value) - maximum) }
        return maximum + log(sum)
    }
}

nonisolated final class MangaOCRRecognizer: @unchecked Sendable {
    static let inputSize = 224
    static let numBeams = 4
    /// `past_key_values` / `cross_key_values` layout: 2 decoder layers × (K, V),
    /// 12 heads of 64 dimensions.
    static let kvLayerSlots = 4
    static let kvHeads = 12
    static let kvHeadDimension = 64

    private enum Decoder {
        /// Classic export: the whole sequence is re-run every step.
        case classic(MangaOCRSession)
        /// KV-cache export (Fushi `manga-ocr-kv-onnx-v1`): identical tokens,
        /// one new token per step plus cached past/cross key-values.
        case cached(cross: MangaOCRSession, decoder: MangaOCRSession)
    }

    private let encoder: MangaOCRSession
    private let decoder: Decoder
    let tokenizer: MangaOCRTokenizer

    init(
        encoderURL: URL,
        decoderURL: URL? = nil,
        crossKVURL: URL? = nil,
        decoderKVURL: URL? = nil,
        vocabURL: URL,
        provider: MangaOCRSession.Provider = .cpu
    ) throws {
        encoder = try MangaOCRSession(modelURL: encoderURL, provider: provider)
        if let crossKVURL, let decoderKVURL {
            decoder = .cached(
                cross: try MangaOCRSession(modelURL: crossKVURL, provider: provider),
                decoder: try MangaOCRSession(modelURL: decoderKVURL, provider: provider)
            )
        } else if let decoderURL {
            decoder = .classic(try MangaOCRSession(modelURL: decoderURL, provider: provider))
        } else {
            throw MangaOCREngineError.modelsMissing
        }
        guard let vocab = try? String(contentsOf: vocabURL, encoding: .utf8) else {
            throw MangaOCREngineError.modelInvalid("vocab.txt")
        }
        tokenizer = try MangaOCRTokenizer(vocabText: vocab)
    }

    func recognize(_ page: MangaOCRBitmap, box: CGRect) throws -> String {
        let pixels = Self.preprocess(page, box: box)
        let pixelValue = try MangaOCRSession.floatValue(pixels, shape: [1, 3, Self.inputSize, Self.inputSize])
        let configuration = MangaOCRBeamSearch.Configuration(
            startTokenID: tokenizer.clsID,
            eosTokenID: tokenizer.sepID,
            numBeams: Self.numBeams
        )
        switch decoder {
        case .classic(let decoder):
            return try recognizeClassic(pixelValue, decoder: decoder, configuration: configuration)
        case .cached(let cross, let decoder):
            return try recognizeCached(pixelValue, cross: cross, decoder: decoder, configuration: configuration)
        }
    }

    private func recognizeClassic(
        _ pixelValue: ORTValue,
        decoder: MangaOCRSession,
        configuration: MangaOCRBeamSearch.Configuration
    ) throws -> String {
        let encoderOutputs = try encoder.run([encoder.resolvedInputName("pixel_values"): pixelValue])
        guard let hidden = encoderOutputs["last_hidden_state"] ?? encoderOutputs.values.first,
              hidden.shape.count == 3 else {
            throw MangaOCREngineError.inferenceFailed("encoder output missing")
        }
        let beams = configuration.numBeams
        var tiled = Data(capacity: hidden.data.count * beams)
        for _ in 0..<beams { tiled.append(hidden.data) }
        let hiddenValue = try MangaOCRSession.floatValue(data: tiled, shape: [beams, hidden.shape[1], hidden.shape[2]])
        let result = try MangaOCRBeamSearch.decode(configuration: configuration) { sequences, _ in
            let beams = sequences.count
            let length = sequences[0].count
            var ids = [Int64](repeating: 0, count: beams * length)
            for beam in 0..<beams {
                for step in 0..<length { ids[beam * length + step] = Int64(sequences[beam][step]) }
            }
            let outputs = try decoder.run([
                "input_ids": try MangaOCRSession.int64Value(ids, shape: [beams, length]),
                "encoder_hidden_states": hiddenValue,
            ])
            guard let logits = outputs["logits"] ?? outputs.values.first, logits.shape.count == 3 else {
                throw MangaOCREngineError.inferenceFailed("decoder output missing")
            }
            let vocab = logits.shape[2]
            return logits.data.withUnsafeBytes { raw -> [[Float]] in
                let values = raw.bindMemory(to: Float.self)
                return (0..<beams).map { beam in
                    let offset = (beam * length + (length - 1)) * vocab
                    return Array(values[offset..<(offset + vocab)])
                }
            }
        }
        return tokenizer.decode(result)
    }

    private func recognizeCached(
        _ pixelValue: ORTValue,
        cross: MangaOCRSession,
        decoder: MangaOCRSession,
        configuration: MangaOCRBeamSearch.Configuration
    ) throws -> String {
        guard let hidden = try encoder.runValues(
            [encoder.resolvedInputName("pixel_values"): pixelValue],
            outputNames: ["last_hidden_state"]
        )["last_hidden_state"] else {
            throw MangaOCREngineError.inferenceFailed("encoder output missing")
        }
        guard let crossValues = try cross.runValues(
            ["encoder_hidden_states": hidden],
            outputNames: ["cross_key_values"]
        )["cross_key_values"] else {
            throw MangaOCREngineError.inferenceFailed("cross_kv output missing")
        }
        // First step: an all-zero placeholder past [4,1,12,1,64]; the graph
        // drops slot 0, which is equivalent to having no past.
        var past = try MangaOCRSession.floatValue(
            [Float](repeating: 0, count: Self.kvLayerSlots * Self.kvHeads * Self.kvHeadDimension),
            shape: [Self.kvLayerSlots, 1, Self.kvHeads, 1, Self.kvHeadDimension]
        )
        var firstStep = true
        let result = try MangaOCRBeamSearch.decode(configuration: configuration) { sequences, sourceBeams in
            // Every beam starts from the same token and only beam 0 has a
            // finite score, so the first step runs one row and copies it.
            let beams = firstStep ? 1 : sequences.count
            var ids = [Int64](repeating: 0, count: beams)
            var beamIndex = [Int64](repeating: 0, count: beams)
            for beam in 0..<beams {
                ids[beam] = Int64(sequences[beam][sequences[beam].count - 1])
                beamIndex[beam] = firstStep ? 0 : Int64(sourceBeams[beam])
            }
            let outputs = try decoder.runValues(
                [
                    "input_ids": try MangaOCRSession.int64Value(ids, shape: [beams, 1]),
                    "beam_idx": try MangaOCRSession.int64Value(beamIndex, shape: [beams]),
                    "past_key_values": past,
                    "cross_key_values": crossValues,
                ],
                outputNames: ["logits", "present_key_values"]
            )
            guard let logits = outputs["logits"], let present = outputs["present_key_values"],
                  let data = try? logits.tensorData() else {
                throw MangaOCREngineError.inferenceFailed("decoder_kv output missing")
            }
            past = present
            let rows = (data as Data).withUnsafeBytes { raw -> [[Float]] in
                let values = raw.bindMemory(to: Float.self)
                let vocab = values.count / beams
                return (0..<beams).map { beam in Array(values[(beam * vocab)..<((beam + 1) * vocab)]) }
            }
            if !firstStep { return rows }
            firstStep = false
            return Array(repeating: rows[0], count: sequences.count)
        }
        return tokenizer.decode(result)
    }

    /// Crop (floor/ceil, clamped), PIL `convert("L")`, PIL BILINEAR to
    /// 224×224, `(v/255 - 0.5)/0.5` replicated to three channels.
    static func preprocess(_ page: MangaOCRBitmap, box: CGRect) -> [Float] {
        let expanded = box.ocrClamped(width: CGFloat(page.width), height: CGFloat(page.height))
        let x = min(max(Int(floor(expanded.minX)), 0), page.width - 1)
        let y = min(max(Int(floor(expanded.minY)), 0), page.height - 1)
        let w = max(1, Int(ceil(expanded.maxX)) - x)
        let h = max(1, Int(ceil(expanded.maxY)) - y)
        var gray = [UInt8](repeating: 0, count: w * h)
        page.pixels.withUnsafeBufferPointer { pixels in
            for row in 0..<h {
                let sourceRow = min(y + row, page.height - 1)
                for column in 0..<w {
                    let sourceColumn = min(x + column, page.width - 1)
                    let offset = (sourceRow * page.width + sourceColumn) * 3
                    let r = Int(pixels[offset])
                    let g = Int(pixels[offset + 1])
                    let b = Int(pixels[offset + 2])
                    gray[row * w + column] = UInt8((19595 * r + 38470 * g + 7471 * b + 32768) >> 16)
                }
            }
        }
        let resized = pilBilinearGray(gray, width: w, height: h, size: inputSize)
        let plane = inputSize * inputSize
        var chw = [Float](repeating: 0, count: 3 * plane)
        for index in 0..<plane {
            let value = Float((Double(resized[index]) / 255.0 - 0.5) / 0.5)
            chw[index] = value
            chw[plane + index] = value
            chw[2 * plane + index] = value
        }
        return chw
    }

    private static let resampleBits = 22
    private static let resampleScale = 1 << resampleBits

    private static func taps(sourceSize: Int, size: Int) -> [(start: Int, weights: [Int])] {
        let scale = Double(sourceSize) / Double(size)
        let support = max(1.0, scale)
        return (0..<size).map { destination in
            let center = (Double(destination) + 0.5) * scale
            let start = max(0, Int(center - support + 0.5))
            let end = min(sourceSize, Int(center + support + 0.5))
            var weights: [Double] = []
            if end > start {
                for source in start..<end {
                    weights.append(max(0, 1 - abs((Double(source) - center + 0.5) / support)))
                }
            }
            let sum = weights.reduce(0, +)
            return (start, weights.map { Int(($0 / sum * Double(resampleScale)).rounded()) })
        }
    }

    /// PIL Resample.c BILINEAR (8 bpc, 22-bit fixed point, horizontal pass
    /// then vertical pass).
    static func pilBilinearGray(_ gray: [UInt8], width: Int, height: Int, size: Int) -> [UInt8] {
        let xTaps = taps(sourceSize: width, size: size)
        let yTaps = taps(sourceSize: height, size: size)
        var horizontal = [UInt8](repeating: 0, count: size * height)
        let half = resampleScale / 2
        for y in 0..<height {
            for x in 0..<size {
                let tap = xTaps[x]
                var sum = half
                for (index, weight) in tap.weights.enumerated() {
                    sum += Int(gray[y * width + tap.start + index]) * weight
                }
                horizontal[y * size + x] = UInt8(min(255, max(0, sum >> resampleBits)))
            }
        }
        var output = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            let tap = yTaps[y]
            for x in 0..<size {
                var sum = half
                for (index, weight) in tap.weights.enumerated() {
                    sum += Int(horizontal[(tap.start + index) * size + x]) * weight
                }
                output[y * size + x] = UInt8(min(255, max(0, sum >> resampleBits)))
            }
        }
        return output
    }
}
