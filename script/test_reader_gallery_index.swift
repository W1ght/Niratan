// test-sources: Models/Book.swift Util/ReaderCharacterNormalizer.swift Features/Reader/Gallery/ReaderImageGalleryIndex.swift
import Foundation

@main
enum ReaderGalleryIndexTest {
    static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }

    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual != expected {
            fail("\(message)\nExpected: \(expected)\nActual: \(actual)")
        }
    }

    static func assertNil<T>(_ value: T?, _ message: String) {
        if value != nil {
            fail(message)
        }
    }

    static func assertTrue(_ value: Bool, _ message: String) {
        if !value {
            fail(message)
        }
    }

    static func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: url)
    }

    static func main() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-reader-gallery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let contentDirectory = temporaryRoot.appendingPathComponent("EPUB", isDirectory: true)
        let chapterURL = contentDirectory.appendingPathComponent("Text/chapter.xhtml")
        let imagesDirectory = contentDirectory.appendingPathComponent("Images", isDirectory: true)
        let outsideImage = temporaryRoot.appendingPathComponent("outside.png")

        try touch(chapterURL)
        try touch(imagesDirectory.appendingPathComponent("first.JPG"))
        try touch(imagesDirectory.appendingPathComponent("second image.png"))
        try touch(imagesDirectory.appendingPathComponent("third.jpeg"))
        try touch(imagesDirectory.appendingPathComponent("gaiji.png"))
        try touch(imagesDirectory.appendingPathComponent("unsupported.webp"))
        try touch(outsideImage)
        try FileManager.default.createSymbolicLink(
            at: imagesDirectory.appendingPathComponent("outside-link.png"),
            withDestinationURL: outsideImage
        )

        let markup = #"""
        <html><body>
          <IMG SRC='../Images/first.JPG'>
          <img src="../Images/second%20image.png">
          <image XLINK:HREF='../Images/third.jpeg'></image>
          <image href="../Images/first.JPG"></image>
          <img src='../Images/first.JPG'>
          <img class='ornament gaiji small' src='../Images/gaiji.png'>
          <img src='https://example.com/remote.png'>
          <img src='data:image/png;base64,AAAA'>
          <img src='../../../outside.png'>
          <img src='../Images/outside-link.png'>
          <img src='../Images/missing.png'>
          <img src='../Images/unsupported.webp'>
          <img src='/tmp/absolute.png'>
        </body></html>
        """#

        let paths = ReaderImageGalleryIndex.imagePaths(
            in: markup,
            chapterURL: chapterURL,
            contentDirectory: contentDirectory
        )
        assertEqual(
            paths,
            ["Images/first.JPG", "Images/second image.png", "Images/third.jpeg"],
            "gallery index should preserve first reading order while filtering duplicates and unsafe resources"
        )

        let positionedMarkup = #"""
        <html><body>甲乙<img src='../Images/first.JPG'>丙丁<image href='../Images/third.jpeg'></image></body></html>
        """#
        let positionedEntries = ReaderImageGalleryIndex.imageEntries(
            in: positionedMarkup,
            chapterURL: chapterURL,
            contentDirectory: contentDirectory
        )
        assertEqual(
            positionedEntries,
            [
                .init(path: "Images/first.JPG", characterOffset: 2),
                .init(path: "Images/third.jpeg", characterOffset: 4),
            ],
            "gallery positions should count readable characters before each image within the chapter"
        )

        let filteredPositionMarkup = #"""
        <html><head>HEAD123</head><body>
        甲<ruby>漢<rt>かん</rt></ruby>
        <script>hidden123</script><style>ignored456</style>
        &nbsp;&amp;&lt;&gt;乙<img src='../Images/first.JPG'>丙<img src='../Images/third.jpeg'>
        </body></html>
        """#
        let filteredPositionEntries = ReaderImageGalleryIndex.imageEntries(
            in: filteredPositionMarkup,
            chapterURL: chapterURL,
            contentDirectory: contentDirectory
        )
        assertEqual(
            filteredPositionEntries,
            [
                .init(path: "Images/first.JPG", characterOffset: 3),
                .init(path: "Images/third.jpeg", characterOffset: 4),
            ],
            "gallery positions should ignore head text, ruby annotations, scripts, styles, and decoded entities"
        )
        assertEqual(
            ReaderImageGalleryIndex.readableCharacterCount(in: filteredPositionMarkup),
            4,
            "background fallback counting should match gallery position filtering"
        )

        let encodedPositionMarkup = #"""
        <html><body>&#x7532;&#20057;&#x1F600;<img src='../Images/first.JPG'>丙</body></html>
        """#
        let encodedPositionEntries = ReaderImageGalleryIndex.imageEntries(
            in: encodedPositionMarkup,
            chapterURL: chapterURL,
            contentDirectory: contentDirectory
        )
        assertEqual(
            encodedPositionEntries,
            [.init(path: "Images/first.JPG", characterOffset: 2)],
            "numeric HTML references should count as their decoded readable characters instead of their source digits"
        )
        assertEqual(
            ReaderImageGalleryIndex.readableCharacterCount(in: encodedPositionMarkup),
            3,
            "numeric HTML references should stay aligned with Reader and Sasayaki character offsets"
        )
        assertEqual(
            ReaderCharacterNormalizer.filteredText(
                from: "<html><body>&#x7532;&#20057;&#65;&#x1F600;</body></html>"
            ),
            "甲乙A",
            "Reader character filtering should decode decimal and hexadecimal references before filtering"
        )

        let storedURL = ReaderImageGalleryIndex.resolvedStoredImageURL(
            for: "Images/second image.png",
            contentDirectory: contentDirectory
        )
        assertEqual(
            storedURL?.path(percentEncoded: false),
            imagesDirectory.appendingPathComponent("second image.png").path(percentEncoded: false),
            "stored gallery paths should resolve back into the current extracted EPUB directory"
        )
        assertNil(
            ReaderImageGalleryIndex.resolvedStoredImageURL(
                for: "../outside.png",
                contentDirectory: contentDirectory
            ),
            "stored paths must not escape the EPUB content directory"
        )

        let cachedURLs = ReaderImageGalleryIndex.resolvedStoredImageURLs(
            for: [
                "Images/first.JPG",
                "../outside.png",
                "Images/outside-link.png",
                "Images/first.JPG",
            ],
            contentDirectory: contentDirectory
        )
        assertEqual(
            Set(cachedURLs?.keys.map { $0 } ?? []),
            Set(["Images/first.JPG"]),
            "gallery URL caching should deduplicate paths while preserving escape and symlink validation"
        )

        var cacheCancellationChecks = 0
        let cancelledCache = ReaderImageGalleryIndex.resolvedStoredImageURLs(
            for: paths,
            contentDirectory: contentDirectory,
            shouldCancel: {
                cacheCancellationChecks += 1
                return cacheCancellationChecks > 1
            }
        )
        assertNil(cancelledCache, "cancelled URL cache refreshes must discard partial validation results")

        let legacyJSON = Data(#"{"characterCount":42,"chapterInfo":{}}"#.utf8)
        let legacyBookInfo = try JSONDecoder().decode(BookInfo.self, from: legacyJSON)
        assertEqual(legacyBookInfo.characterCount, 42, "legacy BookInfo character count should decode")
        assertNil(legacyBookInfo.images, "legacy BookInfo should decode a missing image index as nil")
        assertNil(legacyBookInfo.imagePositions, "legacy BookInfo should decode missing image positions as nil")

        let positions = ["Images/first.JPG": 2, "Images/third.jpeg": 4]
        let indexedBookInfo = BookInfo(
            characterCount: legacyBookInfo.characterCount,
            chapterInfo: legacyBookInfo.chapterInfo,
            images: paths,
            imagePositions: positions
        )
        let decodedBookInfo = try JSONDecoder().decode(
            BookInfo.self,
            from: JSONEncoder().encode(indexedBookInfo)
        )
        assertEqual(decodedBookInfo.characterCount, 42, "image indexing must preserve character count")
        assertTrue(decodedBookInfo.chapterInfo.isEmpty, "image indexing must preserve chapter info")
        assertEqual(decodedBookInfo.images, paths, "indexed images should round-trip through bookinfo JSON")
        assertEqual(decodedBookInfo.imagePositions, positions, "image positions should round-trip through bookinfo JSON")

        let emptyBookInfo = BookInfo(characterCount: 0, chapterInfo: [:], images: [], imagePositions: [:])
        let decodedEmptyBookInfo = try JSONDecoder().decode(
            BookInfo.self,
            from: JSONEncoder().encode(emptyBookInfo)
        )
        assertEqual(decodedEmptyBookInfo.images, [], "an indexed book with no images must remain distinct from legacy nil")
        assertEqual(decodedEmptyBookInfo.imagePositions, [:], "an empty position cache should round-trip")

        let performanceImageCount = 2_000
        var performanceMarkup = "<html><body>"
        for index in 0..<performanceImageCount {
            let fileName = "performance-\(index).png"
            _ = FileManager.default.createFile(
                atPath: imagesDirectory.appendingPathComponent(fileName).path,
                contents: Data()
            )
            performanceMarkup += "字<img src='../Images/\(fileName)'>"
        }
        performanceMarkup += "</body></html>"

        let performanceStart = Date()
        let performanceEntries = ReaderImageGalleryIndex.imageEntries(
            in: performanceMarkup,
            chapterURL: chapterURL,
            contentDirectory: contentDirectory
        )
        let performanceDuration = Date().timeIntervalSince(performanceStart)
        assertEqual(
            performanceEntries.count,
            performanceImageCount,
            "large gallery indexes should retain every unique image"
        )
        assertEqual(
            performanceEntries.last?.characterOffset,
            performanceImageCount,
            "large gallery indexes should retain cumulative character positions"
        )
        assertTrue(
            performanceDuration < 5,
            "large gallery indexing should remain linear-time (took \(performanceDuration) seconds)"
        )

        let cachePerformanceStart = Date()
        let performanceURLCache = ReaderImageGalleryIndex.resolvedStoredImageURLs(
            for: performanceEntries.map(\.path),
            contentDirectory: contentDirectory
        )
        let cachePerformanceDuration = Date().timeIntervalSince(cachePerformanceStart)
        assertEqual(
            performanceURLCache?.count,
            performanceImageCount,
            "large gallery URL caches should retain every validated image"
        )
        assertTrue(
            cachePerformanceDuration < 5,
            "large gallery URL validation should remain bounded (took \(cachePerformanceDuration) seconds)"
        )

        var cancellationChecks = 0
        let cancelledEntries = ReaderImageGalleryIndex.imageEntries(
            in: performanceMarkup,
            chapterURL: chapterURL,
            contentDirectory: contentDirectory,
            shouldCancel: {
                cancellationChecks += 1
                return cancellationChecks > 10
            }
        )
        assertTrue(
            cancelledEntries.isEmpty,
            "cancelled background indexing must discard partial gallery results"
        )

        print("Reader gallery index tests passed")
    }
}
