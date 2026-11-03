import SwiftUI
import UniformTypeIdentifiers

/// The welcome tour: four short pages shown once on first launch (and from Settings › About). Every page scrolls,
/// so nothing is cut off at the largest accessibility text sizes; Skip is always available; VoiceOver moves to each
/// page's title; page changes do not slide when Reduce Motion is on.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var connectivity: PhoneConnectivity
    @ObservedObject var settings: SyncSettings
    @ObservedObject var dictionaries: DictionaryManager

    @State private var page: OnboardingPage = .welcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .id(page)
                    .transition(pageTransition)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Page \(page.number) of \(OnboardingPage.allCases.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
                if page != OnboardingPage.allCases.last {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Skip") { model.finish() }
                            .accessibilityHint("Closes the welcome tour. You can open it again in Settings.")
                            .accessibilityIdentifier("onboardingSkip")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    /// A short slide from the trailing edge; a plain cross-fade with Reduce Motion.
    private var pageTransition: AnyTransition {
        reduceMotion ? AnyTransition.opacity
            : AnyTransition.asymmetric(insertion: AnyTransition.move(edge: .trailing).combined(with: AnyTransition.opacity),
                                       removal: AnyTransition.opacity)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome: WelcomePage(titleFocused: $titleFocused)
        case .howItWorks: HowItWorksPage(status: connectivity.status, titleFocused: $titleFocused)
        case .tryIt: TryItPage(library: library, connectivity: connectivity, titleFocused: $titleFocused)
        case .extras: ExtrasPage(settings: settings, dictionaries: dictionaries, connectivity: connectivity,
                                 titleFocused: $titleFocused)
        }
    }

    private var bottomBar: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return VStack(spacing: 0) {
            Divider()
            layout {
                if let previous = page.previous {
                    Button { go(to: previous) } label: {
                        Text("Back").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboardingBack")
                }
                if let next = page.next {
                    Button { go(to: next) } label: {
                        Text("Continue").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboardingContinue")
                } else {
                    Button { model.finish() } label: {
                        Text("Start Reading").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboardingDone")
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func go(to newPage: OnboardingPage) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page = newPage }
        // Let the new page appear, then move VoiceOver to its title.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { titleFocused = true }
    }
}

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome, howItWorks, tryIt, extras
    var id: Int { rawValue }
    var number: Int { rawValue + 1 }
    var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }
    var previous: OnboardingPage? { OnboardingPage(rawValue: rawValue - 1) }
}

// MARK: - Building blocks

/// A page title: large, a VoiceOver heading, and where VoiceOver lands when the page appears.
private struct PageTitle: View {
    let text: Text
    var titleFocused: AccessibilityFocusState<Bool>.Binding

    var body: some View {
        text
            .font(.largeTitle.bold())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused(titleFocused)
            .accessibilityIdentifier("onboardingTitle")
    }
}

/// A large decorative symbol at the top of a page (hidden from VoiceOver).
private struct HeroSymbol: View {
    let systemName: String
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 56

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size))
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
    }
}

/// An icon with a bold title and a sentence below, read by VoiceOver as one element.
private struct InfoRow: View {
    let systemImage: String
    let title: Text
    let text: Text
    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 32

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                title.font(.headline)
                text
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A rounded panel on the secondary background, for status and links.
private struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    var titleFocused: AccessibilityFocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HeroSymbol(systemName: "applewatch")
            PageTitle(text: Text("Welcome to Folito"), titleFocused: titleFocused)
            Text("Read your own EPUB books on Apple Watch.")
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            InfoRow(systemImage: "book", title: Text("Books you already have"),
                    text: Text("Any DRM-free EPUB file works: no account, no store."))
            InfoRow(systemImage: "wifi.slash", title: Text("Made for the wrist"),
                    text: Text("Scroll with the Digital Crown and read offline, without your iPhone nearby."))
        }
    }
}

