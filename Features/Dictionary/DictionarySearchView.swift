//
//  DictionarySearchView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import CHoshiDicts

struct DictionarySearchView: View {
    private static let resetTextFieldScrollThreshold: CGFloat = 80
    private static let contentTopSpacing = 12

    @Environment(UserConfig.self) private var userConfig
    @Environment(ShortcutManager.self) private var shortcutManager
    @State private var query: String = ""
    @State private var lastQuery: String = ""
    @State private var content: String = ""
    @State private var dictionaryStyles: [String: String] = [:]
    @State private var lookupEntries: [[String: Any]] = []
    @State private var hasSearched = false
    @State private var searchFocused = false
    @State private var didInitialQuery = false
    @State private var popups: [PopupItem] = []
    @State private var clearSelection: Bool = false
    @State private var backCount: Int = 0
    @State private var forwardCount: Int = 0
    @State private var backTrigger: Bool = false
    @State private var forwardTrigger: Bool = false
    @State private var isDragging: Bool = false
    @State private var isRefreshing: Bool = false
    @State private var isResettingTextField: Bool = false
    @State private var scrollViewInitialContentOffset: CGFloat! = nil
    @State private var scrollViewContentOffset: CGFloat! = nil
    @State private var shortcutRegistrationID: UUID?
    @State private var dictionaryEntryNavigationSequence = 0
    @State private var dictionaryEntryNavigationCommand: DictionaryEntryNavigationCommand?
    @State private var profileRepository = ProfileRepository.shared
    var initialQuery: String = ""
    var initialAutofocus: Bool = true
    var shouldFocus: Bool = false

    private var usesTopTabBarLayout: Bool {
        true
    }

    private var searchBarInset: CGFloat {
        usesTopTabBarLayout ? 100 : 50
    }

