// test-sources: Models/Manga.swift Features/Manga/MangaPageProcessing.swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
private enum MangaPageProcessingTests {
    static func main() throws {
        try testWhiteBorderDetectionAndRendering()
        testDirectionAwareSplitPlanning()
        testOCRGeometryMapping()
        testPreferences()
        print("Manga page processing tests passed")
    }

    private static func testWhiteBorderDetectionAndRendering() throws {
        let data = try makeSpreadPNG()
        let analysis = try MangaPageProcessor.analyze(data)
        require(analysis.pixelWidth == 200, "analysis should retain the oriented width")
        require(analysis.pixelHeight == 100, "analysis should retain the oriented height")
        require(
            analysis.whiteBorderContentRect.minX > 0.03
                && analysis.whiteBorderContentRect.minX < 0.08,
            "left scan border should be detected"
        )
        require(
            analysis.whiteBorderContentRect.minY > 0.07
                && analysis.whiteBorderContentRect.minY < 0.13,
            "bottom scan border should be detected"
        )
        require(
            analysis.whiteBorderContentRect.width > 0.86
                && analysis.whiteBorderContentRect.width < 0.94,
            "horizontal scan borders should be removed without clipping content"
        )

        let pages = MangaPagePresentationResolver.pages(
            sourcePaths: ["spread.png"],
            analyses: [analysis],
            options: MangaPageProcessingOptions(
                splitsWidePages: true,
                readingDirection: .rightToLeft,
                cropsWhiteBorders: true
            )
        )
        require(pages.count == 2, "a cropped wide scan should become two display pages")
        let right = try MangaPageProcessor.renderedImage(
            from: data,
            transform: pages[0].transform
        ).image
        let left = try MangaPageProcessor.renderedImage(
            from: data,
            transform: pages[1].transform
        ).image
        require(
            right.size.width > 85 && right.size.width < 95
                && right.size.height > 75 && right.size.height < 85,
            "rendering should apply white-border crop before splitting"
        )
        require(
            dominantColor(in: right) == .blue,
            "RTL should render the right half first"
        )
        require(
            dominantColor(in: left) == .red,
            "RTL should render the left half second"
        )
    }

    private static func testDirectionAwareSplitPlanning() {
        let analysis = MangaPageAnalysis(
            pixelWidth: 2_000,
            pixelHeight: 1_000,
            whiteBorderContentRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let ltr = MangaPagePresentationResolver.pages(
            sourcePaths: ["wide.jpg"],
            analyses: [analysis],
            options: MangaPageProcessingOptions(
                splitsWidePages: true,
                readingDirection: .leftToRight,
                cropsWhiteBorders: false
            )
        )
        require(ltr.map(\.transform.sourceRect.minX) == [0, 0.5], "LTR should start on the left")

        let rtl = MangaPagePresentationResolver.pages(
            sourcePaths: ["wide.jpg"],
            analyses: [analysis],
            options: MangaPageProcessingOptions(
                splitsWidePages: true,
                readingDirection: .rightToLeft,
                cropsWhiteBorders: false
            )
        )
        require(
            rtl.map(\.transform.sourceRect.minX) == [0.5, 0],
            "RTL should start on the right"
        )

        let portrait = MangaPagePresentationResolver.pages(
            sourcePaths: ["portrait.jpg"],
            analyses: [
                MangaPageAnalysis(
                    pixelWidth: 1_000,
                    pixelHeight: 1_500,
                    whiteBorderContentRect: CGRect(x: 0, y: 0, width: 1, height: 1)
                ),
            ],
            options: MangaPageProcessingOptions(
                splitsWidePages: true,
                readingDirection: .rightToLeft,
                cropsWhiteBorders: false
            )
        )
        require(portrait.count == 1, "portrait pages must not be split")
    }

    private static func testOCRGeometryMapping() {
        let sourceRegion = MangaOCRTextRegion(
            id: "right",
            pageIndex: 4,
            blockID: "block",
            lineID: "line",
            sentence: "星",
            utf16Offset: 0,
            isVertical: true,
            normalizedBounds: CGRect(x: 0.70, y: 0.20, width: 0.10, height: 0.20)
        )
        let rightPage = MangaPresentationPage(
            index: 8,
            sourcePageIndex: 4,
            sourcePath: "spread.png",
            transform: MangaPageTransform(
                sourceRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
            )
        )
        let leftPage = MangaPresentationPage(
            index: 9,
            sourcePageIndex: 4,
            sourcePath: "spread.png",
            transform: MangaPageTransform(
                sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)
            )
        )
        let rightRegions = MangaPageProcessor.regions([sourceRegion], for: rightPage)
        require(rightRegions.count == 1, "OCR on the right half should follow that split page")
        require(
            abs(rightRegions[0].normalizedBounds.minX - 0.4) < 0.001,
            "split-page OCR x coordinates should be normalized to the selected half"
        )
        require(
            MangaPageProcessor.regions([sourceRegion], for: leftPage).isEmpty,
            "OCR must not leak onto the other split half"
        )
    }

    private static func testPreferences() {
        let suiteName = "moe.shishamo.hoshi.tests.manga-page-processing"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        require(
            !MangaPageProcessingPreferences.splitsWidePages(in: defaults),
            "existing readers should keep wide spreads until processing is enabled"
        )
        MangaPageProcessingPreferences.save(
            splitsWidePages: true,
            in: defaults
        )
        MangaPageProcessingPreferences.save(
            cropsWhiteBorders: true,
            in: defaults
        )
        require(
            MangaPageProcessingPreferences.splitsWidePages(in: defaults)
                && MangaPageProcessingPreferences.cropsWhiteBorders(in: defaults),
            "manga split and crop choices should persist"
        )
        defaults.removePersistentDomain(forName: suiteName)
    }

    private enum DominantColor {
        case red
        case blue
        case other
    }

    private static func dominantColor(in image: NSImage) -> DominantColor {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let image = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ),
        let pixel = image.cropping(
            to: CGRect(
                x: image.width / 2,
                y: image.height / 2,
                width: 1,
                height: 1
            )
        ) else {
            return .other
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return .other
        }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        if Int(bytes[0]) > Int(bytes[2]) * 2 {
            return .red
        }
        if Int(bytes[2]) > Int(bytes[0]) * 2 {
            return .blue
        }
        return .other
    }

    private static func makeSpreadPNG() throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MangaPageProcessorError.imageUnavailable
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        context.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 90, height: 80))
        context.setFillColor(CGColor(red: 0.05, green: 0.1, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 100, y: 10, width: 90, height: 80))
        guard let image = context.makeImage() else {
            throw MangaPageProcessorError.imageUnavailable
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw MangaPageProcessorError.imageUnavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MangaPageProcessorError.imageUnavailable
        }
        return output as Data
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
