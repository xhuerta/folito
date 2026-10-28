import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SyncSettings
    @State private var confirmTurnOff = false

    var body: some View {
        Form {
            Section {
                Label(settings.isSyncOn ? "Sync is on" : "Sync is off",
                      systemImage: settings.isSyncOn ? "checkmark.circle.fill" : "icloud.slash")
                    .font(.headline)
                    .foregroundStyle(settings.isSyncOn ? Color.green : Color.secondary)
                Text(settings.isSyncOn
                     ? "Reading progress is synced with the server below."
                     : "WristReader works fully without an account. Sync is optional: it only lets you continue the same book on other readers.")
                    .font(.footnote).foregroundStyle(.secondary)
            } footer: {
                Text("Works with any KOReader Sync-compatible server, for example KOReader's, Readest's or one you host yourself. Sync stays off until you save a username and password.")
            }
            Section(settings.isSyncOn ? "Server" : "Optional: connect a sync server") {
                TextField("Server URL", text: $settings.server)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Username", text: $settings.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $settings.password)
                if let warning = settings.insecureWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Section {
                Button(settings.isSyncOn ? "Save changes & send to watch" : "Save & turn on sync") { settings.save() }
                Button("Test connection") { settings.testConnection() }
                Button("Create account") { settings.createAccount() }
            }
            .disabled(settings.isBusy)
            if settings.isBusy { ProgressView() }
            if let status = settings.status { Section { Text(status) } }
            if settings.isSyncOn {
                Section {
                    Button("Turn off sync and remove credentials", role: .destructive) { confirmTurnOff = true }
                } footer: {
                    Text("Removes the login from this iPhone and from your Apple Watch, and clears progress waiting to sync. Your books and reading positions are kept.")
                }
            }
            Section(footer: Text("The password is stored in the iPhone Keychain. Once you turn sync on it is also sent to your paired Apple Watch over WatchConnectivity and stored in the watch's own Keychain, so the watch can sync on its own. Use a password you do not reuse elsewhere; KOReader sync only sends its MD5 hash.")) { EmptyView() }
        }
        .navigationTitle("Sync")
        .confirmationDialog("Turn off sync and remove the saved login from this iPhone and your watch?",
                            isPresented: $confirmTurnOff, titleVisibility: .visible) {
            Button("Turn off sync and remove credentials", role: .destructive) { settings.turnOff() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView(settings: SyncSettings(clientFactory: { _ in MockKOSyncClient() }))
    }
}
