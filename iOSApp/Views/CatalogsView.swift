import SwiftUI
import UIKit
import ReaderCore

/// Navigation values inside the Catalogs sheet.
enum CatalogRoute: Hashable {
    case feed(URL, title: String)
    case book(OPDSEntry)
}

/// The Catalogs sheet (Library › + › Catalogs): the preset catalogs, the ones the user added, and browsing them.
/// A catalog is contacted only when the user opens it (docs/OPDS.md, docs/PRIVACY_DATA_MAP.md).
struct CatalogsView: View {
    @ObservedObject var catalogs: CatalogStore
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(OPDSCatalog.presets) { catalogRow($0) }
                } header: {
                    Text("Free Catalogs", comment: "Catalogs: section header of the built-in catalogs").foregroundStyle(.secondaryText)
                } footer: {
                    Text("Folito contacts a catalog only when you open it. Books you download are added to your library and sent to your Apple Watch, like any other import.",
                         comment: "Catalogs: footer under the built-in catalogs")
                        .foregroundStyle(.secondaryText)
                }
                Section {
                    ForEach(catalogs.custom) { catalog in
                        catalogRow(catalog)
                            .swipeActions {
                                Button(role: .destructive) { catalogs.remove(catalog) } label: {
                                    Label { Text("Remove", comment: "Catalogs: remove a catalog the user added") } icon: { Image(systemName: "trash") }
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) { catalogs.remove(catalog) } label: {
                                    Label { Text("Remove", comment: "Catalogs: remove a catalog the user added") } icon: { Image(systemName: "trash") }
                                }
                            }
                            .accessibilityAction(named: Text("Remove", comment: "Catalogs: remove a catalog the user added")) {
                                catalogs.remove(catalog)
                            }
                    }
                    Button { showAdd = true } label: {
                        ListActionLabel(Text("Add Catalog…", comment: "Catalogs: button that opens the form to add a catalog by address"),
                                        systemImage: "plus")
                            .modifier(ActionLabel())
                    }
                    // No row-level button styling: a default List/Form button row is flagged "Dynamic Type font sizes are
                    // partially unsupported" at AX5 (docs/ACCESSIBILITY.md); the label is an action row (ActionLabel).
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("catalogsAdd")
                } header: {
                    Text("Your Catalogs", comment: "Catalogs: section header of the catalogs the user added").foregroundStyle(.secondaryText)
                }
            }
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
                    CatalogFeedView(url: url, title: title, catalogs: catalogs)
                case .book(let entry):
                    CatalogBookView(entry: entry, catalogs: catalogs, library: library)
                }
            }
            .sheet(isPresented: $showAdd) {
                AddCatalogView(catalogs: catalogs)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.title).font(.body)
                Text(catalog.url.host ?? catalog.url.absoluteString)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("catalogRow")
    }
}

/// An action row's label inside a `List`: icon and text in a plain stack. A `Label` in a list gets an icon column
/// that changes at accessibility sizes, and its text was flagged "Dynamic Type font sizes are partially unsupported"
/// and "Text clipped" at AX5 (docs/ACCESSIBILITY.md, the compact watch notice).
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
struct CatalogFeedView: View {
    let title: String
    @ObservedObject var catalogs: CatalogStore
    @StateObject private var model: CatalogFeedModel