    private var tabBarInset: CGFloat {
        usesTopTabBarLayout ? 0 : 45
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PopupWebView(
                    content: content,
                    position: .zero,
                    scale: CGFloat(userConfig.popupScale),
                    twoColumnLayout: userConfig.twoColumnLayout,
                    clearSelection: clearSelection,
                    dictionaryStyles: dictionaryStyles,
                    lookupEntries: lookupEntries,
                    scanNonJapaneseText: userConfig.scanNonJapaneseText,
                    scanLength: userConfig.scanLength,
                    profileID: profileRepository.activeProfile.id,
                    contentLanguageID: profileRepository.activeProfile.language.rawValue,
                    backTrigger: backTrigger,
                    forwardTrigger: forwardTrigger,
                    dictionaryEntryNavigationCommand: dictionaryEntryNavigationCommand,
                    onMine: { minedContent in
                        await mineAnkiEntry(
                            content: minedContent,
                            context: MiningContext(sentence: lastQuery, documentTitle: nil, coverURL: nil)
                        )
                    },
                    onTextSelected: {
                        closePopups()
                        return handleTextSelection($0, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength, isVertical: false, isFullWidth: false)
                    },
                    onQueryTextSelected: { query in
                        closePopups()
                        guard let result = handleInlineQuerySelection(
                            query,
                            maxResults: userConfig.maxResults,
                            scanLength: userConfig.scanLength
                        ) else {
                            return nil
                        }
                        backCount += 1
                        forwardCount = 0
                        return result
                    },
                    onTapOutside: closePopups,
                    onRedirect: { query in
                        closePopups()
                        let results = LookupEngine.shared.lookup(query, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength)
                        let entries = Self.buildLookupEntries(lookupResults: results)
                        if !entries.isEmpty {
                            backCount += 1
                            forwardCount = 0
                        }
                        return entries
                    },
                    onKanjiRedirect: { kanji in
                        closePopups()
                        let data = LookupEngine.shared.queryKanji(kanji)
                        if data != nil {
                            backCount += 1
                            forwardCount = 0
                        }
                        return data
                    },
                    scrollViewBounces: true,
                    onScrollViewOffsetChanged: { newOffset in
                        if scrollViewInitialContentOffset == nil {
                            scrollViewInitialContentOffset = newOffset
                        }
                        scrollViewContentOffset = newOffset
                    },
                    onScrollViewWillBeginDragging: {
                        isDragging = true
                    },
                    onScrollViewDidEndDragging: {
                        isDragging = false
                        if scrollViewInitialContentOffset - scrollViewContentOffset > Self.resetTextFieldScrollThreshold {
                            isRefreshing = true
                            if !query.isEmpty {
                                isResettingTextField = true
                            }
                        }
                    },
                    onScrollViewDidEndDecelerating: {
                        isRefreshing = false
                        isResettingTextField = false
                    }
                )
                .id("\(lastQuery)-\(profileRepository.activeProfile.id)")
                .simultaneousGesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height

                            guard abs(dx) > abs(dy) && abs(dy) < 20 else { return }

                            if dx > 0 {
                                guard backCount > 0 else { return }
                                backTrigger.toggle()
                                backCount -= 1
                                forwardCount += 1
                            } else {
                                guard forwardCount > 0 else { return }
                                forwardTrigger.toggle()
                                forwardCount -= 1
                                backCount += 1
                            }
                        }
                )

                nestedPopups(geometry: geometry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            NativeGlassPageBackground()
        }
        .dictionarySearchSafeAreaBehavior()
        .overlay(alignment: .top) {
            NativeGlassTopScrim()
                .frame(height: AppPlatform.topSafeArea + 50)
                .ignoresSafeArea(edges: .top)
        }
        .safeAreaInset(edge: .top) {
            VStack {
                DictionarySearchBar(text: $query, isFocused: $searchFocused) {
                    runLookup()
                }

                if let scrollViewInitialContentOffset {
                    SearchResetInset(
                        scrollDistance: scrollViewInitialContentOffset - scrollViewContentOffset,
                        threshold: Self.resetTextFieldScrollThreshold,
                        isQueryEmpty: query.isEmpty,
                        isRefreshing: isRefreshing,
                        isDragging: isDragging,
                        isResettingTextField: isResettingTextField
                    )
                }
            }
        }
        .onChange(of: shouldFocus) {
            searchFocused = true
        }
        .onChange(of: isRefreshing, { _, isRefreshing in
            if isRefreshing {
                query = ""
                searchFocused = true
            }
        })
        .onChange(of: profileRepository.index.globalActiveProfileId) { _, _ in
            closePopups()
            if hasSearched {
                runLookup()
            }
        }
        .onChange(of: LookupEngine.shared.isReadyForLookup) { _, isReady in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if isReady, hasSearched, !trimmed.isEmpty, trimmed == lastQuery {
                runLookup()
            }
        }
        .onAppear {
            registerKeyboardShortcuts()
            if !didInitialQuery && !initialQuery.isEmpty {
                query = initialQuery
                runLookup()
            }
            if initialAutofocus || didInitialQuery {
                searchFocused = false
                Task { @MainActor in
                    searchFocused = true
                }
            } else {
                searchFocused = false
                didInitialQuery = true
            }
        }
        .onDisappear {
            unregisterKeyboardShortcuts()
        }
    }

    @ViewBuilder
    private func nestedPopups(geometry: GeometryProxy) -> some View {
        ForEach($popups) { $popup in
            let popupId = popup.id
            NativeDictionaryPopupView(
                popup: $popup,
                screenSize: geometry.size,
                topInset: AppPlatform.topSafeArea + searchBarInset,
                bottomInset: max(AppPlatform.bottomSafeArea, 30) + tabBarInset,
                onTextSelected: {
                    if let index = popups.firstIndex(where: { $0.id == popupId }) {
                        closeChildPopups(parent: index)
                    }
                    return handleTextSelection($0, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength, isVertical: false, isFullWidth: false)
                },
                onTapOutside: {
                    if let index = popups.firstIndex(where: { $0.id == popupId }) {
                        closeChildPopups(parent: index)
                    }
                },
                onDismiss: {
                    guard let index = popups.firstIndex(where: { $0.id == popupId }),
                          popups.indices.contains(index) else {
                        return
                    }
                    if index == 0 {
                        clearSelection.toggle()
                        closePopups()
                    } else if popups.indices.contains(index - 1) {
                        popups[index - 1].clearSelection.toggle()
                        closeChildPopups(parent: index - 1)
                    }
                },
                onRedirect: { query in
                    let results = LookupEngine.shared.lookup(query, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength)
                    let entries = Self.buildLookupEntries(lookupResults: results)
                    if !entries.isEmpty {
                        backCount += 1
                        forwardCount = 0
                    }
                    return entries
                },
                onKanjiRedirect: { kanji in
                    LookupEngine.shared.queryKanji(kanji)
                }
            )
            .zIndex(Double(100 + (popups.firstIndex(where: { $0.id == popupId }) ?? 0)))
        }
    }

    private func runLookup() {
        closePopups()
        backCount = 0
        forwardCount = 0

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hasSearched = true
        lastQuery = trimmed

        guard !trimmed.isEmpty else {
            content = ""
            lookupEntries = []
            dictionaryStyles = [:]
            return
        }

        let results = LookupEngine.shared.lookup(trimmed, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength)
        if results.isEmpty {
            content = ""
            lookupEntries = []
            dictionaryStyles = [:]
            return
        }

        let styles = LookupEngine.shared.getStyles()
        constructHtml(results: results, styles: styles)
    }

    private func handleTextSelection(_ selection: SelectionData, maxResults: Int, scanLength: Int,  isVertical: Bool, isFullWidth: Bool) -> Int? {
        let lookupResults = LookupEngine.shared.lookup(selection.text, maxResults: maxResults, scanLength: scanLength)
        var dictionaryStyles: [String: String] = [:]
        for style in LookupEngine.shared.getStyles() {
            dictionaryStyles[
                String(decoding: style.dict_name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            ] = String(decoding: style.styles.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        guard let firstResult = lookupResults.first else { return nil }
        let matchedText = String(decoding: firstResult.matched.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var resolvedSelection = selection
        let matchedCharacterCount = resolvedSelection.applyLookupMatch(matchedText)
        let popup = PopupItem(
            showPopup: false,
            currentSelection: resolvedSelection,
            lookupResults: lookupResults,
            dictionaryStyles: dictionaryStyles,
            isVertical: isVertical,
            isFullWidth: isFullWidth,
            clearSelection: false
        )
        popups.append(popup)

        withAnimation(.default.speed(2.2)) {
            popups = popups.map {
                var p = $0
                if p.id == popup.id {
                    p.showPopup = true
                }
                return p
            }
        }
        return matchedCharacterCount
    }

    private func handleInlineQuerySelection(_ query: String, maxResults: Int, scanLength: Int) -> PopupInlineLookupResult? {
        let lookupResults = LookupEngine.shared.lookup(query, maxResults: maxResults, scanLength: scanLength)
        guard let firstResult = lookupResults.first else { return nil }
        let matchedText = String(decoding: firstResult.matched.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return PopupInlineLookupResult(
            entries: Self.buildLookupEntries(lookupResults: lookupResults),
            matchedCharacterCount: matchedText.count
        )
    }

    private func closePopups() {
        guard !popups.isEmpty else { return }
        let popupIds = Set(popups.map(\.id))
        withAnimation(.default.speed(2.4)) {
            popups = popups.map {
                var p = $0
                p.showPopup = false
                return p
            }
        } completion: {
            popups.removeAll { popupIds.contains($0.id) }
        }
    }

    private func closeChildPopups(parent: Int) {
        let popupIds = Set(popups.dropFirst(parent + 1).map(\.id))
        guard !popupIds.isEmpty else { return }
        withAnimation(.default.speed(2.4)) {
            popups = popups.map {
                var p = $0
                if popupIds.contains(p.id) {
                    p.showPopup = false
                }
                return p
            }
        } completion: {
            popups.removeAll { popupIds.contains($0.id) }
        }
    }

    private func registerKeyboardShortcuts() {
        guard shortcutRegistrationID == nil else { return }
        shortcutRegistrationID = shortcutManager.register(
            scope: .dictionary,
            handlers: [
                DictionaryShortcutActions.previousEntry.id: {
                    moveDictionaryEntry(direction: -1)
                },
                DictionaryShortcutActions.nextEntry.id: {
                    moveDictionaryEntry(direction: 1)
                }
            ]
        )
    }

    private func unregisterKeyboardShortcuts() {
        shortcutManager.unregister(shortcutRegistrationID)
        shortcutRegistrationID = nil
    }

    private func moveDictionaryEntry(direction: Int) -> Bool {
        guard !lookupEntries.isEmpty else { return false }
        dictionaryEntryNavigationSequence += 1
        dictionaryEntryNavigationCommand = DictionaryEntryNavigationCommand(
            sequence: dictionaryEntryNavigationSequence,
            direction: direction,
            count: max(1, userConfig.dictionaryEntryJumpCount)
        )
        return true
    }

    private func constructHtml(results: [LookupResult], styles: [DictionaryStyle]) {
        let payload = Self.buildPopupPayload(
            lookupResults: results,
            styles: styles,
            userConfig: userConfig,
            includeOverlayPadding: true,
            querySource: lastQuery,
            topSpacerHeight: Self.contentTopSpacing
        )
        dictionaryStyles = payload.dictionaryStyles
        lookupEntries = payload.lookupEntries
        content = payload.content
    }

    fileprivate static func buildPopupPayload(
        lookupResults: [LookupResult],
        styles: [DictionaryStyle],
        userConfig: UserConfig,
        includeOverlayPadding: Bool,
        querySource: String? = nil,
        topSpacerHeight: Int = 50
    ) -> (content: String, lookupEntries: [[String: Any]], dictionaryStyles: [String: String]) {
        var dictionaryStyles: [String: String] = [:]
        for style in styles {
            dictionaryStyles[
                String(decoding: style.dict_name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            ] = String(decoding: style.styles.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return buildPopupPayload(
            lookupResults: lookupResults,
            dictionaryStyles: dictionaryStyles,
            userConfig: userConfig,
            includeOverlayPadding: includeOverlayPadding,
            querySource: querySource,
            topSpacerHeight: topSpacerHeight
        )
    }

    fileprivate static func buildPopupPayload(
        lookupResults: [LookupResult],
        dictionaryStyles: [String: String],
        userConfig: UserConfig,
        includeOverlayPadding: Bool,
        querySource: String? = nil,
        topSpacerHeight: Int = 50
    ) -> (content: String, lookupEntries: [[String: Any]], dictionaryStyles: [String: String]) {
        let lookupEntries = Self.buildLookupEntries(lookupResults: lookupResults)
        let collapsedDictionaries = userConfig.collapseMode == .custom
        ? ((try? JSONEncoder().encode(DictionaryManager.shared.collapsedDictionaries))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]") : "[]"
        let audioSources = (try? JSONEncoder().encode(userConfig.enabledAudioSources))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let audioSourceNames = (try? JSONEncoder().encode(userConfig.audioSources.filter(\.isEnabled).map(\.name)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let excludedDictionaries = (try? JSONEncoder().encode(DictionaryManager.shared.excludedDictionaries))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let scaledCSS = userConfig.customCSS.replacingOccurrences(of: #"(-?(?:\d+(?:\.\d+)?|\.\d+))px"#, with: "calc($1px * var(--popup-scale))", options: .regularExpression)
        let customCSS = (try? JSONSerialization.data(withJSONObject: scaledCSS, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let querySourceJSON = querySource
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"

        let overlayPadding = includeOverlayPadding ? "<style>.overlay { padding-bottom: 90px; }</style>" : ""
        let querySourceMarkup = querySource == nil ? "" : """
        <div id="dictionary-query-source" class="dictionary-query-source" style="font-size: \(userConfig.searchTextSize)px; min-height: calc(\(userConfig.searchTextSize)px * 1.4);"></div>
        <hr class="dictionary-query-source-divider">
        """

        let content = """
        \(overlayPadding)
        <script>
            window.collapseMode = "\(userConfig.collapseMode.rawValue)";
            window.expandFirstDictionary = \(userConfig.expandFirstDictionary);
            window.twoColumnLayout = \(userConfig.twoColumnLayout);
            window.collapsedDictionaries = \(collapsedDictionaries);
            window.excludedDictionaries = \(excludedDictionaries);
            window.compactGlossaries = \(userConfig.compactGlossaries);
            window.showExpressionTags = \(userConfig.showExpressionTags);
            window.harmonicFrequency = \(userConfig.harmonicFrequency);
            window.deduplicatePitchAccents = \(userConfig.deduplicatePitchAccents);
            window.compactPitchAccents = \(userConfig.compactPitchAccents);
            window.audioSources = \(audioSources);
            window.audioSourceNames = \(audioSourceNames);
            window.audioEnableAutoplay = \(userConfig.audioEnableAutoplay);
            window.audioPlaybackMode = "\(userConfig.audioPlaybackMode.rawValue)";
            window.needsAudio = \(AnkiManager.shared.needsAudio);
            window.allowDupes = \(AnkiManager.shared.allowDupes);
            window.useAnkiConnect = \(AnkiManager.shared.useAnkiConnect);
            window.embedMedia = \(AnkiManager.shared.embedMedia);
            window.compactGlossariesAnki = \(AnkiManager.shared.compactGlossaries);
            window.customCSS = \(customCSS);
            window.dictionaryQuerySource = \(querySourceJSON);
        </script>
        <div style="height: \(topSpacerHeight)px;"></div>
        <div id="entries-container" style="min-height: 100vh;">
            \(querySourceMarkup)
        </div>
        """

        return (content, lookupEntries, dictionaryStyles)
    }

    fileprivate static func buildLookupEntries(lookupResults: [LookupResult]) -> [[String: Any]] {
        var entries: [[String: Any]] = []
        for result in lookupResults {
            let expression = String(result.term.expression)
            let reading = String(result.term.reading)
            let matched = String(decoding: result.matched.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let deinflectionTraces: [[[String: String]]] = result.trace_candidates.map { candidate in
                candidate.trace.reversed().map {
                    [
                        "name": String($0.name),
                        "description": String($0.description),
                    ]
                }
            }
            let deinflectionTrace = deinflectionTraces.first ?? []

            var glossaries: [[String: Any]] = []
            for glossary in result.term.glossaries {
                glossaries.append([
                    "dictionary": String(decoding: glossary.dict_name.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                    "content": String(glossary.glossary),
                    "definitionTags": String(glossary.definition_tags),
                    "termTags": String(glossary.term_tags),
                ])
            }

            var frequencies: [[String: Any]] = []
            for frequency in result.term.frequencies {
                var frequencyTags: [[String: Any]] = []
                for frequencyTag in frequency.frequencies {
                    frequencyTags.append([
                        "value": Int(frequencyTag.value),
                        "displayValue": String(frequencyTag.display_value),
                    ])
                }
                frequencies.append([
                    "dictionary": String(decoding: frequency.dict_name.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                    "frequencies": frequencyTags,
                ])
            }

            var pitches: [[String: Any]] = []
            for pitchEntry in result.term.pitches {
                var pitchPositions: [Int] = []
                var transcriptions: [String] = []
                for element in pitchEntry.pitch_positions {
                    let position = Int(element)
                    if !pitchPositions.contains(position) {
                        pitchPositions.append(position)
                    }
                }
                for element in pitchEntry.transcriptions {
                    let transcription = String(element)
                    if !transcriptions.contains(transcription) {
                        transcriptions.append(transcription)
                    }
                }
                pitches.append([
                    "dictionary": String(decoding: pitchEntry.dict_name.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                    "pitchPositions": pitchPositions,
                    "transcriptions": transcriptions,
                ])
            }

            let rules = String(result.term.rules).split(separator: " ").map { String($0) }

            entries.append([
                "expression": expression,
                "reading": reading,
                "matched": matched,
                "deinflectionTrace": deinflectionTrace,
                "deinflectionTraces": deinflectionTraces,
                "glossaries": glossaries,
                "frequencies": frequencies,
                "pitches": pitches,
                "rules": rules,
            ])
        }
        return entries
    }
}

private extension View {
    @ViewBuilder
    func dictionarySearchSafeAreaBehavior() -> some View {
        self
    }
}

private struct NativeDictionaryPopupView: View {
    @Environment(UserConfig.self) private var userConfig
    @Environment(ShortcutManager.self) private var shortcutManager
    @Binding var popup: PopupItem
    let screenSize: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onTextSelected: (SelectionData) -> Int?
    let onTapOutside: () -> Void
    let onDismiss: () -> Void
    let onRedirect: (String) -> [[String: Any]]
    let onKanjiRedirect: (String) -> [String: Any]?

    @State private var backCount = 0
    @State private var forwardCount = 0
    @State private var backTrigger = false
    @State private var forwardTrigger = false
    @State private var controlsHeight: CGFloat = 0
    @State private var shortcutRegistrationID: UUID?
    @State private var dictionaryEntryNavigationSequence = 0
    @State private var dictionaryEntryNavigationCommand: DictionaryEntryNavigationCommand?
    @State private var profileRepository = ProfileRepository.shared

    private var layout: PopupLayout? {
        guard let selection = popup.currentSelection else { return nil }
        let layout = PopupLayout(
            selectionRect: selection.rect,
            screenSize: screenSize,
            maxWidth: CGFloat(userConfig.popupWidth),
            maxHeight: CGFloat(userConfig.popupHeight),
            isVertical: popup.isVertical,
            isFullWidth: popup.isFullWidth,
            topInset: topInset,
            bottomInset: bottomInset
        )
        guard layout.width.isFinite,
              layout.height.isFinite,
              layout.position.x.isFinite,
              layout.position.y.isFinite else {
            return nil
        }
        return layout
    }

    var body: some View {
        Group {
            if popup.showPopup, let layout {
                let showsActionBar = userConfig.popupActionBar
                let activeControlsHeight = showsActionBar ? controlsHeight : 0
                let payload = DictionarySearchView.buildPopupPayload(
                    lookupResults: popup.lookupResults,
                    dictionaryStyles: popup.dictionaryStyles,
                    userConfig: userConfig,
                    includeOverlayPadding: false
                )

                popupSurface(
                    VStack(spacing: 0) {
                        if showsActionBar {
                            actionBar
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                    controlsHeight = $0
                                }
                        }

                        PopupWebView(
                            content: payload.content,
                            position: CGPoint(
                                x: layout.position.x - layout.width / 2,
                                y: layout.position.y - layout.height / 2 + activeControlsHeight
                            ),
                            scale: CGFloat(userConfig.popupScale),
                            twoColumnLayout: userConfig.twoColumnLayout,
                            clearSelection: popup.clearSelection,
                            hoverLookupDelayMs: userConfig.desktopLookupHoverDelayMs,
                            dictionaryStyles: popup.dictionaryStyles,
                            lookupEntries: payload.lookupEntries,
                            scanNonJapaneseText: userConfig.scanNonJapaneseText,
                            scanLength: userConfig.scanLength,
                            profileID: profileRepository.activeProfile.id,
                            contentLanguageID: profileRepository.activeProfile.language.rawValue,
                            backTrigger: backTrigger,
                            forwardTrigger: forwardTrigger,
                            dictionaryEntryNavigationCommand: dictionaryEntryNavigationCommand,
                            onMine: { content in
                                await mineAnkiEntry(
                                    content: content,
                                    context: MiningContext(sentence: popup.currentSelection?.sentence ?? "", documentTitle: nil, coverURL: nil)
                                )
                            },
                            onTextSelected: onTextSelected,
                            onTapOutside: onTapOutside,
                            onSwipeDismiss: onDismiss,
                            onRedirect: { query in
                                let entries = onRedirect(query)
                                if !entries.isEmpty {
                                    backCount += 1
                                    forwardCount = 0
                                }
                                return entries
                            },
                            onKanjiRedirect: { kanji in
                                let data = onKanjiRedirect(kanji)
                                if data != nil {
                                    backCount += 1
                                    forwardCount = 0
                                }
                                return data
                            }
                        )
                    }
                    .frame(width: layout.width, height: layout.height)
                )
                .position(layout.position)
                .transition(.opacity)
            }
        }
        .onAppear {
            registerKeyboardShortcuts()
        }
        .onDisappear {
            unregisterKeyboardShortcuts()
        }
    }

    @ViewBuilder
    private func popupSurface<Content: View>(_ content: Content) -> some View {
        if #available(macOS 26, *), !userConfig.popupDisableTransparency {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
        } else {
            content
                .background(
                    Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.2), lineWidth: 1))
        }
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Button {
                    backTrigger.toggle()
                    backCount -= 1
                    forwardCount += 1
                } label: {
                    Image(systemName: "chevron.left")
                        .opacity(backCount > 0 ? 1 : 0.3)
                }
                .disabled(backCount == 0)

                Button {
                    forwardTrigger.toggle()
                    forwardCount -= 1
                    backCount += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .opacity(forwardCount > 0 ? 1 : 0.3)
                }
                .disabled(forwardCount == 0)

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }
            .buttonStyle(.borderless)
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            Divider()
        }
    }

    private func registerKeyboardShortcuts() {
        guard shortcutRegistrationID == nil else { return }
        shortcutRegistrationID = shortcutManager.register(
            scope: .dictionary,
            handlers: [
                DictionaryShortcutActions.previousEntry.id: {
                    moveDictionaryEntry(direction: -1)
                },
                DictionaryShortcutActions.nextEntry.id: {
                    moveDictionaryEntry(direction: 1)
                }
            ]
        )
    }

    private func unregisterKeyboardShortcuts() {
        shortcutManager.unregister(shortcutRegistrationID)
        shortcutRegistrationID = nil
    }

    private func moveDictionaryEntry(direction: Int) -> Bool {
        guard popup.showPopup, !popup.lookupResults.isEmpty else { return false }
        dictionaryEntryNavigationSequence += 1
        dictionaryEntryNavigationCommand = DictionaryEntryNavigationCommand(
            sequence: dictionaryEntryNavigationSequence,
            direction: direction,
            count: max(1, userConfig.dictionaryEntryJumpCount)
        )
        return true
    }
}

struct DictionarySearchBar: Equatable, View {

    static func == (lhs: DictionarySearchBar, rhs: DictionarySearchBar) -> Bool {
        lhs.text == rhs.text && lhs.isFocused == rhs.isFocused
    }

    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            CustomSearchField(searchText: $text, isFocused: $isFocused, onSubmit: onSubmit)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .nativeGlassCapsuleSurface()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

fileprivate struct SearchResetInset: View {
    private let scrollDistance: CGFloat
    private let threshold: CGFloat
    private let isQueryEmpty: Bool
    private let isRefreshing: Bool
    private let isDragging: Bool
    private let isResettingTextField: Bool

    private var pullTitle: String {
        isQueryEmpty ? String(localized: "Pull down to show keyboard") : String(localized: "Pull down to clear")
    }

    private var releaseTitle: String {
        isQueryEmpty && !isResettingTextField ? String(localized: "Release to show keyboard") : String(localized: "Release to clear")
    }

    private var height: CGFloat {
        max(0, min(scrollDistance, threshold))
    }

    private var hasReachedThreshold: Bool {
        scrollDistance > threshold
    }

    private var rotateCondition: Bool {
        (hasReachedThreshold && isDragging) || isRefreshing
    }

    var body: some View {
        HStack {
            Image(systemName: "arrow.down")
                .font(.system(size: 30, weight: .regular))
                .rotationEffect(.degrees(rotateCondition ? 180 : 0))

            Text(rotateCondition ? releaseTitle : pullTitle)
                .font(.system(size: 15))
                .contentTransition(.identity)
        }
        .frame(height: threshold)
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .bottom)
        .clipped()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.15), value: hasReachedThreshold)
    }

    init(scrollDistance: CGFloat, threshold: CGFloat, isQueryEmpty: Bool, isRefreshing: Bool, isDragging: Bool, isResettingTextField: Bool) {
        self.scrollDistance = scrollDistance
        self.threshold = threshold
        self.isQueryEmpty = isQueryEmpty
        self.isRefreshing = isRefreshing
        self.isDragging = isDragging
        self.isResettingTextField = isResettingTextField
    }
}
