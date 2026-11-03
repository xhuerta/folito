import SwiftUI
import ReaderCore

/// Settings tab: dictionaries, progress sync and About (privacy policy, support, version, acknowledgements).
struct SettingsView: View {
    @ObservedObject var settings: SyncSettings
    @ObservedObject var dictionaries: DictionaryManager
    @ObservedObject var connectivity: PhoneConnectivity

    var body: some View {
        Form {
            Section {
                if AXProbe.on("noLinks") {
                    LabeledContent {
                        Text(verbatim: "\(dictionaries.installedInfos.count)").foregroundStyle(.secondaryText)
                    } label: {
                        Label("Dictionaries", systemImage: "character.book.closed")
                    }
                } else if AXProbe.on("plainRows") {
                    NavigationLink {
                        DictionariesView(manager: dictionaries, connectivity: connectivity)
                    } label: {
                        Label("Dictionaries", systemImage: "character.book.closed")
                    }
                } else {
                NavigationLink {
                    DictionariesView(manager: dictionaries, connectivity: connectivity)
                } label: {
                    LabeledContent {
                        Text(verbatim: "\(dictionaries.installedInfos.count)").foregroundStyle(.secondaryText)
                    } label: {
                        Label("Dictionaries", systemImage: "character.book.closed")
                    }
                }
                .accessibilityIdentifier("dictionariesLink")
                }
            } footer: {
                if !AXProbe.on("noFooters") {
                Text("Download dictionaries to look up words on your Apple Watch, even offline.").foregroundStyle(.secondaryText)
                }
            }

            Section {
                if AXProbe.on("noLinks") {
                    LabeledContent {
                        Text("Off").foregroundStyle(.secondaryText)
                    } label: {
                        Label("Progress Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                } else if AXProbe.on("plainRows") {
                    NavigationLink {
                        SyncSettingsView(settings: settings)
                    } label: {
                        Label("Progress Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                } else {
                NavigationLink {
                    SyncSettingsView(settings: settings)
                } label: {
                    LabeledContent {
                        if settings.isSyncOn { Text("On").foregroundStyle(.secondaryText) } else { Text("Off").foregroundStyle(.secondaryText) }
                    } label: {
                        Label("Progress Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .accessibilityIdentifier("syncSettingsLink")
                }
            } footer: {
                if !AXProbe.on("noFooters") {
                Text("Optional. Continue the same book in KOReader, Readest and other compatible reading apps.").foregroundStyle(.secondaryText)
                }
            }

            Section {
                ShowWelcomeTourButton()
                Link(destination: AppLinks.privacyPolicy) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .accessibilityHint("Opens in your web browser.")
                Link(destination: AppLinks.support) {
                    AboutRowLabel(Text("Support"), systemImage: "questionmark.circle")
                }
                .accessibilityHint("Opens in your web browser.")
                if !AXProbe.on("plainRows") {
                LabeledContent("Version") {
                    Text(verbatim: AppVersion.displayString()).foregroundStyle(.secondaryText)
                }
                }
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    AboutRowLabel(Text("Acknowledgements"), systemImage: "doc.text")
                }
            } header: {
                if !AXProbe.on("noFooters") {
                Text("About").foregroundStyle(.secondaryText)
                }
            }
        }
        .readableScrollEdges()
        .navigationTitle("Settings")
        .probeChrome()
    }
}

/// Open-source components shipped in the app, each with its full licence text.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                ForEach(OpenSourceComponent.all) { component in
                    if AXProbe.on("noLinks") {
                        LabeledContent {
                            Text(verbatim: component.license).foregroundStyle(.secondaryText)
                        } label: {
                            Text(verbatim: component.name)
                        }
                    } else if AXProbe.on("plainRows") {
                        NavigationLink {
                            LicenseView(component: component)
                        } label: {
                            Text(verbatim: component.name)
                        }
                    } else {
                    NavigationLink {
                        LicenseView(component: component)
                    } label: {
                        LabeledContent {
                            Text(verbatim: component.license).foregroundStyle(.secondaryText)
                        } label: {
                            Text(verbatim: component.name)
                        }
                    }
                    }
                }
            } footer: {
                if !AXProbe.on("noFooters") {
                Text("Folito uses these open-source components. Tap one to read its licence.").foregroundStyle(.secondaryText)
                }
            }
            Section {
                DictionaryCreditsText()
                Link(destination: DictionaryCatalog.all[0].licenseURL) {
                    Label("Licence (CC BY-SA 4.0)", systemImage: "doc.text")
                }
                .accessibilityHint("Opens in your web browser.")
            } header: {
                if !AXProbe.on("noFooters") {
                Text("Dictionary Data").foregroundStyle(.secondaryText)
                }
            }
        }
        .readableScrollEdges()
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .probeChrome()
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
                        .foregroundStyle(.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .readableScrollEdges()
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsView(settings: SyncSettings(clientFactory: { _ in MockKOSyncClient() }),
                     dictionaries: DictionaryManager(), connectivity: PhoneConnectivity())
    }
}

/// A Settings row label: icon and title, or the title alone at accessibility sizes, where the icon-plus-text label
/// did not scale fully at AX5 (the audit flagged "Dynamic Type partially unsupported" and "Text clipped").
private struct AboutRowLabel: View {
    let title: Text
    let systemImage: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: Text, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            title
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label { title } icon: { Image(systemName: systemImage) }
        }
    }
}
