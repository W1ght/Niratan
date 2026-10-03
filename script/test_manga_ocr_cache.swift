// test-sources: Models/Manga.swift Features/Manga/MangaOCRService.swift Features/Manga/OCR/MangaOCRTypes.swift Features/Manga/OCR/MangaOCRRegionBuilder.swift
import Foundation

@main
private enum MangaOCRCacheTests {
    static func main() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "niratan-manga-ocr-cache-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let pagePaths = ["001.jpg", "002.jpg"]
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstKey = MangaOCRCacheKey(
            itemID: "book-a",
            pageIndex: 0,
            pagePath: pagePaths[0],
            modifiedAt: modifiedAt,
            language: .japanese
        )
        let region = MangaOCRTextRegion(
            id: "page-0-line-0",
            pageIndex: 0,
            blockID: "block-0",
            lineID: "line-0",
            sentence: "日本語",
            utf16Offset: 0,
            isVertical: true,
            normalizedBounds: CGRect(x: 0.2, y: 0.1, width: 0.1, height: 0.3)
        )

        let writer = MangaOCRService(cacheDirectory: cacheRoot)
        await writer.storeCachedRegions(
            [region],
            for: firstKey,
            pagePaths: pagePaths
        )
        let emptyKey = MangaOCRCacheKey(
            itemID: "book-a",
            pageIndex: 1,
            pagePath: pagePaths[1],
            modifiedAt: modifiedAt,
            language: .japanese
        )
        await writer.storeCachedRegions(
            [],
            for: emptyKey,
            pagePaths: pagePaths
        )
        let englishKey = MangaOCRCacheKey(
            itemID: "book-a",
            pageIndex: 0,
            pagePath: pagePaths[0],
            modifiedAt: modifiedAt,
            language: .english
        )
        let englishRegion = MangaOCRTextRegion(
            id: "page-0-line-0-en",
            pageIndex: 0,
            blockID: "block-0-en",
            lineID: "line-0-en",
            sentence: "Hello world",
            utf16Offset: 0,
            isVertical: false,
            normalizedBounds: CGRect(
                x: 0.2,
                y: 0.1,
                width: 0.3,
                height: 0.1
            )
        )
        await writer.storeCachedRegions(
            [englishRegion],
            for: englishKey,
            pagePaths: pagePaths
        )

        let reopened = MangaOCRService(cacheDirectory: cacheRoot)
        let reopenedRegions = await reopened.cachedRegions(
            for: firstKey,
            pagePaths: pagePaths
        )
        require(
            reopenedRegions == [region],
            "recognized regions should survive a service restart"
        )
        let reopenedEmptyRegions = await reopened.cachedRegions(
            for: emptyKey,
            pagePaths: pagePaths
        )
        require(
            reopenedEmptyRegions == [],
            "an OCR page with no text should still be cached"
        )
        let reopenedEnglishRegions = await reopened.cachedRegions(
            for: englishKey,
            pagePaths: pagePaths
        )
        require(
            reopenedEnglishRegions == [englishRegion],
            "English and Japanese OCR caches must remain isolated and reusable"
        )

        let changedSourceKey = MangaOCRCacheKey(
            itemID: "book-a",
            pageIndex: 0,
            pagePath: pagePaths[0],
            modifiedAt: modifiedAt.addingTimeInterval(1),
            language: .japanese
        )
        let changedSourceRegions = await reopened.cachedRegions(
            for: changedSourceKey,
            pagePaths: pagePaths
        )
        require(
            changedSourceRegions == nil,
            "changing the source modification date should invalidate cached OCR"
        )

