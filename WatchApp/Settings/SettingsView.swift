import SwiftUI
import ReaderCore

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var sync: SyncCoordinator
    @EnvironmentObject private var typography: TypographyModel
    @AppStorage(ReaderSettings.showSyncInfoKey) private var showSyncInfo = true
    @AppStorage(ReaderSettings.tapToLookUpKey) private var tapToLookUp = true
    @State private var serverStatus = "Not checked"
    @State private var checking = false
    @State private var confirmReset = false

    var body: some View {
        List {
            Section("Reading") {
                Stepper(value: typography.binding(\.fontSize), in: ReaderTypography.fontSizeRange, step: 1) {
                    Text("Text size \(Int(typography.value.fontSize))")
                }
                NavigationLink("Typography") { TypographyEditorView() }
                Toggle("Show sync info", isOn: $showSyncInfo)
            }
            Section {
                Toggle("Tap paragraph to look up", isOn: $tapToLookUp)
                Button("Clear dictionary cache") { env.dictionaryCache.removeAll() }
            } header: {
                Text("Dictionary")
            } footer: {
                Text("Definitions need a network connection; words already looked up work offline.")
            }
            Section("KOReader Sync") {
                if sync.isConfigured {
                    Text(CredentialsStore.username ?? "").font(.footnote).foregroundStyle(.secondary)
                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            Text("Check server")
                            if checking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(checking)
                    Text(serverStatus).font(.footnote).foregroundStyle(.secondary)
                    if sync.hasPending {
                        Text("Progress waiting to sync").font(.footnote).foregroundStyle(.orange)
                    }
                } else {
                    Text("Not configured. Set up sync in the iPhone app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Reset", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Reset settings, reading positions and sync login? Books are kept.",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { env.resetAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        switch await sync.testConnection() {
        case .ok: serverStatus = "Connected"
        case .unauthorized: serverStatus = "Wrong username or password"
        case .offline: serverStatus = "Offline"
        case .notConfigured: serverStatus = "Not configured"
        case .failed: serverStatus = "Server error"
        }
    }
}
