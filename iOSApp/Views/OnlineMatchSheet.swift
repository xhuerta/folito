import SwiftUI
import UIKit
import ReaderCore

/// *Find Details Online* (docs/ONLINE_METADATA.md): looks the book up on Open Library, shows the match (or up to
/// five to choose from) and applies only what the user confirms: the cover and the description separately, and
/// the year, publisher and subjects. Only fields the EPUB lacks are filled; the EPUB file is never changed.
/// Works whether or not *Find Missing Details Online* is on: it is an explicit, one-off request.
struct OnlineMatchSheet: View {
    let hash: String
    @ObservedObject var library: LibraryStore
    let provider: OnlineMetadataProviding
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .searching

    enum Phase: Equatable {
        case searching
        case failed(UserFacingError)
        case empty
        case results([OnlineBookMatch])
    }

    private var entry: LibraryEntry? { library.entries.first { $0.documentHash == hash } }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .searching:
                    ProgressView {
                        Text("Searching Open Library…", comment: "Find Details Online: a lookup is in progress")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("onlineSearching")
                case .failed(let error):
                    ContentUnavailableView {
                        Label(error.title, systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error.message).foregroundStyle(.secondaryText)
                    } actions: {
                        Button {
                            Task { await search() }
                        } label: {
                            Text("Try Again", comment: "Button: retry the online lookup")
                        }
                    }
                    .accessibilityIdentifier("onlineFailed")
                case .empty:
                    ContentUnavailableView {
                        Label {
                            Text("No Matches Found", comment: "Find Details Online: Open Library found nothing")
                        } icon: {
                            Image(systemName: "magnifyingglass")
                        }
                    } description: {
                        Text("Open Library has no book with this title and author. Your book keeps its own details.",
                             comment: "Find Details Online: explanation of the empty result")
                            .foregroundStyle(.secondaryText)
                    }
                    .accessibilityIdentifier("onlineEmpty")
                case .results(let matches):
                    if matches.count == 1, let match = matches.first {
                        OnlineMatchReview(match: match, hash: hash, library: library, provider: provider)
                    } else {
                        OnlineMatchList(matches: matches)
                            .navigationDestination(for: OnlineBookMatch.self) { match in
                                OnlineMatchReview(match: match, hash: hash, library: library, provider: provider)
                            }
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // An icon bar button, like the Library's toolbar: a text bar button keeps a fixed font size
                    // and fails the Dynamic Type audit. The label is still read by VoiceOver and shown by the
                    // Large Content Viewer.
                    Button {
                        dismiss()
                    } label: {
                        Label {
                            Text("Done", comment: "Button: close the Find Details Online sheet")
                        } icon: {
                            Image(systemName: "xmark")
                        }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("onlineDone")
                }
            }
        }
        .environment(\.onlineCoverLoader, { [provider] match in try? await provider.cover(for: match) })
        .task { await search() }
    }

    private func search() async {
        guard let entry else { phase = .empty; return }
        phase = .searching
        do {
            let matches = try await provider.lookup(entry.lookupQuery)
            phase = matches.isEmpty ? .empty : .results(matches)
            if matches.isEmpty {
                Announcer.announce(String(localized: "No matches found.", comment: "VoiceOver announcement: the online lookup found nothing"))
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(.onlineLookupFailed(error))
        }
    }
}

/// Several matches: up to five, best first, to choose from.
private struct OnlineMatchList: View {
    let matches: [OnlineBookMatch]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose the book that matches yours.", comment: "Find Details Online: instruction above several matches")
                    .font(.body)
                    .foregroundStyle(.secondaryText)
                    .padding(.horizontal, 4)
                DetailCard {
                    ForEach(matches) { match in
                        NavigationLink(value: match) {
                            OnlineMatchRow(match: match)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("onlineMatchRow")
                        if match.id != matches.last?.id { Divider() }
                    }
                }
                OpenLibraryCredit()
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .readableScrollEdges()
        .navigationTitle(Text("Choose a Match", comment: "Find Details Online: title of the list of matches"))
    }
}

