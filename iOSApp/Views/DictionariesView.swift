import SwiftUI
import ReaderCore

/// Settings > Dictionaries: the offline dictionaries that can be downloaded for the watch, with their
/// source, licence and size; download, update and delete with progress.
struct DictionariesView: View {
    @ObservedObject var manager: DictionaryManager
    @ObservedObject var connectivity: PhoneConnectivity
    @State private var pendingDelete: DictionaryDescriptor?

    var body: some View {
        List {
            Section {
                ForEach(DictionaryCatalog.all) { descriptor in
                    DictionaryRow(descriptor: descriptor, manager: manager,
                                  watchState: DictionaryWatchState(id: descriptor.id, installed: manager.isInstalled(descriptor.id),
                                                                   onWatch: connectivity.watchDictionaries,
                                                                   sending: connectivity.outstandingDictionaries),
                                  onDelete: { pendingDelete = descriptor })
                }
            } footer: {
                Text("Lookups happen on your Apple Watch without a connection. The iPhone downloads each dictionary once, converts it to a smaller format and sends it to the watch.")
                    .systemSecondaryText()
            }
            Section {
                DictionaryCreditsText()
                Link(destination: DictionaryCatalog.all[0].licenseURL) {
                    Label("Licence (CC BY-SA 4.0)", systemImage: "doc.text")
                }
                .accessibilityHint("Opens in your web browser.")
                Link(destination: DictionaryCatalog.all[0].publisherURL) {
                    Label("reader.dict Website", systemImage: "link")
                }
                .accessibilityHint("Opens in your web browser.")
            } header: {
                Text("Credits").systemSecondaryText()
            }
        }
        .navigationTitle("Dictionaries")
        .task { await manager.checkForUpdates() }
        .confirmationDialog(pendingDelete.map { String(localized: "Delete the \(DictionaryManager.languageName($0.language)) dictionary from your iPhone and Apple Watch?", comment: "Confirmation; the placeholder is a language name") } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { descriptor in
            Button("Delete", role: .destructive) { manager.delete(descriptor.id) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(manager.error?.title ?? "",
               isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.error = nil } }),
               presenting: manager.error) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}

/// Where an installed dictionary is with respect to the watch. Pure, unit-tested.
enum DictionaryWatchState: Equatable {
    case notInstalled
    case onWatch
    case sending
    /// Installed on the phone; the watch has not confirmed it (yet), or has not reported at all.
    case waiting

    init(id: String, installed: Bool, onWatch: Set<String>?, sending: Set<String>) {
        if !installed { self = .notInstalled }
        else if onWatch?.contains(id) == true { self = .onWatch }
        else if sending.contains(id) { self = .sending }
        else { self = .waiting }
    }

    var text: String? {
        switch self {
        case .notInstalled: return nil
        case .onWatch: return String(localized: "On Apple Watch", comment: "Dictionary status")
        case .sending: return String(localized: "Sending to Apple Watch…", comment: "Dictionary status")
        case .waiting: return String(localized: "Waiting for Apple Watch", comment: "Dictionary status: installed on the iPhone, not yet confirmed by the watch")
        }
    }
}

private struct DictionaryRow: View {
    let descriptor: DictionaryDescriptor
    @ObservedObject var manager: DictionaryManager
    let watchState: DictionaryWatchState
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: DictionaryManager.languageName(descriptor.language))
                        .font(.headline)
                    Text(verbatim: descriptor.shortSource)
                        .font(.footnote).systemSecondaryText()
                    Text(DictionarySizes.text(download: descriptor.downloadSize,
                                              installed: manager.installedSize(descriptor.id) ?? descriptor.installedSize))
                        .font(.footnote).systemSecondaryText()
                    if let status = watchState.text {
                        Text(status).font(.footnote).systemSecondaryText()
                    }
                }
                Spacer()
                actions
            }
            progress
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var actions: some View {
        if manager.phases[descriptor.id] != nil {
            Button { manager.cancel(descriptor.id) } label: {
                Label("Cancel", systemImage: "xmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Cancel download"))
        } else if manager.isInstalled(descriptor.id) {
            let hasUpdate = manager.updatesAvailable.contains(descriptor.id)
            Menu {
                Button { manager.download(descriptor) } label: {
                    if hasUpdate {
                        Label("Update", systemImage: "arrow.clockwise")
                    } else {
                        Label("Download Again", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                if hasUpdate {
                    Label("Update Available", systemImage: "arrow.down.circle.fill")
                        .accessibilityLabel(Text("Update available, options"))
                } else {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(Text("Installed, options"))
                }
            }
        } else {
            Button("Download") { manager.download(descriptor) }
                .buttonStyle(.bordered)
                .accessibilityHint(Text("Downloads and installs this dictionary on your iPhone and Apple Watch."))
        }
    }

    @ViewBuilder private var progress: some View {
        switch manager.phases[descriptor.id] {
        case .downloading(let fraction)?:
            ProgressView(value: fraction) { Text("Downloading…").font(.footnote) }
        case .converting(let fraction)?:
            ProgressView(value: fraction) { Text("Preparing for Apple Watch…").font(.footnote) }
        case nil:
            EmptyView()
        }
    }
}

/// "Download 49 MB · On watch 70 MB".
enum DictionarySizes {
    static func text(download: Int64, installed: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        let d = download.formatted(.byteCount(style: .file).locale(locale))
        let w = installed.formatted(.byteCount(style: .file).locale(locale))
        return String(localized: "Download \(d) · On watch \(w)", locale: locale,
                      comment: "Dictionary sizes: download size and space used on the watch")
    }
}

/// The CC BY-SA credit for the dictionary data (also shown in Settings > Acknowledgements).
struct DictionaryCreditsText: View {
    var body: some View {
        Text("Definitions from Wiktionary by its contributors, under the CC BY-SA 4.0 licence. Compiled by reader.dict. Shortened and reformatted by Folito.")
            .font(.footnote)
    }
}

#Preview {
    NavigationStack {
        DictionariesView(manager: DictionaryManager(), connectivity: PhoneConnectivity())
    }
}
