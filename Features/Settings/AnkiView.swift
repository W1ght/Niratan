//
//  AnkiView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct AnkiView: View {
    @State private var ankiManager = AnkiManager.shared
    @State private var dictionaryManager = DictionaryManager.shared
    @State private var confirmFetch = false
    @State private var confirmApplyDefaults = false

    private var availableHandlebars: [String] {
        let hidden: Set<Handlebars> = [
            .glossaryNoDictionary,
            .glossaryFirstBrief,
            .glossaryFirstNoDictionary,
            .selectedGlossaryBrief,
            .selectedGlossaryBriefFallback,
            .selectedGlossaryNoDictionary,
            .selectedGlossaryNoDictionaryFallback,
            .monolingualDefinitionBrief,
            .monolingualDefinitionNoDictionary,
            .bilingualDefinitionBrief,
            .bilingualDefinitionNoDictionary,
            .monolingualDefinitionFallbackBrief,
            .monolingualDefinitionFallbackNoDictionary,
            .bilingualDefinitionFallbackBrief,
            .bilingualDefinitionFallbackNoDictionary
        ]
        var options = Handlebars.allCases
            .filter { !hidden.contains($0) }
            .map(\.rawValue)
        for dict in dictionaryManager.termDictionaries {
            options.append("\(Handlebars.singleGlossaryPrefix)\(dict.index.title)}")
        }
        return options
    }

    var body: some View {
        NativeSettingsForm {
            NativeSettingsSectionCard {
                Text("AnkiConnect", tableName: "Dictionaries")
            } content: {
                NativeSettingsRow {
                    Text("Address", tableName: "Dictionaries")
                } accessory: {
                    TextField(text: Binding(
                        get: { ankiManager.ankiConnectConfig?.url ?? "http://127.0.0.1:8765" },
                        set: { ankiManager.setAnkiConnectURL($0) }
                    ), prompt: Text("Address", tableName: "Dictionaries")) {
                        Text("Address", tableName: "Dictionaries")
                    }
                    .nativeSettingsTextField()
                    .onSubmit { ankiManager.save() }
                }
                NativeSettingsSeparator()
                NativeSettingsRow {
                    Text("Status: \(connectionStatus)", tableName: "Dictionaries")
                        .foregroundStyle(.secondary)
                } accessory: {
                    Button {
                        if ankiManager.ankiConnectConfig?.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                            ankiManager.ankiConnectConfig?.url = "http://127.0.0.1:8765"
                        }
                        ankiManager.save()
                        ankiManager.handleAppBecameActive()
                    } label: {
                        Text("Connect", tableName: "Dictionaries")
                    }
                    .buttonStyle(NativeSettingsActionButtonStyle())
                }
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac card creation uses AnkiConnect.")
                    Text("AnkiMobile callbacks are not used in the Mac app.")
                }
            }

            if ankiManager.isConnected {
                NativeSettingsSectionCard {
                    Text("Refresh", tableName: "Dictionaries")
                } content: {
                    NativeSettingsButtonRow {
                        Button {
                            confirmFetch = true
                        } label: {
                            Text("Fetch decks and models from AnkiConnect")
                        }
                    }
                } footer: {
                    Text("Fetching refreshes decks and models while preserving mappings for fields that still exist.")
                }

                NativeSettingsSectionCard {
                    Text("AnkiConnect Settings")
                } content: {
                    NativeSettingsRow {
                        Text("Duplicate Scope", tableName: "Dictionaries")
                    } accessory: {
                        NativeGlassSegmentedPicker(
                            selection: Binding(
                                get: { ankiManager.ankiConnectConfig?.duplicateScope ?? .collection },
                                set: { value in
                                    ankiManager.ankiConnectConfig?.duplicateScope = value
                                    ankiManager.save()
                                }
                            ),
                            values: [DuplicateScope.collection, .deck, .deckroot],
                            minSegmentWidth: 82
                        ) { scope in
                            duplicateScopeText(scope)
                        }
                    }
                    NativeSettingsSeparator()
                    ankiConfigToggle(
                        title: "Check All Models",
                        value: ankiManager.ankiConnectConfig?.checkAllModels ?? false
                    ) { value in
                        ankiManager.ankiConnectConfig?.checkAllModels = value
                        ankiManager.save()
                    }
                    NativeSettingsSeparator()
                    ankiConfigToggle(
                        title: "Force Sync on adding card",
                        value: ankiManager.ankiConnectConfig?.forceSync ?? false
                    ) { value in
                        ankiManager.ankiConnectConfig?.forceSync = value
                        ankiManager.save()
                    }
                }

                NativeSettingsSectionCard {
                    Text("Config", tableName: "Dictionaries")
                } content: {
                    NativeSettingsRow {
                        Text("Deck", tableName: "Dictionaries")
                    } accessory: {
                        NativeGlassMenuPicker(
                            selection: $ankiManager.selectedDeck,
                            values: ankiManager.availableDecks.map(Optional.some),
                            minWidth: 160
                        ) { deck in
                            if let deck {
                                Text(verbatim: deck)
                            } else {
                                Text("Deck", tableName: "Dictionaries")
                            }
                        }
                        .onChange(of: ankiManager.selectedDeck) { _, _ in ankiManager.save() }
                    }
                    NativeSettingsSeparator()
                    NativeSettingsRow {
                        Text("Model", tableName: "Dictionaries")
                    } accessory: {
                        NativeGlassMenuPicker(
                            selection: $ankiManager.selectedNoteType,
                            values: ankiManager.availableNoteTypes.map { Optional.some($0.name) },
                            minWidth: 160
                        ) { noteType in
                            if let noteType {
                                Text(verbatim: noteType)
                            } else {
                                Text("Model", tableName: "Dictionaries")
                            }
                        }
                        .onChange(of: ankiManager.selectedNoteType) { _, _ in
                            ankiManager.autofillFieldMappings()
                            ankiManager.save()
                        }
                    }
                }

                NativeSettingsSectionCard {
                    Text("Settings", tableName: "Dictionaries")
                } content: {
                    NativeSettingsToggle("Allow Duplicates", isOn: $ankiManager.allowDupes)
                        .onChange(of: ankiManager.allowDupes) { _, _ in ankiManager.save() }
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Compact Glossaries", isOn: $ankiManager.compactGlossaries)
                        .onChange(of: ankiManager.compactGlossaries) { _, _ in ankiManager.save() }
                    NativeSettingsSeparator()
                    NativeSettingsRow {
                        Text("Audio Compression Format")
                    } accessory: {
                        NativeGlassMenuPicker(
                            selection: $ankiManager.audioCompressionFormat,
                            values: AnkiAudioCompressionFormat.allCases,
                            minWidth: 132
                        ) { format in
                            Text(verbatim: format.displayName)
                        }
                        .onChange(of: ankiManager.audioCompressionFormat) { _, _ in
                            ankiManager.save()
                        }
                    }
                    NativeSettingsSeparator()
                    NativeSettingsSliderRow(
                        title: "Audio Quality",
                        value: "\(ankiManager.audioCompressionBitrateKbps) kbps"
                    ) {
                        Slider(
                            value: Binding(
                                get: { Double(ankiManager.audioCompressionBitrateKbps) },
                                set: { ankiManager.audioCompressionBitrateKbps = Int($0) }
                            ),
                            in: 32...192,
                            step: 16
                        )
                        .onChange(of: ankiManager.audioCompressionBitrateKbps) { _, _ in
                            ankiManager.save()
                        }
                    }
                    NativeSettingsSeparator()
                    NativeSettingsToggle("Compress Images", isOn: $ankiManager.compressImages)
                    .onChange(of: ankiManager.compressImages) { _, _ in
                        ankiManager.save()
                    }
                    NativeSettingsSeparator()
                    NativeSettingsRow {
                        Text("Image Format", tableName: "Dictionaries")
                    } accessory: {
                        NativeGlassMenuPicker(
                            selection: $ankiManager.imageCompressionFormat,
                            values: AnkiImageCompressionFormat.allCases,
                            minWidth: 132
                        ) { format in
                            Text(verbatim: format.displayName)
                        }
                        .disabled(!ankiManager.compressImages)
                        .onChange(of: ankiManager.imageCompressionFormat) { _, _ in
                            ankiManager.save()
                        }
                    }
                    NativeSettingsSeparator()
                    NativeSettingsSliderRow(
                        title: "Image Quality",
                        value: "\(Int((ankiManager.imageCompressionQuality * 100).rounded()))%"
                    ) {
                        Slider(
                            value: $ankiManager.imageCompressionQuality,
                            in: 0.40...0.95,
                            step: 0.05
                        )
                        .disabled(!ankiManager.compressImages)
                        .onChange(of: ankiManager.imageCompressionQuality) { _, _ in
                            ankiManager.save()
                        }
                    }
                    if ankiManager.imageCompressionFormat == .avif {
                        NativeSettingsSeparator()
                        NativeSettingsSliderRow(
                            title: "AVIF Maximum Height",
                            value: "\(ankiManager.animatedAVIFMaximumHeight) px"
                        ) {
                            Slider(
                                value: Binding(
                                    get: { Double(ankiManager.animatedAVIFMaximumHeight) },
                                    set: { ankiManager.animatedAVIFMaximumHeight = Int($0) }
                                ),
                                in: AnkiAnimatedAVIFConfiguration.maximumHeightSliderRange,
                                step: 10
                            )
                            .disabled(!ankiManager.compressImages)
                            .onChange(of: ankiManager.animatedAVIFMaximumHeight) { _, _ in
                                ankiManager.save()
                            }
                        }
                        NativeSettingsSeparator()
                        NativeSettingsSliderRow(
                            title: "AVIF Frame Rate",
                            value: "\(ankiManager.animatedAVIFFramesPerSecond) fps"
                        ) {
                            Slider(
                                value: Binding(
                                    get: { Double(ankiManager.animatedAVIFFramesPerSecond) },
                                    set: { ankiManager.animatedAVIFFramesPerSecond = Int($0) }
                                ),
                                in: AnkiAnimatedAVIFConfiguration.framesPerSecondSliderRange,
                                step: 1
                            )
                            .disabled(!ankiManager.compressImages)
                            .onChange(of: ankiManager.animatedAVIFFramesPerSecond) { _, _ in
                                ankiManager.save()
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Higher quality produces larger cards. Image compression applies to book covers and video screenshots; repeated cards reuse matching media files.")
                        if ankiManager.imageCompressionFormat == .avif {
                            Text("Animated AVIF stores independent frames for reliable iOS playback. Lower resolution or frame rate produces smaller cards.")
                        }
                    }
                }
            }

            if ankiManager.isConnected,
               let typeName = ankiManager.selectedNoteType,
               let noteType = ankiManager.availableNoteTypes.first(where: { $0.name == typeName }) {
                NativeSettingsSectionCard {
                    Text("Fields", tableName: "Dictionaries")
                } content: {
                    if AnkiFieldTemplate.hasDefaults(noteType: typeName) {
                        NativeSettingsButtonRow {
                            Button {
                                confirmApplyDefaults = true
                            } label: {
                                Text("Apply Defaults", tableName: "Dictionaries")
                            }
                        }
                        NativeSettingsSeparator()
                    }

                    ForEach(Array(noteType.fields.enumerated()), id: \.element) { index, field in
                        if index > 0 {
                            NativeSettingsSeparator()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: field)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            NativeSettingsEditableMenuField(
                                text: Binding(
                                    get: { ankiManager.fieldMappings[field] ?? "" },
                                    set: { value in
                                        ankiManager.setFieldMapping(value, for: field)
                                    }
                                ),
                                prompt: Text("None", tableName: "Dictionaries"),
                                menuAccessibilityLabel: Text("Fields", tableName: "Dictionaries"),
                                onSubmit: {
                                    ankiManager.save()
                                }
                            ) {
                                Button {
                                    ankiManager.setFieldMapping("", for: field)
                                } label: {
                                    Text(verbatim: "-")
                                }
                                Divider()
                                ForEach(availableHandlebars, id: \.self) { option in
                                    Button {
                                        ankiManager.fieldMappings[field] = option
                                        ankiManager.save()
                                    } label: {
                                        Text(verbatim: option)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }

                    NativeSettingsSeparator()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tags", tableName: "Dictionaries")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        TextField(text: Binding(
                            get: { ankiManager.tags },
                            set: { ankiManager.setTags($0) }
                        ), prompt: Text("None", tableName: "Dictionaries")) {
                            Text("None", tableName: "Dictionaries")
                        }
                        .nativeSettingsTextField()
                        .submitLabel(.done)
                        .onSubmit {
                            ankiManager.save()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .navigationTitle(String(localized: "Anki", table: "Dictionaries"))
        .onAppear {
            ankiManager.handleAppBecameActive()
        }
        .onDisappear { ankiManager.save() }
        .alert(String(localized: "Fetch from Anki?", table: "Dictionaries"), isPresented: $confirmFetch) {
            Button {
                Task { await ankiManager.fetchAnkiConnect() }
            } label: {
                Text("OK", tableName: "Dictionaries")
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", tableName: "Dictionaries")
            }
        } message: {
            Text("This will refresh decks and models while preserving mappings for fields that still exist.")
        }
        .alert(
            String(localized: "Apply defaults?", table: "Dictionaries"),
            isPresented: $confirmApplyDefaults
        ) {
            Button {
                if ankiManager.applyDefaultFieldMappings() {
                    ankiManager.save()
                }
            } label: {
                Text("Apply", tableName: "Dictionaries")
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", tableName: "Dictionaries")
            }
        } message: {
            Text(
                "This replaces mappings for fields defined by the selected note type. Other fields are preserved.",
                tableName: "Dictionaries"
            )
        }
        .alert(String(localized: "Error", table: "Dictionaries"), isPresented: .init(
            get: { ankiManager.errorMessage != nil },
            set: { if !$0 { ankiManager.errorMessage = nil } }
        )) {
            Button {
                ankiManager.errorMessage = nil
            } label: {
                Text("OK", tableName: "Dictionaries")
            }
        } message: {
            Text(verbatim: ankiManager.errorMessage ?? "")
        }
    }

    private func ankiConfigToggle(
        title: LocalizedStringKey,
        value: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        NativeSettingsRow(title) {
            Toggle("", isOn: Binding(
                get: { value },
                set: { newValue in onChange(newValue) }
            ))
                .labelsHidden()
        }
    }

    private var connectionStatus: String {
        if ankiManager.isConnected {
            String(localized: "Connected", table: "Dictionaries")
        } else {
            String(localized: "Not connected", table: "Dictionaries")
        }
    }

    private func duplicateScopeText(_ scope: DuplicateScope) -> Text {
        switch scope {
        case .collection:
            Text("Collection", tableName: "Dictionaries")
        case .deck:
            Text("Deck", tableName: "Dictionaries")
        case .deckroot:
            Text("Deck Root", tableName: "Dictionaries")
        }
    }

}
