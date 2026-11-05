import SwiftUI
import ReaderCore

/// Settings tab: dictionaries, progress sync, book details (online lookup) and About (privacy policy, support, version, acknowledgements).
struct SettingsView: View {
    @ObservedObject var settings: SyncSettings
    @ObservedObject var dictionaries: DictionaryManager
    @ObservedObject var connectivity: PhoneConnectivity

    var body: some View {
        if UITesting.settingsShowsOnlyBookDetails {
            // UI tests only (`-UITestingSettingsBookDetailsOnly`): the accessibility audit of this section.
            Form { BookDetailsSettingsSection() }
                .readableScrollEdges()
                .navigationTitle("Settings")
        } else {
            settingsForm
        }
    }

    private var settingsForm: some View {
        Form {
            Section {
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
            } footer: {
                Text("Download dictionaries to look up words on your Apple Watch, even offline.").foregroundStyle(.secondaryText)
            }

            Section {
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
            } footer: {
                Text("Optional. Continue the same book in KOReader, Readest and other compatible reading apps.").foregroundStyle(.secondaryText)
            }

            BookDetailsSettingsSection()

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
                LabeledContent("Version") {
                    Text(verbatim: AppVersion.displayString()).foregroundStyle(.secondaryText)
                }
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    AboutRowLabel(Text("Acknowledgements"), systemImage: "doc.text")
                }
            } header: {
                Text("About").foregroundStyle(.secondaryText)
            }
        }
        .readableScrollEdges()
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
                        LabeledContent {
                            Text(verbatim: component.license).foregroundStyle(.secondaryText)
                        } label: {
                            Text(verbatim: component.name)
                        }
                    }
                }
            } footer: {
                Text("Folito uses these open-source components. Tap one to read its licence.").foregroundStyle(.secondaryText)
            }
            Section {
                DictionaryCreditsText()
                Link(destination: DictionaryCatalog.all[0].licenseURL) {
                    Label("Licence (CC BY-SA 4.0)", systemImage: "doc.text")
                }
                .accessibilityHint("Opens in your web browser.")
            } header: {
                Text("Dictionary Data").foregroundStyle(.secondaryText)
            }
        }
        .readableScrollEdges()
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
    .environmentObject(OnlineMetadataModel())
    .environmentObject(LibraryStore())
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

/// *Book Details*: the opt-in online lookup of missing covers and descriptions (docs/ONLINE_METADATA.md). The
/// footer says exactly what is sent and to whom.
private struct BookDetailsSettingsSection: View {
    @EnvironmentObject private var model: OnlineMetadataModel
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Section {
            Toggle(isOn: $model.autoLookup) {
                Text("Find Missing Details Online", comment: "Settings toggle: look up missing covers and descriptions on Open Library")
            }
            .accessibilityIdentifier("onlineAutoLookupToggle")
            bulkRows
            Link(destination: AppLinks.internetArchivePrivacy) {
                Text("Internet Archive Privacy Policy", comment: "Settings link: the privacy policy of the Internet Archive, which runs Open Library")
            }
            .accessibilityHint(Text("Opens in your web browser."))
        } header: {
            Text("Book Details", comment: "Settings section: online lookup of missing book details").foregroundStyle(.secondaryText)
        } footer: {
            Text("Off by default. When on, books you import without a cover or description are looked up once on Open Library, a service of the Internet Archive. Only the book’s ISBN, or its title and author, is sent; nothing about you or the rest of your library. You confirm details for a single book in its details.",
                 comment: "Settings footer: what Find Missing Details Online sends, and to whom")
                .foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private var bulkRows: some View {
        switch model.bulk {
        case .running(let done, let total):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .accessibilityHidden(true)
                Text("Looking up \(min(done + 1, total)) of \(total) books…",
                     comment: "Settings › Book Details: lookup progress; placeholders: current book, number of books")
                    .foregroundStyle(.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onlineBulkProgress")
            Button(role: .cancel) {
                model.cancelBulk()
            } label: {
                Text("Stop Looking Up", comment: "Settings › Book Details: cancel the running lookup")
                    .modifier(ActionLabel())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("onlineBulkCancel")
        case .finished(let updated, let total, let cancelled):
            startButton
            Text(verbatim: OnlineMetadataModel.summary(updated: updated, total: total, cancelled: cancelled))
                .foregroundStyle(.secondaryText)
                .accessibilityIdentifier("onlineBulkSummary")
        case .failed(let error):
            startButton
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: error.title)
                Text(verbatim: error.message).foregroundStyle(.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onlineBulkSummary")
        case .idle:
            startButton
        }
    }

    private var startButton: some View {
        Button {
            model.startBulk(library: library)
        } label: {
            // Same rules as the detail screen's action rows: body text that wraps, no row-level button styling,
            // at least 44 pt tall (docs/ACCESSIBILITY.md).
            Text("Look Up Missing Details Now", comment: "Settings button: look up missing covers and descriptions for the whole library")
                .modifier(ActionLabel())
        }
        .buttonStyle(.borderless)
        .accessibilityHint(Text("Looks up the books without a cover or description on Open Library."))
        .accessibilityIdentifier("onlineBulkStart")
    }
}
