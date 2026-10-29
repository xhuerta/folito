import SwiftUI

/// Settings > Progress Sync: optional KOReader Sync (KOSync) login.
struct SyncSettingsView: View {
    @ObservedObject var settings: SyncSettings
    @State private var confirmTurnOff = false

    var body: some View {
        Form {
            Section {
                if settings.isSyncOn {
                    TintedLabel("Sync is on", systemImage: "checkmark.circle.fill", tint: .green)
                        .font(.headline)
                    Text("Reading progress is synced with the server below.")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                } else {
                    Label("Sync is off", systemImage: "icloud.slash")
                        .font(.headline)
                        .foregroundStyle(.secondaryText)
                    Text("Folito works fully without an account. Sync is optional: it only lets you continue the same book on other readers.")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                }
            } footer: {
                Text("Works with any KOReader Sync-compatible server, for example KOReader’s, Readest’s or one you host yourself. Sync stays off until you save a username and password.").systemSecondaryText()
            }

            Section {
                TextField("Server URL", text: $settings.server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $settings.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $settings.password)
                    .textContentType(.password)
                if let warning = settings.insecureWarning {
                    TintedLabel(verbatim: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                        .font(.footnote)
                }
            } header: {
                if settings.isSyncOn {
                    Text("Server").systemSecondaryText()
                } else {
                    Text("Optional: Connect a Sync Server").systemSecondaryText()
                }
            } footer: {
                // App Review 5.1.1(v): the app does not create accounts (KOSync cannot delete them).
                Text("Use an account you already have. To get one, create it on the sync server itself, for example in KOReader (Tools › Progress sync › Register) or on your own server.").systemSecondaryText()
            }

            Section {
                Button {
                    settings.save()
                } label: {
                    if settings.isSyncOn {
                        Text("Save Changes and Send to Watch")
                    } else {
                        Text("Save and Turn On Sync")
                    }
                }
                Button("Test Connection") { settings.testConnection() }
                if settings.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Contacting server…")
                            .foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .disabled(settings.isBusy)

            if let status = settings.status {
                Section {
                    StatusLabel(status: status)
                }
            }

            if settings.isSyncOn {
                Section {
                    Button("Turn Off Sync and Remove Login", role: .destructive) { confirmTurnOff = true }
                } footer: {
                    Text("Removes the login from this iPhone and from your Apple Watch, and clears progress waiting to sync. Your books and reading positions are kept.").systemSecondaryText()
                }
            }

            Section {
            } footer: {
                Text("The password is stored in the iPhone Keychain. Once you turn sync on, it is also sent to your paired Apple Watch and stored in the watch’s own Keychain, so the watch can sync on its own. Use a password you don’t use anywhere else; KOReader Sync only sends its MD5 hash.").systemSecondaryText()
            }
        }
        .navigationTitle("Progress Sync")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Turn off sync and remove the saved login from this iPhone and your Apple Watch?",
                            isPresented: $confirmTurnOff, titleVisibility: .visible) {
            Button("Turn Off Sync", role: .destructive) { settings.turnOff() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: settings.status) { _, status in
            if let status { Announcer.announce(status.text) }
        }
    }
}

/// Outcome of the last action, with an icon so the meaning does not depend on colour alone.
private struct StatusLabel: View {
    let status: SyncStatus

    var body: some View {
        switch status.kind {
        case .success:
            TintedLabel(verbatim: status.text, systemImage: "checkmark.circle.fill", tint: .green)
        case .failure:
            TintedLabel(verbatim: status.text, systemImage: "exclamationmark.triangle.fill", tint: .red)
                .accessibilityLabel(Text("Error: \(status.text)"))
        case .info:
            TintedLabel(verbatim: status.text, systemImage: "info.circle", tint: .secondaryText)
        }
    }
}

#Preview {
    NavigationStack {
        SyncSettingsView(settings: SyncSettings(clientFactory: { _ in MockKOSyncClient() }))
    }
}
