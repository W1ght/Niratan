import Foundation
import AppKit

enum ReaderLyricsModeContractTest {
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

    static func assertSystemSymbolAvailable(_ name: String, _ message: String) {
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
            fputs("FAIL: \(message)\nMissing SF Symbol: \(name)\n", stderr)
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
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let nativeReader = try String(
            contentsOf: root.appendingPathComponent("NativeMac/NativeReaderView.swift"),
            encoding: .utf8
        )
        let sasayakiPlayer = try String(
            contentsOf: root.appendingPathComponent("Features/Sasayaki/SasayakiPlayer.swift"),
            encoding: .utf8
        )
        let readerShortcutActions = try String(
            contentsOf: root.appendingPathComponent("Features/Reader/ReaderShortcutActions.swift"),
            encoding: .utf8
        )
        let readerLyricsTextView = try String(
            contentsOf: root.appendingPathComponent("Features/Reader/Lyrics/ReaderLyricsTextView.swift"),
            encoding: .utf8
        )
        let readerLyricsShiftHoverState = try String(
            contentsOf: root.appendingPathComponent("Features/Reader/Lyrics/ReaderLyricsShiftHoverLookupState.swift"),
            encoding: .utf8
        )
        let readerLyricsLayoutMetrics = try String(
            contentsOf: root.appendingPathComponent("Features/Reader/Lyrics/ReaderLyricsLayoutMetrics.swift"),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: root.appendingPathComponent("Niratan.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let localizationData = try Data(contentsOf: root.appendingPathComponent("Localizable.xcstrings"))
        guard let localizationRoot = try JSONSerialization.jsonObject(with: localizationData) as? [String: Any],
              let localizationStrings = localizationRoot["strings"] as? [String: Any] else {
            fputs("FAIL: Localizable.xcstrings should be valid JSON with a strings object\n", stderr)
            exit(1)
        }

        assertContains(
            nativeReader,
            "enum ReaderDisplayMode",
            "native Reader should model the session-only novel/lyrics display mode"
        )
        assertContains(
            nativeReader,
            "case novel",
            "Reader display mode should keep novel mode as the default path"
        )
        assertContains(
            nativeReader,
            "case lyrics",
            "Reader display mode should expose lyrics mode without adding a new window"
        )
        assertContains(
            nativeReader,
            "var displayMode: ReaderDisplayMode = .novel",
            "lyrics mode should be session-scoped and default to novel"
        )
        assertContains(
            nativeReader,
            "var canShowLyricsMode: Bool",
            "native Reader should centralize the SRT-match/audio gate for lyrics mode"
        )
        let canShowLyricsMode = sourceSection(
            nativeReader,
            from: "var canShowLyricsMode: Bool",
            to: "func navigateBackward()",
            "native Reader should define the lyrics availability gate before Reader actions"
        )
        assertContains(
            canShowLyricsMode,
            "userConfig.enableSasayaki",
            "lyrics mode should respect the global Sasayaki setting"
        )
        assertContains(
            canShowLyricsMode,
            "model.sasayakiPlayer?.hasAudio == true",
            "lyrics mode should require imported/restored audio"
        )
        assertContains(
            canShowLyricsMode,
            "model.sasayakiPlayer?.hasMatch == true",
            "lyrics mode v1 should require a completed SRT-to-EPUB match"
        )

        assertContains(
            nativeReader,
            "ReaderLyricsModeView(",
            "native Reader should render a full-screen lyrics layer inside the Reader"
        )
        assertContains(
            nativeReader,
            ".ignoresSafeArea(.container, edges: .top)",
            "lyrics mode should cover the transparent titlebar safe area so no light strip remains at the top"
        )
        assertContains(
            nativeReader,
            "onTapOutside:",
            "lyrics mode should receive a background tap handler for dismissing lookup popups"
        )
        assertContains(
            nativeReader,
            "onSelection(cue, text, offset, selectionRect, false)",
            "lyrics lookup should request above/below anchored popup placement"
        )
        assertContains(
            nativeReader,
            "hoverLookupDelayMs: userConfig.desktopLookupHoverDelayMs",
            "lyrics Shift-hover lookup should use the same configurable delay as native Reader lookup"
        )
        assertContains(
            project,
            "Reader/Lyrics/ReaderLyricsShiftHoverLookupState.swift",
            "lyrics Shift-hover state should be included in the native target synchronized membership"
        )
        assertContains(
            readerLyricsShiftHoverState,
            "struct ReaderLyricsShiftHoverLookupState",
            "lyrics Shift-hover lookup should use a Reader-owned state machine instead of depending on the Video variant"
        )
        assertContains(
            readerLyricsShiftHoverState,
            "static func normalizedDelayMilliseconds(_ value: Int) -> Int",
            "lyrics Shift-hover lookup should clamp the user-configured delay"
        )
        assertContains(
            readerLyricsTextView,
            "NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)",
            "lyrics Shift-hover lookup should observe Shift without consuming the key event"
        )
        assertContains(
            readerLyricsTextView,
            "scheduleShiftHoverLookup(at: point)",
            "lyrics Shift-hover lookup should schedule through the same point-to-character path as click lookup"
        )
        assertContains(
            readerLyricsTextView,
            "ReaderLyricsShiftHoverLookupState.normalizedDelayMilliseconds(hoverLookupDelayMs)",
            "lyrics Shift-hover lookup should honor the configured hover delay"
        )
        assertContains(
            readerLyricsTextView,
            "func popupCoordinateRect(_ rect: NSRect, from sourceView: NSView) -> CGRect",
            "horizontal lyrics lookup should convert AppKit hit rects into popup coordinates inside the AppKit bridge"
        )
        assertContains(
            readerLyricsTextView,
            "let converted = contentView.convert(rect, from: sourceView)",
            "horizontal lyrics lookup should derive popup coordinates from the actual window content view"
        )
        assertContains(
            readerLyricsTextView,
            "let topSafeAreaInset = contentView.safeAreaInsets.top",
            "lyrics lookup should remove the transparent titlebar safe-area offset before handing coordinates to PopupLayout"
        )
        assertContains(
            readerLyricsTextView,
            "ReaderLyricsPopupCoordinateSpace.popupRect(",
            "lyrics lookup should share one safe-area-aware AppKit-to-popup coordinate conversion path"
        )
        assertNotContains(
            readerLyricsTextView,
            "y = contentView.bounds.maxY - converted.maxY",
            "lyrics lookup should not pass raw full-size contentView y coordinates to PopupLayout"
        )
        assertContains(
            readerLyricsTextView,
            "let popupRect = popupCoordinateRect(rect, from: hitTestTextView)",
            "horizontal lyrics lookup should pass the window-relative rect to the shared popup pipeline"
        )
        assertContains(
            readerLyricsTextView,
            "let popupRect = popupCoordinateRect(glyph.rect)",
            "vertical lyrics lookup should pass a window-relative glyph rect to the shared popup pipeline"
        )
        assertNotContains(
            nativeReader,
            "lyricsSelectionRect(",
            "lyrics lookup should not add a second SwiftUI line-frame offset after AppKit has produced popup coordinates"
        )
        assertNotContains(
            nativeReader,
            "y: popupCoordinateHeight - lineFrame.minY - localRect.maxY",
            "lyrics lookup should not invert the y-axis before handing the rect to PopupLayout"
        )
        assertNotContains(
            nativeReader,
            "popupCoordinateHeight",
            "lyrics lookup should not keep an unused height-based coordinate inversion parameter"
        )
        assertContains(
            nativeReader,
            "isFullWidth: false",
            "lyrics lookup should force anchored popup width instead of Reader full-width popup mode"
        )
        assertContains(
            nativeReader,
            "onSelection: { cue, text, offset, rect, isVertical in",
            "lyrics lookup should carry the line orientation from the lyrics renderer to the Reader model"
        )
        assertContains(
            nativeReader,
            "if model.popup != nil {\n                                model.closePopup()\n                            }",
            "tapping blank lyrics space should close the current popup instead of leaving it open"
        )
        let lyricsProgressBindings = sourceSection(
            nativeReader,
            from: "if displayMode == .lyrics, let player = model.sasayakiPlayer {",
            to: "popupLayer(screenSize: geometry.size)",
            "lyrics progress bindings should belong to the actual lyrics layer"
        )
        assertContains(
            lyricsProgressBindings,
            "currentCharacter: model.displayedCharacterCount",
            "lyrics progress should use the displayed coordinate unit for its current position"
        )
        assertContains(
            lyricsProgressBindings,
            "bookCharacterCount: model.displayedBookInfo.characterCount",
            "lyrics progress should use the same displayed coordinate unit for its total"
        )
        assertNotContains(
            lyricsProgressBindings,
            "currentCharacter: model.currentCharacter",
            "lyrics progress must not combine a native position with the shared canonical total"
        )
        assertNotContains(
            lyricsProgressBindings,
            "bookCharacterCount: model.bookInfo.characterCount",
            "lyrics progress must not combine the canonical position with a native total"
        )
        assertContains(
            nativeReader,
            "var displayedBookInfo: BookInfo { sharedCoordinates?.canonicalBookInfo ?? bookInfo }",
            "displayed counts should retain the native basis for ordinary local books"
        )
        assertContains(
            nativeReader,
            "showStatisticsButton: userConfig.enableStatistics",
            "lyrics mode should show the statistics toggle when Reader statistics are enabled"
        )
        assertContains(
            nativeReader,
            "model.toggleStatisticsTracking()",
            "lyrics mode statistics button should reuse the Reader statistics tracking action"
        )
        let nativeReaderWebViewLayer = sourceSection(
            nativeReader,
            from: "NativeReaderWebView(",
            to: "if displayMode == .lyrics, let player = model.sasayakiPlayer",
            "native Reader should layer lyrics mode above the EPUB WebView"
        )
        assertContains(
            nativeReaderWebViewLayer,
            ".allowsHitTesting(displayMode == .novel)",
            "lyrics mode should disable the underlying EPUB WebView hit testing so lyrics controls receive clicks"
        )
        let lyricsModeView = sourceSection(
            nativeReader,
            from: "struct ReaderLyricsModeView: View",
            to: "@ViewBuilder\n    private var lyricsBackground",
            "lyrics mode view should define its full-screen overlay layout"
        )
        assertContains(
            lyricsModeView,
            ".frame(maxWidth: .infinity, maxHeight: .infinity",
            "lyrics mode root content should fill the Reader overlay at every window size"
        )
        assertContains(
            lyricsModeView,
            "GeometryReader { geometry in",
            "lyrics mode should measure its own overlay bounds instead of trusting the parent Reader geometry"
        )
        assertContains(
            lyricsModeView,
            "let topSafeArea = geometry.safeAreaInsets.top",
            "lyrics mode should measure the window titlebar safe area"
        )
        assertContains(
            lyricsModeView,
            "let backgroundHeight = geometry.size.height + topSafeArea",
            "lyrics mode background should extend behind the transparent titlebar"
        )
        assertContains(
            lyricsModeView,
            "ReaderLyricsLayoutMetrics(size: geometry.size)",
            "lyrics layout metrics should be based on the actual lyrics overlay size"
        )
        assertContains(
            lyricsModeView,
            "var coverImage: NSImage?",
            "lyrics mode should cache the cover image instead of decoding it during every playback tick"
        )
        assertContains(
            lyricsModeView,
            "var heldLyricsCue: SasayakiMatch?",
            "lyrics mode should keep the last highlighted cue during silent gaps between cues"
        )
        assertContains(
            lyricsModeView,
            "var isVerticalLyricsMode = false",
            "lyrics mode vertical writing should be a session-only visual toggle"
        )
        assertContains(
            lyricsModeView,
            "var isLyricsMaskEnabled = false",
            "lyrics mask mode should be a session-only visual toggle"
        )
        assertContains(
            lyricsModeView,
            "var hoveredLyricsCueID: String?",
            "lyrics mask mode should track the hovered sentence without adding persistent settings"
        )
        assertContains(
            lyricsModeView,
            "var activeLyricsCue: SasayakiMatch?",
            "lyrics mode should expose a UI-only active cue independent from SasayakiPlayer clearing WebView highlight"
        )
        assertContains(
            lyricsModeView,
            "player.currentCue ?? heldLyricsCue",
            "lyrics mode should prefer the live cue but hold the previous cue after it finishes"
        )
        assertContains(
            lyricsModeView,
            "loadCoverImage()",
            "lyrics mode should refresh its cached cover image only when the cover URL changes"
        )
        assertNotContains(
            lyricsModeView,
            "private var coverImage: NSImage? {",
            "lyrics mode should not expose cover loading as a computed property that runs during body updates"
        )
        assertContains(
            lyricsModeView,
            ".frame(width: geometry.size.width, height: geometry.size.height",
            "lyrics mode should force GeometryReader content to the exact overlay bounds"
        )
        assertContains(
            lyricsModeView,
            "let contentWidth = max(geometry.size.width - layoutMetrics.chromeHorizontalPadding * 2, 1)",
            "lyrics mode should constrain foreground layout to the visible window width after padding"
        )
        assertContains(
            lyricsModeView,
            "let contentHeight = max(geometry.size.height - layoutMetrics.headerTopPadding * 2, 1)",
            "lyrics mode should constrain foreground layout to the visible window height after padding"
        )
        assertContains(
            lyricsModeView,
            "lyricsBackground\n                    .frame(width: geometry.size.width, height: backgroundHeight)\n                    .offset(y: -topSafeArea)\n                    .clipped()",
            "lyrics background should extend behind the titlebar but remain clipped so blurred artwork cannot expand layout height"
        )
        assertContains(
            lyricsModeView,
            ".frame(width: contentWidth, height: contentHeight)",
            "lyrics content should receive a fixed visible-size proposal instead of the oversized blurred background proposal"
        )
        assertContains(
            lyricsModeView,
            ".position(x: geometry.size.width / 2, y: geometry.size.height / 2)",
            "lyrics content should be centered in the real window frame"
        )
        assertContains(
            nativeReader,
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)",
            "lyrics mode side-by-side content should be centered inside the measured overlay"
        )
        assertContains(
            nativeReader,
            "GeometryReader { geometry in\n            let availableWidth = max(geometry.size.width, 1)",
            "lyrics side-by-side content should measure the actual padded width before sizing columns"
        )
        assertContains(
            nativeReader,
            "let availableHeight = max(geometry.size.height, 1)",
            "lyrics side-by-side content should measure the actual padded height before sizing artwork"
        )
        assertContains(
            nativeReader,
            "playerPanel(metrics: metrics, availableHeight: availableHeight, panelWidth: panelWidth)",
            "lyrics player panel should receive the available height so it cannot overflow at short window sizes"
        )
        assertContains(
            nativeReader,
            "lyricsArtwork(metrics: metrics, availableHeight: availableHeight, panelWidth: panelWidth)",
            "lyrics artwork size should be derived from the measured panel height and width"
        )
        assertContains(
            lyricsModeView,
            "lyricsCloseButton",
            "lyrics mode should keep an explicit close affordance outside the player controls"
        )
        assertContains(
            nativeReader,
            "let lyricsHeight = availableHeight",
            "lyrics mode should give horizontal and vertical lyric stacks the full measured height"
        )
        assertContains(
            nativeReader,
            "lyricsStack(\n                    metrics: metrics,\n                    availableWidth: lyricsWidth,\n                    availableHeight: lyricsHeight",
            "lyrics stack should receive the real display height so vertical lines can fit full sentences"
        )
        assertContains(
            nativeReader,
            "availableWidth: lyricsWidth,",
            "lyrics stack should receive the real lyric column width so vertical mode can fill available columns"
        )
        assertContains(
            nativeReader,
            ".frame(width: lyricsWidth, height: lyricsHeight",
            "lyrics stack should be bounded to the measured available height so it remains visible at different window sizes"
        )
        assertNotContains(
            nativeReader,
            ".frame(width: lyricsWidth, height: lyricsHeight, alignment: .center)\n                    .clipped()",
            "lyrics mask blur should not be hard-clipped to the lyric column because that exposes a rectangular edge"
        )
        assertContains(
            lyricsModeView,
            "lyricsContent(metrics: layoutMetrics)",
            "lyrics mode should use a side-by-side player and lyric layout instead of a bottom transport bar"
        )
        assertContains(
            nativeReader,
            "playerPanel(metrics:",
            "lyrics mode should expose a player-style side panel for artwork, metadata, progress, and controls"
        )
        assertContains(
            nativeReader,
            "lyricsArtwork(metrics:",
            "lyrics mode should render the book cover as a dedicated album-art surface"
        )
        assertContains(
            nativeReader,
            "Color.clear\n                        .frame(width: size, height: size)",
            "lyrics artwork should reserve a transparent square album-art slot"
        )
        assertContains(
            nativeReader,
            ".scaledToFit()",
            "lyrics artwork should fit the cover by its long edge instead of cropping or stretching it"
        )
        assertContains(
            nativeReader,
            ".frame(width: size, height: size, alignment: .center)",
            "lyrics artwork image should stay centered inside the fixed square slot"
        )
        assertContains(
            nativeReader,
            "LazyVStack(alignment: .leading, spacing: ReaderLyricsVisualSpec.listRowSpacing) {\n                    ForEach(cues.indices, id: \\.self) { index in",
            "horizontal lyrics mode should render every matched cue in one lazily scrolling list"
        )
        assertContains(
            nativeReader,
            "LazyHStack(alignment: .center, spacing: verticalLyricsColumnSpacing(metrics: metrics)) {\n                    ForEach(cues.indices.reversed(), id: \\.self) { index in",
            "vertical lyrics mode should render every matched cue as lazily scrolling right-to-left columns"
        )
        assertNotContains(
            nativeReader,
            "visibleLyricsCueWindow(",
            "lyrics mode should not trim the subtitle list to a window around the active cue"
        )
        assertContains(
            nativeReader,
            "var lyricsCues: [SasayakiMatch] {\n        player.matchData?.matches ?? []",
            "lyrics mode should display the full matched cue list"
        )
        assertContains(
            nativeReader,
            "proxy.scrollTo(index, anchor: anchor)",
            "lyrics mode should keep scroll anchoring on the held highlighted cue during silent gaps"
        )
        assertContains(
            nativeReader,
            "func lyricsCueIndex(of cue: SasayakiMatch) -> Int?",
            "lyrics mode should locate the active row without rescanning the whole book on every tick"
        )
        assertContains(
            nativeReader,
            ".onScrollPhaseChange { _, phase in\n                handleLyricsScrollPhase(phase)",
            "lyrics mode should observe manual scrolling of the full subtitle list"
        )
        assertContains(
            nativeReader,
            "case .tracking, .interacting, .decelerating:",
            "manual scrolling should detach the subtitle list from playback"
        )
        assertContains(
            nativeReader,
            "ReaderLyricsVisualSpec.manualScrollFollowResumeDelay",
            "lyrics mode should resume following playback after manual browsing"
        )
        assertContains(
            nativeReader,
            "Label(\"Back to Current Line\"",
            "lyrics mode should offer an explicit way back to the current line while browsing"
        )
        assertContains(
            nativeReader,
            "guard isFollowingPlayback, let index = activeLyricsIndex else { return }",
            "automatic lyrics scrolling should never fight a reader who is browsing the list"
        )
        assertContains(
            nativeReader,
            "if isVerticalLyricsMode {\n            verticalLyricsStack(\n                metrics: metrics,\n                availableWidth: availableWidth,\n                availableHeight: availableHeight\n            )\n        } else {\n            horizontalLyricsStack(metrics: metrics, availableWidth: availableWidth, availableHeight: availableHeight)\n        }",
            "lyrics stack should switch between horizontal and vertical rendering without changing Reader settings"
        )
        assertContains(
            nativeReader,
            "ReaderLyricsVerticalTextLayout.fittedFontSize(",
            "vertical lyrics font fitting should use the shared height and width fitting helper"
        )
        let horizontalLyricsLine = sourceSection(
            nativeReader,
            from: "func lyricsLine(",
            to: "func horizontalLyricsRowHeight(",
            "lyrics mode should define horizontal line rendering separately from vertical line rendering"
        )
        assertContains(
            horizontalLyricsLine,
            "onSelection(cue, text, offset, selectionRect, false)",
            "horizontal lyrics lookup should request above/below anchored popup placement"
        )
        assertNotContains(
            horizontalLyricsLine,
            "guard !isFocused else { return }",
            "focused lyrics rows should not install a no-op SwiftUI tap gesture because it can consume AppKit lookup clicks"
        )
        assertNotContains(
            horizontalLyricsLine,
            "line\n                .onTapGesture",
            "non-focused horizontal lyrics rows must not wrap selectable text in a SwiftUI tap gesture because it consumes AppKit lookup clicks"
        )
        assertContains(
            horizontalLyricsLine,
            "contextLyricsLineTapTarget(for: cue)",
            "non-focused horizontal lyrics rows should keep tap-to-seek on a background target behind the selectable text"
        )
        let lyricsMetalTextContainer = sourceSection(
            readerLyricsTextView,
            from: "final class ReaderLyricsMetalTextContainerView: NSView",
            to: "struct ReaderLyricsSelectableTextView: NSViewRepresentable",
            "lyrics text container should define hit-testing separately from the representable wrapper"
        )
        assertContains(
            lyricsMetalTextContainer,
            "override func hitTest(_ point: NSPoint) -> NSView?",
            "lyrics text containers should let background tap targets receive non-text hits"
        )
        assertContains(
            lyricsMetalTextContainer,
            "return hitView === self ? nil : hitView",
            "lyrics text containers should not claim empty row space that is reserved for tap-to-seek"
        )
        assertContains(
            horizontalLyricsLine,
            "maskedHorizontalLyricsText(cue, fontSize: fontSize, isFocused: isFocused, isRightToLeft: isRightToLeft)",
            "horizontal lyrics mask should render a feathered blurred glyph duplicate for each lazily created row"
        )
        assertNotContains(
            horizontalLyricsLine,
            "ReaderLyricsMaskedTextOverlay",
            "horizontal lyrics rows should not own the blur overlay because per-row offscreen bounds create rectangular edges"
        )
        assertNotContains(
            horizontalLyricsLine,
            "blurredHorizontalLyricsMask(",
            "horizontal lyrics rows should not draw separate blurred mask blocks"
        )
        assertNotContains(
            horizontalLyricsLine,
            ".blur(radius: lyricsMaskBlurRadius(for: cue))",
            "horizontal lyrics mask should not use a bare blur that clips at row edges"
        )
        assertNotContains(
            horizontalLyricsLine,
            ".lyricsSoftMaskBlur(radius: lyricsMaskBlurRadius(for: cue))",
            "horizontal lyrics mask should not blur the entire NSViewRepresentable row because it creates rectangular edges"
        )
        assertContains(
            horizontalLyricsLine,
            ".onHover { hovering in",
            "horizontal lyrics mask should reveal the sentence under the pointer"
        )
        assertNotContains(
            horizontalLyricsLine,
            "onSelection(cue, text, offset, selectionRect, true)",
            "horizontal lyrics lookup should not request vertical side placement"
        )
        assertContains(
            nativeReader,
            "ForEach(cues.indices.reversed(), id: \\.self)",
            "vertical lyrics mode should lay out cue columns in Japanese right-to-left reading order"
        )
        assertContains(
            nativeReader,
            "ReaderLyricsVerticalTextLayout.glyphs(from:",
            "vertical lyrics mode should split cue text into drawable vertical glyph rows"
        )
        assertContains(
            nativeReader,
            "ReaderLyricsVerticalSelectableTextView(",
            "vertical lyrics mode should use a selectable AppKit-backed text view for lookup instead of plain SwiftUI Text"
        )
        assertContains(
            nativeReader,
            "isVertical: Bool? = nil",
            "lyrics lookup should expose an optional vertical placement override without changing horizontal callers"
        )
        assertContains(
            nativeReader,
            "isVertical: false,",
            "lyrics lookup should force above/below popup placement independent of Reader writing direction"
        )
        assertContains(
            nativeReader,
            "isFullWidth: false",
            "lyrics lookup should force anchored popup width instead of Reader full-width popup mode"
        )
        let verticalLyricsLine = sourceSection(
            nativeReader,
            from: "func verticalLyricsLine(",
            to: "func lyricsLine(",
            "lyrics mode should define vertical line rendering separately from horizontal line rendering"
        )
        assertNotContains(
            verticalLyricsLine,
            "player.seekToCue(cue, startPlayback: true)",
            "vertical lyrics lookup clicks should not be followed by a tap-to-seek restart that cancels auto-pause"
        )
        assertContains(
            verticalLyricsLine,
            "onSelection(cue, text, offset, selectionRect, false)",
            "vertical lyrics lookup should request above/below anchored popup placement"
        )
        assertNotContains(
            verticalLyricsLine,
            "onSelection(cue, text, offset, selectionRect, true)",
            "vertical lyrics lookup should not request side popup placement"
        )
        assertContains(
            nativeReader,
            "verticalLyricsLineWidth(",
            "vertical lyrics mode should size each cue for wrapped columns instead of a single narrow column"
        )
        assertContains(
            nativeReader,
            "ReaderLyricsVerticalTextLayout.columns(",
            "vertical lyrics mask should mirror the AppKit vertical text wrapping"
        )
        assertContains(
            verticalLyricsLine,
            "maskedVerticalLyricsText(cue, fontSize: fontSize, isFocused: isFocused, availableHeight: availableHeight)",
            "vertical lyrics mask should render a feathered blurred glyph duplicate for each lazily created column"
        )
        assertNotContains(
            verticalLyricsLine,
            "ReaderLyricsMaskedTextOverlay",
            "vertical lyrics columns should not own the blur overlay because per-column offscreen bounds create rectangular edges"
        )
        assertNotContains(
            verticalLyricsLine,
            "blurredVerticalLyricsMask(",
            "vertical lyrics columns should not draw separate blurred mask blocks"
        )
        assertNotContains(
            verticalLyricsLine,
            ".blur(radius: lyricsMaskBlurRadius(for: cue))",
            "vertical lyrics mask should not use a bare blur that clips at column edges"
        )
        assertNotContains(
            verticalLyricsLine,
            ".lyricsSoftMaskBlur(radius: lyricsMaskBlurRadius(for: cue))",
            "vertical lyrics mask should not blur the entire NSViewRepresentable column because it creates rectangular edges"
        )
        assertContains(
            verticalLyricsLine,
            ".onHover { hovering in",
            "vertical lyrics mask should reveal the sentence column under the pointer"
        )
        assertContains(
            readerLyricsTextView,
            "struct ReaderLyricsVerticalSelectableTextView: NSViewRepresentable",
            "vertical lyrics lookup should have a Reader-owned selectable AppKit bridge"
        )
        assertContains(
            readerLyricsTextView,
            "ReaderLyricsSelectionResolver.lookupCandidates(",
            "vertical lyrics lookup should reuse the same scan-length resolver fallback as horizontal lyrics"
        )
        assertContains(
            readerLyricsTextView,
            "ReaderLyricsSelectionResolver.highlightRange(",
            "vertical lyrics lookup should highlight the resolved dictionary match"
        )
        assertContains(
            readerLyricsTextView,
            "if !isLookupPopupVisible {\n            clearLookupHighlight()",
            "vertical lyrics lookup highlight should clear when the popup closes"
        )
        assertContains(
            nativeReader,
            "let isFocused = cue.id == activeLyricsCue?.id",
            "lyrics lines should stay visually focused while the player current cue is nil between lines"
        )
        assertContains(
            nativeReader,
            "isProgressAnimating: isFocused && player.isPlaying && cue.id == player.currentCue?.id",
            "held lyrics should remain fully lit without running progress animation during silent gaps"
        )
        assertContains(
            nativeReader,
            "let fontSize = metrics.lyricsListFontSize",
            "lyrics rows should share one list font size so focus changes never resize scrolling rows"
        )
        assertContains(
            nativeReader,
            "width: horizontalLyricsTextWidth(availableWidth: availableWidth))",
            "lyrics row height should be measured with the same padded width used for rendering"
        )
        assertContains(
            nativeReader,
            "fontSize: fontSize",
            "lyrics selectable text should use the same font size as wrapped height measurement"
        )
        assertContains(
            nativeReader,
            "ReaderLyricsHorizontalTextLayout.measuredHeight(text: cue.text",
            "wrapped lyrics height should come from the same TextKit layout as rendering"
        )
        assertContains(
            nativeReader,
            "updateHeldLyricsCue(player.currentCue)",
            "lyrics mode should update held cue when the player enters a new live cue"
        )
        assertContains(
            nativeReader,
            "updateHeldLyricsCueForPlaybackPosition()",
            "lyrics mode should repair the held cue when entering or seeking into a silent gap"
        )
        let lyricsControls = sourceSection(
            nativeReader,
            from: "func playerPanel(\n        metrics: ReaderLyricsLayoutMetrics,",
            to: "func handleCurrentCueChange(_ cue: SasayakiMatch?)",
            "lyrics mode should define its bottom controls before cue change handling"
        )
        assertContains(
            lyricsControls,
            "lyricsPlayerMetadata",
            "lyrics player panel should include title/statistics/progress metadata"
        )
        assertContains(
            lyricsControls,
            "LyricsPlayerIconButton",
            "lyrics transport controls should use the reference-style plain player icon button"
        )
        assertContains(
            lyricsControls,
            "verticalLyricsModeButton",
            "lyrics player panel should add a vertical writing toggle beside the statistics button"
        )
        assertContains(
            lyricsControls,
            "lyricsMaskButton\n                verticalLyricsModeButton",
            "lyrics mask toggle should sit immediately to the left of the vertical writing toggle"
        )
        assertContains(
            lyricsControls,
            "HStack(spacing: 10) {\n                lyricsMaskButton\n                verticalLyricsModeButton",
            "lyrics mask and vertical writing toggles should share a fixed-size side control group with the statistics button"
        )
        assertContains(
            lyricsControls,
            "var lyricsMaskButton: some View",
            "lyrics mask toggle should be a dedicated player icon button"
        )
        assertContains(
            lyricsControls,
            "systemName: isLyricsMaskEnabled ? \"eye.slash\" : \"eye\"",
            "lyrics mask toggle should use SF Symbols that reflect the current mask state"
        )
        assertSystemSymbolAvailable(
            "eye",
            "lyrics mask disabled symbol should render on the current macOS"
        )
        assertSystemSymbolAvailable(
            "eye.slash",
            "lyrics mask enabled symbol should render on the current macOS"
        )
        assertContains(
            lyricsControls,
            "isLyricsMaskEnabled.toggle()",
            "lyrics mask toggle should switch mask mode"
        )
        assertContains(
            lyricsControls,
            ".help(Text(\"Lyrics Mask\"))",
            "lyrics mask toggle should have a localized help label"
        )
        assertContains(
            lyricsControls,
            ".accessibilityLabel(Text(\"Lyrics Mask\"))",
            "lyrics mask toggle should expose a readable accessibility label"
        )
        assertContains(
            lyricsControls,
            "systemName: isVerticalLyricsMode ? \"rectangle\" : \"rectangle.portrait\"",
            "lyrics vertical writing toggle should use visible SF Symbols that reflect the current mode"
        )
        assertNotContains(
            lyricsControls,
            "textformat.vertical",
            "lyrics vertical writing toggle should not use a missing SF Symbol that renders as an empty button"
        )
        assertNotContains(
            lyricsControls,
            "textformat",
            "lyrics vertical writing toggle should not use textformat because it can render as localized text"
        )
        assertSystemSymbolAvailable(
            "rectangle",
            "lyrics vertical writing return-to-horizontal symbol should render on the current macOS"
        )
        assertSystemSymbolAvailable(
            "rectangle.portrait",
            "lyrics vertical writing enter-vertical symbol should render on the current macOS"
        )
        assertContains(
            lyricsControls,
            ".accessibilityLabel(Text(\"Vertical Lyrics Mode\"))",
            "lyrics vertical writing toggle should expose a readable accessibility label instead of the raw symbol name"
        )
        assertContains(
            lyricsControls,
            "systemName: isStatisticsTracking ? \"timer\" : \"chart.xyaxis.line\",\n                        diameter: 34,\n                        fontSize: 19",
            "lyrics statistics button should remain the same size as the vertical writing toggle"
        )
        assertContains(
            lyricsControls,
            "diameter: 34,\n            fontSize: 19",
            "lyrics vertical writing toggle should match the statistics button size"
        )
        assertContains(
            lyricsControls,
            "isVerticalLyricsMode.toggle()",
            "lyrics vertical writing toggle should switch the lyrics rendering mode"
        )
        assertContains(
            lyricsControls,
            ".help(Text(\"Vertical Lyrics Mode\"))",
            "lyrics vertical writing toggle should have a localized help label"
        )
        assertContains(
            lyricsControls,
            "player.prevCue()",
            "lyrics transport controls should keep previous sentence navigation"
        )
        assertContains(
            lyricsControls,
            "player.nextCue()",
            "lyrics transport controls should keep next sentence navigation"
        )
        assertContains(
            lyricsControls,
            "lyricsScrubber",
            "lyrics player panel should include a scrubber with elapsed and remaining time"
        )
        assertContains(
            nativeReader,
            "seekLyricsPlayback(to: min(max(value.location.x / trackWidth, 0), 1) * duration)",
            "lyrics scrubber should seek through one manual-seek path"
        )
        assertContains(
            nativeReader,
            "suppressNextCueAdvance = true\n        onManualBaselineReset()\n        player.seekRelative(time - player.currentTime)",
            "scrubbing should reset the statistics baseline instead of counting skipped text"
        )
        assertContains(
            lyricsControls,
            "Reading Speed:",
            "lyrics player panel should include reading speed"
        )
        assertContains(
            lyricsControls,
            "Reading Progress:",
            "lyrics player panel should include reading progress"
        )
        assertContains(
            lyricsControls,
            "Reading Time:",
            "lyrics player panel should include reading time"
        )
        assertContains(
            lyricsControls,
            "Text(title)",
            "lyrics player panel should include the book title"
        )
        assertContains(
            lyricsControls,
            "onToggleStatisticsTracking()",
            "lyrics statistics button should toggle the existing Reader statistics tracker"
        )
        assertNotContains(
            lyricsControls,
            "gobackward.15",
            "lyrics mode should remove the backward time jump button"
        )
        assertNotContains(
            lyricsControls,
            "goforward.15",
            "lyrics mode should remove the forward time jump button"
        )
        assertNotContains(
            lyricsControls,
            "seekRelative(-15)",
            "lyrics mode should remove backward time seeking from the player panel"
        )
        assertNotContains(
            lyricsControls,
            "seekRelative(15)",
            "lyrics mode should remove forward time seeking from the player panel"
        )
        assertNotContains(
            lyricsControls,
            "NativeReaderGlassIconButton",
            "lyrics transport controls should not use the old circular glass button style"
        )
        assertContains(
            nativeReader,
            "displayMode = .lyrics",
            "Reader bottom controls or menu should enter lyrics mode"
        )
        assertContains(
            nativeReader,
            "exitLyricsMode()",
            "Reader should exit lyrics mode through one shared path"
        )
        let exitLyricsMode = sourceSection(
            nativeReader,
            from: "func exitLyricsMode()",
            to: "func setFocusMode",
            "native Reader should expose lyrics mode exit behavior"
        )
        assertContains(
            exitLyricsMode,
            "model.syncBookmarkToCurrentLyricsCue()",
            "exiting lyrics mode should move EPUB progress to the active cue"
        )
        assertContains(
            exitLyricsMode,
            "displayMode = .novel",
            "exiting lyrics mode should restore the normal Reader view"
        )
        let closeShortcut = sourceSection(
            nativeReader,
            from: "func handleReaderCloseShortcut()",
            to: "func handleReaderToggleFocusModeShortcut()",
            "native Reader should expose close shortcut behavior"
        )
        assertContains(
            closeShortcut,
            "if displayMode == .lyrics",
            "Esc should return from lyrics mode before closing the Reader window"
        )
        assertContains(
            closeShortcut,
            "exitLyricsMode()",
            "Reader close shortcut should reuse the lyrics exit path"
        )

        assertContains(
            readerShortcutActions,
            "reader.toggleLyricsMode",
            "Reader shortcuts should expose a menu/shortcut action for lyrics mode"
        )
        assertContains(
            nativeReader,
            "ReaderShortcutActions.toggleLyricsMode.id: handleReaderToggleLyricsModeShortcut",
            "native Reader should register the lyrics mode shortcut"
        )

        assertContains(
            sasayakiPlayer,
            "func visibleCueWindow(radius: Int = 4) -> [SasayakiMatch]",
            "Sasayaki player should expose a stable cue window for lyrics rendering"
        )
        assertContains(
            sasayakiPlayer,
            "func seekToCue(_ cue: SasayakiMatch, startPlayback: Bool = true)",
            "lyrics mode should seek by matched cue without duplicating AVPlayer logic"
        )
        assertContains(
            sasayakiPlayer,
            "func seekRelative(_ delta: TimeInterval)",
            "lyrics mode should expose +/- time seek through the player boundary"
        )
        assertContains(
            nativeReader,
            "func syncBookmarkToCurrentLyricsCue()",
            "Reader model should expose a lyrics exit bookmark sync boundary"
        )
        assertContains(
            nativeReader,
            "func handleLyricsCueDidAdvance(",
            "Reader model should count natural lyrics cue advances through EPUB character positions"
        )
        assertContains(
            nativeReader,
            "resetLyricsStatisticsBaseline()",
            "manual lyrics seeks should reset the statistics baseline to avoid duplicate counts"
        )
        assertContains(
            nativeReader,
            "ReaderLyricsSelectableTextView",
            "lyrics lookup should use a Reader-owned selectable text view in the Light target"
        )
        assertContains(
            readerLyricsTextView,
            "final class ReaderLyricsScrollView: NSScrollView",
            "lyrics text should own a scroll view that keeps its document view sized after SwiftUI/AppKit layout"
        )
        assertContains(
            readerLyricsTextView,
            "import MetalKit",
            "lyrics text rendering should use the native macOS MetalKit stack instead of a third-party renderer"
        )
        assertContains(
            readerLyricsTextView,
            "final class ReaderLyricsMetalRenderView: MTKView",
            "lyrics text should have a narrow MTKView render boundary"
        )
        assertContains(
            readerLyricsTextView,
            "MTLCreateSystemDefaultDevice()",
            "lyrics Metal rendering should use the system Metal device without adding Skia or other dependencies"
        )
        assertContains(
            readerLyricsTextView,
            "ReaderLyricsMetalTexturePair",
            "lyrics Metal rendering should cache selected/upcoming text textures separately from playback progress"
        )
        assertContains(
            readerLyricsTextView,
            "ReaderLyricsMetalUniforms",
            "lyrics Metal rendering should update playback progress through fragment uniforms instead of rebuilding text"
        )
        assertContains(
            readerLyricsTextView,
            "CADisplayLink",
            "lyrics Metal progress should use AppKit's display-synced refresh source on macOS"
        )
        assertContains(
            readerLyricsTextView,
            "displayLink(target: self",
            "lyrics Metal progress should not be capped by SasayakiPlayer's 8Hz AVPlayer observer"
        )
        assertContains(
            readerLyricsTextView,
            "startProgressDisplayLinkIfNeeded",
            "lyrics Metal progress should start a display refresh loop only while focused progress is animating"
        )
        assertContains(
            readerLyricsTextView,
            "stopProgressDisplayLink",
            "lyrics Metal progress should stop the display refresh loop when playback/progress settles"
        )
        assertContains(
            readerLyricsTextView,
            "progressRatePerSecond",
            "lyrics Metal progress should extrapolate between playback ticks from cue duration and playback rate"
        )
        assertContains(
            nativeReader,
            "isProgressAnimating: isFocused && player.isPlaying",
            "lyrics mode should only run high-frequency Metal progress for the focused playing row"
        )
        assertContains(
            nativeReader,
            "progressRate(for: cue)",
            "lyrics mode should pass cue-derived progress velocity into the Metal render boundary"
        )
        assertContains(
            readerLyricsTextView,
            "makeRenderPipelineState",
            "lyrics Metal rendering should use a render pipeline so progress edges can be feathered"
        )
        assertContains(
            readerLyricsTextView,
            "ReaderLyricsVisualSpec.lineProgressionGradientFeather",
            "lyrics Metal progression should carry over the synced lyrics feather width"
        )
        assertContains(
            readerLyricsTextView,
            "drawPrimitives(type: .triangle",
            "lyrics Metal rendering should composite cached text textures on the GPU"
        )
        assertContains(
            readerLyricsTextView,
            "ReaderLyricsHitTestTextView",
            "lyrics lookup hit testing should remain TextKit-backed while visuals move to Metal"
        )
        assertContains(
            readerLyricsTextView,
            "override func layout()",
            "lyrics text scroll view should resync the text view frame whenever AppKit lays it out"
        )
        assertContains(
            readerLyricsTextView,
            "override func hitTest(_ point: NSPoint) -> NSView?",
            "lyrics text AppKit rows should not intercept clicks outside their rendered text"
        )
        assertContains(
            readerLyricsTextView,
            "renderedTextHitBounds",
            "lyrics text hit testing should be limited to the actual glyph bounds"
        )
        assertContains(
            readerLyricsTextView,
            "height: max(bounds.height, rect.height)",
            "lyrics text hit testing should keep glyph horizontal bounds but allow the full row height so fitted focused lines remain clickable"
        )
        assertContains(
            readerLyricsTextView,
            "func syncDocumentViewFrame()",
            "lyrics text scroll view should expose one document-frame sync path"
        )
        assertContains(
            readerLyricsTextView,
            "height: max(bounds.height, ceil(textHeight))",
            "lyrics text view should not stay at a zero initial document frame"
        )
        assertContains(
            readerLyricsTextView,
            "ReaderLyricsTextDirection.isRightToLeft",
            "lyrics text should mirror the server parser's RTL direction handling for Arabic/Hebrew lines"
        )
        assertContains(
            readerLyricsTextView,
            "progressFraction",
            "focused lyrics text should support line progression coloring instead of rendering a static whole line"
        )
        assertContains(
            readerLyricsTextView,
            "lastLyricsRenderSignature",
            "lyrics text should cache render inputs so unchanged context rows do not rebuild attributed strings every playback tick"
        )
        assertContains(
            readerLyricsTextView,
            "progressInputsUnchanged",
            "lyrics text should skip Metal redraws for unchanged non-focused context rows"
        )
        assertContains(
            readerLyricsTextView,
            "guard signature != lastLyricsRenderSignature",
            "lyrics text should skip textStorage updates when render inputs are unchanged"
        )
        assertContains(
            readerLyricsTextView,
            "lastSyncedDocumentBounds",
            "lyrics text scroll view should skip AppKit layout sync when bounds are unchanged"
        )
        assertNotContains(
            readerLyricsTextView,
            "makeBlitCommandEncoder",
            "lyrics progress should not fall back to a hard-edged blit copy"
        )
        assertContains(
            nativeReader,
            "ReaderLyricsVisualSpec.lineChangeAnimation",
            "lyrics line changes should use the synced lyrics spring timing"
        )
        assertContains(
            nativeReader,
            "lineProgress(for cue",
            "lyrics mode should approximate synced per-line progression from Sasayaki cue timing"
        )
        let lyricsMaskBehavior = sourceSection(
            nativeReader,
            from: "func isLyricsMaskVisible(for cue: SasayakiMatch) -> Bool",
            to: "func maskedHorizontalLyricsText(",
            "lyrics mode should define mask visibility before the mask overlays"
        )
        assertContains(
            lyricsMaskBehavior,
            "guard isLyricsMaskEnabled, player.isPlaying, !isLookupPopupVisible else { return false }",
            "lyrics mask should restore all subtitles while paused or while a lookup popup is visible"
        )
        assertContains(
            lyricsMaskBehavior,
            "hoveredLyricsCueID != cue.id",
            "lyrics mask should reveal the corresponding sentence under the mouse"
        )
        assertContains(
            nativeReader,
            "private struct ReaderLyricsMaskedTextOverlay<Content: View>: View",
            "lyrics mask blur should render text glyphs in a dedicated SwiftUI overlay"
        )
        assertContains(
            nativeReader,
            "let feather = ReaderLyricsVisualSpec.lyricsMaskBlurFeatherPadding",
            "lyrics glyph blur should use shared feather padding to avoid clipping text edges"
        )
        assertContains(
            nativeReader,
            ".blur(radius: ReaderLyricsVisualSpec.lyricsMaskBlurRadius, opaque: false)",
            "lyrics glyph overlay should apply Gaussian blur to text glyphs only"
        )
        assertContains(
            nativeReader,
            "func maskedHorizontalLyricsText(",
            "lyrics mode should expose a horizontal text-only mask overlay"
        )
        assertContains(
            nativeReader,
            "func maskedVerticalLyricsText(",
            "lyrics mode should expose a vertical text-only mask overlay"
        )
        assertNotContains(
            nativeReader,
            "private func blurredHorizontalLyricsMask(",
            "lyrics mode should not keep the old per-row horizontal mask helper"
        )
        assertNotContains(
            nativeReader,
            "private func blurredVerticalLyricsMask(",
            "lyrics mode should not keep the old per-column vertical mask helper"
        )
        assertContains(
            readerLyricsLayoutMetrics,
            "static let lyricsMaskBlurFeatherPadding: CGFloat",
            "lyrics visual spec should expose the soft-edge blur padding"
        )
        assertContains(
            lyricsMaskBehavior,
            "if hovering {\n            hoveredLyricsCueID = cue.id",
            "lyrics hover tracking should set the active sentence when the pointer enters"
        )
        assertContains(
            lyricsMaskBehavior,
            "else if hoveredLyricsCueID == cue.id {\n            hoveredLyricsCueID = nil",
            "lyrics hover tracking should only clear the matching sentence when the pointer leaves"
        )
        assertNotContains(
            nativeReader,
            "ReaderLyricsVisualSpec.highlightViewBackgroundOpacity",
            "lyrics words should not render a rounded background behind the focused line"
        )
        assertNotContains(
            nativeReader,
            "RoundedRectangle(cornerRadius: ReaderLyricsVisualSpec.highlightViewCornerRadius",
            "lyrics words should stay background-free while keeping color/progress emphasis"
        )
        assertNotContains(
            lyricsMaskBehavior,
            "RoundedRectangle(cornerRadius:",
            "lyrics mask should not use an opaque rounded cover when Gaussian blur is requested"
        )
        assertNotContains(
            nativeReader,
            "InteractiveSubtitleTextView",
            "lyrics mode must not depend on the Video-only subtitle text view"
        )
        assertNotContains(
            nativeReader,
            "#if HOSHI_VIDEO",
            "Reader lyrics mode must not depend on retired Video feature flags"
        )
        assertContains(
            nativeReader,
            "model.handleLyricsSelection(",
            "lyrics mode should route text lookup through the Reader model and popup stack"
        )
        assertContains(
            nativeReader,
            "MiningContextSelection.timedSentences",
            "lyrics lookup should preserve adjacent Sasayaki cues for Anki context selection"
        )
        assertNotContains(
            nativeReader,
            "let miningContext = MiningContextSelection.text",
            "lyrics lookup should not send a single-sentence mining context because it disables previous/next context buttons"
        )

        for key in [
            "Lyrics Mode",
            "Exit Lyrics Mode",
            "Open Lyrics Mode",
            "Vertical Lyrics Mode",
            "Lyrics Mask",
            "No lyrics match",
            "Session",
            "Reading Progress:",
            "Back to Current Line",
            "Playback Position",
            "Previous Cue",
            "Next Cue"
        ] {
            assertLocalized(
                localizationStrings,
                key,
                languages: ["en", "zh-Hans"],
                "lyrics mode visible strings should have English and Simplified Chinese localization"
            )
        }

        assertContains(
            project,
            "ReaderLyricsLayoutMetrics.swift",
            "native target should include the Reader lyrics layout metrics"
        )
        assertContains(
            project,
            "ReaderLyricsSelectionResolver.swift",
            "native target should include the Reader lyrics selection resolver"
        )
        assertContains(
            project,
            "ReaderLyricsTextView.swift",
            "native target should include the Reader lyrics selectable text view"
        )

        print("reader lyrics mode contract passed")
    }
}

try ReaderLyricsModeContractTest.main()
