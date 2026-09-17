import SwiftUI

struct OnlineSubtitleBrowserView: View {
    let suggestion: JimakuMediaSuggestion
    let onSelectJimaku: (JimakuSubtitleFile) -> Void
    let onSelectAJATT: (AJATTSubtitleFile) -> Void
    let onSelectOpenSubtitles: (RemoteVideoSubtitleOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model = OnlineSubtitleBrowserModel()
    @AppStorage("videoSubtitleSearchAJATTEnabled") private var ajattEnabled = true
    @AppStorage("videoSubtitleSearchJimakuEnabled") private var jimakuEnabled = true
    @AppStorage("videoSubtitleSearchOpenSubtitlesEnabled") private var openSubtitlesEnabled = true
    @State private var showingCredentials = false
    @State private var languageFilter = ""
    @State private var versionFilter = ""
    @State private var resultFilter = ""
    @State private var expandedGroups: Set<String> = []

    private var providers: Set<OnlineSubtitleProvider> {
        Set(OnlineSubtitleProvider.allCases.filter {
            switch $0 {
            case .ajatt: ajattEnabled
            case .jimaku: jimakuEnabled
            case .openSubtitles: openSubtitlesEnabled
            }
        })
    }
    private var candidates: [OnlineSubtitleCandidate] {
        OnlineSubtitleProvider.allCases.flatMap { model.candidates[$0] ?? [] }
    }
    private var groups: [OnlineSubtitleGroup] {
        OnlineSubtitleGroup.build(candidates, language: languageFilter, version: versionFilter, filter: resultFilter)
    }
    private var isSearching: Bool { model.resolvingSeries || !model.searching.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Find Subtitles", systemImage: "captions.bubble").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                searchPanel.frame(width: 300)
                Divider()
                results.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 720)
        .task(id: suggestion) { model.prepare(suggestion) }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showingCredentials) { sourceSettings }
    }

    private var searchPanel: some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Subtitles").font(.headline)
                    Spacer()
                    Button { showingCredentials = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.glass).help("Subtitle Settings")
                }
                TextField("Search title", text: $model.query)
                    .textFieldStyle(.roundedBorder).onSubmit(search)
                TextField("Episode (Optional)", text: $model.episodeText)
                    .textFieldStyle(.roundedBorder).onSubmit(search)
                Picker("Content Type", selection: $model.kind) {
                    Text("Anime").tag(JimakuSearchKind.anime)
                    Text("Live Action").tag(JimakuSearchKind.liveAction)
                }
                if model.series.count > 1 {
                    Picker("Matching Title", selection: Binding(
                        get: { model.selectedSeriesID ?? 0 },
                        set: { id in
                            guard let series = model.series.first(where: { $0.id == id }) else { return }
                            clearFilters()
                            model.search(providers: providers, selectedSeries: series)
                        }
                    )) {
                        ForEach(model.series) { series in
                            Text([series.name, series.seasonYear.map(String.init)].compactMap { $0 }.joined(separator: " · ")).tag(series.id)
                        }
                    }
                }
                if !candidates.isEmpty {
                    Divider()
                    Picker("Language", selection: $languageFilter) {
                        Text("All").tag("")
                        ForEach(Array(Set(candidates.map(\.language))).sorted(), id: \.self) { language in
                            Text(Self.languageName(language)).tag(language)
                        }
                    }
                    let versions = Array(Set(candidates.map(\.version).filter { !$0.isEmpty })).sorted()
                    if !versions.isEmpty {
                        Picker("Version", selection: $versionFilter) {
                            Text("All").tag("")
                            ForEach(versions, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("Filter results (e.g. WEBRip, BD)", text: $resultFilter)
                        .textFieldStyle(.roundedBorder)
                }
                Button(action: search) {
                    Label("Search", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(providers.isEmpty || model.downloading)
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                if !model.failures.isEmpty && !isSearching {
                    Text("Some subtitles could not be retrieved. Try again later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }.disabled(model.downloading)
    }

    private var results: some View {
        VStack(spacing: 0) {
            if isSearching || model.downloading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.downloading ? String(localized: "Downloading Subtitle…") : String(localized: "Finding subtitles…"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }.padding(18)
            }
            if groups.isEmpty && !isSearching {
                ContentUnavailableView(model.hasSearched ? "No Matching Subtitles" : "Find Subtitles",
                    systemImage: "captions.bubble", description: Text(model.hasSearched
                        ? "Try another title, episode or filter." : "Search results will appear here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { group in versionCard(group) }
                        if model.openSubtitlesPage < model.openSubtitlesTotalPages {
                            Button("Load More") { model.loadMore() }.disabled(isSearching)
                        }
                    }.padding(20)
                }
            }
        }.disabled(model.downloading)
    }

    private func versionCard(_ group: OnlineSubtitleGroup) -> some View {
        let item = group.representative
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text([item.provider.rawValue, Self.languageName(item.language), item.version.isEmpty ? nil : item.version]
                        .compactMap { $0 }.joined(separator: " · ")).font(.headline)
                    Text(item.name).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Text(String.localizedStringWithFormat(String(localized: "%lld subtitle files"), Int64(group.candidates.count)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if group.candidates.count == 1 {
                    Button("Use Subtitle") { use(item.file) }.buttonStyle(.glassProminent)
                }
                Button {
                    if !expandedGroups.insert(group.id).inserted { expandedGroups.remove(group.id) }
                } label: {
                    Image(systemName: expandedGroups.contains(group.id) ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.glass)
                .help("Show Subtitle Files")
            }
            if expandedGroups.contains(group.id) {
                Divider()
                ForEach(group.candidates) { candidate in
                    Button { use(candidate.file) } label: {
                        Label(candidate.name, systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.glass)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var sourceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Subtitle Settings").font(.title2)
            Toggle("AJATT", isOn: $ajattEnabled)
            Divider()
            Toggle("Jimaku", isOn: $jimakuEnabled)
            SubtitleSourceCredentialView(provider: .jimaku)
            Divider()
            Toggle("OpenSubtitles", isOn: $openSubtitlesEnabled)
            SubtitleSourceCredentialView(provider: .openSubtitles)
            Text("Anime searches use AniList to match original, English and romaji titles. Search titles are sent to AniList and enabled API sources. AJATT matches its catalog locally.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(OnlineSubtitleProvider.allCases) { provider in
                if let error = model.failures[provider] {
                    Text(verbatim: "\(provider.rawValue): \(error)").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Done") { showingCredentials = false }.buttonStyle(.glassProminent)
            }
        }.padding(24).frame(width: 560)
    }

    private func search() {
        clearFilters()
        model.search(providers: providers)
    }
    private func clearFilters() {
        languageFilter = ""
        versionFilter = ""
        resultFilter = ""
        expandedGroups = []
    }
    private func use(_ file: OnlineSubtitleFile) {
        switch file {
        case .ajatt(let file): onSelectAJATT(file); dismiss()
        case .jimaku(let file): onSelectJimaku(file); dismiss()
        case .openSubtitles(let file):
            model.download(file) { option in onSelectOpenSubtitles(option); dismiss() }
        }
    }
    private static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code.uppercased()
    }
}

struct SubtitleSourceCredentialView: View {
    let provider: OnlineSubtitleProvider
    @State private var draft = ""
    @State private var stored = false
    @State private var busy = false
    @State private var status: String?
    @State private var confirmingRemoval = false
    private var store: JimakuCredentialStore {
        provider == .jimaku ? .shared : .openSubtitles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(provider.rawValue).font(.headline)
            HStack {
                SecureField("Enter a new API key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { save() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                Button("Remove", role: .destructive) { confirmingRemoval = true }.disabled(!stored || busy)
            }
            Text(status ?? (stored ? String(localized: "Saved in Keychain") : String(localized: "Not configured")))
                .font(.caption).foregroundStyle(.secondary)
            Link("Get API Key", destination: URL(string: provider == .jimaku ? "https://jimaku.cc/account" : "https://www.opensubtitles.com/consumers")!)
            if provider == .openSubtitles {
                Text("Use your own OpenSubtitles API key. It is stored in macOS Keychain and sent only to the official API. Downloads are subject to the service quota.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            do { stored = try await store.hasAPIKey() }
            catch { status = String(localized: "Unable to read subtitle credentials from Keychain.") }
        }
        .confirmationDialog("Remove Subtitle API Key?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { remove() }
        }
    }

    private func save() {
        let value = draft
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.save(apiKey: value)
                stored = true
                draft = ""
                status = nil
                if provider == .jimaku { NotificationCenter.default.post(name: .jimakuCredentialDidChange, object: nil) }
            } catch { status = String(localized: "Unable to save subtitle credentials to Keychain.") }
        }
    }

    private func remove() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.removeAPIKey()
                stored = false
                draft = ""
                status = nil
                if provider == .jimaku { NotificationCenter.default.post(name: .jimakuCredentialDidChange, object: nil) }
            } catch { status = String(localized: "Unable to remove subtitle credentials from Keychain.") }
        }
    }
}
