// test-sources: Features/Reader/ReaderWebView/ReaderViewportGeometry.swift
import CoreGraphics
import Foundation

@main
enum ReaderPopupSasayakiRegressionTest {
    static func assertEqual(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        if abs(actual - expected) > 0.0001 {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }

    static func assertContains(_ haystack: String, _ needle: String, _ message: String) {
        if !haystack.contains(needle) {
            fputs("FAIL: \(message)\nMissing: \(needle)\n", stderr)
            exit(1)
        }
    }

    static func assertNotContains(_ haystack: String, _ needle: String, _ message: String) {
        if haystack.contains(needle) {
            fputs("FAIL: \(message)\nUnexpected: \(needle)\n", stderr)
            exit(1)
        }
    }

    static func assertLocalized(
        _ strings: [String: Any],
        _ key: String,
        languages: [String],
        _ message: String
    ) {
        guard let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any] else {
            fputs("FAIL: \(message)\nMissing localization key: \(key)\n", stderr)
            exit(1)
        }
        for language in languages where localizations[language] == nil {
            fputs("FAIL: \(message)\nMissing \(language) localization for key: \(key)\n", stderr)
            exit(1)
        }
    }

    static func assertOccurrenceCountAtLeast(
        _ haystack: String,
        _ needle: String,
        _ minimumCount: Int,
        _ message: String
    ) {
        let count = haystack.components(separatedBy: needle).count - 1
        if count < minimumCount {
            fputs("FAIL: \(message)\nExpected at least \(minimumCount) occurrences of \(needle), found \(count)\n", stderr)
            exit(1)
        }
    }

