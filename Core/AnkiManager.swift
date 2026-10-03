//
//  AnkiManager.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import SQLite3
import libzstd
import ZIPFoundation

struct AnkiDuplicateLookupResult {
    let isDuplicate: Bool
    let noteIDs: [Int64]

    var webPayload: [String: Any] {
        [
            "isDuplicate": isDuplicate,
            "noteIDs": noteIDs.map(String.init)
        ]
    }
}

@Observable
@MainActor
class AnkiManager {
    static let shared = AnkiManager()

    private(set) var activeProfileID = HoshiProfile.defaultJapanese.id
    
    var selectedDeck: String?
    var selectedNoteType: String?
    var fieldMappings: [String: String] = [:]
    var tags: String = ""
    
    var availableDecks: [String] = []
    var availableNoteTypes: [AnkiNoteType] = []
    
    var allowDupes: Bool = false
    var compactGlossaries: Bool = false
    var embedMedia: Bool = false
    var compressImages = true
    var imageCompressionQuality = 0.80
    var imageCompressionFormat: AnkiImageCompressionFormat = .jpeg
    var animatedAVIFMaximumHeight = AnkiAnimatedAVIFConfiguration.defaultMaximumHeight
    var animatedAVIFFramesPerSecond = AnkiAnimatedAVIFConfiguration.defaultFramesPerSecond
    var audioCompressionFormat: AnkiAudioCompressionFormat = .aac
    var audioCompressionBitrateKbps = 64
    
    var errorMessage: String?
    
    var savedWords: Set<String> = []
    
    var isConnected: Bool {
        isAnkiConnectReachable
    }
    
    var needsAudio: Bool {
        fieldMappings.values.contains(Handlebars.audio.rawValue)
    }
    
    var needsSasayakiAudio: Bool {
        fieldMappings.values.contains(Handlebars.sasayakiAudio.rawValue)
    }

    var needsVideoScreenshot: Bool {
        fieldMappings.values.contains(Handlebars.bookCover.rawValue)
            || fieldMappings.values.contains(Handlebars.videoScreenshot.rawValue)
    }

    var needsVideoAudioClip: Bool {
        fieldMappings.values.contains(Handlebars.sasayakiAudio.rawValue)
            || fieldMappings.values.contains(Handlebars.videoAudioClip.rawValue)
    }
    
    var useAnkiConnect: Bool { true }
    var ankiConnectConfig: AnkiConnectConfig? = AnkiConnectConfig(url: "http://127.0.0.1:8765", timeout: 10, duplicateScope: .collection, forceSync: false)
    var isAnkiConnectReachable = false
    private var ankiConnectReconnectTask: Task<Void, Never>?
    
    private static let ankiConfig = "anki_config.json"
    private static let ankiWords = "anki_words.json"
    
    private static let handlebarRegex = /\{.*?\}/
    private static let defaultAnkiConnectURL = "http://127.0.0.1:8765"
    private static let ankiBundleIdentifiers = [
        "net.ankiweb.anki",
        "net.ankiweb.dtop",
        "net.ichi2.anki"
    ]
    private static let ankiActivationPollDelay = Duration.milliseconds(50)
    private static let ankiActivationPollAttempts = 10

    private enum CachedAnkiMediaDirectory {
        case available(URL)
        case unavailable
    }

    private struct NoteBuildConfiguration {
        let fieldMappings: [String: String]
        let tags: String
        let allowDuplicates: Bool
        let duplicateScope: DuplicateScope
        let checkAllModels: Bool
        let compressImages: Bool
        let imageCompressionQuality: Double
        let imageCompressionFormat: AnkiImageCompressionFormat
        let audioCompressionFormat: AnkiAudioCompressionFormat
    }

    private var cachedAnkiMediaDirectories: [String: CachedAnkiMediaDirectory] = [:]
    
    private init() {
        activeProfileID = ProfileRepository.shared.activeProfile.id
        loadTransport()
        loadProfile()
        ensureAnkiConnectURL()
        if autofillFieldMappings() {
            save()
        }
        loadWords()
        if ankiConnectConfig?.url != nil {
            scheduleAnkiConnectReconnect(immediate: true)
        }
    }

    func activateProfile(_ profileID: String) {
        guard ProfileRepository.shared.profile(id: profileID) != nil else { return }
        guard activeProfileID != profileID else { return }
        if ProfileRepository.shared.profile(id: activeProfileID) != nil {
            save()
        }
        activeProfileID = profileID
        loadProfile()
        if autofillFieldMappings() {
            save()
        }
    }
    
    func pingAnkiConnect() async {
        await refreshAnkiConnectStatus(scheduleRetry: true)
    }