    init(url: URL, title: String, catalogs: CatalogStore) {
        self.title = title
        self.catalogs = catalogs
        _model = StateObject(wrappedValue: CatalogFeedModel(url: url, client: catalogs.client))
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
            .alert(model.moreError?.title ?? "",
                   isPresented: Binding(get: { model.moreError != nil }, set: { if !$0 { model.moreError = nil } }),
                   presenting: model.moreError) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.message)
            }
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
                Button { Task { await model.load() } } label: { Text("Try Again").frame(minHeight: 44) }
            }
        case .loaded:
            if model.entries.isEmpty {
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
            if entry.kind == .navigation, let url = entry.navigationURL {
                NavigationLink(value: CatalogRoute.feed(url, title: entry.title)) {
                    CatalogEntryRow(entry: entry, catalogs: catalogs)
                }
                .accessibilityIdentifier("catalogSectionRow")
            } else {
                NavigationLink(value: CatalogRoute.book(entry)) {
                    CatalogEntryRow(entry: entry, catalogs: catalogs)
                }
                .accessibilityIdentifier("catalogBookRow")
            }
        }
    }

    private var list: some View {
        List {
            // No empty header (an empty header is an unlabelled accessibility element).
            if let feedTitle = model.title, feedTitle != title {
                Section {
                    entryRows
                } header: {
                    Text(feedTitle).foregroundStyle(.secondaryText)
                }
            } else {
                Section { entryRows }
            }
            if model.nextURL != nil {
                Section {
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
                        // No row-level button styling: a default List/Form button row is flagged "Dynamic Type font sizes are
                        // partially unsupported" at AX5 (docs/ACCESSIBILITY.md); the label is an action row (ActionLabel).
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("catalogLoadMore")
                    }
                }
            }
        }
        .readableScrollEdges()
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

// MARK: - Add

/// Adds a catalog by address (no sign-in yet). The address is checked by reading the catalog once.
struct AddCatalogView: View {
    @ObservedObject var catalogs: CatalogStore
    @Environment(\.dismiss) private var dismiss
    /// Starts with the scheme, so the field shows text rather than a low-contrast placeholder.
    @State private var address = "https://"
    @State private var name = ""
    @State private var problem: String?
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Visible labels above the fields instead of placeholders: placeholder text is a light
                    // system gray, below 4.5:1 (docs/ACCESSIBILITY.md).
                    fieldLabel(Text("Address", comment: "Add Catalog: label of the catalog address field"))
                    TextField(text: $address, prompt: Text(verbatim: "")) {
                        Text("Address", comment: "Add Catalog: label of the catalog address field")
                    }
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .accessibilityLabel(Text("Address", comment: "Add Catalog: label of the catalog address field"))
                    .accessibilityIdentifier("catalogAddress")
                    fieldLabel(Text("Name (Optional)", comment: "Add Catalog: label of the optional name field"))
                    TextField(text: $name, prompt: Text(verbatim: "")) {
                        Text("Name (Optional)", comment: "Add Catalog: label of the optional name field")
                    }
                    // With a prompt, the label closure is not read by VoiceOver: name the field explicitly.
                    .accessibilityLabel(Text("Name (Optional)", comment: "Add Catalog: label of the optional name field"))
                    .accessibilityIdentifier("catalogName")
                } footer: {
                    Text("The address of an OPDS catalog, for example a Calibre-Web, Kavita or Komga server. Catalogs that need a sign-in aren’t supported yet.",
                         comment: "Add Catalog: footer under the address and name fields")
                        .foregroundStyle(.secondaryText)
                }
                if let problem {
                    Section {
                        Label {
                            Text(problem).font(.body)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    if isChecking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Checking Catalog…", comment: "Add Catalog: the address is being checked")
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                    } else {
                        Button { Task { await add() } } label: {
                            Text("Add Catalog", comment: "Add Catalog: button that checks the address and adds the catalog")
                                .modifier(ActionLabel())
                        }
                        // No row-level button styling: a default List/Form button row is flagged "Dynamic Type font sizes are
                        // partially unsupported" at AX5 (docs/ACCESSIBILITY.md); the label is an action row (ActionLabel).
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("catalogAddConfirm")
                    }
                }
            }
            .readableScrollEdges()
            .navigationTitle(Text("Add Catalog", comment: "Title of the form that adds a catalog by address"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label { Text("Cancel") } icon: { Image(systemName: "xmark") }
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
    }

    private func fieldLabel(_ text: Text) -> some View {
        text.font(.subheadline).foregroundStyle(.secondaryText)
            .listRowSeparator(.hidden, edges: .bottom)
    }

    private func add() async {
        problem = nil
        isChecking = true
        defer { isChecking = false }
        if let message = await catalogs.add(address: address, name: name) {
            problem = message
            Announcer.announce(message)
        } else {
            dismiss()
        }
    }
}