/// One match in the list: the cover (loaded from Open Library) next to title, authors and year, at every size.
private struct OnlineMatchRow: View {
    let match: OnlineBookMatch
    @State private var image: UIImage?
    @Environment(\.onlineCoverLoader) private var loadCover

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverThumbnail(image: image, title: match.title, author: match.authors.first ?? "", width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: match.title).font(.body.weight(.semibold))
                if !match.authors.isEmpty {
                    Text(verbatim: match.authors.joined(separator: ", ")).font(.body).foregroundStyle(.secondaryText)
                }
                if let year = match.year {
                    Text(verbatim: String(year)).font(.body).foregroundStyle(.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task {
            // Thumbnails are fetched one at a time through the shared client (Open Library's etiquette).
            if image == nil, match.coverID != nil, let data = await loadCover?(match) { image = UIImage(data: data) }
        }
    }
}

/// Loads a match's cover (the list's thumbnails); set by the sheet's owner.
private struct OnlineCoverLoaderKey: EnvironmentKey {
    static let defaultValue: (@Sendable (OnlineBookMatch) async -> Data?)? = nil
}

extension EnvironmentValues {
    var onlineCoverLoader: (@Sendable (OnlineBookMatch) async -> Data?)? {
        get { self[OnlineCoverLoaderKey.self] }
        set { self[OnlineCoverLoaderKey.self] = newValue }
    }
}

/// One match, to confirm: cover, title, authors, year, publisher, description; and the actions that apply it.
struct OnlineMatchReview: View {
    let match: OnlineBookMatch
    let hash: String
    @ObservedObject var library: LibraryStore
    let provider: OnlineMetadataProviding
    @State private var loadedDescription: String?
    @State private var coverData: Data?
    @State private var coverImage: UIImage?
    @State private var loading = true
    @State private var loadError: UserFacingError?
    @State private var applied: OnlineFieldSelection = []
    @State private var applying = false

    private var entry: LibraryEntry? { library.entries.first { $0.documentHash == hash } }

    /// The match with what was loaded for it.
    private var loadedMatch: OnlineBookMatch {
        var m = match
        m.description = loadedDescription ?? match.description
        return m
    }

