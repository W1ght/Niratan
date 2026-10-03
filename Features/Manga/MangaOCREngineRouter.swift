import CoreGraphics
import Foundation
import ImageIO

/// The concrete OCR engine a reader session uses after resolving the
/// "Automatic" preference.
nonisolated enum MangaResolvedOCREngine: Equatable, Sendable {
    case googleLens
    case appleVision
    case local(MangaLocalOCRModel)

    /// Directory name of this engine's page cache.
    var cacheEngineID: String {
        switch self {
        case .googleLens: MangaOCRCacheKey.googleLensEngineID
        case .appleVision: "apple-vision"
        case .local(.mangaCTC): "local-manga-ctc"
        case .local(.mangaOCR): "local-manga-ocr"
        }
    }

    var uploadsPages: Bool {
        self == .googleLens
    }

    var titleKey: String {
        switch self {
        case .googleLens: MangaOCREngineChoice.googleLens.titleKey
        case .appleVision: MangaOCREngineChoice.appleVision.titleKey
        case .local(.mangaCTC): MangaOCREngineChoice.mangaCTC.titleKey
        case .local(.mangaOCR): MangaOCREngineChoice.mangaOCR.titleKey
        }
    }
}

nonisolated struct MangaOCREngineSelection: Equatable, Sendable {
    let engine: MangaResolvedOCREngine
    /// Cache identity: engine revision plus model fingerprint.
    let signature: String
    /// False when the chosen local engine's models are not downloaded.
    let isAvailable: Bool
}

/// Resolves the OCR preference and runs the on-device engines. Google Lens
/// stays in `MangaOCRService`; nothing here uploads page images.
nonisolated enum MangaOCREngineRouter {
    static let googleLensConsentKey = "mangaGoogleOCRDisclosureAccepted"

    private static let englishVisionEngine: MangaVisionOCREngine = {
        var configuration = MangaVisionOCRConfiguration()
        configuration.languages = ["en-US"]
        return MangaVisionOCREngine(configuration: configuration)
    }()

    static func hasGoogleLensConsent(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: googleLensConsentKey)
    }

    static func resolve(
        _ choice: MangaOCREngineChoice,
        store: MangaOCRModelStore = .shared
    ) async -> MangaOCREngineSelection {
        switch choice {
        case .googleLens:
            return MangaOCREngineSelection(
                engine: .googleLens,
                signature: MangaOCRCacheKey.googleLensEngineSignature,
                isAvailable: true
            )
        case .appleVision:
            return await visionSelection(store: store)
        case .mangaCTC:
            return await localSelection(.mangaCTC, store: store)
        case .mangaOCR:
            return await localSelection(.mangaOCR, store: store)
        case .automatic:
            if await store.isReady(.mangaCTC) {
                return await localSelection(.mangaCTC, store: store)
            }
            if await store.isReady(.mangaOCR) {
                return await localSelection(.mangaOCR, store: store)
            }
            return await visionSelection(store: store)
        }
    }

    private static func localSelection(
        _ model: MangaLocalOCRModel,
        store: MangaOCRModelStore
    ) async -> MangaOCREngineSelection {
        MangaOCREngineSelection(
            engine: .local(model),
            signature: MangaLocalOCREngine.shared.engineSignature(for: model),
            isAvailable: await store.isReady(model.modelSet)
        )
    }

    /// Vision results differ when the text detector guides its crops, so the
    /// detector state is part of the cache signature.
    private static func visionSelection(
        store: MangaOCRModelStore
    ) async -> MangaOCREngineSelection {
        let usesDetector = await store.isReady(.textDetector)
        let detectorSuffix = usesDetector
            ? "detector-\(store.fingerprint(for: .textDetector))"
            : "page"
        return MangaOCREngineSelection(
            engine: .appleVision,
            signature: "\(MangaVisionOCREngine.shared.engineSignature)-\(detectorSuffix)",
            isAvailable: true
        )
    }

    /// Recognizes one page with an on-device engine. The image is decoded
    /// with its EXIF orientation applied, matching what the reader shows.
    static func recognize(
        _ data: Data,
        engine: MangaResolvedOCREngine,
        language: MangaOCRLanguage,
        rightToLeft: Bool
    ) async throws -> MangaOCRPageResult {
        let image = try await Task.detached(priority: .userInitiated) {
            try orientedImage(from: data)
        }.value
        try Task.checkCancellation()
        switch engine {
        case .googleLens:
            preconditionFailure("Google Lens recognition belongs to MangaOCRService")
        case .appleVision:
            let vision = language == .english ? englishVisionEngine : MangaVisionOCREngine.shared
            return try await vision.recognize(image, rightToLeft: rightToLeft)
        case .local(let model):
            return try await MangaLocalOCREngine.shared.recognize(
                image,
                model: model,
                rightToLeft: rightToLeft
            )
        }
    }

    static func orientedImage(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                  ] as CFDictionary
              ) else {
            throw MangaOCREngineError.imageUnavailable
        }
        return image
    }
}
