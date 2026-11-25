import SwiftUI
import ReaderCore

// User collections of the Library (#164): the collection picker (a book's context menu, its details, and several
// books chosen in the Library), the screen that creates, renames, reorders and deletes collections, and the name
// form. The collections themselves are `BookCollections` (ReaderCore), kept by `LibraryStore`.
//
// Accessibility: every text field has a visible label above it (no placeholder-only field: placeholder text is
// below 4.5:1), rows are single elements with their state (selected) and actions (rename, move, delete) in the
// Actions rotor, and nothing switches layout at accessibility text sizes (docs/ACCESSIBILITY.md).

/// The books a collection picker adds or removes: one book, or several chosen in the Library.
struct CollectionTarget: Identifiable {
    let hashes: [String]
    /// The book's title, or the number of books chosen.
    let title: String
    var id: String { hashes.joined(separator: ",") }

    init(hashes: [String], title: String) {
        self.hashes = hashes
        self.title = title
    }

    /// Several books chosen in the Library: titled by their number (one book by its title).
    init(books: [SelectableBook]) {
        hashes = books.map(\.id)
        title = books.count == 1 ? books[0].title
            : String(localized: "\(books.count.formatted()) Books", comment: "Collection picker: header when several books are chosen (always 2 or more); the placeholder is the number")
    }
}

/// The strings that the Library row, the book details and the collection screens share.
enum CollectionText {
    static var addTitle: String {
        String(localized: "Add to Collection…", comment: "Action on a book (context menu, VoiceOver action, book details): opens the collection picker")
    }

    static func removeTitle(_ name: String) -> String {
        String(localized: "Remove from “\(name)”",
               comment: "Action on a book (VoiceOver action, book details): takes it out of a collection; the placeholder is the collection's name. The book stays in the Library.")
    }

    static var explanation: String {
        String(localized: "Collections group your books your way, like “To Read” or “Book Club”. A book can be in several collections, and deleting a collection never deletes its books.",
               comment: "Explanation of collections (empty state of By Collection, the Collections screen and the collection picker)")
    }

    static func message(for problem: BookCollections.NameProblem) -> String {
        switch problem {
        case .empty:
            return String(localized: "Enter a name for the collection.", comment: "Collection name form: the name is blank")
        case .duplicate(let other):
            return String(localized: "There’s already a collection named “\(other)”.",
                          comment: "Collection name form: another collection has this name; the placeholder is its name")
        }
    }

    static func deleteTitle(_ name: String) -> String {
        String(localized: "Delete “\(name)”?", comment: "Confirmation title before deleting a collection; the placeholder is the collection's name")
    }

    static var deleteMessage: String {
        String(localized: "Only the collection is deleted. Its books stay in your Library and in any other collections.",
               comment: "Confirmation message before deleting a collection")
    }
}

/// "No Collections": what collections are, and a button to make the first one.
struct CollectionsEmptyState: View {
    var onCreate: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label { Text("No Collections", comment: "Empty state: the user has no collections yet") } icon: {
                Image(systemName: "folder")
            }
        } description: {
            Text(verbatim: CollectionText.explanation)
                .foregroundStyle(.secondaryText)
        } actions: {
            // Borderless: in a List row, plain buttons all fire on a tap anywhere in the row.
            Button(action: onCreate) {
                Text("New Collection", comment: "Button: create a collection")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("collectionsNew")
        }
    }
}

