//
//  DictionaryManager.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI
import CHoshiDicts
import CxxStdlib

nonisolated private func dictionaryImporterTitleString(_ title: std.string) -> String {
    String(describing: title)
}

@Observable
@MainActor
class DictionaryManager {
    static let shared = DictionaryManager()
    static let frequencyDictionaryRenamedNotification = Notification.Name("hoshiFrequencyDictionaryRenamed")

    private struct PhysicalDictionaryCatalog {
        let termDictionaries: [DictionaryInfo]
        let frequencyDictionaries: [DictionaryInfo]
        let pitchDictionaries: [DictionaryInfo]
        let kanjiDictionaries: [DictionaryInfo]
        let updatableDictionaries: [(DictionaryInfo, DictionaryType)]
    }

    private(set) var activeProfileID: String
    private(set) var termDictionaries: [DictionaryInfo] = []
    private(set) var frequencyDictionaries: [DictionaryInfo] = []
    private(set) var pitchDictionaries: [DictionaryInfo] = []
    private(set) var kanjiDictionaries: [DictionaryInfo] = []
    private(set) var updatableDictionaries: [(DictionaryInfo, DictionaryType)] = []
    private(set) var availableDictionaryUpdates: [(DictionaryInfo, DictionaryType)] = []
    private(set) var collapsedDictionaries: Set<String> = []
    private(set) var isImporting = false
    private(set) var isUpdating = false
    private(set) var isCheckingUpdates = false
    private var physicalDictionaryCatalog: PhysicalDictionaryCatalog?
    private var dictionaryCatalogGeneration: UInt64 = 0
    var shouldShowError = false
    var errorMessage = ""
    var currentImport = ""

    /// Term dictionaries left out of the Anki `{glossary}` field; the popup still shows them.
    var excludedDictionaries: [String] {
        termDictionaries.filter { $0.category == .exclude }.map(\.index.title)
    }

    private static let configFileName = "config.json"
    private static let collapsedConfig = "collapsed.json"

    private init() {
        activeProfileID = ProfileRepository.shared.activeProfile.id
        reloadActiveProfileDictionaryState()
    }

    func reloadActiveProfileDictionaryState() {
        loadDictionaries()
        loadCollapsedDictionaries()
        refreshLookupQueryIfNeeded()
    }

    var activeLanguage: ContentLanguageProfile {
        ProfileRepository.shared.profile(id: activeProfileID)?.language ?? .japanese
    }

    var recommendedDictionaries: [DictionaryRecommendation] {
        DictionaryRecommendation.forLanguage(activeLanguage)
    }

    func activateProfile(_ profileID: String) {
        guard ProfileRepository.shared.profile(id: profileID) != nil else { return }
        guard activeProfileID != profileID else { return }
        activeProfileID = profileID
        applyActiveProfileDictionaryConfiguration()
        loadCollapsedDictionaries()
        refreshLookupQueryIfNeeded()
    }

    func loadDictionaries() {
        availableDictionaryUpdates = []
        physicalDictionaryCatalog = scanPhysicalDictionaryCatalog()
        dictionaryCatalogGeneration &+= 1
        applyActiveProfileDictionaryConfiguration()
    }

    private func applyActiveProfileDictionaryConfiguration() {
        guard let physicalDictionaryCatalog else {
            termDictionaries = []
            frequencyDictionaries = []
            pitchDictionaries = []
            kanjiDictionaries = []
            updatableDictionaries = []
            return
        }

        let storedTermDicts = physicalDictionaryCatalog.termDictionaries
        let storedFreqDicts = physicalDictionaryCatalog.frequencyDictionaries
        let storedPitchDicts = physicalDictionaryCatalog.pitchDictionaries
        let storedKanjiDicts = physicalDictionaryCatalog.kanjiDictionaries
        updatableDictionaries = physicalDictionaryCatalog.updatableDictionaries

        if let config = try? loadDictionaryConfig() {
            termDictionaries = collectDictionaries(storedDicts: storedTermDicts, configDicts: config.termDictionaries, enableUnconfigured: false)
            frequencyDictionaries = collectDictionaries(storedDicts: storedFreqDicts, configDicts: config.frequencyDictionaries, enableUnconfigured: false)
            pitchDictionaries = collectDictionaries(storedDicts: storedPitchDicts, configDicts: config.pitchDictionaries, enableUnconfigured: false)
            kanjiDictionaries = collectDictionaries(storedDicts: storedKanjiDicts, configDicts: config.kanjiDictionaries ?? [], enableUnconfigured: false)
        } else {
            let preserveLegacyDefaults = activeProfileID == ProfileRepository.shared.index.defaultProfileId
            termDictionaries = storedTermDicts.map { dictionary in
                var dictionary = dictionary
                dictionary.isEnabled = preserveLegacyDefaults
                return dictionary
            }
            frequencyDictionaries = storedFreqDicts.map { dictionary in
                var dictionary = dictionary
                dictionary.isEnabled = preserveLegacyDefaults
                return dictionary
            }
            pitchDictionaries = storedPitchDicts.map { dictionary in
                var dictionary = dictionary
                dictionary.isEnabled = preserveLegacyDefaults
                return dictionary
            }
            kanjiDictionaries = storedKanjiDicts.map { dictionary in
                var dictionary = dictionary
                dictionary.isEnabled = preserveLegacyDefaults
                return dictionary
            }
        }
    }

