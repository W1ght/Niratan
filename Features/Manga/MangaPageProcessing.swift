import AppKit
import CoreGraphics
import Foundation
import ImageIO

nonisolated struct MangaPageAnalysis: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    /// Normalized coordinates with a bottom-left origin.
    let whiteBorderContentRect: CGRect
    /// Median corner luminance (0...1), used for the automatic background.
    let backgroundLuminance: Double

    init(
        pixelWidth: Int,
        pixelHeight: Int,
        whiteBorderContentRect: CGRect,
        backgroundLuminance: Double = 1
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.whiteBorderContentRect = whiteBorderContentRect
        self.backgroundLuminance = backgroundLuminance
    }
}

nonisolated struct MangaPageTransform: Equatable, Sendable {
    /// Normalized coordinates with a bottom-left origin.
    let sourceRect: CGRect
    /// Rotates the cropped page a quarter turn clockwise ("rotate to fit").
    let rotatesClockwise: Bool

    init(sourceRect: CGRect, rotatesClockwise: Bool = false) {
        self.sourceRect = sourceRect
        self.rotatesClockwise = rotatesClockwise
    }

    static let identity = MangaPageTransform(
        sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1)
    )
}

nonisolated struct MangaPresentationPage: Equatable, Identifiable, Sendable {
    let index: Int
    let sourcePageIndex: Int
    let sourcePath: String
    let transform: MangaPageTransform

    var id: Int { index }
}

nonisolated struct MangaPageProcessingOptions: Equatable, Sendable {
    let splitsWidePages: Bool
    let readingDirection: MangaReadingDirection
    let cropsWhiteBorders: Bool
    let rotatesWidePages: Bool

    init(
        splitsWidePages: Bool,
        readingDirection: MangaReadingDirection,
        cropsWhiteBorders: Bool,
        rotatesWidePages: Bool = false
    ) {
        self.splitsWidePages = splitsWidePages
        self.readingDirection = readingDirection
        self.cropsWhiteBorders = cropsWhiteBorders
        self.rotatesWidePages = rotatesWidePages
    }

    var requiresAnalysis: Bool {
        splitsWidePages || cropsWhiteBorders || rotatesWidePages
    }
}

nonisolated enum MangaPageProcessingPreferences {
    static let splitsWidePagesKey = "mangaReaderSplitsWidePages"
    static let cropsWhiteBordersKey = "mangaReaderCropsWhiteBorders"

    static func splitsWidePages(
        in defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: splitsWidePagesKey)
    }

    static func cropsWhiteBorders(
        in defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: cropsWhiteBordersKey)
    }

    static func save(
        splitsWidePages: Bool,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(splitsWidePages, forKey: splitsWidePagesKey)
    }

    static func save(
        cropsWhiteBorders: Bool,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(cropsWhiteBorders, forKey: cropsWhiteBordersKey)
    }

}

nonisolated enum MangaPagePresentationResolver {
    static let widePageAspectRatio = 1.25
    /// Fushi rotates pages wider than 1.15x their height.
    static let rotatedPageAspectRatio = 1.15

    static func unprocessedPages(
        sourcePaths: [String]
    ) -> [MangaPresentationPage] {
        sourcePaths.enumerated().map {
            MangaPresentationPage(
                index: $0.offset,
                sourcePageIndex: $0.offset,
                sourcePath: $0.element,
                transform: .identity
            )
        }
    }

    static func pages(
        sourcePaths: [String],
        analyses: [MangaPageAnalysis],
        options: MangaPageProcessingOptions
    ) -> [MangaPresentationPage] {
        guard sourcePaths.count == analyses.count else {
            return unprocessedPages(sourcePaths: sourcePaths)
        }

        var transforms: [
            (
                sourcePageIndex: Int,
                sourcePath: String,
                transform: MangaPageTransform
            )
        ] = []
        for (sourcePageIndex, sourcePath) in sourcePaths.enumerated() {
            let analysis = analyses[sourcePageIndex]
            let contentRect = options.cropsWhiteBorders
                ? clampedUnitRect(analysis.whiteBorderContentRect)
                : CGRect(x: 0, y: 0, width: 1, height: 1)
            let contentWidth = CGFloat(analysis.pixelWidth) * contentRect.width
            let contentHeight = CGFloat(analysis.pixelHeight) * contentRect.height
            let isWide = contentHeight > 0
                && contentWidth / contentHeight >= widePageAspectRatio
            let rotates = options.rotatesWidePages
                && contentHeight > 0
                && contentWidth > contentHeight * rotatedPageAspectRatio

            if rotates {
                // Rotation shows the whole spread sideways, so it replaces
                // splitting for that page.
                transforms.append(
                    (
                        sourcePageIndex,
                        sourcePath,
                        MangaPageTransform(
                            sourceRect: contentRect,
                            rotatesClockwise: true
                        )
                    )
                )
            } else if options.splitsWidePages, isWide {
                let left = CGRect(
                    x: contentRect.minX,
                    y: contentRect.minY,
                    width: contentRect.width / 2,
                    height: contentRect.height
                )
                let right = CGRect(
                    x: contentRect.midX,
                    y: contentRect.minY,
                    width: contentRect.maxX - contentRect.midX,
                    height: contentRect.height
                )
                let startsOnRight = options.readingDirection == .rightToLeft
                let orderedRects = startsOnRight ? [right, left] : [left, right]
                transforms.append(contentsOf: orderedRects.map {
                    (
                        sourcePageIndex,
                        sourcePath,
                        MangaPageTransform(sourceRect: $0)
                    )
                })
            } else {
                transforms.append(
                    (
                        sourcePageIndex,
                        sourcePath,
                        MangaPageTransform(sourceRect: contentRect)
                    )
                )
            }
        }

        return transforms.enumerated().map {
            MangaPresentationPage(
                index: $0.offset,
                sourcePageIndex: $0.element.sourcePageIndex,
                sourcePath: $0.element.sourcePath,
                transform: $0.element.transform
            )
        }
    }

    private static func clampedUnitRect(_ rect: CGRect) -> CGRect {
        let resolved = rect.standardized.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard !resolved.isNull,
              resolved.width > 0,
              resolved.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return resolved
    }
}

