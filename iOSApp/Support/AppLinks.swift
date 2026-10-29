import Foundation

/// Every external link the iPhone app shows. Single source of truth: change them here only.
enum AppLinks {
    /// Support site, published from docs/site to the public repo xhuerta/wristreader-site (GitHub Pages).
    static let site = URL(string: "https://xhuerta.github.io/wristreader-site/")!

    /// Same URL as App Store Connect's privacy policy field (guideline 5.1.1(i)).
    static var privacyPolicy: URL { page("privacy.html") }

    /// App Store Connect "Support URL".
    static var support: URL { page("support.html") }

    /// Spanish speakers get the translated pages under es/; everyone else the English ones.
    static func page(_ name: String, languageCode: String? = Locale.preferredLanguages.first) -> URL {
        let spanish = languageCode.map { Locale(identifier: $0).language.languageCode == .spanish } ?? false
        return site.appending(path: spanish ? "es/\(name)" : name)
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