    func refreshLookupQueryIfNeeded() {
        let enabledTermPaths = termDictionaries
            .filter { $0.isEnabled }
            .map(\.path)

        let enabledFreqPaths = frequencyDictionaries
            .filter { $0.isEnabled }
            .map(\.path)

        let enabledPitchPaths = pitchDictionaries
            .filter { $0.isEnabled }
            .map(\.path)

        let enabledKanjiPaths = kanjiDictionaries
            .filter { $0.isEnabled }
            .map(\.path)

        LookupEngine.shared.buildQuery(
            termPaths: enabledTermPaths,
            freqPaths: enabledFreqPaths,
            pitchPaths: enabledPitchPaths,
            kanjiPaths: enabledKanjiPaths,
            languageID: activeLanguage.rawValue,
            contentGeneration: dictionaryCatalogGeneration
        )
    }

    private func scanPhysicalDictionaryCatalog() -> PhysicalDictionaryCatalog {
        updatableDictionaries = []
        let termDictionaries = (try? getDictionariesFromStorage(type: .term)) ?? []
        let frequencyDictionaries = (try? getDictionariesFromStorage(type: .frequency)) ?? []
        let pitchDictionaries = (try? getDictionariesFromStorage(type: .pitch)) ?? []
        let kanjiDictionaries = (try? getDictionariesFromStorage(type: .kanji)) ?? []
        return PhysicalDictionaryCatalog(
            termDictionaries: termDictionaries,
            frequencyDictionaries: frequencyDictionaries,
            pitchDictionaries: pitchDictionaries,
            kanjiDictionaries: kanjiDictionaries,
            updatableDictionaries: updatableDictionaries
        )
    }

    func collectDictionaries(
        storedDicts: [DictionaryInfo],
        configDicts: [DictionaryConfig.DictionaryEntry],
        enableUnconfigured: Bool = false
    ) -> [DictionaryInfo] {
        var result: [DictionaryInfo] = []

        // collect dictionaries that are saved in config
        for configDict in configDicts.sorted(by: { $0.order < $1.order }) {
            if let stored = storedDicts.first(where: { $0.path.lastPathComponent == configDict.fileName }) {
                var dictInfo = stored
                dictInfo.isEnabled = configDict.isEnabled
                dictInfo.order = configDict.order
                dictInfo.category = configDict.category ?? .none
                result.append(dictInfo)
            }
        }

        // append remaining dicts that were imported
        let currentResult = Set(result.map({ $0.path.lastPathComponent }))
        for storedDict in storedDicts {
            if !currentResult.contains(storedDict.path.lastPathComponent) {
                var dictInfo = storedDict
                dictInfo.isEnabled = enableUnconfigured
                dictInfo.order = result.count
                result.append(dictInfo)
            }
        }
        return result
    }

