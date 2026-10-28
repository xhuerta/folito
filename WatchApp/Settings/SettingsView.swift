import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var sync: SyncCoordinator
    @AppStorage(ReaderSettings.fontSizeKey) private var fontSize = ReaderSettings.defaultFontSize
    @AppStorage(ReaderSettings.showSyncInfoKey) private var showSyncInfo = true
    @State private var serverStatus = "Not checked"
    @State private var checking = false
    @State private var confirmReset = false

    var body: some View {
        List {
            Section("Reading") {
                Stepper(value: $fontSize, in: ReaderSettings.minFontSize...ReaderSettings.maxFontSize, step: 1) {
                    Text("Text size \(Int(ReaderSettings.clampFontSize(fontSize)))")
                }
                Toggle("Show sync info", isOn: $showSyncInfo)
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
