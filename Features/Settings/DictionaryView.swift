//
//  DictionaryView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UniformTypeIdentifiers
import SwiftUI

struct DictionaryView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var dictionaryManager = DictionaryManager.shared
    @State private var isImporting = false
    @State private var showCSSEditor = false
    @State private var showCollapsedDictionaryCustomization = false
    @State private var showRecommendedDictionaryPicker = false
    @State private var showUpdateDictionaryPicker = false
    @State private var showNoDictionaryUpdatesAlert = false
    @State private var selectedRecommendedDictionaryIDs: Set<String> = []
    @State private var selectedUpdatableDictionaryIDs: Set<UUID> = []
    @State private var selectedType: DictionaryType = .term
    @State private var dropTargetDictionaryID: UUID?
    @State private var activeDictionaryDragSourceID: UUID?
    @State private var dictionaryRowFrames: [UUID: CGRect] = [:]
    @State private var isDownloadingKanjiFont = false
    @State private var hasKanjiStrokeOrderFont = FontManager.shared.hasKanjiStrokeOrderFont
    @State private var showFontDownloadConfirmation = false

    private var dictionaries: [DictionaryInfo] {
        switch selectedType {
        case .term: return dictionaryManager.termDictionaries
        case .frequency: return dictionaryManager.frequencyDictionaries
        case .pitch: return dictionaryManager.pitchDictionaries
        case .kanji: return dictionaryManager.kanjiDictionaries
        }
    }

    private var dictionaryReorderCoordinateSpaceName: String {
        "settings-dictionary-reorder-\(selectedType.rawValue)"
    }

    private var updateCandidates: [DictionaryUpdateCandidate] {
        dictionaryManager.availableDictionaryUpdates.map { dictionary, type in
            DictionaryUpdateCandidate(dictionary: dictionary, type: type)
        }
    }

    private var selectedRecommendedDictionaries: [DictionaryRecommendation] {
        dictionaryManager.recommendedDictionaries.filter { selectedRecommendedDictionaryIDs.contains($0.id) }
    }

    private var selectedUpdateDictionaries: [(DictionaryInfo, DictionaryType)] {
        updateCandidates
            .filter { selectedUpdatableDictionaryIDs.contains($0.id) }
            .map { ($0.dictionary, $0.type) }
    }

    private var lastUpdate: String {
        guard let date = UserDefaults.standard.object(forKey: "lastDictionaryUpdate") as? Date else {
            return String(localized: "Never", table: "Dictionaries")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func dictionaryUpdateIntervalText(_ interval: DictionaryUpdateInterval) -> Text {
        switch interval {
        case .daily:
            Text("Daily", tableName: "Dictionaries")
        case .weekly:
            Text("Weekly", tableName: "Dictionaries")
        case .monthly:
            Text("Monthly", tableName: "Dictionaries")
        }
    }

    var body: some View {
        @Bindable var userConfig = userConfig
        NativeSettingsForm {
            NativeSettingsSectionCard {
                Text("Dictionaries", tableName: "Dictionaries")
            } content: {
                NativeSettingsButtonRow {
                    Button {
                        selectedRecommendedDictionaryIDs = Set(dictionaryManager.recommendedDictionaries.map(\.id))
                        showRecommendedDictionaryPicker = true
                    } label: {
                        Text("Download Recommended Dictionaries", tableName: "Dictionaries")
                    }
                    .disabled(dictionaryManager.isImporting || dictionaryManager.recommendedDictionaries.isEmpty)

                    Button {
                        isImporting = true
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .fileImporter(
                        isPresented: $isImporting,
                        allowedContentTypes: [.zip],
                        allowsMultipleSelection: true,
                        onCompletion: { result in
                            if case .success(let urls) = result {
                                dictionaryManager.importDictionary(from: urls)
                            }
                        }
                    )
                    .disabled(dictionaryManager.isImporting || dictionaryManager.isUpdating)

                    Button {
                        showCSSEditor = true
                    } label: {
                        Label {
                            Text("Custom CSS", tableName: "Dictionaries")
                        } icon: {
                            Image(systemName: "curlybraces")
                        }
                    }
                    .disabled(dictionaryManager.isImporting || dictionaryManager.isUpdating)
                }
                NativeSettingsSeparator()
                NativeSettingsRow {
                    Text("Supported Formats", tableName: "Dictionaries")
                } accessory: {
                    Text("Yomitan term, frequency, pitch and kanji dictionaries (.zip) are supported", tableName: "Dictionaries")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }

            if !dictionaryManager.kanjiDictionaries.isEmpty {
                NativeSettingsSectionCard {
                    Text("Kanji", tableName: "Dictionaries")
                } content: {
                    NativeSettingsRow {
                        Text("Stroke Order Font", tableName: "Dictionaries")
                    } accessory: {
                        if hasKanjiStrokeOrderFont {
                            Text("Installed", tableName: "Dictionaries")
                                .foregroundStyle(.secondary)
                        } else {
                            Button {
                                showFontDownloadConfirmation = true
                            } label: {
                                Text("Download", tableName: "Dictionaries")
                            }
                            .buttonStyle(NativeSettingsActionButtonStyle())
                            .disabled(isDownloadingKanjiFont)
                        }
                    }
                } footer: {
                    Text("Shows stroke order diagrams for the character in kanji entries.", tableName: "Dictionaries")
                }
            }

            if dictionaryManager.updatableDictionaries.count > 0 {
                NativeSettingsSectionCard {
                    Text("Updates", tableName: "Dictionaries")
                } content: {
                    NativeSettingsToggle(
                        "Update Automatically",
                        isOn: $userConfig.autoUpdateDictionaries
                    )
                    if userConfig.autoUpdateDictionaries {
                        NativeSettingsSeparator()
                        NativeSettingsRow {
                            Text("Interval", tableName: "Dictionaries")
                        } accessory: {
                            NativeGlassSegmentedPicker(
                                selection: $userConfig.dictionaryUpdateInterval,
                                values: DictionaryUpdateInterval.allCases,
                                minSegmentWidth: 66
                            ) { interval in
                                dictionaryUpdateIntervalText(interval)
                            }
                        }
                    }
                    NativeSettingsSeparator()
                    NativeSettingsRow {
                        Text("Last Update", tableName: "Dictionaries")
                    } accessory: {
                        Text(verbatim: lastUpdate)
                            .foregroundStyle(.secondary)
                    }
                    NativeSettingsSeparator()
                    NativeSettingsButtonRow {
                        Button {
                            Task {
                                let updates = await dictionaryManager.refreshAvailableDictionaryUpdates()
                                selectedUpdatableDictionaryIDs = Set(updates.map { $0.0.id })
                                if updates.isEmpty {
                                    if !dictionaryManager.shouldShowError {
                                        showNoDictionaryUpdatesAlert = true
                                    }
                                } else {
                                    showUpdateDictionaryPicker = true
                                }
                            }
                        } label: {
                            Text("Update Dictionaries", tableName: "Dictionaries")
                        }
                        .disabled(
                            dictionaryManager.isCheckingUpdates
                                || dictionaryManager.isUpdating
                                || dictionaryManager.updatableDictionaries.isEmpty
                        )
                    }
                }
            }

            NativeSettingsSectionCard("Settings") {
                NativeSettingsToggle(
                    "Default to Dictionary Tab",
                    isOn: $userConfig.dictionaryTabDefault
                )
            }

            DictionaryBehaviorSettingsSections(
                showCollapsedDictionaryCustomization: $showCollapsedDictionaryCustomization
            )

            NativeSettingsSectionCard {
                HStack {
                    Text("Dictionaries", tableName: "Dictionaries")
                    Spacer()
                    dictionaryTypePicker
                }
            } content: {
                VStack(spacing: 0) {
                    ForEach(Array(dictionaries.enumerated()), id: \.element.id) { index, dict in
                        if index > 0 {
                            NativeSettingsSeparator()
                        }
                        NativeSettingsRow {
                            HStack(spacing: 10) {
                                dictionaryReorderHandle()
                                    .contentShape(Rectangle())
                                    .highPriorityGesture(dictionaryReorderGesture(for: dict.id))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: dict.index.title)
                                    Text(verbatim: dict.index.revision)
                                        .lineLimit(1)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } accessory: {
                            if selectedType == .term {
                                DictionaryCategoryPicker(selection: Binding(
                                    get: { dict.category },
                                    set: { dictionaryManager.setDictionaryCategory(id: dict.id, category: $0) }
                                ))
                            }
                            Toggle("", isOn: Binding(
                                get: { dict.isEnabled },
                                set: { dictionaryManager.toggleDictionary(id: dict.id, enabled: $0, type: selectedType) }
                            ))
                            .labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .background {
                            if dropTargetDictionaryID == dict.id {
                                Color.accentColor.opacity(0.12)
                            }
                        }
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: DictionaryRowFramePreferenceKey.self,
                                    value: [dict.id: proxy.frame(in: .named(dictionaryReorderCoordinateSpaceName))]
                                )
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteDictionary(dict)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .scaleEffect(activeDictionaryDragSourceID == dict.id ? 1.01 : 1)
                        .zIndex(activeDictionaryDragSourceID == dict.id ? 1 : 0)
                        .frame(maxWidth: .infinity)
                    }
                }
                .coordinateSpace(name: dictionaryReorderCoordinateSpaceName)
                .onPreferenceChange(DictionaryRowFramePreferenceKey.self) { frames in
                    dictionaryRowFrames = frames
                }
            }
        }
        .sheet(isPresented: $showCSSEditor) {
            DictionaryDetailSettingView()
        }
        .sheet(isPresented: $showCollapsedDictionaryCustomization) {
            CollapsedDictionariesSheet()
        }
        .sheet(isPresented: $showRecommendedDictionaryPicker) {
            RecommendedDictionarySelectionSheet(
                recommendations: dictionaryManager.recommendedDictionaries,
                selectedIDs: $selectedRecommendedDictionaryIDs
            ) {
                let selectedRecommendations = selectedRecommendedDictionaries
                dictionaryManager.importRecommendedDictionaries(selectedRecommendations)
            }
        }
        .sheet(isPresented: $showUpdateDictionaryPicker) {
            DictionaryUpdateSelectionSheet(
                candidates: updateCandidates,
                selectedIDs: $selectedUpdatableDictionaryIDs
            ) {
                let selectedDictionaries = selectedUpdateDictionaries
                dictionaryManager.updateDictionaries(selectedDictionaries, refreshAvailabilityAfterUpdate: true)
            }
        }
        .overlay {
            if dictionaryManager.isImporting || dictionaryManager.isUpdating || dictionaryManager.isCheckingUpdates {
                LoadingOverlay(dictionaryManager.currentImport)
            } else if isDownloadingKanjiFont {
                LoadingOverlay(String(localized: "Downloading Stroke Order Font", table: "Dictionaries"))
            }
        }
        .alert(String(localized: "Download Font", table: "Dictionaries"), isPresented: $showFontDownloadConfirmation) {
            Button {
                downloadKanjiStrokeOrderFont()
            } label: {
                Text("Download", tableName: "Dictionaries")
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", tableName: "Dictionaries")
            }
        } message: {
            Text("This will download and automatically import the kanji stroke order font (17 MB).", tableName: "Dictionaries")
        }
        .navigationTitle(String(localized: "Dictionaries", table: "Dictionaries"))
        .alert(String(localized: "Error", table: "Dictionaries"), isPresented: $dictionaryManager.shouldShowError) {
            Button(role: .cancel) {
            } label: {
                Text("OK", tableName: "Dictionaries")
            }
        } message: {
            Text(verbatim: dictionaryManager.errorMessage)
        }
        .alert(String(localized: "No Dictionary Updates", table: "Dictionaries"), isPresented: $showNoDictionaryUpdatesAlert) {
            Button(role: .cancel) {
            } label: {
                Text("OK", tableName: "Dictionaries")
            }
        } message: {
            Text("All dictionaries are already up to date.", tableName: "Dictionaries")
        }
    }

    private func downloadKanjiStrokeOrderFont() {
        isDownloadingKanjiFont = true
        Task {
            let success = await FontManager.downloadKanjiStrokeOrderFont()
            isDownloadingKanjiFont = false
            hasKanjiStrokeOrderFont = FontManager.shared.hasKanjiStrokeOrderFont
            if !success {
                dictionaryManager.errorMessage = String(localized: "Failed to download the stroke order font", table: "Dictionaries")
                dictionaryManager.shouldShowError = true
            }
        }
    }

    private func deleteDictionary(_ dictionary: DictionaryInfo) {
        guard let index = dictionaries.firstIndex(where: { $0.id == dictionary.id }) else {
            return
        }
        dictionaryManager.deleteDictionary(indexSet: IndexSet(integer: index), type: selectedType)
    }

    private func reorderDictionary(_ sourceID: UUID, onto targetID: UUID) -> Bool {
        guard let sourceIndex = dictionaries.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = dictionaries.firstIndex(where: { $0.id == targetID }),
              let destination = DictionaryReorder.destinationOffset(
                sourceIndex: sourceIndex,
                targetIndex: targetIndex
              ) else {
            return false
        }
        withAnimation(.snappy(duration: 0.18)) {
            dictionaryManager.moveDictionary(
                from: IndexSet(integer: sourceIndex),
                to: destination,
                type: selectedType
            )
        }
        return true
    }

    private func dictionaryReorderGesture(for sourceID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(dictionaryReorderCoordinateSpaceName))
            .onChanged { value in
                updateDictionaryDrag(sourceID, to: value.location)
            }
            .onEnded { value in
                endDictionaryDrag(sourceID, at: value.location)
            }
    }

    private func updateDictionaryDrag(_ sourceID: UUID, to location: CGPoint) {
        beginDictionaryDragIfNeeded(sourceID)
        guard let targetID = dictionaryRowFrames.first(where: { id, frame in
            id != sourceID && frame.insetBy(dx: -4, dy: -4).contains(location)
        })?.key else {
            return
        }
        guard dropTargetDictionaryID != targetID else {
            return
        }
        if reorderDictionary(sourceID, onto: targetID) {
            dropTargetDictionaryID = targetID
        }
    }

    private func endDictionaryDrag(_ sourceID: UUID, at location: CGPoint) {
        updateDictionaryDrag(sourceID, to: location)
        withAnimation(.easeOut(duration: 0.16)) {
            activeDictionaryDragSourceID = nil
            dropTargetDictionaryID = nil
        }
    }

    private func beginDictionaryDragIfNeeded(_ sourceID: UUID) {
        guard activeDictionaryDragSourceID != sourceID else {
            return
        }
        withAnimation(.snappy(duration: 0.16)) {
            activeDictionaryDragSourceID = sourceID
            dropTargetDictionaryID = nil
        }
    }

    private func dictionaryReorderHandle() -> some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 32)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var dictionaryListHeader: some View {
        #if os(macOS)
        Text("Dictionaries", tableName: "Dictionaries")
        #else
        dictionaryTypePicker
            .listRowInsets(EdgeInsets())
            .padding(.bottom, 12)
        #endif
    }

    private var dictionaryTypePicker: some View {
        NativeGlassSegmentedPicker(
            selection: $selectedType,
            values: [DictionaryType.term, .frequency, .pitch, .kanji],
            minSegmentWidth: 72
        ) { type in
            switch type {
            case .term:
                Text("Term", tableName: "Dictionaries")
            case .frequency:
                Text("Frequency", tableName: "Dictionaries")
            case .pitch:
                Text("Pitch", tableName: "Dictionaries")
            case .kanji:
                Text("Kanji", tableName: "Dictionaries")
            }
        }
    }
}

private struct DictionaryUpdateCandidate: Identifiable {
    let dictionary: DictionaryInfo
    let type: DictionaryType

    var id: UUID {
        dictionary.id
    }
}

private struct RecommendedDictionarySelectionSheet: View {
    let recommendations: [DictionaryRecommendation]
    @Binding var selectedIDs: Set<String>
    let onDownload: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var allSelected: Bool {
        !recommendations.isEmpty && recommendations.allSatisfy { selectedIDs.contains($0.id) }
    }

    var body: some View {
        DictionarySelectionSheetSurface(
            title: String(localized: "Download Dictionaries", table: "Dictionaries")
        ) {
            NativeSettingsSectionCard {
                Text("Dictionaries", tableName: "Dictionaries")
            } content: {
                ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, recommendation in
                    if index > 0 {
                        NativeSettingsSeparator()
                    }
                    DictionarySelectionRow(isSelected: selectionBinding(for: recommendation.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: recommendation.name)
                                .font(.body.weight(.medium))
                            DictionaryTypeBadge(type: recommendation.type)
                        }
                    }
                }
            }
        } actionBar: {
            DictionarySelectionActionBar {
                Button {
                    toggleAll()
                } label: {
                    if allSelected {
                        Text("Clear", tableName: "Dictionaries")
                    } else {
                        Text("Select All", tableName: "Dictionaries")
                    }
                }
                .buttonStyle(DictionarySelectionActionButtonStyle())

                Spacer(minLength: 24)

                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel", tableName: "Dictionaries")
                }
                .buttonStyle(DictionarySelectionActionButtonStyle())

                Button {
                    dismiss()
                    onDownload()
                } label: {
                    Text("Download", tableName: "Dictionaries")
                }
                .disabled(selectedIDs.isEmpty)
                .buttonStyle(DictionarySelectionActionButtonStyle(isProminent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding {
            selectedIDs.contains(id)
        } set: { isSelected in
            if isSelected {
                selectedIDs.insert(id)
            } else {
                selectedIDs.remove(id)
            }
        }
    }

    private func toggleAll() {
        if allSelected {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(recommendations.map(\.id))
        }
    }
}

private struct DictionaryUpdateSelectionSheet: View {
    let candidates: [DictionaryUpdateCandidate]
    @Binding var selectedIDs: Set<UUID>
    let onUpdate: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var allSelected: Bool {
        !candidates.isEmpty && candidates.allSatisfy { selectedIDs.contains($0.id) }
    }

    var body: some View {
        DictionarySelectionSheetSurface(
            title: String(localized: "Update Dictionaries", table: "Dictionaries")
        ) {
            NativeSettingsSectionCard {
                Text("Dictionaries", tableName: "Dictionaries")
            } content: {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 {
                        NativeSettingsSeparator()
                    }
                    DictionarySelectionRow(isSelected: selectionBinding(for: candidate.id)) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: candidate.dictionary.index.title)
                                    .font(.body.weight(.medium))
                                Text(verbatim: candidate.dictionary.index.revision)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 16)
                            DictionaryTypeBadge(type: candidate.type)
                        }
                    }
                }
            }
        } actionBar: {
            DictionarySelectionActionBar {
                Button {
                    toggleAll()
                } label: {
                    if allSelected {
                        Text("Clear", tableName: "Dictionaries")
                    } else {
                        Text("Select All", tableName: "Dictionaries")
                    }
                }
                .buttonStyle(DictionarySelectionActionButtonStyle())

                Spacer(minLength: 24)

                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel", tableName: "Dictionaries")
                }
                .buttonStyle(DictionarySelectionActionButtonStyle())

                Button {
                    dismiss()
                    onUpdate()
                } label: {
                    Text("Update", tableName: "Dictionaries")
                }
                .disabled(selectedIDs.isEmpty)
                .buttonStyle(DictionarySelectionActionButtonStyle(isProminent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding {
            selectedIDs.contains(id)
        } set: { isSelected in
            if isSelected {
                selectedIDs.insert(id)
            } else {
                selectedIDs.remove(id)
            }
        }
    }

    private func toggleAll() {
        if allSelected {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(candidates.map(\.id))
        }
    }
}

private struct DictionarySelectionSheetSurface<Content: View, ActionBar: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actionBar: () -> ActionBar

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NativeSettingsForm(horizontalPadding: 18, verticalPadding: 18, spacing: 16) {
                    content()
                }
                actionBar()
            }
            .background {
                NativeGlassPageBackground()
            }
            .navigationTitle(title)
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}

