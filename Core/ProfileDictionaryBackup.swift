//
//  ProfileDictionaryBackup.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum ProfileDictionaryBackupError: LocalizedError {
    case missingDictionaryPayload
    case invalidProfileIndex
    case unsafeArchiveEntry

    var errorDescription: String? {
        switch self {
        case .missingDictionaryPayload:
            String(localized: "The backup does not contain a dictionary collection.")
        case .invalidProfileIndex:
            String(localized: "The backup contains an invalid Profile index.")
        case .unsafeArchiveEntry:
            String(localized: "The backup contains an unsafe file entry.")
        }
    }
}

struct ProfileDictionaryBackup {
    static let metadataDirectoryName = ".hoshi-profiles"
    static let profileDictionaryFiles = [
        "dictionary_config.json",
        "dictionary_settings.json",
        "collapsed.json"
    ]

    let appDirectory: URL
    let repository: ProfileRepository
    private let fileManager: FileManager

    init(
        appDirectory: URL,
        repository: ProfileRepository,
        fileManager: FileManager = .default
    ) {
        self.appDirectory = appDirectory
        self.repository = repository
        self.fileManager = fileManager
    }

    func makeStagingDirectory(at destination: URL) throws {
        let dictionaryRoot = appDirectory.appendingPathComponent("Dictionaries", isDirectory: true)
        guard fileManager.fileExists(atPath: dictionaryRoot.path) else {
            throw ProfileDictionaryBackupError.missingDictionaryPayload
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try copyDirectoryContents(from: dictionaryRoot, to: destination, excluding: [Self.metadataDirectoryName])

        let defaultID = repository.index.defaultProfileId
        projectIfPresent(
            repository.dictionaryConfigURL(for: defaultID),
            to: destination.appendingPathComponent("config.json")
        )
        projectIfPresent(
            repository.collapsedDictionariesURL(for: defaultID),
            to: destination.appendingPathComponent("collapsed.json")
        )

        let metadata = destination.appendingPathComponent(Self.metadataDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: metadata, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(repository.index).write(
            to: metadata.appendingPathComponent(ProfileRepository.indexFileName),
            options: .atomic
        )

        for profile in repository.index.profiles {
            let outputDirectory = metadata.appendingPathComponent(profile.id, isDirectory: true)
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            for fileName in Self.profileDictionaryFiles {
                let source = try repository.profileDirectory(for: profile.id).appendingPathComponent(fileName)
                projectIfPresent(source, to: outputDirectory.appendingPathComponent(fileName))
            }
        }
    }

    func restoreExtractedDirectory(_ extractedDirectory: URL) throws {
        let payload = try resolvedPayloadRoot(in: extractedDirectory)
        try validateTree(payload)
        let importedIndex = try loadProfileIndex(from: payload)

        let dictionaryRoot = appDirectory.appendingPathComponent("Dictionaries", isDirectory: true)
        let replacement = appDirectory.appendingPathComponent(".Dictionaries.restore-\(UUID().uuidString)", isDirectory: true)
        let previous = appDirectory.appendingPathComponent(".Dictionaries.previous-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: replacement)
            try? fileManager.removeItem(at: previous)
        }

        try fileManager.createDirectory(at: replacement, withIntermediateDirectories: true)
        try copyDirectoryContents(from: payload, to: replacement, excluding: [Self.metadataDirectoryName])
        try validateDictionaryCollection(replacement)

        if fileManager.fileExists(atPath: dictionaryRoot.path) {
            try fileManager.moveItem(at: dictionaryRoot, to: previous)
        }
        do {
            try fileManager.moveItem(at: replacement, to: dictionaryRoot)
        } catch {
            if fileManager.fileExists(atPath: previous.path) {
                try? fileManager.moveItem(at: previous, to: dictionaryRoot)
            }
            throw error
        }

        do {
            if let importedIndex {
                let profileSource = payload.appendingPathComponent(Self.metadataDirectoryName, isDirectory: true)
                try repository.mergeDictionaryBackup(
                    index: importedIndex,
                    profilesSourceDirectory: profileSource
                )
            } else {
                try restoreLegacyProjection(from: dictionaryRoot)
            }
            try? fileManager.removeItem(at: previous)
        } catch {
            try? fileManager.removeItem(at: dictionaryRoot)
            if fileManager.fileExists(atPath: previous.path) {
                try? fileManager.moveItem(at: previous, to: dictionaryRoot)
            }
            throw error
        }
    }

    private func loadProfileIndex(from payload: URL) throws -> ProfileIndex? {
        let indexURL = payload
            .appendingPathComponent(Self.metadataDirectoryName, isDirectory: true)
            .appendingPathComponent(ProfileRepository.indexFileName)
        guard fileManager.fileExists(atPath: indexURL.path) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(ProfileIndex.self, from: Data(contentsOf: indexURL))
            guard decoded.profiles.allSatisfy({ ProfileRepository.isSafeProfileID($0.id) }) else {
                throw ProfileDictionaryBackupError.invalidProfileIndex
            }
            return decoded
        } catch let error as ProfileDictionaryBackupError {
            throw error
        } catch {
            throw ProfileDictionaryBackupError.invalidProfileIndex
        }
    }

    private func restoreLegacyProjection(from dictionaryRoot: URL) throws {
        let defaultID = repository.index.defaultProfileId
        for (fileName, destination) in [
            ("config.json", repository.dictionaryConfigURL(for: defaultID)),
            ("collapsed.json", repository.collapsedDictionariesURL(for: defaultID))
        ] {
            let source = dictionaryRoot.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private func resolvedPayloadRoot(in extractedDirectory: URL) throws -> URL {
        let contents = try fileManager.contentsOfDirectory(
            at: extractedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if contents.contains(where: { ["Term", "Frequency", "Pitch", "Kanji", "config.json"].contains($0.lastPathComponent) })
            || fileManager.fileExists(atPath: extractedDirectory.appendingPathComponent(Self.metadataDirectoryName).path) {
            return extractedDirectory
        }
        if contents.count == 1,
           (try contents[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return contents[0]
        }
        throw ProfileDictionaryBackupError.missingDictionaryPayload
    }

    private func validateTree(_ root: URL) throws {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { return }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ProfileDictionaryBackupError.unsafeArchiveEntry
            }
            let canonical = item.standardizedFileURL.path
            guard canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/") else {
                throw ProfileDictionaryBackupError.unsafeArchiveEntry
            }
        }
    }

    private func validateDictionaryCollection(_ root: URL) throws {
        for type in DictionaryType.allCasesForBackup {
            let directory = root.appendingPathComponent(type.rawValue, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let dictionaries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for dictionary in dictionaries {
                let values = try dictionary.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }
                let indexURL = dictionary.appendingPathComponent("index.json")
                guard let data = try? Data(contentsOf: indexURL),
                      (try? JSONDecoder().decode(DictionaryIndex.self, from: data)) != nil else {
                    throw ProfileDictionaryBackupError.missingDictionaryPayload
                }
            }
        }
        let config = root.appendingPathComponent("config.json")
        if fileManager.fileExists(atPath: config.path) {
            _ = try JSONDecoder().decode(DictionaryConfig.self, from: Data(contentsOf: config))
        }
    }

    private func projectIfPresent(_ source: URL, to destination: URL) {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try? fileManager.removeItem(at: destination)
        try? fileManager.copyItem(at: source, to: destination)
    }

    private func copyDirectoryContents(from source: URL, to destination: URL, excluding: Set<String>) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        ) where !excluding.contains(item.lastPathComponent) {
            let output = destination.appendingPathComponent(item.lastPathComponent)
            try? fileManager.removeItem(at: output)
            try fileManager.copyItem(at: item, to: output)
        }
    }
}

private extension DictionaryType {
    static let allCasesForBackup: [DictionaryType] = [.term, .frequency, .pitch, .kanji]
}
