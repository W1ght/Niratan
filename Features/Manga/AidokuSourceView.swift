import AidokuRuntime
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@Observable
@MainActor
final class AidokuSourceViewModel {
    var catalog = AidokuGlobalCatalog()
    var availableSources: [AidokuAvailableSource] = []
    var selectedSourceID: String?
    var listings: [AidokuListing] = []
    var selectedListingID: String?
    var query = ""
    var browseItems: [AidokuManga] = []
    var browsePage = 1
    var hasNextPage = false
    var detail: AidokuManga?
    var isDetailLoading = false
    var detailErrorMessage: String?
    var isLoading = false
    var errorMessage: String?
    var sourceListURLDraft = ""
    var pendingInsecureSourceListURL: URL?
    var pendingPackageURL: URL?
    var pendingInsecureSource: AidokuAvailableSource?
    var sourceForLogin: AidokuInstalledSourceRecord?
    var basicLoginConfiguration: AidokuLoginConfiguration?
    var webLoginRequest: AidokuWebLoginRequest?
    var websiteVerificationRequest: AidokuWebsiteVerificationSheetRequest?
    var activeWebsiteVerificationRequest: AidokuWebsiteVerificationSheetRequest?
    var settingsSource: AidokuInstalledSourceRecord?
    var sourceSettings: [AidokuSetting] = []
    var sourceSettingValues: [String: String] = [:]
    var sourceSettingListValues: [String: [String]] = [:]
    var sourceSettingListDrafts: [String: String] = [:]
    var settingsLanguageSelection: AidokuSourceLanguageSelection?
    var sourceLanguageFilter: String?
    var sourceSearchText = ""
    var filters: [AidokuFilter] = []
    var filterValues: [String: AidokuFilterValue] = [:]
    var usernameDraft = ""
    var passwordDraft = ""
    var coverRevision = UUID()
    var selectedSourceRequiresAuthentication = false

    @ObservationIgnored private let store = AidokuGlobalStore.shared
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var detailRequestID: UUID?
    @ObservationIgnored private var languageSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var languageSelectionRequestID: UUID?
    @ObservationIgnored private var webLoginPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var homeContinuationListingID: String?
    @ObservationIgnored private var activeBrowseRequestID = UUID()
    @ObservationIgnored private var activeSearchQuery: String?
    @ObservationIgnored var sourceAccessCompletionHandler: ((String) -> Void)?

    var visibleInstalledSources: [AidokuInstalledSourceRecord] {
        catalog.installedSources
            .filter { catalog.allowsAdultContent || $0.contentRating == .safe }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var visibleAvailableSources: [AidokuAvailableSource] {
        availableSources
            .filter { candidate in
                catalog.allowsAdultContent
                    || (candidate.entry.contentRating ?? .safe) == .safe
            }
            .sorted { $0.entry.name.localizedStandardCompare($1.entry.name) == .orderedAscending }
    }

    var filteredInstalledSources: [AidokuInstalledSourceRecord] {
        return visibleInstalledSources.filter {
            languageFilterMatches($0.languages)
                && AidokuSourceSearch.matches(
                    query: sourceSearchText,
                    fields: installedSearchFields($0)
                )
        }
    }

    var filteredAvailableSources: [AidokuAvailableSource] {
        return visibleAvailableSources.filter {
            languageFilterMatches($0.entry.languages ?? [])
                && AidokuSourceSearch.matches(
                    query: sourceSearchText,
                    fields: availableSearchFields($0)
                )
        }
    }

    var hasActiveSourceFilters: Bool {
        sourceLanguageFilter != nil || AidokuSourceSearch.hasTerms(sourceSearchText)
    }

    var sourceLanguageOptions: [String] {
        let languageGroups = visibleInstalledSources.map(\.languages)
            + visibleAvailableSources.map { $0.entry.languages ?? [] }
        var languages = AidokuLanguageDefaults.supportedLanguages(languageGroups.flatMap { $0 })
            .filter { $0.caseInsensitiveCompare("All") != .orderedSame }
        if languageGroups.contains(where: AidokuLanguageDefaults.isMultilingual),
           !languages.contains(where: { $0.caseInsensitiveCompare("multi") == .orderedSame }) {
            languages.append("multi")
        }
        return languages.sorted {
            languageDisplayName($0).localizedStandardCompare(languageDisplayName($1)) == .orderedAscending
        }
    }

    var visibleLibrary: [AidokuLibraryEntry] {
        catalog.library
            .filter { catalog.allowsAdultContent || $0.manga.contentRating != .adult }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var selectedSource: AidokuInstalledSourceRecord? {
        catalog.installedSources.first { $0.sourceID == selectedSourceID }
    }

    var shouldOfferSelectedSourceLogin: Bool {
        guard selectedSourceRequiresAuthentication,
              selectedSource != nil,
              let errorMessage else { return false }
        return isAuthenticationMessage(errorMessage) || browseItems.isEmpty
    }

    var shouldOfferSelectedSourceWebsiteVerification: Bool {
        guard let websiteVerificationRequest,
              websiteVerificationRequest.source.sourceID == selectedSourceID else {
            return false
        }
        return true
    }

    func load() {
        let browseRequestID = beginBrowseRequest()
        detailTask?.cancel()
        task = Task {
            await reload(
                refreshLists: false,
                browseRequestID: browseRequestID
            )
        }
    }

    /// Refreshes the shared catalog for callers that only need installed sources,
    /// settings, or website-authentication sheets and must not browse a source.
    func loadCatalogOnly() {
        task = Task {
            catalog = await store.snapshot()
        }
    }

    func refresh() {
        coverRevision = UUID()
        let browseRequestID = beginBrowseRequest()
        detailTask?.cancel()
        task = Task {
            await reload(
                refreshLists: true,
                browseRequestID: browseRequestID
            )
        }
    }

    func addSourceList(confirmInsecure: Bool = false) {
        guard let url = URL(string: sourceListURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = String(localized: "Enter a valid source list URL.")
            return
        }
        let insecure = url.scheme?.lowercased() == "http"
            || AidokuSourceListParser.isLocalNetworkHost(url.host)
        if insecure && !confirmInsecure {
            pendingInsecureSourceListURL = url
            return
        }
        task = Task {
            await self.perform {
                _ = try await self.store.addSourceList(url: url, insecureTransportApproved: insecure)
                self.sourceListURLDraft = ""
                await self.reload(refreshLists: true)
            }
        }
    }

    func removeSourceList(_ id: UUID) {
        task = Task { await self.perform { try await self.store.removeSourceList(id: id); await self.reload() } }
    }

    func requestLocalImport(_ url: URL) {
        pendingPackageURL = url
    }

    func confirmLocalImport() {
        guard let url = pendingPackageURL else { return }
        pendingPackageURL = nil
        task = Task {
            await self.perform {
                _ = try await self.store.installLocalPackage(url)
                if !self.catalog.didAcknowledgeThirdPartyDisclosure {
                    try await self.store.acknowledgeThirdPartyDisclosure()
                }
                await self.reload(refreshLists: false)
            }
        }
    }

    func install(_ candidate: AidokuAvailableSource) {
        if let value = candidate.entry.downloadURL,
           let url = URL(string: value),
           (url.scheme?.lowercased() == "http" || AidokuSourceListParser.isLocalNetworkHost(url.host)),
           catalog.sourceLists.first(where: { $0.id == candidate.listID })?.insecureTransportApproved != true {
            pendingInsecureSource = candidate
            return
        }
        install(candidate, insecureTransportApproved: false)
    }

    func confirmInsecureInstall() {
        guard let candidate = pendingInsecureSource else { return }
        pendingInsecureSource = nil
        install(candidate, insecureTransportApproved: true)
    }

    private func install(
        _ candidate: AidokuAvailableSource,
        insecureTransportApproved: Bool
    ) {
        task = Task {
            await self.perform {
                _ = try await self.store.installSource(
                    candidate.entry,
                    from: candidate.listID,
                    insecureTransportApproved: insecureTransportApproved
                )
                if !self.catalog.didAcknowledgeThirdPartyDisclosure {
                    try await self.store.acknowledgeThirdPartyDisclosure()
                }
                await self.reload()
            }
        }
    }

    func update(_ source: AidokuInstalledSourceRecord) {
        task = Task { await self.perform { _ = try await self.store.confirmUpdate(sourceID: source.sourceID); await self.reload() } }
    }

    func uninstall(_ source: AidokuInstalledSourceRecord) {
        task = Task { await self.perform { try await self.store.uninstall(sourceID: source.sourceID); await self.reload() } }
    }

    func setAllowsAdultContent(_ value: Bool) {
        task = Task { await self.perform { try await self.store.setAllowsAdultContent(value); await self.reload() } }
    }

    func usesDirectMediaConnection(sourceID: String) -> Bool {
        catalog.sourceDirectMediaConnections?[sourceID] == true
    }

    func setDirectMediaConnection(_ enabled: Bool, sourceID: String) {
        task = Task {
            await self.perform {
                try await self.store.setDirectMediaConnection(enabled, sourceID: sourceID)
                self.coverRevision = UUID()
                self.catalog = await self.store.snapshot()
            }
        }
    }

    func selectSource(_ sourceID: String?) {
        let browseRequestID = beginBrowseRequest()
        detailTask?.cancel()
        webLoginPreparationTask?.cancel()
        webLoginPreparationTask = nil
        detailTask = nil
        detailRequestID = nil
        isDetailLoading = false
        detailErrorMessage = nil
        selectedSourceID = sourceID
        selectedListingID = nil
        query = ""
        activeSearchQuery = nil
        browseItems = []
        homeContinuationListingID = nil
        detail = nil
        selectedSourceRequiresAuthentication = false
        websiteVerificationRequest = nil
        activeWebsiteVerificationRequest = nil
        task = Task {
            await updateSelectedSourceAuthentication(sourceID)
            await loadBrowse(
                reset: true,
                requestID: browseRequestID
            )
        }
    }

    func requestLoginForSelectedSource() {
        guard let source = selectedSource else { return }
        task?.cancel()
        errorMessage = nil
        task = Task {
            await self.perform {
                let runtime = try await self.store.runtime(sourceID: source.sourceID)
                let settings = try await runtime.settings()
                guard let configuration = settings.compactMap({ setting -> AidokuLoginConfiguration? in
                    guard case .login(let configuration) = setting else { return nil }
                    return configuration
                }).first else {
                    throw AidokuRuntimeError.runtimeFailure(
                        String(localized: "This source requires authentication but does not provide a login form.")
                    )
                }
                self.login(configuration, source: source)
            }
        }
    }

    func showSettings(_ source: AidokuInstalledSourceRecord) {
        languageSelectionTask?.cancel()
        languageSelectionTask = nil
        languageSelectionRequestID = nil
        settingsSource = source
        sourceSettings = []
        sourceSettingValues = [:]
        settingsLanguageSelection = nil
        task = Task {
            await self.perform {
                self.settingsLanguageSelection = try await self.store.languageSelection(
                    sourceID: source.sourceID
                )
                let runtime = try await self.store.runtime(sourceID: source.sourceID)
                self.sourceSettings = try await runtime.settings()
                var values: [String: String] = [:]
                var listValues: [String: [String]] = [:]
                for setting in self.sourceSettings {
                    switch setting {
                    case .switchValue(let id, _, let defaultValue, _):
                        let data = await self.store.sourceValue(sourceID: source.sourceID, key: id)
                        values[id] = data.flatMap { self.decodeSettingValue($0, setting: setting) } ?? (defaultValue ? "true" : "false")
                    case .select(let id, _, _, _, let defaultValue):
                        let data = await self.store.sourceValue(sourceID: source.sourceID, key: id)
                        values[id] = data.flatMap { self.decodeSettingValue($0, setting: setting) } ?? defaultValue ?? ""
                    case .multiSelect(let id, _, _, _, let defaultValues):
                        let data = await self.store.sourceValue(sourceID: source.sourceID, key: id)
                        listValues[id] = data.flatMap(self.decodeStringList) ?? defaultValues ?? []
                    case .segment(let id, _, _, let defaultIndex):
                        let data = await self.store.sourceValue(sourceID: source.sourceID, key: id)
                        values[id] = data.flatMap { self.decodeSettingValue($0, setting: setting) }
                            ?? defaultIndex.map { String($0) } ?? "0"
                    case .text(let id, _, let defaultValue, _):
                        let data = await self.store.sourceValue(sourceID: source.sourceID, key: id)
                        values[id] = data.flatMap { self.decodeSettingValue($0, setting: setting) } ?? defaultValue ?? ""
                    case .stepper(let id, _, let defaultValue, _, _, _):
                        let data = await self.store.sourceValue(sourceID: source.sourceID, key: id)
                        values[id] = data.flatMap { self.decodeSettingValue($0, setting: setting) }
                            ?? defaultValue.map { String($0) } ?? ""
                    case .editableList(let id, _, _, let defaultValues):
                        let data = await self.store.sourceValue(sourceID: source.sourceID, key: id)
                        listValues[id] = data.flatMap(self.decodeStringList) ?? defaultValues ?? []
                    case .login, .header: break
                    }
                }
                self.sourceSettingValues = values
                self.sourceSettingListValues = listValues
                self.sourceSettingListDrafts = [:]
            }
        }
    }

    func login(_ configuration: AidokuLoginConfiguration, source: AidokuInstalledSourceRecord) {
        switch configuration.method {
        case .basic:
            basicLoginConfiguration = configuration
            sourceForLogin = source
        case .web, .oauth:
            guard let value = configuration.url, let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                errorMessage = String(localized: "The source did not provide a valid login URL.")
                return
            }
            settingsSource = nil
            webLoginPreparationTask?.cancel()
            webLoginPreparationTask = Task {
                do {
                    let userAgent = try await store.resolvedWebsiteUserAgent(
                        sourceID: source.sourceID
                    )
                    try Task.checkCancellation()
                    guard catalog.installedSources.contains(where: {
                        $0.sourceID == source.sourceID
                    }) else { return }
                    webLoginRequest = AidokuWebLoginRequest(
                        source: source,
                        configuration: configuration,
                        url: url,
                        userAgent: userAgent
                    )
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = aidokuErrorMessage(error)
                }
            }
        }
    }

    func finishWebLogin(
        _ request: AidokuWebLoginRequest,
        cookies: [HTTPCookie],
        localStorage: [String: String],
        userAgent: String
    ) {
        task = Task {
            await self.perform {
                let relevantCookies = AidokuWebLoginValues.relevantCookies(
                    cookies,
                    loginURL: request.url
                )
                let values = AidokuWebLoginValues.mergedValues(
                    cookies: relevantCookies,
                    localStorage: localStorage
                )
                let runtime = try await self.store.runtime(sourceID: request.source.sourceID)
                guard try await runtime.webLogin(key: request.configuration.key, cookies: values) else {
                    throw AidokuRuntimeError.runtimeFailure(String(localized: "The source rejected the login."))
                }
                let stored = relevantCookies.map {
                    AidokuStoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, secure: $0.isSecure, expiresAt: $0.expiresDate)
                }
                try await self.store.saveWebsiteSession(
                    cookies: stored,
                    userAgent: userAgent,
                    sourceID: request.source.sourceID
                )
                self.coverRevision = UUID()
                self.webLoginRequest = nil
                self.errorMessage = nil
                self.sourceAccessCompletionHandler?(request.source.sourceID)
                if self.selectedSourceID == request.source.sourceID {
                    let browseRequestID = self.activateBrowseRequest()
                    await self.loadBrowse(
                        reset: true,
                        requestID: browseRequestID
                    )
                }
            }
        }
    }

