import SwiftUI
import ReaderCore

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var sync: SyncCoordinator
    @EnvironmentObject private var typography: TypographyModel
    @AppStorage(ReaderSettings.showSyncInfoKey) private var showSyncInfo = true
    @AppStorage(ReaderSettings.tapToLookUpKey) private var tapToLookUp = true
    /// Result of the last "Check server" (nil: not checked).
    @State private var connection: SyncCoordinator.ConnectionResult?
    @State private var checking = false
    @State private var confirmReset = false
    @State private var confirmRemove = false

    var body: some View {
        List {
            Section("Reading") {
                TextSizeStepper()
                NavigationLink("Typography") { TypographyEditorView() }
                    .accessibilityIdentifier("typographyLink")
                if sync.isConfigured { Toggle("Show Sync Status", isOn: $showSyncInfo) }
            }
            Section {
                Toggle("Tap Paragraph to Look Up", isOn: $tapToLookUp)
                Button("Clear Dictionary Cache") { env.dictionaryCache.removeAll() }
            } header: {
                Text("Dictionary")
            } footer: {
                Text("Definitions need a network connection; words already looked up work offline.")
            }
            Section {
                if sync.isConfigured {
                    if let user = CredentialsStore.username, !user.isEmpty {
                        LabeledContent("Account", value: user)
                    }
                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            Text("Check Server")
                            if checking {
                                Spacer()
                                ProgressView().accessibilityLabel(Text("Checking"))
                            }
                        }
                    }
                    .disabled(checking)
                    Text(WatchMessages.connection(connection))
                        .font(.footnote).foregroundStyle(.secondary)
                    if sync.hasPending {
                        Label("Progress waiting to sync", systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                    }
                    Button("Remove Credentials", role: .destructive) { confirmRemove = true }
                } else {
                    Text("Sync is optional and off. Reading works fully offline. To sync progress with a KOReader-compatible server, set it up in the iPhone app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Progress Sync (Optional)")
            }
            Section {
                Button("Reset", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Resets settings, reading positions and the sync login. Books are kept.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Remove the sync login from this watch? Books and reading positions are kept.",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Credentials", role: .destructive) {
                env.removeSyncCredentials()
                connection = nil
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Reset settings, reading positions and sync login? Books are kept.",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { env.resetAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        connection = await sync.testConnection()
    }
}
