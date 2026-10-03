//
//  PopupView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import CHoshiDicts
import CxxStdlib

struct AnkiMiningToast: Identifiable, Equatable {
    let id = UUID()
    let result: AnkiMiningResult

    static func == (lhs: AnkiMiningToast, rhs: AnkiMiningToast) -> Bool {
        lhs.id == rhs.id
    }
}

struct AnkiMiningToastView: View {
    let toast: AnkiMiningToast

    private var title: String {
        switch toast.result.status {
        case .added: return String(localized: "Card Added")
        case .duplicate: return String(localized: "Duplicate Found")
        case .failed: return String(localized: "Add Failed")
        case .pending: return String(localized: "Sent to Anki")
        }
    }

    private var iconName: String {
        switch toast.result.status {
        case .added: return "checkmark.circle.fill"
        case .duplicate: return "doc.on.doc.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .pending: return "paperplane.fill"
        }
    }

    private var tint: Color {
        switch toast.result.status {
        case .added: return .green
        case .duplicate: return .orange
        case .failed: return .red
        case .pending: return .blue
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            toastContent
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: 420, alignment: .leading)
                .glassEffect(.regular.tint(tint.opacity(0.16)), in: .rect(cornerRadius: 28))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(tint.opacity(0.32), lineWidth: 1)
                )
                .shadow(color: tint.opacity(0.20), radius: 18, y: 8)
                .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
        }
        .padding(.horizontal, 18)
    }

    private var toastContent: some View {
        HStack(spacing: 13) {
            Image(systemName: iconName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(toast.result.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)
        }
    }
}

private struct ContextMiningDraft: Identifiable {
    let id = UUID()
    let content: [String: String]
    let selection: MiningContextSelection
    let entryIndex: Int?
}

struct PopupView: View {
    private struct ResolvedPopupLayout {
        let width: CGFloat
        let height: CGFloat
        let position: CGPoint
        let origin: CGPoint
    }

    @Environment(UserConfig.self) private var userConfig
    @Environment(ShortcutManager.self) private var shortcutManager
    @Binding var isVisible: Bool
    let selectionData: SelectionData?
    let lookupResults: [LookupResult]
    let dictionaryStyles: [String: String]
    let screenSize: CGSize
    let isVertical: Bool
    let isFullWidth: Bool
    let centersOnSelection: Bool
    let placement: PopupViewPlacement
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    let coverURL: URL?
    let documentTitle: String?
    let profileID: String?
    var clearSelection: Bool
    var onTextSelected: ((SelectionData) -> Int?)?
    var onTapOutside: (() -> Void)?
    var onSwipeDismiss: (() -> Void)?
    var onSasayakiJumpDismiss: (() -> Void)?
    var onPause: (() -> Void)?
    var sasayakiCue: SasayakiMatch?
    var sasayakiPlayer: SasayakiPlayer?
    var wasPaused = false
    var miningContextProvider: ((String, MiningContextSelectionResult?) async -> MiningContext)?

    @State private var content: String = ""
    @State private var lookupEntries: [[String: Any]] = []
    @State private var miningToast: AnkiMiningToast?
    @State private var miningToastTask: Task<Void, Never>?
    @State private var controlsHeight: CGFloat = 0
    @State private var backCount: Int = 0
    @State private var forwardCount: Int = 0
    @State private var backTrigger: Bool = false
    @State private var forwardTrigger: Bool = false
    @State private var contextMiningDraft: ContextMiningDraft?
    @State private var shortcutRegistrationID: UUID?
    @State private var dictionaryEntryNavigationSequence = 0
    @State private var dictionaryEntryNavigationCommand: DictionaryEntryNavigationCommand?
    @State private var ankiNoteCommandSequence = 0
    @State private var ankiNoteCommand: PopupAnkiNoteCommand?
    @State private var profileRepository = ProfileRepository.shared

    private var opaquePopupBackground: AnyShapeStyle {
        AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
    }

    @MainActor
    private var effectiveTwoColumnLayout: Bool {
        userConfig.dictionaryProfileSettings().twoColumnLayout ?? false
    }