    static func sourceSection(
        _ source: String,
        from start: String,
        to end: String,
        _ message: String
    ) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            fputs("FAIL: \(message)\nMissing section boundary: \(start) ... \(end)\n", stderr)
            exit(1)
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    static func main() throws {
        let viewportRect = CGRect(x: 120, y: 180, width: 28, height: 16)
        let pagedRect = ReaderViewportGeometry.selectionRect(
            fromViewportRect: viewportRect,
            adjustedContentInset: CGPoint(x: 7, y: 11),
            scrollBoundsOrigin: CGPoint(x: 0, y: 23),
            subtractVerticalScrollOffset: true
        )
        assertEqual(pagedRect.minX, 127, "paged popup x should include left inset")
        assertEqual(pagedRect.minY, 168, "paged popup y should include top inset and subtract scroll offset")
        assertEqual(pagedRect.width, 28, "paged popup width should be preserved")
        assertEqual(pagedRect.height, 16, "paged popup height should be preserved")

        let continuousHorizontalRect = ReaderViewportGeometry.selectionRect(
            fromViewportRect: viewportRect,
            adjustedContentInset: CGPoint(x: 7, y: 11),
            scrollBoundsOrigin: CGPoint(x: 0, y: 23),
            subtractVerticalScrollOffset: false
        )
        assertEqual(continuousHorizontalRect.minY, 191, "horizontal continuous popup y should not subtract vertical scroll offset")

        let fullViewportRect = ReaderViewportGeometry.selectionRect(
            fromViewportRect: viewportRect,
            adjustedContentInset: .zero,
            scrollBoundsOrigin: .zero,
            subtractVerticalScrollOffset: false
        )
        assertEqual(fullViewportRect.minX, viewportRect.minX, "full-viewport popup x should not add a synthetic side inset")
        assertEqual(fullViewportRect.minY, viewportRect.minY, "full-viewport popup y should not add a synthetic top inset")

        let horizontalAnchorRect = ReaderViewportGeometry.selectionRect(
            fromViewportRect: viewportRect,
            adjustedContentInset: .zero,
            scrollBoundsOrigin: .zero,
            subtractVerticalScrollOffset: false
        )
        assertEqual(horizontalAnchorRect.minX, viewportRect.minX, "horizontal popup anchor should preserve the selected word x")
        assertEqual(horizontalAnchorRect.minY, viewportRect.minY, "horizontal popup anchor should stay on the selected word")
        assertEqual(horizontalAnchorRect.width, viewportRect.width, "horizontal popup anchor should preserve the selected word width")
        assertEqual(horizontalAnchorRect.height, viewportRect.height, "horizontal popup anchor should stay the selected glyph height")

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let nativeReader = try String(
            contentsOf: root.appendingPathComponent("NativeMac/NativeReaderView.swift"),
            encoding: .utf8
        )
        let shiftHoverWebView = try String(
            contentsOf: root.appendingPathComponent("Core/SelectionLookup/HoshiShiftHoverWKWebView.swift"),
            encoding: .utf8
        )
        let nativeFullscreenImageView = sourceSection(
            nativeReader,
            from: "struct NativeFullscreenImageView",
            to: "struct NativeFullscreenImageWebView",
            "native Reader should define a fullscreen image overlay"
        )
        let nativeFullscreenImageWebView = sourceSection(
            nativeReader,
            from: "struct NativeFullscreenImageWebView",
            to: "func nsColorHex",
            "native Reader should define a fullscreen image WebView"
        )
        let popupView = try String(
            contentsOf: root.appendingPathComponent("Features/Popup/PopupView.swift"),
            encoding: .utf8
        )
        let dictionaryManager = try String(
            contentsOf: root.appendingPathComponent("Core/DictionaryManager.swift"),
            encoding: .utf8
        )
        let readerGoToView = try String(
            contentsOf: root.appendingPathComponent("Features/Reader/Search/ReaderGoToView.swift"),
            encoding: .utf8
        )
        let userConfigSource = try String(
            contentsOf: root.appendingPathComponent("Core/UserConfig.swift"),
            encoding: .utf8
        )
        let profileSource = try String(
            contentsOf: root.appendingPathComponent("Models/Profile.swift"),
            encoding: .utf8
        )
        let appearanceSettings = try String(
            contentsOf: root.appendingPathComponent("Features/Settings/AppearanceView.swift"),
            encoding: .utf8
        )
        let changelog = try String(
            contentsOf: root.appendingPathComponent("docs/CHANGELOG.md"),
            encoding: .utf8
        )
        let readerRegressionDoc = try String(
            contentsOf: root.appendingPathComponent("docs/READER_REGRESSION_TESTING.md"),
            encoding: .utf8
        )
        assertContains(
            popupView,
            "import CxxStdlib",
            "Popup clean builds must explicitly import the std::string-to-Swift bridge they use"
        )
        assertContains(
            dictionaryManager,
            "import CxxStdlib",
            "Dictionary manager clean builds must explicitly import the std::string-to-Swift bridge they use"
        )
        assertContains(
            dictionaryManager,
            "nonisolated private func dictionaryImporterTitleString(_ title: std.string) -> String",
            "Dictionary manager should centralize importer title conversion for clean Swift/C++ builds"
        )
        assertNotContains(
            dictionaryManager,
            "insert(String(importResult.title))",
            "Dictionary manager should avoid direct std::string initializers that fail in clean Swift/C++ builds"
        )
        assertNotContains(
            dictionaryManager,
            "let title = String(importResult.title)",
            "Dictionary manager should avoid direct std::string initializers that fail in clean Swift/C++ builds"
        )
        assertNotContains(
            dictionaryManager,
            "let new = String(importResult.title)",
            "Dictionary manager should avoid direct std::string initializers that fail in clean Swift/C++ builds"
        )
        assertContains(
            nativeReader,
            "coverURL: model.coverURL",
            "Reader popup mining should pass the active book cover into MiningContext"
        )
        assertNotContains(
            nativeReader,
            "coverURL: nil",
            "Reader popup mining should not discard the active book cover"
        )
        guard let readerIdentityStart = nativeReader.range(of: "let readerIdentity = ["),
              let readerIdentityEnd = nativeReader.range(
                of: "].joined(separator: \"-\")",
                range: readerIdentityStart.upperBound..<nativeReader.endIndex
              ) else {
            fputs("FAIL: native Reader should define a readerIdentity array\n", stderr)
            exit(1)
        }
        let readerIdentityBlock = String(nativeReader[readerIdentityStart.lowerBound..<readerIdentityEnd.upperBound])
        let paginatedReaderScript = try String(
            contentsOf: root.appendingPathComponent("Features/Reader/ReaderWebView/reader.js"),
            encoding: .utf8
        )
        let continuousReaderScript = try String(
            contentsOf: root.appendingPathComponent("Features/Reader/ScrollReaderWebView/scrollreader.js"),
            encoding: .utf8
        )
        let selectionScript = try String(
            contentsOf: root.appendingPathComponent("Features/Reader/ReaderWebView/selection.js"),
            encoding: .utf8
        )
        let navigateSection = sourceSection(
            nativeReader,
            from: "fileprivate func navigate(_ direction: NativeReaderNavigationDirection)",
            to: "fileprivate func handleCommand(_ command: WebViewCommand)",
            "native Reader should expose one manual navigation bridge"
        )
        let programmaticNavigationSection = sourceSection(
            nativeReader,
            from: "case .restoreProgress(let progress):",
            to: "case .clearSelection:",
            "native Reader should keep programmatic navigation separate from manual page turns"
        )
        let nativeApp = try String(
            contentsOf: root.appendingPathComponent("NativeMac/HoshiNativeMacApp.swift"),
            encoding: .utf8
        )
        let sasayakiSheet = try String(
            contentsOf: root.appendingPathComponent("Features/Sasayaki/SasayakiSheet.swift"),
            encoding: .utf8
        )
        let sasayakiPlayer = try String(
            contentsOf: root.appendingPathComponent("Features/Sasayaki/SasayakiPlayer.swift"),
            encoding: .utf8
        )
        let nativeReuseViews = try String(
            contentsOf: root.appendingPathComponent("NativeMac/NativeReuseViews.swift"),
            encoding: .utf8
        )
        let nativeMacSection = try String(
            contentsOf: root.appendingPathComponent("NativeMac/NativeMacSection.swift"),
            encoding: .utf8
        )
        let nativeMacSidebarView = try String(
            contentsOf: root.appendingPathComponent("NativeMac/NativeMacSidebarView.swift"),
            encoding: .utf8
        )
        let nativeMacDetailView = try String(
            contentsOf: root.appendingPathComponent("NativeMac/NativeMacDetailView.swift"),
            encoding: .utf8
        )
        let nativeMacPlaceholderViews = try String(
            contentsOf: root.appendingPathComponent("NativeMac/NativeMacPlaceholderViews.swift"),
            encoding: .utf8
        )
        let shortcutBridge = try String(
            contentsOf: root.appendingPathComponent("Core/ReaderKeyboardShortcutAppKitBridge.swift"),
            encoding: .utf8
        )
        let shortcutManager = try String(
            contentsOf: root.appendingPathComponent("Core/Shortcuts/ShortcutManager.swift"),
            encoding: .utf8
        )
        let localizationData = try Data(contentsOf: root.appendingPathComponent("Localizable.xcstrings"))
        guard let localizationRoot = try JSONSerialization.jsonObject(with: localizationData) as? [String: Any],
              let localizationStrings = localizationRoot["strings"] as? [String: Any] else {
            fputs("FAIL: Localizable.xcstrings should be valid JSON with a strings object\n", stderr)
            exit(1)
        }
        assertContains(selectionScript, "language: 'ja'", "Reader selection must declare a language policy")
        assertContains(selectionScript, "isEnglishScanBoundaryAt", "Reader selection must support English phrase boundaries")
        assertContains(selectionScript, "findEnglishWordStart", "English lookup must start at the beginning of the tapped word")
        assertContains(selectionScript, "EnglishWordInternalDelimiters", "English lookup must retain apostrophes and hyphens inside words")
        assertContains(selectionScript, "rect: this.getSelectionRect(x, y)", "horizontal Reader lookup should send the upstream character rect as the only popup anchor")
        assertNotContains(selectionScript, "anchorPoint:", "horizontal Reader lookup should not send click-point anchors because they drift with event timing")
        assertNotContains(selectionScript, "getSelectionLineRect", "horizontal Reader lookup should not send expanded line rects because they move popups away from the selected glyph")
        assertNotContains(selectionScript, "resolveLineHeight", "horizontal Reader lookup should not estimate popup placement from CSS line-height")
        assertContains(
            nativeReader,
            "let publisherColumnResetCss = parent.userConfig.continuousMode ? \"\" : \"\"\"",
            "publisher column overrides should only be reset in paginated Reader mode"
        )
        assertContains(
            nativeReader,
            "body * {\n                column-count: auto !important;\n                -webkit-column-count: auto !important;",
            "paginated Reader should neutralize nested publisher multi-column declarations"
        )
        assertContains(
            nativeReader,
            "\\(publisherColumnResetCss)",
            "native Reader should inject the conditional nested-column reset"
        )
        assertNotContains(
            nativeReader,
            "-webkit-line-box-contain",
            "Reader should not use the WebKit line-box override that can distort publisher layout"
        )
        assertContains(
            selectionScript,
            "closest('p, .kanji-entry li, .glossary-content, .expr-tag, .dictionary-query-source')",
            "Reader and Dictionary lookup should not scan across expression-tag or query-line boundaries"
        )
        let lookupHighlightSection = sourceSection(
            selectionScript,
            from: "highlightSelection(charCount)",
            to: "getNormalizedOffset(targetNode, offset)",
            "Reader selection should expose its lookup-highlight boundary"
        )
        assertContains(
            selectionScript,
            "highlight: null",
            "Reader lookup should retain one reusable CSS Highlight object"
        )
        assertContains(
            lookupHighlightSection,
            "if (!this.highlight) {\n                this.highlight = new Highlight();\n                CSS.highlights.set('hoshi-selection', this.highlight);",
            "Reader lookup should create and register its CSS Highlight only once"
        )
        assertContains(
            lookupHighlightSection,
            "highlights.forEach(range => this.highlight.add(range));",
            "Reader lookup should refill the reusable CSS Highlight with current ranges"
        )
        assertNotContains(
            lookupHighlightSection,
            "new Highlight(...highlights)",
            "Reader lookup should not allocate a new CSS Highlight for every scan"
        )
        assertContains(
            selectionScript,
            "this.applyFallbackHighlights(highlights);",
            "Reader lookup should retain the fallback highlighter for WebKit without CSS Highlights"
        )
        assertContains(
            selectionScript,
            "clearLookupSelection() {\n        this.highlight?.clear();",
            "clearing Reader lookup should clear the reusable Highlight object"
        )
        assertContains(
            paginatedReaderScript,
            "else if (cursor > start && cursor < end)",
            "paginated Sasayaki highlighting should retain punctuation that crosses text nodes"
        )
        assertContains(
            continuousReaderScript,
            "else if (cursor > start && cursor < end)",
            "continuous Sasayaki highlighting should retain punctuation that crosses text nodes"
        )
        assertContains(
            nativeReader,
            "if (img.complete) {\n                            if (img.naturalWidth > 0) {\n                                processImg();\n                            } else {\n                                resolve();",
            "failed images that completed before injection must not block Reader restore and Sasayaki cue setup"
        )
        assertContains(
            nativeReader,
            "[...ruby.childNodes].forEach(node =>",
            "Reader ruby normalization should iterate a stable node snapshot while replacing text nodes"
        )
        assertContains(
            nativeReader,
            "} else {\n                            node.remove();\n                        }",
            "Reader ruby normalization should remove whitespace text nodes that split lookup ranges"
        )
        assertContains(nativeReader, "window.hoshiSelection.language =", "native Reader must inject the resolved Profile language")
        assertContains(
            profileSource,
            "var twoColumnHorizontalPages: Bool? = nil",
            "Reader Profile settings should add two-column pages as an optional field so existing profile JSON decodes"
        )
        assertContains(
            userConfigSource,
            "var readerTwoColumnHorizontalPages: Bool",
            "UserConfig should persist the Reader two-column horizontal page preference"
        )
        assertContains(
            userConfigSource,
            "twoColumnHorizontalPages: readerTwoColumnHorizontalPages",
            "Reader Profile snapshots should include the two-column horizontal page preference"
        )
        assertContains(
            userConfigSource,
            "readerTwoColumnHorizontalPages = settings.twoColumnHorizontalPages ?? false",
            "Reader Profile restore should default old profiles to single-column pages"
        )
        assertContains(
            appearanceSettings,
            "if !userConfig.continuousMode && !userConfig.verticalWriting",
            "Appearance settings should only expose two-column pages where they can take effect"
        )
        assertContains(
            appearanceSettings,
            "NativeSettingsToggle(\"Two-Column Horizontal Pages\", isOn: $userConfig.readerTwoColumnHorizontalPages)",
            "Appearance settings should expose the two-column horizontal page toggle"
        )
        assertLocalized(
            localizationStrings,
            "Two-Column Horizontal Pages",
            languages: ["en", "zh-Hans", "zh-Hant"],
            "the Reader two-column page setting should be localized"
        )
        assertContains(
            readerIdentityBlock,
            "userConfig.readerTwoColumnHorizontalPages",
            "native Reader reload identity should include the two-column horizontal page preference"
        )
        assertContains(
            nativeReader,
            "let horizontalPageColumns = parent.userConfig.readerTwoColumnHorizontalPages",
            "native Reader CSS injection should derive horizontal spread column count from the Reader setting"
        )
        assertContains(
            nativeReader,
            "let horizontalSpreadColumnGap = 32",
            "native Reader two-column horizontal spreads should use a fixed center gutter"
        )
        let paragraphScript = try String(
            contentsOf: root.appendingPathComponent("Features/Reader/ReaderWebView/paragraph.js"),
            encoding: .utf8
        )
        for field in ["paragraphMode: Bool? = nil", "textAnimation: Bool? = nil", "textSpeed: Int? = nil"] {
            assertContains(profileSource, "var \(field)", "Reader Profile paragraph settings must stay optional so existing profile JSON decodes")
        }
        assertContains(
            userConfigSource,
            "paragraphMode = settings.paragraphMode ?? false",
            "Reader Profile restore should default old profiles to regular pagination"
        )
        assertContains(
            readerIdentityBlock,
            "userConfig.paragraphMode",
            "native Reader reload identity should include paragraph mode"
        )
        assertContains(
            nativeReader,
            "&& !paragraphMode ? 2 : 1",
            "paragraph mode should render one paragraph per single-column page"
        )
        assertContains(
            nativeReader,
            "document.fonts.ready.then(() => window.hoshiParagraph.layoutParagraphs())",
            "paragraph layout must run after fonts load and before node offsets, cues and restore"
        )
        assertContains(
            nativeReader,
            "if (window.hoshiParagraph?.finishTextAnimation()) {",
            "a click during text animation should finish the animation instead of looking up"
        )
        assertContains(
            nativeReader,
            "margin-block-start: 0 !important;\n                break-before: column !important;",
            "paragraph pages must not start with an empty page from publisher paragraph margins"
        )
        assertContains(
            paragraphScript,
            "const position = vertical ? rect.top : rect.left;",
            "paragraph page detection must follow Mac vertical top-to-bottom pagination"
        )
        assertContains(
            appearanceSettings,
            "!userConfig.continuousMode && !userConfig.verticalWriting && !userConfig.paragraphMode",
            "two-column spreads should be hidden while paragraph mode controls pagination"
        )
        for key in ["Paragraph Mode", "Text Animation", "Text Speed", "%lld/s"] {
            assertLocalized(localizationStrings, key, languages: ["en", "zh-Hans", "zh-Hant"], "paragraph mode settings should be localized")
        }
        assertContains(
            nativeReader,
            "? \"max(1px, calc((var(--page-width, 100vw) - \\(horizontalPadding)vw - \\(horizontalSpreadColumnGap)px) / 2))\"",
            "native Reader two-column widths should preserve side padding while keeping the center gutter fixed"
        )
        assertNotContains(
            nativeReader,
            "? \"max(1px, calc((var(--page-width, 100vw) - \\(horizontalPadding * 2)vw) / 2))\"",
            "native Reader two-column widths should not keep deriving the center gutter from horizontal padding"
        )
        assertContains(
            nativeReader,
            "let horizontalSpreadPageSize = horizontalPageColumns > 1",
            "native Reader should keep two-column pagination aligned to the fixed visual gutter"
        )
        assertContains(
            nativeReader,
            "let horizontalSpreadSideClip = \"\\(horizontalPadding / 2)vw\"",
            "native Reader should derive the two-column side clip from the existing horizontal padding"
        )
        assertContains(
            nativeReader,
            "let horizontalSpreadClipCss = horizontalPageColumns > 1",
            "native Reader should clip side gutters only for horizontal two-column spreads"
        )
        assertContains(
            nativeReader,
            "body::before,\n            body::after",
            "native Reader should hide neighboring spread text with viewport-fixed visual overlays"
        )
        assertContains(
            nativeReader,
            "background: var(--hoshi-reader-background-color);",
            "native Reader side overlays should match the current Reader background"
        )
        assertNotContains(
            nativeReader,
            "-webkit-mask-image:",
            "native Reader should not put a mask on the scrollable body because multi-column body width is not viewport width"
        )
        assertContains(
            nativeReader,
            "window.hoshiReader.horizontalPageColumns = \\(horizontalPageColumns);",
            "native Reader should pass horizontal spread column count into reader.js"
        )
        assertContains(
            nativeReader,
            "window.hoshiReader.horizontalSpreadPageSize = \\(horizontalSpreadPageSize);",
            "native Reader should pass the fixed-gutter page step into reader.js without changing native statistics callbacks"
        )
        assertContains(
            paginatedReaderScript,
            "horizontalPageColumns: 1",
            "paginated reader.js should default to single-column horizontal spreads"
        )
        assertContains(
            paginatedReaderScript,
            "horizontalSpreadPageSize: null",
            "paginated reader.js should default to the viewport page step unless native Reader supplies fixed-gutter spread geometry"
        )
        assertNotContains(
            paginatedReaderScript,
            "registerKeyboardNavigation",
            "paginated reader.js should not add a JS keydown fallback because WKWebView keyDown already dispatches Reader shortcuts"
        )
        assertContains(
            paginatedReaderScript,
            "horizontalTerminalPageTarget: null",
            "paginated reader.js should remember an attempted two-column terminal page target that WebKit may clamp asynchronously"
        )
        assertContains(
            paginatedReaderScript,
            "horizontalContentMetricsCache: null",
            "paginated reader.js should cache two-column terminal content geometry for the current chapter layout"
        )
        assertContains(
            paginatedReaderScript,
            "var scrollEl = document.body;",
            "paginated reader.js should keep using body as the paginated column scroll container"
        )
        assertContains(
            paginatedReaderScript,
            "context.scrollEl.addEventListener('scroll', function () {",
            "paginated reader.js snap handling should listen to the same scroll container used for page turns"
        )
        assertNotContains(
            paginatedReaderScript,
            "document.body.addEventListener('scroll'",
            "paginated reader.js should not snap against body when WebKit scrolls documentElement"
        )
        assertContains(
            paginatedReaderScript,
            "var viewportSize = vertical ? this.pageHeight : this.pageWidth;",
            "paginated reader.js should distinguish the visible viewport from the page-turn step"
        )
        assertContains(
            paginatedReaderScript,
            "var scrollViewportSize = vertical ? (scrollEl.clientHeight || window.innerHeight) : (scrollEl.clientWidth || window.innerWidth);",
            "paginated reader.js should size two-column trailing scroll extent from the actual scroll container viewport"
        )
        assertContains(
            paginatedReaderScript,
            "var scrollStartPadding = vertical ? 0 : (parseFloat(window.getComputedStyle(scrollEl).paddingLeft) || 0);",
            "paginated reader.js should compensate for horizontal body padding when making the final spread reachable"
        )
        assertContains(
            paginatedReaderScript,
            "var scrollEndPadding = vertical ? 0 : (parseFloat(window.getComputedStyle(scrollEl).paddingRight) || 0);",
            "paginated reader.js should compensate for both horizontal body paddings when making the final spread reachable"
        )
        assertContains(
            paginatedReaderScript,
            "var rawMaxScroll = Math.max(0, totalSize - viewportSize);",
            "paginated reader.js should compute scroll limits from the visible viewport"
        )
        assertContains(
            paginatedReaderScript,
            "var limitTolerance = 1;",
            "paginated reader.js should default chapter-limit detection to the existing one-pixel tolerance"
        )
        assertContains(
            paginatedReaderScript,
            "this.horizontalPageColumns > 1 && !vertical",
            "paginated reader.js should align horizontal two-column spread limits without changing vertical behavior"
        )
        assertContains(
            paginatedReaderScript,
            "this.horizontalPageColumns > 1 && !vertical && this.horizontalSpreadPageSize > 0",
            "paginated reader.js should use fixed-gutter spread geometry only for horizontal two-column pages"
        )
        assertContains(
            paginatedReaderScript,
            "horizontalContentEndOffset(scrollEl)",
            "paginated reader.js should find the last real content position for two-column spread limits"
        )
        assertContains(
            paginatedReaderScript,
            "return this.horizontalContentMetrics(scrollEl).maxEnd;",
            "paginated reader.js should reuse cached two-column content extent instead of rescanning the chapter repeatedly"
        )
        assertContains(
            paginatedReaderScript,
            "horizontalTerminalContentOffset(scrollEl)",
            "paginated reader.js should find the last real content position when restoring chapter-end progress"
        )
        assertContains(
            paginatedReaderScript,
            "lastPage = this.alignToPage(context, terminalOffset);",
            "paginated reader.js should restore two-column chapter ends to the spread containing real content"
        )
        assertContains(
            paginatedReaderScript,
            "while (actualLastPage > 0 && !this.hasVisibleContentInViewport(context))",
            "paginated reader.js should back away from a blank WebKit terminal spread during chapter-end restore"
        )
        assertContains(
            paginatedReaderScript,
            "hasVisibleContentInViewport(context)",
            "paginated reader.js should detect terminal two-column targets that would render as blank pages"
        )
        assertContains(
            paginatedReaderScript,
            "hasTerminalContentInViewport(context)",
            "paginated reader.js should detect when the current two-column spread already contains the last real content"
        )
        assertContains(
            paginatedReaderScript,
            "if (this.horizontalPageColumns > 1 && !context.vertical && this.hasTerminalContentInViewport(context)) {",
            "paginated reader.js should cross chapters instead of moving to a phantom terminal spread"
        )
        assertContains(
            paginatedReaderScript,
            "if (isTerminalTarget && !this.hasVisibleContentInViewport(context)) {",
            "paginated reader.js should avoid showing a blank terminal two-column spread before crossing chapters"
        )
        assertContains(
            paginatedReaderScript,
            "if ((context.contentMetrics?.maxEnd || 0) <= currentScroll + context.viewportSize + context.limitTolerance) {",
            "paginated reader.js should treat a two-column spread that already contains the last real content as the chapter limit"
        )
        assertContains(
            paginatedReaderScript,
            "this.setScrollOffset(context, currentScroll);",
            "paginated reader.js should restore the prior visible spread when a terminal target is blank"
        )
        assertContains(
            paginatedReaderScript,
            "NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT",
            "paginated reader.js should scan text and image elements in DOM order for two-column page bounds"
        )
        assertContains(
            paginatedReaderScript,
            "visibleContentBounds(scrollEl)",
            "paginated reader.js should derive the actually visible horizontal content bounds from Reader side padding"
        )
        assertContains(
            paginatedReaderScript,
            "rectIntersectsViewport(rect, bounds)",
            "paginated reader.js should test visibility against the unmasked viewport area"
        )
        assertContains(
            paginatedReaderScript,
            "visibleBounds.left",
            "paginated reader.js should ignore content clipped by the left side mask"
        )
        assertContains(
            paginatedReaderScript,
            "visibleBounds.right",
            "paginated reader.js should ignore content clipped by the right side mask"
        )
        assertContains(
            paginatedReaderScript,
            "node.matches?.('img, svg')",
            "paginated reader.js should count plain image pages when finding two-column content extent"
        )
        assertNotContains(
            paginatedReaderScript,
            "document.querySelectorAll('img.block-img, svg')",
            "paginated reader.js should not miss image-only pages whose images were not promoted to block-img"
        )
        assertContains(
            paginatedReaderScript,
            "ensureHorizontalSpreadScrollExtent(maxScroll, viewportSize)",
            "paginated reader.js should add trailing scroll extent only when a two-column final spread needs it"
        )
        assertContains(
            paginatedReaderScript,
            "this.ensureHorizontalSpreadScrollExtent(maxScroll, scrollViewportSize + scrollStartPadding + scrollEndPadding)",
            "paginated reader.js should make the final two-column spread reachable even when body padding changes the scroll viewport"
        )
        assertContains(
            paginatedReaderScript,
            "limitTolerance = Math.max(1, scrollStartPadding + scrollEndPadding + 1);",
            "paginated reader.js should allow padded two-column final spreads to count as chapter limits"
        )
        assertContains(
            paginatedReaderScript,
            "Math.floor(Math.max(0, contentMetrics.maxEnd - 1) / pageSize) * pageSize",
            "paginated reader.js should align the final two-column spread to the spread containing real content"
        )
        assertContains(
            paginatedReaderScript,
            "return context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;",
            "paginated reader.js should report the actual browser scroll offset after setting paginated scroll"
        )
        assertContains(
            paginatedReaderScript,
            "if (currentScroll >= (context.maxScroll - context.limitTolerance)) {",
            "paginated reader.js should use the padded two-column limit tolerance before trying another unreachable page scroll"
        )
        assertContains(
            paginatedReaderScript,
            "if (targetScroll >= (context.maxScroll - context.limitTolerance) && actualScroll <= currentScroll + 1) {",
            "paginated reader.js should treat an unreachable final two-column spread target as the chapter limit"
        )
        assertContains(
            paginatedReaderScript,
            "this.horizontalTerminalPageTarget && currentScroll > this.horizontalTerminalPageTarget.before + 1",
            "paginated reader.js should report the chapter limit after WebKit asynchronously clamps a terminal two-column page target"
        )
        assertContains(
            paginatedReaderScript,
            "this.horizontalTerminalPageTarget = { before: currentScroll, target: targetScroll };",
            "paginated reader.js should mark the first successful move toward a terminal two-column page target"
        )
        assertContains(
            paginatedReaderScript,
            "this.horizontalTerminalPageTarget = null;\n        const rect = this.getRect(range);",
            "paginated reader.js should clear stale terminal page targets before internal range navigation"
        )
        assertContains(
            nativeReader,
            "position: relative !important;",
            "native Reader should give two-column horizontal spacer geometry a stable body containing block"
        )
        assertContains(
            paginatedReaderScript,
            "hoshi-reader-spread-end-spacer",
            "paginated reader.js should mark its invisible spread spacer so content scanning ignores it"
        )
        assertNotContains(
            paginatedReaderScript,
            "Math.floor((rawMaxScroll + 1) / pageSize) * pageSize",
            "paginated reader.js should not infer two-column final spreads from raw scrollWidth alone"
        )
        assertContains(
            navigateSection,
            "parent.onPageTurn()",
            "manual two-column page navigation should still enter the existing page-turn statistics path once"
        )
        assertContains(
            nativeReader,
            "var onNavigationHandled: (UUID) -> Void",
            "native Reader should clear a consumed page-navigation request so it cannot replay after a chapter reload"
        )
        assertContains(
            nativeReader,
            "NativeReaderNavigationConsumptionRegistry",
            "native Reader should remember consumed page-navigation requests across WebView reloads"
        )
        assertContains(
            nativeReader,
            "guard NativeReaderNavigationConsumptionRegistry.consume(navigation.id)",
            "native Reader should refuse to replay the same page-navigation request after a chapter reload"
        )
        assertContains(
            nativeReader,
            "onNavigationHandled(navigation.id)",
            "native Reader should mark keyboard page navigation as handled before asynchronous chapter changes"
        )
        assertContains(
            nativeReader,
            "if pageNavigation?.id == navigationID {",
            "native Reader should clear only the page-navigation request that was actually consumed"
        )
        assertContains(
            nativeReader,
            "pageNavigation = nil",
            "native Reader should remove consumed page-navigation requests from SwiftUI state"
        )
        assertContains(
            nativeReader,
            "override func keyDown(with event: NSEvent) {\n        if shortcutManager?.handleKeyDown(event) == true { return }",
            "native Reader WKWebView should keep Reader keyboard shortcuts on the native keyDown path"
        )
        assertNotContains(
            nativeReader,
            "registerKeyboardNavigation",
            "native Reader should not inject a second JS keyboard navigation path that can double-consume one physical key press"
        )
        assertNotContains(
            nativeReader,
            "private func navigateForward() {\n        model.handleManualNavigation()",
            "native Reader should not start page-turn statistics before WebView actually consumes forward navigation"
        )
        assertNotContains(
            nativeReader,
            "private func navigateBackward() {\n        model.handleManualNavigation()",
            "native Reader should not start page-turn statistics before WebView actually consumes backward navigation"
        )
        assertNotContains(
            programmaticNavigationSection,
            "onPageTurn()",
            "two-column restore and internal jumps should not start page-turn statistics"
        )
        assertContains(
            readerRegressionDoc,
            "single-column and two-column horizontal paginated pages",
            "Reader regression guidance should cover the new horizontal two-column page mode"
        )
        assertContains(
            changelog,
            "two-column horizontal page layout",
            "the user-visible Reader layout option should be recorded in the changelog"
        )
        assertContains(
            nativeReader,
            "final class NativeReaderWKWebView: HoshiShiftHoverWKWebView",
            "native Reader should use the non-focus-stealing Shift-hover WebView boundary"
        )
        assertNotContains(
            nativeReader,
            "keyboardNavigation",
            "native Reader should not install a JS keyboard navigation message bridge in addition to ShortcutManager"
        )
        assertNotContains(
            nativeReader,
            "focusRequested",
            "native Reader Shift-hover lookup must not move first-responder ownership between WebViews"
        )
        assertContains(
            shiftHoverWebView,
            "NSEvent.addLocalMonitorForEvents(\n            matching: .flagsChanged",
            "Shift-hover modifier tracking should use a lifecycle-bound local monitor"
        )
        assertContains(
            shiftHoverWebView,
            "self.containsCurrentPointer(in: window)",
            "Shift modifier updates should target only the WebView currently under the pointer"
        )
        assertContains(
            shiftHoverWebView,
            "window.hoshiSelection?.setNativeShiftPressed?",
            "the native modifier monitor should update selection.js without changing focus"
        )
        assertContains(
            shiftHoverWebView,
            "return event",
            "the Shift modifier monitor must never consume AppKit events"
        )
        assertContains(
            nativeReader,
            "(webView as? NativeReaderWKWebView)?.relinquishTextInputFocus()",
            "Reader reload and teardown should relinquish WebKit text input before changing page lifecycle"
        )
        let shiftHoverSelectionSection = sourceSection(
            selectionScript,
            from: "registerShiftHoverLookup(maxLength, hoverDelayMs) {",
            to: "clearFallbackHighlights()",
            "selection.js should define the shared Shift-hover lookup handler"
        )
        assertContains(
            shiftHoverSelectionSection,
            "this.shiftKeyPressed = event.shiftKey;",
            "pointer movement should synchronize Shift state before scheduling lookup"
        )
        assertContains(
            shiftHoverSelectionSection,
            "this.setNativeShiftPressed = (pressed) => {",
            "selection.js should accept native Shift state without a focus handoff"
        )
        assertNotContains(
            shiftHoverSelectionSection,
            "focusRequested",
            "Shift-hover selection must not ask AppKit to transfer WebView focus"
        )
        assertContains(
            nativeReader,
            "window.hoshiSelection.registerShiftHoverLookup(lookupScanLength, \\(parent.userConfig.desktopLookupHoverDelayMs));",
            "native Reader must register Shift-hover with the configured Mac hover delay"
        )
        assertContains(
            nativeReader,
            "const lookupScanLength = \\(parent.userConfig.scanLength);",
            "native Reader click and Shift-hover lookup must share the configured scan length"
        )
        assertContains(
            nativeReader,
            "BookStorage.loadMetadata(root: root) ?? book",
            "Reader last-access updates must preserve language and Profile fields written by sidecar migration"
        )
        let nativeBuildScript = try String(
            contentsOf: root.appendingPathComponent("script/build_and_run_native.sh"),
            encoding: .utf8
        )
        let xcodeProject = try String(
            contentsOf: root.appendingPathComponent("Niratan.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        assertContains(
            nativeReader,
            "const browserSelection = window.getSelection();\n                    if (browserSelection && !browserSelection.isCollapsed) { return; }",
            "native Reader drag selection must bypass click lookup so WebKit keeps the selected range"
        )
        assertContains(
            nativeReader,
            "case goTo",
            "native Reader must expose a unified Go to sheet instead of separate navigation-only sheets"
        )
        assertContains(
            nativeReader,
            "ReaderGoToView(",
            "native Reader Go to sheet must render the unified search/chapters/highlights view"
        )
        assertContains(
            nativeReader,
            "onSearchResultJump: { result in\n                            model.jumpToCharacter(result.character)",
            "Reader search results must jump through the existing character-position Reader path"
        )
        assertContains(
            nativeReader,
            "toggleSidePanel(.goTo)",
            "native Reader must open the unified Go to side panel from its bottom-right button"
        )
        assertContains(
            readerGoToView,
            "NativeReaderInspectorTabBar(\n                tabs: ReaderGoToTab.allCases,\n                selection: $selectedTab,",
            "Reader Go to should switch Search, Chapters and Highlights with the side-panel tab bar"
        )
        assertNotContains(
            readerGoToView,
            ".background(.ultraThinMaterial, in: Capsule())",
            "Reader Go to tabs must not flatten Liquid Glass with an opaque material fill"
        )
        assertNotContains(
            readerGoToView,
            ".pickerStyle(.segmented)",
            "Reader Go to tabs should not use the default dark segmented Picker chrome"
        )
        assertContains(
            readerGoToView,
            "var chapterLabelBySpineIndex: [Int: String]",
            "Reader Go to highlight grouping should build chapter labels with duplicate-spine TOC entries safely"
        )
        assertNotContains(
            readerGoToView,
            "Dictionary(uniqueKeysWithValues: chapterRows.map",
            "Reader Go to highlights must not crash when multiple TOC rows point at the same spine item"
        )
        assertNotContains(
            nativeReader,
            "search-highlight",
            "current-book search v1 must not inject temporary search highlights into the Reader body"
        )
        assertContains(
            nativeReader,
            "config.userContentController.add(context.coordinator, name: \"selectionState\")",
            "native Reader must receive browser selection state for its AppKit context menu"
        )
        assertContains(
            nativeReader,
            "webView.configuration.userContentController.removeScriptMessageHandler(forName: \"selectionState\")",
            "native Reader must remove its selection-state script handler"
        )
        assertContains(
            nativeReader,
            "override func willOpenMenu(_ menu: NSMenu, with event: NSEvent)",
            "native Reader must extend the standard WebKit context menu as it opens"
        )
        assertContains(
            nativeReader,
            "super.willOpenMenu(menu, with: event)",
            "native Reader must preserve WebKit standard context-menu items"
        )
        assertNotContains(
            nativeReader,
            "override func menu(for event: NSEvent) -> NSMenu?",
            "native Reader must not customize the unused outer WKWebView menu provider"
        )
        assertContains(
            nativeReader,
            "window.hoshiHighlights.createHighlight",
            "native Reader highlight actions must reuse the shared JavaScript range creator"
        )
        assertContains(
            nativeReader,
            "case \"selectionState\":",
            "native Reader must update native menu eligibility from browser selection state"
        )
        assertContains(
            nativeReader,
            "onHighlightCreated: model.addHighlight",
            "native Reader must forward WebView highlight creation into the book model"
        )
        assertContains(
            nativeReader,
            "func addHighlight(_ color: HighlightColor, _ creation: HighlightData)",
            "native Reader model must expose book-scoped highlight persistence"
        )
        assertContains(
            nativeReader,
            "try? BookStorage.save(highlights, inside: rootURL, as: FileNames.highlights)",
            "native Reader must persist created highlights in the current book"
        )
        for key in ["Yellow", "Green", "Blue", "Pink", "Purple"] {
            assertLocalized(
                localizationStrings,
                key,
                languages: ["en", "zh-Hans"],
                "native Reader highlight colors should have English and Simplified Chinese localization"
            )
        }

        assertNotContains(
            nativeMacSection,
            "case reader",
            "native home sidebar should not expose a standalone Reader section"
        )
        assertNotContains(
            nativeMacDetailView,
            "case .reader",
            "native home detail should not keep the removed Reader placeholder route"
        )
        assertNotContains(
            nativeMacPlaceholderViews,
            "NativeReaderPlaceholderView",
            "native home should not keep the removed Reader placeholder view"
        )
        assertContains(
            nativeMacSection,
            "var title: LocalizedStringKey",
            "native home navigation titles should use localized keys"
        )
        assertContains(
            nativeMacSection,
            "var detail: LocalizedStringKey",
            "native home navigation details should use localized keys"
        )
        assertNotContains(
            nativeMacSidebarView,
            "HoshiAppIconGlyph",
            "native home sidebar should not show an in-app app icon glyph"
        )
        assertContains(
            xcodeProject,
            "48AA10502FAA000100000001 /* Assets.xcassets in Resources */",
            "native target should include the shared asset catalog for app icon support"
        )
        assertContains(
            xcodeProject,
            "48AA10512FAA000100000001 /* HoshiIcon.icon in Resources */",
            "native target should include the HoshiIcon.icon resource"
        )
        assertOccurrenceCountAtLeast(
            xcodeProject,
            "ASSETCATALOG_COMPILER_APPICON_NAME = HoshiIcon;",
            2,
            "native target should use the HoshiIcon app icon in Debug and Release"
        )
        assertContains(
            nativeBuildScript,
            "refresh_app_icon_registration",
            "native build harness should refresh Finder/Dock app icon registration after builds"
        )
        assertContains(
            nativeBuildScript,
            "lsregister\" -f \"$APP_BUNDLE\"",
            "native build harness should re-register the app bundle with LaunchServices"
        )
        for key in ["Bookshelf", "Bookshelf and sync", "Dictionary search", "App settings", "Niratan"] {
            assertLocalized(
                localizationStrings,
                key,
                languages: ["en", "zh-Hans"],
                "native home navigation should have English and Simplified Chinese localization"
            )
        }

        assertContains(
            nativeReader,
            "ReaderViewportGeometry.selectionRect",
            "native Reader should use the shared selection rect conversion"
        )
        assertContains(
            nativeReader,
            "static func cgFloatValue(_ value: Any?) -> CGFloat?",
            "native Reader should decode WKScriptMessage numeric coordinates regardless of NSNumber or Double bridging"
        )
        assertContains(
            nativeReader,
            "Self.cgFloatValue(rectData[\"x\"])",
            "native Reader should use robust numeric decoding for the selected character x coordinate"
        )
        assertContains(
            nativeReader,
            "Self.cgFloatValue(rectData[\"y\"])",
            "native Reader should use robust numeric decoding for the selected character y coordinate"
        )
        assertContains(
            nativeReader,
            "let shouldSubtractVerticalScrollOffset = parent.userConfig.verticalWriting",
            "horizontal Reader popup placement should not subtract WKWebView visibleRect origin from viewport rects"
        )
        assertNotContains(
            nativeReader,
            "!parent.userConfig.continuousMode || parent.userConfig.verticalWriting",
            "horizontal paged Reader popup placement should not treat non-continuous mode as a scroll-offset correction"
        )
        assertNotContains(nativeReader, "mouseLocationOutsideOfEventStream", "native Reader should not use current AppKit mouse location for popup placement because it is not stable")
        assertNotContains(nativeReader, "body[\"anchorPoint\"]", "native Reader should not decode click-point anchors for popup placement")
        assertNotContains(nativeReader, "body[\"lineRect\"]", "native Reader should not decode expanded line rects for popup placement")
        assertNotContains(
            nativeReader,
            "useHorizontalLineAnchor:",
            "native Reader must not replace the selected word anchor with the visual line rect"
        )
        let popupModels = try String(
            contentsOf: root.appendingPathComponent("Features/Popup/PopupModels.swift"),
            encoding: .utf8
        )
        let popupLayoutSection = sourceSection(
            popupModels,
            from: "struct PopupLayout",
            to: "struct SelectionData",
            "Popup layout should stay in PopupModels.swift"
        )
        assertNotContains(popupModels, "let avoidanceRect: CGRect?", "Reader popup selection data should not carry line avoidance rects")
        assertNotContains(popupModels, "let anchorPoint: CGPoint?", "Reader popup selection data should not carry unstable click-point anchors")
        assertContains(
            popupLayoutSection,
            "selectionRect.minY - topInset - popupPadding",
            "Horizontal popup layout should measure space above from the selected character top edge"
        )
        assertContains(
            popupLayoutSection,
            "screenSize.height - bottomInset - selectionRect.maxY - popupPadding",
            "Horizontal popup layout should measure space below from the selected character bottom edge"
        )
        assertContains(
            popupLayoutSection,
            "spaceBelow >= spaceAbove || spaceBelow >= maxHeight",
            "Horizontal popup should choose the side with room before computing height"
        )
        assertContains(
            popupLayoutSection,
            "let availableHeight = showBelow ? spaceBelow : spaceAbove",
            "Horizontal popup height should be limited by the side it actually uses"
        )
        assertContains(
            popupLayoutSection,
            "selectionRect.maxY + popupPadding + (height / 2)",
            "Horizontal popup should open directly below the selected character bottom edge"
        )
        assertContains(
            popupLayoutSection,
            "selectionRect.minY - popupPadding - (height / 2)",
            "Horizontal popup should open directly above the selected character top edge"
        )
        assertNotContains(popupView, "avoidanceRect: selectionData.avoidanceRect", "PopupView should not pass unstable line avoidance rects into PopupLayout")
        assertNotContains(popupView, "anchorPoint: selectionData.anchorPoint", "PopupView should not pass unstable click anchors into PopupLayout")
        assertContains(
            popupView,
            "let showsActionBar = userConfig.popupActionBar || backCount > 0 || forwardCount > 0",
            "popup history controls should appear after an internal redirect even when the persistent action-bar preference is off"
        )
        assertContains(
            popupView,
            "sasayakiControls(for: cue, player: player, includesActionBar: showsActionBar)",
            "popup history and close controls should share the Sasayaki control row when audio is available"
        )
        assertContains(
            popupView,
            ".buttonStyle(.plain)",
            "popup control buttons should keep transparent hit frames without individual button backgrounds"
        )
        assertContains(
            nativeReader,
            ".hoshi-sasayaki-cue.hoshi-sasayaki-active",
            "native Reader should style active Sasayaki cues"
        )
        assertContains(
            nativeReader,
            "background-color: var(--hoshi-sasayaki-background-color)",
            "native Reader should apply the configured Sasayaki highlight background"
        )
        assertContains(
            nativeReader,
            "isVertical: false",
            "native nested popup selections should use horizontal popup layout"
        )
        assertContains(
            nativeReader,
            "isFullWidth: false",
            "native nested popup selections should avoid full-width Reader popup layout"
        )
        assertContains(
            nativeReader,
            "var sepiaInverted: Bool",
            "native Reader should support sepia dark inversion"
        )
        assertContains(
            nativeReader,
            "effectiveReaderColorScheme == .dark ?",
            "native Reader should derive Sasayaki colors from the effective reader theme"
        )
        assertContains(
            nativeReader,
            ".preferredColorScheme(readerPreferredColorScheme)",
            "native Reader should leave System and inverted Sepia unforced so the independent window follows macOS appearance changes"
        )
        assertContains(
            nativeReader,
            "var effectiveReaderColorScheme: ColorScheme",
            "native Reader should resolve effective colors separately from its optional appearance override"
        )
        assertNotContains(
            nativeReader,
            ".preferredColorScheme(readerTheme)",
            "native Reader must not feed an inherited color scheme back as a fixed window preference"
        )
        assertContains(
            nativeReader,
            "context.coordinator.syncTextColor()",
            "native Reader should update WebView text color when theme changes without reloading"
        )
        assertContains(
            nativeReader,
            "static func textColorScript(_ hex: String?) -> String",
            "native Reader should use a single set/remove text color script for theme isolation"
        )
        assertContains(
            nativeReader,
            "document.documentElement.style.removeProperty('--hoshi-text-color')",
            "native Reader should clear sepia/custom text color when switching to a normal theme"
        )
        assertContains(
            nativeReader,
            "userConfig.usesDarkSepia(in: systemColorScheme)",
            "native Reader should use dark sepia only for the sepia theme in macOS Dark Mode"
        )
        assertContains(
            nativeReader,
            "context.coordinator.syncBackgroundColor()",
            "native Reader should update the page background when the theme or macOS appearance changes"
        )
        assertContains(
            nativeApp,
            "userConfig.preferredColorScheme",
            "native app appearance should share the follow-system theme rule"
        )
        assertContains(
            nativeReader,
            "nativeReaderGlassCapsuleControl",
            "native Reader bottom controls should use Liquid Glass capsule surfaces"
        )
        assertContains(
            nativeReader,
            "NativeSettingsDetailView(section: .appearance",
            "native Reader Appearance sheet should reuse the same Settings detail component"
        )
        assertNotContains(
            nativeReader,
            "NativeGlassCircleButton(systemName: \"chevron.left\", diameter: 34, fontSize: 18)",
            "native Reader should not render a bottom-left close/back button because the Reader window has standard traffic-light controls"
        )
        assertNotContains(
            nativeReader,
            "NativeReaderGlassGroup",
            "native Reader bottom page-turn button group should be removed"
        )
        assertContains(
            nativeReader,
            "userConfig.readerShowProgressTop && !progressString.isEmpty",
            "native Reader should only show top progress when Appearance requests top progress"
        )
        assertContains(
            nativeReader,
            "!userConfig.readerShowProgressTop && !progressString.isEmpty",
            "native Reader should show bottom progress when Appearance requests bottom progress"
        )
        assertContains(
            nativeReader,
            "userConfig.readerProgressCount != .off",
            "native Reader progress should respect the progress count setting"
        )
        assertContains(
            nativeReader,
            "userConfig.readerShowPercentage",
            "native Reader progress should respect the percentage visibility setting"
        )
        assertContains(
            nativeReader,
            "let readerSize = CGSize(\n                width: max(geometry.size.width.rounded(), 1)",
            "native Reader should size WebKit from the complete available viewport"
        )
        assertContains(
            nativeReader,
            "viewSize: readerSize",
            "native Reader pagination should use the same complete viewport size as WebKit"
        )
        for identityInput in [
            "userConfig.readerFuriganaMode",
            "userConfig.horizontalPadding",
            "userConfig.verticalPadding",
            "userConfig.avoidPageBreak",
            "userConfig.justifyText",
            "userConfig.blurImages",
            "userConfig.layoutAdvanced",
            "userConfig.lineHeight",
            "userConfig.characterSpacing",
            "userConfig.paragraphSpacing",
        ] {
            assertContains(
                readerIdentityBlock,
                identityInput,
                "native Reader reload identity should include layout-affecting setting: \(identityInput)"
            )
        }
        assertContains(
            nativeReader,
            ".frame(width: geometry.size.width, height: geometry.size.height)",
            "native Reader WebView should fill the complete available viewport"
        )
        assertContains(
            nativeReader,
            ".background(readerBackgroundColor.ignoresSafeArea())\n        .overlay {",
            "native Reader background should extend behind the transparent window chrome while overlays stay controlled by Reader layout"
        )
        assertNotContains(
            nativeReader,
            ".ignoresSafeArea(edges: .top)",
            "native Reader should rely on the Reader window's full-size transparent chrome instead of a manual top safe-area override"
        )
        assertNotContains(
            nativeReader,
            ".ignoresSafeArea(edges: [.top, .bottom])",
            "native Reader should not extend into top and bottom safe areas as one coupled text viewport"
        )
        assertNotContains(
            nativeReader,
            ".ignoresSafeArea(edges: [.leading, .trailing])",
            "native Reader text viewport should stay inside the GeometryReader safe viewport instead of entering rounded window edges"
        )
        for forbidden in [
            "NativeReaderChromeMetrics",
            "NativeReaderWebContainerView",
            "NativeReaderPassthroughMaskView",
            "readerWebViewSideInset",
            "viewportOrigin",
            "visualSideInset",
            "visualBottomInset",
            "textComfortPadding",
            "sideTextInset",
            "bottomTextInset",
        ] {
            assertNotContains(
                nativeReader,
                forbidden,
                "native Reader should not reserve fixed visual insets or mask full-viewport text: \(forbidden)"
            )
        }
        assertContains(
            nativeReader,
            "adjustedContentInset: .zero",
            "native Reader popup coordinates should share the full WebView viewport origin"
        )
        assertContains(
            nativeReader,
            #"padding: \(verticalPadding / 2)vh \(horizontalPadding / 2)vw !important;"#,
            "native Reader body padding should only reflect the user's layout settings"
        )
        assertContains(
            nativeReader,
            "img.block-img {\n                max-width: \\(imgWidth) !important;",
            "native Reader should keep large raster images on the v0.5.0 block-image sizing path"
        )
        assertContains(
            nativeReader,
            "svg {\n                max-width: \\(imgWidth) !important;",
            "native Reader should keep SVG image containers on the v0.5.0 sizing path"
        )
        assertContains(
            nativeReader,
            "svg {\n                max-width: \\(imgWidth) !important;\n                max-height: \\(imgHeight) !important;\n                width: 100% !important;\n                height: 100% !important;",
            "native Reader SVGs should fill their constrained container like v0.5.0 instead of inheriting raster auto sizing"
        )
        assertContains(
            nativeReader,
            #"let imgWidth = parent.userConfig.continuousMode"#,
            "native Reader should compute image width separately for paginated and continuous modes"
        )
        assertContains(
            nativeReader,
            #"? (parent.userConfig.verticalWriting ? "none" : "\(100 - horizontalPadding)vw")"#,
            "native Reader continuous images should match v0.5.0 by limiting only the cross axis width"
        )
        assertContains(
            nativeReader,
            #"? (parent.userConfig.verticalWriting ? "calc(\(100 - verticalPadding)vh - \(Double(bottomOverlap) * (100 - verticalPadding) / 100)px)" : "none")"#,
            "native Reader continuous images should match v0.5.0 by limiting only the cross axis height"
        )
        assertNotContains(
            nativeReader,
            "img.block-img, svg {\n                max-width: \\(imgWidth) !important;",
            "native Reader should not merge raster and SVG image rules because their width/height semantics differ"
        )
        assertContains(
            nativeReader,
            "html, body {\n                margin: 0 !important;\n                padding: 0 !important;\n                color: var(--hoshi-text-color) !important;\n                writing-mode: \\(writingMode) !important;\n                -webkit-writing-mode: \\(writingMode) !important;\n                \\(rootOverflowCss)",
            "native Reader root CSS should match the Catalyst viewport contract without applying columns to html"
        )
        assertContains(
            nativeReader,
            "let paginatedHtmlHeightCss = parent.userConfig.continuousMode ? \"\"",
            "native Reader should apply fixed html viewport height only in paginated mode"
        )
        assertContains(
            nativeReader,
            "let bodyPageHeightCss = parent.userConfig.continuousMode ? \"\" : \"height: var(--page-height, 100vh) !important;\"",
            "native Reader should apply fixed body page height only in paginated mode"
        )
        assertContains(
            nativeReader,
            "\\(bodyColumnCss)",
            "native Reader should apply paginated column geometry only to body"
        )
        assertContains(
            nativeReader,
            "let bottomOverlap = parent.userConfig.verticalWriting ? parent.userConfig.fontSize : 0",
            "native Reader vertical pagination should keep only the Catalyst font-derived bottom overlap"
        )
        assertContains(
            nativeReader,
            "? \"calc(\\(verticalPadding)vh + \\(bottomOverlap)px)\"",
            "native Reader vertical column gap should derive from user padding and the font overlap"
        )
        assertContains(
            nativeReader,
            "? \"\\(horizontalSpreadColumnGap)px\" : \"\\(horizontalPadding)vw\"",
            "native Reader should fix the two-column center gutter while preserving user padding for single-column page gaps"
        )
        assertNotContains(
            paginatedReaderScript,
            "maxAlignedScroll",
            "paginated Reader navigation should not discard a final partial page"
        )
        assertContains(
            paginatedReaderScript,
            "currentScroll >= (context.maxScroll - context.limitTolerance)",
            "paginated Reader should report the chapter limit at the true scroll boundary with the active layout tolerance"
        )
        assertContains(
            paginatedReaderScript,
            "Math.min(currentScroll + context.pageSize, context.maxScroll)",
            "paginated Reader should navigate into a final partial page before changing chapters"
        )
        assertContains(
            shortcutManager,
            "func handleKeyDown(_ event: NSEvent) -> Bool",
            "ShortcutManager should expose the unified dispatcher to focused AppKit controls"
        )
        assertContains(
            nativeReader,
            "final class NativeReaderWKWebView: HoshiShiftHoverWKWebView",
            "native Reader WKWebView should capture keyDown while focused"
        )
        assertContains(
            nativeReader,
            "if shortcutManager?.handleKeyDown(event) == true { return }",
            "native Reader WKWebView should consume handled shortcuts before WebKit native scrolling"
        )
        assertContains(
            shortcutManager,
            "handle(event, source: .localMonitor)",
            "the local monitor must identify its dispatch source"
        )
        assertContains(
            shortcutManager,
            "static var sharedMonitor: Any?",
            "ShortcutManager should install only one process-wide AppKit local monitor"
        )
        assertContains(
            shortcutManager,
            "static var installedManagers: [InstalledManager]",
            "ShortcutManager should dispatch the shared local monitor to installed managers"
        )
        assertContains(
            shortcutManager,
            "for entry in installedManagers.reversed()",
            "ShortcutManager should give the most recently installed matching window manager the first chance to handle a key event"
        )
        assertContains(
            shortcutManager,
            "manager.managedWindow === event.window",
            "ShortcutManager shared monitor should route events only to managers that own the event window"
        )
        assertNotContains(
            shortcutManager,
            "protocol ShortcutEventDispatchResponder",
            "ShortcutManager should not need a second marker protocol after routing the shared monitor by window"
        )
        assertNotContains(
            shortcutManager,
            "private var monitor: Any?",
            "ShortcutManager instances should not each install their own local monitor"
        )
        assertNotContains(
            shortcutManager,
            "handledEventSignature",
            "mutually exclusive dispatch paths must not rely on timestamp deduplication"
        )
        assertContains(
            nativeReader,
            "var canHandleSasayakiShortcut: Bool {\n        (activeSheet == nil || activeSheet == .sasayaki)",
            "Sasayaki playback shortcuts should keep working while the Sasayaki sheet is open"
        )
        assertNotContains(
            shortcutManager,
            ".eventNumber",
            "keyboard shortcut dispatch must not query NSEvent.eventNumber because AppKit asserts for key events"
        )
        assertContains(
            nativeReader,
            "shortcutManager: shortcutManager",
            "native Reader WebView should use the shared ShortcutManager instead of a private shortcut path"
        )
        assertContains(
            nativeReader,
            "nativeBottomControls\n                .ignoresSafeArea(edges: .bottom)",
            "native Reader bottom chrome should extend into the bottom safe area"
        )
        assertContains(
            nativeReader,
            ".padding(.bottom, 18)",
            "native Reader bottom controls should sit closer to the bottom edge"
        )
        assertContains(
            nativeReader,
            "nativeBottomInfoOverlay",
            "native Reader should have a bottom progress overlay"
        )
        assertContains(
            nativeReader,
            "private struct NativeReaderPosition",
            "native Reader should model jump destinations"
        )
        assertContains(
            nativeReader,
            "var backHistory: [NativeReaderPosition] = []",
            "native Reader should retain backward jump history"
        )
        assertContains(
            nativeReader,
            "var forwardHistory: [NativeReaderPosition] = []",
            "native Reader should retain forward jump history"
        )
        assertOccurrenceCountAtLeast(
            nativeReader,
            "recordPosition()",
            4,
            "chapter, character/highlight, and internal-link jumps should record their origin"
        )
        assertContains(
            nativeReader,
            "func navigateBackwards()",
            "native Reader should restore a backward jump destination"
        )
        assertContains(
            nativeReader,
            "func navigateForwards()",
            "native Reader should restore a forward jump destination"
        )
        assertContains(
            nativeReader,
            "func handleManualNavigation()",
            "manual Reader navigation should invalidate stale forward history"
        )
        assertContains(
            nativeReader,
            "reader.statistics.pageTurn",
            "manual Reader navigation should log page-turn statistics boundaries"
        )
        assertContains(
            nativeReader,
            "arrow.uturn.backward.circle",
            "native Reader should show the backward progress control"
        )
        assertContains(
            nativeReader,
            "model.navigateBackwards()",
            "native Reader backward progress control should restore its destination"
        )
        assertContains(
            nativeReader,
            "arrow.uturn.right.circle",
            "native Reader should show the forward progress control"
        )
        assertContains(
            nativeReader,
            "model.navigateForwards()",
            "native Reader forward progress control should restore its destination"
        )
        assertContains(
            nativeReader,
            "contentLanguage.displayCount(forRawCharacters: target)",
            "native Reader history controls should use the active Profile's display units"
        )
        assertContains(
            nativeReader,
            "func persistBookmark(_ newProgress: Double)",
            "native Reader should separate bookmark persistence from reading-statistics checkpoints"
        )
        assertContains(
            nativeReader,
            "func establishProgrammaticDestination(_ progress: Double)",
            "programmatic Reader navigation should persist its destination and reset the statistics baseline"
        )
        assertOccurrenceCountAtLeast(
            nativeReader,
            "establishProgrammaticDestination(",
            5,
            "chapter, character/highlight, history, and link jumps should establish a non-reading destination"
        )
        assertContains(
            nativeReader,
            "func syncProgressAfterProgrammaticJump(_ progress: Double)",
            "fragment jumps should synchronize their resolved progress without counting the jump distance"
        )
        assertContains(
            nativeReader,
            "func syncBookmarkToSasayakiCue(_ cue: SasayakiMatch)",
            "Sasayaki cue jumps should persist the matching Reader bookmark destination"
        )
        assertContains(
            nativeReader,
            "var onInternalJump: (Double) -> Void",
            "native Reader WebView should distinguish resolved internal jumps from ordinary reading progress"
        )
        assertContains(
            nativeReader,
            "onInternalJump: model.syncProgressAfterProgrammaticJump",
            "native Reader should route resolved internal jumps through the programmatic statistics boundary"
        )
        assertContains(
            nativeReader,
            "if spineIndex == index",
            "same-chapter internal links should restore inside the current WebView instead of reloading the chapter"
        )
        let explicitJumpSection = sourceSection(
            nativeReader,
            from: "func jumpToCharacter(_ characterCount: Int)",
            to: "func navigateBackwards()",
            "native Reader should expose the explicit jump section"
        )
        assertNotContains(
            explicitJumpSection,
            "saveBookmark(",
            "chapter and character/highlight jumps must not count their destination as reading"
        )
        let internalLinkSection = sourceSection(
            nativeReader,
            from: "func jumpToLink(_ url: URL) -> Bool",
            to: "func recordPosition()",
            "native Reader should expose the internal-link jump section"
        )
        assertNotContains(
            internalLinkSection,
            "saveBookmark(",
            "internal-link jumps must not count their destination as reading"
        )
        let historyRestoreSection = sourceSection(
            nativeReader,
            from: "func restorePosition(_ position: NativeReaderPosition)",
            to: "func characterProgress(for position: NativeReaderPosition)",
            "native Reader should expose the history restoration section"
        )
        assertContains(
            historyRestoreSection,
            "establishProgrammaticDestination(progress)",
            "history restoration should establish a new non-reading statistics baseline"
        )
        assertNotContains(
            historyRestoreSection,
            "saveBookmark(",
            "history restoration must not count its destination as reading"
        )
        assertContains(
            nativeReader,
            "var statisticsString: String",
            "native Reader should format session statistics for its information chrome"
        )
        assertContains(
            nativeReader,
            "Logger(subsystem: \"moe.shishamo.hoshi\", category: \"ReaderStatistics\")",
            "Reader statistics should expose structured diagnostics for zero-character sessions"
        )
        assertContains(
            nativeReader,
            "reader.statistics.update",
            "native Reader should log statistics deltas before applying them"
        )
        assertContains(
            nativeReader,
            "reader.statistics.zeroCharacterPosition",
            "native Reader should log when statistics are running on a zero-character Reader position"
        )
        assertContains(
            nativeReader,
            "reader.statistics.save.success",
            "native Reader should log successful statistics writes"
        )
        assertContains(
            nativeReader,
            "reader.statistics.save.failure",
            "native Reader should log failed statistics writes instead of silently dropping them"
        )
        assertContains(
            nativeReader,
            "guard userConfig.enableStatistics else { return \"\" }",
            "native Reader should not show session statistics when Statistics is disabled"
        )
        assertContains(
            nativeReader,
            "if userConfig.readerShowReadingSpeed",
            "native Reader should honor the Show Reading Speed setting"
        )
        assertContains(
            nativeReader,
            "contentLanguage.displayCount(forRawCharacters: model.sessionStatistics.readingSpeed)",
            "native Reader speed should use the active Profile's display units"
        )
        assertContains(
            nativeReader,
            "if userConfig.readerShowReadingTime",
            "native Reader should honor the Show Reading Time setting"
        )
        assertContains(
            nativeReader,
            "Duration.seconds(model.sessionStatistics.readingTime)",
            "native Reader should format the current session reading time"
        )
        assertContains(
            nativeReader,
            "var isReaderWindowActive = false\n    private var isStatisticsSheetActive = false\n    private var isReaderContentCovered = false",
            "native Reader should retain focus sources plus explicit covered-content state"
        )
        assertContains(
            nativeReader,
            "var isStatisticsContextActive: Bool {\n        isStatisticsSheetActive || (isReaderWindowActive && !isReaderContentCovered)\n    }",
            "native Reader should count only on an approved, unobscured reading or statistics surface"
        )
        let statisticsStartSection = sourceSection(
            nativeReader,
            from: "func startTracking()",
            to: "func stopTracking()",
            "native Reader should expose statistics start behavior"
        )
        assertContains(
            statisticsStartSection,
            "isTracking = true\n        isPaused = !isStatisticsContextActive\n        resetTrackingBaseline()",
            "statistics started outside both approved focus surfaces should wait in a paused state"
        )
        let statisticsFocusSection = sourceSection(
            nativeReader,
            from: "func updateReaderWindowActivity(_ isActive: Bool)",
            to: "func toggleStatisticsTracking()",
            "native Reader should expose aggregate statistics focus reconciliation"
        )
        assertContains(
            statisticsFocusSection,
            "func updateReaderWindowActivity(_ isActive: Bool) {\n        isReaderWindowActive = isActive\n        reconcileStatisticsFocus()\n    }",
            "Reader-window focus should update its source before reconciliation"
        )
        assertContains(
            statisticsFocusSection,
            "func updateStatisticsSheetActivity(_ isActive: Bool) {\n        isStatisticsSheetActive = isActive\n        reconcileStatisticsFocus()\n    }",
            "Statistics-sheet focus should update its source before reconciliation"
        )
        assertContains(
            statisticsFocusSection,
            "func updateReaderContentCovered(_ isCovered: Bool) {\n        isReaderContentCovered = isCovered\n        reconcileStatisticsFocus()\n    }",
            "Reader sheets and full-screen images should explicitly pause and resume statistics"
        )
        assertContains(
            statisticsFocusSection,
            "if isStatisticsContextActive {\n            guard isTracking, isPaused else { return }\n            resetTrackingBaseline()\n            isPaused = false\n            return\n        }",
            "aggregate focus gain should reset the baseline before resuming an existing session"
        )
        assertContains(
            statisticsFocusSection,
            "guard isTracking, !isPaused else { return }\n        flushStats()\n        isPaused = true",
            "aggregate focus loss should flush foreground time before pausing"
        )
        assertContains(
            nativeReader,
            ".onChange(of: isActive, initial: true) { _, isActive in\n            updateKeyboardShortcutRegistration(isActive: isActive)\n            model.updateReaderWindowActivity(isActive)\n        }",
            "Reader key-window changes should keep shortcut and statistics focus responsibilities separate"
        )
        let statisticsSheetSection = sourceSection(
            nativeReader,
            from: "struct NativeReaderStatisticsSheet: View",
            to: "struct NativeReaderGlassIconButton: View",
            "native Reader should expose an observable Statistics sheet wrapper"
        )
        assertContains(
            statisticsSheetSection,
            "let model: NativeReaderModel",
            "Statistics sheet wrapper should observe the Reader model directly"
        )
        assertContains(
            statisticsSheetSection,
            "ReaderStatisticsContentView(\n            sessionStatistics: model.sessionStatistics,\n            todaysStatistics: model.todaysStatistics,\n            allTimeStatistics: model.allTimeStatistics",
            "Statistics sheet wrapper should pass fresh model values into the presentation view"
        )
        assertContains(
            statisticsSheetSection,
            "NativeWindowActivityReader { _, isKey in\n                model.updateStatisticsSheetActivity(isKey)\n            }",
            "Statistics sheet should reuse the existing window-activity reader for its own key state"
        )
        assertContains(
            statisticsSheetSection,
            ".onDisappear {\n            model.updateStatisticsSheetActivity(false)\n        }",
            "Statistics sheet dismissal should clear its focus source"
        )
        assertContains(
            nativeReader,
            "NativeReaderSidePanel(edge: .trailing",
            "native Reader should present Statistics in the trailing side panel"
        )
        assertContains(
            nativeReader,
            "} else {\n                        NativeReaderStatisticsSheet(",
            "native Reader should present the observable Statistics sheet wrapper"
        )
        assertContains(
            nativeReader,
            ".onChange(of: model.imageURL, initial: true) { _, _ in\n            updateReaderContentCoverage()\n        }",
            "full-screen Reader image presentation should participate in statistics activity"
        )
        assertContains(
            nativeReader,
            "let nonStatisticsSheetIsOpen = activeSheet != nil && activeSheet != .statistics",
            "non-statistics Reader sheets should cover reading while the live Statistics sheet remains an approved context"
        )
        assertNotContains(
            statisticsSheetSection,
            "TimelineView",
            "Statistics sheet should rely on model observation instead of a second timer"
        )
        assertContains(
            nativeReader,
            "guard !isTracking else {\n            startStatisticsTimerIfNeeded()",
            "an already-started model-owned statistics task should remain alive while focus temporarily pauses updates"
        )
        assertContains(
            nativeReader,
            "if !self.isPaused {\n                    self.updateStats()",
            "the model-owned statistics timer should skip updates while focus temporarily pauses tracking"
        )
        assertContains(
            nativeReader,
            "let showStatistics = !statisticsString.isEmpty",
            "native Reader bottom information should render enabled session statistics"
        )
        assertContains(
            nativeReader,
            "var statisticsAutostartMode: StatisticsAutostartMode = .off",
            "native Reader should retain the configured statistics autostart mode for every navigation source"
        )
        assertContains(
            nativeReader,
            "statisticsAutostartMode = userConfig.statisticsAutostartMode",
            "native Reader should configure its shared page-turn statistics policy"
        )
        assertContains(
            nativeReader,
            "func startTrackingOnPageTurnIfNeeded() {\n        if statisticsAutostartMode == .pageturn && !isTracking",
            "native Reader page-turn statistics should use the model's configured policy"
        )
        let sasayakiChapterLoadSection = sourceSection(
            nativeReader,
            from: "func loadChapterForSasayaki(index: Int)",
            to: "func loadCurrentChapterState()",
            "native Reader should expose the Sasayaki cross-chapter load boundary"
        )
        assertContains(
            sasayakiChapterLoadSection,
            "let progress = sasayakiCueProgress(for: index) ?? 0",
            "Sasayaki cross-chapter navigation should restore the target cue instead of chapter progress zero"
        )
        assertContains(
            sasayakiChapterLoadSection,
            "startTrackingOnPageTurnIfNeeded()",
            "Sasayaki cross-chapter navigation should start page-turn statistics"
        )
        assertContains(
            sasayakiChapterLoadSection,
            "flushStats()",
            "Sasayaki cross-chapter navigation should flush the old reading position before moving"
        )
        assertContains(
            sasayakiChapterLoadSection,
            "establishProgrammaticDestination(progress)",
            "Sasayaki cross-chapter navigation should persist a non-reading destination and reset its statistics baseline"
        )
        assertNotContains(
            sasayakiChapterLoadSection,
            "saveBookmark(progress)",
            "Sasayaki cross-chapter navigation must not flush statistics again from the destination"
        )
        assertContains(
            nativeReader,
            "func sasayakiCueProgress(for chapterIndex: Int) -> Double?",
            "native Reader should derive cross-chapter progress from the pending Sasayaki cue"
        )
        assertContains(
            sasayakiPlayer,
            "let loadChapter: (Int) -> Void",
            "Sasayaki should let the Reader resolve chapter progress from the pending cue"
        )
        assertNotContains(
            sasayakiPlayer,
            "loadChapter(cue.chapterIndex, 0)",
            "Sasayaki must not force cross-chapter cue navigation to progress zero"
        )
        let sasayakiRestoreSection = sourceSection(
            sasayakiPlayer,
            from: "func handleRestoreCompleted(currentIndex: Int)",
            to: "func prepareTransition()",
            "Sasayaki player should expose the reader restore-completion handler"
        )
        assertNotContains(
            sasayakiRestoreSection,
            "guard hasMatch, chapterTransition else { return }",
            "Sasayaki restore should also highlight the saved cue on first Reader open"
        )
        assertContains(
            sasayakiRestoreSection,
            "timeline.cue(at: currentTime - delay)",
            "Sasayaki restore should resolve the saved playback position into an active cue"
        )
        assertContains(
            sasayakiRestoreSection,
            "revealCue = resume && autoScroll",
            "paused audio restore should not scroll to the active cue until playback resumes"
        )
        let togglePlaybackSection = sourceSection(
            sasayakiPlayer,
            from: "func togglePlayback()",
            to: "func updatePlaybackActivity()",
            "Sasayaki player should expose play/pause behavior"
        )
        assertContains(
            togglePlaybackSection,
            "displayCue(currentCue, reveal: true)",
            "resuming Sasayaki in the same chapter should reveal the active cue"
        )
        assertContains(
            sasayakiPlayer,
            "func nextCueMatch(after time: Double) -> SasayakiMatch?",
            "Sasayaki manual next-cue navigation should resolve the target cue, not only its timestamp"
        )
        assertContains(
            sasayakiPlayer,
            "func prevCueMatch(before time: Double) -> SasayakiMatch?",
            "Sasayaki manual previous-cue navigation should resolve the target cue, not only its timestamp"
        )
        assertContains(
            sasayakiPlayer,
            "func navigateToCue(_ cue: SasayakiMatch,",
            "Sasayaki manual cue navigation should handle cross-chapter targets explicitly"
        )
        assertContains(
            sasayakiPlayer,
            "revealPendingCueOnRestore",
            "Sasayaki manual cross-chapter navigation should reveal the pending cue after the Reader restores"
        )
        let nextCueSection = sourceSection(
            sasayakiPlayer,
            from: "func nextCue()",
            to: "func prevCue()",
            "Sasayaki next-cue shortcut should use cue-aware navigation"
        )
        assertContains(
            nextCueSection,
            "timeline.nextCueMatch",
            "Sasayaki next-cue shortcut should keep the target chapter information"
        )
        assertContains(
            nextCueSection,
            "navigateToCue",
            "Sasayaki next-cue shortcut should route cross-chapter targets through the navigation helper"
        )
        let prevCueSection = sourceSection(
            sasayakiPlayer,
            from: "func prevCue()",
            to: "func skip(forward: Bool)",
            "Sasayaki previous-cue shortcut should use cue-aware navigation"
        )
        assertContains(
            prevCueSection,
            "timeline.prevCueMatch",
            "Sasayaki previous-cue shortcut should keep the target chapter information"
        )
        assertContains(
            prevCueSection,
            "navigateToCue",
            "Sasayaki previous-cue shortcut should route cross-chapter targets through the navigation helper"
        )
        assertOccurrenceCountAtLeast(
            nativeReader,
            "self.parent.onPageTurn()\n                        self.parent.onProgressChanged",
            2,
            "Sasayaki same-chapter auto-scroll should start statistics only when WebView reports changed progress"
        )
        let jumpToCueSection = sourceSection(
            nativeReader,
            from: "func jumpToSasayakiCue()",
            to: "var body: some View",
            "native Reader should expose the popup Sasayaki jump path"
        )
        assertContains(
            jumpToCueSection,
            "model.syncBookmarkToSasayakiCue(cue)",
            "the j Sasayaki shortcut should persist the cue's Reader bookmark destination"
        )
        let popupLayerSection = sourceSection(
            nativeReader,
            from: "func popupLayer(screenSize: CGSize)",
            to: "var nativeTopInfoOverlay",
            "native Reader should wire popup dismissal callbacks"
        )
        assertContains(
            popupLayerSection,
            "if let cue = popup.sasayakiCue {\n                        model.syncBookmarkToSasayakiCue(cue)\n                    }",
            "Reader popup Sasayaki jump dismissal should persist the cue's Reader bookmark destination"
        )
        assertContains(
            nativeReader,
            ".overlay(alignment: .top) {",
            "native Reader top info overlay should be centered instead of pinned to the top trailing corner"
        )
        assertNotContains(
            nativeReader,
            ".overlay(alignment: .topTrailing)",
            "native Reader top info overlay should not be pinned to the top trailing corner"
        )
        assertContains(
            nativeReader,
            "VStack(alignment: .center, spacing: 2)",
            "native Reader top info text should be centered"
        )
        assertContains(
            nativeReader,
            "var nativeBottomControls: some View {\n        if !focusMode {\n            ZStack {\n                nativeBottomInfoOverlay",
            "native Reader bottom progress should share the same vertical row as bottom controls"
        )
        assertNotContains(
            nativeReader,
            "nativeReaderGlassCapsuleSurface",
            "native Reader title and progress use upstream's plain bar text instead of glass capsules"
        )
        assertContains(
            nativeReader,
            "if !focusMode && model.imageURL == nil {",
            "native Reader edge effects should follow upstream and hide with the bars"
        )
        assertNotContains(
            nativeReader,
            ".background(.thinMaterial, in: Capsule())",
            "native Reader info capsules should not use plain thinMaterial backgrounds"
        )
        assertNotContains(
            nativeReader,
            "model.progressString",
            "native Reader should not use a model-level progress string that ignores Appearance settings"
        )
        assertContains(
            nativeReader,
            "NativeGlassCircleButton(systemName: \"xmark\"",
            "native Reader Appearance sheet should expose a glass close button"
        )
        assertContains(
            nativeFullscreenImageView,
            "NativeGlassCircleButton(systemName: \"xmark\", diameter: 38, fontSize: 15)",
            "native Reader fullscreen image overlay should use the shared Liquid Glass close button"
        )
        assertNotContains(
            nativeFullscreenImageView,
            ".buttonStyle(.borderedProminent)\n            .buttonBorderShape(.circle)",
            "native Reader fullscreen image overlay should not use a plain bordered close button"
        )
        assertContains(
            nativeFullscreenImageWebView,
            "webView.setValue(false, forKey: \"drawsBackground\")",
            "native Reader fullscreen image WebView should disable WebKit's default AppKit white background"
        )
        assertContains(
            nativeReader,
            "scope: .sasayaki",
            "native Reader should register Sasayaki actions with the unified shortcut manager"
        )
        assertContains(
            nativeReader,
            "SasayakiShortcutActions.previousCue.id",
            "native Reader should register the previous Sasayaki cue action"
        )
        assertContains(
            nativeReader,
            "SasayakiShortcutActions.nextCue.id",
            "native Reader should register the next Sasayaki cue action"
        )
        assertNotContains(
            nativeReader,
            "NativeReaderSasayakiShortcutMonitor",
            "native Reader should not restore a feature-private AppKit event monitor"
        )
        assertContains(
            shortcutManager,
            "NSEvent.addLocalMonitorForEvents",
            "the unified shortcut manager should own the AppKit key event monitor"
        )
        assertContains(
            shortcutBridge,
            "case 33: return \"[\"",
            "native shortcut matching should normalize the ANSI left bracket key code"
        )
        assertContains(
            shortcutBridge,
            "case 30: return \"]\"",
            "native shortcut matching should normalize the ANSI right bracket key code"
        )
        assertContains(
            shortcutBridge,
            "\"【\"",
            "native shortcut matching should accept CJK left bracket characters for the default Sasayaki shortcut"
        )
        assertContains(
            shortcutBridge,
            "\"】\"",
            "native shortcut matching should accept CJK right bracket characters for the default Sasayaki shortcut"
        )
        assertContains(
            sasayakiSheet,
            "NativeSettingsForm",
            "native Sasayaki sheet should use the same card form style as Settings"
        )
        assertContains(
            sasayakiSheet,
            "NativeSettingsSectionCard",
            "native Sasayaki sheet should use Settings card sections"
        )
        assertContains(
            sasayakiSheet,
            "NativeReaderInspectorHeader(title: \"Sasayaki\", subtitle: currentChapterTitle, onClose: onDismiss)",
            "native Sasayaki side panel should use the shared Reader side-panel header"
        )
        assertContains(
            nativeReuseViews,
            ".toggleStyle(.switch)",
            "native settings toggles should render as macOS switches instead of checkboxes"
        )
        assertContains(
            nativeReuseViews,
            "struct NativeGlassCircleButton",
            "native Reader sheets should share a macOS glass circle button"
        )
        assertContains(
            nativeReuseViews,
            ".nativeGlassCardSurface(cornerRadius: 18)",
            "native settings cards should participate in macOS Liquid Glass on supported systems"
        )
        assertContains(
            nativeBuildScript,
            "--light|--video)",
            "native launcher should explicitly reject retired build-variant arguments"
        )
        assertNotContains(
            nativeBuildScript,
            "Niratan Video",
            "native launcher should use the single Niratan scheme"
        )
        assertNotContains(
            nativeBuildScript,
            "Debug-Video",
            "native launcher should use the standard Debug product"
        )
        print("reader popup/Sasayaki regressions passed")
    }
}
