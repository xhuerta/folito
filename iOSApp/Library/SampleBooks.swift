import Foundation

/// Small public-domain EPUBs bundled with the app (iOSApp/Resources/SampleBooks/sample-<language>.epub), one per
/// app language, so a new user (or App Review) can see a book reach the watch without finding an EPUB first.
/// Built by scripts/samples/build_samples.py from docs/samples-src; sources and rights in docs/SAMPLE_BOOKS.md.
/// They are imported through the normal pipeline (`LibraryStore.addSample`) and can be deleted like any book.
enum SampleBooks {
    /// The app's languages, each with a sample. Keep in sync with LANGUAGES in scripts/samples/build_samples.py.
    static let languages = ["en", "es", "fr", "de", "it", "pt-BR", "ja", "zh-Hans"]
    static let fallbackLanguage = "en"

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