    func requestWebsiteVerification() {
        guard let request = websiteVerificationRequest else { return }
        let nextAttempt = request.withFreshPresentationID()
        websiteVerificationRequest = nextAttempt
        activeWebsiteVerificationRequest = nextAttempt
    }

    func cancelWebsiteVerification(requestID: UUID) {
        guard activeWebsiteVerificationRequest?.id == requestID else { return }
        activeWebsiteVerificationRequest = nil
    }

    func isWebsiteVerificationActive(
        _ request: AidokuWebsiteVerificationSheetRequest
    ) -> Bool {
        websiteVerificationRequest?.id == request.id
            && activeWebsiteVerificationRequest?.id == request.id
            && selectedSourceID == request.source.sourceID
    }

    func finishWebsiteVerification(
        _ request: AidokuWebsiteVerificationSheetRequest,
        cookies: [HTTPCookie],
        userAgent: String
    ) async -> Bool {
        guard isWebsiteVerificationActive(request) else { return false }
        do {
            try Task.checkCancellation()
            let relevantCookies = AidokuWebLoginValues.relevantCookies(
                cookies,
                loginURL: request.runtimeRequest.url
            )
            let stored = relevantCookies.map(AidokuStoredCookie.init)
            guard isWebsiteVerificationActive(request) else { return false }
            // didSubmit disables every user dismissal path before this actor
            // call. The store performs read/merge/Keychain write serially and
            // only then yields while invalidating the old runtime.
            try await store.saveWebsiteSession(
                cookies: stored,
                userAgent: userAgent,
                sourceID: request.source.sourceID
            )
            try Task.checkCancellation()
            guard isWebsiteVerificationActive(request) else { return true }
            coverRevision = UUID()
            errorMessage = nil
            websiteVerificationRequest = nil
            activeWebsiteVerificationRequest = nil
            switch request.retryTarget {
            case .browse where selectedSourceID == request.source.sourceID:
                let browseRequestID = beginBrowseRequest()
                task = Task {
                    await self.loadBrowse(
                        reset: true,
                        requestID: browseRequestID
                    )
                }
            case .details(let mangaKey):
                guard selectedSourceID == request.source.sourceID,
                      let detail,
                      detail.key == mangaKey else { return true }
                loadDetails(detail)
            case .discovery:
                // The Discover detail owns the currently selected work and
                // retries only while that work/source pair is still active.
                break
            default:
                break
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isWebsiteVerificationActive(request) else { return false }
            errorMessage = aidokuErrorMessage(error)
            return false
        }
    }

    func saveSetting(_ setting: AidokuSetting, sourceID: String) {
        let id = setting.id
        let sensitive: Bool
        if case .text(_, _, _, let secure) = setting { sensitive = secure }
        else if case .switchValue(_, _, _, let secure) = setting { sensitive = secure }
        else { sensitive = false }
        let value = encodeSettingValue(sourceSettingValues[id] ?? "", setting: setting)
        task = Task {
            await self.perform {
                try await self.store.setSourceValue(value, sourceID: sourceID, key: id, sensitive: sensitive)
                self.coverRevision = UUID()
            }
        }
    }

    func toggleSettingOption(
        _ option: String,
        enabled: Bool,
        setting: AidokuSetting,
        sourceID: String
    ) {
        var values = sourceSettingListValues[setting.id] ?? []
        if enabled {
            if !values.contains(option) { values.append(option) }
        } else {
            values.removeAll { $0 == option }
        }
        sourceSettingListValues[setting.id] = values
        saveSetting(setting, sourceID: sourceID)
    }

    func updateEditableListItem(
        _ value: String,
        index: Int,
        setting: AidokuSetting,
        sourceID: String
    ) {
        guard var values = sourceSettingListValues[setting.id], values.indices.contains(index) else { return }
        values[index] = value
        sourceSettingListValues[setting.id] = values
        saveSetting(setting, sourceID: sourceID)
    }

    func addEditableListItem(setting: AidokuSetting, sourceID: String) {
        let value = (sourceSettingListDrafts[setting.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        sourceSettingListValues[setting.id, default: []].append(value)
        sourceSettingListDrafts[setting.id] = ""
        saveSetting(setting, sourceID: sourceID)
    }

    func removeEditableListItem(index: Int, setting: AidokuSetting, sourceID: String) {
        guard var values = sourceSettingListValues[setting.id], values.indices.contains(index) else { return }
        values.remove(at: index)
        sourceSettingListValues[setting.id] = values
        saveSetting(setting, sourceID: sourceID)
    }

    func selectContentLanguage(_ language: String, sourceID: String) {
        guard let selection = settingsLanguageSelection else { return }
        settingsLanguageSelection = AidokuSourceLanguageSelection(
            type: selection.type,
            supportedLanguages: selection.supportedLanguages,
            selectedLanguages: [language]
        )
        saveContentLanguages([language], sourceID: sourceID)
    }

    func toggleContentLanguage(_ language: String, enabled: Bool, sourceID: String) {
        guard let selection = settingsLanguageSelection else { return }
        var languages = selection.selectedLanguages
        if enabled {
            if !languages.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
                languages.append(language)
            }
        } else {
            languages.removeAll { $0.caseInsensitiveCompare(language) == .orderedSame }
            guard !languages.isEmpty else { return }
        }
        languages = AidokuLanguageDefaults.normalizedSelection(
            supportedLanguages: selection.supportedLanguages,
            selectedLanguages: languages,
            preferredLanguageIdentifiers: [],
            type: selection.type
        )
        settingsLanguageSelection = AidokuSourceLanguageSelection(
            type: selection.type,
            supportedLanguages: selection.supportedLanguages,
            selectedLanguages: languages
        )
        saveContentLanguages(languages, sourceID: sourceID)
    }

    func languageDisplayName(_ identifier: String) -> String {
        if identifier.caseInsensitiveCompare("multi") == .orderedSame {
            return String(localized: "Multilingual")
        }
        guard let name = Locale.current.localizedString(forIdentifier: identifier),
              name.caseInsensitiveCompare(identifier) != .orderedSame else {
            return identifier
        }
        return "\(name) (\(identifier))"
    }

    func languageSummary(_ languages: [String]) -> String {
        AidokuLanguageDefaults.supportedLanguages(languages)
            .map(languageDisplayName)
            .joined(separator: ", ")
    }

    func compactLanguageSummary(_ languages: [String], limit: Int = 3) -> String {
        let names = AidokuLanguageDefaults.supportedLanguages(languages)
            .map(languageDisplayName)
        guard names.count > limit else { return names.joined(separator: ", ") }
        return names.prefix(limit).joined(separator: ", ") + " +\(names.count - limit)"
    }

    func installedSourceIconData(_ source: AidokuInstalledSourceRecord) async -> Data? {
        try? await store.installedSourceIconData(sourceID: source.sourceID)
    }

    func availableSourceIconData(_ source: AidokuAvailableSource) async -> Data? {
        try? await store.availableSourceIconData(source)
    }

    func selectListing(_ listingID: String?) {
        let browseRequestID = beginBrowseRequest()
        selectedListingID = listingID
        query = ""
        activeSearchQuery = nil
        browseItems = []
        homeContinuationListingID = nil
        task = Task {
            await loadBrowse(
                reset: true,
                requestID: browseRequestID
            )
        }
    }

    func search() {
        let submittedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        query = submittedQuery
        activeSearchQuery = submittedQuery.isEmpty ? nil : submittedQuery
        selectedListingID = nil
        homeContinuationListingID = nil
        let browseRequestID = beginBrowseRequest()
        task = Task {
            await loadBrowse(
                reset: true,
                requestID: browseRequestID
            )
        }
    }

    func retryBrowse() {
        let browseRequestID = beginBrowseRequest()
        task = Task {
            await loadBrowse(
                reset: true,
                requestID: browseRequestID
            )
        }
    }

    func loadNextPageIfNeeded(current item: AidokuManga) {
        guard item.key == browseItems.last?.key, hasNextPage, !isLoading else { return }
        let browseRequestID = beginBrowseRequest()
        task = Task {
            await loadBrowse(
                reset: false,
                requestID: browseRequestID
            )
        }
    }

    func showDetails(_ manga: AidokuManga) {
        detail = manga
        loadDetails(manga)
    }

    func retryDetails() {
        guard let detail else { return }
        loadDetails(detail)
    }

    func dismissDetails() {
        detailTask?.cancel()
        detailTask = nil
        detailRequestID = nil
        isDetailLoading = false
        detailErrorMessage = nil
        detail = nil
    }

    private func loadDetails(_ manga: AidokuManga) {
        guard let sourceID = selectedSourceID else { return }
        detailTask?.cancel()
        let requestID = UUID()
        detailRequestID = requestID
        isDetailLoading = true
        detailErrorMessage = nil
        detailTask = Task {
            defer {
                if self.detailRequestID == requestID {
                    self.isDetailLoading = false
                }
            }
            do {
                let runtime = try await self.store.runtime(sourceID: sourceID)
                let summary = try await runtime.mangaDetails(manga, chapters: false)
                try Task.checkCancellation()
                guard self.detailRequestID == requestID,
                      self.detail?.key == manga.key else { return }
                self.detail = summary
                let loaded = try await runtime.mangaDetails(summary, chapters: true)
                try Task.checkCancellation()
                guard self.detailRequestID == requestID,
                      self.detail?.key == manga.key else { return }
                self.detail = loaded
            } catch is CancellationError {
                return
            } catch AidokuRuntimeError.cancelled {
                return
            } catch {
                guard self.detailRequestID == requestID,
                      self.detail?.key == manga.key else { return }
                let captured = await self.captureWebsiteVerification(
                    error,
                    sourceID: sourceID,
                    retryTarget: .details(mangaKey: manga.key),
                    isCurrent: {
                        self.detailRequestID == requestID
                            && self.detail?.key == manga.key
                    }
                )
                guard self.detailRequestID == requestID,
                      self.detail?.key == manga.key else { return }
                self.detailErrorMessage = captured
                    ? String(localized: "Complete the website check before browsing this source.")
                    : aidokuErrorMessage(error)
            }
        }
    }

    func isInLibrary(sourceID: String, mangaKey: String) -> Bool {
        catalog.library.contains { $0.sourceID == sourceID && $0.manga.key == mangaKey }
    }

    func toggleLibrary(source: AidokuInstalledSourceRecord, manga: AidokuManga) {
        task = Task {
            await self.perform {
                if self.isInLibrary(sourceID: source.sourceID, mangaKey: manga.key) {
                    try await self.store.removeFromLibrary(sourceID: source.sourceID, mangaKey: manga.key)
                } else {
                    try await self.store.addToLibrary(sourceID: source.sourceID, sourceName: source.name, manga: manga)
                }
                await self.reload()
            }
        }
    }

    func basicLogin() {
        guard let source = sourceForLogin, let configuration = basicLoginConfiguration else { return }
        let username = usernameDraft
        let password = passwordDraft
        task = Task {
            await self.perform {
                let runtime = try await self.store.runtime(sourceID: source.sourceID)
                guard try await runtime.basicLogin(key: configuration.key, username: username, password: password) else {
                    throw AidokuRuntimeError.runtimeFailure(String(localized: "The source rejected the login."))
                }
                await self.store.invalidateCaches(sourceID: source.sourceID)
                try await self.store.saveSecret(Data(username.utf8), sourceID: source.sourceID, key: "login-username")
                try await self.store.saveSecret(Data(password.utf8), sourceID: source.sourceID, key: "login-password")
                self.coverRevision = UUID()
                self.usernameDraft = ""
                self.passwordDraft = ""
                self.sourceForLogin = nil
                self.basicLoginConfiguration = nil
                self.errorMessage = nil
                self.sourceAccessCompletionHandler?(source.sourceID)
                if self.selectedSourceID == source.sourceID {
                    let browseRequestID = self.activateBrowseRequest()
                    await self.loadBrowse(
                        reset: true,
                        requestID: browseRequestID
                    )
                }
            }
        }
    }

    func cancelBasicLogin() {
        usernameDraft = ""
        passwordDraft = ""
        sourceForLogin = nil
        basicLoginConfiguration = nil
    }

    private func encodeSettingValue(_ value: String, setting: AidokuSetting) -> Data {
        var writer = AidokuPostcardWriter()
        switch setting {
        case .switchValue:
            writer.write(value == "true")
        case .stepper:
            writer.write(Double(value) ?? 0)
        case .segment:
            writer.write(Int32(value) ?? 0)
        case .select, .text:
            writer.write(value)
        case .multiSelect, .editableList:
            writer.write(sourceSettingListValues[setting.id] ?? []) { $0.write($1) }
        case .header, .login:
            return Data()
        }
        return writer.data
    }

    private func decodeSettingValue(_ data: Data, setting: AidokuSetting) -> String? {
        do {
            var reader = AidokuPostcardReader(data: data)
            let value: String
            switch setting {
            case .switchValue:
                value = try reader.readBool() ? "true" : "false"
            case .stepper:
                value = String(try reader.readDouble())
            case .segment:
                value = String(try reader.readInt32())
            case .select, .text:
                value = try reader.readString()
            case .multiSelect, .editableList, .header, .login:
                return nil
            }
            try reader.finish()
            return value
        } catch {
            return nil
        }
    }

    private func decodeStringList(_ data: Data) -> [String]? {
        do {
            var reader = AidokuPostcardReader(data: data)
            let values = try reader.readArray { try $0.readString() }
            try reader.finish()
            return values
        } catch {
            return nil
        }
    }

    func prepareReading(
        source: AidokuInstalledSourceRecord,
        manga: AidokuManga,
        initialChapterKey: String? = nil,
        profileID: String
    ) -> MangaRemoteReadingRequest {
        AidokuReadingRequestFactory.make(
            source: source,
            manga: manga,
            initialChapterKey: initialChapterKey,
            profileID: profileID,
            catalog: catalog
        )
    }

    func sourceRecord(for entry: AidokuLibraryEntry) -> AidokuInstalledSourceRecord? {
        catalog.installedSources.first { $0.sourceID == entry.sourceID }
    }

    private func beginBrowseRequest() -> UUID {
        task?.cancel()
        task = nil
        return activateBrowseRequest()
    }

    private func activateBrowseRequest() -> UUID {
        let requestID = UUID()
        activeBrowseRequestID = requestID
        isLoading = false
        return requestID
    }

    private func isCurrentBrowseRequest(
        _ requestID: UUID,
        sourceID: String
    ) -> Bool {
        activeBrowseRequestID == requestID
            && selectedSourceID == sourceID
            && !Task.isCancelled
    }

    private func reload(
        refreshLists: Bool = false,
        browseRequestID: UUID? = nil
    ) async {
        let browseRequestID = browseRequestID ?? activateBrowseRequest()
        isLoading = true
        defer {
            if activeBrowseRequestID == browseRequestID {
                isLoading = false
            }
        }
        do {
            catalog = await store.snapshot()
            availableSources = try await store.availableSources(forceRefresh: refreshLists)
            try Task.checkCancellation()
            guard activeBrowseRequestID == browseRequestID else { return }
            catalog = await store.snapshot()
            if selectedSourceID == nil || !visibleInstalledSources.contains(where: { $0.sourceID == selectedSourceID }) {
                selectedSourceID = visibleInstalledSources.first?.sourceID
            }
            await updateSelectedSourceAuthentication(selectedSourceID)
            guard activeBrowseRequestID == browseRequestID else { return }
            if selectedSourceID != nil, browseItems.isEmpty {
                await loadBrowse(
                    reset: true,
                    requestID: browseRequestID
                )
            }
        } catch is CancellationError {
            return
        } catch AidokuRuntimeError.cancelled {
            return
        } catch {
            guard activeBrowseRequestID == browseRequestID else { return }
            errorMessage = aidokuErrorMessage(error)
        }
    }

    private func updateSelectedSourceAuthentication(_ sourceID: String?) async {
        guard let sourceID else {
            selectedSourceRequiresAuthentication = false
            return
        }
        let requiresAuthentication = await store.requiresAuthentication(sourceID: sourceID)
        guard selectedSourceID == sourceID else { return }
        selectedSourceRequiresAuthentication = requiresAuthentication
    }

    private func loadBrowse(reset: Bool, requestID: UUID) async {
        guard activeBrowseRequestID == requestID,
              let sourceID = selectedSourceID else { return }
        if reset {
            browsePage = 1
            browseItems = []
            hasNextPage = false
            homeContinuationListingID = nil
            errorMessage = nil
        }
        isLoading = true
        defer {
            if activeBrowseRequestID == requestID {
                isLoading = false
            }
        }
        do {
            let runtime = try await store.runtime(sourceID: sourceID)
            if reset {
                let loadedListings = (try? await runtime.listings()) ?? []
                let loadedFilters = (try? await runtime.filters()) ?? []
                try Task.checkCancellation()
                guard isCurrentBrowseRequest(requestID, sourceID: sourceID) else {
                    return
                }
                listings = loadedListings
                filters = loadedFilters
            }
            let requestedSearchQuery = activeSearchQuery
            let requestedListingID = selectedListingID
            let requestedContinuationListingID = homeContinuationListingID
            let requestedFilters = filterValues.map { ($0.key, $0.value) }
            var requestedPage = browsePage
            var page: AidokuMangaPage
            if let requestedSearchQuery {
                page = try await runtime.search(
                    query: requestedSearchQuery,
                    page: requestedPage,
                    filters: requestedFilters
                )
            } else if let listing = listings.first(where: { $0.id == requestedListingID }) {
                page = try await runtime.mangaList(
                    listing: listing,
                    page: requestedPage
                )
            } else if !reset,
                      let listing = listings.first(where: {
                          $0.id == requestedContinuationListingID
                      }) {
                page = try await runtime.mangaList(
                    listing: listing,
                    page: requestedPage
                )
            } else {
                let home = reset ? try await runtime.homeManga() : []
                if home.isEmpty {
                    page = try await runtime.search(
                        query: nil,
                        page: requestedPage,
                        filters: requestedFilters
                    )
                } else {
                    let continuation = listings.first(where: { $0.kind == .popular }) ?? listings.first
                    requestedPage = 0
                    page = AidokuMangaPage(entries: home, hasNextPage: continuation != nil)
                    try Task.checkCancellation()
                    guard isCurrentBrowseRequest(requestID, sourceID: sourceID) else {
                        return
                    }
                    homeContinuationListingID = continuation?.id
                }
            }
            try Task.checkCancellation()
            guard isCurrentBrowseRequest(requestID, sourceID: sourceID),
                  activeSearchQuery == requestedSearchQuery,
                  selectedListingID == requestedListingID else {
                return
            }
            var existing = Set(browseItems.map(\.key))
            var additions = visibleEntries(in: page).filter { !existing.contains($0.key) }
            var duplicatePageFingerprints = Set<String>()
            var skippedDuplicatePages = 0

            // Home commonly contains the same titles as page 1 of Popular.
            // Advance through a few distinct duplicate-only pages immediately;
            // otherwise the unchanged trailing sentinel never appears again and
            // infinite scrolling stops even though the source has more pages.
            while additions.isEmpty, page.hasNextPage, skippedDuplicatePages < 4 {
                let fingerprint = page.entries.map(\.key).joined(separator: "\u{1f}")
                guard !fingerprint.isEmpty,
                      duplicatePageFingerprints.insert(fingerprint).inserted else { break }
                skippedDuplicatePages += 1
                requestedPage += 1
                if let requestedSearchQuery {
                    page = try await runtime.search(
                        query: requestedSearchQuery,
                        page: requestedPage,
                        filters: requestedFilters
                    )
                } else if let listing = listings.first(where: { $0.id == requestedListingID })
                            ?? listings.first(where: { $0.id == homeContinuationListingID }) {
                    page = try await runtime.mangaList(
                        listing: listing,
                        page: requestedPage
                    )
                } else {
                    page = try await runtime.search(
                        query: nil,
                        page: requestedPage,
                        filters: requestedFilters
                    )
                }
                try Task.checkCancellation()
                guard isCurrentBrowseRequest(requestID, sourceID: sourceID),
                      activeSearchQuery == requestedSearchQuery,
                      selectedListingID == requestedListingID else {
                    return
                }
                existing = Set(browseItems.map(\.key))
                additions = visibleEntries(in: page).filter { !existing.contains($0.key) }
            }
            browseItems.append(contentsOf: additions)
            hasNextPage = page.hasNextPage && !additions.isEmpty
            browsePage = hasNextPage ? requestedPage + 1 : requestedPage
        } catch is CancellationError {
            return
        } catch AidokuRuntimeError.cancelled {
            return
        } catch {
            guard isCurrentBrowseRequest(requestID, sourceID: sourceID) else {
                return
            }
            if !(await captureWebsiteVerification(
                error,
                sourceID: sourceID,
                retryTarget: .browse,
                isCurrent: {
                    self.isCurrentBrowseRequest(
                        requestID,
                        sourceID: sourceID
                    )
                }
            )) {
                guard isCurrentBrowseRequest(requestID, sourceID: sourceID) else {
                    return
                }
                errorMessage = aidokuErrorMessage(error)
            }
        }
    }

    private func captureWebsiteVerification(
        _ error: Error,
        sourceID: String,
        retryTarget: AidokuWebsiteVerificationRetryTarget,
        isCurrent: @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard let runtimeError = error as? AidokuRuntimeError,
              case .websiteVerificationRequired(let runtimeRequest) = runtimeError,
              !Task.isCancelled,
              isCurrent(),
              selectedSourceID == sourceID,
              let source = catalog.installedSources.first(where: { $0.sourceID == sourceID }) else {
            return false
        }
        let cookies = await store.storedCookies(sourceID: sourceID)
        guard !Task.isCancelled,
              isCurrent(),
              selectedSourceID == sourceID,
              catalog.installedSources.contains(where: { $0.sourceID == sourceID }) else {
            return false
        }
        let request = AidokuWebsiteVerificationSheetRequest(
            source: source,
            runtimeRequest: runtimeRequest,
            existingCookies: cookies,
            retryTarget: retryTarget
        )
        websiteVerificationRequest = request
        if retryTarget == .browse {
            activeWebsiteVerificationRequest = request
        } else {
            // A detail is already presented as a sheet. Keep the challenge
            // pending and let the detail action present verification from
            // that sheet's own hierarchy, avoiding competing outer sheets.
            activeWebsiteVerificationRequest = nil
        }
        errorMessage = String(localized: "Complete the website check before browsing this source.")
        return true
    }

    private func visibleEntries(in page: AidokuMangaPage) -> [AidokuManga] {
        page.entries.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (catalog.allowsAdultContent || $0.contentRating != .adult)
        }
    }

    private func saveContentLanguages(_ languages: [String], sourceID: String) {
        languageSelectionTask?.cancel()
        let requestID = UUID()
        languageSelectionRequestID = requestID
        isLoading = true
        errorMessage = nil
        languageSelectionTask = Task {
            defer {
                if self.languageSelectionRequestID == requestID {
                    self.isLoading = false
                }
            }
            do {
                let selection = try await self.store.setSelectedLanguages(
                    languages,
                    sourceID: sourceID
                )
                try Task.checkCancellation()
                guard self.languageSelectionRequestID == requestID else { return }
                self.settingsLanguageSelection = selection
                self.coverRevision = UUID()
                self.catalog = await self.store.snapshot()
                guard self.selectedSourceID == sourceID else { return }
                self.detailTask?.cancel()
                self.detailTask = nil
                self.detailRequestID = nil
                self.detail = nil
                self.listings = []
                self.selectedListingID = nil
                self.query = ""
                self.activeSearchQuery = nil
                self.filters = []
                self.filterValues = [:]
                self.browseItems = []
                self.homeContinuationListingID = nil
                let browseRequestID = self.activateBrowseRequest()
                await self.loadBrowse(
                    reset: true,
                    requestID: browseRequestID
                )
            } catch is CancellationError {
                return
            } catch AidokuRuntimeError.cancelled {
                return
            } catch {
                guard self.languageSelectionRequestID == requestID else { return }
                self.errorMessage = self.aidokuErrorMessage(error)
            }
        }
    }

    private func languageFilterMatches(_ languages: [String]) -> Bool {
        guard let sourceLanguageFilter else { return true }
        return AidokuLanguageDefaults.matchesLanguageFilter(
            sourceLanguageFilter,
            supportedLanguages: languages
        )
    }

    private func installedSearchFields(_ source: AidokuInstalledSourceRecord) -> [String] {
        var fields = [source.name, source.sourceID]
        if let listID = source.listID,
           let listName = catalog.sourceLists.first(where: { $0.id == listID })?.name {
            fields.append(listName)
        }
        fields.append(contentsOf: source.languages)
        fields.append(contentsOf: source.languages.map(languageDisplayName))
        return fields
    }

    private func availableSearchFields(_ source: AidokuAvailableSource) -> [String] {
        let languages = source.entry.languages ?? []
        return [
            source.entry.name,
            source.entry.id,
            source.listName,
            source.entry.baseURL ?? "",
        ] + (source.entry.altNames ?? []) + languages + languages.map(languageDisplayName)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { try await operation() } catch { errorMessage = aidokuErrorMessage(error) }
    }

    private func aidokuErrorMessage(_ error: Error) -> String {
        if let runtimeError = error as? AidokuRuntimeError,
           runtimeError == .altStoreAppCatalog {
            return String(localized: "This URL is an AltStore app catalog for installing Aidoku, not an Aidoku source list containing .aix sources.")
        }
        if let runtimeError = error as? AidokuRuntimeError,
           case .websiteVerificationRequired = runtimeError {
            return String(localized: "Complete the website check before browsing this source.")
        }
        let message = error.localizedDescription
        if selectedSourceRequiresAuthentication, isAuthenticationMessage(message) {
            return String(localized: "Log in to this source before browsing or reading manga.")
        }
        if let runtimeError = error as? AidokuRuntimeError {
            return runtimeError.localizedMessage
        }
        return message
    }

    private func isAuthenticationMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("login")
            || normalized.contains("log in")
            || normalized.contains("unauthorized")
            || normalized.contains("authentication")
    }
}

