import Foundation

/// A dictionary the iPhone app can download. See docs/DICTIONARIES.md (sources, licences, how to add one).
public struct DictionaryDescriptor: Identifiable, Equatable, Sendable {
    /// Stable id, also the installed file name and the WatchConnectivity id ("readerdict-en").
    public var id: String
    /// Primary language subtag of the headwords (and of the definitions: these are monolingual).
    public var language: String
    /// Where the source file is downloaded from (HTTPS).
    public var downloadURL: URL
    /// Approximate download size in bytes (for the list; the real size comes from the server).
    public var downloadSize: Int64
    /// Approximate size of the converted file on the watch, in bytes.
    public var installedSize: Int64
    /// Approximate number of headwords.
    public var headwords: Int
    /// SHA-256 of the download, when the source publishes one (reader.dict does not: the ZIP's CRC-32s,
    /// the HTTP length and the StarDict/gzip internal checks are verified instead).
    public var sha256: String?
    /// Where the data comes from ("Wiktionary").
    public var dataSource: String
    public var dataSourceURL: URL
    /// Who compiled the downloadable file ("reader.dict").
    public var publisher: String
    public var publisherURL: URL
    public var license: String
    public var licenseURL: URL

    /// Credit line stored in the converted file (English; the apps show a localized version).
    public var attribution: String {
        "Definitions from \(dataSource) (\(dataSourceURL.absoluteString)) by its contributors, licensed under "
            + "\(license) (\(licenseURL.absoluteString)). Compiled by \(publisher) (\(publisherURL.absoluteString)). "
            + "Converted by Folito: formatting removed, long entries shortened."
    }

    /// Short source label shown under every definition.
    public var shortSource: String { "\(dataSource) \u{00B7} \(publisher) \u{00B7} \(license)" }

    /// Footer of the compact file built from this download.
    public func compactInfo(sourceVersion: String = "") -> CompactDictionaryInfo {
        CompactDictionaryInfo(id: id, name: "\(publisher) \(language.uppercased())", language: language,
                              source: shortSource, dataSource: dataSource, publisher: publisher, license: license, licenseURL: licenseURL.absoluteString,
                              attribution: attribution, sourceURL: downloadURL.absoluteString,
                              sourceVersion: sourceVersion)
    }
}

public enum DictionaryCatalog {
    static let wiktionary = URL(string: "https://www.wiktionary.org/")!
    static let readerDict = URL(string: "https://www.reader-dict.com/")!
    static let ccBySA4 = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!

    /// reader.dict monolingual StarDict files, without etymologies (smaller; Folito does not show
    /// etymologies). Sizes measured on the October 2026 files.
    static func readerDict(_ lang: String, download: Int64, installed: Int64, headwords: Int) -> DictionaryDescriptor {
        DictionaryDescriptor(
            id: "readerdict-\(lang)", language: lang,
            downloadURL: URL(string: "https://www.reader-dict.com/file/\(lang)/dict-\(lang)-\(lang)-noetym.zip")!,
            downloadSize: download, installedSize: installed, headwords: headwords, sha256: nil,
            dataSource: "Wiktionary", dataSourceURL: wiktionary,
            publisher: "reader.dict", publisherURL: readerDict,
            license: "CC BY-SA 4.0", licenseURL: ccBySA4)
    }

    /// One monolingual dictionary for each app language.
    public static let all: [DictionaryDescriptor] = [
        readerDict("en", download: 48_779_057, installed: 50_198_671, headwords: 847_544),
        readerDict("es", download: 9_783_364, installed: 10_768_120, headwords: 110_616),
        readerDict("fr", download: 32_369_677, installed: 35_837_459, headwords: 522_980),
        readerDict("de", download: 14_534_282, installed: 15_794_050, headwords: 183_237),
        readerDict("it", download: 6_496_721, installed: 6_852_076, headwords: 73_364),
        readerDict("pt", download: 6_199_722, installed: 6_805_281, headwords: 86_385),
        readerDict("ja", download: 7_144_573, installed: 7_047_598, headwords: 108_290),
        readerDict("zh", download: 3_664_692, installed: 3_950_287, headwords: 75_793),
    ]

    public static func descriptor(id: String) -> DictionaryDescriptor? { all.first { $0.id == id } }
}
