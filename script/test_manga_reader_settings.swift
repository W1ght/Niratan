// test-sources: Models/Manga.swift Features/Manga/MangaPageProcessing.swift Features/Manga/MangaReaderSettings.swift
import AppKit
import Foundation

@main
private enum MangaReaderSettingsTests {
    @MainActor
    static func main() async throws {
        testTapZones()
        testSpreads()
        testDecodingAndNormalization()
        testLegacyMigration()
        try await testTitleOverrides()
        testRotatedRegions()
        print("Manga reader settings tests passed")
    }

    private static func testTapZones() {
        var settings = MangaReaderSettings()
        settings.direction = .rightToLeft
        require(
            settings.tapZoneAction(at: CGPoint(x: 0.1, y: 0.5)) == .next
                && settings.tapZoneAction(at: CGPoint(x: 0.9, y: 0.5)) == .previous
                && settings.tapZoneAction(at: CGPoint(x: 0.5, y: 0.5)) == .menu,
            "right-to-left left/right zones must follow the reading direction like the arrow keys"
        )
        settings.direction = .leftToRight
        require(
            settings.tapZoneAction(at: CGPoint(x: 0.1, y: 0.5)) == .previous
                && settings.tapZoneAction(at: CGPoint(x: 0.9, y: 0.5)) == .next,
            "left-to-right zones must mirror"
        )
        settings.invertsTapZonesHorizontally = true
        require(
            settings.tapZoneAction(at: CGPoint(x: 0.1, y: 0.5)) == .next,
            "inverting horizontally must swap the side zones"
        )
        settings.invertsTapZonesHorizontally = false
        settings.tapZoneLayout = .kindle
        require(
            settings.tapZoneAction(at: CGPoint(x: 0.5, y: 0.1)) == .menu
                && settings.tapZoneAction(at: CGPoint(x: 0.1, y: 0.6)) == .previous
                && settings.tapZoneAction(at: CGPoint(x: 0.7, y: 0.6)) == .next,
            "the Kindle layout must keep the top band for the interface"
        )
        settings.tapZoneLayout = .disabled
        require(
            settings.tapZoneAction(at: CGPoint(x: 0.1, y: 0.5)) == nil,
            "disabled click zones must not turn pages"
        )
    }

    private static func testSpreads() {
        let wide: Set<Int> = [3]
        let spreads = MangaSpreadResolver.spreads(
            pageCount: 7,
            isDouble: true,
            showsCoverAlone: true,
            showsWidePagesAlone: true,
            isWide: { wide.contains($0) }
        )
        require(
            spreads == [[0], [1, 2], [3], [4, 5], [6]],
            "spreads must keep the cover and wide pages alone and realign pairs after them: \(spreads)"
        )
        let noCover = MangaSpreadResolver.spreads(
            pageCount: 4,
            isDouble: true,
            showsCoverAlone: false,
            showsWidePagesAlone: false,
            isWide: { _ in true }
        )
        require(noCover == [[0, 1], [2, 3]], "pairing from the first page must remain available")
        let single = MangaSpreadResolver.spreads(
            pageCount: 3,
            isDouble: false,
            showsCoverAlone: true,
            showsWidePagesAlone: true,
            isWide: { _ in false }
        )
        require(single == [[0], [1], [2]], "single-page mode must show one page per spread")
        require(
            MangaSpreadResolver.spreadIndex(containing: 5, in: spreads) == 3,
            "a page must resolve to its spread"
        )
    }

