import SwiftUI
import UIKit
import ReaderCore

/// Navigation value of a local book's detail screen.
struct BookDetailRoute: Hashable {
    let hash: String
}

/// A local book: large cover, title, authors, series, description, publication details, reading state and the
/// same actions as the Library row. Everything shown comes from the EPUB and the watch, plus the details the user
/// took from Open Library (*Find Details Online*, docs/ONLINE_METADATA.md), each marked "From Open Library".
struct BookDetailView: View {
    let hash: String
    @ObservedObject var library: LibraryStore
    @ObservedObject var connectivity: PhoneConnectivity
    var sendToWatch: (LibraryEntry) -> Void
    @EnvironmentObject private var onlineMetadata: OnlineMetadataModel
    @State private var showOnlineLookup = false
    @Environment(ReadestLibraryModel.self) private var readest: ReadestLibraryModel?
    @Environment(\.dismiss) private var dismiss
    @State private var deletion = BookDeletion()
    @State private var showFullDescription = false

    /// Longer descriptions are shortened (at a word, with "…") behind a "More" button. The text is cut, not
    /// line-limited, so nothing on screen is clipped at any text size.
    static let descriptionPreviewLength = 280

    private var entry: LibraryEntry? { library.entries.first { $0.documentHash == hash } }

    var body: some View {
        Group {
            if let entry {
                content(entry)
            } else {
                ContentUnavailableView("Book Removed", systemImage: "book.closed")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .modifier(BookDeletionDialogs(library: library, readest: readest, deletion: $deletion))
        .sheet(isPresented: $showOnlineLookup) {
            OnlineMatchSheet(hash: hash, library: library, provider: onlineMetadata.provider)
        }
        .onChange(of: entry == nil) { _, removed in
            if removed { dismiss() }
        }
    }

    /// A scroll view of cards, not a `List`: as a `List` at the largest text size the accessibility audit
    /// reported Dynamic Type and Text clipped findings with no element on the pages showing the section
    /// headers, the `LabeledContent` rows (which switch to a stacked layout at accessibility sizes) and the
    /// action rows, and "partially unsupported" on the More row (docs/ACCESSIBILITY.md). Here every row has
    /// one layout at every text size and every text uses a text style.
    private func content(_ entry: LibraryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(entry)
                if let text = entry.mergedDetails.description {
                    section(Text("Description", comment: "Book detail section: the book's own blurb")) {
                        description(text.value)
                        if text.source == .openLibrary { Self.fromOpenLibrary }
                    }
                }
                section(Text("Information", comment: "Book detail section: publisher, year, language, progress")) {
                    information(entry)
                }
                section(nil) { actions(entry) }
                if let online = entry.online {
                    OpenLibraryCredit(pageURL: online.sourceURL)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(entry.title)
        .accessibilityIdentifier("bookDetail")
    }

    /// A titled card, like an inset grouped list section.
    private func section<Content: View>(_ title: Text?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                title
                    .font(.headline)
                    .foregroundStyle(.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Header

    private func header(_ entry: LibraryEntry) -> some View {
        VStack(spacing: 12) {
            CoverThumbnail(image: entry.hasCover == true ? CoverImages.shared.cover(hash: entry.documentHash,
                                                                                    in: library.booksDirectory) : nil,
                           title: entry.title, author: entry.author, width: 150)
                .padding(.bottom, 4)
            if entry.online?.hasCover == true {
                Text("Cover from Open Library", comment: "Book detail: caption under a cover found online")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("onlineCoverCaption")
            }
            Text(entry.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(entry.author)
                .font(.body)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
            if let series = entry.details?.series {
                Text(Self.seriesText(series))
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// "Book 2 of Dune", or "Part of Dune" without a position.
    static func seriesText(_ series: BookSeries) -> String {
        guard let index = series.index else {
            return String(localized: "Part of \(series.name)", comment: "Book detail: series without a position; the placeholder is the series name")
        }
        let number = index.formatted(.number.precision(.fractionLength(0...2)))
        return String(localized: "Book \(number) of \(series.name)",
                      comment: "Book detail: position in a series, e.g. “Book 2 of Dune”; placeholders: number, series name")
    }

    // MARK: Description

    @ViewBuilder
    private func description(_ text: String) -> some View {
        let preview = DescriptionExcerpt.excerpt(text, maxCharacters: Self.descriptionPreviewLength)
        Text(verbatim: showFullDescription || !preview.truncated ? text : preview.text)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("bookDescription")
        if preview.truncated {
            // A text-style font, no line limit: the label grows with Dynamic Type; the minimum height keeps a
            // 44 pt hit area at small sizes.
            Button {
                showFullDescription.toggle()
            } label: {
                Group {
                    if showFullDescription {
                        Text("Less", comment: "Button: collapse the book description")
                    } else {
                        Text("More", comment: "Button: show the whole book description")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityHint(showFullDescription ? Text("Shows a shorter description.")
                                                   : Text("Shows the whole description."))
            .accessibilityIdentifier("bookDescriptionMore")
        }
    }

    // MARK: Information

    @ViewBuilder
    private func information(_ entry: LibraryEntry) -> some View {
        let details = entry.details
        let merged = entry.mergedDetails
        let state = watchState(entry)
        if let publisher = merged.publisher {
            row(Text("Publisher", comment: "Book detail label"), value: publisher.value, online: publisher.source == .openLibrary)
        }
        if let year = merged.year {
            row(Text("Published", comment: "Book detail label: publication year"), value: String(year.value),
                online: year.source == .openLibrary)
        }
        if let language = details?.language {
            row(Text("Language", comment: "Book detail label"),
                value: Locale.current.localizedString(forIdentifier: language) ?? language)
        }
        if let fraction = connectivity.watchProgress[entry.documentHash] {
            row(Text("Progress", comment: "Book detail label: how much has been read on the watch"),
                value: String(localized: "\(DisplayFormat.percent(fraction)) read",
                              comment: "Book detail: reading progress on the watch; the placeholder is a percentage"))
        }
        if state == .onWatch, let seconds = connectivity.watchTimeRemaining[entry.documentHash] {
            row(Text("Time Remaining", comment: "Book detail label: estimated reading time left"),
                value: DisplayFormat.timeLeft(seconds, style: .full))
        }
        row(Text("Apple Watch", comment: "Book detail label: whether the book is on the watch"), value: state.text)
        if let subjects = merged.subjects {
            row(Text("Subjects", comment: "Book detail label: the book's subjects or genres"),
                value: subjects.value.joined(separator: ", "), online: subjects.source == .openLibrary)
        }
        if let isbn = details?.isbn {
            row(Text(verbatim: "ISBN"), value: isbn) // i18n-ignore: an international standard abbreviation
        }
        row(Text("File Size", comment: "Book detail label: size of the converted book"), value: DisplayFormat.fileSize(entry.size))
    }

    /// Title above value at every text size (not a `LabeledContent`, which switches layout at accessibility
    /// sizes); one element for VoiceOver. The value uses `secondaryText` (the system's secondary label is below
    /// 4.5:1, docs/ACCESSIBILITY.md).
    /// `online` adds the "From Open Library" caption.
    private func row(_ title: Text, value: String, online: Bool = false) -> some View {
        DetailRow(title: title, value: value, caption: online ? Self.fromOpenLibraryText : nil)
    }

    static let fromOpenLibraryText = Text("From Open Library", comment: "Caption on a book detail that was found online")

    /// The caption under a value found online (subtle: footnote, secondary colour).
    static var fromOpenLibrary: some View {
        fromOpenLibraryText
            .font(.footnote)
            .foregroundStyle(.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    static let readableRed = UIColor { traits in
        UIColor.systemRed.resolvedColor(with: UITraitCollection(traitsFrom: [traits,
                                                                            UITraitCollection(accessibilityContrast: .high)]))
    }

    private func watchState(_ entry: LibraryEntry) -> BookWatchState {
        BookWatchState(entry, inFlight: connectivity.outstandingHashes.contains(entry.documentHash))
    }

    @ViewBuilder
    private func actions(_ entry: LibraryEntry) -> some View {
        let state = watchState(entry)
        let readestOn = readest?.isAvailable == true
        let inReadest = readestOn && readest?.cloudBook(for: entry, in: library.entries) != nil
        let isUploading = readest?.uploading.contains(entry.documentHash) == true
        if state == .removedOnWatch || (connectivity.status.canSend && state != .sending) {
            Button { sendToWatch(entry) } label: {
                Label(state.sendActionTitle, systemImage: "applewatch.and.arrow.forward").modifier(ActionLabel())
            }
            .buttonStyle(.borderless)
        }
        if isUploading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Uploading to Readest…").font(.body)
            }
            .frame(minHeight: 44)
        } else if readestOn && !inReadest {
            Button {
                Task { await readest?.upload(entry, from: library) }
            } label: {
                Label("Upload to Readest", systemImage: "icloud.and.arrow.up").modifier(ActionLabel())
            }
            .buttonStyle(.borderless)
        }
        if !OnlineMetadataMerge.missing(details: entry.details, hasEPUBCover: entry.hasEPUBCover).isEmpty {
            // An explicit, one-off lookup: works whether or not Find Missing Details Online is on.
            Button { showOnlineLookup = true } label: {
                Label("Find Details Online", systemImage: "text.magnifyingglass").modifier(ActionLabel())
            }
            .buttonStyle(.borderless)
            .accessibilityHint(Text("Looks this book up on Open Library. You choose what to add."))
            .accessibilityIdentifier("bookDetailFindOnline")
        }
        if entry.online != nil {
            Button { library.removeOnlineDetails(hash: entry.documentHash) } label: {
                Label("Remove Online Details", systemImage: "arrow.uturn.backward").modifier(ActionLabel())
            }
            .buttonStyle(.borderless)
            .accessibilityHint(Text("Shows only the details from the book file again."))
            .accessibilityIdentifier("bookDetailRemoveOnline")
        }
        if inReadest {
            Button { library.delete(entry) } label: {
                Label("Remove Download", systemImage: "xmark.icloud").modifier(ActionLabel())
            }
            .buttonStyle(.borderless)
        }
        Button(role: .destructive) {
            deletion.request(entry, inReadest: inReadest)
        } label: {
            // The increased-contrast red: system red text on a white row is about 3.6:1, below 4.5:1.
            Label("Delete", systemImage: "trash").foregroundStyle(Color(uiColor: Self.readableRed)).modifier(ActionLabel())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("bookDetailDelete")
    }
}

/// An action row's label: body text that wraps at every size, the full row width as hit area, at least 44 pt tall.
struct ActionLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// The pending steps of deleting a book, shared by the Library and the detail screen.
struct BookDeletion {
    /// A local-only book: "Delete Book?".
    var entry: LibraryEntry?
    /// A local book that is also in Readest: ask "this iPhone only" or "Readest too".
    var choice: LibraryEntry?
    /// Deleting from Readest needs its own, explicit confirmation.
    var readestBook: ReadestCloudBook?
    /// The local copy to delete too once the Readest deletion is confirmed ("Delete from Readest Too").
    var readestLocal: LibraryEntry?

    mutating func request(_ entry: LibraryEntry, inReadest: Bool) {
        if inReadest { choice = entry } else { self.entry = entry }
    }
}

/// The delete confirmations (this iPhone only, Readest too, and the explicit Readest confirmation).
struct BookDeletionDialogs: ViewModifier {
    @ObservedObject var library: LibraryStore
    let readest: ReadestLibraryModel?
    @Binding var deletion: BookDeletion

    func body(content: Content) -> some View {
        content
        .confirmationDialog(deleteTitle(deletion.entry), isPresented: Binding(get: { deletion.entry != nil },
                                                                              set: { if !$0 { deletion.entry = nil } }),
                            titleVisibility: .visible, presenting: deletion.entry) { entry in
            Button("Delete Book", role: .destructive) { library.delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The book is also removed from your Apple Watch, together with its reading position there.")
        }
        .confirmationDialog(deleteTitle(deletion.choice),
                            isPresented: Binding(get: { deletion.choice != nil },
                                                 set: { if !$0 { deletion.choice = nil } }),
                            titleVisibility: .visible, presenting: deletion.choice) { entry in
            Button("Delete from This iPhone Only") { library.delete(entry) }
            Button("Delete from Readest Too", role: .destructive) {
                let book = readest?.cloudBook(for: entry, in: library.entries)
                // Present the explicit confirmation once this dialog has gone.
                Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    deletion.readestLocal = entry
                    deletion.readestBook = book
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Deleting it from this iPhone also removes it from your Apple Watch. It stays in Readest, so you can download it again.")
        }
        .alert(readestDeleteTitle, isPresented: Binding(get: { deletion.readestBook != nil },
                                                        set: { if !$0 { deletion.readestBook = nil; deletion.readestLocal = nil } }),
               presenting: deletion.readestBook) { book in
            Button("Delete from Readest", role: .destructive) {
                let local = deletion.readestLocal
                Task {
                    await readest?.deleteFromReadest(book)
                    if let local, readest?.cloudBook(hash: book.hash) == nil { library.delete(local) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The book is removed from your Readest account and from every device that syncs with it. This can’t be undone.")
        }
    }

    private func deleteTitle(_ entry: LibraryEntry?) -> String {
        guard let entry else { return "" }
        return String(localized: "Delete “\(entry.title)”?", comment: "Confirmation title; the placeholder is the book title")
    }

    private var readestDeleteTitle: String {
        guard let book = deletion.readestBook else { return "" }
        return String(localized: "Delete “\(book.title)” from Readest?", comment: "Confirmation title; the placeholder is the book title")
    }
}