    init(
        userConfig: UserConfig,
        isVisible: Binding<Bool>,
        selectionData: SelectionData?,
        lookupResults: [LookupResult],
        dictionaryStyles: [String: String],
        screenSize: CGSize,
        isVertical: Bool,
        isFullWidth: Bool,
        centersOnSelection: Bool = false,
        placement: PopupViewPlacement = .anchored,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        coverURL: URL?,
        documentTitle: String?,
        profileID: String? = nil,
        clearSelection: Bool,
        onTextSelected: ((SelectionData) -> Int?)? = nil,
        onTapOutside: (() -> Void)? = nil,
        onSwipeDismiss: (() -> Void)? = nil,
        onSasayakiJumpDismiss: (() -> Void)? = nil,
        onPause: (() -> Void)? = nil,
        sasayakiCue: SasayakiMatch? = nil,
        sasayakiPlayer: SasayakiPlayer? = nil,
        wasPaused: Bool = false,
        miningContextProvider: ((String, MiningContextSelectionResult?) async -> MiningContext)? = nil
    ) {
        _isVisible = isVisible
        self.selectionData = selectionData
        self.lookupResults = lookupResults
        self.dictionaryStyles = dictionaryStyles
        self.screenSize = screenSize
        self.isVertical = isVertical
        self.isFullWidth = isFullWidth
        self.centersOnSelection = centersOnSelection
        self.placement = placement
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.coverURL = coverURL
        self.documentTitle = documentTitle
        self.profileID = profileID
        self.clearSelection = clearSelection
        self.onTextSelected = onTextSelected
        self.onTapOutside = onTapOutside
        self.onSwipeDismiss = onSwipeDismiss
        self.onSasayakiJumpDismiss = onSasayakiJumpDismiss
        self.onPause = onPause
        self.sasayakiCue = sasayakiCue
        self.sasayakiPlayer = sasayakiPlayer
        self.wasPaused = wasPaused
        self.miningContextProvider = miningContextProvider

        let cache = Self.buildContent(lookupResults: lookupResults, userConfig: userConfig)
        _content = State(initialValue: cache.content)
        _lookupEntries = State(initialValue: cache.lookupEntries)
    }