extension AidokuRuntimeError {
    /// App-side translation of the runtime package's English error descriptions.
    var localizedMessage: String {
        switch self {
        case .invalidArchive:
            String(localized: "The file is not a valid Aidoku source package.")
        case .archiveTooLarge:
            String(localized: "The Aidoku source package exceeds 64 MiB.")
        case .expandedArchiveTooLarge:
            String(localized: "The expanded Aidoku source package exceeds 256 MiB.")
        case .tooManyArchiveEntries:
            String(localized: "The Aidoku source package contains too many files.")
        case .unsafeArchivePath(let path):
            String(localized: "The source package contains an unsafe path: \(path)")
        case .symbolicLink(let path):
            String(localized: "The source package contains a symbolic link: \(path)")
        case .missingPayload(let name):
            String(localized: "The source package is missing Payload/\(name).")
        case .invalidManifest:
            String(localized: "The source package manifest is invalid.")
        case .altStoreAppCatalog:
            String(localized: "This URL is an AltStore app catalog for installing Aidoku, not an Aidoku source list containing .aix sources.")
        case .invalidSourceID:
            String(localized: "The source package has an unsafe source identifier.")
        case .sourceIDMismatch(let expected, let actual):
            String(localized: "The source identifier does not match (expected \(expected), found \(actual)).")
        case .invalidWasm:
            String(localized: "The source package does not contain a valid WebAssembly module.")
        case .incompatibleSource(let reason):
            String(localized: "The Aidoku source is incompatible: \(reason)")
        case .unsupportedURL:
            String(localized: "Only HTTP and HTTPS source URLs are supported.")
        case .insecureTransportRequiresConfirmation:
            String(localized: "This source uses HTTP or a local-network address and requires confirmation.")
        case .responseTooLarge:
            String(localized: "The source response is too large.")
        case .timedOut:
            String(localized: "The Aidoku source timed out.")
        case .cancelled:
            String(localized: "The Aidoku source operation was cancelled.")
        case .sourceUnavailable:
            String(localized: "The Aidoku source is not installed.")
        case .malformedPostcard:
            String(localized: "The Aidoku source returned malformed Postcard data.")
        case .websiteVerificationRequired:
            String(localized: "Website verification is required before this Aidoku source can continue.")
        case .runtimeFailure(let message):
            message
        }
    }
}