        await reopened.storeCachedRegions(
            [region],
            for: changedSourceKey,
            pagePaths: pagePaths
        )
        let changedPagePaths = ["cover.jpg", "002.jpg"]
        let reorderedKey = MangaOCRCacheKey(
            itemID: "book-a",
            pageIndex: 0,
            pagePath: changedPagePaths[0],
            modifiedAt: changedSourceKey.modifiedAt,
            language: .japanese
        )
        let reorderedRegions = await reopened.cachedRegions(
            for: reorderedKey,
            pagePaths: changedPagePaths
        )
        require(
            reorderedRegions == nil,
            "changing the stable page path list should invalidate cached OCR"
        )

        try await testEngineIsolation()
        print("Manga OCR cache tests passed")
    }

    /// Each engine keeps its own directory; re-running one engine never drops
    /// another engine's pages, and a new engine signature invalidates only
    /// that engine.
    private static func testEngineIsolation() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "niratan-manga-ocr-engines-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let pagePaths = ["001.jpg"]
        let lensKey = MangaOCRCacheKey(
            itemID: "book-b",
            pageIndex: 0,
            pagePath: pagePaths[0],
            modifiedAt: nil,
            language: .japanese
        )
        var visionKey = lensKey
        visionKey.engineID = "apple-vision"
        visionKey.engineSignature = "apple-vision-v1-page"
        let lensRegion = MangaOCRTextRegion(
            id: "lens",
            pageIndex: 0,
            blockID: "lens-block",
            lineID: "lens-line",
            sentence: "レンズ",
            utf16Offset: 0,
            isVertical: true,
            normalizedBounds: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.3)
        )
        let visionRegion = MangaOCRTextRegion(
            id: "vision",
            pageIndex: 0,
            blockID: "vision-block",
            lineID: "vision-line",
            sentence: "ビジョン",
            utf16Offset: 0,
            isVertical: true,
            normalizedBounds: CGRect(x: 0.5, y: 0.1, width: 0.1, height: 0.3)
        )
        let service = MangaOCRService(cacheDirectory: cacheRoot)
        await service.storeCachedRegions([lensRegion], for: lensKey, pagePaths: pagePaths)
        await service.storeCachedRegions([visionRegion], for: visionKey, pagePaths: pagePaths)

        let reopened = MangaOCRService(cacheDirectory: cacheRoot)
        let reopenedLens = await reopened.cachedRegions(for: lensKey, pagePaths: pagePaths)
        let reopenedVision = await reopened.cachedRegions(for: visionKey, pagePaths: pagePaths)
        require(
            reopenedLens == [lensRegion] && reopenedVision == [visionRegion],
            "Google Lens and Apple Vision pages must be cached side by side"
        )
        let itemDirectory = try FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil
        ).first
        let engineDirectories = try itemDirectory.map {
            try FileManager.default.contentsOfDirectory(atPath: $0.path).sorted()
        } ?? []
        require(
            engineDirectories == ["apple-vision-ja", "ja"],
            "Google Lens must keep its original per-language directory beside other engines"
        )

        var newModelKey = visionKey
        newModelKey.engineSignature = "apple-vision-v1-detector-abc"
        let newModelRegions = await reopened.cachedRegions(for: newModelKey, pagePaths: pagePaths)
        require(
            newModelRegions == nil,
            "a new engine signature must invalidate that engine's pages"
        )
        let keptLens = await reopened.cachedRegions(for: lensKey, pagePaths: pagePaths)
        require(
            keptLens == [lensRegion],
            "invalidating one engine must keep the other engine's pages"
        )

        await reopened.storeCachedRegions([visionRegion], for: visionKey, pagePaths: pagePaths)
        await reopened.clear(itemID: "book-b", engineID: "apple-vision", language: .japanese)
        let afterClear = MangaOCRService(cacheDirectory: cacheRoot)
        let clearedVision = await afterClear.cachedRegions(for: visionKey, pagePaths: pagePaths)
        let survivingLens = await afterClear.cachedRegions(for: lensKey, pagePaths: pagePaths)
        require(
            clearedVision == nil && survivingLens == [lensRegion],
            "re-running one engine must clear only that engine's pages"
        )
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