    private var applicable: OnlineFieldSelection {
        guard let entry else { return [] }
        var result = OnlineMetadataMerge.applicable(loadedMatch, details: entry.details, hasEPUBCover: entry.hasEPUBCover,
                                                    online: entry.online)
        if coverData == nil { result.remove(.cover) }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let text = loadedMatch.description {
                    DetailCard(title: Text("Description", comment: "Book detail section: the book's own blurb")) {
                        Text(verbatim: text)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("onlineMatchDescription")
                    }
                }
                if match.publisher != nil || !match.subjects.isEmpty {
                    DetailCard(title: Text("Information", comment: "Book detail section: publisher, year, language, progress")) {
                        if let publisher = match.publisher {
                            DetailRow(title: Text("Publisher", comment: "Book detail label"), value: publisher)
                        }
                        if !match.subjects.isEmpty {
                            DetailRow(title: Text("Subjects", comment: "Book detail label: the book's subjects or genres"),
                                      value: match.subjects.joined(separator: ", "))
                        }
                    }
                }
                DetailCard { actions }
                Text("Only details your book is missing are added. The book file itself is not changed, and you can remove online details at any time.",
                     comment: "Find Details Online: note below the actions")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .padding(.horizontal, 4)
                OpenLibraryCredit(pageURL: match.pageURL)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .readableScrollEdges()
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(Text("Review Match", comment: "Find Details Online: title of the screen that shows one match"))
        .accessibilityIdentifier("onlineMatchReview")
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            CoverThumbnail(image: coverImage, title: match.title, author: match.authors.first ?? "", width: 120)
                .padding(.bottom, 4)
            Text(verbatim: match.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !match.authors.isEmpty {
                Text(verbatim: match.authors.joined(separator: ", "))
                    .font(.body)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if let year = match.year {
                Text("Published \(String(year))", comment: "Find Details Online: the match's publication year")
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var actions: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading cover and description…", comment: "Find Details Online: loading the match's details").font(.body)
            }
            .frame(minHeight: 44)
        } else {
            if let loadError {
                Text(loadError.message).font(.body).foregroundStyle(.secondaryText)
            }
            let options = applicable
            if options.contains(.cover) {
                applyButton(.cover, Text("Use This Cover", comment: "Find Details Online: apply the match's cover"),
                            systemImage: "photo", id: "onlineUseCover")
            } else if applied.contains(.cover) {
                done(Text("Cover Added", comment: "Find Details Online: the cover was applied"))
            }
            if options.contains(.description) {
                applyButton(.description, Text("Use Description", comment: "Find Details Online: apply the match's description"),
                            systemImage: "text.alignleft", id: "onlineUseDescription")
            } else if applied.contains(.description) {
                done(Text("Description Added", comment: "Find Details Online: the description was applied"))
            }
            if options.contains(.publication) {
                applyButton(.publication, Text("Use Year, Publisher and Subjects",
                                               comment: "Find Details Online: apply the match's year, publisher and subjects"),
                            systemImage: "info.circle", id: "onlineUsePublication")
            } else if applied.contains(.publication) {
                done(Text("Year, Publisher and Subjects Added", comment: "Find Details Online: publication details were applied"))
            }
            if options.isEmpty && applied.isEmpty {
                Text("Your book already has everything this match offers.",
                     comment: "Find Details Online: the match would not add anything")
                    .font(.body)
                    .foregroundStyle(.secondaryText)
            }
        }
    }

    private func applyButton(_ piece: OnlineFieldSelection, _ title: Text, systemImage: String, id: String) -> some View {
        Button {
            Task { await apply(piece) }
        } label: {
            Label { title } icon: { Image(systemName: systemImage) }.modifier(ActionLabel())
        }
        .buttonStyle(.borderless)
        .disabled(applying)
        .accessibilityIdentifier(id)
    }

    private func done(_ title: Text) -> some View {
        Label {
            title.foregroundStyle(.primary)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .modifier(ActionLabel())
    }

    private func load() async {
        defer { loading = false }
        do {
            if match.coverID != nil, coverData == nil, let data = try await provider.cover(for: match),
               let image = UIImage(data: data) {
                coverData = data
                coverImage = image
            }
            if loadedDescription == nil, match.description == nil {
                loadedDescription = try await provider.description(for: match)
            }
        } catch is CancellationError {
        } catch {
            loadError = .onlineLookupFailed(error)
        }
    }

    private func apply(_ piece: OnlineFieldSelection) async {
        applying = true
        defer { applying = false }
        let result = await library.applyOnline(loadedMatch, selection: piece, coverData: piece.contains(.cover) ? coverData : nil,
                                               to: hash)
        applied.formUnion(result)
        if !result.isEmpty {
            Announcer.announce(String(localized: "Added from Open Library.", comment: "VoiceOver announcement: an online detail was applied"))
        }
    }
}

/// "From Open Library" with a link to the record, as their terms ask for a courtesy link back.
struct OpenLibraryCredit: View {
    var pageURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Book details from Open Library, a project of the Internet Archive.",
                 comment: "Attribution under details found online")
                .font(.footnote)
                .foregroundStyle(.secondaryText)
            if let pageURL {
                Link(destination: pageURL) {
                    Text("View on Open Library", comment: "Link: opens the book's page on openlibrary.org")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityHint(Text("Opens in your web browser."))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled card, like an inset grouped list section (the book detail screen's layout; see `BookDetailView`).
struct DetailCard<Content: View>: View {
    var title: Text? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                title
                    .font(.headline)
                    .foregroundStyle(.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Title above value at every text size, one element for VoiceOver (see `BookDetailView.row`).
struct DetailRow: View {
    let title: Text
    let value: String
    var caption: Text? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.body)
            Text(verbatim: value).font(.body).foregroundStyle(.secondaryText)
            if let caption {
                caption.font(.footnote).foregroundStyle(.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