    private var layout: ResolvedPopupLayout? {
        guard let selectionData else {
            return nil
        }

        if placement == .panelSurface {
            let width = max(0, screenSize.width)
            let height = max(0, screenSize.height)
            guard width.isFinite,
                  height.isFinite,
                  width > 0,
                  height > 0 else {
                return nil
            }
            return ResolvedPopupLayout(
                width: width,
                height: height,
                position: CGPoint(x: width / 2, y: height / 2),
                origin: .zero
            )
        }

        let result = PopupLayout(
            selectionRect: selectionData.rect,
            screenSize: screenSize,
            maxWidth: CGFloat(userConfig.popupWidth),
            maxHeight: CGFloat(userConfig.popupHeight),
            isVertical: isVertical,
            isFullWidth: isFullWidth,
            centersOnSelection: centersOnSelection,
            topInset: topInset,
            bottomInset: bottomInset
        )

        guard result.width.isFinite,
              result.height.isFinite,
              result.position.x.isFinite,
              result.position.y.isFinite else {
            return nil
        }

        return ResolvedPopupLayout(
            width: result.width,
            height: result.height,
            position: result.position,
            origin: CGPoint(
                x: result.position.x - result.width / 2,
                y: result.position.y - result.height / 2
            )
        )
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                historyBackButton
                historyForwardButton
                Spacer()
                popupCloseButton
            }
            .buttonStyle(.plain)
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            Divider()
        }
    }

    @ViewBuilder
    private func sasayakiControls(
        for cue: SasayakiMatch,
        player: SasayakiPlayer,
        includesActionBar: Bool
    ) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if includesActionBar {
                    HStack(spacing: 12) {
                        historyBackButton
                        historyForwardButton
                        Spacer()
                        popupCloseButton
                    }
                }

                HStack(spacing: 20) {
                    Button {
                        Task { @MainActor in
                            await WordAudioPlayer.shared.stop()
                            player.playCue(from: cue, stop: true)
                        }
                    } label: {
                        popupControlIcon("arrow.clockwise")
                    }

                    Button {
                        Task { @MainActor in
                            await WordAudioPlayer.shared.stop()
                            if wasPaused {
                                onPause?()
                            } else {
                                player.togglePlayback()
                            }
                        }
                    } label: {
                        popupControlIcon(player.isPlaying || wasPaused ? "pause.fill" : "play.fill")
                    }

                    Button {
                        Task { @MainActor in
                            await WordAudioPlayer.shared.stop()
                            (onSasayakiJumpDismiss ?? onSwipeDismiss)?()
                            player.playCue(from: cue, stop: false)
                        }
                    } label: {
                        popupControlIcon("forward.frame")
                    }
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            Divider()
        }
    }

    private var historyBackButton: some View {
        Button {
            backTrigger.toggle()
            backCount -= 1
            forwardCount += 1
        } label: {
            popupControlIcon("chevron.left")
                .opacity(backCount > 0 ? 1 : 0.3)
        }
        .disabled(backCount == 0)
    }

    private var historyForwardButton: some View {
        Button {
            forwardTrigger.toggle()
            forwardCount -= 1
            backCount += 1
        } label: {
            popupControlIcon("chevron.right")
                .opacity(forwardCount > 0 ? 1 : 0.3)
        }
        .disabled(forwardCount == 0)
    }

    private var popupCloseButton: some View {
        Button {
            onSwipeDismiss?()
        } label: {
            popupControlIcon("xmark")
        }
    }

    private func popupControlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .frame(width: 52, height: 32)
            .contentShape(Rectangle())
    }

    private func popupContent(selectionData: SelectionData, layout: ResolvedPopupLayout) -> some View {
        let showsActionBar = userConfig.popupActionBar || backCount > 0 || forwardCount > 0
        let activeControlsHeight = showsActionBar || (sasayakiCue != nil && sasayakiPlayer?.hasAudio == true) ? controlsHeight : 0

        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let cue = sasayakiCue, let player = sasayakiPlayer, player.hasAudio {
                    sasayakiControls(for: cue, player: player, includesActionBar: showsActionBar)
                } else if showsActionBar {
                    actionBar
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                controlsHeight = $0
            }

            PopupWebView(
                content: content,
                position: CGPoint(x: layout.origin.x, y: layout.origin.y + activeControlsHeight),
                scale: CGFloat(userConfig.popupScale),
                twoColumnLayout: effectiveTwoColumnLayout,
                clearSelection: clearSelection,
                hoverLookupDelayMs: userConfig.desktopLookupHoverDelayMs,
                dictionaryStyles: dictionaryStyles,
                lookupEntries: lookupEntries,
                scanNonJapaneseText: userConfig.scanNonJapaneseText,
                scanLength: userConfig.scanLength,
                profileID: profileRepository.activeProfile.id,
                contentLanguageID: profileRepository.activeProfile.language.rawValue,
                backTrigger: backTrigger,
                forwardTrigger: forwardTrigger,
                dictionaryEntryNavigationCommand: dictionaryEntryNavigationCommand,
                ankiNoteCommand: ankiNoteCommand,
                onMine: { content in
                    let result = await mineEntry(
                        content: content,
                        sentence: selectionData.sentence,
                        contextSelection: nil
                    )
                    showMiningToast(for: result)
                    return result
                },
                onMiningFeedback: { result in
                    showMiningToast(for: result)
                },
                onPrepareContextMining: selectionData.miningContext.map { miningContext in
                    { content in
                        contextMiningDraft = ContextMiningDraft(
                            content: content,
                            selection: miningContext,
                            entryIndex: content["_entryIndex"].flatMap(Int.init)
                        )
                    }
                },
                onTextSelected: onTextSelected,
                onTapOutside: onTapOutside,
                onSwipeDismiss: onSwipeDismiss,
                onRedirect: { query in
                    let results = LookupEngine.shared.lookup(
                        query,
                        maxResults: userConfig.maxResults,
                        scanLength: userConfig.scanLength
                    )
                    let entries = Self.buildLookupEntries(lookupResults: results)
                    if !entries.isEmpty {
                        backCount += 1
                        forwardCount = 0
                    }
                    return entries
                },
                onKanjiRedirect: { kanji in
                    let data = LookupEngine.shared.queryKanji(kanji)
                    if data != nil {
                        backCount += 1
                        forwardCount = 0
                    }
                    return data
                }
            )
        }
        .frame(width: layout.width, height: layout.height)
    }

    var body: some View {
        Group {
            if #available(iOS 26, macOS 26, *), !userConfig.popupDisableTransparency {
                GlassEffectContainer(spacing: 18) {
                    ZStack(alignment: .top) {
                        if isVisible, let selectionData, let layout, !content.isEmpty {
                            popupContent(selectionData: selectionData, layout: layout)
                                .glassEffect(.regular, in: .rect(cornerRadius: 8))
                                .position(layout.position)
                        }
                        topToast
                    }
                }
                .frame(width: screenSize.width, height: screenSize.height, alignment: .top)
            } else {
                ZStack(alignment: .top) {
                    if isVisible, let selectionData, let layout, !content.isEmpty {
                        popupContent(selectionData: selectionData, layout: layout)
                            .background(
                                opaquePopupBackground,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.2), lineWidth: 1))
                            .position(layout.position)
                    }
                    topToast
                }
                .frame(width: screenSize.width, height: screenSize.height, alignment: .top)
            }
        }
        .onAppear {
            registerKeyboardShortcuts()
        }
        .onDisappear {
            unregisterKeyboardShortcuts()
        }
        .sheet(item: $contextMiningDraft) { draft in
            MiningContextSelectionView(
                selection: draft.selection,
                onCancel: {
                    contextMiningDraft = nil
                },
                onConfirm: { contextSelection in
                    let result = await mineEntry(
                        content: draft.content,
                        sentence: contextSelection.sentence,
                        contextSelection: contextSelection
                    )
                    if let noteID = result.noteID, let entryIndex = draft.entryIndex {
                        showAnkiNoteButton(entryIndex: entryIndex, noteID: noteID)
                    }
                    showMiningToast(for: result)
                    return result
                }
            )
        }
    }

    @ViewBuilder
    private var topToast: some View {
        if let miningToast {
            AnkiMiningToastView(toast: miningToast)
                .padding(.top, max(18, topInset + 18))
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1000)
                .allowsHitTesting(false)
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
        guard isVisible, !lookupEntries.isEmpty else { return false }
        dictionaryEntryNavigationSequence += 1
        dictionaryEntryNavigationCommand = DictionaryEntryNavigationCommand(
            sequence: dictionaryEntryNavigationSequence,
            direction: direction,
            count: max(1, userConfig.dictionaryEntryJumpCount)
        )
        return true
    }

    private func mineEntry(
        content: [String: String],
        sentence: String,
        contextSelection: MiningContextSelectionResult?
    ) async -> AnkiMiningResult {
        let miningProfileID = profileRepository.activeProfile.id
        if let preflightResult = await preflightAnkiMining(content: content) {
            return preflightResult
        }
        guard profileRepository.activeProfile.id == miningProfileID else {
            return .failed(String(localized: "The active Profile changed. Try adding the card again."))
        }

        let miningAudioFormat = AnkiManager.shared.audioCompressionFormat
        let miningAudioBitrateKbps = AnkiManager.shared.audioCompressionBitrateKbps
        var sasayakiAudioData: Data?
        if AnkiManager.shared.needsSasayakiAudio, let cue = sasayakiCue, let player = sasayakiPlayer, player.hasAudio {
            sasayakiAudioData = await player.cueSentenceAudio(
                cue,
                sentence: sentence,
                format: miningAudioFormat,
                bitrateKbps: miningAudioBitrateKbps
            )
            guard profileRepository.activeProfile.id == miningProfileID else {
                return .failed(String(localized: "The active Profile changed. Try adding the card again."))
            }
        }

        var context = if let miningContextProvider {
            await miningContextProvider(sentence, contextSelection)
        } else {
            MiningContext(
                sentence: sentence,
                documentTitle: documentTitle,
                coverURL: coverURL,
                profileID: miningProfileID,
                sasayakiAudioData: sasayakiAudioData,
                sasayakiAudioFormat: miningAudioFormat
            )
        }
        context.sasayakiAudioFormat = miningAudioFormat
        guard profileRepository.activeProfile.id == miningProfileID else {
            return .failed(String(localized: "The active Profile changed. Try adding the card again."))
        }
        context.profileID = miningProfileID
        return await mineAnkiEntry(content: content, context: context, preflightAlreadyPassed: true)
    }

    private func showMiningToast(for result: AnkiMiningResult) {
        withAnimation(.default.speed(1.4)) {
            miningToast = AnkiMiningToast(result: result)
        }
        miningToastTask?.cancel()
        miningToastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.default.speed(1.4)) {
                    miningToast = nil
                }
            }
        }
    }

    private func showAnkiNoteButton(entryIndex: Int, noteID: Int64) {
        ankiNoteCommandSequence += 1
        ankiNoteCommand = PopupAnkiNoteCommand(
            sequence: ankiNoteCommandSequence,
            entryIndex: entryIndex,
            noteID: noteID
        )
    }

    private static func buildLookupEntries(lookupResults: [LookupResult]) -> [[String: Any]] {
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
                    "transcriptions": transcriptions
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

    private static func buildContent(lookupResults: [LookupResult], userConfig: UserConfig) -> (content: String, lookupEntries: [[String: Any]]) {
        let entries = buildLookupEntries(lookupResults: lookupResults)

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

        let content = """
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
            window.swipeThreshold = \(userConfig.popupSwipeToDismiss ? userConfig.popupSwipeThreshold : 0);
        </script>
        <div id="entries-container"></div>
        """

        return (content, entries)
    }
}
