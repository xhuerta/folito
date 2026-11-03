import Foundation

/// Small public-domain EPUBs bundled with the app (iOSApp/Resources/SampleBooks/sample-<language>.epub), one per
/// app language, so a new user (or App Review) can see a book reach the watch without finding an EPUB first.
/// Built by scripts/samples/build_samples.py from docs/samples-src; sources and rights in docs/SAMPLE_BOOKS.md.
/// They are imported through the normal pipeline (`LibraryStore.addSample`) and can be deleted like any book.
enum SampleBooks {
    /// The app's languages, each with a sample. Keep in sync with LANGUAGES in scripts/samples/build_samples.py.
    static let languages = ["en", "es", "fr", "de", "it", "pt-BR", "ja", "zh-Hans"]
    static let fallbackLanguage = "en"

    /// One bundled sample, as listed under "Other Languages…". Title and author match the EPUB's metadata
    /// (docs/samples-src/<language>.txt; checked by `SampleBookSelectionTests`).
    struct Sample: Identifiable, Equatable {
        let language: String
        let title: String
        let author: String
        var id: String { language }

        /// The language's name in that language ("Español", "Deutsch", "日本語").
        var nativeLanguageName: String { SampleBooks.nativeName(for: language) }
    }

    /// Every bundled sample, in `languages` order.
    static let all: [Sample] = [
        Sample(language: "en", title: "Pride and Prejudice", author: "Jane Austen"),
        Sample(language: "es", title: "Don Quijote de la Mancha", author: "Miguel de Cervantes Saavedra"),
        Sample(language: "fr", title: "Les Misérables", author: "Victor Hugo"),
        Sample(language: "de", title: "Die Verwandlung", author: "Franz Kafka"),
        Sample(language: "it", title: "I promessi sposi", author: "Alessandro Manzoni"),
        Sample(language: "pt-BR", title: "Dom Casmurro", author: "Machado de Assis"),
        Sample(language: "ja", title: "吾輩は猫である", author: "夏目漱石"),
        Sample(language: "zh-Hans", title: "狂人日记", author: "鲁迅"),
    ]

    /// All samples with `preferred` (normally `preferredLanguage`) first, the rest in `languages` order.
    static func ordered(preferred: String) -> [Sample] {
        all.filter { $0.language == preferred } + all.filter { $0.language != preferred }
    }

    /// A language's own name for itself, with a capital first letter where the script has one.
    static func nativeName(for language: String) -> String {
        let locale = Locale(identifier: language)
        guard let name = locale.localizedString(forIdentifier: language), let first = name.first else {
            return language
        }
        return String(first).uppercased(with: locale) + name.dropFirst()
    }

    /// The sample for the language the app is running in (`Bundle.preferredLocalizations`), English otherwise.
    static var preferredLanguage: String {
        language(for: Bundle.main.preferredLocalizations.first)
    }

    /// Maps a BCP 47 tag to one of `languages`: any Portuguese to pt-BR, Simplified (or unspecified) Chinese to
    /// zh-Hans, and anything without a sample (including Traditional Chinese) to English.
    static func language(for tag: String?) -> String {
        guard let tag, !tag.isEmpty else { return fallbackLanguage }
        let language = Locale.Language(identifier: tag)
        switch language.languageCode {
        case .english?: return "en"
        case .spanish?: return "es"
        case .french?: return "fr"
        case .german?: return "de"
        case .italian?: return "it"
        case .portuguese?: return "pt-BR"
        case .japanese?: return "ja"
        case .chinese?:
            let script = language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
            return script == .hanTraditional ? fallbackLanguage : "zh-Hans"
        default: return fallbackLanguage
        }
    }

    static func resourceName(for language: String) -> String { "sample-\(language)" }

    static func url(for language: String, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName(for: language), withExtension: "epub")
    }
}