private struct AidokuSourceIconView: View {
    let requestID: String
    let load: @MainActor () async -> Data?

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.09))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: requestID) {
            image = nil
            for attempt in 0..<2 {
                if attempt > 0 {
                    do {
                        try await Task.sleep(for: .seconds(31))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                if let data = await load(),
                   !Task.isCancelled,
                   let loadedImage = NSImage(data: data) {
                    image = loadedImage
                    return
                }
            }
        }
    }
}

private struct AidokuManagementRow<Leading: View, Actions: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            leading()
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    actions()
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

struct AidokuSourcesView: View {
    @Bindable var viewModel: AidokuSourceViewModel

    var body: some View {
        NativeSettingsForm {
            NativeSettingsSectionCard(
                "Aidoku Source Lists",
                footer: "Aidoku sources contain third-party WebAssembly code and can access arbitrary HTTP(S) endpoints. Install only sources you trust."
            ) {
                NativeSettingsRow { Text("Source List URL") } accessory: {
                    TextField("Source List URL", text: $viewModel.sourceListURLDraft)
                        .nativeSettingsTextField()
                        .frame(maxWidth: 420)
                        .onSubmit { viewModel.addSourceList() }
                }
                NativeSettingsSeparator()
                AidokuManagementRow {
                    Text("Show Adult Sources and Manga")
                } actions: {
                    Toggle("Show Adult Sources and Manga", isOn: Binding(
                        get: { viewModel.catalog.allowsAdultContent },
                        set: { viewModel.setAllowsAdultContent($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    Button("Add List") { viewModel.addSourceList() }.buttonStyle(.glassProminent)
                    Button("Import .aix") { presentImporter() }.buttonStyle(.glass)
                    Button("Check for Updates") { viewModel.refresh() }.buttonStyle(.glass)
                }
                NativeSettingsSeparator()
                NativeSettingsRow { Text("Source Language") } accessory: {
                    NativeGlassMenuPicker(
                        selection: $viewModel.sourceLanguageFilter,
                        values: [nil] + viewModel.sourceLanguageOptions.map(Optional.some),
                        minWidth: 240
                    ) { language in
                        Text(language.map(viewModel.languageDisplayName) ?? String(localized: "All Languages"))
                    }
                }
                NativeSettingsSeparator()
                NativeSettingsRow { Text("Search Sources") } accessory: {
                    TextField("Search Aidoku Sources", text: $viewModel.sourceSearchText)
                        .nativeSettingsTextField()
                        .frame(minWidth: 240, maxWidth: 420)
                }
                ForEach(viewModel.catalog.sourceLists) { list in
                    NativeSettingsSeparator()
                    AidokuManagementRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(list.name)
                            Text(list.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } actions: {
                        if list.isBuiltIn {
                            Text("Built-in")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Remove", role: .destructive) { viewModel.removeSourceList(list.id) }
                                .buttonStyle(.glass)
                        }
                    }
                }
            }

            NativeSettingsSectionCard("Installed Aidoku Sources") {
                LazyVStack(spacing: 0) {
                    if viewModel.filteredInstalledSources.isEmpty {
                        AidokuManagementRow {
                            if !viewModel.hasActiveSourceFilters {
                                Text("No Aidoku sources are installed.").foregroundStyle(.secondary)
                            } else {
                                Text("No installed Aidoku sources match the current filters.").foregroundStyle(.secondary)
                            }
                        } actions: {
                            EmptyView()
                        }
                    }
                    ForEach(Array(viewModel.filteredInstalledSources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { NativeSettingsSeparator() }
                        AidokuManagementRow {
                            HStack(spacing: 12) {
                                AidokuSourceIconView(
                                    requestID: "installed\u{1f}\(source.sourceID)\u{1f}\(source.version)"
                                ) {
                                    await viewModel.installedSourceIconData(source)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name)
                                        .lineLimit(1)
                                    Text("\(source.sourceID) · v\(source.version) · \(viewModel.compactLanguageSummary(source.languages))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    if let failure = source.lastFailure {
                                        Text(failure)
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        } actions: {
                            Toggle("Direct Media", isOn: Binding(
                                get: { viewModel.usesDirectMediaConnection(sourceID: source.sourceID) },
                                set: { viewModel.setDirectMediaConnection($0, sourceID: source.sourceID) }
                            ))
                            .toggleStyle(.switch)
                            .help("Bypass the macOS system proxy for this source's covers and reading pages.")
                            if source.pendingUpdateVersion != nil {
                                Button("Update") { viewModel.update(source) }.buttonStyle(.glassProminent)
                            }
                            Button("Settings") { viewModel.showSettings(source) }.buttonStyle(.glass)
                            Button("Login") {
                                viewModel.showSettings(source)
                            }.buttonStyle(.glass)
                            Button("Uninstall", role: .destructive) { viewModel.uninstall(source) }.buttonStyle(.glass)
                        }
                    }
                }
            }

            NativeSettingsSectionCard("Available Aidoku Sources") {
                LazyVStack(spacing: 0) {
                    if viewModel.filteredAvailableSources.isEmpty {
                        AidokuManagementRow {
                            if !viewModel.hasActiveSourceFilters {
                                Text("Add a source list to discover Aidoku sources.").foregroundStyle(.secondary)
                            } else {
                                Text("No available Aidoku sources match the current filters.").foregroundStyle(.secondary)
                            }
                        } actions: {
                            EmptyView()
                        }
                    }
                    ForEach(Array(viewModel.filteredAvailableSources.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { NativeSettingsSeparator() }
                        AidokuManagementRow {
                            HStack(spacing: 12) {
                                AidokuSourceIconView(
                                    requestID: "available\u{1f}\(candidate.id)\u{1f}\(candidate.entry.version)\u{1f}\(candidate.entry.iconURL ?? "")"
                                ) {
                                    await viewModel.availableSourceIconData(candidate)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.entry.name).lineLimit(1)
                                    Text("\(candidate.listName) · v\(candidate.entry.version) · \(viewModel.compactLanguageSummary(candidate.entry.languages ?? []))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        } actions: {
                            if viewModel.catalog.installedSources.contains(where: { $0.sourceID == candidate.entry.id }) {
                                Text("Installed").foregroundStyle(.secondary)
                            } else {
                                Button("Install") { viewModel.install(candidate) }.buttonStyle(.glassProminent)
                            }
                        }
                    }
                }
            }
        }
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
        .overlay { if viewModel.isLoading { ProgressView().controlSize(.large) } }
        .aidokuErrorBanner(viewModel)
        .alert("Allow Insecure Source List?", isPresented: Binding(
            get: { viewModel.pendingInsecureSourceListURL != nil },
            set: { if !$0 { viewModel.pendingInsecureSourceListURL = nil } }
        )) {
            Button("Allow") { viewModel.addSourceList(confirmInsecure: true); viewModel.pendingInsecureSourceListURL = nil }
            Button("Cancel", role: .cancel) { viewModel.pendingInsecureSourceListURL = nil }
        } message: {
            Text("HTTP or local-network source lists are not protected by normal HTTPS transport security.")
        }
        .alert("Install Third-Party Aidoku Source?", isPresented: Binding(
            get: { viewModel.pendingPackageURL != nil },
            set: { if !$0 { viewModel.pendingPackageURL = nil } }
        )) {
            Button("Install") { viewModel.confirmLocalImport() }
            Button("Cancel", role: .cancel) { viewModel.pendingPackageURL = nil }
        } message: {
            Text("This package contains third-party WebAssembly code and may contact arbitrary HTTP(S) or local-network services. Install only packages you trust.")
        }
        .alert("Allow Insecure Source Download?", isPresented: Binding(
            get: { viewModel.pendingInsecureSource != nil },
            set: { if !$0 { viewModel.pendingInsecureSource = nil } }
        )) {
            Button("Allow") { viewModel.confirmInsecureInstall() }
            Button("Cancel", role: .cancel) { viewModel.pendingInsecureSource = nil }
        } message: {
            Text("This source package will be downloaded over HTTP or from the local network without normal HTTPS transport protection.")
        }
        .aidokuSourceAccessSheets(viewModel)
    }

    private func presentImporter() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "aix") ?? .zip]
        panel.message = String(localized: "Choose an Aidoku .aix source package.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.requestLocalImport(url)
    }
}

struct AidokuBrowseView: View {
    @Bindable var viewModel: AidokuSourceViewModel
    let activeProfileID: String
    let onOpen: (MangaRemoteReadingRequest) -> Void
    private let columns = [GridItem(.adaptive(minimum: BookshelfLayout.v050CoverWidth, maximum: BookshelfLayout.v050CoverWidth), spacing: BookshelfLayout.columnSpacing)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NativeGlassMenuPicker(selection: Binding(get: { viewModel.selectedSourceID }, set: { viewModel.selectSource($0) }), values: [nil] + viewModel.visibleInstalledSources.map { Optional($0.sourceID) }, minWidth: 170) { id in
                    Text(viewModel.catalog.installedSources.first(where: { $0.sourceID == id })?.name ?? String(localized: "Select Source"))
                }
                if !viewModel.listings.isEmpty {
                    NativeGlassMenuPicker(selection: Binding(get: { viewModel.selectedListingID }, set: { viewModel.selectListing($0) }), values: [nil] + viewModel.listings.map { Optional($0.id) }, minWidth: 140) { id in
                        Text(viewModel.listings.first(where: { $0.id == id })?.name ?? String(localized: "Home"))
                    }
                }
                TextField("Search Manga", text: $viewModel.query).nativeSettingsTextField().onSubmit { viewModel.search() }
                if !viewModel.filters.isEmpty {
                    Menu("Filters") {
                        AidokuFilterMenu(viewModel: viewModel)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                }
                Button("Search") { viewModel.search() }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
            }
            .controlSize(.regular)
            .padding(14)
            Divider()
            if viewModel.selectedSource == nil {
                ContentUnavailableView("No Aidoku Source Selected", systemImage: "books.vertical", description: Text("Install an Aidoku source in Manga Sources."))
            } else if viewModel.browseItems.isEmpty,
                      viewModel.shouldOfferSelectedSourceWebsiteVerification {
                ContentUnavailableView {
                    Label("Website Verification Required", systemImage: "checkmark.shield")
                } description: {
                    Text("Complete the website check before browsing this source.")
                } actions: {
                    Button("Verify Website") { viewModel.requestWebsiteVerification() }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                }
            } else if viewModel.browseItems.isEmpty,
                      viewModel.shouldOfferSelectedSourceLogin {
                ContentUnavailableView {
                    Label("Login Required", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Log in to this source before browsing or reading manga.")
                } actions: {
                    Button("Log In") { viewModel.requestLoginForSelectedSource() }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                }
            } else if viewModel.browseItems.isEmpty,
                      let errorMessage = viewModel.errorMessage {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { viewModel.retryBrowse() }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                }
            } else if viewModel.browseItems.isEmpty,
                      !viewModel.isLoading {
                ContentUnavailableView("No Manga", systemImage: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: BookshelfLayout.rowSpacing) {
                        ForEach(viewModel.browseItems) { manga in
                            AidokuMangaCard(
                                manga: manga,
                                sourceID: viewModel.selectedSourceID,
                                sourceVersion: viewModel.selectedSource?.version ?? 0,
                                revision: viewModel.coverRevision
                            ) { viewModel.showDetails(manga) }
                                .onAppear { viewModel.loadNextPageIfNeeded(current: manga) }
                        }
                        if viewModel.hasNextPage {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .onAppear {
                                    guard let last = viewModel.browseItems.last else { return }
                                    viewModel.loadNextPageIfNeeded(current: last)
                                }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .buttonBorderShape(.capsule)
        .overlay { if viewModel.isLoading { ProgressView().controlSize(.large) } }
        .sheet(item: $viewModel.detail) { manga in
            AidokuMangaDetailView(manga: manga, source: viewModel.selectedSource, viewModel: viewModel, activeProfileID: activeProfileID, onOpen: onOpen)
        }
        .sheet(item: Binding(
            get: {
                viewModel.detail == nil
                    ? viewModel.activeWebsiteVerificationRequest
                    : nil
            },
            set: { value in
                if viewModel.detail == nil {
                    viewModel.activeWebsiteVerificationRequest = value
                }
            }
        )) { request in
            AidokuWebsiteVerificationSheet(request: request, viewModel: viewModel)
        }
        .aidokuErrorBanner(viewModel)
    }
}

struct AidokuLibraryView: View {
    @Bindable var viewModel: AidokuSourceViewModel
    let activeProfileID: String
    let onOpen: (MangaRemoteReadingRequest) -> Void
    private let columns = [GridItem(.adaptive(minimum: BookshelfLayout.v050CoverWidth, maximum: BookshelfLayout.v050CoverWidth), spacing: BookshelfLayout.columnSpacing)]

    var body: some View {
        Group {
            if viewModel.visibleLibrary.isEmpty {
                ContentUnavailableView("Aidoku Library Is Empty", systemImage: "books.vertical", description: Text("Add manga from Aidoku Browse."))
            } else {
                ScrollView {
                    HStack { Text("Aidoku Library").font(.title2.bold()); Spacer(); Button("Refresh") { viewModel.load() }.buttonStyle(.glass) }.padding([.horizontal, .top], 22)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: BookshelfLayout.rowSpacing) {
                        ForEach(viewModel.visibleLibrary) { entry in
                            AidokuMangaCard(
                                manga: entry.manga,
                                sourceID: entry.sourceID,
                                sourceVersion: viewModel.sourceRecord(for: entry)?.version ?? 0,
                                revision: viewModel.coverRevision
                            ) {
                                guard let source = viewModel.sourceRecord(for: entry) else { return }
                                onOpen(viewModel.prepareReading(source: source, manga: entry.manga, profileID: activeProfileID))
                            }
                            .opacity(viewModel.sourceRecord(for: entry) == nil ? 0.55 : 1)
                            .contextMenu {
                                if viewModel.sourceRecord(for: entry) == nil { Text("Source Unavailable") }
                                Button("Remove from Library", role: .destructive) {
                                    if let source = viewModel.sourceRecord(for: entry) { viewModel.toggleLibrary(source: source, manga: entry.manga) }
                                }
                            }
                        }
                    }.padding(22)
                }
            }
        }
        .overlay { if viewModel.isLoading { ProgressView().controlSize(.large) } }
        .aidokuErrorBanner(viewModel)
    }
}

private struct AidokuFilterMenu: View {
    @Bindable var viewModel: AidokuSourceViewModel

    var body: some View {
        ForEach(viewModel.filters) { filter in
            switch filter {
            case .header(_, let title):
                Text(title)
            case .text(let id, let title, let placeholder):
                TextField(
                    placeholder ?? title,
                    text: Binding(
                        get: {
                            guard case .text(let value) = viewModel.filterValues[id] else { return "" }
                            return value
                        },
                        set: { viewModel.filterValues[id] = .text($0) }
                    )
                )
            case .check(let id, let title, let canExclude, let defaultValue):
                if canExclude {
                    Picker(title, selection: Binding(
                        get: { if case .check(let value) = viewModel.filterValues[id] { return value }; return defaultValue },
                        set: { viewModel.filterValues[id] = .check($0) }
                    )) {
                        Text("Any").tag(0)
                        Text("Include").tag(1)
                        Text("Exclude").tag(-1)
                    }
                } else {
                    Toggle(title, isOn: Binding(
                        get: { if case .check(let value) = viewModel.filterValues[id] { return value > 0 }; return defaultValue != 0 },
                        set: { viewModel.filterValues[id] = .check($0 ? 1 : 0) }
                    ))
                }
            case .select(let id, let title, let options, let values, let defaultValue):
                Picker(title, selection: Binding(
                    get: {
                        guard case .select(let value) = viewModel.filterValues[id] else { return defaultValue ?? values.first ?? "" }
                        return value
                    },
                    set: { viewModel.filterValues[id] = .select($0) }
                )) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(options[index]).tag(values.indices.contains(index) ? values[index] : options[index])
                    }
                }
            case .multiSelect(let id, let title, let options, let values):
                Menu(title) {
                    ForEach(options.indices, id: \.self) { index in
                        let value = values.indices.contains(index) ? values[index] : options[index]
                        Toggle(options[index], isOn: Binding(
                            get: {
                                guard case .multiSelect(let included, _) = viewModel.filterValues[id] else { return false }
                                return included.contains(value)
                            },
                            set: { enabled in
                                var included: Set<String> = []
                                var excluded: Set<String> = []
                                if case .multiSelect(let currentIncluded, let currentExcluded) = viewModel.filterValues[id] {
                                    included = currentIncluded; excluded = currentExcluded
                                }
                                if enabled { included.insert(value); excluded.remove(value) } else { included.remove(value) }
                                viewModel.filterValues[id] = .multiSelect(include: included, exclude: excluded)
                            }
                        ))
                    }
                }
            case .sort(let id, let title, let options, let canAscend):
                Picker(title, selection: Binding(
                    get: {
                        guard case .sort(let index, _) = viewModel.filterValues[id] else { return 0 }
                        return index
                    },
                    set: { index in viewModel.filterValues[id] = .sort(index: index, ascending: canAscend) }
                )) {
                    ForEach(options.indices, id: \.self) { index in Text(options[index]).tag(index) }
                }
            case .range(let id, let title, let minimum, let maximum, _):
                TextField("\(title) (min)", text: rangeBinding(id: id, lower: true, fallback: minimum))
                TextField("\(title) (max)", text: rangeBinding(id: id, lower: false, fallback: maximum))
            }
        }
    }

    private func rangeBinding(id: String, lower: Bool, fallback: Float?) -> Binding<String> {
        Binding(
            get: {
                guard case .range(let currentLower, let currentUpper) = viewModel.filterValues[id] else {
                    return fallback.map { String($0) } ?? ""
                }
                return (lower ? currentLower : currentUpper).map { String($0) } ?? ""
            },
            set: { text in
                var currentLower: Float?
                var currentUpper: Float?
                if case .range(let savedLower, let savedUpper) = viewModel.filterValues[id] {
                    currentLower = savedLower; currentUpper = savedUpper
                }
                if lower { currentLower = Float(text) } else { currentUpper = Float(text) }
                viewModel.filterValues[id] = .range(lower: currentLower, upper: currentUpper)
            }
        )
    }
}

struct AidokuSourceSettingsSheet: View {
    let source: AidokuInstalledSourceRecord
    @Bindable var viewModel: AidokuSourceViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings for \(source.name)").font(.title2.bold())
                Spacer()
                Button("Close") { viewModel.settingsSource = nil }.buttonStyle(.glass)
            }.padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let selection = viewModel.settingsLanguageSelection {
                        languageSelectionRow(selection)
                        if !viewModel.sourceSettings.isEmpty { Divider() }
                    }
                    if viewModel.sourceSettings.isEmpty,
                       viewModel.settingsLanguageSelection == nil {
                        Text("This source has no configurable settings.").foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.sourceSettings) { setting in
                        settingRow(setting)
                    }
                }.padding(24)
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder
    private func languageSelectionRow(_ selection: AidokuSourceLanguageSelection) -> some View {
        switch selection.type {
        case .single:
            LabeledContent("Content Language") {
                NativeGlassMenuPicker(
                    selection: Binding(
                        get: { selection.selectedLanguages.first ?? selection.supportedLanguages.first ?? "" },
                        set: { viewModel.selectContentLanguage($0, sourceID: source.sourceID) }
                    ),
                    values: selection.supportedLanguages,
                    minWidth: 220
                ) { language in
                    Text(viewModel.languageDisplayName(language))
                }
            }
        case .multiple:
            LabeledContent("Content Languages") {
                Menu {
                    ForEach(selection.supportedLanguages, id: \.self) { language in
                        let selected = selection.selectedLanguages.contains {
                            $0.caseInsensitiveCompare(language) == .orderedSame
                        }
                        Toggle(viewModel.languageDisplayName(language), isOn: Binding(
                            get: { selected },
                            set: {
                                viewModel.toggleContentLanguage(
                                    language,
                                    enabled: $0,
                                    sourceID: source.sourceID
                                )
                            }
                        ))
                        .disabled(selected && selection.selectedLanguages.count == 1)
                    }
                } label: {
                    Text(viewModel.languageSummary(selection.selectedLanguages))
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .frame(minWidth: 240)
                .help("Choose at least one language for this source.")
            }
        }
    }

    @ViewBuilder
    private func settingRow(_ setting: AidokuSetting) -> some View {
        switch setting {
        case .header(_, let title):
            Text(title).font(.headline)
        case .switchValue(let id, let title, _, _):
            Toggle(title, isOn: Binding(
                get: { viewModel.sourceSettingValues[id] == "true" },
                set: { viewModel.sourceSettingValues[id] = $0 ? "true" : "false"; viewModel.saveSetting(setting, sourceID: source.sourceID) }
            ))
        case .select(let id, let title, let values, let labels, _):
            let displayedTitle = id == "url" && title.isEmpty ? String(localized: "Base URL") : title
            LabeledContent(displayedTitle) {
                NativeGlassMenuPicker(
                    selection: Binding(
                        get: { viewModel.sourceSettingValues[id] ?? values.first ?? "" },
                        set: {
                            viewModel.sourceSettingValues[id] = $0
                            viewModel.saveSetting(setting, sourceID: source.sourceID)
                        }
                    ),
                    values: values,
                    minWidth: 220
                ) { value in
                    let index = values.firstIndex(of: value)
                    Text(index.flatMap { labels.indices.contains($0) ? labels[$0] : nil } ?? value)
                }
            }
        case .multiSelect(let id, let title, let values, let labels, _):
            LabeledContent(title) {
                Menu {
                    ForEach(values.indices, id: \.self) { index in
                        let value = values[index]
                        let selected = viewModel.sourceSettingListValues[id]?.contains(value) == true
                        Button {
                            viewModel.toggleSettingOption(
                                value,
                                enabled: !selected,
                                setting: setting,
                                sourceID: source.sourceID
                            )
                        } label: {
                            Label(
                                labels.indices.contains(index) ? labels[index] : value,
                                systemImage: selected ? "checkmark" : "circle"
                            )
                        }
                    }
                } label: {
                    Text(viewModel.sourceSettingListValues[id]?.isEmpty == false
                         ? viewModel.sourceSettingListValues[id]!.joined(separator: ", ")
                         : String(localized: "None"))
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            }
        case .segment(let id, let title, let options, _):
            LabeledContent(title) {
                NativeGlassSegmentedPicker(
                    selection: Binding(
                        get: { Int32(viewModel.sourceSettingValues[id] ?? "") ?? 0 },
                        set: {
                            viewModel.sourceSettingValues[id] = String($0)
                            viewModel.saveSetting(setting, sourceID: source.sourceID)
                        }
                    ),
                    values: options.indices.map { Int32($0) },
                    minSegmentWidth: 68
                ) { index in
                    Text(options.indices.contains(Int(index)) ? options[Int(index)] : String(index))
                }
            }
        case .text(let id, let title, _, let secure):
            LabeledContent(title) {
                if secure {
                    SecureField(title, text: Binding(get: { viewModel.sourceSettingValues[id] ?? "" }, set: { viewModel.sourceSettingValues[id] = $0 }))
                        .nativeSettingsTextField().onSubmit { viewModel.saveSetting(setting, sourceID: source.sourceID) }
                } else {
                    TextField(title, text: Binding(get: { viewModel.sourceSettingValues[id] ?? "" }, set: { viewModel.sourceSettingValues[id] = $0 }))
                        .nativeSettingsTextField().onSubmit { viewModel.saveSetting(setting, sourceID: source.sourceID) }
                }
            }
        case .stepper(let id, let title, _, let minimum, let maximum, let step):
            Stepper(title, value: Binding(
                get: { Double(viewModel.sourceSettingValues[id] ?? "") ?? minimum },
                set: { viewModel.sourceSettingValues[id] = String($0); viewModel.saveSetting(setting, sourceID: source.sourceID) }
            ), in: minimum...maximum, step: step)
        case .editableList(let id, let title, let placeholder, _):
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                ForEach(Array((viewModel.sourceSettingListValues[id] ?? []).enumerated()), id: \.offset) { index, value in
                    HStack {
                        TextField(title, text: Binding(
                            get: {
                                let values = viewModel.sourceSettingListValues[id] ?? []
                                return values.indices.contains(index) ? values[index] : value
                            },
                            set: {
                                viewModel.updateEditableListItem(
                                    $0,
                                    index: index,
                                    setting: setting,
                                    sourceID: source.sourceID
                                )
                            }
                        ))
                        .nativeSettingsTextField()
                        Button("Remove", systemImage: "minus.circle") {
                            viewModel.removeEditableListItem(
                                index: index,
                                setting: setting,
                                sourceID: source.sourceID
                            )
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                    }
                }
                HStack {
                    TextField(
                        placeholder ?? title,
                        text: Binding(
                            get: { viewModel.sourceSettingListDrafts[id] ?? "" },
                            set: { viewModel.sourceSettingListDrafts[id] = $0 }
                        )
                    )
                    .nativeSettingsTextField()
                    .onSubmit {
                        viewModel.addEditableListItem(setting: setting, sourceID: source.sourceID)
                    }
                    Button("Add", systemImage: "plus.circle") {
                        viewModel.addEditableListItem(setting: setting, sourceID: source.sourceID)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                }
            }
        case .login(let configuration):
            Button(configuration.title.isEmpty ? String(localized: "Login") : configuration.title) { viewModel.login(configuration, source: source) }.buttonStyle(.glass)
        }
    }
}

struct AidokuWebLoginRequest: Identifiable {
    let id = UUID()
    let source: AidokuInstalledSourceRecord
    let configuration: AidokuLoginConfiguration
    let url: URL
    let userAgent: String
}

enum AidokuWebsiteVerificationRetryTarget: Sendable, Equatable {
    case browse
    case details(mangaKey: String)
    case discovery(workID: String)
}

struct AidokuWebsiteVerificationSheetRequest: Identifiable, Sendable {
    let id: UUID
    let source: AidokuInstalledSourceRecord
    let runtimeRequest: AidokuWebsiteVerificationRequest
    let existingCookies: [AidokuStoredCookie]
    let retryTarget: AidokuWebsiteVerificationRetryTarget

    init(
        id: UUID = UUID(),
        source: AidokuInstalledSourceRecord,
        runtimeRequest: AidokuWebsiteVerificationRequest,
        existingCookies: [AidokuStoredCookie],
        retryTarget: AidokuWebsiteVerificationRetryTarget
    ) {
        self.id = id
        self.source = source
        self.runtimeRequest = runtimeRequest
        self.existingCookies = existingCookies
        self.retryTarget = retryTarget
    }

    func withFreshPresentationID() -> Self {
        Self(
            source: source,
            runtimeRequest: runtimeRequest,
            existingCookies: existingCookies,
            retryTarget: retryTarget
        )
    }
}

struct AidokuWebLoginSheet: View {
    let request: AidokuWebLoginRequest
    @Bindable var viewModel: AidokuSourceViewModel
    @State private var cookieStore: WKHTTPCookieStore?
    @State private var webView: WKWebView?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(request.configuration.title.isEmpty ? String(localized: "Web Login") : request.configuration.title).font(.title2.bold())
                Spacer()
                Button("Cancel") { viewModel.webLoginRequest = nil }.buttonStyle(.glass)
                Button("Finish Login") { finish() }.buttonStyle(.glassProminent)
            }.padding()
            Divider()
            AidokuLoginWebView(url: request.url, userAgent: request.userAgent) { cookieStore, webView in
                self.cookieStore = cookieStore
                self.webView = webView
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
    }

    private func finish() {
        cookieStore?.getAllCookies { cookies in
            guard let webView else { return }
            webView.evaluateJavaScript("navigator.userAgent") { userAgentValue, _ in
                let evaluatedUserAgent = (userAgentValue as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let userAgent = evaluatedUserAgent?.isEmpty == false
                    ? evaluatedUserAgent!
                    : request.userAgent
                guard let script = AidokuWebLoginValues.localStorageReadScript(
                    keys: request.configuration.localStorageKeys
                ) else {
                    Task { @MainActor in
                        viewModel.finishWebLogin(
                            request,
                            cookies: cookies,
                            localStorage: [:],
                            userAgent: userAgent
                        )
                    }
                    return
                }
                webView.evaluateJavaScript(script) { result, _ in
                    let localStorage = AidokuWebLoginValues.decodedLocalStorageValues(result)
                    Task { @MainActor in
                        viewModel.finishWebLogin(
                            request,
                            cookies: cookies,
                            localStorage: localStorage,
                            userAgent: userAgent
                        )
                    }
                }
            }
        }
    }
}

private struct AidokuLoginWebView: NSViewRepresentable {
    let url: URL
    let userAgent: String
    let onReady: (WKHTTPCookieStore, WKWebView) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent
        onReady(configuration.websiteDataStore.httpCookieStore, webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

private struct AidokuWebsiteVerificationNavigationState: Equatable {
    var statusCode: Int?
    var didFinishMainFrame = false
}

struct AidokuWebsiteVerificationSheet: View {
    let request: AidokuWebsiteVerificationSheetRequest
    @Bindable var viewModel: AidokuSourceViewModel

    @State private var cookieStore: WKHTTPCookieStore?
    @State private var webView: WKWebView?
    @State private var navigationState = AidokuWebsiteVerificationNavigationState()
    @State private var lifecycleGeneration = UUID()
    @State private var isActive = true
    @State private var automaticCheckTask: Task<Void, Never>?
    @State private var checkTask: Task<Void, Never>?
    @State private var submitTask: Task<Void, Never>?
    @State private var isChecking = false
    @State private var didSubmit = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Website Verification").font(.title2.bold())
                    Text(request.source.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isChecking || didSubmit { ProgressView().controlSize(.small) }
                Button("Cancel") { cancel() }
                    .buttonStyle(.glass)
                    .disabled(didSubmit)
                Button("Complete Verification") { checkVerification(showFailure: true) }
                    .buttonStyle(.glassProminent)
                    .disabled(webView == nil || cookieStore == nil || isChecking || didSubmit)
            }
            .padding()
            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            }
            Divider()
            AidokuWebsiteVerificationWebView(
                request: request.runtimeRequest,
                existingCookies: request.existingCookies
            ) { cookieStore, webView in
                guard isCurrent(lifecycleGeneration) else { return }
                self.cookieStore = cookieStore
                self.webView = webView
            } onStateChange: { navigationState in
                guard isCurrent(lifecycleGeneration) else { return }
                self.navigationState = navigationState
                scheduleAutomaticCheck()
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
        .onAppear {
            statusMessage = String(localized: "Complete the website check in the page below.")
        }
        .interactiveDismissDisabled(didSubmit)
        .onDisappear {
            invalidateLifecycle()
            viewModel.cancelWebsiteVerification(requestID: request.id)
        }
    }

    private func scheduleAutomaticCheck() {
        guard isCurrent(lifecycleGeneration), !didSubmit else { return }
        automaticCheckTask?.cancel()
        checkTask?.cancel()
        isChecking = false
        let generation = lifecycleGeneration
        automaticCheckTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, isCurrent(generation) else { return }
            checkVerification(showFailure: false)
        }
    }

    private func checkVerification(showFailure: Bool) {
        guard isCurrent(lifecycleGeneration), !isChecking, !didSubmit,
              let cookieStore, let webView else { return }
        automaticCheckTask?.cancel()
        let generation = lifecycleGeneration
        isChecking = true
        checkTask?.cancel()
        checkTask = Task { @MainActor in
            let cookies = await allCookies(in: cookieStore)
            guard !Task.isCancelled, isCurrent(generation) else { return }
            let scriptValue: Any?
            do {
                scriptValue = try await webView.evaluateJavaScript(
                    AidokuWebLoginValues.verificationStateScript
                )
            } catch {
                guard !Task.isCancelled, isCurrent(generation) else { return }
                isChecking = false
                if showFailure {
                    statusMessage = String(localized: "Website verification has not finished yet.")
                }
                return
            }
            guard !Task.isCancelled, isCurrent(generation) else { return }
            isChecking = false
            finishVerificationCheck(
                cookies: cookies,
                scriptValue: scriptValue,
                showFailure: showFailure,
                generation: generation
            )
        }
    }

    private func finishVerificationCheck(
        cookies: [HTTPCookie],
        scriptValue: Any?,
        showFailure: Bool,
        generation: UUID
    ) {
        guard isCurrent(generation), !didSubmit else { return }
        guard let state = AidokuWebLoginValues.verificationState(scriptValue) else {
            if showFailure {
                statusMessage = String(localized: "Website verification has not finished yet.")
            }
            return
        }
        guard navigationState.didFinishMainFrame,
              (navigationState.statusCode.map { ![403, 503].contains($0) } ?? true),
              !state.challenge else {
            if showFailure {
                statusMessage = String(localized: "Website verification has not finished yet.")
            }
            return
        }
        guard state.userAgent == request.runtimeRequest.userAgent else {
            if showFailure {
                statusMessage = String(
                    localized: "The website user agent changed during verification. Please try again."
                )
            }
            return
        }
        guard AidokuWebLoginValues.hasNewOrChangedClearanceCookie(
            cookies,
            verificationURL: request.runtimeRequest.url,
            existingCookies: request.existingCookies,
            requestHeaders: request.runtimeRequest.headers
        ) else {
            if showFailure {
                statusMessage = String(
                    localized: "The website did not provide a new verification cookie."
                )
            }
            return
        }

        didSubmit = true
        statusMessage = nil
        automaticCheckTask?.cancel()
        checkTask?.cancel()
        submitTask = Task { @MainActor in
            let saved = await viewModel.finishWebsiteVerification(
                request,
                cookies: cookies,
                userAgent: state.userAgent
            )
            guard !Task.isCancelled, isCurrent(generation) else { return }
            if !saved {
                didSubmit = false
                statusMessage = String(localized: "Website verification could not be saved. Try again.")
            }
        }
    }

    private func allCookies(in cookieStore: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        isActive
            && lifecycleGeneration == generation
            && viewModel.isWebsiteVerificationActive(request)
    }

    private func cancel() {
        guard !didSubmit else { return }
        invalidateLifecycle()
        viewModel.cancelWebsiteVerification(requestID: request.id)
    }

    private func invalidateLifecycle() {
        guard isActive else { return }
        isActive = false
        lifecycleGeneration = UUID()
        automaticCheckTask?.cancel()
        checkTask?.cancel()
        submitTask?.cancel()
        automaticCheckTask = nil
        checkTask = nil
        submitTask = nil
        webView?.stopLoading()
        webView = nil
        cookieStore = nil
    }
}

private struct AidokuWebsiteVerificationWebView: NSViewRepresentable {
    let request: AidokuWebsiteVerificationRequest
    let existingCookies: [AidokuStoredCookie]
    let onReady: (WKHTTPCookieStore, WKWebView) -> Void
    let onStateChange: (AidokuWebsiteVerificationNavigationState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            verificationURL: request.url,
            onStateChange: onStateChange
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Aidoku's Cloudflare handler uses the default persistent WebKit
        // store. Managed Turnstile challenges can reject private or isolated
        // browsing stores even when the UA string is identical.
        let dataStore = WKWebsiteDataStore.default()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = request.userAgent
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: dataStore.httpCookieStore)
        context.coordinator.deliverReady(
            cookieStore: dataStore.httpCookieStore,
            webView: webView,
            callback: onReady
        )
        context.coordinator.load(
            request: request,
            cookies: existingCookies,
            in: webView
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.detach()
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        private let verificationURL: URL
        private let onStateChange: (AidokuWebsiteVerificationNavigationState) -> Void
        private weak var cookieStore: WKHTTPCookieStore?
        private var navigationState = AidokuWebsiteVerificationNavigationState()
        private var visitedHosts: Set<String> = []
        private var isActive = true

        init(
            verificationURL: URL,
            onStateChange: @escaping (AidokuWebsiteVerificationNavigationState) -> Void
        ) {
            self.verificationURL = verificationURL
            self.onStateChange = onStateChange
            if let host = verificationURL.host?.lowercased() {
                visitedHosts.insert(host)
            }
        }

        func attach(to cookieStore: WKHTTPCookieStore) {
            self.cookieStore = cookieStore
            cookieStore.add(self)
        }

        func detach() {
            isActive = false
            cookieStore?.remove(self)
            cookieStore = nil
            Self.clearVerificationData(for: visitedHosts)
        }

        private static func clearVerificationData(for hosts: Set<String>) {
            guard !hosts.isEmpty else { return }
            DispatchQueue.main.async {
                let dataStore = WKWebsiteDataStore.default()
                dataStore.httpCookieStore.getAllCookies { cookies in
                    for cookie in cookies where hosts.contains(where: {
                        Self.cookieDomain(cookie.domain, matches: $0)
                    }) {
                        dataStore.httpCookieStore.delete(cookie)
                    }
                }
                let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
                dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                    let matchingRecords = records.filter { record in
                        let name = record.displayName.lowercased()
                        return hosts.contains {
                            name == $0 || name.hasSuffix(".\($0)") || $0.hasSuffix(".\(name)")
                        }
                    }
                    guard !matchingRecords.isEmpty else { return }
                    dataStore.removeData(
                        ofTypes: dataTypes,
                        for: matchingRecords,
                        completionHandler: {}
                    )
                }
            }
        }

        private static func cookieDomain(_ value: String, matches host: String) -> Bool {
            let domain = value
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix(".\(domain)")
        }

        func deliverReady(
            cookieStore: WKHTTPCookieStore,
            webView: WKWebView,
            callback: @escaping (WKHTTPCookieStore, WKWebView) -> Void
        ) {
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, self.isActive, let webView else { return }
                callback(cookieStore, webView)
            }
        }

        func load(
            request: AidokuWebsiteVerificationRequest,
            cookies: [AidokuStoredCookie],
            in webView: WKWebView
        ) {
            let httpCookies = AidokuWebLoginValues.httpCookies(
                cookies,
                for: request.url
            )
            setCookies(httpCookies, index: 0) { [weak self, weak webView] in
                guard let self, self.isActive, let webView else { return }
                var urlRequest = URLRequest(url: request.url)
                urlRequest.httpMethod = request.method
                urlRequest.httpBody = request.body
                for (key, value) in request.headers {
                    urlRequest.setValue(value, forHTTPHeaderField: key)
                }
                urlRequest.setValue(request.userAgent, forHTTPHeaderField: "User-Agent")
                webView.load(urlRequest)
            }
        }

        private func setCookies(
            _ cookies: [HTTPCookie],
            index: Int,
            completion: @escaping () -> Void
        ) {
            guard isActive else { return }
            guard cookies.indices.contains(index), let cookieStore else {
                completion()
                return
            }
            cookieStore.setCookie(cookies[index]) { [weak self] in
                self?.setCookies(cookies, index: index + 1, completion: completion)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            if let host = navigationResponse.response.url?.host?.lowercased() {
                visitedHosts.insert(host)
            }
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse {
                navigationState.statusCode = response.statusCode
                navigationState.didFinishMainFrame = false
                notifyStateChange()
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            navigationState.didFinishMainFrame = true
            notifyStateChange()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            navigationState.didFinishMainFrame = false
            notifyStateChange()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            navigationState.didFinishMainFrame = false
            notifyStateChange()
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            notifyStateChange()
        }

        private func notifyStateChange() {
            guard isActive else { return }
            onStateChange(navigationState)
        }
    }
}

private enum AidokuWebLoginValues {
    struct VerificationState: Decodable {
        let userAgent: String
        let challenge: Bool
    }

    static let verificationStateScript = """
    (() => JSON.stringify({
      userAgent: navigator.userAgent || "",
      challenge:
        document.querySelector('input[name="cf-turnstile-response"]') !== null ||
        document.getElementById('challenge-error-title') !== null ||
        document.getElementById('challenge-error-text') !== null
    }))()
    """

    static func relevantCookies(_ cookies: [HTTPCookie], loginURL: URL) -> [HTTPCookie] {
        guard let loginHost = loginURL.host?.lowercased() else { return [] }
        return cookies.filter { cookie in
            cookieDomain(cookie.domain, matchesHost: loginHost)
        }
    }

    static func httpCookies(
        _ cookies: [AidokuStoredCookie],
        for url: URL
    ) -> [HTTPCookie] {
        cookies.filter { storedCookie($0, appliesTo: url) }.compactMap { cookie in
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name,
                .value: cookie.value,
                .domain: cookie.domain,
                .path: cookie.path.isEmpty ? "/" : cookie.path,
                .secure: cookie.secure ? "TRUE" : "FALSE",
            ]
            if let expiresAt = cookie.expiresAt { properties[.expires] = expiresAt }
            return HTTPCookie(properties: properties)
        }
    }

    static func hasNewOrChangedClearanceCookie(
        _ cookies: [HTTPCookie],
        verificationURL: URL,
        existingCookies: [AidokuStoredCookie],
        requestHeaders: [String: String]
    ) -> Bool {
        var previousValues = Set(
            existingCookies.filter {
                $0.name == "cf_clearance" && storedCookie($0, appliesTo: verificationURL)
            }.map(\.value)
        )
        if let cookieHeader = requestHeaders.first(where: {
            $0.key.caseInsensitiveCompare("Cookie") == .orderedSame
        })?.value {
            previousValues.formUnion(cookieValues(named: "cf_clearance", in: cookieHeader))
        }
        let now = Date()
        return cookies.contains { cookie in
            cookie.name == "cf_clearance"
                && !cookie.value.isEmpty
                && httpCookie(cookie, appliesTo: verificationURL, now: now)
                && !previousValues.contains(cookie.value)
        }
    }

    static func verificationState(_ value: Any?) -> VerificationState? {
        guard let string = value as? String,
              let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VerificationState.self, from: data)
    }

    static func mergedValues(cookies: [HTTPCookie], localStorage: [String: String]) -> [String: String] {
        var values = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0.value) })
        // A declared local-storage key is an explicit source contract, so it wins
        // over a same-named cookie when both are present.
        values.merge(localStorage) { _, localStorageValue in localStorageValue }
        return values
    }

    static func localStorageReadScript(keys: [String]) -> String? {
        let distinctKeys = Array(Set(keys.filter { !$0.isEmpty })).sorted()
        guard !distinctKeys.isEmpty,
              let data = try? JSONEncoder().encode(distinctKeys),
              let literal = String(data: data, encoding: .utf8) else { return nil }
        return """
        (() => {
          const keys = \(literal);
          const values = {};
          for (const key of keys) {
            try {
              const value = window.localStorage.getItem(key);
              if (typeof value === "string") values[key] = value;
            } catch (_) {}
          }
          return JSON.stringify(values);
        })()
        """
    }

    static func decodedLocalStorageValues(_ result: Any?) -> [String: String] {
        guard let string = result as? String,
              let data = string.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return values
    }

    private static func storedCookie(
        _ cookie: AidokuStoredCookie,
        appliesTo url: URL
    ) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return cookieDomain(cookie.domain, matchesHost: host)
            && (cookie.expiresAt.map { $0 > Date() } ?? true)
            && (!cookie.secure || url.scheme?.lowercased() == "https")
            && cookiePath(cookie.path, matchesRequestPath: url.path)
    }

    private static func httpCookie(
        _ cookie: HTTPCookie,
        appliesTo url: URL,
        now: Date
    ) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return cookieDomain(cookie.domain, matchesHost: host)
            && (cookie.expiresDate.map { $0 > now } ?? true)
            && (!cookie.isSecure || url.scheme?.lowercased() == "https")
            && cookiePath(cookie.path, matchesRequestPath: url.path)
    }

    private static func cookieDomain(_ rawDomain: String, matchesHost host: String) -> Bool {
        let rawDomain = rawDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !rawDomain.isEmpty else { return false }
        if rawDomain.hasPrefix(".") {
            let domain = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !domain.isEmpty && (host == domain || host.hasSuffix(".\(domain)"))
        }
        return host == rawDomain
    }

    private static func cookiePath(
        _ rawCookiePath: String,
        matchesRequestPath rawRequestPath: String
    ) -> Bool {
        let cookiePath = rawCookiePath.isEmpty ? "/" : rawCookiePath
        let requestPath = rawRequestPath.isEmpty ? "/" : rawRequestPath
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return boundary < requestPath.endIndex && requestPath[boundary] == "/"
    }

    private static func cookieValues(named name: String, in header: String) -> Set<String> {
        Set(header.split(separator: ";").compactMap { part in
            let components = part.split(separator: "=", maxSplits: 1)
            guard components.count == 2,
                  components[0].trimmingCharacters(in: .whitespacesAndNewlines) == name else {
                return nil
            }
            let value = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })
    }
}

private extension AidokuStoredCookie {
    init(_ cookie: HTTPCookie) {
        self.init(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            secure: cookie.isSecure,
            expiresAt: cookie.expiresDate
        )
    }
}

private struct AidokuMangaCard: View {
    let manga: AidokuManga
    let sourceID: String?
    let sourceVersion: Int
    let revision: UUID
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ShelfBookCard(title: manga.title, progress: nil) {
                AidokuCoverView(
                    manga: manga,
                    sourceID: sourceID,
                    sourceVersion: sourceVersion,
                    revision: revision
                )
            }
            .contentShape(.rect)
        }.buttonStyle(.plain)
    }
}

