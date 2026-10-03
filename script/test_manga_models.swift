// test-sources: Models/Manga.swift
import Foundation

@main
private enum MangaModelTests {
    static func main() {
        require(MangaMediaTypes.isArchive(URL(fileURLWithPath: "volume.CBZ")), "CBZ should be supported")
        require(MangaMediaTypes.isArchive(URL(fileURLWithPath: "volume.zip")), "ZIP should be supported")
        require(MangaMediaTypes.isArchive(URL(fileURLWithPath: "volume.epub")), "EPUB should be supported")
        require(
            MangaMediaTypes.cbzContentType.identifier == "moe.shishamo.hoshi.cbz-archive"
                && MangaMediaTypes.cbzContentType.isDeclared
                && !MangaMediaTypes.cbzContentType.isDynamic
                && MangaMediaTypes.importContentTypes.contains(MangaMediaTypes.cbzContentType),
            "CBZ must use the stable declared type in the open panel"
        )
        require(
            MangaMediaTypes.containerKind(for: URL(fileURLWithPath: "volume.EPUB")) == .epubArchive,
            "EPUB must use spine-aware page parsing"
        )
        require(!MangaMediaTypes.isArchive(URL(fileURLWithPath: "volume.rar")), "RAR should remain out of v1")
        require(MangaMediaTypes.isImagePath("chapter/page.WEBP"), "WebP pages should be recognized")

        let ltr = MangaPagePairResolver.indices(
            startingAt: 2,
            pageCount: 6,
            direction: .leftToRight
        )
        require(ltr == [2, 3], "LTR double page order should be ascending")

        let rtl = MangaPagePairResolver.indices(
            startingAt: 2,
            pageCount: 6,
            direction: .rightToLeft
        )
        require(rtl == [3, 2], "RTL double page order should be reversed")

        let lastPage = MangaPagePairResolver.indices(
            startingAt: 5,
            pageCount: 6,
            direction: .rightToLeft
        )
        require(lastPage == [5], "The last odd page should remain a single page")

        let clamped = MangaPagePairResolver.indices(
            startingAt: 99,
            pageCount: 3,
            direction: .leftToRight
        )
        require(clamped == [2], "Pair resolution should clamp out-of-range progress")

        require(
            MangaWheelNavigationResolver.navigation(
                deltaX: 0,
                deltaY: -1,
                hasPreciseScrollingDeltas: false
            ) == .forward,
            "Scrolling a mouse wheel down should advance the paged reader"
        )
        require(
            MangaWheelNavigationResolver.navigation(
                deltaX: 0,
                deltaY: 1,
                hasPreciseScrollingDeltas: false
            ) == .backward,
            "Scrolling a mouse wheel up should move back in the paged reader"
        )
        require(
            MangaWheelNavigationResolver.navigation(
                deltaX: 0,
                deltaY: -12,
                hasPreciseScrollingDeltas: true
            ) == nil,
            "Precise trackpad scrolling must not turn paged manga"
        )
        require(
            MangaWheelNavigationResolver.navigation(
                deltaX: 2,
                deltaY: 1,
                hasPreciseScrollingDeltas: false
            ) == nil,
            "A horizontal-dominant wheel event must not turn paged manga"
        )
        var wheelAccumulator = MangaWheelNavigationAccumulator()
        require(
            wheelAccumulator.consume(
                deltaX: 0,
                deltaY: -0.4,
                hasPreciseScrollingDeltas: false
            ) == nil,
            "A partial mouse-wheel delta should wait for the navigation threshold"
        )
        require(
            wheelAccumulator.consume(
                deltaX: 0,
                deltaY: -0.6,
                hasPreciseScrollingDeltas: false
            ) == .forward,
            "Accumulated mouse-wheel deltas should navigate after reaching the threshold"
        )
        require(
            wheelAccumulator.consume(
                deltaX: 0,
                deltaY: 0.5,
                hasPreciseScrollingDeltas: false
            ) == nil
                && wheelAccumulator.consume(
                    deltaX: 0,
                    deltaY: -0.6,
                    hasPreciseScrollingDeltas: false
                ) == nil,
            "Reversing wheel direction should clear the previous partial delta"
        )
        require(
            MangaWheelZoomResolver.scale(
                currentScale: 1,
                deltaX: 0,
                deltaY: 10,
                hasPreciseScrollingDeltas: true
            )! > 1,
            "Command-scroll up should increase manga zoom"
        )
        require(
            MangaWheelZoomResolver.scale(
                currentScale: 2,
                deltaX: 0,
                deltaY: 100,
                hasPreciseScrollingDeltas: true
            ) == 2,
            "Modifier-wheel zoom should respect the configured upper bound"
        )

        let suiteName = "moe.shishamo.hoshi.tests.manga-reader-preferences"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        require(
            MangaReaderPreferences.layout(in: defaults) == .singlePage,
            "layout preference should have a stable default"
        )
        require(
            MangaReaderPreferences.direction(in: defaults) == .rightToLeft,
            "direction preference should have a stable default"
        )
        require(
            !MangaReaderPreferences.isOCREnabled(in: defaults),
            "whole-manga OCR should remain opt-in by default"
        )
        require(
            MangaReaderPreferences.zoomPercentage(in: defaults) == 100,
            "manga page zoom should default to fit scale"
        )
        MangaReaderPreferences.save(layout: .doublePage, in: defaults)
        MangaReaderPreferences.save(direction: .leftToRight, in: defaults)
        MangaReaderPreferences.save(isOCREnabled: true, in: defaults)
        MangaReaderPreferences.save(zoomPercentage: 137, in: defaults)
        require(
            MangaReaderPreferences.layout(in: defaults) == .doublePage,
            "the last manga layout should persist"
        )
        require(
            MangaReaderPreferences.direction(in: defaults) == .leftToRight,
            "the last manga reading direction should persist"
        )
        require(
            MangaReaderPreferences.isOCREnabled(in: defaults),
            "the text overlay choice should persist for cached OCR on reopen"
        )
        require(
            MangaReaderPreferences.zoomPercentage(in: defaults) == 137,
            "an arbitrary manga page zoom percentage should persist"
        )
        MangaReaderPreferences.save(zoomPercentage: 999, in: defaults)
        require(
            MangaReaderPreferences.zoomPercentage(in: defaults) == 200,
            "manga page zoom should clamp to its supported upper bound"
        )

        require(
            MangaLibraryPreferences.sortOption(in: defaults) == .manual,
            "manga library sorting should default independently to manual"
        )
        require(
            MangaLibraryPreferences.showReading(in: defaults),
            "the manga reading shelf should be visible by default"
        )
        MangaLibraryPreferences.save(sortOption: .recent, in: defaults)
        MangaLibraryPreferences.save(showReading: false, in: defaults)
        require(
            MangaLibraryPreferences.sortOption(in: defaults) == .recent,
            "manga library sorting should persist independently"
        )
        require(
            !MangaLibraryPreferences.showReading(in: defaults),
            "the manga reading shelf preference should persist independently"
        )
        defaults.removePersistentDomain(forName: suiteName)

        let legacyCatalogJSON = """
        {
          "sources": [],
          "items": [{
            "id": "legacy-item",
            "sourceID": "00000000-0000-0000-0000-000000000001",
            "relativePath": ".",
            "title": "Legacy",
            "containerKind": "directory",
            "pageCount": 12,
            "currentPageIndex": 4
          }]
        }
        """
        let legacyCatalog = try! JSONDecoder().decode(
            MangaLibraryCatalog.self,
            from: Data(legacyCatalogJSON.utf8)
        )
        require(legacyCatalog.shelves.isEmpty, "legacy catalogs should default to no manga shelves")
        require(legacyCatalog.manualItemOrder.isEmpty, "legacy catalogs should default to no manual order")
        require(legacyCatalog.hiddenItemIDs.isEmpty, "legacy catalogs should default to no hidden items")
        require(
            legacyCatalog.items.first?.displayTitle == "Legacy",
            "legacy items without renamed titles should decode unchanged"
        )

        var organizedItem = legacyCatalog.items[0]
        organizedItem.renamedTitle = "Renamed"
        let shelf = MangaShelf(name: "Favorites", itemIDs: [organizedItem.id])
        let organizedCatalog = MangaLibraryCatalog(
            sources: [],
            items: [organizedItem],
            shelves: [shelf],
            manualItemOrder: [organizedItem.id],
            hiddenItemIDs: [organizedItem.id]
        )
        let roundTrippedCatalog = try! JSONDecoder().decode(
            MangaLibraryCatalog.self,
            from: JSONEncoder().encode(organizedCatalog)
        )
        require(
            roundTrippedCatalog == organizedCatalog,
            "manga organization and renamed titles should round-trip"
        )

        print("Manga model tests passed")
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