    private static func testDecodingAndNormalization() {
        let data = Data(#"{"mode":"continuous","zoomPercentage":999,"brightness":-500,"customColorFilterHex":"oops"}"#.utf8)
        guard let settings = try? JSONDecoder().decode(MangaReaderSettings.self, from: data) else {
            require(false, "partial settings JSON must decode")
            return
        }
        require(
            settings.mode == .continuous
                && settings.direction == .rightToLeft
                && settings.spreadMode == .automatic
                && settings.zoomPercentage == MangaReaderSettings.maximumZoomPercentage
                && settings.brightness == -100
                && settings.customColorFilterHex == "#F4ECD8"
                && settings.ocrTrigger == .automatic
                && settings.ocrEngine == .automatic,
            "missing fields must take defaults and stored values must be clamped"
        )
        var eink = MangaReaderSettings()
        eink.einkMode = true
        require(
            eink.effectivePageAnimation == .none
                && eink.effectiveGrayscale
                && eink.backgroundColor(pageLuminance: 0) == .white,
            "E-ink mode must disable animation, force grayscale and use a white background"
        )
        var automatic = MangaReaderSettings()
        automatic.usesAutomaticBackground = true
        require(
            automatic.backgroundColor(pageLuminance: 0.1) == .black
                && automatic.backgroundColor(pageLuminance: 0.9) == .white,
            "the automatic background must follow the page's corner luminance"
        )
    }

    private static func testLegacyMigration() {
        let suiteName = "moe.shishamo.hoshi.tests.manga-reader-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("doublePage", forKey: MangaReaderPreferences.layoutKey)
        defaults.set("leftToRight", forKey: MangaReaderPreferences.directionKey)
        defaults.set(150, forKey: MangaReaderPreferences.zoomLevelKey)
        defaults.set(true, forKey: MangaPageProcessingPreferences.splitsWidePagesKey)
        defaults.set(true, forKey: MangaReaderPreferences.ocrEnabledKey)
        let migrated = MangaReaderSettingsStore.migratedSettings(from: defaults)
        require(
            migrated.mode == .paged
                && migrated.spreadMode == .double
                && !migrated.showsCoverAlone
                && migrated.direction == .leftToRight
                && migrated.zoomPercentage == 150
                && migrated.splitsWidePages
                && migrated.ocrEngine == .googleLens,
            "upgrading must keep the previous layout, pairing, direction, zoom, processing and OCR engine"
        )
        let fresh = MangaReaderSettingsStore.migratedSettings(
            from: UserDefaults(suiteName: suiteName + "-empty")!
        )
        require(
            fresh == MangaReaderSettings(),
            "a new install must start from Fushi's defaults"
        )
    }

    @MainActor
    private static func testTitleOverrides() async throws {
        let suiteName = "moe.shishamo.hoshi.tests.manga-reader-overrides-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("niratan-manga-overrides-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("overrides.json")

        let store = MangaReaderSettingsStore(defaults: defaults, overridesURL: url)
        var title = store.effectiveSettings(for: "book")
        title.direction = .leftToRight
        store.update("direction", from: title, documentID: "book")
        var global = store.global
        global.background = .white
        global.direction = .rightToLeft
        store.updateGlobal(global)
        await store.flush()

        let reopened = MangaReaderSettingsStore(defaults: defaults, overridesURL: url)
        let book = reopened.effectiveSettings(for: "book")
        let other = reopened.effectiveSettings(for: "other")
        require(
            book.direction == .leftToRight
                && book.background == .white
                && other.direction == .rightToLeft
                && reopened.overriddenKeys(for: "book") == ["direction"],
            "a title override must only replace its own field and persist"
        )
        reopened.clearOverride("direction", documentID: "book")
        require(
            reopened.effectiveSettings(for: "book").direction == .rightToLeft
                && reopened.overriddenKeys(for: "book").isEmpty,
            "clearing an override must return the title to the global value"
        )
    }

    private static func testRotatedRegions() {
        let region = MangaOCRTextRegion(
            id: "r",
            pageIndex: 0,
            blockID: "b",
            lineID: "l",
            sentence: "横",
            utf16Offset: 0,
            isVertical: false,
            normalizedBounds: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.1)
        )
        let page = MangaPresentationPage(
            index: 0,
            sourcePageIndex: 0,
            sourcePath: "wide.jpg",
            transform: MangaPageTransform(
                sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                rotatesClockwise: true
            )
        )
        let rotated = MangaPageProcessor.regions([region], for: page)
        guard let bounds = rotated.first?.normalizedBounds else {
            require(false, "rotated pages must keep their OCR regions")
            return
        }
        require(
            abs(bounds.minX - 0.6) < 0.0001
                && abs(bounds.minY - 0.7) < 0.0001
                && abs(bounds.width - 0.1) < 0.0001
                && abs(bounds.height - 0.2) < 0.0001
                && rotated.first?.isVertical == true,
            "a clockwise rotation must map OCR geometry onto the rotated page: \(bounds)"
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
