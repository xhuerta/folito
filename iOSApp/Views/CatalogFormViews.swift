import SwiftUI
import ReaderCore

// MARK: - Add

/// Adds a catalog by address, with an optional sign-in (user name and password) for self-hosted servers. The
/// address and the sign-in are checked by reading the catalog once; the sign-in is then saved in the Keychain
/// (docs/OPDS.md, "Sign-in").
struct AddCatalogView: View {
    @ObservedObject var catalogs: CatalogStore
    @Environment(\.dismiss) private var dismiss
    /// Starts with the scheme, so the field shows text rather than a low-contrast placeholder.
    @State private var address = "https://"
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var problem: String?
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Visible labels above the fields instead of placeholders: placeholder text is a light
                    // system gray, below 4.5:1 (docs/ACCESSIBILITY.md).
                    CatalogFieldLabel(text: Text("Address", comment: "Add Catalog: label of the catalog address field"))
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
                    CatalogFieldLabel(text: Text("Name (Optional)", comment: "Add Catalog: label of the optional name field"))
                    TextField(text: $name, prompt: Text(verbatim: "")) {
                        Text("Name (Optional)", comment: "Add Catalog: label of the optional name field")
                    }
                    // With a prompt, the label closure is not read by VoiceOver: name the field explicitly.
                    .accessibilityLabel(Text("Name (Optional)", comment: "Add Catalog: label of the optional name field"))
                    .accessibilityIdentifier("catalogName")
                } footer: {
                    Text("The address of an OPDS catalog, for example a Calibre, Calibre-Web, Kavita or Komga server.",
                         comment: "Add Catalog: footer under the address and name fields")
                        .foregroundStyle(.secondaryText)
                }
                CatalogSignInSection(username: $username, password: $password, savedUsername: nil)
                if let problem { CatalogProblemSection(message: problem) }
                Section {
                    if isChecking {
                        CatalogCheckingRow()
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

    private func add() async {
        problem = nil
        isChecking = true
        defer { isChecking = false }
        if let message = await catalogs.add(address: address, name: name, username: username, password: password) {
            problem = message
            Announcer.announce(message)
        } else {
            password = ""
            dismiss()
        }
    }
}

// MARK: - Edit

/// Edits a catalog the user added: its name and its sign-in, or removes it. With `signInOnly` (opened from a
/// catalog page that answered "sign-in needed") only the sign-in is shown. The saved password is never shown or
/// put back into a field: an empty password keeps it.
///
/// Cards in a `ScrollView`, not a `Form` (docs/ACCESSIBILITY.md, "Catalogs"): as a `Form`, the rows and footers
/// that were fully on screen in the middle of the longer edit form were flagged "Dynamic Type font sizes are
/// partially unsupported" at AX5 (the mid-list artifact). *Save* / *Sign In* is an icon bar button, so the keyboard
/// never covers it: as a row under the fields it stayed under the keyboard on CI's iPhones, and neither the
/// `Form` nor the `ScrollView` moved or closed the keyboard on a swipe. Dragging the content also closes the keyboard.
struct EditCatalogView: View {
    let catalog: OPDSCatalog
    var signInOnly = false
    @ObservedObject var catalogs: CatalogStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var username: String
    @State private var password = ""
    @State private var problem: String?
    @State private var isChecking = false

    init(catalog: OPDSCatalog, signInOnly: Bool = false, catalogs: CatalogStore) {
        self.catalog = catalog
        self.signInOnly = signInOnly
        self.catalogs = catalogs
        _name = State(initialValue: catalog.title)
        _username = State(initialValue: catalogs.signIn(for: catalog) ?? "")
    }

    private var canSignIn: Bool { OPDSSignInPolicy.canSignIn(to: catalog.url) }
    private var savedUsername: String? { catalogs.signIn(for: catalog) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !signInOnly { catalogCard }
                    if canSignIn {
                        CatalogSignInCard(username: $username, password: $password, savedUsername: savedUsername)
                    } else {
                        DetailCard {
                            Text("Sign-in is available only for catalogs with an https:// address, so that the password is never sent unencrypted.",
                                 comment: "Edit Catalog: shown instead of the sign-in fields for a plain http:// catalog")
                                .font(.body)
                                .foregroundStyle(.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if isChecking {
                        DetailCard { CatalogCheckingRow() }
                    } else if let problem {
                        DetailCard { CatalogProblemLabel(message: problem) }
                    }
                    if !signInOnly { removeCard }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.immediately)
            .readableScrollEdges()
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(signInOnly
                             ? Text("Sign In", comment: "Title of the form that asks for a catalog's user name and password")
                             : Text("Edit Catalog", comment: "Title of the form that edits a catalog the user added"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label { Text("Cancel") } icon: { Image(systemName: "xmark") }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("catalogEditCancel")
                }
                ToolbarItem(placement: .confirmationAction) { saveButton }
            }
        }
    }

    /// The name field and the address, as text (the address cannot be changed).
    private var catalogCard: some View {
        DetailCard {
            CatalogCardField(label: Text("Name", comment: "Edit Catalog: label of the catalog name field")) {
                TextField(text: $name, prompt: Text(verbatim: "")) {
                    Text("Name", comment: "Edit Catalog: label of the catalog name field")
                }
                .accessibilityLabel(Text("Name", comment: "Edit Catalog: label of the catalog name field"))
                .accessibilityIdentifier("catalogEditName")
            }
            Divider()
            // Title above value, like `DetailRow` (a subheadline secondary title was flagged for contrast here).
            VStack(alignment: .leading, spacing: 2) {
                Text("Address", comment: "Add Catalog: label of the catalog address field")
                    .font(.body)
                Text(verbatim: catalog.url.absoluteString)
                    .font(.body)
                    .foregroundStyle(.secondaryText)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One element named "Address" with the address as its value: a URL alone is not a human-readable label.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Address", comment: "Add Catalog: label of the catalog address field"))
            .accessibilityValue(Text(verbatim: catalog.url.absoluteString))
            .accessibilityIdentifier("catalogEditAddress")
        }
    }

    /// An icon bar button (a checkmark, labelled *Sign In* or *Save*), like the other bar buttons: a text bar
    /// button keeps a fixed font size and is flagged by the Dynamic Type audit (docs/ACCESSIBILITY.md).
    private var saveButton: some View {
        Button { Task { await save() } } label: {
            Label {
                if signInOnly {
                    Text("Sign In", comment: "Catalog sign-in: button that checks and saves the user name and password")
                } else {
                    Text("Save", comment: "Edit Catalog: button that saves the name and sign-in")
                }
            } icon: {
                Image(systemName: "checkmark")
            }
        }
        .labelStyle(.iconOnly)
        .disabled(isChecking)
        .accessibilityIdentifier("catalogEditSave")
    }

    private var removeCard: some View {
        DetailCard {
            if savedUsername != nil {
                Button(role: .destructive) {
                    catalogs.removeSignIn(for: catalog)
                    username = ""
                    password = ""
                    Announcer.announce(String(localized: "Sign-in removed.",
                                              comment: "VoiceOver announcement after a catalog's saved sign-in was deleted"))
                } label: {
                    Text("Remove Sign-In", comment: "Edit Catalog: deletes the saved user name and password from the Keychain")
                        .foregroundStyle(.destructiveText)
                        .modifier(ActionLabel())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("catalogRemoveSignIn")
                Divider()
            }
            Button(role: .destructive) {
                catalogs.remove(catalog)
                dismiss()
            } label: {
                Text("Remove Catalog", comment: "Edit Catalog: removes the catalog (and its sign-in) from the list")
                    .foregroundStyle(.destructiveText)
                    .modifier(ActionLabel())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("catalogRemove")
        }
    }

    private func save() async {
        problem = nil
        isChecking = true
        defer { isChecking = false }
        if let message = await catalogs.update(catalog, name: name, username: username, password: password) {
            problem = message
            Announcer.announce(message)
        } else {
            password = ""
            dismiss()
        }
    }
}

// MARK: - Shared parts

/// A field's visible label, in its own row above the field.
struct CatalogFieldLabel: View {
    let text: Text

    var body: some View {
        text.font(.subheadline).foregroundStyle(.secondaryText)
            .listRowSeparator(.hidden, edges: .bottom)
    }
}

/// User name and password fields with visible labels, and what Folito does with them.
struct CatalogSignInSection: View {
    @Binding var username: String
    @Binding var password: String
    /// The saved sign-in's user name, if there is one: the password field then may stay empty.
    let savedUsername: String?

    var body: some View {
        Section {
            CatalogFieldLabel(text: Text("User Name (Optional)", comment: "Catalog form: label of the optional sign-in user name field"))
            TextField(text: $username, prompt: Text(verbatim: "")) {
                Text("User Name", comment: "Catalog form: label of the sign-in user name field")
            }
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(Text("User Name", comment: "Catalog form: label of the sign-in user name field"))
            .accessibilityIdentifier("catalogUsername")
            CatalogFieldLabel(text: Text("Password", comment: "Catalog form: label of the sign-in password field"))
            SecureField(text: $password, prompt: Text(verbatim: "")) {
                Text("Password", comment: "Catalog form: label of the sign-in password field")
            }
            .textContentType(.password)
            .accessibilityLabel(Text("Password", comment: "Catalog form: label of the sign-in password field"))
            .accessibilityIdentifier("catalogPassword")
        } footer: {
            CatalogSignInNotes(savedUsername: savedUsername)
        }
    }
}

/// The sign-in fields as a card with their notes under it, for the card layout of `EditCatalogView`.
struct CatalogSignInCard: View {
    @Binding var username: String
    @Binding var password: String
    let savedUsername: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailCard {
                CatalogCardField(label: Text("User Name (Optional)", comment: "Catalog form: label of the optional sign-in user name field")) {
                    TextField(text: $username, prompt: Text(verbatim: "")) {
                        Text("User Name", comment: "Catalog form: label of the sign-in user name field")
                    }
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text("User Name", comment: "Catalog form: label of the sign-in user name field"))
                    .accessibilityIdentifier("catalogUsername")
                }
                Divider()
                CatalogCardField(label: Text("Password", comment: "Catalog form: label of the sign-in password field")) {
                    SecureField(text: $password, prompt: Text(verbatim: "")) {
                        Text("Password", comment: "Catalog form: label of the sign-in password field")
                    }
                    .textContentType(.password)
                    .accessibilityLabel(Text("Password", comment: "Catalog form: label of the sign-in password field"))
                    .accessibilityIdentifier("catalogPassword")
                }
            }
            // Footnote text that wraps at every size, like a form footer.
            CatalogSignInNotes(savedUsername: savedUsername)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }
}

/// What Folito does with the sign-in, and how to keep or remove a saved one.
struct CatalogSignInNotes: View {
    let savedUsername: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if savedUsername != nil {
                Text("A password is saved. Leave the password empty to keep it, or clear both fields to remove the sign-in.",
                     comment: "Edit Catalog: footer of the sign-in fields when a sign-in is saved")
            }
            Text("Only for catalogs that ask for one, such as Calibre, Calibre-Web or Komga. Folito keeps the password in this iPhone’s Keychain and sends it only to this catalog’s server, over an encrypted https:// connection.",
                 comment: "Catalog form: footer under the sign-in fields")
        }
        .foregroundStyle(.secondaryText)
    }
}

/// A field in a card: its visible label above it (placeholder text is below 4.5:1; docs/ACCESSIBILITY.md).
struct CatalogCardField<Field: View>: View {
    let label: Text
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Primary, not secondaryText: the audit failed the grey label at 5.99:1 (run 45501413904).
            label.font(.subheadline).foregroundStyle(.primary)
            field
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }
}

/// The problem found when checking a catalog, as its own form section.
struct CatalogProblemSection: View {
    let message: String

    var body: some View {
        Section { CatalogProblemLabel(message: message) }
    }
}

/// The problem found when checking a catalog: a warning icon and the message, one element.
struct CatalogProblemLabel: View {
    let message: String

    var body: some View {
        Label {
            Text(message).font(.body)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("catalogProblem")
    }
}

/// "Checking Catalog…" with a spinner, in place of the form's main button.
struct CatalogCheckingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Checking Catalog…", comment: "Add Catalog: the address is being checked")
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
