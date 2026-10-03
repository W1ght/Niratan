//
//  FushiInterconnectSettingsSection.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Settings > Syncing cards for pairing with a Fushi host and syncing novel
/// reading progress with it.
struct FushiInterconnectSettingsSection: View {
    @State private var flow = FushiPairingFlow()
    @State private var browser = FushiBonjourBrowser()
    @State private var address = ""
    @State private var pin = ""
    @State private var showUnpairConfirmation = false
    @State private var showConflicts = false
    @State private var syncMessage: String?
    private let store = FushiInterconnectStore.shared
    private let coordinator = FushiProgressCoordinator.shared

    var body: some View {
        @Bindable var store = store
        NativeSettingsSectionCard {
            Text("Fushi Interconnect")
        } content: {
            if store.isPaired {
                pairedRows(autoSync: $store.autoSyncProgress)
            } else {
                pairingRows
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Syncs novel reading positions with a Fushi device on your network that has interconnect hosting turned on. Books are matched by title, so both sides need the same EPUB.")
                Text("When both devices moved since the last sync, Niratan asks which position to keep instead of overwriting either one.")
            }
        }
        .onAppear {
            if !store.isPaired {
                browser.start()
            }
        }
        .onDisappear {
            browser.stop()
        }
        .onChange(of: store.isPaired) { _, paired in
            if paired {
                browser.stop()
                address = ""
                pin = ""
            } else {
                browser.start()
            }
        }
        .alert("Disconnect from Fushi?", isPresented: $showUnpairConfirmation) {
            Button("Disconnect", role: .destructive) {
                store.unpair()
                coordinator.forgetHost()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Niratan forgets the pairing. Reading positions on both devices stay as they are.")
        }
        .sheet(isPresented: $showConflicts) {
            FushiConflictSheet(includePostponed: true) {
                showConflicts = false
            }
        }

        if store.isPaired && !coordinator.pendingConflicts.isEmpty {
            NativeSettingsSectionCard("Unresolved Conflicts") {
                ForEach(Array(coordinator.pendingConflicts.enumerated()), id: \.element.id) { index, conflict in
                    if index > 0 {
                        NativeSettingsSeparator()
                    }
                    NativeSettingsRow {
                        Text(verbatim: conflict.book.displayTitle)
                            .lineLimit(1)
                    } accessory: {
                        if coordinator.isPostponed(conflict) {
                            Text("Postponed")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                NativeSettingsSeparator()
                NativeSettingsButtonRow {
                    Button("Resolve…") {
                        showConflicts = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pairedRows(autoSync: Binding<Bool>) -> some View {
        NativeSettingsRow("Host") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: store.displayName)
                if let url = store.hostURL {
                    Text(verbatim: url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        NativeSettingsSeparator()
        NativeSettingsRow {
            NativeSettingsSubtitledLabel(
                "Auto Sync Reading Progress",
                subtitle: "Syncs when a book opens and closes, while reading, and once at launch."
            )
        } accessory: {
            Toggle("", isOn: autoSync)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        NativeSettingsSeparator()
        NativeSettingsButtonRow {
            Button {
                syncAllNow()
            } label: {
                Text("Sync All Books Now")
            }
            .disabled(coordinator.isSyncingAll)
            if coordinator.isSyncingAll {
                ProgressView()
                    .controlSize(.small)
            }
            Button(role: .destructive) {
                showUnpairConfirmation = true
            } label: {
                Text("Disconnect")
            }
        }
        if let syncMessage {
            NativeSettingsSeparator()
            NativeSettingsRow {
                Text(verbatim: syncMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } accessory: {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var pairingRows: some View {
        if !browser.hosts.isEmpty {
            ForEach(browser.hosts) { host in
                NativeSettingsRow {
                    Label {
                        Text(verbatim: host.name)
                    } icon: {
                        Image(systemName: host.usesTLS ? "lock.laptopcomputer" : "laptopcomputer")
                    }
                } accessory: {
                    Button("Use") {
                        Task {
                            if let resolved = await browser.address(of: host) {
                                address = resolved
                            }
                        }
                    }
                    .disabled(flow.isBusy)
                }
                NativeSettingsSeparator()
            }
        }
        NativeSettingsRow("Address") {
            TextField("192.168.1.10:38765", text: $address)
                .disabled(flow.isBusy)
                .nativeSettingsTextField()
                .onSubmit(startPairing)
        }
        NativeSettingsSeparator()
        statusRows
        NativeSettingsButtonRow {
            if flow.isBusy {
                Button("Cancel") {
                    flow.cancel()
                }
            } else {
                Button("Pair with Fushi") {
                    startPairing()
                }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        switch flow.state {
        case .idle:
            EmptyView()
        case .checking:
            statusRow(Text("Connecting to Fushi…"), busy: true)
        case .waitingForHost(let hostName):
            statusRow(Text("Waiting for approval on \(hostName)… Accept the request in Fushi."), busy: true)
        case .needsPIN(let hostName):
            NativeSettingsRow {
                NativeSettingsSubtitledLabel(
                    "PIN",
                    subtitle: "Enter the 6-digit PIN shown on the Fushi device."
                )
            } accessory: {
                HStack(spacing: 8) {
                    TextField("000000", text: $pin)
                        .frame(width: 90)
                        .nativeSettingsTextField()
                        .onSubmit { flow.submitPIN(pin) }
                    Button("Confirm") {
                        flow.submitPIN(pin)
                    }
                    .disabled(pin.filter(\.isNumber).count != 6)
                }
            }
            .help(Text(verbatim: hostName))
            NativeSettingsSeparator()
        case .failed(let message):
            statusRow(
                Text(verbatim: message).foregroundStyle(.red),
                busy: false
            )
        }
        if let fingerprint = flow.certificateFingerprint {
            NativeSettingsRow {
                NativeSettingsSubtitledLabel(
                    "Certificate",
                    subtitle: "Check that it matches the fingerprint shown in Fushi."
                )
            } accessory: {
                Text(verbatim: fingerprint)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            NativeSettingsSeparator()
        }
    }

    private func statusRow(_ text: Text, busy: Bool) -> some View {
        Group {
            NativeSettingsRow {
                text
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } accessory: {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            NativeSettingsSeparator()
        }
    }

    private func startPairing() {
        guard !flow.isBusy else { return }
        pin = ""
        flow.pair(address: address)
    }

    private func syncAllNow() {
        syncMessage = nil
        Task {
            let books = (try? BookStorage.loadAllBooks()) ?? []
            let report = await coordinator.syncAll(books: books, trigger: .manual(presentOnBookshelf: false))
            syncMessage = Self.summary(report)
            if report.conflicts > 0 {
                showConflicts = true
            }
        }
    }

    private static func summary(_ report: FushiSyncAllReport) -> String {
        var parts = [
            String(localized: "\(report.matched) books matched on Fushi"),
            String(localized: "\(report.pulled) updated from Fushi"),
            String(localized: "\(report.pushed) sent to Fushi")
        ]
        if report.conflicts > 0 {
            parts.append(String(localized: "\(report.conflicts) need a decision"))
        }
        if report.failed > 0 {
            parts.append(String(localized: "\(report.failed) failed"))
        }
        var text = parts.joined(separator: String(localized: ", "))
        if let error = report.lastError {
            text += "\n" + error
        }
        return text
    }
}
