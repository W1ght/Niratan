//
//  SyncView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct SyncView: View {
    @Environment(UserConfig.self) var userConfig
    @State private var librarySync = GoogleDriveSyncManager.shared
    @State private var isAuthenticated = false
    @State private var isConnecting = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var showClearCacheConfirmation = false
    @State private var showSignOutConfirmation = false
    @State private var showQueue = false

    private var needsOwnClientId: Bool {
        userConfig.syncProvider == .ttu || GoogleDriveAuth.bundledClientId == nil
    }

    var body: some View {
        @Bindable var userConfig = userConfig
        NativeSettingsForm {
            NativeSettingsSectionCard {
                Text("Syncing")
            } content: {
                NativeSettingsToggle("Enable", isOn: $userConfig.enableSync)
                NativeSettingsSeparator()
                NativeSettingsRow("Provider") {
                    NativeGlassSegmentedPicker(
                        selection: Binding(
                            get: { userConfig.syncProvider },
                            set: changeProvider
                        ),
                        values: [SyncProvider.gdrive, .ttu],
                        minSegmentWidth: 96
                    ) { provider in
                        switch provider {
                        case .gdrive:
                            Text("Google Drive")
                        case .ttu:
                            Text(verbatim: "ッツ/yatsu")
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    switch userConfig.syncProvider {
                    case .gdrive:
                        Text("Syncs your whole library between Niratan devices: books, covers, reading positions, statistics, highlights, shelves and Sasayaki data.")
                    case .ttu:
                        Text("Sync bookmarks and statistics with ッツ Reader per book via Google Drive.")
                    }
                    if userConfig.enableSync && needsOwnClientId {
                        Text("A **[Google Cloud project](https://github.com/ttu-ttu/ebook-reader?tab=readme-ov-file#storage-sources)** is necessary for syncing.")
                        Text("1. After the initial setup, create another **OAuth client ID** in the same project.")
                        Text("2. Select **iOS** as the **Application type** and set the **Bundle ID** to '**moe.shishamo.hoshi**'.")
                        Text("3. Paste the **Client ID** in the textbox below and press '**Connect Google Drive**'.")
                        if userConfig.syncProvider == .ttu {
                            Text("4. You can sync individual books by long-pressing and selecting '**Sync**'.")
                            Text("**[More...](https://github.com/Manhhao/Hoshi-Reader/blob/develop/TTUSYNC.md)**")
                        }
                    }
                }
            }

            if userConfig.enableSync {
                connectionSection(clientId: $userConfig.googleClientId)

                if userConfig.syncProvider == .ttu {
                    ttuSections
                } else if isAuthenticated {
                    librarySection
                }
            }

            FushiInterconnectSettingsSection()
        }
        .navigationTitle("Syncing")
        .onAppear {
            refreshAuthentication()
        }
        .onChange(of: userConfig.enableSync) { _, enabled in
            if enabled {
                librarySync.start()
            } else {
                Task {
                    await librarySync.stop()
                }
            }
        }
        .sheet(isPresented: $showQueue) {
            SyncQueueView(sync: librarySync)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .alert("Clear Cache?", isPresented: $showClearCacheConfirmation) {
            Button("Clear", role: .destructive) {
                Task {
                    do {
                        GoogleDriveHandler.clearCache()
                        if userConfig.syncProvider == .gdrive {
                            try await librarySync.clearCache()
                        }
                    } catch {
                        present(error)
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will clear cached folder ids and book covers.")
        }
        .alert("Sign out?", isPresented: $showSignOutConfirmation) {
            Button("Confirm", role: .destructive) {
                Task {
                    do {
                        try await librarySync.signOut()
                    } catch {
                        present(error)
                    }
                    refreshAuthentication()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Signing out will clear authorization tokens, cached folder ids and book covers.")
        }
    }

    private func connectionSection(clientId: Binding<String>) -> some View {
        NativeSettingsSectionCard("Connection") {
            if needsOwnClientId {
                NativeSettingsRow("Client ID") {
                    TextField("Required", text: clientId)
                        .disabled(isAuthenticated)
                        .opacity(isAuthenticated ? 0.6 : 1)
                        .nativeSettingsTextField()
                }
                NativeSettingsSeparator()
            }
            NativeSettingsRow("Status") {
                Text(isConnecting
                     ? String(localized: "Connecting…")
                     : (isAuthenticated ? String(localized: "Connected") : String(localized: "Not connected")))
                    .foregroundStyle(.secondary)
            }
            NativeSettingsSeparator()
            NativeSettingsButtonRow {
                if isAuthenticated {
                    Button(role: .destructive) {
                        showClearCacheConfirmation = true
                    } label: {
                        Text("Clear Cache")
                    }
                    Button(role: .destructive) {
                        showSignOutConfirmation = true
                    } label: {
                        Text("Sign out")
                    }
                } else {
                    Button {
                        signIn()
                    } label: {
                        Text("Connect Google Drive")
                    }
                    .disabled(isConnecting)
                }
            }
        }
    }

    @ViewBuilder
    private var ttuSections: some View {
        @Bindable var userConfig = userConfig
        NativeSettingsSectionCard("Behaviour") {
            NativeSettingsRow("Direction") {
                NativeGlassSegmentedPicker(
                    selection: $userConfig.syncMode,
                    values: SyncMode.allCases,
                    minSegmentWidth: 76
                ) { mode in
                    textOfSyncMode(mode)
                }
            }
            NativeSettingsSeparator()
            NativeSettingsToggle("Auto Sync", isOn: $userConfig.enableAutoSync)
        }

        NativeSettingsSectionCard("Data") {
            NativeSettingsRow {
                NativeSettingsSubtitledLabel(
                    "Upload Books",
                    subtitle: "Uploads books on first sync if no bookdata is stored on Google Drive."
                )
            } accessory: {
                Toggle("", isOn: $userConfig.syncUploadBooks)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if userConfig.enableStatistics {
                NativeSettingsSeparator()
                NativeSettingsToggle("Sync Stats", isOn: $userConfig.statisticsEnableSync)
            }

            if userConfig.enableSasayaki {
                NativeSettingsSeparator()
                NativeSettingsToggle("Sync Audiobook Progress", isOn: $userConfig.sasayakiEnableSync)
            }
        }
    }

    private var librarySection: some View {
        let queue = librarySync.queue
        let progress = librarySync.progress
        let failed = queue.filter { $0.error != nil }.count
        return NativeSettingsSectionCard("Library") {
            NativeSettingsRow("Last Sync") {
                if let lastSync = librarySync.lastSync {
                    Text(lastSync, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)
                } else {
                    Text(librarySync.isSyncing ? String(localized: "Syncing…") : String(localized: "Never"))
                        .foregroundStyle(.secondary)
                }
            }
            NativeSettingsSeparator()
            Button {
                showQueue = true
            } label: {
                VStack(spacing: 8) {
                    HStack {
                        Text("Queue")
                        Spacer()
                        if let progress {
                            Text(verbatim: "\(progress.done) / \(progress.total)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else if failed > 0 {
                            Text("\(failed) failed")
                                .foregroundStyle(.red)
                        } else if !queue.isEmpty {
                            Text(verbatim: "\(queue.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Empty")
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    if let progress, progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                    }
                }
                .frame(minHeight: 46)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NativeSettingsSeparator()
            NativeSettingsButtonRow {
                Button {
                    Task {
                        await librarySync.sync()
                    }
                } label: {
                    Text("Sync Now")
                }
                .disabled(librarySync.isSyncing)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let errorMessage = librarySync.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Text("Books stored only on Google Drive appear on the shelf with a cloud badge and download when opened. Syncs every two minutes while Niratan is active.")
            }
        }
    }

    private func signIn() {
        isConnecting = true
        Task {
            defer {
                isConnecting = false
                refreshAuthentication()
            }
            do {
                try await GoogleDriveAuth.shared.authenticate(provider: userConfig.syncProvider)
            } catch {
                present(error)
            }
        }
    }

    private func changeProvider(_ provider: SyncProvider) {
        guard provider != userConfig.syncProvider else { return }
        Task {
            await librarySync.stop()
            GoogleDriveHandler.clearCache()
            userConfig.syncProvider = provider
            refreshAuthentication()
            librarySync.start()
        }
    }

    private func refreshAuthentication() {
        isAuthenticated = GoogleDriveAuth.shared.isAuthenticated(for: userConfig.syncProvider)
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }

    private func textOfSyncMode(_ mode: SyncMode) -> some View {
        switch mode {
        case .auto:
            Text("Auto")
        case .manual:
            Text("Manual")
        }
    }
}

private struct SyncQueueView: View {
    let sync: GoogleDriveSyncManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let queue = sync.queue
        let current = sync.progress?.current
        NavigationStack {
            List(queue) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let direction = item.direction {
                                Image(systemName: imageOfDirection(direction))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text(verbatim: item.title)
                                .lineLimit(1)
                        }
                        if let error = item.error {
                            Text(verbatim: error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if current?.contains(item.key) == true {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background {
                NativeGlassPageBackground()
            }
            .overlay {
                if queue.isEmpty {
                    ContentUnavailableView("All Books Synced", systemImage: "checkmark.icloud")
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help(String(localized: "Close"))
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func imageOfDirection(_ direction: GoogleDriveSyncManager.Direction) -> String {
        switch direction {
        case .upload:
            "arrow.up"
        case .download:
            "arrow.down"
        case .both:
            "arrow.up.arrow.down"
        }
    }
}
