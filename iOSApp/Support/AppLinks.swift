import Foundation

/// Every external link the iPhone app shows. Single source of truth: change them here only.
enum AppLinks {
    /// Support site, published from docs/site to the public repo xhuerta/folito-site (GitHub Pages, custom domain folito.app).
    static let site = URL(string: "https://folito.app/")!

    /// Same URL as App Store Connect's privacy policy field (guideline 5.1.1(i)).
    static var privacyPolicy: URL { page("privacy.html") }

    /// App Store Connect "Support URL".
    static var support: URL { page("support.html") }

    /// The page in the reader's language when the site is translated into it (es/, fr/, de/, it/, pt-br/, ja/,
    /// zh-hans/; see scripts/site/build.py); English, at the site root, for every other language.
    static func page(_ name: String, languageCode: String? = Locale.preferredLanguages.first) -> URL {
        guard let folder = siteFolder(languageCode: languageCode) else { return site.appending(path: name) }
        return site.appending(path: "\(folder)/\(name)")
    }

    /// Site folder for a BCP 47 language tag, or nil for English and for languages the site is not translated into.
    static func siteFolder(languageCode: String?) -> String? {
        guard let languageCode else { return nil }
        let language = Locale.Language(identifier: languageCode)
        switch language.languageCode {
        case .spanish?: return "es"
        case .french?: return "fr"
        case .german?: return "de"
        case .italian?: return "it"
        // Only Brazilian Portuguese is published; it is the closest match for every Portuguese reader.
        case .portuguese?: return "pt-br"
        case .japanese?: return "ja"
        case .chinese?:
            // Only Simplified Chinese is published: "zh-Hans", "zh-CN", "zh-SG" or a bare "zh". Traditional
            // (zh-Hant, zh-TW, zh-HK, zh-MO) readers get English rather than a script they may not read.
            let script = language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
            return script == .hanTraditional ? nil : "zh-hans"
        default: return nil
        }
    }
}

/// App version and build as shown in Settings > About.
enum AppVersion {
    /// "1.2 (34)" from `CFBundleShortVersionString` and `CFBundleVersion`; whichever is missing is left out.
    static func displayString(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = (info?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (version.isEmpty, build.isEmpty) {
        case (false, false):
            return String(localized: "\(version) (\(build))",
                          comment: "App version followed by the build number in parentheses, e.g. 1.2 (34)")
        case (false, true): return version
        case (true, false): return build
        case (true, true): return String(localized: "Unknown", comment: "App version could not be read")
        }
    }
}

/// An open-source component that ships inside the app, with its licence text bundled as a resource.
struct OpenSourceComponent: Identifiable, Equatable {
    var id: String { name }
    let name: String
    /// SPDX identifier, shown as-is (not translated).
    let license: String
    let homepage: URL
    /// Resource name (without extension, type `txt`) holding the full licence and NOTICE text.
    let resource: String

    /// Every third-party package linked into the app (see Packages/ReaderCore/Package.resolved).
    /// Licences verified on each repository at the pinned revision.
    static let all: [OpenSourceComponent] = [
        OpenSourceComponent(name: "ZIPFoundation", license: "MIT",
                            homepage: URL(string: "https://github.com/weichsel/ZIPFoundation")!,
                            resource: "License-ZIPFoundation"),
        OpenSourceComponent(name: "Swift Crypto", license: "Apache-2.0",
                            homepage: URL(string: "https://github.com/apple/swift-crypto")!,
                            resource: "License-swift-crypto"),
        OpenSourceComponent(name: "SwiftASN1", license: "Apache-2.0",
                            homepage: URL(string: "https://github.com/apple/swift-asn1")!,
                            resource: "License-swift-asn1"),
    ]

    func licenseText(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resource, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