private struct HowItWorksPage: View {
    let status: WatchStatus
    var titleFocused: AccessibilityFocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HeroSymbol(systemName: "iphone.and.arrow.forward")
            PageTitle(text: Text("How It Works"), titleFocused: titleFocused)
            InfoRow(systemImage: "square.and.arrow.down", title: Text("1. Import on your iPhone"),
                    text: Text("Open an EPUB from the Files app or the share sheet and choose Folito, or tap Import EPUB in the Library."))
            InfoRow(systemImage: "applewatch.and.arrow.forward", title: Text("2. Sent to your watch automatically"),
                    text: Text("The iPhone app sends each book to Folito on your Apple Watch. Books reach the watch only through the iPhone app, so keep it installed."))
            InfoRow(systemImage: "book.closed", title: Text("3. Read on your watch"),
                    text: Text("Books are stored on the watch and can be read offline."))
            watchAppPanel
        }
    }

    /// Whether the watch app is installed, from the same WatchConnectivity state the Library shows.
    @ViewBuilder
    private var watchAppPanel: some View {
        Panel {
            switch status {
            case .ready:
                TintedLabel("Folito is installed on your Apple Watch.", systemImage: "checkmark.circle.fill", tint: AnyShapeStyle(.tint))
                    .font(.headline)
            case .appNotInstalled:
                Label("Folito Isn’t on Your Apple Watch", systemImage: "applewatch")
                    .font(.headline)
                Text("Open the Watch app on this iPhone, find Folito under Available Apps and tap Install. Your books are sent automatically once it’s installed.")
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case .notPaired:
                Label("No Apple Watch", systemImage: "applewatch.slash")
                    .font(.headline)
                Text("Pair an Apple Watch with this iPhone to read on your wrist. Books you import stay here and are sent once a watch is paired.")
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case .activating, .unsupported:
                Label("The watch app", systemImage: "applewatch")
                    .font(.headline)
                Text("Folito for Apple Watch installs with the iPhone app. If it isn’t on your watch, open the Watch app on this iPhone, find Folito under Available Apps and tap Install.")
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboardingWatchStatus")
    }
}

private struct TryItPage: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var connectivity: PhoneConnectivity
    var titleFocused: AccessibilityFocusState<Bool>.Binding

    @State private var showImporter = false
    /// An import this page started and is waiting for.
    @State private var awaitingImport = false
    /// The book this page imported (or found already imported), shown with its watch state.
    @State private var resultHash: String?
    @State private var error: UserFacingError?

    private let sampleLanguage = SampleBooks.preferredLanguage

    private var result: LibraryEntry? {
        guard let resultHash else { return nil }
        return library.entries.first { $0.documentHash == resultHash }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HeroSymbol(systemName: "books.vertical")
            PageTitle(text: Text("Try It Now"), titleFocused: titleFocused)
            Text("Add a short public-domain sample book and watch it arrive on your Apple Watch. It’s a book like any other: delete it whenever you like.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                Button(action: addSample) {
                    Label("Add a Sample Book", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("onboardingAddSample")
                Button { showImporter = true } label: {
                    Label("Import My Own Book", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboardingImportOwn")
            }
            .controlSize(.large)
            .disabled(library.isImporting)
            status
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [EPUBContentType.epub]) { picked in
            switch picked {
            case .success(let url):
                error = nil
                awaitingImport = true
                library.importEPUB(from: url)
            case .failure:
                error = .pickerFailed()
            }
        }
        .onChange(of: library.lastImported) { _, entry in
            guard awaitingImport, let entry else { return }
            awaitingImport = false
            resultHash = entry.documentHash
        }
        .onChange(of: library.importError) { _, newError in
            guard awaitingImport, let newError else { return }
            // Shown here, on the tour; the Library's alert would only appear after the tour closes.
            awaitingImport = false
            error = newError
            library.importError = nil
        }
        .onChange(of: resultHash) { _, _ in
            if let result { Announcer.announce(addedText(result)) }
        }
    }

    private func addSample() {
        error = nil
        if let existing = library.sampleEntry(language: sampleLanguage) {
            resultHash = existing.documentHash
            Announcer.announce(addedText(existing))
        } else if library.addSample(language: sampleLanguage) {
            awaitingImport = true
        } else {
            // Only possible in a build without the sample resources.
            error = .pickerFailed()
        }
    }

    private func addedText(_ entry: LibraryEntry) -> String {
        String(localized: "“\(entry.title)” is in your library.",
               comment: "Welcome tour: result after adding a book; the placeholder is the book title")
    }

    @ViewBuilder
    private var status: some View {
        if awaitingImport && library.isImporting {
            Panel {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Importing book")
                }
            }
            .accessibilityElement(children: .combine)
        } else if let error {
            Panel {
                Label(error.title, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(error.message)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else if let result {
            let state = BookWatchState(sentToWatch: result.sentToWatch,
                                       inFlight: connectivity.outstandingHashes.contains(result.documentHash))
            Panel {
                TintedLabel(verbatim: addedText(result), systemImage: "checkmark.circle.fill", tint: AnyShapeStyle(.tint))
                    .font(.headline)
                TintedLabel(verbatim: state.text, systemImage: state.systemImage,
                            tint: state == .onWatch ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondaryText))
                    .foregroundStyle(.secondaryText)
                if !connectivity.status.canSend {
                    Text("It’s sent as soon as Folito on your Apple Watch can receive it.")
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboardingImportResult")
        }
    }
}

private struct ExtrasPage: View {
    @ObservedObject var settings: SyncSettings
    @ObservedObject var dictionaries: DictionaryManager
    @ObservedObject var connectivity: PhoneConnectivity
    var titleFocused: AccessibilityFocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HeroSymbol(systemName: "sparkles")
            PageTitle(text: Text("Optional Extras"), titleFocused: titleFocused)
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(systemImage: "character.book.closed", title: Text("Offline dictionaries"),
                        text: Text("Look up words on your watch, even without a connection."))
                NavigationLink {
                    DictionariesView(manager: dictionaries, connectivity: connectivity)
                } label: {
                    linkLabel(Text("Open Dictionaries"))
                }
                .accessibilityIdentifier("onboardingDictionaries")
            }
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(systemImage: "arrow.triangle.2.circlepath", title: Text("Progress sync"),
                        text: Text("Continue the same book in KOReader or Readest. Off unless you turn it on."))
                NavigationLink {
                    SyncSettingsView(settings: settings)
                } label: {
                    linkLabel(Text("Open Progress Sync"))
                }
                .accessibilityIdentifier("onboardingSync")
            }
            Text("Both are also in Settings.")
                .foregroundStyle(.secondaryText)
            Panel {
                Text("A note from the developer")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Folito is made by Xabier Lahuerta, an independent developer. It’s open source and has no ads and no tracking. Thanks for trying it!")
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: AppLinks.sourceCode) {
                    Label("Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityHint("Opens in your web browser.")
            }
        }
    }

    private func linkLabel(_ title: Text) -> some View {
        HStack {
            title
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// The EPUB content type for document pickers.
enum EPUBContentType {
    static let epub = UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub") ?? .data
}

#Preview {
    OnboardingView(model: OnboardingModel(arguments: ["-UITestingShowOnboarding"]),
                   library: LibraryStore(rootDirectory: FileManager.default.temporaryDirectory
                       .appendingPathComponent("preview-onboarding")),
                   connectivity: PhoneConnectivity(),
                   settings: SyncSettings(clientFactory: { _ in MockKOSyncClient() }),
                   dictionaries: DictionaryManager())
}
