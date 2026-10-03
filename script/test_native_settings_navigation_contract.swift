import Foundation

private enum NativeSettingsNavigationContractTests {
    static func read(_ relativePath: String) -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent(relativePath)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Unable to read \(relativePath)")
        }
        return source
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func run() {
        let root = read("NativeMac/NativeMacRootView.swift")
        let settings = read("NativeMac/NativeReuseViews.swift")
        let dictionary = read("Features/Settings/DictionaryView.swift")
        let dictionaryManager = read("Core/DictionaryManager.swift")
        let agents = read("AGENTS.md")
        let audio = read("Features/Settings/AudioView.swift")
        let profiles = read("Features/Settings/ProfilesView.swift")
        let advanced = read("Features/Settings/AdvancedView.swift")
        let anki = read("Features/Settings/AnkiView.swift")
        let ankiConnect = read("Features/Settings/AnkiConnectView.swift")
        let sync = read("Features/Settings/SyncView.swift")

        require(
            root.contains("} detail: {\n            Group {")
                && root.contains("NativeMacDetailView(")
                && !root.contains(".id(selectedSection)"),
            "Changing the main sidebar section must retain one stable detail host without forced identity replacement"
        )
        require(
            root.contains(".toolbarBackgroundVisibility(windowToolbarBackgroundVisibility, for: .windowToolbar)")
                && root.contains("var windowToolbarBackgroundVisibility: Visibility")
                && root.contains("return .hidden"),
            "Native app sections should preserve one stable transparent system toolbar over the shared glass background"
        )
        require(
            settings.contains("NativeGlassPageBackground()")
                && settings.contains(".ignoresSafeArea(.container, edges: .top)")
                && settings.contains(".listStyle(.sidebar)\n        .scrollContentBackground(.hidden)\n        .background(.clear)")
                && settings.contains(".nativeGlassCardSurface(cornerRadius: 18)"),
            "Native Settings sidebar, detail and cards must use shared glass surfaces behind the transparent toolbar"
        )
        require(
            settings.contains("struct NativeSettingsTextFieldModifier: ViewModifier")
                && settings.contains("var isFocused: Bool")
                && settings.contains("content\n            .textFieldStyle(.plain)\n            .focused($isFocused)")
                && settings.contains(".glassEffect(.regular.interactive(), in: Capsule())")
                && settings.contains("isFocused ? Color.accentColor")
                && anki.components(separatedBy: ".nativeSettingsTextField()").count == 3
                && ankiConnect.components(separatedBy: ".nativeSettingsTextField()").count == 3
                && sync.contains(".nativeSettingsTextField()")
                && audio.components(separatedBy: ".nativeSettingsTextField()").count == 3
                && profiles.contains(".nativeSettingsTextField()")
                && !anki.contains(".textFieldStyle(.roundedBorder)")
                && !ankiConnect.contains(".textFieldStyle(.roundedBorder)")
                && !sync.contains(".textFieldStyle(.roundedBorder)")
                && !audio.contains(".textFieldStyle(.roundedBorder)")
                && audio.contains("GlassEffectContainer(spacing: 8)")
                && audio.contains("Label(\"Add Source\", systemImage: \"plus\")")
                && audio.contains(".buttonStyle(.glass)")
                && audio.contains(".buttonBorderShape(.circle)")
                && audio.contains(".controlSize(.large)"),
            "Native Settings text and secure fields should share the macOS 26 interactive glass capsule style"
        )
        require(
            !settings.contains(
                """

                            Divider()

                            NativeSettingsDetailView
                """
            ),
            "Native Settings should not draw a vertical Divider between its custom sidebar and detail content"
        )
        require(
            !dictionary.contains("DictionarySettingsView()"),
            "Dictionary preferences must be shown inline instead of pushing a nested Settings destination"
        )
        require(
            dictionary.contains("DictionaryBehaviorSettingsSections("),
            "The dictionary page must keep lookup and display preferences inline"
        )
        require(
            dictionary.contains("var showCollapsedDictionaryCustomization = false")
                && dictionary.contains(".sheet(isPresented: $showCollapsedDictionaryCustomization)")
                && dictionary.contains("DictionaryBehaviorSettingsSections(")
                && dictionary.contains("showCollapsedDictionaryCustomization: $showCollapsedDictionaryCustomization")
                && dictionary.contains("@Binding var showCollapsedDictionaryCustomization: Bool")
                && dictionary.contains("showCollapsedDictionaryCustomization = true")
                && dictionary.contains("CollapsedDictionariesSheet()")
                && dictionary.contains("struct CollapsedDictionariesSheet: View")
                && dictionary.contains("NativeSettingsForm(horizontalPadding: 18, verticalPadding: 18, spacing: 16)")
                && dictionary.contains("NativeGlassPageBackground()")
                && dictionary.contains("ContentUnavailableView")
                && dictionary.contains(".frame(width: 560)")
                && dictionary.contains(".frame(minHeight: 420)")
                && dictionary.contains("GlassEffectContainer(spacing: 10)")
                && !dictionary.contains("NavigationStack {\n                CollapsedDictionariesView()")
                && dictionary.contains("dismiss()")
                && !dictionary.contains(
                    """
                    NavigationLink {
                                                    CollapsedDictionariesView()
                    """
                ),
            "Collapsed dictionary customization must open as a dismissible sheet instead of pushing an unreachable nested settings destination"
        )
        require(
            agents.contains("新增或重构 UI")
                && agents.contains("macOS 26 原生控件")
                && agents.contains("Liquid Glass")
                && agents.contains("不得新增 SwiftUI `Material` 背景"),
            "AGENTS.md must require new and refactored UI to use native macOS 26 controls without legacy Material chrome"
        )
        require(
            dictionary.contains("RecommendedDictionarySelectionSheet")
                && dictionary.contains("DictionaryUpdateSelectionSheet")
                && dictionary.contains("var selectedRecommendedDictionaryIDs: Set<String> = []")
                && dictionary.contains("var selectedUpdatableDictionaryIDs: Set<UUID> = []")
                && dictionary.contains("var showNoDictionaryUpdatesAlert = false")
                && dictionary.contains("dictionaryManager.importRecommendedDictionaries(selectedRecommendations)")
                && dictionary.contains("dictionaryManager.updateDictionaries(selectedDictionaries, refreshAvailabilityAfterUpdate: true)")
                && !dictionary.contains("recommendedDownloadMessage")
                && !dictionary.contains("showDownloadConfirmation")
                && !dictionary.contains("showUpdateConfirmation"),
            "Dictionary download and update actions must present selectable list sheets instead of all-or-nothing confirmation alerts"
        )
        require(
            dictionary.contains("DictionarySelectionSheetSurface")
                && dictionary.contains("NativeSettingsForm(horizontalPadding: 18, verticalPadding: 18, spacing: 16)")
                && dictionary.contains("NativeSettingsSectionCard")
                && dictionary.contains("NativeGlassPageBackground()")
                && dictionary.contains("DictionarySelectionRow")
                && !dictionary.contains(#"List {"#),
            "Dictionary selection sheets must use the macOS 26 Native Settings glass components instead of a default SwiftUI List"
        )
        require(
            dictionary.contains("DictionarySelectionActionBar")
                && dictionary.contains("DictionarySelectionActionButtonStyle")
                && dictionary.contains("GlassEffectContainer(spacing: 10)")
                && dictionary.contains(".glassEffect(.regular.interactive(), in: Capsule())")
                && !dictionary.contains("DictionarySelectionSheetSurface<Content: View, SheetToolbar: ToolbarContent>")
                && !dictionary.contains("@ToolbarContentBuilder")
                && !dictionary.contains(".toolbar(content: toolbar)"),
            "Dictionary selection sheet actions must use an in-content glass action bar instead of the system sheet toolbar material"
        )
        require(
            dictionaryManager.contains("func importRecommendedDictionaries(_ recommendations: [DictionaryRecommendation]? = nil)")
                && dictionaryManager.contains("func updateDictionaries(")
                && dictionaryManager.contains("refreshAvailabilityAfterUpdate: Bool = false")
                && dictionaryManager.contains("let recommendations = recommendations ?? recommendedDictionaries")
                && dictionaryManager.contains("let dictionaries = dictionaries ?? updatableDictionaries"),
            "Dictionary manager must support importing and updating an explicit selected subset"
        )
        require(
            dictionary.contains("dictionaryManager.availableDictionaryUpdates.map")
                && dictionary.contains("let updates = await dictionaryManager.refreshAvailableDictionaryUpdates()")
                && dictionary.contains("dictionaryManager.updateDictionaries(selectedDictionaries, refreshAvailabilityAfterUpdate: true)")
                && dictionary.contains("showNoDictionaryUpdatesAlert = true")
                && dictionary.contains("No Dictionary Updates")
                && dictionary.contains("All dictionaries are already up to date.")
                && dictionary.contains("dictionaryManager.isCheckingUpdates")
                && dictionaryManager.contains("private(set) var availableDictionaryUpdates")
                && dictionaryManager.contains("private(set) var isCheckingUpdates")
                && dictionaryManager.contains("DictionaryUpdateSourceResolver.updateCapableIndex")
                && dictionaryManager.contains("func refreshAvailableDictionaryUpdates(showErrors: Bool = true, session: URLSession = .shared) async")
                && dictionaryManager.contains("if refreshAvailabilityAfterUpdate")
                && dictionaryManager.contains("_ = await self.refreshAvailableDictionaryUpdates(showErrors: false, session: session)")
                && dictionaryManager.contains("DictionaryUpdateAvailability.shouldOfferUpdate"),
            "Manual dictionary update selection must full-scan remote revisions, only list dictionaries with actual newer revisions, and refresh availability after selected updates"
        )
        require(
            settings.contains("struct NativeSettingsRow")
                && !settings.contains("struct NativeSettingsReorderRow")
                && !settings.contains("NativeSettingsReorderPasteboard")
                && !settings.contains("dragConfiguration(.init(allowMove: true))"),
            "Settings reorder must not depend on pasteboard drop targets inside the outer settings scroll container"
        )
        require(
            dictionary.contains("DictionaryRowFramePreferenceKey")
                && dictionary.contains("dictionaryReorderCoordinateSpaceName")
                && dictionary.contains(".coordinateSpace(name: dictionaryReorderCoordinateSpaceName)")
                && dictionary.contains(".onPreferenceChange(DictionaryRowFramePreferenceKey.self)")
                && dictionary.contains(".highPriorityGesture(dictionaryReorderGesture")
                && dictionary.contains("DragGesture(minimumDistance: 8, coordinateSpace: .named(dictionaryReorderCoordinateSpaceName))")
                && dictionary.contains("updateDictionaryDrag")
                && dictionary.contains("endDictionaryDrag")
                && !dictionary.contains("NativeSettingsReorderRow(")
                && !dictionary.contains(".onDrag {")
                && !dictionary.contains(".onDrop(of: [.plainText]")
                && dictionary.contains("dictionaryManager.moveDictionary"),
            "Dictionary rows must use the same in-scroll gesture reorder pattern as the bookshelf"
        )
        require(
            dictionary.contains("dictionaryReorderHandle()")
                && dictionary.contains(".contentShape(Rectangle())")
                && dictionary.contains("GeometryReader")
                && dictionary.contains("proxy.frame(in: .named(dictionaryReorderCoordinateSpaceName))"),
            "Dictionary rows must track row frames in the outer settings list coordinate space"
        )
        require(
            audio.contains("AudioSourceRowFramePreferenceKey")
                && audio.contains("audioSourceReorderCoordinateSpaceName")
                && audio.contains(".coordinateSpace(name: audioSourceReorderCoordinateSpaceName)")
                && audio.contains(".onPreferenceChange(AudioSourceRowFramePreferenceKey.self)")
                && audio.contains(".highPriorityGesture(audioSourceReorderGesture")
                && audio.contains("DragGesture(minimumDistance: 8, coordinateSpace: .named(audioSourceReorderCoordinateSpaceName))")
                && audio.contains("updateAudioSourceDrag")
                && audio.contains("endAudioSourceDrag")
                && !audio.contains("NativeSettingsReorderRow(")
                && !audio.contains(".onDrag {"),
            "Audio source rows must mirror the in-scroll gesture reorder pattern"
        )
        require(
            audio.contains("audioSourceReorderHandle()")
                && audio.contains(".contentShape(Rectangle())")
                && audio.contains("GeometryReader")
                && !audio.contains(".onDrop(of: [.plainText]")
                && audio.contains("dropTargetAudioSourceID == sourceID")
                && audio.contains("userConfig.audioSources.move"),
            "Audio source rows must track row frames, highlight the active target, and persist the reordered array"
        )
        require(
            audio.contains("let sourceID = source.id")
                && audio.contains("deleteAudioSource(id: sourceID)")
                && audio.contains("func deleteAudioSource(id sourceID: AudioSource.ID)")
                && audio.contains("let remainingSources = userConfig.audioSources.filter { $0.id != sourceID }")
                && audio.contains("userConfig.audioSources = remainingSources")
                && !audio.contains("removeAll { $0.id == source.id }"),
            "Audio source deletion must capture a stable row ID before replacing the bound source array"
        )
        require(
            settings.contains("case profiles") && settings.contains("ProfilesView()"),
            "Native Settings must expose the Profiles management page"
        )
        require(
            profiles.contains("setGlobalActiveProfile")
                && profiles.contains("ProfileActivationCoordinator.activateGlobal(")
                && !profiles.contains("setPrimaryProfile")
                && !profiles.contains("Primary Profile")
                && !profiles.contains("Default Profile"),
            "Profiles must expose one global runtime selection without per-language defaults"
        )
        require(
            profiles.contains("copyFromProfileID: repository.activeProfile.id"),
            "Normal profile creation must copy the current active profile"
        )
        require(
            profiles.contains("let profileID = deletingProfile.id")
                && profiles.contains(
                    "SuwayomiConnectionStore.shared.clear("
                )
                && profiles.contains("profileID: profileID"),
            "Deleting a Profile must also remove its Profile-scoped Suwayomi Keychain credential"
        )
        require(
            settings.contains(
                """
                Section("Reader") {
                                nativeSettingsRow(.audio)
                                nativeSettingsRow(.statistics)
                                nativeSettingsRow(.sasayaki)
                            }
                """
            ),
            "Reader settings must contain only audio, statistics and Sasayaki"
        )
        require(
            settings.contains(
                """
                            Section("Video") {
                                nativeSettingsRow(.video)
                            }
                """
            ),
            "The full build must expose Video in its own settings group"
        )
        require(
            settings.contains(
                """
                Section("Shortcuts & Controls") {
                                nativeSettingsRow(.keyboardShortcuts)
                                nativeSettingsRow(.gameController)
                            }
                """
            ),
            "Keyboard shortcuts and game controller settings must have their own group"
        )
        require(
            advanced.contains("Section(\"Reader\")")
                && advanced.contains("Section(\"Video\")")
                && advanced.contains("Section(\"Shortcuts & Controls\")"),
            "The legacy Advanced settings path must use the same Reader, Video and controls grouping"
        )

        print("Native settings navigation contract passed")
    }
}

NativeSettingsNavigationContractTests.run()
