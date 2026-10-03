import AppKit
import SwiftUI

/// Adds a Jellyfin, Emby or Plex server, or refreshes an existing sign-in.
struct MediaServerSignInSheet: View {
    enum ServerFamily: String, CaseIterable, Identifiable {
        case jellyfinEmby
        case plex

        var id: String { rawValue }
    }

    enum Method: String, CaseIterable, Identifiable {
        case password
        case token

        var id: String { rawValue }
    }

    var existingAccount: MediaServerAccount?
    var onSignedIn: (MediaServerAccount) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var family: ServerFamily = .jellyfinEmby
    @State private var method: Method = .password
    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var isWorking = false
    @State private var isWaitingForBrowser = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(existingAccount == nil ? "Add Media Server" : "Sign In Again"))
                .font(.headline)

            Picker("Server Type", selection: $family) {
                Text("Jellyfin / Emby").tag(ServerFamily.jellyfinEmby)
                Text("Plex").tag(ServerFamily.plex)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isWorking || existingAccount != nil)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Server Address")
                        .gridColumnAlignment(.trailing)
                    TextField(serverPlaceholder, text: $serverAddress)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                }

                GridRow {
                    Text("Sign In With")
                    Picker("Sign In With", selection: $method) {
                        Text(LocalizedStringKey(family == .plex ? "Plex Account" : "Password")).tag(Method.password)
                        Text(LocalizedStringKey(family == .plex ? "Plex Token" : "Access Token")).tag(Method.token)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                if method == .password {
                    GridRow {
                        Text(LocalizedStringKey(family == .plex ? "Email or Username" : "Username"))
                        TextField("", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.username)
                    }
                    GridRow {
                        Text("Password")
                        SecureField("", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)
                            .onSubmit(signIn)
                    }
                } else {
                    GridRow {
                        Text(LocalizedStringKey(family == .plex ? "Plex Token" : "Access Token"))
                        SecureField("", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(signIn)
                    }
                }
            }
            .disabled(isWorking)

            Text(footnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                if family == .plex, method == .password {
                    Button("Sign In with Browser…", action: signInWithBrowser)
                        .disabled(isWorking)
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    task?.cancel()
                    dismiss()
                }

                Button(action: signIn) {
                    if isWorking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(LocalizedStringKey(isWaitingForBrowser ? "Waiting for Browser…" : "Signing In…"))
                        }
                    } else {
                        Text("Sign In")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || !canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: prefill)
        .onChange(of: family) { _, _ in
            errorMessage = nil
        }
        .onDisappear {
            task?.cancel()
            task = nil
        }
    }

    private var serverPlaceholder: String {
        family == .plex ? "http://192.168.1.10:32400" : "http://192.168.1.10:8096"
    }

    private var footnote: LocalizedStringKey {
        switch (family, method) {
        case (.plex, .password):
            "Signs in with your plex.tv account. Leave the address empty to use the first server of the account."
        case (.plex, .token):
            "A Plex token can be left empty for servers that allow access without sign-in on the local network."
        case (_, .password):
            "The password is sent only to this server. Niratan keeps the returned access token in macOS Keychain."
        case (_, .token):
            "Use a user access token. Server API keys are not tied to a user and cannot list libraries."
        }
    }

    private var canSubmit: Bool {
        let hasAddress = !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch (family, method) {
        case (.plex, .password):
            return !username.isEmpty && !password.isEmpty
        case (.plex, .token):
            return hasAddress
        case (_, .password):
            return hasAddress && !username.isEmpty
        case (_, .token):
            return hasAddress && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func prefill() {
        guard let existingAccount else { return }
        family = existingAccount.kind == .plex ? .plex : .jellyfinEmby
        serverAddress = existingAccount.serverURL.absoluteString
        username = existingAccount.username
    }

    private func signIn() {
        guard canSubmit, !isWorking else { return }
        let address = serverAddress
        let family = family
        let method = method
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password
        let token = token
        run {
            switch (family, method) {
            case (.plex, .password):
                try await PlexMediaServerClient.signIn(rawURL: address, username: username, password: password)
            case (.plex, .token):
                try await PlexMediaServerClient.signIn(rawURL: address, token: token)
            case (_, .password):
                try await JellyfinMediaServerClient.signIn(rawURL: address, username: username, password: password)
            case (_, .token):
                try await JellyfinMediaServerClient.signIn(
                    rawURL: address,
                    accessToken: token.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    private func signInWithBrowser() {
        let address = serverAddress
        run {
            let pin = try await PlexMediaServerClient.requestPIN()
            await MainActor.run {
                isWaitingForBrowser = true
                NSWorkspace.shared.open(pin.authURL)
            }
            return try await PlexMediaServerClient.signIn(rawURL: address, pin: pin)
        }
    }

    private func run(
        _ operation: @escaping @Sendable () async throws -> (account: MediaServerAccount, token: String)
    ) {
        isWorking = true
        errorMessage = nil
        task?.cancel()
        task = Task { @MainActor in
            defer {
                isWorking = false
                isWaitingForBrowser = false
            }
            do {
                let result = try await operation()
                guard !Task.isCancelled else { return }
                let stored = try await MediaServerAccountStore.shared.upsert(result.account, token: result.token)
                onSignedIn(stored)
                dismiss()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Signed-in servers with sign-in and removal actions, shared by Video
/// settings and the video library.
struct MediaServerAccountsList: View {
    var onSelect: ((MediaServerAccount) -> Void)?

    @State private var store = MediaServerAccountStore.shared
    @State private var isAdding = false
    @State private var reauthenticating: MediaServerAccount?
    @State private var pendingRemoval: MediaServerAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.accounts.isEmpty {
                NativeSettingsRow {
                    Text("No media servers")
                        .foregroundStyle(.secondary)
                } accessory: {
                    addButton
                }
            } else {
                ForEach(store.accounts) { account in
                    NativeSettingsRow {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                Text("\(account.kind.displayName) · \(account.accountSummary)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: account.kind.systemImage)
                        }
                    } accessory: {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                if let onSelect {
                                    Button("Browse") { onSelect(account) }
                                }
                                Button("Sign In Again") { reauthenticating = account }
                                Button("Remove", role: .destructive) { pendingRemoval = account }
                            }
                        }
                        .buttonStyle(NativeSettingsActionButtonStyle())
                    }
                    NativeSettingsSeparator()
                }
                NativeSettingsRow {
                    EmptyView()
                } accessory: {
                    addButton
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            MediaServerSignInSheet()
        }
        .sheet(item: $reauthenticating) { account in
            MediaServerSignInSheet(existingAccount: account)
        }
        .confirmationDialog(
            "Remove Media Server?",
            isPresented: removalBinding,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { account in
            Button("Remove", role: .destructive) {
                Task { await store.remove(account.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("Niratan signs out of \(account.displayName). Media on the server is not changed.")
        }
    }

    private var addButton: some View {
        Button {
            isAdding = true
        } label: {
            Label("Add Media Server…", systemImage: "plus")
        }
        .buttonStyle(NativeSettingsActionButtonStyle())
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }
}
