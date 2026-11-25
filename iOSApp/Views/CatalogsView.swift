    private func submitSearch() {
        guard let link = model.search else { return }
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { return }
        let request = CatalogSearchRequest(link: link, terms: terms, pageURL: model.url)
        guard isSearchPresented else { return openSearch(request) }
        // End the search before pushing the results. Pushed while the search was still active, the page came
        // back without its navigation bar (no title, back button or search field; PR #193, CI job
        // 139027425473, screen recording of `testCatalogSearchAtDefaultSize`). Ending it hides the keyboard;
        // the results are pushed once the field has gone back to the navigation bar.
        isSearchPresented = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            openSearch(request)
        }
    }

import SwiftUI
import UIKit
import ReaderCore

/// Navigation values inside the Catalogs sheet.
enum CatalogRoute: Hashable {
    case feed(URL, title: String)
    case book(OPDSEntry)
    /// The results of a catalog page's search.
    case search(CatalogSearchRequest)
}

/// The Catalogs sheet (Library › + › Catalogs): the preset catalogs, the ones the user added, and browsing them.
/// A catalog is contacted only when the user opens it (docs/OPDS.md, docs/PRIVACY_DATA_MAP.md).
struct CatalogsView: View {
    @ObservedObject var catalogs: CatalogStore
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var editing: OPDSCatalog?
    /// The pushed screens. Search results are pushed onto it as a `CatalogRoute` value, like every other screen:
    /// pushed with `navigationDestination(item:)` from the catalog page instead, the results screen's own
    /// value-based rows (`NavigationLink(value: CatalogRoute.book)`) did nothing when tapped (PR #193, CI job
    /// 139005494662).
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            // Cards in a `ScrollView`, like the book details, not a `List`: at AX5 the audit flagged the rows of a
            // `List` that were fully on screen only in the middle or at the end of the list ("partially unsupported";
            // docs/ACCESSIBILITY.md). Cards have one layout at every size.
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        DetailCard(title: Text("Free Catalogs", comment: "Catalogs: section header of the built-in catalogs")) {
                            ForEach(OPDSCatalog.presets) { catalog in
                                catalogRow(catalog)
                                if catalog.id != OPDSCatalog.presets.last?.id { Divider() }
                            }
                        }
                        Text("Folito contacts a catalog only when you open it. Books you download are added to your library and sent to your Apple Watch, like any other import.",
                             comment: "Catalogs: footer under the built-in catalogs")
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            .padding(.horizontal, 4)
                    }
                    DetailCard(title: Text("Your Catalogs", comment: "Catalogs: section header of the catalogs the user added")) {
                        ForEach(catalogs.custom) { catalog in
                            catalogRow(catalog)
                                .contextMenu {
                                    Button { editing = catalog } label: {
                                        Label { Text("Edit…", comment: "Catalogs: edit the name and sign-in of a catalog the user added") } icon: { Image(systemName: "pencil") }
                                    }
                                    Button(role: .destructive) { catalogs.remove(catalog) } label: {
                                        Label { Text("Remove", comment: "Catalogs: remove a catalog the user added") } icon: { Image(systemName: "trash") }
                                    }
                                }
                                .accessibilityAction(named: Text("Edit", comment: "Catalogs: VoiceOver action that edits the name and sign-in of a catalog the user added")) {
                                    editing = catalog
                                }
                                .accessibilityAction(named: Text("Remove", comment: "Catalogs: remove a catalog the user added")) {
                                    catalogs.remove(catalog)
                                }
                            Divider()
                        }
                        Button { showAdd = true } label: {
                            ListActionLabel(Text("Add Catalog…", comment: "Catalogs: button that opens the form to add a catalog by address"),
                                            systemImage: "plus")
                                .modifier(ActionLabel())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("catalogsAdd")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .readableScrollEdges()
            .navigationTitle(Text("Catalogs", comment: "Title of the screen that lists OPDS catalogs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // An icon bar button, like the other sheets: a text bar button keeps a fixed font size.
                    Button { dismiss() } label: {
                        Label { Text("Done", comment: "Button: close the Catalogs sheet") } icon: { Image(systemName: "xmark") }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("catalogsDone")
                }
            }
            .navigationDestination(for: CatalogRoute.self) { route in
                switch route {
                case .feed(let url, let title):
                    CatalogFeedView(url: url, title: title, catalogs: catalogs) { request in
                        path.append(CatalogRoute.search(request))
                    }
                case .book(let entry):
                    CatalogBookView(entry: entry, catalogs: catalogs, library: library)
                case .search(let request):
                    CatalogFeedView(search: request, catalogs: catalogs)
                }
            }
            .sheet(isPresented: $showAdd) {
                AddCatalogView(catalogs: catalogs)
            }
            .sheet(item: $editing) { catalog in
                EditCatalogView(catalog: catalog, catalogs: catalogs)
            }
            .alert(catalogs.alert?.title ?? "",
                   isPresented: Binding(get: { catalogs.alert != nil }, set: { if !$0 { catalogs.alert = nil } }),
                   presenting: catalogs.alert) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.message)
            }
        }
    }

    private func catalogRow(_ catalog: OPDSCatalog) -> some View {
        NavigationLink(value: CatalogRoute.feed(catalog.url, title: catalog.title)) {
            CardLinkRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text(catalog.title).font(.body)
                    Text(catalog.url.host ?? catalog.url.absoluteString)
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                    if let user = catalogs.signIn(for: catalog) {
                        Text("Signed in as \(user)", comment: "Catalogs: caption of a catalog with a saved sign-in; the placeholder is the user name")
                            .font(.subheadline)
                            .foregroundStyle(.secondaryText)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("catalogRow")
    }
}

/// A row of a card that opens another screen: the content, then a chevron; at least 44 pt tall, one element.
struct CardLinkRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            content.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// An action row's label: icon and text in a plain stack, not a `Label` (in a list a label's icon column changes at
/// accessibility sizes; docs/ACCESSIBILITY.md, the compact watch notice).
struct ListActionLabel: View {
    let text: Text
    let systemImage: String

    init(_ text: Text, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).accessibilityHidden(true)
            text.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Feed

/// One catalog page: sections that lead further, and books. Further pages are loaded on request (Load More), so
/// the catalog is never asked for more than the user looks at.
///
/// A page whose feed offers search (`rel="search"`, docs/OPDS.md) has a search field; submitting it pushes the
/// results (a `CatalogRoute.search` on the Catalogs stack), shown by this same view (rows, Load More, errors and Sign In alike). The catalog is asked only when
/// the user submits a search.
struct CatalogFeedView: View {
    let title: String
    @ObservedObject var catalogs: CatalogStore
    @StateObject private var model: CatalogFeedModel
    /// The added catalog being edited from this page (its root page's Edit button, or Sign In after a 401).
    @State private var editing: CatalogEdit?
    @State private var query = ""
    /// Whether the search field is active (focused, or showing its Cancel button).
    @State private var isSearchPresented = false
    /// Pushes the results of a search (onto the Catalogs stack's path).
    private let openSearch: (CatalogSearchRequest) -> Void

    struct CatalogEdit: Identifiable {
        let catalog: OPDSCatalog
        let signInOnly: Bool
        var id: String { catalog.id + (signInOnly ? ".signin" : "") }
    }

    init(url: URL, title: String, catalogs: CatalogStore,
         openSearch: @escaping (CatalogSearchRequest) -> Void = { _ in }) {
        self.title = title
        self.catalogs = catalogs
        self.openSearch = openSearch
        _model = StateObject(wrappedValue: CatalogFeedModel(url: url, client: catalogs.client))
    }

    /// The results of a search.
    init(search request: CatalogSearchRequest, catalogs: CatalogStore) {
        self.title = String(localized: "Search Results", comment: "Catalog search: title of the screen with the results")
        self.catalogs = catalogs
        self.openSearch = { _ in }
        _model = StateObject(wrappedValue: CatalogFeedModel(search: request, client: catalogs.client))
    }

    private func submitSearch() {
        guard let link = model.search else { return }
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { return }
        // Hide the keyboard: the results screen is pushed, and the keyboard would cover its rows.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        openSearch(CatalogSearchRequest(link: link, terms: terms, pageURL: model.url))
    }

    var body: some View {
        content
            // The name of the row that was tapped: the feed's own title can be long ("Standard Ebooks - Newest
            // Ebooks"), and an inline navigation title is one line, clipped at large text sizes (audit). The feed's
            // title, when it differs, heads the list instead, where it wraps.
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.loadIfNeeded() }
            .refreshable { await model.load() }
            .toolbar {
                // On an added catalog's own page: edit its name and sign-in.
                if !model.isSearch, let catalog = catalogs.custom.first(where: { $0.url == model.url }) {
                    ToolbarItem(placement: .primaryAction) {
                        Button { editing = CatalogEdit(catalog: catalog, signInOnly: false) } label: {
                            Label { Text("Edit Catalog", comment: "Catalog page: toolbar button that edits the catalog's name and sign-in") } icon: { Image(systemName: "pencil") }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("catalogEdit")
                    }
                }
            }
            .sheet(item: $editing, onDismiss: {
                // After a sign-in was saved, read the page again with it.
                if model.failedForSignIn, let catalog = catalogs.signInCatalog(for: model.url),
                   catalogs.signIn(for: catalog) != nil {
                    Task { await model.load() }
                }
            }) { edit in
                EditCatalogView(catalog: edit.catalog, signInOnly: edit.signInOnly, catalogs: catalogs)
            }
            .alert(model.moreError?.title ?? "",
                   isPresented: Binding(get: { model.moreError != nil }, set: { if !$0 { model.moreError = nil } }),
                   presenting: model.moreError) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.message)
            }
            .modifier(CatalogSearchField(isEnabled: model.search != nil, text: $query, isPresented: $isSearchPresented,
                                         submit: submitSearch))
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView {
                Text("Loading Catalog…", comment: "Catalogs: shown while a catalog page loads")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ContentUnavailableView {
                Label(error.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message).foregroundStyle(.secondaryText)
            } actions: {
                // A page of an added https catalog that wants a sign-in (or refused the saved one): ask for it.
                if model.failedForSignIn, let catalog = catalogs.signInCatalog(for: model.url) {
                    Button { editing = CatalogEdit(catalog: catalog, signInOnly: true) } label: {
                        Text("Sign In…", comment: "Catalog page: opens the form for the catalog's user name and password").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("catalogSignIn")
                }
                Button { Task { await model.load() } } label: { Text("Try Again").frame(minHeight: 44) }
            }
        case .loaded:
            if model.entries.isEmpty, let request = model.searchRequest {
                ContentUnavailableView.search(text: request.terms)
            } else if model.entries.isEmpty {
                ContentUnavailableView {
                    Label { Text("Nothing Here", comment: "Catalogs: an empty catalog page") } icon: { Image(systemName: "tray") }
                } description: {
                    Text("This catalog page has no books or sections.", comment: "Catalogs: an empty catalog page")
                        .foregroundStyle(.secondaryText)
                }
            } else {
                list
            }
        }
    }

    private var entryRows: some View {
        ForEach(model.entries) { entry in
            Group {
                if entry.kind == .navigation, let url = entry.navigationURL {
                    NavigationLink(value: CatalogRoute.feed(url, title: entry.title)) {
                        CardLinkRow { CatalogEntryRow(entry: entry, catalogs: catalogs) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("catalogSectionRow")
                } else {
                    NavigationLink(value: CatalogRoute.book(entry)) {
                        CardLinkRow { CatalogEntryRow(entry: entry, catalogs: catalogs) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("catalogBookRow")
                }
            }
            if entry.id != model.entries.last?.id { Divider() }
        }
    }

    /// Cards in a `ScrollView`, not a `List` (see `CatalogsView`).
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    // No empty title: the feed's own title heads the card only when it differs from the screen's.
                    if let feedTitle = model.title, feedTitle != title {
                        Text(feedTitle)
                            .font(.headline)
                            .foregroundStyle(.secondaryText)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.horizontal, 4)
                    }
                    // Lazy: a page can hold hundreds of entries, and each row loads its cover when it appears.
                    LazyVStack(alignment: .leading, spacing: 12) { entryRows }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                if model.nextURL != nil {
                    DetailCard {
                        if model.isLoadingMore {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Loading More…", comment: "Catalogs: the next page of a catalog is loading")
                            }
                            .frame(minHeight: 44)
                            .accessibilityElement(children: .combine)
                        } else {
                            Button { Task { await model.loadMore() } } label: {
                                ListActionLabel(Text("Load More", comment: "Catalogs: button that loads the next page of a catalog"),
                                                systemImage: "arrow.down.circle")
                                    .modifier(ActionLabel())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("catalogLoadMore")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .readableScrollEdges()
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// The search field of a catalog page whose feed offers search (always shown under the title, so it is found
/// without scrolling up). Submitting runs the search; typing alone contacts nothing.
private struct CatalogSearchField: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String
    @Binding var isPresented: Bool
    let submit: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(text: $text, isPresented: $isPresented, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: Text("Search Catalog", comment: "Catalog page: placeholder of the search field"))
                .onSubmit(of: .search, submit)
        } else {
            content
        }
    }
}

/// A row of a catalog page: cover (decorative), title, then authors or a short summary. One element for VoiceOver.
struct CatalogEntryRow: View {
    let entry: OPDSEntry
    @ObservedObject var catalogs: CatalogStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if entry.kind == .book || entry.listImageURL != nil {
                CatalogCover(url: entry.listImageURL, title: entry.title, author: entry.authors.first ?? "",
                             catalogs: catalogs, width: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
                if entry.kind == .book && entry.epubLink == nil {
                    Text("Not available as EPUB", comment: "Catalogs: caption on a book the catalog offers only in other formats or with DRM")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String? {
        if !entry.authors.isEmpty { return entry.authors.formatted(.list(type: .and)) }
        guard let summary = entry.summary else { return nil }
        let excerpt = DescriptionExcerpt.excerpt(summary, maxCharacters: 120)
        return excerpt.text
    }
}

/// A catalog's cover image, or the placeholder cover while it loads or when there is none.
struct CatalogCover: View {
    let url: URL?
    let title: String
    let author: String
    @ObservedObject var catalogs: CatalogStore
    var width: CGFloat
    @State private var image: UIImage?

    var body: some View {
        CoverThumbnail(image: image, title: title, author: author, width: width)
            .task(id: url) {
                guard let url else { return }
                image = await catalogs.image(at: url)
            }
    }
}

// MARK: - Book

/// A book of a catalog: cover, title, authors, Download, description and details. Built like the Library's book
/// details (cards in a `ScrollView`, one layout at every text size).
struct CatalogBookView: View {
    let entry: OPDSEntry
    @ObservedObject var catalogs: CatalogStore
    @ObservedObject var library: LibraryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                card(nil) { download }
                if let summary = entry.summary {
                    card(Text("Description", comment: "Book detail section: the book's own blurb")) {
                        Text(summary).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if hasInformation {
                    card(Text("Information", comment: "Book detail section: publisher, year, language, progress")) {
                        information
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .readableScrollEdges()
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("catalogBook")
    }

    private var header: some View {
        VStack(spacing: 12) {
            CatalogCover(url: entry.imageURL ?? entry.thumbnailURL, title: entry.title,
                         author: entry.authors.first ?? "", catalogs: catalogs, width: 150)
                .padding(.bottom, 4)
            Text(entry.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !entry.authors.isEmpty {
                Text(entry.authors.formatted(.list(type: .and)))
                    .font(.body)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var download: some View {
        if entry.epubLink == nil {
            Text("This book isn’t offered as a DRM-free EPUB file, so Folito can’t download it.",
                 comment: "Catalog book: the catalog offers only other formats, DRM-protected files or purchases")
                .font(.body)
                .foregroundStyle(.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if catalogs.downloading.contains(entry.id) {
            HStack(spacing: 8) {
                ProgressView()
                Text("Downloading…").font(.body)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        } else if catalogs.downloaded.contains(entry.id) {
            Label {
                Text("In Your Library", comment: "Catalog book: the book was downloaded into the library")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            Button {
                Task { await catalogs.download(entry, into: library) }
            } label: {
                Label { Text("Download") } icon: { Image(systemName: "arrow.down.circle") }
                    .modifier(ActionLabel())
            }
            .buttonStyle(.borderless)
            .disabled(library.isImporting)
            .accessibilityHint(Text("Adds the book to your library and sends it to your Apple Watch.",
                                    comment: "Catalog book: hint of the Download button"))
            .accessibilityIdentifier("catalogDownload")
        }
    }

    private var hasInformation: Bool {
        entry.publisher != nil || entry.year != nil || entry.language != nil || entry.epubLink?.length != nil
    }

    @ViewBuilder
    private var information: some View {
        if let publisher = entry.publisher {
            DetailRow(title: Text("Publisher", comment: "Book detail label"), value: publisher)
        }
        if let year = entry.year {
            DetailRow(title: Text("Published", comment: "Book detail label: publication year"), value: String(year))
        }
        if let language = entry.language {
            DetailRow(title: Text("Language", comment: "Book detail label"),
                      value: Locale.current.localizedString(forIdentifier: language) ?? language)
        }
        if let length = entry.epubLink?.length {
            DetailRow(title: Text("File Size"), value: length.formatted(.byteCount(style: .file)))
        }
    }

    private func card<Content: View>(_ title: Text?, @ViewBuilder content: () -> Content) -> some View {
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
}