struct AidokuCoverView: View {
    let manga: AidokuManga
    let sourceID: String?
    let sourceVersion: Int
    let revision: UUID
    @State private var image: NSImage?
    @State private var didFail = false
    var body: some View {
        ZStack {
            Color.gray.opacity(0.3)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else {
                Image(systemName: didFail ? "book.closed.fill" : "book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(0.709, contentMode: .fit).clipped()
        .task(id: "\(sourceID ?? "")\u{1f}\(sourceVersion)\u{1f}\(revision)\u{1f}\(manga.key)\u{1f}\(manga.coverURL ?? "")") {
            image = nil
            didFail = false
            guard let sourceID else { return }
            do {
                let data = try await AidokuGlobalStore.shared.coverData(
                    sourceID: sourceID,
                    manga: manga
                )
                try Task.checkCancellation()
                guard let loaded = NSImage(data: data) else {
                    throw AidokuRuntimeError.runtimeFailure(String(localized: "Cached cover could not be decoded"))
                }
                image = loaded
                didFail = false
            } catch is CancellationError {
                return
            } catch AidokuRuntimeError.cancelled {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                didFail = true
            }
        }
    }
}

private struct AidokuMangaDetailView: View {
    let manga: AidokuManga
    let source: AidokuInstalledSourceRecord?
    @Bindable var viewModel: AidokuSourceViewModel
    let activeProfileID: String
    let onOpen: (MangaRemoteReadingRequest) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(manga.title).font(.title2.bold()); Spacer(); Button("Close") { viewModel.dismissDetails() }.buttonStyle(.glass) }.padding()
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AidokuCoverView(
                            manga: manga,
                            sourceID: source?.sourceID,
                            sourceVersion: source?.version ?? 0,
                            revision: viewModel.coverRevision
                        ).frame(maxWidth: 300)
                        if let authors = manga.authors, !authors.isEmpty { LabeledContent("Author", value: authors.joined(separator: ", ")) }
                        if let summary = manga.summary, !summary.isEmpty { Text(summary).textSelection(.enabled) }
                        if let source {
                            HStack {
                                Button("Read") { onOpen(viewModel.prepareReading(source: source, manga: manga, profileID: activeProfileID)) }.buttonStyle(.glassProminent)
                                    .disabled(manga.chapters?.contains(where: { !$0.locked }) != true)
                                Button(viewModel.isInLibrary(sourceID: source.sourceID, mangaKey: manga.key) ? "Remove from Library" : "Add to Library") { viewModel.toggleLibrary(source: source, manga: manga) }.buttonStyle(.glass)
                            }
                        }
                    }.padding()
                }.frame(minWidth: 320)
                Group {
                    if viewModel.isDetailLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading Chapters").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let message = viewModel.detailErrorMessage {
                        ContentUnavailableView {
                            Label("Chapters Unavailable", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(message)
                        } actions: {
                            if viewModel.shouldOfferSelectedSourceWebsiteVerification {
                                Button("Verify Website") {
                                    viewModel.requestWebsiteVerification()
                                }
                                .buttonStyle(.glassProminent)
                            }
                            Button("Retry") { viewModel.retryDetails() }.buttonStyle(.glassProminent)
                        }
                    } else {
                        List(manga.chapters ?? []) { chapter in
                            Button {
                                guard let source else { return }
                                onOpen(viewModel.prepareReading(source: source, manga: manga, initialChapterKey: chapter.key, profileID: activeProfileID))
                            } label: {
                                HStack {
                                    Text(chapter.title ?? chapter.chapterNumber.map { String(localized: "Chapter \($0.formatted())") } ?? chapter.key)
                                    Spacer()
                                    if chapter.locked {
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(.secondary)
                                            .help("Locked")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(chapter.locked)
                        }
                    }
                }.frame(minWidth: 360)
            }
        }
        .frame(minWidth: 960, minHeight: 680)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
        .sheet(item: Binding(
            get: {
                viewModel.detail != nil
                    ? viewModel.activeWebsiteVerificationRequest
                    : nil
            },
            set: { value in
                if viewModel.detail != nil {
                    viewModel.activeWebsiteVerificationRequest = value
                }
            }
        )) { request in
            AidokuWebsiteVerificationSheet(request: request, viewModel: viewModel)
        }
    }
}

