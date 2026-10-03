// test-sources: Models/Anki.swift Models/Book.swift Models/Profile.swift Models/Dictionary.swift Core/ProfileDictionaryBackup.swift Core/ProfileRepository.swift
import Foundation

@main
private enum ProfileRepositoryTests {
    static func main() throws {
        try testLanguageNormalizationAndWordUnits()
        try testGlobalResolutionIgnoresLegacyContexts()
        try testBookMetadataProfileCompatibility()
        try testLanguageSpecificDictionaryRecommendations()
        try testProfileSettingsDefaultsAndRoundTrip()
        try testRepositoryMigrationAndPersistence()
        try testEquivalentLegacyVideoProfileMerges()
        try testProfileLifecycleAndPathSafety()
        try testProfileDictionaryBackupRoundTrip()
        try testKanjiDictionaryConfigCompatibility()
        print("Profile repository tests passed")
    }

    private static func testProfileSettingsDefaultsAndRoundTrip() throws {
        var reader = ReaderProfileSettings.defaults
        reader.verticalWriting = false
        reader.fontSize = 28
        let readerRoundTrip = try JSONDecoder().decode(
            ReaderProfileSettings.self,
            from: JSONEncoder().encode(reader)
        )
        precondition(readerRoundTrip == reader)

        let legacyReaderData = Data(#"""
        {
            "theme":"System",
            "uiTheme":"System",
            "systemLightSepia":false,
            "sepiaInvertInDark":false,
            "customBackgroundColor":"#FFFFFFFF",
            "customTextColor":"#000000FF",
            "customInfoColor":"#999999FF",
            "verticalWriting":true,
            "selectedFont":"Hiragino Mincho ProN",
            "fontSize":22,
            "hideFurigana":false,
            "continuousMode":false,
            "horizontalPadding":5,
            "verticalPadding":0,
            "avoidPageBreak":false,
            "justifyText":false,
            "blurImages":false,
            "layoutAdvanced":false,
            "lineHeight":1.65,
            "characterSpacing":0,
            "paragraphSpacing":0,
            "showTitle":true,
            "showCharacters":true,
            "showPercentage":true,
            "showProgressTop":true,
            "showStatisticsToggle":false,
            "showReadingSpeed":false,
            "showReadingTime":false,
            "showSasayakiToggle":false
        }
        """#.utf8)
        let legacyReader = try JSONDecoder().decode(
            ReaderProfileSettings.self,
            from: legacyReaderData
        )
        precondition(legacyReader.twoColumnHorizontalPages == nil)

        var dictionary = DictionaryProfileSettings.defaults
        dictionary.scanLength = 32
        dictionary.customCSS = ".entry { color: red; }"
        let dictionaryRoundTrip = try JSONDecoder().decode(
            DictionaryProfileSettings.self,
            from: JSONEncoder().encode(dictionary)
        )
        precondition(dictionaryRoundTrip == dictionary)

        let legacyDictionaryData = Data(#"""
        {
            "dictionaryTabDefault":false,
            "scanNonJapaneseText":true,
            "maxResults":16,
            "scanLength":16,
            "collapseMode":"Expand All",
            "expandFirstDictionary":false,
            "compactGlossaries":true,
            "showExpressionTags":false,
            "harmonicFrequency":false,
            "deduplicatePitchAccents":false,
            "compactPitchAccents":true,
            "customCSS":""
        }
        """#.utf8)
        let legacyDictionary = try JSONDecoder().decode(
            DictionaryProfileSettings.self,
            from: legacyDictionaryData
        )
        let legacyTwoColumn = Mirror(reflecting: legacyDictionary).children.first {
            $0.label == "twoColumnLayout"
        }
        precondition(legacyTwoColumn != nil)
        precondition(String(describing: legacyTwoColumn!.value) == "nil")
    }

    private static func testLanguageSpecificDictionaryRecommendations() throws {
        let english = DictionaryRecommendation.forLanguage(.english)
        precondition(english.count == 7)
        precondition(english.contains { $0.name == "Wiktionary English-English IPA" && $0.type == .pitch })
        precondition(english.contains { $0.name == "Leipzig English Wikipedia" && $0.type == .frequency })
        precondition(!english.contains { $0.name == "JMdict" })

        let japanese = DictionaryRecommendation.forLanguage(.japanese)
        precondition(japanese.contains { $0.name == "JMdict" })
        precondition(japanese.contains { $0.name == "Jitendex" })
        precondition(japanese.contains { $0.name == "KANJIDIC" && $0.type == .kanji })
        precondition(!english.contains { $0.type == .kanji })
        precondition(!japanese.contains { $0.name.contains("English-English") })
    }

    private static func testBookMetadataProfileCompatibility() throws {
        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy","cover":null,"folder":"Legacy","lastAccess":0}"#.utf8)
        let decoded = try JSONDecoder().decode(BookMetadata.self, from: legacy)
        precondition(decoded.profileId == nil)
        precondition(decoded.bookLanguage == nil)

        let english = BookMetadata(
            title: "English",
            cover: nil,
            folder: "English",
            lastAccess: .distantPast,
            profileId: "english",
            bookLanguage: "en-GB"
        )
        let roundTrip = try JSONDecoder().decode(BookMetadata.self, from: JSONEncoder().encode(english))
        precondition(roundTrip.profileId == "english")
        precondition(roundTrip.bookLanguage == "en-GB")
    }

    private static func testLanguageNormalizationAndWordUnits() throws {
        precondition(ContentLanguageProfile.normalize("ja-JP") == .japanese)
        precondition(ContentLanguageProfile.normalize("EN_us") == .english)
        precondition(ContentLanguageProfile.normalize("fr") == nil)
        precondition(ContentLanguageProfile.english.displayCount(forRawCharacters: 0) == 0)
        precondition(ContentLanguageProfile.english.displayCount(forRawCharacters: 1) == 1)
        precondition(ContentLanguageProfile.english.displayCount(forRawCharacters: 6) == 2)
        precondition(ContentLanguageProfile.english.rawCharacters(forDisplayCount: 12) == 60)
        precondition(ContentLanguageProfile.japanese.displayCount(forRawCharacters: 12) == 12)
    }

    private static func testGlobalResolutionIgnoresLegacyContexts() throws {
        let japanese = HoshiProfile.defaultJapanese
        let english = HoshiProfile(id: "english", name: "English", dictionaryLanguageId: "en")
        let alternate = HoshiProfile(id: "alternate", name: "Alternate", dictionaryLanguageId: "ja")
        let index = ProfileIndex(
            profiles: [japanese, english, alternate],
            defaultProfileId: japanese.id,
            globalActiveProfileId: alternate.id,
            primaryProfileIdsByLanguage: ["ja": japanese.id, "en": english.id]
        )

        precondition(ProfileResolver.resolve(.book(profileID: english.id, bookLanguage: "ja"), in: index).id == alternate.id)
        precondition(ProfileResolver.resolve(.book(profileID: "missing", bookLanguage: "en-GB"), in: index).id == alternate.id)
        precondition(ProfileResolver.resolve(.book(profileID: nil, bookLanguage: "fr"), in: index).id == alternate.id)
        precondition(ProfileResolver.resolve(.video(profileID: english.id), in: index).id == alternate.id)
        precondition(ProfileResolver.resolve(.video(profileID: "missing"), in: index).id == alternate.id)
        precondition(ProfileResolver.resolve(.global, in: index).id == alternate.id)

        var videoTransitionIndex = index
        videoTransitionIndex.globalActiveProfileId = english.id
        precondition(ProfileResolver.resolve(.global, in: videoTransitionIndex).id == english.id)
        precondition(
            ProfileResolver.resolve(
                .video(profileID: ProfileRepository.legacyJapaneseVideoProfileID),
                in: videoTransitionIndex
            ).id == english.id
        )
        precondition(
            ProfileResolver.resolve(
                .book(profileID: HoshiProfile.defaultJapanese.id, bookLanguage: "ja"),
                in: videoTransitionIndex
            ).id == english.id
        )
        precondition(ProfileResolver.resolve(.global, in: videoTransitionIndex).id == english.id)
    }

    private static func testRepositoryMigrationAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "profile-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        let dictionaries = root.appendingPathComponent("Dictionaries")
        try FileManager.default.createDirectory(at: dictionaries, withIntermediateDirectories: true)
        let legacyConfig = Data(#"{"termDictionaries":[],"frequencyDictionaries":[],"pitchDictionaries":[]}"#.utf8)
        try legacyConfig.write(to: dictionaries.appendingPathComponent("config.json"))
        try Data(#"["JMdict"]"#.utf8).write(to: dictionaries.appendingPathComponent("collapsed.json"))
        let legacyAnki = try JSONEncoder().encode(AnkiConfig(
            selectedDeck: "Mining",
            selectedNoteType: "Lapis",
            allowDupes: false,
            compactGlossaries: true,
            embedMedia: true,
            fieldMappings: [
                "SentenceAudio": Handlebars.sasayakiAudio.rawValue,
                "Picture": Handlebars.bookCover.rawValue
            ],
            tags: "",
            availableDecks: ["Mining"],
            availableNoteTypes: [AnkiNoteType(
                name: "Lapis",
                fields: ["SentenceAudio", "Picture"]
            )],
            useAnkiConnect: true,
            ankiConnectConfig: nil
        ))
        try legacyAnki.write(to: root.appendingPathComponent("anki_config.json"))

        let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
        let legacyVideoDirectory = profiles.appendingPathComponent(
            ProfileRepository.legacyJapaneseVideoProfileID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyVideoDirectory,
            withIntermediateDirectories: true
        )
        let preservedVideoConfig = Data(#"{"termDictionaries":[],"frequencyDictionaries":[],"pitchDictionaries":[],"marker":"video-custom"}"#.utf8)
        try preservedVideoConfig.write(to: legacyVideoDirectory.appendingPathComponent("dictionary_config.json"))
        let legacyVideoProfile = HoshiProfile(
            id: ProfileRepository.legacyJapaneseVideoProfileID,
            name: "Japanese Video",
            dictionaryLanguageId: "ja",
            isDefault: true
        )
        let legacyIndex = ProfileIndex(
            profiles: [.defaultJapanese, legacyVideoProfile],
            defaultProfileId: HoshiProfile.defaultJapanese.id,
            globalActiveProfileId: legacyVideoProfile.id,
            primaryProfileIdsByLanguage: ["ja": legacyVideoProfile.id]
        )
        try JSONEncoder().encode(legacyIndex).write(to: profiles.appendingPathComponent("profiles.json"))
        defaults.set(ProfileRepository.legacyJapaneseVideoProfileID, forKey: ProfileRepository.videoProfileDefaultsKey)

        let repository = try ProfileRepository(appDirectory: root, defaults: defaults)
        precondition(repository.index.profiles.map(\.id) == [
            HoshiProfile.defaultJapanese.id,
            ProfileRepository.legacyJapaneseVideoProfileID,
        ])
        precondition(repository.profile(id: ProfileRepository.legacyJapaneseVideoProfileID)?.isDefault == false)
        precondition(repository.index.globalActiveProfileId == ProfileRepository.legacyJapaneseVideoProfileID)
        precondition(repository.index.primaryProfileIdsByLanguage["ja"] == ProfileRepository.legacyJapaneseVideoProfileID)
        precondition(repository.videoProfileID == ProfileRepository.legacyJapaneseVideoProfileID)
        let migratedConfig = try Data(contentsOf: repository.dictionaryConfigURL(for: HoshiProfile.defaultJapanese.id))
        precondition(migratedConfig == legacyConfig)
        precondition(FileManager.default.fileExists(atPath: repository.collapsedDictionariesURL(for: HoshiProfile.defaultJapanese.id).path))
        precondition(FileManager.default.fileExists(atPath: dictionaries.appendingPathComponent("config.json").path))
        let migratedAnki = try Data(contentsOf: repository.ankiConfigURL(for: HoshiProfile.defaultJapanese.id))
        precondition(migratedAnki == legacyAnki)
        let second = try ProfileRepository(appDirectory: root, defaults: defaults)
        precondition(second.index == repository.index)
        let persistedConfig = try Data(contentsOf: second.dictionaryConfigURL(for: HoshiProfile.defaultJapanese.id))
        precondition(persistedConfig == legacyConfig)
        let reloadedVideoConfig = try Data(
            contentsOf: second.dictionaryConfigURL(for: ProfileRepository.legacyJapaneseVideoProfileID)
        )
        precondition(reloadedVideoConfig == preservedVideoConfig)
    }

    private static func testEquivalentLegacyVideoProfileMerges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "profile-equivalent-video-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
        let defaultDirectory = profiles.appendingPathComponent(HoshiProfile.defaultJapanese.id)
        let legacyVideoDirectory = profiles.appendingPathComponent(
            ProfileRepository.legacyJapaneseVideoProfileID
        )
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyVideoDirectory, withIntermediateDirectories: true)
        let equivalentConfig = Data(
            #"{"termDictionaries":[],"frequencyDictionaries":[],"pitchDictionaries":[]}"#.utf8
        )
        try equivalentConfig.write(to: defaultDirectory.appendingPathComponent("dictionary_config.json"))
        try equivalentConfig.write(to: legacyVideoDirectory.appendingPathComponent("dictionary_config.json"))

        let legacyVideoProfile = HoshiProfile(
            id: ProfileRepository.legacyJapaneseVideoProfileID,
            name: "Japanese Video",
            dictionaryLanguageId: "ja",
            isDefault: true
        )
        let storedIndex = ProfileIndex(
            profiles: [.defaultJapanese, legacyVideoProfile],
            defaultProfileId: HoshiProfile.defaultJapanese.id,
            globalActiveProfileId: legacyVideoProfile.id,
            primaryProfileIdsByLanguage: ["ja": legacyVideoProfile.id]
        )
        try JSONEncoder().encode(storedIndex).write(
            to: profiles.appendingPathComponent("profiles.json")
        )
        defaults.set(
            ProfileRepository.legacyJapaneseVideoProfileID,
            forKey: ProfileRepository.videoProfileDefaultsKey
        )

        let repository = try ProfileRepository(appDirectory: root, defaults: defaults)
        precondition(repository.index.profiles == [.defaultJapanese])
        precondition(repository.index.globalActiveProfileId == HoshiProfile.defaultJapanese.id)
        precondition(repository.index.primaryProfileIdsByLanguage["ja"] == HoshiProfile.defaultJapanese.id)
        precondition(repository.videoProfileID == HoshiProfile.defaultJapanese.id)
        precondition(FileManager.default.fileExists(
            atPath: legacyVideoDirectory.appendingPathComponent("dictionary_config.json").path
        ))
    }

    private static func testProfileLifecycleAndPathSafety() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "profile-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        let repository = try ProfileRepository(appDirectory: root, defaults: defaults)
        precondition(repository.videoProfileID == HoshiProfile.defaultJapanese.id)
        let english = try repository.createProfile(name: " English ", language: .english, copyFromProfileID: nil)
        precondition(english.name == "English")
        precondition(repository.index.primaryProfileIdsByLanguage["en"] == english.id)
        try repository.setGlobalActiveProfile(english.id)
        try repository.setVideoProfile(english.id)
        precondition(repository.resolve(.global).id == english.id)
        precondition(repository.resolve(.video(profileID: repository.videoProfileID)).id == english.id)
        try repository.setVideoProfile(nil)
        precondition(repository.videoProfileID == HoshiProfile.defaultJapanese.id)
        precondition(repository.resolve(.video(profileID: repository.videoProfileID)).id == english.id)
        precondition(repository.resolve(.book(profileID: HoshiProfile.defaultJapanese.id, bookLanguage: "ja")).id == english.id)

        try repository.renameProfile(english.id, to: "English Novel")
        precondition(repository.profile(id: english.id)?.name == "English Novel")
        try repository.deleteProfile(english.id)
        precondition(repository.profile(id: english.id) == nil)
        precondition(repository.videoProfileID == HoshiProfile.defaultJapanese.id)
        precondition(repository.resolve(.global).id == HoshiProfile.defaultJapanese.id)

        do {
            _ = try repository.profileDirectory(for: "../escape")
            preconditionFailure("unsafe profile id should fail")
        } catch ProfileRepositoryError.unsafeProfileID {
            // Expected.
        }

        do {
            try repository.deleteProfile(HoshiProfile.defaultJapanese.id)
            preconditionFailure("default profile should not be deleted")
        } catch ProfileRepositoryError.cannotDeleteDefaultProfile {
            // Expected.
        }

    }

    private static func testProfileDictionaryBackupRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "profile-backup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        let repository = try ProfileRepository(appDirectory: root, defaults: defaults)
        let english = try repository.createProfile(name: "English", language: .english, copyFromProfileID: nil)
        let dictionaries = root.appendingPathComponent("Dictionaries")
        let dictionary = dictionaries.appendingPathComponent("Term/Oxford")
        try FileManager.default.createDirectory(at: dictionary, withIntermediateDirectories: true)
        let index = Data(#"{"title":"Oxford","format":3,"revision":"1","isUpdatable":false,"indexUrl":"","downloadUrl":""}"#.utf8)
        try index.write(to: dictionary.appendingPathComponent("index.json"))

        let defaultConfig = Data(#"{"termDictionaries":[{"fileName":"Oxford","isEnabled":false,"order":0}],"frequencyDictionaries":[],"pitchDictionaries":[]}"#.utf8)
        let englishConfig = Data(#"{"termDictionaries":[{"fileName":"Oxford","isEnabled":true,"order":0}],"frequencyDictionaries":[],"pitchDictionaries":[]}"#.utf8)
        try defaultConfig.write(to: repository.dictionaryConfigURL(for: HoshiProfile.defaultJapanese.id))
        try englishConfig.write(to: repository.dictionaryConfigURL(for: english.id))
        let preservedAnki = Data(#"{"selectedDeck":"English Mining"}"#.utf8)
        let preservedReader = Data(#"{"fontSize":30}"#.utf8)
        try preservedAnki.write(to: repository.ankiConfigURL(for: english.id))
        try preservedReader.write(to: repository.readerSettingsURL(for: english.id))

        let backup = ProfileDictionaryBackup(appDirectory: root, repository: repository)
        let staging = root.appendingPathComponent("Export")
        try backup.makeStagingDirectory(at: staging)
        precondition(FileManager.default.fileExists(atPath: staging.appendingPathComponent(".hoshi-profiles/profiles.json").path))
        let projectedDefaultConfig = try Data(contentsOf: staging.appendingPathComponent("config.json"))
        precondition(projectedDefaultConfig == defaultConfig)

        try Data(#"{"termDictionaries":[],"frequencyDictionaries":[],"pitchDictionaries":[]}"#.utf8)
            .write(to: repository.dictionaryConfigURL(for: english.id))
        try backup.restoreExtractedDirectory(staging)
        let restoredEnglishConfig = try Data(contentsOf: repository.dictionaryConfigURL(for: english.id))
        let restoredAnki = try Data(contentsOf: repository.ankiConfigURL(for: english.id))
        let restoredReader = try Data(contentsOf: repository.readerSettingsURL(for: english.id))
        precondition(restoredEnglishConfig == englishConfig)
        precondition(restoredAnki == preservedAnki)
        precondition(restoredReader == preservedReader)
        precondition(FileManager.default.fileExists(atPath: dictionaries.appendingPathComponent("Term/Oxford/index.json").path))

        let legacy = root.appendingPathComponent("Legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try defaultConfig.write(to: legacy.appendingPathComponent("config.json"))
        try backup.restoreExtractedDirectory(legacy)
        let restoredLegacyConfig = try Data(contentsOf: repository.dictionaryConfigURL(for: HoshiProfile.defaultJapanese.id))
        precondition(restoredLegacyConfig == defaultConfig)

        repository.removeDictionaryReferences(fileName: "Oxford", title: "Oxford")
        let cleanedEnglish = try JSONDecoder().decode(
            DictionaryConfig.self,
            from: Data(contentsOf: repository.dictionaryConfigURL(for: english.id))
        )
        precondition(cleanedEnglish.termDictionaries.isEmpty)
        let ankiAfterCleanup = try Data(contentsOf: repository.ankiConfigURL(for: english.id))
        precondition(ankiAfterCleanup == preservedAnki)
    }

    private static func testKanjiDictionaryConfigCompatibility() throws {
        precondition(DictionaryType(rawValue: "Kanji") == .kanji)

        let legacy = try JSONDecoder().decode(
            DictionaryConfig.self,
            from: Data(#"{"termDictionaries":[],"frequencyDictionaries":[],"pitchDictionaries":[]}"#.utf8)
        )
        precondition(legacy.kanjiDictionaries == nil)

        let current = Data(#"{"termDictionaries":[],"frequencyDictionaries":[],"pitchDictionaries":[],"kanjiDictionaries":[{"fileName":"KANJIDIC","isEnabled":true,"order":0},{"fileName":"Kanjium","isEnabled":false,"order":1}]}"#.utf8)
        let decoded = try JSONDecoder().decode(DictionaryConfig.self, from: current)
        precondition(decoded.kanjiDictionaries?.map(\.fileName) == ["KANJIDIC", "Kanjium"])
        let roundTrip = try JSONDecoder().decode(DictionaryConfig.self, from: JSONEncoder().encode(decoded))
        precondition(roundTrip.kanjiDictionaries?.map(\.isEnabled) == [true, false])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "profile-kanji-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let repository = try ProfileRepository(appDirectory: root, defaults: defaults)
        let configURL = repository.dictionaryConfigURL(for: HoshiProfile.defaultJapanese.id)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try current.write(to: configURL)
        repository.removeDictionaryReferences(fileName: "KANJIDIC", title: "KANJIDIC")
        let cleaned = try JSONDecoder().decode(DictionaryConfig.self, from: Data(contentsOf: configURL))
        precondition(cleaned.kanjiDictionaries?.map(\.fileName) == ["Kanjium"])
        precondition(cleaned.kanjiDictionaries?.first?.order == 0)

        let backupRoot = root.appendingPathComponent("BackupPayload")
        let kanjiDictionary = backupRoot.appendingPathComponent("Kanji/KANJIDIC")
        try FileManager.default.createDirectory(at: kanjiDictionary, withIntermediateDirectories: true)
        try Data("not a dictionary".utf8).write(to: kanjiDictionary.appendingPathComponent("broken.bin"))
        try current.write(to: backupRoot.appendingPathComponent("config.json"))
        let backup = ProfileDictionaryBackup(appDirectory: root, repository: repository)
        do {
            try backup.restoreExtractedDirectory(backupRoot)
            preconditionFailure("kanji dictionaries without index.json must be rejected")
        } catch ProfileDictionaryBackupError.missingDictionaryPayload {
        }
    }
}