private struct DictionarySelectionActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                content()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct DictionarySelectionActionButtonStyle: ButtonStyle {
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .frame(minWidth: 86, minHeight: 34)
            .contentShape(Capsule())
            .background {
                if isProminent {
                    Capsule()
                        .fill(Color.accentColor.opacity(isEnabled ? 0.34 : 0.12))
                } else if configuration.isPressed {
                    Capsule()
                        .fill(.secondary.opacity(0.12))
                }
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }

    private var foregroundStyle: Color {
        if !isEnabled {
            return .secondary
        }
        return isProminent ? .accentColor : .primary
    }
}

private struct DictionarySelectionRow<Label: View>: View {
    @Binding var isSelected: Bool
    @ViewBuilder var label: () -> Label

    var body: some View {
        Toggle(isOn: $isSelected) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .toggleStyle(.checkbox)
        .frame(minHeight: 46)
        .padding(.horizontal, 16)
    }
}

/// Category used by the monolingual/bilingual Anki handlebars; Exclude leaves the dictionary out of `{glossary}`.
private struct DictionaryCategoryPicker: View {
    @Binding var selection: DictionaryCategory

    var body: some View {
        Picker(selection: $selection) {
            ForEach(DictionaryCategory.allCases) { category in
                categoryText(category).tag(category)
            }
        } label: {
            Text("Category", tableName: "Dictionaries")
        }
        .labelsHidden()
        .fixedSize()
        .help(String(localized: "Category for Anki definition fields", table: "Dictionaries"))
    }

