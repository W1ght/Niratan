import AppKit
import Foundation

enum ReaderGalleryContractTest {
    static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }

    static func assertContains(_ source: String, _ needle: String, _ message: String) {
        if !source.contains(needle) {
            fail("\(message)\nMissing: \(needle)")
        }
    }

    static func assertNotContains(_ source: String, _ needle: String, _ message: String) {
        if source.contains(needle) {
            fail("\(message)\nUnexpected: \(needle)")
        }
    }

    static func assertOccurrences(
        _ source: String,
        _ needle: String,
        atLeast minimumCount: Int,
        _ message: String
    ) {
        let count = source.components(separatedBy: needle).count - 1
        if count < minimumCount {
            fail("\(message)\nExpected at least \(minimumCount), found \(count): \(needle)")
        }
    }

    static func assertLocalized(
        _ strings: [String: Any],
        key: String,
        expected: [String: String]
    ) {
        guard let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any] else {
            fail("missing localization key: \(key)")
        }
        for (language, value) in expected {
            guard let localization = localizations[language] as? [String: Any],
                  let stringUnit = localization["stringUnit"] as? [String: Any],
                  stringUnit["value"] as? String == value else {
                fail("\(key) should localize \(language) as \(value)")
            }
        }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        let model = try source("Models/Book.swift")
        let processor = try source("Util/BookProcessor.swift")
        let bookshelf = try source("Features/Bookshelf/BookshelfViewModel.swift")
        let ttuConverter = try source("Util/TtuConverter.swift")
        let reader = try source("NativeMac/NativeReaderView.swift")
        let nativeReuseViews = try source("NativeMac/NativeReuseViews.swift")
        let gallery = try source("Features/Reader/Gallery/GalleryView.swift")
        let goTo = try source("Features/Reader/Search/ReaderGoToView.swift")
        let statistics = try source("Features/Reader/StatisticsView.swift")
        let sasayaki = try source("Features/Sasayaki/SasayakiSheet.swift")
        let project = try source("Niratan.xcodeproj/project.pbxproj")

        assertContains(model, "let images: [String]?", "BookInfo should keep a backward-compatible optional image index")
        assertContains(model, "let imagePositions: [String: Int]?", "BookInfo should cache spoiler-safe image reading positions")
        assertContains(processor, "static func imagePaths(document: EPUBDocument)", "legacy books should support image-only backfill")
        assertContains(processor, "where seenImages.insert(entry.path).inserted", "gallery paths should deduplicate across spine chapters")
        assertContains(processor, "static func imageIndex(sources: [ImageIndexSource]) -> ImageIndex?", "legacy gallery backfill should accept sendable chapter sources")
        assertContains(processor, "guard !Task.isCancelled else { return nil }", "gallery indexing should stop after Reader cancellation")
        guard let importProcessStart = processor.range(
            of: "static func process(document: EPUBDocument) -> BookInfo"
        ), let backgroundIndexStart = processor.range(
            of: "static func imagePaths(document: EPUBDocument)",
            range: importProcessStart.upperBound..<processor.endIndex
        ) else {
            fail("BookProcessor should keep distinct import and background Gallery paths")
        }
        let importProcess = String(
            processor[importProcessStart.lowerBound..<backgroundIndexStart.lowerBound]
        )
        assertContains(
            importProcess,
            "content.filtered().count",
            "book import should preserve the existing character-statistics pass"
        )
        assertNotContains(
            importProcess,
            "appendImages(",
            "book import must not run Gallery regex and per-image filesystem validation on the MainActor"
        )
        assertContains(
            importProcess,
            "BookInfo(characterCount: total, chapterInfo: chapterInfo)",
            "book import should leave optional Gallery metadata for background backfill"
        )
        assertContains(
            bookshelf,
            "BookProcessor.process(document: document)",
            "EPUB import should use the lightweight shared character-processing path"
        )
        assertContains(
            ttuConverter,
            "BookProcessor.process(document: document)",
            "TTU import should use the same lightweight character-processing path"
        )

        assertContains(reader, "case gallery", "Reader should expose gallery sheet state")
        assertContains(reader, "activeSheet = .gallery", "Reader bottom-right button should open the gallery")
        assertContains(reader, "NativeReaderGlassIconButton(systemName: \"photo.on.rectangle\"", "Reader gallery should use the planned SF Symbol as a visible button")
        assertContains(reader, ".help(Text(\"Gallery\"))", "Reader gallery button should keep its label as help text")
        assertContains(reader, "Task.detached(priority: .utility)", "legacy gallery backfill must stay off the MainActor opening path")
        assertContains(
            reader,
            "if storedBookInfo.images == nil || storedBookInfo.imagePositions == nil",
            "new and legacy imports should schedule Gallery backfill when optional metadata is absent"
        )
        assertContains(
            reader,
            "BookProcessor.imageIndex(sources: sources)",
            "Reader Gallery backfill should execute the isolated image-index operation"
        )
        assertContains(reader, "withTaskCancellationHandler", "Reader cancellation should propagate to gallery indexing")
        assertContains(reader, "galleryIndexTask?.cancel()", "closing Reader should cancel gallery indexing")
        assertContains(reader, "private var galleryImageURLCache: [String: URL]", "gallery should cache validated image URLs in memory")
        assertContains(reader, "guard let url = galleryImageURLCache[path]", "gallery view refreshes should avoid repeated filesystem validation")
        assertContains(reader, "galleryURLCacheTask?.cancel()", "closing Reader should cancel URL cache validation")
        assertOccurrences(
            reader,
            "startGalleryImageURLCacheRefresh(",
            atLeast: 3,
            "validated gallery URLs should refresh after both book loading and legacy index updates"
        )
        assertNotContains(reader, "ReaderImageGalleryIndex.resolvedStoredImageURL(", "gallery computed properties must not repeat filesystem validation")
        assertContains(reader, "characterCount: latestBookInfo.characterCount", "legacy gallery backfill must preserve the latest character count")
        assertContains(reader, "chapterInfo: latestBookInfo.chapterInfo", "legacy gallery backfill must preserve the latest chapter mapping")
        assertContains(reader, ".ignoresSafeArea()\n                .transition(.opacity)\n                .zIndex(200)", "gallery should fill the whole Reader window above the bars")
        assertContains(reader, "let position = bookInfo.imagePositions?[path]", "gallery should read each image's character position")
        assertContains(reader, "let isRead = position.map { $0 <= currentCharacter } ?? true", "gallery read state should follow character progress")
        assertNotContains(reader, "onSelect: { url in", "gallery selection should no longer dismiss the gallery sheet")
        assertOccurrences(
            reader,
            "guard activeSheet == nil, model.imageURL == nil else { return false }",
            atLeast: 2,
            "Reader previous/next page shortcuts must remain disabled while the gallery sheet is active"
        )

        assertContains(gallery, "LazyVGrid", "macOS gallery should use a desktop image grid")
        assertContains(gallery, "let isLoading: Bool", "gallery should expose background indexing state")
        assertContains(gallery, "if isLoading", "gallery should show progress while a legacy index is built")
        assertContains(gallery, ".adaptive(minimum: 250, maximum: 380)", "gallery should add columns as the sheet grows wider")
        assertNotContains(gallery, "count: 4", "gallery should not remain fixed at four columns")
        assertContains(gallery, "if selectedImageIndex != nil", "image preview should cover the retained gallery without destroying its state")
        assertContains(gallery, "NativeFullscreenImageView(", "gallery preview should reuse the existing full-screen image renderer")
        assertContains(gallery, ".keyboardShortcut(key, modifiers: [])", "gallery navigation buttons should accept unmodified arrow keys")
        assertContains(gallery, "key: .leftArrow", "gallery preview should bind Left Arrow to the previous image")
        assertContains(gallery, "key: .rightArrow", "gallery preview should bind Right Arrow to the next image")
        assertContains(gallery, ".onExitCommand(perform: dismiss)", "Escape should return from image preview to the retained gallery")
        assertContains(gallery, "CoverImage(url: item.url, maxPixelSize: 1600)", "gallery should decode bounded thumbnails asynchronously")
        assertContains(gallery, ".blur(radius: isBlurred ? 18 : 0)", "unread gallery thumbnails should remain blurred")
        assertNotContains(gallery, "revealedImageIDs.insert(item.id)", "opening an unread thumbnail should keep the large preview blurred")
        assertContains(gallery, "onReveal:", "the blurred large preview should offer an explicit second-step reveal")
        assertContains(gallery, "revealedImageIDs.insert(images[currentIndex].id)", "tapping the blurred large image should reveal it for the gallery session")
        assertContains(gallery, "isBlurred: !images[currentIndex].isRead", "unread images should remain blurred in preview")
        assertContains(gallery, "ContentUnavailableView(\"No Images\"", "empty books should show an explicit gallery state")
        assertContains(gallery, "NativeReaderInspectorHeader(title: \"Gallery\"", "gallery should use the shared Reader header")
        assertContains(gallery, "pinnedViews: [.sectionHeaders]", "gallery should divide images by chapter with pinned headers")
        assertContains(reader, "if activeSheet == .gallery {\n                GalleryView(", "gallery should cover the Reader window instead of opening a sheet")
        assertNotContains(gallery, "NavigationStack {", "gallery should not inherit navigation toolbar placement")
        assertNotContains(gallery, ".navigationTitle(\"Gallery\")", "gallery should render a centered modal title")
        assertContains(goTo, "NativeReaderInspectorHeader(title: \"Go to\"", "Go to should use the shared Reader side-panel header")
        assertNotContains(goTo, "NavigationStack {", "Go to should not inherit navigation toolbar placement")
        assertContains(statistics, "NativeReaderInspectorHeader(title: \"Statistics\"", "Statistics should use the shared Reader side-panel header")
        assertNotContains(statistics, "NavigationStack {", "Statistics should not inherit navigation toolbar placement")
        assertContains(sasayaki, "NativeReaderInspectorHeader(title: \"Sasayaki\"", "Sasayaki should use the shared Reader side-panel header")
        assertNotContains(sasayaki, "NavigationStack {", "Sasayaki should not inherit navigation toolbar placement")
        assertContains(reader, "NativeReaderInspectorHeader(title: \"Appearance\"", "Appearance should use the shared Reader side-panel header")
        assertContains(reader, ".environment(\\.nativeSettingsPresentation, .inspector)", "Appearance side panel should render settings as a desktop inspector")
        assertContains(nativeReuseViews, "struct NativeReaderSheetPanel<Content: View>", "Reader sheets should share one native panel shell")
        assertContains(nativeReuseViews, "ZStack {", "Reader panel title should center independently of controls")
        assertContains(nativeReuseViews, "HStack {", "Reader panel should anchor its close control")
        assertContains(nativeReuseViews, "NativeGlassCircleButton(systemName: \"xmark\"", "Reader panel should reuse the native Liquid Glass close control")
        assertContains(nativeReuseViews, ".accessibilityLabel(Text(\"Close\"))", "Reader panel close control should have a localized accessibility label")
        assertContains(nativeReuseViews, ".onExitCommand(perform: onClose)", "Escape should close a Reader panel")

        let galleryIndex = try source("Features/Reader/Gallery/ReaderImageGalleryIndex.swift")
        assertContains(galleryIndex, "ReadableCharacterCounter", "gallery offsets should use one cumulative counter")
        assertContains(galleryIndex, "private static let attributeRegex", "gallery attributes should use one cached parser regex")
        assertContains(galleryIndex, "static func resolvedStoredImageURLs", "gallery should batch-validate stored image paths off-main")
        assertNotContains(galleryIndex, "NSRegularExpression.escapedPattern", "gallery indexing must not compile attribute regexes per image")
        assertNotContains(galleryIndex, "characterOffset(in markup:", "gallery offsets must not rescan the chapter prefix for every image")

        assertContains(project, "Reader/Gallery/GalleryView.swift", "GalleryView must belong to the native target")
        assertContains(project, "Reader/Gallery/ReaderImageGalleryIndex.swift", "gallery indexing must belong to the native target")
        if NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil) == nil {
            fail("photo.on.rectangle should be available on the deployment platform")
        }

        let localizationData = try Data(contentsOf: root.appendingPathComponent("Localizable.xcstrings"))
        guard let localizationRoot = try JSONSerialization.jsonObject(with: localizationData) as? [String: Any],
              let strings = localizationRoot["strings"] as? [String: Any] else {
            fail("Localizable.xcstrings should be valid JSON")
        }
        assertLocalized(strings, key: "Gallery", expected: [
            "en": "Gallery",
            "zh-Hans": "图片库",
            "zh-Hant": "圖片庫"
        ])
        assertLocalized(strings, key: "No Images", expected: [
            "en": "No Images",
            "zh-Hans": "没有图片",
            "zh-Hant": "沒有圖片"
        ])
        assertLocalized(strings, key: "Unread Image", expected: [
            "en": "Unread Image",
            "zh-Hans": "未阅读插画",
            "zh-Hant": "未閱讀插畫"
        ])

        print("Reader gallery contract passed")
    }
}

try ReaderGalleryContractTest.main()