private struct AidokuSourceAccessSheetsModifier: ViewModifier {
    @Bindable var viewModel: AidokuSourceViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $viewModel.sourceForLogin) { source in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Login to \(source.name)").font(.title2.bold())
                    TextField("Username", text: $viewModel.usernameDraft)
                        .nativeSettingsTextField()
                    SecureField("Password", text: $viewModel.passwordDraft)
                        .nativeSettingsTextField()
                    HStack {
                        Spacer()
                        Button("Cancel") { viewModel.cancelBasicLogin() }
                            .buttonStyle(.glass)
                        Button("Login") { viewModel.basicLogin() }
                            .buttonStyle(.glassProminent)
                    }
                }
                .padding(24)
                .frame(minWidth: 460)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
            }
            .sheet(item: $viewModel.settingsSource) { source in
                AidokuSourceSettingsSheet(source: source, viewModel: viewModel)
            }
            .sheet(item: $viewModel.webLoginRequest) { request in
                AidokuWebLoginSheet(request: request, viewModel: viewModel)
            }
    }
}

extension View {
    func aidokuSourceAccessSheets(_ viewModel: AidokuSourceViewModel) -> some View {
        modifier(AidokuSourceAccessSheetsModifier(viewModel: viewModel))
    }
}

private extension View {
    func aidokuErrorBanner(_ viewModel: AidokuSourceViewModel) -> some View {
        overlay(alignment: .topTrailing) {
            if let message = viewModel.errorMessage {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Aidoku Error").font(.headline)
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    if viewModel.shouldOfferSelectedSourceWebsiteVerification {
                        Button("Verify Website") { viewModel.requestWebsiteVerification() }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.capsule)
                    } else if viewModel.shouldOfferSelectedSourceLogin {
                        Button("Log In") { viewModel.requestLoginForSelectedSource() }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.capsule)
                    }
                    Button { viewModel.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(14)
                .frame(maxWidth: 520)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .padding(16)
            }
        }
    }
}
