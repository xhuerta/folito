import SwiftUI

/// Settings tab: progress sync and About (privacy policy, support, version, acknowledgements).
struct SettingsView: View {
    @ObservedObject var settings: SyncSettings

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    SyncSettingsView(settings: settings)
                } label: {
                    LabeledContent {
                        if settings.isSyncOn { Text("On") } else { Text("Off") }
                    } label: {
                        Label("Progress Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .accessibilityIdentifier("syncSettingsLink")
            } footer: {
                Text("Optional. Continue the same book in KOReader and other compatible reading apps.")
            }

            Section("About") {
                Link(destination: AppLinks.privacyPolicy) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .accessibilityHint("Opens in your web browser.")
                Link(destination: AppLinks.support) {
                    Label("Support", systemImage: "questionmark.circle")
                }
                .accessibilityHint("Opens in your web browser.")
                LabeledContent("Version", value: AppVersion.displayString())
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Label("Acknowledgements", systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("Settings")
    }
}

/// Open-source components shipped in the app, each with its full licence text.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                ForEach(OpenSourceComponent.all) { component in
                    NavigationLink {
                        LicenseView(component: component)
                    } label: {
                        LabeledContent(component.name, value: component.license)
                    }
                }
            } footer: {
                Text("WristReader uses these open-source components. Tap one to read its licence.")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenseView: View {
    let component: OpenSourceComponent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Link(destination: component.homepage) {
                    Label(component.homepage.absoluteString, systemImage: "link")
                }
                .accessibilityHint("Opens in your web browser.")
                if let text = component.licenseText() {
                    Text(verbatim: text)
                        .font(.footnote)
                        .textSelection(.enabled)
                } else {
                    Text("The licence text is missing from this build. It is available on the project’s website.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsView(settings: SyncSettings(clientFactory: { _ in MockKOSyncClient() }))
    }
}
