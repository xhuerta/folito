import SwiftUI
import ReaderCore

/// Localized names and texts of sync connectors. The screen itself is generated from
/// `SyncConnectorRegistry`; a new connector adds its cases here (see docs/SYNC_CONNECTORS.md).
enum SyncText {
    static func serviceName(_ d: SyncConnectorDescriptor) -> String {
        switch d.id {
        case KOSyncConnectorFactory.id:
            return String(localized: "KOReader Sync", comment: "Name of the KOReader progress sync service")
        case ReadestConnectorFactory.id:
            return String(localized: "Readest", comment: "Name of the Readest Cloud sync service (brand name)")
        default:
            return d.displayName
        }
    }

    static func fieldLabel(_ f: CredentialField) -> String {
        switch f.kind {
        case .url: return String(localized: "Server URL", comment: "Sync form field")
        case .username: return String(localized: "Username", comment: "Sync form field")
        case .email: return String(localized: "Email", comment: "Sync form field: account email address")
        case .password: return String(localized: "Password", comment: "Sync form field")
        case .token: return String(localized: "Access Token", comment: "Sync form field: an API token")
        }
    }

    static func summary(_ d: SyncConnectorDescriptor) -> String {
        switch d.id {
        case KOSyncConnectorFactory.id:
            return String(localized: "Works with any KOReader Sync-compatible server, for example KOReader’s, Readest’s or one you host yourself. Sync stays off until you save a username and password.",
                          comment: "Footer under the sync service picker when KOReader Sync is selected")
        case ReadestConnectorFactory.id:
            return String(localized: "Syncs with Readest Cloud, used by the Readest apps and by the Readest plugin for KOReader (for example on a Kobo). Folito is not made by Readest.",
                          comment: "Footer under the sync service picker when Readest is selected")
        default:
            return d.summary
        }
    }

    static func formFooter(_ d: SyncConnectorDescriptor) -> String {
        switch d.id {
        case ReadestConnectorFactory.id:
            return String(localized: "Use the Readest account you already have. To create one, sign up in the Readest app.",
                          comment: "Footer under the Readest sign-in fields")
        default:
            // App Review 5.1.1(v): the app does not create accounts (KOSync cannot delete them).
            return String(localized: "Use an account you already have. To get one, create it on the sync server itself, for example in KOReader (Tools › Progress sync › Register) or on your own server.",
                          comment: "Footer under the sync login fields")
        }
    }

    static func privacyFooter(_ d: SyncConnectorDescriptor) -> String {
        switch d.id {
        case ReadestConnectorFactory.id:
            return String(localized: "Folito never stores your Readest password: it signs in once and keeps only the session, in the iPhone Keychain and, once sent, in your Apple Watch’s Keychain. Your email, each book’s identifiers (file and metadata hashes) and your reading position are sent to Readest’s servers.",
                          comment: "Privacy note at the bottom of the sync screen when Readest is selected")
        default:
            return String(localized: "The password is stored in the iPhone Keychain. Once you turn sync on, it is also sent to your paired Apple Watch and stored in the watch’s own Keychain, so the watch can sync on its own. Use a password you don’t use anywhere else; KOReader Sync only sends its MD5 hash.",
                          comment: "Privacy note at the bottom of the sync screen")
        }
    }
}

/// Settings > Progress Sync: None, or one connector from `SyncConnectorRegistry` with its sign-in form.
struct SyncSettingsView: View {
    @ObservedObject var settings: SyncSettings
    @State private var confirmTurnOff = false

    var body: some View {
        Form {
            Section {
                if settings.isSyncOn, let active = settings.activeFactory {
                    TintedLabel("Sync is on", systemImage: "checkmark.circle.fill", tint: .green)
                        .font(.headline)
                    Text("Reading progress is synced with \(SyncText.serviceName(active.descriptor)).")
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
            }

            Section {
                Picker("Sync Service", selection: $settings.selectedConnectorID) {
                    Text("None").tag("")
                    ForEach(settings.registry.descriptors, id: \.id) { d in
                        Text(verbatim: SyncText.serviceName(d)).tag(d.id)
                    }
                }
                .accessibilityHint("Chooses where reading progress is synced.")
                .accessibilityIdentifier("syncServicePicker")
            } footer: {
                if let f = settings.selectedFactory {
                    Text(verbatim: SyncText.summary(f.descriptor)).systemSecondaryText()
                }
            }

            if let factory = settings.selectedFactory {
                connectorSections(factory)
            }

            if let status = settings.status {
                Section {
                    StatusLabel(status: status)
                }
            }

            if settings.isSyncOn {
                Section {
                    if settings.activeFactory?.descriptor.usesSession == true {
                        Button("Sign Out", role: .destructive) { confirmTurnOff = true }
                    } else {
                        Button("Turn Off Sync and Remove Login", role: .destructive) { confirmTurnOff = true }
                    }
                } footer: {
                    Text("Removes the login from this iPhone and from your Apple Watch, and clears progress waiting to sync. Your books and reading positions are kept.").systemSecondaryText()
                }
            }

            if let f = settings.selectedFactory {
                Section {
                } footer: {
                    Text(verbatim: SyncText.privacyFooter(f.descriptor)).systemSecondaryText()
                }
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

    @ViewBuilder
    private func connectorSections(_ factory: SyncConnectorFactory) -> some View {
        let d = factory.descriptor
        if settings.isSignedInToSelected {
            Section {
                LabeledContent("Account") {
                    Text(verbatim: settings.accountLabel ?? "").systemSecondaryText()
                }
            } header: {
                Text("Signed In").systemSecondaryText()
            }
        } else {
            Section {
                ForEach(d.credentialFields, id: \.key) { field in
                    CredentialFieldRow(field: field, text: Binding(
                        get: { settings.value(for: field.key) },
                        set: { settings.setValue($0, for: field.key) }))
                }
                if let warning = settings.insecureWarning {
                    TintedLabel(verbatim: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                        .font(.footnote)
                }
            } header: {
                if d.id == settings.activeConnectorID {
                    Text("Server").systemSecondaryText()
                } else if d.usesSession {
                    Text("Sign In to \(SyncText.serviceName(d))").systemSecondaryText()
                } else {
                    Text("Optional: Connect a Sync Server").systemSecondaryText()
                }
            } footer: {
                Text(verbatim: SyncText.formFooter(d)).systemSecondaryText()
            }

            Section {
                Button {
                    Task { await settings.save() }
                } label: {
                    if d.usesSession {
                        Text("Sign In and Turn On Sync")
                    } else if d.id == settings.activeConnectorID {
                        Text("Save Changes and Send to Watch")
                    } else {
                        Text("Save and Turn On Sync")
                    }
                }
                if d.supportsConnectionTest {
                    Button("Test Connection") { settings.testConnection() }
                }
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
        }
    }
}

/// One generated input of a connector's sign-in form; its label doubles as the VoiceOver label.
private struct CredentialFieldRow: View {
    let field: CredentialField
    @Binding var text: String

    var body: some View {
        let label = SyncText.fieldLabel(field)
        switch field.kind {
        case .password, .token:
            SecureField(label, text: $text)
                .textContentType(.password)
        case .url:
            TextField(label, text: $text)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .email:
            TextField(label, text: $text)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .username:
            TextField(label, text: $text)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