/// A row of a list of collections: a folder icon and the name, one layout at every text size (not a `Label`, whose
/// icon column changes at accessibility sizes in a list).
private struct CollectionNameRow: View {
    let name: String
    var systemImage = "folder"
    var selected: Bool? = nil
    /// A button that is not a choice (*New Collection*): the name in the tint colour.
    var isAction = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: selected.map { $0 ? "checkmark.circle.fill" : "circle" } ?? systemImage)
                .foregroundStyle(selected == true || isAction ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondaryText))
                .accessibilityHidden(true)
            Text(verbatim: name)
                .foregroundStyle(isAction ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Name form

/// Creates or renames a collection: a field with a visible label, Save and Cancel. A name already used by another
/// collection is refused with a message under the field.
struct CollectionNameForm: View {
    enum Mode {
        /// A new collection, with these books in it (none from the Collections screen).
        case create(books: [String])
        case rename(BookCollection)
    }

    let mode: Mode
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var problem: String?
    @FocusState private var isFocused: Bool

    init(mode: Mode, library: LibraryStore) {
        self.mode = mode
        self.library = library
        if case .rename(let collection) = mode {
            _name = State(initialValue: collection.name)
        } else {
            _name = State(initialValue: "")
        }
    }

    private var isRename: Bool {
        if case .rename = mode { return true }
        return false
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Collection Name", comment: "Collection name form: label of the name field")
                            .font(.subheadline)
                            .foregroundStyle(.secondaryText)
                        TextField(text: $name, prompt: Text(verbatim: "")) {
                            Text("Collection Name", comment: "Collection name form: label of the name field")
                        }
                        .font(.body)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .frame(minHeight: 44)
                        // With a prompt, the label closure is not read by VoiceOver: name the field explicitly.
                        .accessibilityLabel(Text("Collection Name", comment: "Collection name form: label of the name field"))
                        .accessibilityIdentifier("collectionNameField")
                    }
                } footer: {
                    if let problem {
                        Label {
                            Text(verbatim: problem)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                        }
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("collectionNameProblem")
                    } else {
                        Text(verbatim: CollectionText.explanation)
                            .foregroundStyle(.secondaryText)
                    }
                }
            }
            .navigationTitle(isRename ? Text("Rename Collection", comment: "Title of the form that renames a collection")
                                      : Text("New Collection", comment: "Title of the form that creates a collection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel") }
                        .accessibilityIdentifier("collectionNameCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) { Text("Save", comment: "Collection name form: saves the name") }
                        .disabled(!canSave)
                        .accessibilityIdentifier("collectionNameSave")
                }
            }
            .onAppear { isFocused = true }
        }
    }

    private func save() {
        let found: BookCollections.NameProblem?
        switch mode {
        case .create(let books):
            if case .failure(let error) = library.createCollection(named: name, books: books) {
                found = error
            } else {
                found = nil
            }
        case .rename(let collection):
            found = library.renameCollection(collection.id, to: name)
        }
        if let found {
            let message = CollectionText.message(for: found)
            problem = message
            Announcer.announce(message)
        } else {
            dismiss()
        }
    }
}

// MARK: - Collections screen

/// Create, rename (tap a row), reorder (Edit, or VoiceOver's Move Up / Move Down) and delete collections. Deleting
/// asks first, and says that the books are kept.
struct CollectionsManagerView: View {
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var form: FormRoute?
    @State private var pendingDelete: BookCollection?

    private enum FormRoute: Identifiable {
        case create
        case rename(BookCollection)

        var id: String {
            switch self {
            case .create: return "create"
            case .rename(let collection): return "rename:" + collection.id
            }
        }
    }

    private var collections: [BookCollection] { library.collections.collections }

    var body: some View {
        NavigationStack {
            List {
                if collections.isEmpty {
                    Section { CollectionsEmptyState { form = .create } }
                } else {
                    Section {
                        ForEach(collections) { collection in
                            row(collection)
                        }
                        .onMove { library.moveCollections(fromOffsets: $0, toOffset: $1) }
                        .onDelete { offsets in
                            // Asks first; the row stays until the deletion is confirmed.
                            if let index = offsets.first, collections.indices.contains(index) {
                                pendingDelete = collections[index]
                            }
                        }
                    } header: {
                        Text("Your Collections", comment: "Collections screen: header of the list of collections")
                            .foregroundStyle(.secondaryText)
                    } footer: {
                        Text("Tap a collection to rename it. Use Edit to change their order.",
                             comment: "Collections screen: footer under the list of collections")
                            .foregroundStyle(.secondaryText)
                    }
                    Section {
                        Button { form = .create } label: {
                            CollectionNameRow(name: String(localized: "New Collection", comment: "Button: create a collection"),
                                              systemImage: "folder.badge.plus", isAction: true)
                        }
                        .accessibilityIdentifier("collectionsManageNew")
                    }
                }
            }
            .navigationTitle(Text("Collections", comment: "Title of the screen that manages the user's collections"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done") }
                        .accessibilityIdentifier("collectionsDone")
                }
                if !collections.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                            .accessibilityIdentifier("collectionsEdit")
                    }
                }
            }
            .sheet(item: $form) { route in
                switch route {
                case .create: CollectionNameForm(mode: .create(books: []), library: library)
                case .rename(let collection): CollectionNameForm(mode: .rename(collection), library: library)
                }
            }
            .confirmationDialog(pendingDelete.map { CollectionText.deleteTitle($0.name) } ?? "",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { collection in
                Button(role: .destructive) { library.deleteCollection(collection.id) } label: {
                    Text("Delete Collection", comment: "Confirmation button: deletes a collection (not its books)")
                }
                .accessibilityIdentifier("collectionsConfirmDelete")
                Button(role: .cancel) {} label: { Text("Cancel") }
            } message: { _ in
                Text(verbatim: CollectionText.deleteMessage)
            }
        }
    }

    private func row(_ collection: BookCollection) -> some View {
        let index = collections.firstIndex { $0.id == collection.id } ?? 0
        return Button { form = .rename(collection) } label: {
            CollectionNameRow(name: collection.name)
        }
        .accessibilityHint(Text("Renames the collection.", comment: "VoiceOver hint of a row of the Collections screen"))
        .accessibilityActions {
            Button { form = .rename(collection) } label: { Text("Rename", comment: "Action: rename a collection") }
            if index > 0 {
                Button { library.moveCollection(collection.id, by: -1) } label: {
                    Text("Move Up", comment: "VoiceOver action: move a collection one place up the list")
                }
            }
            if index < collections.count - 1 {
                Button { library.moveCollection(collection.id, by: 1) } label: {
                    Text("Move Down", comment: "VoiceOver action: move a collection one place down the list")
                }
            }
            Button { pendingDelete = collection } label: { Text("Delete") }
        }
        .contextMenu {
            Button { form = .rename(collection) } label: {
                Label { Text("Rename", comment: "Action: rename a collection") } icon: { Image(systemName: "pencil") }
            }
            Button(role: .destructive) { pendingDelete = collection } label: {
                Label { Text("Delete") } icon: { Image(systemName: "trash") }
            }
        }
        .accessibilityIdentifier("collectionRow")
    }
}

