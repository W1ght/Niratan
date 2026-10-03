import AidokuRuntime
import Foundation
import Security
import WebKit

actor AidokuGlobalStore {
    static let shared = AidokuGlobalStore()

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let catalogURL: URL
    private let sourcesDirectory: URL
    private let cacheDirectory: URL
    private let coverLoader: AidokuCoverLoader
    private let sourceIconLoader: AidokuSourceIconLoader
    private let keychain: AidokuKeychainStore
    private var catalog: AidokuGlobalCatalog
    private var runtimes: [String: AidokuSourceRuntime] = [:]

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        keychain: AidokuKeychainStore = .live
    ) {
        self.fileManager = fileManager
        let applicationSupport = rootDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Niratan", isDirectory: true)
                .appendingPathComponent("Aidoku", isDirectory: true)
        self.rootDirectory = applicationSupport
        catalogURL = applicationSupport.appendingPathComponent("catalog.json")
        sourcesDirectory = applicationSupport.appendingPathComponent("Sources", isDirectory: true)
        let cacheDirectory = applicationSupport.appendingPathComponent("Cache", isDirectory: true)
        self.cacheDirectory = cacheDirectory
        coverLoader = AidokuCoverLoader(cacheDirectory: cacheDirectory)
        sourceIconLoader = AidokuSourceIconLoader(cacheDirectory: cacheDirectory)
        self.keychain = keychain
        let catalogFileExists = fileManager.fileExists(atPath: catalogURL.path)
        let decodedCatalog: AidokuGlobalCatalog? = if let data = try? Data(contentsOf: catalogURL),
           data.count <= AidokuLimits.maximumJSONBytes,
           let decoded = try? JSONDecoder().decode(AidokuGlobalCatalog.self, from: data) {
            decoded
        } else {
            nil
        }
        catalog = decodedCatalog ?? AidokuGlobalCatalog()
        let maySeedBuiltInSources = decodedCatalog != nil || !catalogFileExists
        if maySeedBuiltInSources, catalog.seedBuiltInSourceLists() {
            try? fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(catalog).write(to: catalogURL, options: .atomic)
        }
    }

    func snapshot() -> AidokuGlobalCatalog { catalog }

    func availableSources(forceRefresh: Bool = false) async throws -> [AidokuAvailableSource] {
        var available: [AidokuAvailableSource] = []
        let now = Date()
        var didChange = false
        for index in catalog.sourceLists.indices {
            let record = catalog.sourceLists[index]
            let shouldRefresh = forceRefresh
                || record.lastCheckedAt == nil
                || now.timeIntervalSince(record.lastCheckedAt ?? .distantPast) >= 24 * 60 * 60
                || record.cachedSources == nil
            let list: AidokuSourceList
            if shouldRefresh {
                list = try await fetchSourceList(
                    url: record.url,
                    insecureTransportApproved: record.insecureTransportApproved
                )
                catalog.sourceLists[index].name = list.name
                catalog.sourceLists[index].lastCheckedAt = now
                catalog.sourceLists[index].cachedSources = list.sources
                didChange = true
            } else {
                list = AidokuSourceList(name: record.name, sources: record.cachedSources ?? [])
            }
            available.append(contentsOf: list.sources.map {
                AidokuAvailableSource(listID: record.id, listName: list.name, entry: $0)
            })
        }
        if didChange { try persist() }
        return available
    }

    func setAllowsAdultContent(_ value: Bool) throws {
        catalog.allowsAdultContent = value
        try persist()
    }

    func acknowledgeThirdPartyDisclosure() throws {
        catalog.didAcknowledgeThirdPartyDisclosure = true
        try persist()
    }

    func addSourceList(
        url: URL,
        insecureTransportApproved: Bool
    ) async throws -> AidokuSourceListRecord {
        try AidokuSourceListParser.validateRemoteURL(url, insecureTransportConfirmed: insecureTransportApproved)
        let list = try await fetchSourceList(url: url, insecureTransportApproved: insecureTransportApproved)
        let existingIndex = catalog.sourceLists.firstIndex { $0.url == url }
        let record = AidokuSourceListRecord(
            id: existingIndex.map { catalog.sourceLists[$0].id } ?? UUID(),
            name: list.name,
            url: url,
            insecureTransportApproved: insecureTransportApproved,
            lastCheckedAt: Date(),
            cachedSources: list.sources
        )
        if let existingIndex {
            catalog.sourceLists[existingIndex] = record
        } else {
            catalog.sourceLists.append(record)
        }
        try persist()
        return record
    }

    func removeSourceList(id: UUID) throws {
        guard catalog.sourceLists.first(where: { $0.id == id })?.isBuiltIn != true else { return }
        catalog.sourceLists.removeAll { $0.id == id }
        try persist()
    }

    func checkForUpdates(force: Bool = false) async throws {
        let now = Date()
        for index in catalog.sourceLists.indices {
            let record = catalog.sourceLists[index]
            if !force, let lastCheck = record.lastCheckedAt,
               now.timeIntervalSince(lastCheck) < 24 * 60 * 60 { continue }
            let list = try await fetchSourceList(
                url: record.url,
                insecureTransportApproved: record.insecureTransportApproved
            )
            catalog.sourceLists[index].name = list.name
            catalog.sourceLists[index].lastCheckedAt = now
            catalog.sourceLists[index].cachedSources = list.sources
            for entry in list.sources {
                guard let installedIndex = catalog.installedSources.firstIndex(where: { $0.sourceID == entry.id }),
                      entry.version > catalog.installedSources[installedIndex].version,
                      let value = entry.downloadURL,
                      let downloadURL = URL(string: value) else { continue }
                catalog.installedSources[installedIndex].pendingUpdateVersion = entry.version
                catalog.installedSources[installedIndex].pendingUpdateURL = downloadURL
            }
        }
        try persist()
    }

    func installLocalPackage(_ url: URL) async throws -> AidokuInstalledSourceRecord {
        try await installPackage(url, listID: nil, downloadURL: nil)
    }

    func installSource(
        _ entry: AidokuSourceList.Entry,
        from listID: UUID,
        insecureTransportApproved: Bool = false
    ) async throws -> AidokuInstalledSourceRecord {
        guard let value = entry.downloadURL, let url = URL(string: value) else {
            throw AidokuRuntimeError.unsupportedURL
        }
        let approved = insecureTransportApproved
            || catalog.sourceLists.first(where: { $0.id == listID })?.insecureTransportApproved == true
        try AidokuSourceListParser.validateRemoteURL(url, insecureTransportConfirmed: approved)
        let packageURL = try await downloadPackage(url: url, insecureTransportApproved: approved)
        defer { try? fileManager.removeItem(at: packageURL) }
        return try await installPackage(packageURL, listID: listID, downloadURL: url, expectedSourceID: entry.id)
    }

    func confirmUpdate(sourceID: String) async throws -> AidokuInstalledSourceRecord {
        guard let record = catalog.installedSources.first(where: { $0.sourceID == sourceID }),
              let url = record.pendingUpdateURL else { throw AidokuRuntimeError.sourceUnavailable }
        let approved = record.listID.flatMap { listID in
            catalog.sourceLists.first(where: { $0.id == listID })?.insecureTransportApproved
        } ?? false
        try AidokuSourceListParser.validateRemoteURL(
            url,
            insecureTransportConfirmed: approved
        )
        let packageURL = try await downloadPackage(url: url, insecureTransportApproved: approved)
        defer { try? fileManager.removeItem(at: packageURL) }
        return try await installPackage(packageURL, listID: record.listID, downloadURL: record.downloadURL, expectedSourceID: sourceID)
    }

    func uninstall(sourceID: String) async throws {
        let runtime = runtimes.removeValue(forKey: sourceID)
        if let runtime { await runtime.cancel() }
        try await AidokuPackageInstaller(rootDirectory: sourcesDirectory).uninstall(sourceID: sourceID)
        try? await coverLoader.removeSource(sourceID)
        try? await sourceIconLoader.invalidateSource(sourceID)
        catalog.installedSources.removeAll { $0.sourceID == sourceID }
        catalog.sourceDefaults[sourceID] = nil
        catalog.sourceDirectMediaConnections?[sourceID] = nil
        catalog.sourceLanguageSelections?[sourceID] = nil
        try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent(sourceID, isDirectory: true))
        try keychain.removeAll(sourceID)
        try persist()
    }

    func runtime(sourceID: String) async throws -> AidokuSourceRuntime {
        guard catalog.installedSources.contains(where: { $0.sourceID == sourceID }) else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        if let runtime = runtimes[sourceID] { return runtime }
        let initialWebsiteSession = storedWebsiteSession(sourceID: sourceID)
        let initialPersistedUserAgent = initialWebsiteSession?.userAgent.nilIfEmpty
            ?? keychain.read(sourceID, "user-agent")
                .flatMap { String(data: $0, encoding: .utf8) }?
                .nilIfEmpty
        let discoveredUserAgent = if let initialPersistedUserAgent {
            initialPersistedUserAgent
        } else {
            await AidokuWebUserAgentProvider.shared.userAgent()
        }

        guard catalog.installedSources.contains(where: { $0.sourceID == sourceID }) else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        if let runtime = runtimes[sourceID] { return runtime }
        // The WKWebView UA lookup yields the actor. A verification sheet may
        // persist a newer cookie/UA pair while it is suspended, so re-read the
        // atomic session before constructing the runtime.
        let websiteSession = storedWebsiteSession(sourceID: sourceID)
        let cookies = websiteSession?.cookies ?? legacyCookies(sourceID: sourceID)
        let userAgent = websiteSession?.userAgent.nilIfEmpty
            ?? keychain.read(sourceID, "user-agent")
                .flatMap { String(data: $0, encoding: .utf8) }?
                .nilIfEmpty
            ?? discoveredUserAgent
        let sourceManifest = try manifest(sourceID: sourceID)
        var defaults = mergedSourceDefaults(sourceID: sourceID)
        if let selection = resolvedLanguageSelection(
            manifest: sourceManifest,
            sourceID: sourceID
        ) {
            defaults["language"] = nil
            defaults["languages"] = nil
            defaults.merge(AidokuLanguageDefaults.encodedDefaults(
                type: selection.type,
                selectedLanguages: selection.selectedLanguages
            )) { _, languageDefault in languageDefault }
            if catalog.sourceLanguageSelections?[sourceID] != selection.selectedLanguages {
                var selections = catalog.sourceLanguageSelections ?? [:]
                selections[sourceID] = selection.selectedLanguages
                catalog.sourceLanguageSelections = selections
                try persist()
            }
        }
        let runtime = try AidokuSourceRuntime(configuration: .init(
            sourceDirectory: sourcesDirectory.appendingPathComponent(sourceID, isDirectory: true),
            defaults: defaults,
            cookies: cookies,
            userAgent: userAgent,
            defaultsWriter: { [weak self] values in
                Task { try? await self?.setRuntimeDefaults(values, sourceID: sourceID) }
            }
        ))
        runtimes[sourceID] = runtime
        return runtime
    }

    func coverData(
        sourceID: String,
        manga: AidokuManga
    ) async throws -> Data {
        guard let source = catalog.installedSources.first(where: { $0.sourceID == sourceID }) else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        let runtime = try await runtime(sourceID: sourceID)
        let maximumParallelRequests = (try? manifest(sourceID: sourceID))?
            .config?.resolvedMaximumParallelRequests ?? 5
        return try await coverLoader.data(
            sourceID: sourceID,
            sourceVersion: source.version,
            manga: manga,
            runtime: runtime,
            maximumParallelRequests: maximumParallelRequests,
            usesSystemProxy: catalog.sourceDirectMediaConnections?[sourceID] != true
        )
    }

    func installedSourceIconData(sourceID: String) async throws -> Data {
        guard let source = catalog.installedSources.first(where: { $0.sourceID == sourceID }) else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        let sourceDirectory = sourcesDirectory.appendingPathComponent(sourceID, isDirectory: true)
        do {
            return try await sourceIconLoader.data(
                sourceID: sourceID,
                sourceVersion: source.version,
                location: .installedSource(sourceDirectory)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch AidokuRuntimeError.cancelled {
            throw AidokuRuntimeError.cancelled
        } catch {
            guard let listID = source.listID,
                  let list = catalog.sourceLists.first(where: { $0.id == listID }),
                  let entry = list.cachedSources?.first(where: {
                      $0.id == sourceID && $0.version == source.version
                  }),
                  let value = entry.iconURL,
                  let iconURL = URL(string: value) else { throw error }
            return try await sourceIconLoader.data(
                sourceID: sourceID,
                sourceVersion: source.version,
                location: .remote(
                    iconURL,
                    insecureTransportApproved: list.insecureTransportApproved
                )
            )
        }
    }

    func availableSourceIconData(_ candidate: AidokuAvailableSource) async throws -> Data {
        guard let list = catalog.sourceLists.first(where: { $0.id == candidate.listID }),
              let entry = list.cachedSources?.first(where: {
                  $0.id == candidate.entry.id && $0.version == candidate.entry.version
              }),
              let value = entry.iconURL,
              let iconURL = URL(string: value) else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        return try await sourceIconLoader.data(
            sourceID: entry.id,
            sourceVersion: entry.version,
            location: .remote(
                iconURL,
                insecureTransportApproved: list.insecureTransportApproved
            )
        )
    }

    func setDirectMediaConnection(_ enabled: Bool, sourceID: String) async throws {
        guard catalog.installedSources.contains(where: { $0.sourceID == sourceID }) else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        var values = catalog.sourceDirectMediaConnections ?? [:]
        if enabled { values[sourceID] = true } else { values[sourceID] = nil }
        catalog.sourceDirectMediaConnections = values.isEmpty ? nil : values
        try? await coverLoader.invalidateSource(sourceID)
        try persist()
    }

    func languageSelection(sourceID: String) throws -> AidokuSourceLanguageSelection? {
        try resolvedLanguageSelection(
            manifest: manifest(sourceID: sourceID),
            sourceID: sourceID
        )
    }

    @discardableResult
    func setSelectedLanguages(
        _ languages: [String],
        sourceID: String
    ) async throws -> AidokuSourceLanguageSelection {
        try Task.checkCancellation()
        let sourceManifest = try manifest(sourceID: sourceID)
        guard let type = sourceManifest.resolvedLanguageSelectType else {
            throw AidokuRuntimeError.incompatibleSource("source does not declare multiple languages")
        }
        let supported = AidokuLanguageDefaults.supportedLanguages(
            sourceManifest.info.languages ?? []
        )
        let selected = AidokuLanguageDefaults.normalizedSelection(
            supportedLanguages: supported,
            selectedLanguages: languages,
            preferredLanguageIdentifiers: [],
            type: type
        )
        try Task.checkCancellation()
        var selections = catalog.sourceLanguageSelections ?? [:]
        selections[sourceID] = selected
        catalog.sourceLanguageSelections = selections
        try persist()

        let runtime = runtimes.removeValue(forKey: sourceID)
        if let runtime { await runtime.cancel() }
        try? await coverLoader.invalidateSource(sourceID)
        return AidokuSourceLanguageSelection(
            type: type,
            supportedLanguages: supported,
            selectedLanguages: selected
        )
    }

    func invalidateCaches(sourceID: String) async {
        try? await coverLoader.invalidateSource(sourceID)
    }

    func manifest(sourceID: String) throws -> AidokuSourceManifest {
        guard catalog.installedSources.contains(where: { $0.sourceID == sourceID }) else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        let url = sourcesDirectory
            .appendingPathComponent(sourceID, isDirectory: true)
            .appendingPathComponent("source.json")
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= AidokuLimits.maximumJSONBytes else {
            throw AidokuRuntimeError.responseTooLarge
        }
        return try JSONDecoder().decode(AidokuSourceManifest.self, from: data)
    }

    /// Authentication metadata is package data only. This deliberately does
    /// not inspect or materialize any stored credential.
    func requiresAuthentication(sourceID: String) -> Bool {
        (try? manifest(sourceID: sourceID).requiresAuth) ?? false
    }

    func addToLibrary(
        sourceID: String,
        sourceName: String,
        manga: AidokuManga,
        discoveryWorkID: String? = nil
    ) throws {
        catalog.library.removeAll { $0.sourceID == sourceID && $0.manga.key == manga.key }
        catalog.library.append(AidokuLibraryEntry(
            sourceID: sourceID,
            sourceName: sourceName,
            manga: manga,
            addedAt: Date(),
            updatedAt: Date(),
            discoveryWorkID: discoveryWorkID
        ))
        try persist()
    }

    func replaceDiscoveryLibraryEntry(
        workID: String,
        sourceID: String,
        sourceName: String,
        manga: AidokuManga
    ) throws {
        catalog.library.removeAll { $0.discoveryWorkID == workID }
        catalog.library.append(AidokuLibraryEntry(
            sourceID: sourceID,
            sourceName: sourceName,
            manga: manga,
            addedAt: Date(),
            updatedAt: Date(),
            discoveryWorkID: workID
        ))
        try persist()
    }

    func setDiscoveryMapping(
        workID: String,
        sourceID: String,
        manga: AidokuManga
    ) throws {
        var mappings = catalog.discoverySourceMappings ?? [:]
        mappings[workID] = AidokuDiscoverySourceMapping(
            sourceID: sourceID,
            manga: manga,
            updatedAt: Date()
        )
        catalog.discoverySourceMappings = mappings
        try persist()
    }

    func removeDiscoveryMapping(workID: String) throws {
        catalog.discoverySourceMappings?[workID] = nil
        if catalog.discoverySourceMappings?.isEmpty == true {
            catalog.discoverySourceMappings = nil
        }
        try persist()
    }

    func removeFromLibrary(sourceID: String, mangaKey: String) throws {
        catalog.library.removeAll { $0.sourceID == sourceID && $0.manga.key == mangaKey }
        try persist()
    }

    func updateProgress(_ progress: AidokuChapterProgress) throws {
        catalog.progress.removeAll { $0.id == progress.id }
        catalog.progress.append(progress)
        try persist()
    }

    func saveSecret(_ value: Data, sourceID: String, key: String) throws {
        try keychain.save(value, sourceID, key)
    }

    func storedCookies(sourceID: String) -> [AidokuStoredCookie] {
        storedWebsiteSession(sourceID: sourceID)?.cookies ?? legacyCookies(sourceID: sourceID)
    }

    func resolvedWebsiteUserAgent(sourceID: String) async throws -> String {
        guard catalog.installedSources.contains(where: { $0.sourceID == sourceID }) else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        if let manifestUserAgent = try manifest(sourceID: sourceID)
            .config?.userAgent?.nilIfEmpty {
            return manifestUserAgent
        }
        let legacyUserAgent = keychain.read(sourceID, "user-agent").flatMap {
            String(data: $0, encoding: .utf8)?.nilIfEmpty
        }
        if let persistedUserAgent = storedWebsiteSession(sourceID: sourceID)?
            .userAgent.nilIfEmpty ?? legacyUserAgent {
            return persistedUserAgent
        }

        let discoveredUserAgent = await AidokuWebUserAgentProvider.shared.userAgent()
        guard catalog.installedSources.contains(where: { $0.sourceID == sourceID }) else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        // Package/session state may change while the WKWebView lookup yields.
        if let manifestUserAgent = try manifest(sourceID: sourceID)
            .config?.userAgent?.nilIfEmpty {
            return manifestUserAgent
        }
        let refreshedLegacyUserAgent = keychain.read(sourceID, "user-agent").flatMap {
            String(data: $0, encoding: .utf8)?.nilIfEmpty
        }
        return storedWebsiteSession(sourceID: sourceID)?.userAgent.nilIfEmpty
            ?? refreshedLegacyUserAgent
            ?? discoveredUserAgent
    }

    func saveWebsiteSession(
        cookies: [AidokuStoredCookie],
        userAgent: String,
        sourceID: String
    ) async throws {
        try Task.checkCancellation()
        let session = try encodedWebsiteSession(
            cookies: cookies,
            userAgent: userAgent,
            sourceID: sourceID
        )
        // This is the actor-serialized commit boundary. Callers may cancel up
        // to this point; after the write the paired cookie/UA session is valid.
        try Task.checkCancellation()
        try keychain.save(
            session,
            sourceID,
            AidokuWebsiteSession.keychainKey
        )
        await invalidateWebsiteSessionRuntime(sourceID: sourceID)
    }

    private func encodedWebsiteSession(
        cookies: [AidokuStoredCookie],
        userAgent: String,
        sourceID: String
    ) throws -> Data {
        guard catalog.installedSources.contains(where: { $0.sourceID == sourceID }) else {
            throw AidokuRuntimeError.sourceUnavailable
        }
        let userAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userAgent.isEmpty else {
            throw AidokuRuntimeError.runtimeFailure(
                String(localized: "Niratan could not determine the website user agent.")
            )
        }
        let existing = storedWebsiteSession(sourceID: sourceID)?.cookies
            ?? legacyCookies(sourceID: sourceID)
        return try JSONEncoder().encode(AidokuWebsiteSession(
            cookies: AidokuWebsiteSessionCookieMerger.merge(
                existing: existing,
                incoming: cookies
            ),
            userAgent: userAgent
        ))
    }

    private func invalidateWebsiteSessionRuntime(sourceID: String) async {
        let runtime = runtimes.removeValue(forKey: sourceID)
        if let runtime { await runtime.cancel() }
        try? await coverLoader.invalidateSource(sourceID)
    }

    func secret(sourceID: String, key: String) -> Data? {
        keychain.read(sourceID, key)
    }

    func sourceValue(sourceID: String, key: String) -> Data? {
        if let encoded = keychain.read(sourceID, "sensitive-settings"),
           let settings = try? JSONDecoder().decode([String: Data].self, from: encoded),
           let value = settings[key] { return value }
        if let value = catalog.sourceDefaults[sourceID]?[key] { return value }
        if let encoded = keychain.read(sourceID, "runtime-defaults"),
           let settings = try? JSONDecoder().decode([String: Data].self, from: encoded) {
            return settings[key]
        }
        return nil
    }

    func setSourceValue(
        _ value: Data?,
        sourceID: String,
        key: String,
        sensitive: Bool
    ) async throws {
        if sensitive {
            let encoded = keychain.read(sourceID, "sensitive-settings")
            var settings = encoded.flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
            settings[key] = value
            try keychain.save(try JSONEncoder().encode(settings), sourceID, "sensitive-settings")
            catalog.sourceDefaults[sourceID]?[key] = nil
        } else {
            catalog.sourceDefaults[sourceID, default: [:]][key] = value
        }
        runtimes[sourceID] = nil
        try? await coverLoader.invalidateSource(sourceID)
        try persist()
    }

    private func setDefaults(_ values: [String: Data], sourceID: String) throws {
        catalog.sourceDefaults[sourceID] = values
        try persist()
    }

    private func setRuntimeDefaults(_ values: [String: Data], sourceID: String) throws {
        // Source-authored defaults have no reliable sensitivity annotation. Keep the
        // complete opaque payload in the Aidoku-specific Keychain service instead of
        // risking credentials or session tokens in Application Support.
        try keychain.save(try JSONEncoder().encode(values), sourceID, "runtime-defaults")
    }

    private func installPackage(
        _ url: URL,
        listID: UUID?,
        downloadURL: URL?,
        expectedSourceID: String? = nil
    ) async throws -> AidokuInstalledSourceRecord {
        let installer = AidokuPackageInstaller(rootDirectory: sourcesDirectory)
        let librarySnapshot = catalog.library
        let progressSnapshot = catalog.progress
        let discoveryMappingSnapshot = catalog.discoverySourceMappings
        let installed: AidokuInstalledSource
        do {
            installed = try await installer.install(
                archiveURL: url,
                expectedSourceID: expectedSourceID,
                migrate: { old, new, stagedSource in
                    try await self.migrateKeys(
                        sourceID: new.info.id,
                        old: old,
                        new: new,
                        stagedSource: stagedSource
                    )
                }
            )
        } catch {
            catalog.library = librarySnapshot
            catalog.progress = progressSnapshot
            catalog.discoverySourceMappings = discoveryMappingSnapshot
            throw error
        }
        let record = AidokuInstalledSourceRecord(
            sourceID: installed.id,
            name: installed.manifest.info.name,
            version: installed.manifest.info.version,
            contentRating: installed.manifest.info.contentRating ?? .safe,
            languages: installed.manifest.info.languages ?? [],
            listID: listID,
            downloadURL: downloadURL,
            pendingUpdateVersion: nil,
            pendingUpdateURL: nil,
            installedAt: installed.installedAt,
            lastFailure: nil
        )
        catalog.installedSources.removeAll { $0.sourceID == installed.id }
        catalog.installedSources.append(record)
        if let selection = resolvedLanguageSelection(
            manifest: installed.manifest,
            sourceID: installed.id
        ) {
            var selections = catalog.sourceLanguageSelections ?? [:]
            selections[installed.id] = selection.selectedLanguages
            catalog.sourceLanguageSelections = selections
        } else {
            catalog.sourceLanguageSelections?[installed.id] = nil
        }
        let runtime = runtimes.removeValue(forKey: installed.id)
        if let runtime { await runtime.cancel() }
        try? await coverLoader.invalidateSource(installed.id)
        try? await sourceIconLoader.invalidateSource(installed.id)
        try persist()
        return record
    }

    private func migrateKeys(
        sourceID: String,
        old: AidokuSourceManifest,
        new: AidokuSourceManifest,
        stagedSource: URL
    ) async throws {
        guard new.info.version >= old.info.version else {
            throw AidokuRuntimeError.incompatibleSource("source version moved backwards")
        }
        var defaults = mergedSourceDefaults(sourceID: sourceID)
        if let selection = resolvedLanguageSelection(manifest: new, sourceID: sourceID) {
            defaults["language"] = nil
            defaults["languages"] = nil
            defaults.merge(AidokuLanguageDefaults.encodedDefaults(
                type: selection.type,
                selectedLanguages: selection.selectedLanguages
            )) { _, languageDefault in languageDefault }
        }
        let runtime = try AidokuSourceRuntime(configuration: .init(
            sourceDirectory: stagedSource,
            defaults: defaults
        ))
        let retained = catalog.library.filter { $0.sourceID == sourceID }
        let retainedMappings = (catalog.discoverySourceMappings ?? [:]).filter {
            $0.value.sourceID == sourceID
        }
        var mangaKeyMap: [String: String] = [:]
        var migratedLibrary: [AidokuLibraryEntry] = []
        for entry in retained {
            let oldKey = entry.manga.key
            let newKey = try await runtime.migrateMangaKey(oldKey)
            guard !newKey.isEmpty else {
                throw AidokuRuntimeError.incompatibleSource("migration returned an empty manga key")
            }
            mangaKeyMap[oldKey] = newKey
            var migrated = entry
            migrated.manga = entry.manga.replacingKey(newKey)
            migrated.updatedAt = Date()
            migratedLibrary.append(migrated)
        }
        var migratedMappings: [String: AidokuDiscoverySourceMapping] = [:]
        for (workID, mapping) in retainedMappings {
            let oldKey = mapping.manga.key
            let newKey: String
            if let retainedKey = mangaKeyMap[oldKey] {
                newKey = retainedKey
            } else {
                newKey = try await runtime.migrateMangaKey(oldKey)
                mangaKeyMap[oldKey] = newKey
            }
            guard !newKey.isEmpty else {
                throw AidokuRuntimeError.incompatibleSource("migration returned an empty manga key")
            }
            var migrated = mapping
            migrated.manga = mapping.manga.replacingKey(newKey)
            migrated.updatedAt = Date()
            migratedMappings[workID] = migrated
        }
        var migratedProgress: [AidokuChapterProgress] = []
        for item in catalog.progress where item.sourceID == sourceID {
            let mangaKey: String
            if let retainedKey = mangaKeyMap[item.mangaKey] {
                mangaKey = retainedKey
            } else {
                mangaKey = try await runtime.migrateMangaKey(item.mangaKey)
            }
            let chapterKey = try await runtime.migrateChapterKey(
                mangaKey: item.mangaKey,
                chapterKey: item.chapterKey
            )
            guard !mangaKey.isEmpty, !chapterKey.isEmpty else {
                throw AidokuRuntimeError.incompatibleSource("migration returned an empty chapter identity")
            }
            migratedProgress.append(AidokuChapterProgress(
                sourceID: sourceID,
                mangaKey: mangaKey,
                chapterKey: chapterKey,
                pageIndex: item.pageIndex,
                pageCount: item.pageCount,
                completed: item.completed,
                updatedAt: Date()
            ))
        }
        catalog.library.removeAll { $0.sourceID == sourceID }
        catalog.library.append(contentsOf: migratedLibrary)
        catalog.progress.removeAll { $0.sourceID == sourceID }
        catalog.progress.append(contentsOf: migratedProgress)
        var mappings = catalog.discoverySourceMappings ?? [:]
        for workID in retainedMappings.keys { mappings[workID] = nil }
        mappings.merge(migratedMappings) { _, migrated in migrated }
        catalog.discoverySourceMappings = mappings.isEmpty ? nil : mappings
    }

    private func fetchSourceList(url: URL, insecureTransportApproved: Bool) async throws -> AidokuSourceList {
        try AidokuSourceListParser.validateRemoteURL(url, insecureTransportConfirmed: insecureTransportApproved)
        let (data, response) = try await AidokuHTTPClient.data(
            for: URLRequest(url: url),
            maximumBytes: AidokuLimits.maximumJSONBytes,
            insecureTransportApproved: insecureTransportApproved
        )
        guard data.count <= AidokuLimits.maximumJSONBytes,
              (200..<300).contains(response.statusCode),
              let finalURL = response.url else { throw AidokuRuntimeError.responseTooLarge }
        try AidokuSourceListParser.validateRemoteURL(finalURL, insecureTransportConfirmed: insecureTransportApproved)
        return try AidokuSourceListParser.parse(data: data, baseURL: finalURL)
    }

    private func downloadPackage(url: URL, insecureTransportApproved: Bool) async throws -> URL {
        let (data, response) = try await AidokuHTTPClient.data(
            for: URLRequest(url: url),
            maximumBytes: AidokuLimits.maximumArchiveBytes,
            insecureTransportApproved: insecureTransportApproved
        )
        guard (200..<300).contains(response.statusCode),
              let finalURL = response.url,
              ["http", "https"].contains(finalURL.scheme?.lowercased() ?? "") else {
            throw AidokuRuntimeError.archiveTooLarge
        }
        try AidokuSourceListParser.validateRemoteURL(
            finalURL,
            insecureTransportConfirmed: insecureTransportApproved
        )
        let destination = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("aix")
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    private func resolvedLanguageSelection(
        manifest: AidokuSourceManifest,
        sourceID: String
    ) -> AidokuSourceLanguageSelection? {
        guard let type = manifest.resolvedLanguageSelectType else { return nil }
        let supported = AidokuLanguageDefaults.supportedLanguages(
            manifest.info.languages ?? []
        )
        let selected = AidokuLanguageDefaults.normalizedSelection(
            supportedLanguages: supported,
            selectedLanguages: catalog.sourceLanguageSelections?[sourceID],
            type: type
        )
        return AidokuSourceLanguageSelection(
            type: type,
            supportedLanguages: supported,
            selectedLanguages: selected
        )
    }

    /// Source-authored runtime values are a fallback. Explicit user settings
    /// must win over an older runtime snapshot, and sensitive settings win last.
    private func mergedSourceDefaults(sourceID: String) -> [String: Data] {
        var values: [String: Data] = [:]
        if let encoded = keychain.read(sourceID, "runtime-defaults"),
           let runtimeValues = try? JSONDecoder().decode([String: Data].self, from: encoded) {
            values = runtimeValues
        }
        values.merge(catalog.sourceDefaults[sourceID] ?? [:]) { _, explicit in explicit }
        if let encoded = keychain.read(sourceID, "sensitive-settings"),
           let sensitiveValues = try? JSONDecoder().decode([String: Data].self, from: encoded) {
            values.merge(sensitiveValues) { _, sensitive in sensitive }
        }
        return values
    }

    private func storedWebsiteSession(sourceID: String) -> AidokuWebsiteSession? {
        guard let data = keychain.read(sourceID, AidokuWebsiteSession.keychainKey),
              let session = try? JSONDecoder().decode(AidokuWebsiteSession.self, from: data),
              session.userAgent.nilIfEmpty != nil else {
            return nil
        }
        return session
    }

    private func legacyCookies(sourceID: String) -> [AidokuStoredCookie] {
        keychain.read(sourceID, "cookies").flatMap {
            try? JSONDecoder().decode([AidokuStoredCookie].self, from: $0)
        } ?? []
    }

    private func persist() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(catalog).write(to: catalogURL, options: .atomic)
    }
}

nonisolated struct AidokuWebsiteSession: Codable, Sendable, Equatable {
    static let keychainKey = "website-session"

    let cookies: [AidokuStoredCookie]
    let userAgent: String
}

nonisolated enum AidokuWebsiteSessionCookieMerger {
    private struct Identity: Hashable, Comparable {
        let name: String
        let domain: String
        let path: String

        init(_ cookie: AidokuStoredCookie) {
            name = cookie.name
            domain = cookie.domain
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            path = cookie.path.isEmpty ? "/" : cookie.path
        }

        static func < (lhs: Identity, rhs: Identity) -> Bool {
            if lhs.domain != rhs.domain { return lhs.domain < rhs.domain }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return lhs.name < rhs.name
        }
    }

    static func merge(
        existing: [AidokuStoredCookie],
        incoming: [AidokuStoredCookie]
    ) -> [AidokuStoredCookie] {
        var values: [Identity: AidokuStoredCookie] = [:]
        for cookie in existing { values[Identity(cookie)] = cookie }
        for cookie in incoming { values[Identity(cookie)] = cookie }
        return values.keys.sorted().compactMap { values[$0] }
    }
}

@MainActor
private final class AidokuWebUserAgentProvider {
    static let shared = AidokuWebUserAgentProvider()
    static let fallbackUserAgent = "Niratan AidokuRuntime/1"

    private var cachedUserAgent: String?

    func userAgent() async -> String {
        if let cachedUserAgent { return cachedUserAgent }
        let webView = WKWebView(frame: .zero)
        let value = try? await webView.evaluateJavaScript("navigator.userAgent")
        guard let userAgent = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !userAgent.isEmpty else {
            return Self.fallbackUserAgent
        }
        cachedUserAgent = userAgent
        return userAgent
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

nonisolated private extension AidokuManga {
    func replacingKey(_ key: String) -> AidokuManga {
        AidokuManga(
            key: key,
            title: title,
            coverURL: coverURL,
            artists: artists,
            authors: authors,
            summary: summary,
            url: url,
            tags: tags,
            status: status,
            contentRating: contentRating,
            viewer: viewer,
            chapters: chapters
        )
    }
}

nonisolated struct AidokuKeychainStore: Sendable {
    let save: @Sendable (Data, String, String) throws -> Void
    let read: @Sendable (String, String) -> Data?
    let removeAll: @Sendable (String) throws -> Void

    static let live = AidokuKeychainStore(
        save: { data, sourceID, key in try AidokuKeychain.liveSave(data, sourceID: sourceID, key: key) },
        read: { sourceID, key in AidokuKeychain.liveRead(sourceID: sourceID, key: key) },
        removeAll: { sourceID in try AidokuKeychain.liveRemoveAll(sourceID: sourceID) }
    )
}

nonisolated private enum AidokuKeychain {
    static let service = DevelopmentDataIsolation.keychainName("moe.shishamo.hoshi.aidoku")
    static func account(sourceID: String, key: String) -> String { "\(sourceID)\u{1f}\(key)" }
    static func liveSave(_ data: Data, sourceID: String, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account(sourceID: sourceID, key: key)]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrGeneric as String: Data(sourceID.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AidokuRuntimeError.runtimeFailure(String(localized: "Unable to save Aidoku credential")) }
        } else if status != errSecSuccess { throw AidokuRuntimeError.runtimeFailure(String(localized: "Unable to save Aidoku credential")) }
    }
    static func liveRead(sourceID: String, key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account(sourceID: sourceID, key: key), kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func liveRemoveAll(sourceID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrGeneric as String: Data(sourceID.utf8)]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AidokuRuntimeError.runtimeFailure(String(localized: "Unable to remove Aidoku credentials")) }
    }
}