    private func categoryText(_ category: DictionaryCategory) -> Text {
        switch category {
        case .none:
            Text("No Category", tableName: "Dictionaries")
        case .monolingual:
            Text("Monolingual", tableName: "Dictionaries")
        case .bilingual:
            Text("Bilingual", tableName: "Dictionaries")
        case .exclude:
            Text("Exclude", tableName: "Dictionaries")
        }
    }
}

private struct DictionaryTypeBadge: View {
    let type: DictionaryType

    var body: some View {
        dictionaryTypeText
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var dictionaryTypeText: some View {
        switch type {
        case .term:
            Text("Term", tableName: "Dictionaries")
        case .frequency:
            Text("Frequency", tableName: "Dictionaries")
        case .pitch:
            Text("Pitch", tableName: "Dictionaries")
        case .kanji:
            Text("Kanji", tableName: "Dictionaries")
        }
    }
}

private struct DictionaryRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct DictionaryBehaviorSettingsSections: View {
    @Environment(UserConfig.self) private var userConfig
    @Binding var showCollapsedDictionaryCustomization: Bool

    var body: some View {
        @Bindable var userConfig = userConfig
        Group {
            NativeSettingsSectionCard {
                Text("Lookup", tableName: "Dictionaries")
            } content: {
                NativeSettingsToggle(
                    "Scan Non-Japanese Text",
                    isOn: $userConfig.scanNonJapaneseText
                )
                NativeSettingsSeparator()
                NativeSettingsRow {
                    Text("Max Results", tableName: "Dictionaries")
                } accessory: {
                    Text(verbatim: "\(userConfig.maxResults)")
                        .fontWeight(.semibold)
                    Stepper(value: $userConfig.maxResults, in: 1...50) {
                        Text("Max Results", tableName: "Dictionaries")
                    }
                    .labelsHidden()
                }
                NativeSettingsSeparator()
                NativeSettingsRow {
                    Text("Scan Length", tableName: "Dictionaries")
                } accessory: {
                    Text(verbatim: "\(userConfig.scanLength)")
                        .fontWeight(.semibold)
                    Stepper(value: $userConfig.scanLength, in: 1...64) {
                        Text("Scan Length", tableName: "Dictionaries")
                    }
                    .labelsHidden()
                }
                NativeSettingsSeparator()
                NativeSettingsRow {
                    Text("Frequency Sorting", tableName: "Dictionaries")
                } accessory: {
                    Picker(selection: $userConfig.frequencySortOrder) {
                        ForEach(LookupFrequencySortOrder.allCases, id: \.self) { order in
                            frequencySortOrderText(order).tag(order)
                        }
                    } label: {
                        Text("Frequency Sorting", tableName: "Dictionaries")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if userConfig.frequencySortOrder != .auto {
                    NativeSettingsSeparator()
                    NativeSettingsRow {
                        Text("Frequency Dictionary", tableName: "Dictionaries")
                    } accessory: {
                        Picker(selection: $userConfig.frequencySortDictionary) {
                            if !frequencyDictionaryTitles.contains(userConfig.frequencySortDictionary) {
                                Text("None", tableName: "Dictionaries").tag(userConfig.frequencySortDictionary)
                            }
                            ForEach(frequencyDictionaryTitles, id: \.self) { title in
                                Text(verbatim: title).tag(title)
                            }
                        } label: {
                            Text("Frequency Dictionary", tableName: "Dictionaries")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } footer: {
                if userConfig.frequencySortOrder != .auto {
                    Text(
                        "Results with the same match are ranked by the selected frequency dictionary. Results without a value are listed last.",
                        tableName: "Dictionaries"
                    )
                }
            }

            NativeSettingsSectionCard {
                Text("Search Text", tableName: "Dictionaries")
            } content: {
                NativeSettingsRow {
                    Text("Text Size", tableName: "Dictionaries")
                } accessory: {
                    Text(verbatim: "\(userConfig.searchTextSize)")
                        .fontWeight(.semibold)
                    Stepper(value: $userConfig.searchTextSize, in: 12...48) {
                        Text("Text Size", tableName: "Dictionaries")
                    }
                    .labelsHidden()
                }
            }

            NativeSettingsSectionCard {
                Text("Collapse Dictionaries", tableName: "Dictionaries")
            } content: {
                NativeSettingsRow {
                    Text("Mode", tableName: "Dictionaries")
                } accessory: {
                    NativeGlassSegmentedPicker(
                        selection: $userConfig.collapseMode,
                        values: CollapseMode.allCases,
                        minSegmentWidth: 82
                    ) { mode in
                        collapseModeText(mode)
                    }
                }
                if userConfig.collapseMode != .expandAll {
                    NativeSettingsSeparator()
                    NativeSettingsToggle(
                        "Expand First Dictionary",
                        isOn: $userConfig.expandFirstDictionary
                    )
                }
                if userConfig.collapseMode == .custom {
                    NativeSettingsSeparator()
                    NativeSettingsButtonRow {
                        Button {
                            showCollapsedDictionaryCustomization = true
                        } label: {
                            Text("Configure", tableName: "Dictionaries")
                        }
                    }
                }
            }

            NativeSettingsSectionCard {
                Text("Behaviour", tableName: "Dictionaries")
            } content: {
                NativeSettingsToggle("Two-Column Layout", isOn: $userConfig.twoColumnLayout)
                NativeSettingsSeparator()
                NativeSettingsToggle("Compact Glossaries", isOn: $userConfig.compactGlossaries)
                NativeSettingsSeparator()
                NativeSettingsToggle("Show Expression Tags", isOn: $userConfig.showExpressionTags)
                NativeSettingsSeparator()
                NativeSettingsToggle("Harmonic Frequency", isOn: $userConfig.harmonicFrequency)
                NativeSettingsSeparator()
                NativeSettingsToggle("Deduplicate Pitch Accents", isOn: $userConfig.deduplicatePitchAccents)
                NativeSettingsSeparator()
                NativeSettingsToggle("Compact Pitch Accents", isOn: $userConfig.compactPitchAccents)
                NativeSettingsSeparator()
                NativeSettingsSliderRow(
                    title: "Mac Hover Delay",
                    value: "\(userConfig.desktopLookupHoverDelayMs) ms"
                ) {
                    Slider(value: .init(
                        get: { Double(userConfig.desktopLookupHoverDelayMs) },
                        set: { userConfig.desktopLookupHoverDelayMs = Int($0) }
                    ), in: 0...250, step: 5)
                }
            } footer: {
                Text(
                    "Arranges glossaries in two columns. Only recommended when used with full-width or on larger screens.",
                    tableName: "Dictionaries"
                )
            }
        }
    }

    private var frequencyDictionaryTitles: [String] {
        DictionaryManager.shared.frequencyDictionaries
            .filter(\.isEnabled)
            .map(\.index.title)
    }

    private func frequencySortOrderText(_ order: LookupFrequencySortOrder) -> Text {
        switch order {
        case .auto:
            Text("Auto", tableName: "Dictionaries")
        case .ascending:
            Text("Ascending", tableName: "Dictionaries")
        case .descending:
            Text("Descending", tableName: "Dictionaries")
        }
    }

    private func collapseModeText(_ mode: CollapseMode) -> Text {
        switch mode {
        case .expandAll:
            Text("Expand All", tableName: "Dictionaries")
        case .collapseAll:
            Text("Collapse All", tableName: "Dictionaries")
        case .custom:
            Text("Custom", tableName: "Dictionaries")
        }
    }
}

private struct CollapsedDictionariesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dictionaryManager = DictionaryManager.shared

    var body: some View {
        VStack(spacing: 0) {
            NativeSettingsForm(horizontalPadding: 18, verticalPadding: 18, spacing: 16) {
                headerSection
                dictionariesSection
            }
        }
        .background {
            NativeGlassPageBackground()
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }

    private var headerSection: some View {
        NativeSettingsSectionCard {
            HStack(spacing: 12) {
                Text("Collapse Dictionaries", tableName: "Dictionaries")
                Spacer()
                GlassEffectContainer(spacing: 10) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
                    .help(String(localized: "Close"))
                }
            }
        } content: {
            if dictionaryManager.termDictionaries.isEmpty {
                ContentUnavailableView {
                    Label(
                        String(localized: "No Term Dictionaries", table: "Dictionaries"),
                        systemImage: "character.book.closed.ja"
                    )
                } description: {
                    Text("Install a term dictionary before customizing collapsed dictionaries.", tableName: "Dictionaries")
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Text("Choose which term dictionaries start collapsed in lookup results.", tableName: "Dictionaries")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private var dictionariesSection: some View {
        if !dictionaryManager.termDictionaries.isEmpty {
            NativeSettingsSectionCard {
                Text("Dictionaries", tableName: "Dictionaries")
            } content: {
                ForEach(Array(dictionaryManager.termDictionaries.enumerated()), id: \.element.id) { index, dict in
                    if index > 0 {
                        NativeSettingsSeparator()
                    }
                    Button {
                        dictionaryManager.toggleCollapsedDictionary(title: dict.index.title)
                    } label: {
                        HStack {
                            Image(systemName: dictionaryManager.collapsedDictionaries.contains(dict.index.title) ? "chevron.right" : "chevron.down")
                                .foregroundStyle(dictionaryManager.collapsedDictionaries.contains(dict.index.title) ? .secondary : .primary)
                                .frame(width: 16)
                            Text(verbatim: dict.index.title)
                            Spacer()
                        }
                        .frame(minHeight: 46)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct CollapsedDictionariesView: View {
    @State private var dictionaryManager = DictionaryManager.shared

    var body: some View {
        NativeSettingsForm {
            NativeSettingsSectionCard {
                Text("Collapse Dictionaries", tableName: "Dictionaries")
            } content: {
                ForEach(Array(dictionaryManager.termDictionaries.enumerated()), id: \.element.id) { index, dict in
                    if index > 0 {
                        NativeSettingsSeparator()
                    }
                    Button {
                        dictionaryManager.toggleCollapsedDictionary(title: dict.index.title)
                    } label: {
                        HStack {
                            Image(systemName: dictionaryManager.collapsedDictionaries.contains(dict.index.title) ? "chevron.right" : "chevron.down")
                                .foregroundStyle(dictionaryManager.collapsedDictionaries.contains(dict.index.title) ? .secondary : .primary)
                                .frame(width: 16)
                            Text(verbatim: dict.index.title)
                            Spacer()
                        }
                        .frame(minHeight: 46)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(String(localized: "Collapse Dictionaries", table: "Dictionaries"))
        .inlineNavigationTitleIfAvailable()
    }
}

struct DictionaryDetailSettingView: View {
    @Environment(UserConfig.self) var userConfig
    @Environment(\.dismiss) private var dismiss
    @State private var customCSS: String = ""

    var body: some View {
        NavigationStack {
            CSSEditorView(text: $customCSS)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                #if os(macOS)
                .background {
                    NativeGlassPageBackground()
                }
                #else
                .background(Color(.secondarySystemBackground).ignoresSafeArea())
                #endif
                .navigationTitle(String(localized: "Custom CSS", table: "Dictionaries"))
                .inlineNavigationTitleIfAvailable()
                .toolbar {
                    #if os(macOS)
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .destructive) {
                            customCSS = ""
                        } label: {
                            Text("Reset", tableName: "Dictionaries")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                    #else
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            customCSS = ""
                        } label: {
                            Text("Reset", tableName: "Dictionaries")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                    #endif
                }
        }
        .onAppear {
            customCSS = userConfig.customCSS
        }
        .onDisappear {
            userConfig.customCSS = customCSS
        }
    }
}