    func getDictionariesFromStorage(type: DictionaryType) throws -> [DictionaryInfo] {
        let directory = try Self.getDictionariesDirectory()
            .appendingPathComponent(type.rawValue)

        if !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap {
            let values = try $0.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                try? BookStorage.delete(at: $0)
                return nil
            }
            guard let index = BookStorage.load(DictionaryIndex.self, from: $0.appendingPathComponent("index.json")) else {
                try? BookStorage.delete(at: $0)
                return nil
            }
            let result = DictionaryInfo(index: index, path: $0)
            if let updateCapableIndex = DictionaryUpdateSourceResolver.updateCapableIndex(for: index, type: type) {
                let updateCapableResult = DictionaryInfo(
                    id: result.id,
                    index: updateCapableIndex,
                    path: result.path,
                    isEnabled: result.isEnabled,
                    order: result.order
                )
                updatableDictionaries.append((updateCapableResult, type))
                return updateCapableResult
            }
            return result
        }
    }

    private func loadDictionaryConfig() throws -> DictionaryConfig? {
        let configURL = ProfileRepository.shared.dictionaryConfigURL(for: activeProfileID)

        if FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)) {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            return try decoder.decode(DictionaryConfig.self, from: data)
        }
        return nil
    }

    private func loadCollapsedDictionaries() {
        collapsedDictionaries = []
        do {
            let configURL = ProfileRepository.shared.collapsedDictionariesURL(for: activeProfileID)

            if FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)) {
                let data = try Data(contentsOf: configURL)
                let decoder = JSONDecoder()
                collapsedDictionaries = try decoder.decode(Set<String>.self, from: data)
            }
        } catch {
            collapsedDictionaries = []
        }
    }

    private func saveDictionaryConfig() {
        let config = DictionaryConfig(
            termDictionaries: termDictionaries.map {
                DictionaryConfig.DictionaryEntry(
                    fileName: $0.path.lastPathComponent,
                    isEnabled: $0.isEnabled,
                    order: $0.order,
                    category: $0.category == .none ? nil : $0.category
                )
            },
            frequencyDictionaries: frequencyDictionaries.map {
                DictionaryConfig.DictionaryEntry(
                    fileName: $0.path.lastPathComponent,
                    isEnabled: $0.isEnabled,
                    order: $0.order,
                    category: $0.category == .none ? nil : $0.category
                )
            },
            pitchDictionaries: pitchDictionaries.map {
                DictionaryConfig.DictionaryEntry(
                    fileName: $0.path.lastPathComponent,
                    isEnabled: $0.isEnabled,
                    order: $0.order,
                    category: $0.category == .none ? nil : $0.category
                )
            },
            kanjiDictionaries: kanjiDictionaries.map {
                DictionaryConfig.DictionaryEntry(
                    fileName: $0.path.lastPathComponent,
                    isEnabled: $0.isEnabled,
                    order: $0.order
                )
            }
        )

        let configURL = ProfileRepository.shared.dictionaryConfigURL(for: activeProfileID)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(config)

            let directory = configURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            try data.write(to: configURL, options: .atomic)
            if activeProfileID == ProfileRepository.shared.index.defaultProfileId {
                let legacyURL = try Self.getDictionariesDirectory().appendingPathComponent(Self.configFileName)
                try data.write(to: legacyURL, options: .atomic)
            }
        } catch {
            showError(String(localized: "Failed to save dictionary config: \(error.localizedDescription)", table: "Dictionaries"))
        }
    }

    func saveCollapsedDictionaries() {
        let configURL = ProfileRepository.shared.collapsedDictionariesURL(for: activeProfileID)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(collapsedDictionaries)

            let directory = configURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            try data.write(to: configURL, options: .atomic)
            if activeProfileID == ProfileRepository.shared.index.defaultProfileId {
                let legacyURL = try Self.getDictionariesDirectory().appendingPathComponent(Self.collapsedConfig)
                try data.write(to: legacyURL, options: .atomic)
            }
        } catch {
            showError(String(localized: "Failed to save collapsed dictionaries: \(error.localizedDescription)", table: "Dictionaries"))
        }
    }

    func importRecommendedDictionaries(_ recommendations: [DictionaryRecommendation]? = nil) {
        let recommendations = recommendations ?? recommendedDictionaries
        guard !recommendations.isEmpty else { return }
        isImporting = true

        Task.detached {
            var tempFiles: [URL] = []
            var importedTitles = Set<String>()
            defer {
                for file in tempFiles {
                    try? FileManager.default.removeItem(at: file)
                }
            }

            do {
                for recommendation in recommendations {
                    await MainActor.run {
                        self.currentImport = String(localized: "Fetching \(recommendation.name)", table: "Dictionaries")
                    }

                    let downloadURL: URL
                    if let indexURL = recommendation.indexURL {
                        let (data, _) = try await URLSession.shared.data(from: URL(string: indexURL)!)
                        let remoteIndex = try JSONDecoder().decode(DictionaryIndex.self, from: data)
                        downloadURL = URL(string: remoteIndex.downloadUrl)!
                        await MainActor.run {
                            self.currentImport = String(localized: "Downloading \(remoteIndex.title)", table: "Dictionaries")
                        }
                    } else if let directURL = recommendation.downloadURL {
                        downloadURL = URL(string: directURL)!
                        await MainActor.run {
                            self.currentImport = String(localized: "Downloading \(recommendation.name)", table: "Dictionaries")
                        }
                    } else {
                        continue
                    }

                    let (temp, _) = try await URLSession.shared.download(from: downloadURL)
                    tempFiles.append(temp)

                    await MainActor.run {
                        self.currentImport = String(localized: "Importing \(recommendation.name)", table: "Dictionaries")
                    }

                    let destinationPath = try await Self.getDictionariesDirectory()
                        .appendingPathComponent(recommendation.type.rawValue).path(percentEncoded: false)

                    let importResult = dictionary_importer.import(
                        std.string(temp.path(percentEncoded: false)),
                        std.string(destinationPath)
                    )

                    if !importResult.success {
                        throw URLError(.cannotParseResponse)
                    }
                    importedTitles.insert(dictionaryImporterTitleString(importResult.title))
                }

                await MainActor.run {
                    self.isImporting = false
                    self.loadDictionaries()
                    self.enableDictionaries(named: importedTitles)
                    self.saveDictionaryConfig()
                    self.refreshLookupQueryIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.showError(String(localized: "Failed to download dictionaries: \(error.localizedDescription)", table: "Dictionaries"))
                }
            }
        }
    }

    func importDictionary(from urls: [URL]) {
        isImporting = true

        Task.detached {
            var imported: [String] = []
            var importedTitles = Set<String>()
            var failed: [String] = []

            for url in urls {
                await MainActor.run {
                    self.currentImport = String(localized: "Importing \(url.lastPathComponent)", table: "Dictionaries")
                }

                let current = url.lastPathComponent
                guard url.startAccessingSecurityScopedResource() else {
                    failed.append(current)
                    continue
                }

                defer { url.stopAccessingSecurityScopedResource() }

                let importResult = dictionary_importer.import(
                    std.string(url.path(percentEncoded: false)),
                    std.string(FileManager.default.temporaryDirectory.path(percentEncoded: false))
                )

                if importResult.success {
                    let title = dictionaryImporterTitleString(importResult.title)
                    importedTitles.insert(title)
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(String(title))
                    defer { try? FileManager.default.removeItem(at: temp) }
                    if importResult.term_count > 0 {
                        try await BookStorage.copyFile(from: temp, to: "Dictionaries/\(DictionaryType.term.rawValue)/\(title)")
                    }
                    if importResult.freq_count > 0 {
                        try await BookStorage.copyFile(from: temp, to: "Dictionaries/\(DictionaryType.frequency.rawValue)/\(title)")
                    }
                    if importResult.pitch_count > 0 {
                        try await BookStorage.copyFile(from: temp, to: "Dictionaries/\(DictionaryType.pitch.rawValue)/\(title)")
                    }
                    if importResult.kanji_count > 0 {
                        try await BookStorage.copyFile(from: temp, to: "Dictionaries/\(DictionaryType.kanji.rawValue)/\(title)")
                    }
                    imported.append(current)
                } else if let reason = importResult.errors.first {
                    failed.append("\(current): \(String(reason))")
                } else {
                    failed.append(current)
                }
            }

            await MainActor.run {
                self.isImporting = false

                if !imported.isEmpty {
                    self.loadDictionaries()
                    self.enableDictionaries(named: importedTitles)
                    self.saveDictionaryConfig()
                    self.refreshLookupQueryIfNeeded()
                }

                if imported.isEmpty {
                    self.showError(failed.isEmpty
                        ? String(localized: "Failed to import dictionary", table: "Dictionaries")
                        : String(localized: "Failed to import dictionary:\n\(failed.joined(separator: "\n"))", table: "Dictionaries"))
                } else if !failed.isEmpty {
                    self.showError(String(localized: "Some dictionaries could not be imported:\n\(failed.joined(separator: "\n"))", table: "Dictionaries"))
                }
            }
        }
    }

    func updateDictionaries(
        _ dictionaries: [(DictionaryInfo, DictionaryType)]? = nil,
        showErrors: Bool = true,
        refreshAvailabilityAfterUpdate: Bool = false,
        session: URLSession = .shared
    ) {
        let dictionaries = dictionaries ?? updatableDictionaries
        guard !dictionaries.isEmpty else { return }
        isUpdating = true
        Task.detached {
            var tempFiles: [URL] = []
            defer {
                for file in tempFiles {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            var failures: [String] = []
            for (dictionary, type) in dictionaries {
                let index = dictionary.index
                await MainActor.run {
                    self.currentImport = String(localized: "Checking \(index.title)", table: "Dictionaries")
                }

                do {
                    let (data, _) = try await session.data(from: URL(string: index.indexUrl)!)
                    let remoteIndex = try JSONDecoder().decode(DictionaryIndex.self, from: data)

                    if !DictionaryUpdateAvailability.shouldOfferUpdate(
                        localRevision: index.revision,
                        remoteRevision: remoteIndex.revision
                    ) {
                        continue
                    }

                    await MainActor.run {
                        self.currentImport = String(localized: "Downloading \(remoteIndex.title)", table: "Dictionaries")
                    }

                    let (temp, _) = try await session.download(from: URL(string: remoteIndex.downloadUrl)!)
                    tempFiles.append(temp)

                    await MainActor.run {
                        self.currentImport = String(localized: "Importing \(remoteIndex.title)", table: "Dictionaries")
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    tempFiles.append(tempDir)

                    let importResult = dictionary_importer.import(
                        std.string(temp.path(percentEncoded: false)),
                        std.string(tempDir.path(percentEncoded: false))
                    )

                    if !importResult.success {
                        failures.append(importResult.errors.first.map { "\(index.title): \(String($0))" }
                            ?? String(localized: "\(index.title): Import failed", table: "Dictionaries"))
                        continue
                    }

                    let new = dictionaryImporterTitleString(importResult.title)
                    let old = dictionary.index.title
                    let tempPath = tempDir.appendingPathComponent(new)
                    let destPath = try await Self.getDictionariesDirectory()
                        .appendingPathComponent(type.rawValue)
                        .appendingPathComponent(new)

                    if new == old {
                        try? FileManager.default.removeItem(at: destPath)
                    }
                    try FileManager.default.moveItem(at: tempPath, to: destPath)

                    await MainActor.run {
                        self.loadDictionaries()
                        if old != new {
                            if let currentIndex = self.getDictionaryIndex(title: old, type: type) {
                                let wasEnabled = self.isDictionaryEnabled(at: currentIndex, type: type)
                                let wasCollapsed = self.collapsedDictionaries.contains(old)
                                let wasCategory = type == .term ? self.termDictionaries[currentIndex].category : .none
                                self.deleteDictionary(indexSet: IndexSet(integer: currentIndex), type: type)
                                let importedIndex = self.getDictionaryIndex(title: new, type: type)!
                                self.setDictionaryEnabled(index: importedIndex, enabled: wasEnabled, type: type)
                                let importedID = self.termDictionaries.indices.contains(importedIndex) && type == .term
                                    ? self.termDictionaries[importedIndex].id
                                    : nil
                                self.moveDictionary(from: IndexSet(integer: importedIndex), to: currentIndex, type: type)
                                if let importedID, wasCategory != .none {
                                    self.setDictionaryCategory(id: importedID, category: wasCategory)
                                }
                                if type == .frequency {
                                    NotificationCenter.default.post(
                                        name: Self.frequencyDictionaryRenamedNotification,
                                        object: nil,
                                        userInfo: ["old": old, "new": new]
                                    )
                                }
                                AnkiManager.shared.updateHandlebar(old: old, new: new)
                                if wasCollapsed {
                                    self.collapsedDictionaries.insert(new)
                                    self.saveCollapsedDictionaries()
                                }
                            }
                        } else {
                            self.refreshLookupQueryIfNeeded()
                        }
                    }
                } catch {
                    failures.append("\(index.title): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                self.isUpdating = false
                self.availableDictionaryUpdates.removeAll { candidate, _ in
                    dictionaries.contains { dictionary, _ in dictionary.id == candidate.id }
                }
                if failures.count < dictionaries.count {
                    UserDefaults.standard.set(Date.now, forKey: "lastDictionaryUpdate")
                }
                if !failures.isEmpty && showErrors {
                    self.showError(failures.joined(separator: "\n"))
                }
            }

            if refreshAvailabilityAfterUpdate {
                _ = await self.refreshAvailableDictionaryUpdates(showErrors: false, session: session)
            }
        }
    }

    func refreshAvailableDictionaryUpdates(showErrors: Bool = true, session: URLSession = .shared) async -> [(DictionaryInfo, DictionaryType)] {
        let dictionaries = updatableDictionaries
        guard !dictionaries.isEmpty else {
            availableDictionaryUpdates = []
            return []
        }

        isCheckingUpdates = true
        var candidates: [(DictionaryInfo, DictionaryType)] = []
        var failures: [String] = []

        for (dictionary, type) in dictionaries {
            let index = dictionary.index
            currentImport = String(localized: "Checking \(index.title)", table: "Dictionaries")

            do {
                let (data, _) = try await session.data(from: URL(string: index.indexUrl)!)
                let remoteIndex = try JSONDecoder().decode(DictionaryIndex.self, from: data)

                if DictionaryUpdateAvailability.shouldOfferUpdate(
                    localRevision: index.revision,
                    remoteRevision: remoteIndex.revision
                ) {
                    candidates.append((dictionary, type))
                }
            } catch {
                failures.append("\(index.title): \(error.localizedDescription)")
            }
        }

        availableDictionaryUpdates = candidates
        isCheckingUpdates = false

        if !failures.isEmpty && showErrors {
            showError(failures.joined(separator: "\n"))
        }

        return candidates
    }

    func autoUpdateDictionaries() {
        guard !isImporting, !isUpdating, !updatableDictionaries.isEmpty else {
            return
        }

        let interval = UserDefaults.standard.string(forKey: "dictionaryUpdateInterval")
            .flatMap(DictionaryUpdateInterval.init)?
            .timeInterval ?? DictionaryUpdateInterval.weekly.timeInterval
        let lastUpdate = UserDefaults.standard.object(forKey: "lastDictionaryUpdate") as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastUpdate) >= interval else {
            return
        }

        let config = URLSessionConfiguration.default
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        updateDictionaries(showErrors: false, session: URLSession(configuration: config))
    }

    func toggleDictionary(id: UUID, enabled: Bool, type: DictionaryType) {
        switch type {
        case .term:
            guard let index = termDictionaries.firstIndex(where: { $0.id == id }) else { return }
            termDictionaries[index].isEnabled = enabled
        case .frequency:
            guard let index = frequencyDictionaries.firstIndex(where: { $0.id == id }) else { return }
            frequencyDictionaries[index].isEnabled = enabled
        case .pitch:
            guard let index = pitchDictionaries.firstIndex(where: { $0.id == id }) else { return }
            pitchDictionaries[index].isEnabled = enabled
        case .kanji:
            guard let index = kanjiDictionaries.firstIndex(where: { $0.id == id }) else { return }
            kanjiDictionaries[index].isEnabled = enabled
        }
        saveDictionaryConfig()
        refreshLookupQueryIfNeeded()
    }

    func setDictionaryCategory(id: UUID, category: DictionaryCategory) {
        guard let index = termDictionaries.firstIndex(where: { $0.id == id }) else { return }
        termDictionaries[index].category = category
        saveDictionaryConfig()
    }

    func moveDictionary(from: IndexSet, to: Int, type: DictionaryType) {
        switch type {
        case .term:
            termDictionaries.move(fromOffsets: from, toOffset: to)
        case .frequency:
            frequencyDictionaries.move(fromOffsets: from, toOffset: to)
        case .pitch:
            pitchDictionaries.move(fromOffsets: from, toOffset: to)
        case .kanji:
            kanjiDictionaries.move(fromOffsets: from, toOffset: to)
        }
        updateOrder(type: type)
        saveDictionaryConfig()
        refreshLookupQueryIfNeeded()
    }

    func updateOrder(type: DictionaryType) {
        switch type {
        case .term:
            for index in termDictionaries.indices {
                termDictionaries[index].order = index
            }
        case .frequency:
            for index in frequencyDictionaries.indices {
                frequencyDictionaries[index].order = index
            }
        case .pitch:
            for index in pitchDictionaries.indices {
                pitchDictionaries[index].order = index
            }
        case .kanji:
            for index in kanjiDictionaries.indices {
                kanjiDictionaries[index].order = index
            }
        }
    }

    func deleteDictionary(indexSet: IndexSet, type: DictionaryType) {
        let dictionaries: [DictionaryInfo] = indexSet.compactMap { index in
            switch type {
            case .term: termDictionaries.indices.contains(index) ? termDictionaries[index] : nil
            case .frequency: frequencyDictionaries.indices.contains(index) ? frequencyDictionaries[index] : nil
            case .pitch: pitchDictionaries.indices.contains(index) ? pitchDictionaries[index] : nil
            case .kanji: kanjiDictionaries.indices.contains(index) ? kanjiDictionaries[index] : nil
            }
        }
        for dictionary in dictionaries {
            ProfileRepository.shared.removeDictionaryReferences(
                fileName: dictionary.path.lastPathComponent,
                title: dictionary.index.title
            )
            try? BookStorage.delete(at: dictionary.path)
            updatableDictionaries.removeAll { $0.0.path == dictionary.path }
            collapsedDictionaries.remove(dictionary.index.title)
        }

        switch type {
        case .term:
            for index in indexSet.sorted(by: >) where termDictionaries.indices.contains(index) {
                termDictionaries.remove(at: index)
            }
        case .frequency:
            for index in indexSet.sorted(by: >) where frequencyDictionaries.indices.contains(index) {
                frequencyDictionaries.remove(at: index)
            }
        case .pitch:
            for index in indexSet.sorted(by: >) where pitchDictionaries.indices.contains(index) {
                pitchDictionaries.remove(at: index)
            }
        case .kanji:
            for index in indexSet.sorted(by: >) where kanjiDictionaries.indices.contains(index) {
                kanjiDictionaries.remove(at: index)
            }
        }
        updateOrder(type: type)
        saveDictionaryConfig()
        saveCollapsedDictionaries()
        loadDictionaries()
        refreshLookupQueryIfNeeded()
    }

    func toggleCollapsedDictionary(title: String) {
        if collapsedDictionaries.contains(title) {
            collapsedDictionaries.remove(title)
        } else {
            collapsedDictionaries.insert(title)
        }
        saveCollapsedDictionaries()
    }

    private func isDictionaryEnabled(at index: Int, type: DictionaryType) -> Bool {
        switch type {
        case .term:
            termDictionaries[index].isEnabled
        case .frequency:
            frequencyDictionaries[index].isEnabled
        case .pitch:
            pitchDictionaries[index].isEnabled
        case .kanji:
            kanjiDictionaries[index].isEnabled
        }
    }

    private func setDictionaryEnabled(index: Int, enabled: Bool, type: DictionaryType) {
        switch type {
        case .term:
            termDictionaries[index].isEnabled = enabled
        case .frequency:
            frequencyDictionaries[index].isEnabled = enabled
        case .pitch:
            pitchDictionaries[index].isEnabled = enabled
        case .kanji:
            kanjiDictionaries[index].isEnabled = enabled
        }
    }

    private func enableDictionaries(named titles: Set<String>) {
        for index in termDictionaries.indices where titles.contains(termDictionaries[index].index.title) {
            termDictionaries[index].isEnabled = true
        }
        for index in frequencyDictionaries.indices where titles.contains(frequencyDictionaries[index].index.title) {
            frequencyDictionaries[index].isEnabled = true
        }
        for index in pitchDictionaries.indices where titles.contains(pitchDictionaries[index].index.title) {
            pitchDictionaries[index].isEnabled = true
        }
        for index in kanjiDictionaries.indices where titles.contains(kanjiDictionaries[index].index.title) {
            kanjiDictionaries[index].isEnabled = true
        }
    }

    private func getDictionaryIndex(title: String, type: DictionaryType) -> Int? {
        switch type {
        case .term:
            termDictionaries.firstIndex { $0.index.title == title }
        case .frequency:
            frequencyDictionaries.firstIndex { $0.index.title == title }
        case .pitch:
            pitchDictionaries.firstIndex { $0.index.title == title }
        case .kanji:
            kanjiDictionaries.firstIndex { $0.index.title == title }
        }
    }

    private static func getDictionariesDirectory() throws -> URL {
        try BookStorage.getAppDirectory().appendingPathComponent("Dictionaries")
    }

    private func showError(_ message: String) {
        errorMessage = message
        shouldShowError = true
    }
}