    func getMediaDirPath() async -> URL? {
        ensureAnkiConnectURL()
        let cacheKey = ankiMediaDirectoryCacheKey
        if let cached = cachedAnkiMediaDirectories[cacheKey] {
            switch cached {
            case .available(let url):
                return url
            case .unavailable:
                return nil
            }
        }

        do {
            guard let path = try await ankiConnectRequest(action: "getMediaDirPath") as? String else {
                cachedAnkiMediaDirectories[cacheKey] = .unavailable
                return nil
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false),
                isDirectory: &isDirectory
            )
            guard exists,
                  isDirectory.boolValue,
                  FileManager.default.isWritableFile(atPath: url.path(percentEncoded: false)) else {
                cachedAnkiMediaDirectories[cacheKey] = .unavailable
                return nil
            }
            cachedAnkiMediaDirectories[cacheKey] = .available(url)
            return url
        } catch {
            cachedAnkiMediaDirectories[cacheKey] = .unavailable
            return nil
        }
    }

    func handleAppBecameActive() {
        ensureAnkiConnectURL()
        scheduleAnkiConnectReconnect(immediate: true)
    }

    private func refreshAnkiConnectStatus(scheduleRetry: Bool) async {
        ensureAnkiConnectURL()
        do {
            _ = try await ankiConnectRequest(action: "version")
            isAnkiConnectReachable = true
            ankiConnectReconnectTask?.cancel()
            ankiConnectReconnectTask = nil
            save()
        } catch {
            isAnkiConnectReachable = false
            if scheduleRetry {
                scheduleAnkiConnectReconnect()
            }
        }
    }

    private func scheduleAnkiConnectReconnect(immediate: Bool = false) {
        ensureAnkiConnectURL()
        guard !isAnkiConnectReachable, ankiConnectReconnectTask == nil else { return }

        ankiConnectReconnectTask = Task { @MainActor [weak self] in
            var delay: UInt64 = immediate ? 0 : 2_000_000_000

            while !Task.isCancelled {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }

                guard let self else { return }

                do {
                    _ = try await self.ankiConnectRequest(action: "version")
                    self.isAnkiConnectReachable = true
                    self.ankiConnectReconnectTask = nil
                    self.save()
                    return
                } catch {
                    self.isAnkiConnectReachable = false
                    delay = delay == 0 ? 2_000_000_000 : min(delay * 2, 10_000_000_000)
                }
            }
        }
    }

    private func ensureAnkiConnectURL() {
        let current = ankiConnectConfig?.url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if current?.isEmpty != false {
            if ankiConnectConfig == nil {
                ankiConnectConfig = AnkiConnectConfig(url: Self.defaultAnkiConnectURL, timeout: 10, duplicateScope: .collection, forceSync: false)
            } else {
                ankiConnectConfig?.url = Self.defaultAnkiConnectURL
            }
        }
    }

    func setAnkiConnectURL(_ url: String) {
        ankiConnectConfig?.url = url
        save()
    }

    func setAnkiConnectAPIKey(_ apiKey: String) {
        ankiConnectConfig?.apiKey = apiKey
        save()
    }

    func setFieldMapping(_ value: String, for field: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            fieldMappings[field] = ""
        } else {
            fieldMappings[field] = value
        }
        save()
    }

    func setTags(_ tags: String) {
        self.tags = tags
        save()
    }
    
    func fetchAnkiConnect() async {
        await refreshAnkiConnectStatus(scheduleRetry: false)

        guard isAnkiConnectReachable else {
            scheduleAnkiConnectReconnect()
            errorMessage = String(localized: "AnkiConnect is not connected. Please start Anki and try again.")
            return
        }

        do {
            guard let decks = try await ankiConnectRequest(action: "deckNames") as? [String],
                  let models = try await ankiConnectRequest(action: "modelNames") as? [String] else {
                return
            }
            
            var noteTypes: [AnkiNoteType] = []
            for model in models {
                if let fields = try await ankiConnectRequest(action: "modelFieldNames", params: ["modelName": model]) as? [String] {
                    noteTypes.append(AnkiNoteType(name: model, fields: fields))
                }
            }

            applyFetchedAnkiMetadata(decks: decks, noteTypes: noteTypes)
            isAnkiConnectReachable = true
            save()
        } catch {
            isAnkiConnectReachable = false
            scheduleAnkiConnectReconnect()
            errorMessage = error.localizedDescription
        }
    }

    private func applyFetchedAnkiMetadata(decks: [String], noteTypes: [AnkiNoteType]) {
        let usableNoteTypes = noteTypes.filter { !$0.fields.isEmpty }
        guard !decks.isEmpty, !usableNoteTypes.isEmpty else {
            errorMessage = String(localized: "No decks or models were returned from Anki.")
            return
        }

        availableDecks = decks
        availableNoteTypes = usableNoteTypes

        if let selectedDeck, decks.contains(selectedDeck) {
            self.selectedDeck = selectedDeck
        } else if let deck = decks.first(where: { $0.caseInsensitiveCompare("Default") != .orderedSame }) {
            selectedDeck = deck
        } else {
            selectedDeck = decks.first
        }

        if let selectedNoteType,
           let noteType = usableNoteTypes.first(where: { $0.name == selectedNoteType }) {
            pruneFieldMappings(availableFields: noteType.fields)
            autofillFieldMappings()
        } else if let noteType = usableNoteTypes.first {
            selectedNoteType = noteType.name
            pruneFieldMappings(availableFields: noteType.fields)
            autofillFieldMappings()
        }
    }

    private func pruneFieldMappings(availableFields: [String]) {
        let available = Set(availableFields)
        fieldMappings = fieldMappings.filter { field, _ in
            available.contains(field)
        }
    }

    @discardableResult
    func autofillFieldMappings() -> Bool {
        guard let selectedNoteType,
              let noteType = availableNoteTypes.first(where: { $0.name == selectedNoteType }) else {
            return false
        }

        let updated = AnkiFieldTemplate.autofilledMappings(
            noteType: selectedNoteType,
            availableFields: noteType.fields,
            existing: fieldMappings
        )
        guard updated != fieldMappings else { return false }
        fieldMappings = updated
        return true
    }

    @discardableResult
    func applyDefaultFieldMappings() -> Bool {
        guard let selectedNoteType,
              let noteType = availableNoteTypes.first(where: { $0.name == selectedNoteType }) else {
            return false
        }

        let updated = AnkiFieldTemplate.appliedDefaultMappings(
            noteType: selectedNoteType,
            availableFields: noteType.fields,
            existing: fieldMappings
        )
        guard updated != fieldMappings else { return false }
        fieldMappings = updated
        return true
    }

    func addNote(content: [String: String], context: MiningContext) async -> Int64? {
        guard let deck = selectedDeck,
              let noteType = selectedNoteType else {
            return nil
        }

        let configuration = NoteBuildConfiguration(
            fieldMappings: fieldMappings,
            tags: tags,
            allowDuplicates: allowDupes,
            duplicateScope: ankiConnectConfig?.duplicateScope ?? .collection,
            checkAllModels: ankiConnectConfig?.checkAllModels == true,
            compressImages: compressImages,
            imageCompressionQuality: imageCompressionQuality,
            imageCompressionFormat: imageCompressionFormat,
            audioCompressionFormat: audioCompressionFormat
        )
        return await addNoteAnkiConnect(
            content: content,
            context: context,
            deck: deck,
            noteType: noteType,
            configuration: configuration
        )
    }

    private var ankiMediaDirectoryCacheKey: String {
        "\(ankiConnectConfig?.url ?? "")\n\(ankiConnectConfig?.apiKey ?? "")"
    }

    private func directAudioMarkup(filename: String) -> String {
        "[sound:\(safeAnkiMediaFilename(filename))]"
    }

    private func directImageMarkup(filename: String) -> String {
        "<img src=\"\(safeAnkiMediaFilename(filename))\">"
    }

    @discardableResult
    private func writeDirectMedia(
        data: Data,
        filename: String,
        mediaDirectory: URL
    ) throws -> String {
        let safeFilename = safeAnkiMediaFilename(filename)
        let destination = mediaDirectory.appendingPathComponent(
            safeFilename,
            isDirectory: false
        )
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            return safeFilename
        }
        let tempURL = mediaDirectory.appendingPathComponent(
            ".\(safeFilename).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try data.write(to: tempURL)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        return safeFilename
    }

    private func setDirectMediaFields(
        _ fieldNames: [String],
        markup: String,
        fields: inout [String: String]
    ) {
        for field in fieldNames {
            fields[field] = markup
        }
    }

    private func safeAnkiMediaFilename(_ filename: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: filename).lastPathComponent
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let sanitized = String(lastPathComponent.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return trimmed.isEmpty ? "hoshi_media" : sanitized
    }

    private func safeMediaExtension(_ ext: String, fallback: String) -> String {
        guard !ext.isEmpty else { return fallback }
        let sanitized = safeAnkiMediaFilename(ext.lowercased())
        return sanitized.contains(".") || sanitized.isEmpty ? fallback : sanitized
    }
    
    private func addNoteAnkiConnect(
        content: [String: String],
        context: MiningContext,
        deck: String,
        noteType: String,
        configuration: NoteBuildConfiguration
    ) async -> Int64? {
        let singleGlossaries: [String: String]
        if let singleGlossariesJson = content["singleGlossaries"],
           let singleGlossariesData = singleGlossariesJson.data(using: .utf8),
           let singleGlossariesParsed = try? JSONDecoder().decode([String: String].self, from: singleGlossariesData) {
            singleGlossaries = singleGlossariesParsed
        } else {
            singleGlossaries = [:]
        }
        
        var fields: [String: String] = [:]
        var audioFields: [String] = []
        var sasayakiAudioFields: [String] = []
        var videoAudioFields: [String] = []
        var pictureFields: [String] = []
        var videoScreenshotFields: [String] = []
        
        for (field, fieldContent) in configuration.fieldMappings {
            if fieldContent == Handlebars.audio.rawValue {
                audioFields.append(field)
            } else if fieldContent == Handlebars.sasayakiAudio.rawValue {
                if context.video == nil {
                    sasayakiAudioFields.append(field)
                } else {
                    videoAudioFields.append(field)
                }
            } else if fieldContent == Handlebars.videoAudioClip.rawValue {
                videoAudioFields.append(field)
            } else if fieldContent == Handlebars.bookCover.rawValue {
                if context.video == nil {
                    pictureFields.append(field)
                } else {
                    videoScreenshotFields.append(field)
                }
            } else if fieldContent == Handlebars.videoScreenshot.rawValue {
                videoScreenshotFields.append(field)
            } else {
                fields[field] = fieldContent.replacing(Self.handlebarRegex) { match in
                    handlebarToValue(handlebar: String(match.0), context: context, content: content, singleGlossaries: singleGlossaries)
                }
            }
        }

        let dictionaryMedia = content["dictionaryMedia"].flatMap {
            try? JSONDecoder().decode([DictionaryMedia].self, from: Data($0.utf8))
        }
        let shouldResolveDirectMediaDirectory = !sasayakiAudioFields.isEmpty
            || !videoAudioFields.isEmpty
            || !pictureFields.isEmpty
            || !videoScreenshotFields.isEmpty
            || dictionaryMedia?.isEmpty == false
        let directMediaDirectory = shouldResolveDirectMediaDirectory
            ? await getMediaDirPath()
            : nil
        
        let options = configuration.duplicateScope.ankiConnectOptions(
            deck: deck,
            allowDuplicates: configuration.allowDuplicates,
            checkAllModels: configuration.checkAllModels
        )
        var note: [String: Any] = [
            "deckName": deck,
            "modelName": noteType,
            "fields": fields,
            "options": options
        ]
        
        var audio: [[String: Any]] = []
        if !audioFields.isEmpty, let audioURL = content["audio"],
           let url = URL(string: audioURL),
           let audioData = try? await URLSession.shared.data(from: url).0 {
            audio.append([
                "data": audioData.base64EncodedString(),
                "filename": "hoshi_audio_\(audioData.sha1).mp3",
                "fields": audioFields
            ])
        }
        if !sasayakiAudioFields.isEmpty, let audioData = context.sasayakiAudioData {
            let filename = "hoshi_sasayaki_\(audioData.sha1).\(context.sasayakiAudioFormat.fileExtension)"
            if let directMediaDirectory,
               let directFilename = try? writeDirectMedia(
                data: audioData,
                filename: filename,
                mediaDirectory: directMediaDirectory
               ) {
                setDirectMediaFields(
                    sasayakiAudioFields,
                    markup: directAudioMarkup(filename: directFilename),
                    fields: &fields
                )
            } else {
                audio.append([
                    "data": audioData.base64EncodedString(),
                    "filename": filename,
                    "fields": sasayakiAudioFields
                ])
            }
        }
        if !videoAudioFields.isEmpty {
            if directMediaDirectory != nil,
               let filename = context.video?.audioClipFilename {
                setDirectMediaFields(
                    videoAudioFields,
                    markup: directAudioMarkup(filename: filename),
                    fields: &fields
                )
            } else if let audioURL = context.video?.audioClipURL,
                      let audioData = try? Data(contentsOf: audioURL) {
                let ext = safeMediaExtension(
                    audioURL.pathExtension,
                    fallback: configuration.audioCompressionFormat.fileExtension
                )
                audio.append([
                    "data": audioData.base64EncodedString(),
                    "filename": "hoshi_video_audio_\(audioData.sha1).\(ext)",
                    "fields": videoAudioFields
                ])
            }
        }
        if !audio.isEmpty {
            note["audio"] = audio
        }
        
        let pictureSource: (data: Data, fileExtension: String, filenamePrefix: String)? = {
            if let manga = context.manga {
                return (
                    manga.imageData,
                    safeMediaExtension(manga.imageExtension, fallback: "png"),
                    "hoshi_manga_page"
                )
            }
            if let coverURL = context.coverURL,
               let coverData = try? Data(contentsOf: coverURL) {
                return (
                    coverData,
                    safeMediaExtension(coverURL.pathExtension, fallback: "png"),
                    "hoshi_cover"
                )
            }
            return nil
        }()
        if !pictureFields.isEmpty, let pictureSource {
            let processedCover = AnkiMediaProcessor.image(
                data: pictureSource.data,
                sourceExtension: pictureSource.fileExtension,
                compress: configuration.compressImages,
                format: configuration.imageCompressionFormat,
                quality: configuration.imageCompressionQuality
            )
            let filename = "\(pictureSource.filenamePrefix)_\(processedCover.data.sha1).\(processedCover.fileExtension)"
            if let directMediaDirectory,
               let directFilename = try? writeDirectMedia(
                data: processedCover.data,
                filename: filename,
                mediaDirectory: directMediaDirectory
               ) {
                setDirectMediaFields(
                    pictureFields,
                    markup: directImageMarkup(filename: directFilename),
                    fields: &fields
                )
            } else {
                note["picture"] = [[
                    "data": processedCover.data.base64EncodedString(),
                    "filename": filename,
                    "fields": pictureFields
                ]]
            }
        }
        if !videoScreenshotFields.isEmpty {
            if directMediaDirectory != nil,
               let filename = context.video?.screenshotFilename {
                setDirectMediaFields(
                    videoScreenshotFields,
                    markup: directImageMarkup(filename: filename),
                    fields: &fields
                )
            } else if let screenshotURL = context.video?.screenshotURL,
                      let screenshotData = try? Data(contentsOf: screenshotURL) {
                var pictures = note["picture"] as? [[String: Any]] ?? []
                let ext = safeMediaExtension(screenshotURL.pathExtension, fallback: "png")
                pictures.append([
                    "data": screenshotData.base64EncodedString(),
                    "filename": "hoshi_video_frame_\(screenshotData.sha1).\(ext)",
                    "fields": videoScreenshotFields
                ])
                note["picture"] = pictures
            }
        }
        
        if let dictionaryMedia {
            for media in dictionaryMedia {
                let mediaData = LookupEngine.shared.getMediaFile(dictName: media.dictionary, mediaPath: media.path)
                let ext = safeMediaExtension(
                    URL(fileURLWithPath: media.path).pathExtension,
                    fallback: "bin"
                )
                let filename = "hoshi_dict_\(mediaData.sha1).\(ext)"
                if let directMediaDirectory,
                   let directFilename = try? writeDirectMedia(
                    data: mediaData,
                    filename: filename,
                    mediaDirectory: directMediaDirectory
                   ) {
                    fields = fields.mapValues {
                        $0.replacingOccurrences(of: media.filename, with: directFilename)
                    }
                } else {
                    fields = fields.mapValues {
                        $0.replacingOccurrences(of: media.filename, with: filename)
                    }
                    _ = try? await ankiConnectRequest(action: "storeMediaFile", params: [
                        "filename": filename,
                        "data": mediaData.base64EncodedString()
                    ])
                }
            }
        }
        note["fields"] = fields
        
        let tagList = configuration.tags.split(separator: " ").map(String.init)
        if !tagList.isEmpty {
            note["tags"] = tagList
        }
        
        do {
            let result = try await ankiConnectRequest(action: "addNote", params: ["note": note])
            guard let noteID = (result as? NSNumber)?.int64Value, noteID > 0 else {
                errorMessage = String(localized: "AnkiConnect did not return the added note ID.")
                return nil
            }
            addWord(content["expression"] ?? "")
            LocalFileServer.shared.clearMedia()
            
            if ankiConnectConfig?.forceSync == true {
                await syncAnkiConnect()
            }
            return noteID
        } catch {
            isAnkiConnectReachable = false
            scheduleAnkiConnectReconnect()
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func openNoteInAnki(_ noteID: Int64) async -> Bool {
        await openNotesInAnki([noteID])
    }

    func openNotesInAnki(_ noteIDs: [Int64]) async -> Bool {
        var seen = Set<Int64>()
        let validNoteIDs = noteIDs.filter { $0 > 0 && seen.insert($0).inserted }
        guard !validNoteIDs.isEmpty else { return false }

        do {
            let query = "nid:\(validNoteIDs.map(String.init).joined(separator: ","))"
            await activateAnkiApplication()
            _ = try await ankiConnectRequest(
                action: "guiBrowse",
                params: ["query": query]
            )

            isAnkiConnectReachable = true
            return true
        } catch {
            isAnkiConnectReachable = false
            scheduleAnkiConnectReconnect()
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func activateAnkiApplication() async {
        guard let application = Self.ankiBundleIdentifiers.lazy.compactMap({ bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        }).first else {
            return
        }

        _ = application.unhide()
        NSApp.yieldActivation(to: application)
        _ = application.activate()

        for _ in 0..<Self.ankiActivationPollAttempts where !application.isActive {
            try? await Task.sleep(for: Self.ankiActivationPollDelay)
        }
    }
    
    func duplicateLookup(word: String) async -> AnkiDuplicateLookupResult {
        let savedWordFallback = AnkiDuplicateLookupResult(
            isDuplicate: savedWords.contains(word),
            noteIDs: []
        )
        guard let noteTypeName = selectedNoteType,
              let noteType = availableNoteTypes.first(where: { $0.name == selectedNoteType }),
              let firstField = noteType.fields.first,
              let deck = selectedDeck else {
            return savedWordFallback
        }
        
        var options: [String: Any] = [:]
        if ankiConnectConfig?.duplicateScope == .collection {
            options["duplicateScope"] = "collection"
        } else {
            options["duplicateScope"] = "deck"
            if ankiConnectConfig?.duplicateScope == .deckroot {
                let rootDeck = deck.split(separator: "::", maxSplits: 1).first.map(String.init) ?? deck
                options["duplicateScopeOptions"] = [
                    "deckName": rootDeck,
                    "checkChildren": true
                ]
            }
        }
        if ankiConnectConfig?.checkAllModels == true {
            var duplicateScopeOptions = options["duplicateScopeOptions"] as? [String: Any] ?? [:]
            duplicateScopeOptions["checkAllModels"] = true
            options["duplicateScopeOptions"] = duplicateScopeOptions
        }
        let note: [String: Any] = [
            "deckName": deck,
            "modelName": noteTypeName,
            "fields": [firstField: word],
            "options": options
        ]
        let duplicateQuery = duplicateSearchQuery(
            word: word,
            deck: deck,
            noteTypeName: noteTypeName,
            firstField: firstField
        )
        
        do {
            let result = try await ankiConnectRequest(action: "canAddNotesWithErrorDetail", params: ["notes": [note]])
            if let results = result as? [[String: Any]],
               let first = results.first,
               let canAdd = first["canAdd"] as? Bool {
                guard !canAdd else {
                    return AnkiDuplicateLookupResult(isDuplicate: false, noteIDs: [])
                }

                savedWords.insert(word)
                let noteIDs = try await duplicateNoteIDs(matching: duplicateQuery)
                return AnkiDuplicateLookupResult(isDuplicate: true, noteIDs: noteIDs)
            }
        } catch {
            isAnkiConnectReachable = false
            scheduleAnkiConnectReconnect()
        }
        
        return AnkiDuplicateLookupResult(isDuplicate: savedWords.contains(word), noteIDs: [])
    }

    func checkDuplicate(word: String) async -> Bool {
        await duplicateLookup(word: word).isDuplicate
    }

    private func duplicateSearchQuery(
        word: String,
        deck: String,
        noteTypeName: String,
        firstField: String
    ) -> String {
        var terms: [String] = []

        switch ankiConnectConfig?.duplicateScope ?? .collection {
        case .collection:
            break
        case .deck:
            terms.append(quotedAnkiSearchTerm("deck:\(deck)"))
        case .deckroot:
            let rootDeck = deck.split(separator: "::", maxSplits: 1).first.map(String.init) ?? deck
            terms.append(quotedAnkiSearchTerm("deck:\(rootDeck)"))
        }

        let checkAllModels = ankiConnectConfig?.checkAllModels == true
        if !checkAllModels {
            terms.append(quotedAnkiSearchTerm("note:\(noteTypeName)"))
        }

        var seenFields = Set<String>()
        let firstFields = (checkAllModels ? availableNoteTypes.compactMap(\.fields.first) : [firstField])
            .filter { seenFields.insert($0.lowercased()).inserted }
        let fieldTerms = firstFields.map {
            quotedAnkiSearchTerm("\($0.lowercased()):\(word)")
        }
        if fieldTerms.count == 1, let fieldTerm = fieldTerms.first {
            terms.append(fieldTerm)
        } else if !fieldTerms.isEmpty {
            terms.append("(\(fieldTerms.joined(separator: " or ")))")
        }

        return terms.joined(separator: " ")
    }

    private func quotedAnkiSearchTerm(_ term: String) -> String {
        // Match Yomitan's Anki query escaping: quote the complete term and
        // remove embedded quote characters that would break Anki's parser.
        "\"\(term.replacingOccurrences(of: "\"", with: ""))\""
    }

    private func duplicateNoteIDs(matching query: String) async throws -> [Int64] {
        let result = try await ankiConnectRequest(
            action: "findNotes",
            params: ["query": query]
        )
        guard let values = result as? [Any] else { return [] }

        var seen = Set<Int64>()
        return values.compactMap { value in
            let noteID: Int64?
            if let number = value as? NSNumber {
                noteID = number.int64Value
            } else if let string = value as? String {
                noteID = Int64(string)
            } else {
                noteID = nil
            }
            guard let noteID, noteID > 0, seen.insert(noteID).inserted else { return nil }
            return noteID
        }
    }
    
    func syncAnkiConnect() async  {
        do {
            _ = try await ankiConnectRequest(action: "sync")
        } catch {}
    }
    
    func updateHandlebar(old: String, new: String) {
        guard old != new else { return }
        fieldMappings = fieldMappings.mapValues {
            $0.replacingOccurrences(of: "\(Handlebars.singleGlossaryPrefix)\(old)}", with: "\(Handlebars.singleGlossaryPrefix)\(new)}")
        }
        
        save()
    }
    
    func save() {
        let profileData = AnkiProfileConfig(
            selectedDeck: selectedDeck,
            selectedNoteType: selectedNoteType,
            allowDupes: allowDupes,
            compactGlossaries: compactGlossaries,
            embedMedia: embedMedia,
            fieldMappings: fieldMappings,
            tags: tags,
            duplicateScope: ankiConnectConfig?.duplicateScope ?? .collection,
            checkAllModels: ankiConnectConfig?.checkAllModels ?? false,
            compressVideoScreenshots: nil,
            compressImages: compressImages,
            imageCompressionQuality: imageCompressionQuality,
            imageCompressionFormat: imageCompressionFormat,
            animatedAVIFMaximumHeight: animatedAVIFMaximumHeight,
            animatedAVIFFramesPerSecond: animatedAVIFFramesPerSecond,
            audioCompressionFormat: audioCompressionFormat,
            audioCompressionBitrateKbps: audioCompressionBitrateKbps
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let encoded = try? encoder.encode(profileData) else { return }
        let profileURL = ProfileRepository.shared.ankiConfigURL(for: activeProfileID)
        try? FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? encoded.write(to: profileURL, options: .atomic)
        guard let legacyURL = try? BookStorage.getAppDirectory().appendingPathComponent(Self.ankiConfig) else {
            return
        }

        let legacy: AnkiConfig
        if activeProfileID == ProfileRepository.shared.index.defaultProfileId {
            legacy = makeLegacyConfig(from: profileData)
        } else if let existingData = try? Data(contentsOf: legacyURL),
                  let existing = try? JSONDecoder().decode(AnkiConfig.self, from: existingData) {
            legacy = existing.updatingSharedState(
                availableDecks: availableDecks,
                availableNoteTypes: availableNoteTypes,
                ankiConnectConfig: ankiConnectConfig
            )
        } else {
            let defaultURL = ProfileRepository.shared.ankiConfigURL(
                for: ProfileRepository.shared.index.defaultProfileId
            )
            let defaultProfile = (try? Data(contentsOf: defaultURL))
                .flatMap { try? JSONDecoder().decode(AnkiProfileConfig.self, from: $0) }
            legacy = makeLegacyConfig(from: defaultProfile ?? profileData)
        }

        if let legacyEncoded = try? encoder.encode(legacy) {
            try? legacyEncoded.write(to: legacyURL, options: .atomic)
        }
    }

    private func makeLegacyConfig(from profile: AnkiProfileConfig) -> AnkiConfig {
        AnkiConfig(
            selectedDeck: profile.selectedDeck,
            selectedNoteType: profile.selectedNoteType,
            allowDupes: profile.allowDupes,
            compactGlossaries: profile.compactGlossaries,
            embedMedia: profile.embedMedia,
            fieldMappings: profile.fieldMappings,
            tags: profile.tags,
            availableDecks: availableDecks,
            availableNoteTypes: availableNoteTypes,
            useAnkiConnect: useAnkiConnect,
            ankiConnectConfig: ankiConnectConfig,
            compressVideoScreenshots: nil,
            compressImages: profile.effectiveCompressImages,
            imageCompressionQuality: profile.effectiveImageCompressionQuality,
            imageCompressionFormat: profile.effectiveImageCompressionFormat,
            animatedAVIFMaximumHeight: profile.effectiveAnimatedAVIFMaximumHeight,
            animatedAVIFFramesPerSecond: profile.effectiveAnimatedAVIFFramesPerSecond,
            audioCompressionFormat: profile.effectiveAudioCompressionFormat,
            audioCompressionBitrateKbps: profile.effectiveAudioCompressionBitrateKbps
        )
    }
    
    /// First glossary, in dictionary order, from a term dictionary of the given category.
    private func categoryGlossary(
        _ category: DictionaryCategory,
        fallback: DictionaryCategory? = nil,
        singleGlossaries: [String: String]
    ) -> String {
        for dictionary in DictionaryManager.shared.termDictionaries where dictionary.category == category {
            if let glossary = singleGlossaries[dictionary.index.title], !glossary.isEmpty {
                return glossary
            }
        }
        guard let fallback else { return "" }
        return categoryGlossary(fallback, singleGlossaries: singleGlossaries)
    }

    private func handlebarToValue(handlebar: String, context: MiningContext, content: [String: String], singleGlossaries: [String: String]) -> String {
        if handlebar.hasPrefix(Handlebars.singleGlossaryPrefix) {
            let dictName = String(handlebar.dropFirst(Handlebars.singleGlossaryPrefix.count).dropLast())
            if dictName.hasSuffix("-brief") {
                let baseDictName = String(dictName.dropLast("-brief".count))
                return Self.stripGlossaryHeaders(singleGlossaries[baseDictName] ?? "")
            }
            if dictName.hasSuffix("-no-dictionary") {
                let baseDictName = String(dictName.dropLast("-no-dictionary".count))
                return Self.stripDictionaryName(singleGlossaries[baseDictName] ?? "")
            }
            return singleGlossaries[dictName] ?? ""
        } else if let standardHandlebar = Handlebars(rawValue: handlebar) {
            switch standardHandlebar {
            case .expression:
                return content["expression"] ?? ""
            case .reading:
                return content["reading"] ?? ""
            case .furiganaPlain:
                return content["furiganaPlain"] ?? ""
            case .glossary:
                return content["glossary"] ?? ""
            case .glossaryBrief:
                return Self.stripGlossaryHeaders(content["glossary"] ?? "")
            case .glossaryNoDictionary:
                return Self.stripDictionaryName(content["glossary"] ?? "")
            case .glossaryFirst:
                return content["glossaryFirst"] ?? ""
            case .glossaryFirstBrief:
                return Self.stripGlossaryHeaders(content["glossaryFirst"] ?? "")
            case .glossaryFirstNoDictionary:
                return Self.stripDictionaryName(content["glossaryFirst"] ?? "")
            case .selectedGlossary:
                return singleGlossaries[content["selectedDictionary"] ?? ""] ?? ""
            case .selectedGlossaryFallback:
                return singleGlossaries[content["selectedDictionary"] ?? ""] ?? content["glossaryFirst"] ?? ""
            case .selectedGlossaryBrief:
                return Self.stripGlossaryHeaders(singleGlossaries[content["selectedDictionary"] ?? ""] ?? "")
            case .selectedGlossaryBriefFallback:
                let selected = singleGlossaries[content["selectedDictionary"] ?? ""] ?? content["glossaryFirst"] ?? ""
                return Self.stripGlossaryHeaders(selected)
            case .selectedGlossaryNoDictionary:
                return Self.stripDictionaryName(singleGlossaries[content["selectedDictionary"] ?? ""] ?? "")
            case .selectedGlossaryNoDictionaryFallback:
                let selected = singleGlossaries[content["selectedDictionary"] ?? ""] ?? content["glossaryFirst"] ?? ""
                return Self.stripDictionaryName(selected)
            case .monolingualDefinition:
                return categoryGlossary(.monolingual, singleGlossaries: singleGlossaries)
            case .monolingualDefinitionBrief:
                return Self.stripGlossaryHeaders(categoryGlossary(.monolingual, singleGlossaries: singleGlossaries))
            case .monolingualDefinitionNoDictionary:
                return Self.stripDictionaryName(categoryGlossary(.monolingual, singleGlossaries: singleGlossaries))
            case .bilingualDefinition:
                return categoryGlossary(.bilingual, singleGlossaries: singleGlossaries)
            case .bilingualDefinitionBrief:
                return Self.stripGlossaryHeaders(categoryGlossary(.bilingual, singleGlossaries: singleGlossaries))
            case .bilingualDefinitionNoDictionary:
                return Self.stripDictionaryName(categoryGlossary(.bilingual, singleGlossaries: singleGlossaries))
            case .monolingualDefinitionFallback:
                return categoryGlossary(.monolingual, fallback: .bilingual, singleGlossaries: singleGlossaries)
            case .monolingualDefinitionFallbackBrief:
                return Self.stripGlossaryHeaders(categoryGlossary(.monolingual, fallback: .bilingual, singleGlossaries: singleGlossaries))
            case .monolingualDefinitionFallbackNoDictionary:
                return Self.stripDictionaryName(categoryGlossary(.monolingual, fallback: .bilingual, singleGlossaries: singleGlossaries))
            case .bilingualDefinitionFallback:
                return categoryGlossary(.bilingual, fallback: .monolingual, singleGlossaries: singleGlossaries)
            case .bilingualDefinitionFallbackBrief:
                return Self.stripGlossaryHeaders(categoryGlossary(.bilingual, fallback: .monolingual, singleGlossaries: singleGlossaries))
            case .bilingualDefinitionFallbackNoDictionary:
                return Self.stripDictionaryName(categoryGlossary(.bilingual, fallback: .monolingual, singleGlossaries: singleGlossaries))
            case .frequencies:
                return content["frequenciesHtml"] ?? ""
            case .frequencyHarmonicRank:
                return content["freqHarmonicRank"] ?? ""
            case .pitchPositions:
                return content["pitchPositions"] ?? ""
            case .pitchCategories:
                return content["pitchCategories"] ?? ""
            case .phoneticTranscriptions:
                return content["phoneticTranscriptions"] ?? ""
            case .sentence:
                guard let matched = content["matched"] else { return context.sentence }
                return context.sentence.replacingOccurrences(of: matched, with: "<b>\(matched)</b>")
            case .documentTitle:
                return context.documentTitle ?? ""
            case .popupSelectionText:
                return content["popupSelectionText"] ?? ""
            case .bookCover:
                if let video = context.video {
                    return video.value(for: .videoScreenshot)
                }
                var coverPath: String?
                if let coverURL = context.coverURL {
                    try? LocalFileServer.shared.setCover(file: coverURL)
                    coverPath = "http://localhost:\(LocalFileServer.port)/cover/cover.\(coverURL.pathExtension)"
                }
                return coverPath ?? ""
            case .audio:
                return content["audio"] ?? ""
            case .sasayakiAudio:
                if let video = context.video {
                    return video.value(for: .videoAudioClip)
                }
                guard let data = context.sasayakiAudioData else { return "" }
                LocalFileServer.shared.setSasayakiAudio(data)
                return "http://localhost:\(LocalFileServer.port)/sasayaki/audio.m4a"
            case .videoFileName, .videoTimestamp, .videoCueStart, .videoCueEnd,
                 .videoSubtitle, .videoPreviousSubtitle, .videoNextSubtitle,
                 .videoScreenshot, .videoAudioClip:
                return context.video?.value(for: standardHandlebar) ?? ""
            }
        }
        return ""
    }

    private static func stripGlossaryHeaders(_ html: String) -> String {
        html.replacing(#/(<li data-dictionary="[^"]*">)<i>[^<]*</i> /#) { $0.output.1 }
    }

    private static func stripDictionaryName(_ html: String) -> String {
        html.replacing(#/<li data-dictionary="(?<dict>[^"]+)"><i>(?<label>[^<]*)</i> /#) { match in
            let dict = String(match.dict)
            let label = String(match.label)
            let stripped = label.replacingOccurrences(of: ", \(dict))", with: ")")
            if stripped == "(\(dict))" {
                return "<li data-dictionary=\"\(dict)\">"
            }
            return "<li data-dictionary=\"\(dict)\"><i>\(stripped)</i> "
        }
    }
    
    private func loadProfile() {
        let url = ProfileRepository.shared.ankiConfigURL(for: activeProfileID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              let data = try? Data(contentsOf: url) else {
            selectedDeck = nil
            selectedNoteType = nil
            allowDupes = false
            compactGlossaries = false
            embedMedia = false
            compressImages = true
            imageCompressionQuality = 0.80
            imageCompressionFormat = .jpeg
            animatedAVIFMaximumHeight = AnkiAnimatedAVIFConfiguration.defaultMaximumHeight
            animatedAVIFFramesPerSecond = AnkiAnimatedAVIFConfiguration.defaultFramesPerSecond
            audioCompressionFormat = .aac
            audioCompressionBitrateKbps = 64
            fieldMappings = [:]
            tags = ""
            ankiConnectConfig?.duplicateScope = .collection
            ankiConnectConfig?.checkAllModels = false
            return
        }

        let decoder = JSONDecoder()
        if let profile = try? decoder.decode(AnkiProfileConfig.self, from: data) {
            apply(profile)
            return
        }
        if let legacy = try? decoder.decode(AnkiConfig.self, from: data) {
            selectedDeck = legacy.selectedDeck
            selectedNoteType = legacy.selectedNoteType
            allowDupes = legacy.allowDupes
            compactGlossaries = legacy.compactGlossaries ?? false
            embedMedia = legacy.embedMedia ?? false
            compressImages = legacy.effectiveCompressImages
            imageCompressionQuality = legacy.effectiveImageCompressionQuality
            imageCompressionFormat = legacy.effectiveImageCompressionFormat
            animatedAVIFMaximumHeight = legacy.effectiveAnimatedAVIFMaximumHeight
            animatedAVIFFramesPerSecond = legacy.effectiveAnimatedAVIFFramesPerSecond
            audioCompressionFormat = legacy.effectiveAudioCompressionFormat
            audioCompressionBitrateKbps = legacy.effectiveAudioCompressionBitrateKbps
            fieldMappings = legacy.fieldMappings
            tags = legacy.tags ?? ""
            if availableDecks.isEmpty { availableDecks = legacy.availableDecks }
            if availableNoteTypes.isEmpty { availableNoteTypes = legacy.availableNoteTypes }
            ankiConnectConfig?.duplicateScope = legacy.ankiConnectConfig?.duplicateScope ?? .collection
            ankiConnectConfig?.checkAllModels = legacy.ankiConnectConfig?.checkAllModels ?? false
            save()
            return
        }

        selectedDeck = nil
        selectedNoteType = nil
        allowDupes = false
        compactGlossaries = false
        embedMedia = false
        compressImages = true
        imageCompressionQuality = 0.80
        imageCompressionFormat = .jpeg
        animatedAVIFMaximumHeight = AnkiAnimatedAVIFConfiguration.defaultMaximumHeight
        animatedAVIFFramesPerSecond = AnkiAnimatedAVIFConfiguration.defaultFramesPerSecond
        audioCompressionFormat = .aac
        audioCompressionBitrateKbps = 64
        fieldMappings = [:]
        tags = ""
        ankiConnectConfig?.duplicateScope = .collection
        ankiConnectConfig?.checkAllModels = false
    }

    private func apply(_ profile: AnkiProfileConfig) {
        selectedDeck = profile.selectedDeck
        selectedNoteType = profile.selectedNoteType
        allowDupes = profile.allowDupes
        compactGlossaries = profile.compactGlossaries
        embedMedia = profile.embedMedia
        compressImages = profile.effectiveCompressImages
        imageCompressionQuality = profile.effectiveImageCompressionQuality
        imageCompressionFormat = profile.effectiveImageCompressionFormat
        animatedAVIFMaximumHeight = profile.effectiveAnimatedAVIFMaximumHeight
        animatedAVIFFramesPerSecond = profile.effectiveAnimatedAVIFFramesPerSecond
        audioCompressionFormat = profile.effectiveAudioCompressionFormat
        audioCompressionBitrateKbps = profile.effectiveAudioCompressionBitrateKbps
        fieldMappings = profile.fieldMappings
        tags = profile.tags
        ankiConnectConfig?.duplicateScope = profile.duplicateScope
        ankiConnectConfig?.checkAllModels = profile.checkAllModels
    }

    private func loadTransport() {
        guard let directory = try? BookStorage.getAppDirectory() else { return }
        let url = directory.appendingPathComponent(Self.ankiConfig)
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AnkiConfig.self, from: data) else { return }
        availableDecks = config.availableDecks
        availableNoteTypes = config.availableNoteTypes
        if let stored = config.ankiConnectConfig {
            ankiConnectConfig = AnkiConnectConfig(
                url: stored.url,
                timeout: stored.timeout,
                duplicateScope: .collection,
                checkAllModels: false,
                forceSync: stored.forceSync
            )
        }
    }
    
    func importAnkiBackup(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        try FileManager.default.unzipItem(at: url, to: tempDir)
        
        let collection = try Data(contentsOf: tempDir.appendingPathComponent("collection.anki21b"))
        let sqliteData = try Self.decompressZstd(collection)
        
        let dbFile = tempDir.appendingPathComponent("collection.db")
        try sqliteData.write(to: dbFile)
        
        savedWords = try Self.extractExpressionField(from: dbFile)
        try Self.saveWords(savedWords)
    }
    
    private func loadWords() {
        guard let url = try? BookStorage.getAppDirectory().appendingPathComponent(AnkiManager.ankiWords),
              let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return
        }
        savedWords = words
    }
    
    func addWord(_ word: String) {
        savedWords.insert(word)
        try? Self.saveWords(savedWords)
    }
    
    private static func saveWords(_ words: Set<String>) throws {
        let file = try BookStorage.getAppDirectory().appendingPathComponent(ankiWords)
        try JSONEncoder().encode(words).write(to: file)
    }
    
    private static func decompressZstd(_ data: Data) throws -> Data {
        let dctx = ZSTD_createDCtx()!
        defer { ZSTD_freeDCtx(dctx) }
        
        var result = Data()
        let blockSize = ZSTD_DStreamOutSize()
        
        try data.withUnsafeBytes { src in
            var input = ZSTD_inBuffer(src: src.baseAddress, size: src.count, pos: 0)
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: blockSize)
            defer { dst.deallocate() }
            
            while input.pos < input.size {
                var outBuf = ZSTD_outBuffer(dst: dst, size: blockSize, pos: 0)
                let ret = ZSTD_decompressStream(dctx, &outBuf, &input)
                guard ZSTD_isError(ret) == 0 else {
                    throw ColpkgError.zstd
                }
                result.append(dst, count: outBuf.pos)
            }
        }
        return result
    }
    
    private static func extractExpressionField(from url: URL) throws -> Set<String> {
        var db: OpaquePointer?
        sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE, nil)
        sqlite3_exec(db, "PRAGMA journal_mode=OFF", nil, nil, nil)
        defer { sqlite3_close(db) }
        
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT flds FROM notes", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        
        var words = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let row = sqlite3_column_text(stmt, 0) else {
                continue
            }
            let word = String(cString: row).prefix(while: { $0 != "\u{1f}" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                words.insert(word)
            }
        }
        return words
    }
    
    private func ankiConnectRequest(action: String, params: [String: Any]? = nil) async throws -> Any? {
        guard let urlString = ankiConnectConfig?.url,
              let url = URL(string: urlString) else {
            throw AnkiConnectError.invalidUrl
        }
        
        var body: [String: Any] = ["action": action, "version": 6]
        if let params {
            body["params"] = params
        }
        if let apiKey = ankiConnectConfig?.apiKey, !apiKey.isEmpty {
            body["key"] = apiKey
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        
        if let error = json["error"] as? String {
            throw AnkiConnectError.ankiconnectError(error)
        }
        
        return json["result"]
    }
    
    private func mimeType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
    
    enum AnkiConnectError: LocalizedError {
        case invalidUrl
        case ankiconnectError(String)
        
        var errorDescription: String? {
            switch self {
            case .invalidUrl: String(localized: "Invalid URL specified")
            case .ankiconnectError(let error): error
            }
        }
    }
    
    enum ColpkgError: LocalizedError {
        case zstd
        
        var errorDescription: String? {
            switch self {
            case .zstd: String(localized: "Failed to decompress database")
            }
        }
    }
}