// MARK: - Picker

/// Puts books in collections and takes them out: a tap on a collection adds the books (a check mark shows they are
/// in it), a second tap takes them out. *New Collection* creates one with the books in it.
struct CollectionPicker: View {
    let target: CollectionTarget
    @ObservedObject var library: LibraryStore
    /// After *Done* (the multi-select screen closes too).
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showNewCollection = false

    var body: some View {
        NavigationStack {
            List {
                if library.collections.isEmpty {
                    Section {
                        CollectionsEmptyState { showNewCollection = true }
                    } header: {
                        Text(verbatim: target.title).foregroundStyle(.secondaryText)
                    }
                } else {
                    Section {
                        ForEach(library.collections.collections) { collection in
                            pickerRow(collection)
                        }
                    } header: {
                        Text(verbatim: target.title).foregroundStyle(.secondaryText)
                    } footer: {
                        Text("Tap a collection to add or remove. Books stay in your Library either way.",
                             comment: "Collection picker: footer under the list of collections")
                            .foregroundStyle(.secondaryText)
                    }
                    Section {
                        Button { showNewCollection = true } label: {
                            CollectionNameRow(name: String(localized: "New Collection", comment: "Button: create a collection"),
                                              systemImage: "folder.badge.plus", isAction: true)
                        }
                        .accessibilityIdentifier("collectionPickerNew")
                    }
                }
            }
            .navigationTitle(Text("Add to Collection", comment: "Title of the collection picker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                        onDone?()
                    } label: { Text("Done") }
                    .accessibilityIdentifier("collectionPickerDone")
                }
            }
            .sheet(isPresented: $showNewCollection) {
                CollectionNameForm(mode: .create(books: target.hashes), library: library)
            }
        }
    }

    private func pickerRow(_ collection: BookCollection) -> some View {
        let isIn = library.collections.containsAll(target.hashes, in: collection.id)
        return Button { library.toggleBooks(target.hashes, inCollection: collection.id) } label: {
            CollectionNameRow(name: collection.name, selected: isIn)
        }
        .accessibilityAddTraits(isIn ? .isSelected : [])
        .accessibilityHint(isIn ? Text("Removes from this collection.", comment: "VoiceOver hint of a collection the book is in (collection picker)")
                                : Text("Adds to this collection.", comment: "VoiceOver hint of a collection the book is not in (collection picker)"))
        .accessibilityIdentifier("collectionPickerRow")
    }
}

// MARK: - Choosing several books

/// A book offered in the multi-select screen.
struct SelectableBook: Identifiable {
    /// The row's hash (the local book's, when there is one).
    let id: String
    let title: String
    let author: String
}

/// *Add Books to a Collection*: every book of the Library with a selection circle, then *Add to Collection…* opens
/// the collection picker for the chosen books. A screen of its own, not a selection mode of the Library list,
/// whose grouped modes list a book in several sections.
struct BookSelectionView: View {
    let books: [SelectableBook]
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    @State private var target: CollectionTarget?

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                Section {
                    ForEach(books) { book in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: book.title)
                                .font(.headline)
                            if !book.author.isEmpty {
                                Text(verbatim: book.author)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("collectionSelectRow")
                        .tag(book.id)
                    }
                } header: {
                    Text("Choose Books", comment: "Add Books to a Collection: header of the list of books to choose from")
                        .foregroundStyle(.secondaryText)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(Text("Select Books", comment: "Title of the screen that chooses several books to add to a collection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel") }
                        .accessibilityIdentifier("collectionSelectCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        target = CollectionTarget(books: books.filter { selection.contains($0.id) })
                    } label: {
                        Text(verbatim: CollectionText.addTitle)
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("collectionSelectAdd")
                }
            }
            .sheet(item: $target) { chosen in
                CollectionPicker(target: chosen, library: library) { dismiss() }
            }
        }
    }
}
