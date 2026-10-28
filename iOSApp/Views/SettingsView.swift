import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SyncSettings

    var body: some View {
        Form {
            Section("KOReader Sync server") {
                TextField("Server URL", text: $settings.server)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Username", text: $settings.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $settings.password)
            }
            Section {
                Button("Save & send to watch") { settings.save() }
                Button("Test connection") { settings.testConnection() }
                Button("Create account") { settings.createAccount() }
            }
            .disabled(settings.isBusy)
            if settings.isBusy { ProgressView() }
            if let status = settings.status { Section { Text(status) } }
            Section(footer: Text("The password is stored in the iPhone Keychain and is also sent to your paired Apple Watch over WatchConnectivity, where it is stored in the watch's own Keychain. The watch needs it to sync on its own. Use a password you do not reuse elsewhere; KOReader sync only sends its MD5 hash.")) { EmptyView() }
        }
        .navigationTitle("Sync")
    }
}

#Preview {
    NavigationStack {
        SettingsView(settings: SyncSettings(clientFactory: { _ in MockKOSyncClient() }))
    }
}