nonisolated final class MangaRenderedPageImage: @unchecked Sendable {
    let image: NSImage

    init(image: NSImage) {
        self.image = image
    }
}

nonisolated enum MangaPageProcessorError: LocalizedError {
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .imageUnavailable:
            String(localized: "The manga page could not be loaded.")
        }
    }
}

nonisolated enum MangaPageProcessor {
    private static let analysisMaximumDimension = 512
    /// Fushi treats pixels whose mean channel differs from the median corner
    /// background by more than 35/255 as page content.
    private static let borderDifferenceThreshold = 35.0

    static func analyze(_ data: Data) throws -> MangaPageAnalysis {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let rawWidth = number(properties[kCGImagePropertyPixelWidth]),
              let rawHeight = number(properties[kCGImagePropertyPixelHeight]),
              rawWidth > 0,
              rawHeight > 0,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: analysisMaximumDimension,
                  ] as CFDictionary
              ) else {
            throw MangaPageProcessorError.imageUnavailable
        }

        let orientation = number(properties[kCGImagePropertyOrientation]) ?? 1
        let swapsDimensions = [5, 6, 7, 8].contains(orientation)
        let border = detectBorder(in: thumbnail)
        return MangaPageAnalysis(
            pixelWidth: swapsDimensions ? rawHeight : rawWidth,
            pixelHeight: swapsDimensions ? rawWidth : rawHeight,
            whiteBorderContentRect: border.contentRect,
            backgroundLuminance: border.backgroundLuminance
        )
    }

    /// Reads only the image header; the size already accounts for EXIF
    /// orientation.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = number(properties[kCGImagePropertyPixelWidth]),
              let height = number(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0 else {
            return nil
        }
        let orientation = number(properties[kCGImagePropertyOrientation]) ?? 1
        return [5, 6, 7, 8].contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// Median corner luminance (0...1) from a tiny thumbnail, for the
    /// automatic page background.
    static func backgroundLuminance(of data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 32,
                  ] as CFDictionary
              ) else {
            return nil
        }
        return detectBorder(in: thumbnail).backgroundLuminance
    }

    static func renderedImage(
        from data: Data,
        transform: MangaPageTransform
    ) throws -> MangaRenderedPageImage {
        if transform == .identity, let image = NSImage(data: data) {
            return MangaRenderedPageImage(image: image)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let rawWidth = number(properties[kCGImagePropertyPixelWidth]),
              let rawHeight = number(properties[kCGImagePropertyPixelHeight]) else {
            throw MangaPageProcessorError.imageUnavailable
        }
        let maximumDimension = max(rawWidth, rawHeight)
        guard maximumDimension > 0,
              let orientedImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                  ] as CFDictionary
              ),
              let croppedImage = crop(
                  orientedImage,
                  to: transform.sourceRect
              ) else {
            throw MangaPageProcessorError.imageUnavailable
        }
        let finalImage = transform.rotatesClockwise
            ? rotateClockwise(croppedImage) ?? croppedImage
            : croppedImage

        return MangaRenderedPageImage(
            image: NSImage(
                cgImage: finalImage,
                size: NSSize(
                    width: finalImage.width,
                    height: finalImage.height
                )
            )
        )
    }

    static func regions(
        _ regions: [MangaOCRTextRegion],
        for page: MangaPresentationPage
    ) -> [MangaOCRTextRegion] {
        let sourceRect = page.transform.sourceRect
        guard sourceRect.width > 0, sourceRect.height > 0 else { return [] }

        return regions.compactMap { region in
            let bounds = region.normalizedBounds
            guard sourceRect.contains(
                CGPoint(x: bounds.midX, y: bounds.midY)
            ) else {
                return nil
            }
            let clipped = bounds.intersection(sourceRect)
            guard !clipped.isNull,
                  clipped.width > 0,
                  clipped.height > 0 else {
                return nil
            }
            var local = CGRect(
                x: (clipped.minX - sourceRect.minX) / sourceRect.width,
                y: (clipped.minY - sourceRect.minY) / sourceRect.height,
                width: clipped.width / sourceRect.width,
                height: clipped.height / sourceRect.height
            )
            var isVertical = region.isVertical
            if page.transform.rotatesClockwise {
                // A clockwise quarter turn maps the bottom-left normalized
                // point (x, y) to (y, 1 - x).
                local = CGRect(
                    x: local.minY,
                    y: 1 - local.maxX,
                    width: local.height,
                    height: local.width
                )
                isVertical.toggle()
            }
            let suffix = "-presentation-\(page.index)"
            return MangaOCRTextRegion(
                id: region.id + suffix,
                pageIndex: region.pageIndex,
                blockID: region.blockID + suffix,
                lineID: region.lineID + suffix,
                sentence: region.sentence,
                utf16Offset: region.utf16Offset,
                isVertical: isVertical,
                normalizedBounds: local
            )
        }
    }

    private static func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func crop(
        _ image: CGImage,
        to normalizedRect: CGRect
    ) -> CGImage? {
        let rect = normalizedRect.standardized.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let minX = floor(rect.minX * width)
        let maxX = ceil(rect.maxX * width)
        let minYFromTop = floor((1 - rect.maxY) * height)
        let maxYFromTop = ceil((1 - rect.minY) * height)
        let pixelRect = CGRect(
            x: minX,
            y: minYFromTop,
            width: maxX - minX,
            height: maxYFromTop - minYFromTop
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }

    private static func rotateClockwise(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: height,
            height: width,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        // CoreGraphics uses a bottom-left origin: rotating the drawing by
        // -90 degrees around the new canvas turns the page clockwise.
        context.translateBy(x: 0, y: CGFloat(width))
        context.rotate(by: -.pi / 2)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage()
    }

    /// Port of Fushi's `_inspectSource`: the background is the median of the
    /// four corner luminances, and the content box is every pixel that differs
    /// from it by more than 35/255, with a one-pixel margin. Uniform pages keep
    /// their full size.
    private static func detectBorder(
        in image: CGImage
    ) -> (contentRect: CGRect, backgroundLuminance: Double) {
        let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else {
            return (fullRect, 1)
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return (fullRect, 1)
        }
        // Transparent areas read as white paper.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        func mean(_ offset: Int) -> Double {
            (Double(pixels[offset]) + Double(pixels[offset + 1])
                + Double(pixels[offset + 2])) / 3
        }
        // The context rows are stored top-down.
        let corners = [
            0,
            (width - 1) * 4,
            (height - 1) * width * 4,
            (width * height - 1) * 4,
        ].map(mean).sorted()
        let background = (corners[1] + corners[2]) / 2

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width
            where abs(mean(row + x * 4) - background) > borderDifferenceThreshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        let luminance = background / 255
        guard maxX > minX, maxY > minY else {
            return (fullRect, luminance)
        }
        minX = max(0, minX - 1)
        minY = max(0, minY - 1)
        maxX = min(width, maxX + 2)
        maxY = min(height, maxY + 2)
        let contentRect = CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(height - maxY) / CGFloat(height),
            width: CGFloat(maxX - minX) / CGFloat(width),
            height: CGFloat(maxY - minY) / CGFloat(height)
        )
        return (contentRect, luminance)
    }
}

/// Groups presentation pages into the spreads shown side by side, following
/// Fushi's `manga_spread_model.dart`: an optional lone cover, wide pages shown
/// alone, and pairing that realigns after every lone page.
nonisolated enum MangaSpreadResolver {
    static func spreads(
        pageCount: Int,
        isDouble: Bool,
        showsCoverAlone: Bool,
        showsWidePagesAlone: Bool,
        isWide: (Int) -> Bool
    ) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        guard isDouble else {
            return (0..<pageCount).map { [$0] }
        }
        var spreads: [[Int]] = []
        var index = 0
        while index < pageCount {
            if index == 0, showsCoverAlone {
                spreads.append([0])
                index += 1
                continue
            }
            if showsWidePagesAlone, isWide(index) {
                spreads.append([index])
                index += 1
                continue
            }
            let next = index + 1
            if next < pageCount, !(showsWidePagesAlone && isWide(next)) {
                spreads.append([index, next])
                index += 2
            } else {
                spreads.append([index])
                index += 1
            }
        }
        return spreads
    }

    static func spreadIndex(containing pageIndex: Int, in spreads: [[Int]]) -> Int? {
        spreads.firstIndex { $0.contains(pageIndex) }
    }
}
