import Foundation
import OnnxRuntimeBindings

/// A decoded output tensor.
nonisolated struct MangaOCRTensor: @unchecked Sendable {
    let shape: [Int]
    let elementType: ORTTensorElementDataType
    let data: Data

    var floats: [Float] {
        switch elementType {
        case .float:
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case .int64:
            return data.withUnsafeBytes { $0.bindMemory(to: Int64.self).map { Float($0) } }
        case .int32:
            return data.withUnsafeBytes { $0.bindMemory(to: Int32.self).map { Float($0) } }
        default:
            return []
        }
    }
}

/// Thin wrapper over one ONNX Runtime session. Not thread-safe: always used
/// from inside a single owning actor.
nonisolated final class MangaOCRSession: @unchecked Sendable {
    enum Provider: Sendable {
        case cpu
        case coreML
    }

    nonisolated(unsafe) private static let environment: ORTEnv? = try? ORTEnv(loggingLevel: .warning)

    private let session: ORTSession
    let inputNames: [String]
    let outputNames: [String]

    init(modelURL: URL, provider: Provider = .cpu) throws {
        guard let environment = Self.environment else {
            throw MangaOCREngineError.inferenceFailed("ORT environment unavailable")
        }
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        if provider == .coreML {
            let coreML = ORTCoreMLExecutionProviderOptions()
            coreML.createMLProgram = true
            try options.appendCoreMLExecutionProvider(with: coreML)
        }
        do {
            session = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: options)
        } catch {
            throw MangaOCREngineError.modelInvalid(modelURL.lastPathComponent)
        }
        inputNames = (try? session.inputNames()) ?? []
        outputNames = (try? session.outputNames()) ?? []
    }

    /// Resolve an input name the way Fushi's `resolveInputNames` does: a
    /// single-input model uses its only input; otherwise accept `alternates`.
    func resolvedInputName(_ preferred: String, alternates: [String] = []) -> String {
        if inputNames.count == 1 { return inputNames[0] }
        if inputNames.contains(preferred) { return preferred }
        return alternates.first(where: inputNames.contains) ?? preferred
    }

    func run(_ inputs: [String: ORTValue]) throws -> [String: MangaOCRTensor] {
        let outputs: [String: ORTValue]
        do {
            outputs = try session.run(
                withInputs: inputs,
                outputNames: Set(outputNames),
                runOptions: nil
            )
        } catch {
            throw MangaOCREngineError.inferenceFailed(error.localizedDescription)
        }
        var result: [String: MangaOCRTensor] = [:]
        for (name, value) in outputs {
            guard let info = try? value.tensorTypeAndShapeInfo(),
                  let data = try? value.tensorData() else { continue }
            result[name] = MangaOCRTensor(
                shape: info.shape.map(\.intValue),
                elementType: info.elementType,
                data: data as Data
            )
        }
        return result
    }

    /// Run and keep the requested outputs as ORT values (no copy), e.g. to
    /// feed key-value caches back into the next step.
    func runValues(_ inputs: [String: ORTValue], outputNames names: Set<String>) throws -> [String: ORTValue] {
        do {
            return try session.run(withInputs: inputs, outputNames: names, runOptions: nil)
        } catch {
            throw MangaOCREngineError.inferenceFailed(error.localizedDescription)
        }
    }

    static func floatValue(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.stride) }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    static func floatValue(data: Data, shape: [Int]) throws -> ORTValue {
        try ORTValue(tensorData: NSMutableData(data: data), elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    static func int64Value(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Int64>.stride) }
        return try ORTValue(tensorData: data, elementType: .int64, shape: shape.map { NSNumber(value: $0) })
    }
}
