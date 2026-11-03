import SwiftUI

/// "Other Languages…": every bundled sample book (see `SampleBooks`), the app's language first, each with the
/// language's own name, the title and the author. Samples already in the library are shown as such and cannot be
/// added twice. Picking one closes the sheet and hands the language to `onPick`, which imports it through
/// `LibraryStore.addSample` like the main "Add a Sample Book" button.
struct SampleBookPicker: View {
    @ObservedObject var library: LibraryStore
    var preferredLanguage: String = SampleBooks.preferredLanguage
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SampleBooks.ordered(preferred: preferredLanguage)) { sample in
                        row(sample)
                    }
                } footer: {
                    Text("Short public-domain excerpts. Each one is added to your library and sent to your Apple Watch like any other book.")
                        .foregroundStyle(.secondaryText)
                }
            }
            .navigationTitle("Sample Books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("samplePickerCancel")
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ sample: SampleBooks.Sample) -> some View {
        let added = library.sampleEntry(language: sample.language) != nil
        Button {
            dismiss()
            onPick(sample.language)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: sample.nativeLanguageName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(verbatim: sample.title)
                        .foregroundStyle(.primary)
                    Text(verbatim: sample.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                    if added {
                        Text("In Library", comment: "Sample book list: this sample is already in the library")
                            .font(.subheadline)
                            .foregroundStyle(.secondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if added {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(added || library.isImporting)
        .accessibilityElement(children: .combine)
        .accessibilityHint(added ? Text(verbatim: "") : Text("Adds this sample book to your library."))
        .accessibilityIdentifier("sample-\(sample.language)")
    }
}
