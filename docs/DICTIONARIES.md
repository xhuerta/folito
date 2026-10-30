# Offline dictionaries

Word lookup on the watch works without a connection. The iPhone app downloads the dictionaries the user
picks, converts them into a compact indexed file and sends that file to the watch, which looks words up in it
locally. No word ever leaves the device.

## Source

| | |
|---|---|
| Data | [Wiktionary](https://www.wiktionary.org), by its contributors |
| Compiled by | [reader.dict](https://www.reader-dict.com) (code: [BoboTiG/ebook-reader-dict](https://github.com/BoboTiG/ebook-reader-dict), MIT) |
| Data licence | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), as stated on reader.dict's [legal page](https://www.reader-dict.com/legal-mentions) |
| Files used | monolingual StarDict, etymology-free variant: `https://www.reader-dict.com/file/{lang}/dict-{lang}-{lang}-noetym.zip` |
| Cost | the monolingual downloads are free |

Each language edition of Wiktionary explains its own words in its own language, so every dictionary is
monolingual: Spanish words are explained in Spanish. The same URLs are used by KOReader's built-in dictionary
downloader. reader.dict refreshes the files about twice a month at the same address; the app compares the
ETag (HEAD request while *Settings › Dictionaries* is open) to offer an update.

| Language | Headwords | Download (ZIP) | On the watch |
|---|---:|---:|---:|
| English (`en`) | 847,544 | 48.8 MB | 50.2 MB |
| Spanish (`es`) | 110,616 | 9.8 MB | 10.8 MB |
| French (`fr`) | 522,980 | 32.4 MB | 35.8 MB |
| German (`de`) | 183,237 | 14.5 MB | 15.8 MB |
| Italian (`it`) | 73,364 | 6.5 MB | 6.9 MB |
| Portuguese (`pt`) | 86,385 | 6.2 MB | 6.8 MB |
| Japanese (`ja`) | 108,290 | 7.1 MB | 7.0 MB |
| Chinese (`zh`) | 75,793 | 3.7 MB | 4.0 MB |

Sizes measured on the October 2026 files. The download includes the full HTML definitions; the watch file
keeps up to 6 sections per word, 8 senses per section, 4 sub-senses per sense and 400 characters per
definition, and adds an index of every headword and every inflected form the source lists.

### Why reader.dict

Checked in October 2026:

- **reader.dict**: Wiktionary-based StarDict files for all 8 app languages, free (monolingual), CC BY-SA 4.0,
  stable per-language URLs, sizes from 4 to 49 MB, inflected forms included (`.syn`, so "ran" finds "run").
  No terms restrict downloads by apps; KOReader links the same files. The site's "All rights reserved" footer
  covers the site and the reader.dict trademark; the dictionary data is CC BY-SA 4.0 (legal page).
- **kaikki.org / wiktextract** (CC BY-SA): raw JSONL per Wiktionary edition, 340 MB to 25 GB uncompressed.
  Usable only through a server-side conversion pipeline we would have to run and host.
- **FreeDict** (GPL and others): bilingual pairs only, no monolingual dictionaries for these languages.
- **Apple's dictionaries**: watchOS has no dictionary API. `UIReferenceLibraryViewController` is iOS-only and
  only shows Apple's own UI, so its definitions cannot be copied to the watch.

## Licence obligations

CC BY-SA 4.0 applies to the dictionary data, not to Folito's code (FSL-1.1-ALv2): the app never bundles the
data and the developer never distributes it. Each user downloads the file from reader.dict, and the
conversion on their iPhone is a private adaptation for their own devices. Even so, the app gives the credit the
licence asks for wherever definitions are shown:

- the source line under every definition on the watch ("Wiktionary · reader.dict · CC BY-SA 4.0");
- *Settings › Dictionary Credits* on the watch, with the full credit and the licence URL;
- the iPhone's *Settings › Dictionaries* (credits section with links) and *Settings › Acknowledgements*.

The credit names the authors (Wiktionary contributors), the licence with its link, the compiler
(reader.dict) and the changes (shortened and reformatted by Folito). The converted file's footer stores the same
attribution text. If Folito ever hosts converted files itself, that is distribution of an adaptation: the
files must stay under CC BY-SA 4.0 with this attribution.

## Pipeline (iPhone)

`iOSApp/Dictionaries/DictionaryManager.swift`, conversion in ReaderCore:

1. **Download** over HTTPS with progress (`FileDownload`, ephemeral session, User-Agent naming the app).
2. **Verify**: HTTP 200, byte count equal to `Content-Length`, the catalog's SHA-256 when it has one
   (reader.dict publishes none), then the ZIP's CRC-32 per member (`ZIPFoundation`), the `.idx` size and word
   count against the `.ifo`, and the gzip trailer (CRC-32 and length) of the `.dict.dz`.
3. **Convert** (`StarDictConverter`): inflate `.dict.dz` to a temporary file, parse each definition
   (`StarDictDefinition`, which reuses `HTMLText`), write the compact file (`CompactDictionaryWriter`), add one
   key per headword and per `.syn` form.
4. **Install** on the phone (`InstalledDictionaries`), then **send** it to the watch with
   `WCSession.transferFile` and its SHA-256 and size (docs/WATCH_CONNECTIVITY.md). The watch checks both
   before installing. The phone keeps its copy to resend it if the watch loses it.

The conversion takes 10 s to 2 min on a Linux CI core (English and French are the slowest) and runs off the
main thread; it can be cancelled.

### Why the watch does not download directly

The watch could fetch over Wi-Fi/LTE, but the source files are ZIPs of 4 to 49 MB that must be inflated
(up to about 200 MB of temporary data for English) and parsed; that is slow and battery-hungry on the watch,
background downloads there are limited, and watch storage is the scarce resource. The iPhone app is
needed anyway to send books, so the phone does the heavy work and the watch only receives the final file.

## Compact format (`.folidict`)

`Packages/ReaderCore/Sources/ReaderCore/Dictionary/CompactDictionary.swift` documents the layout:

```
"FOLIDIC1"
definition blocks   raw deflate, about 64 KiB of encoded entries each
key buckets         128 sorted keys each, front-coded, raw deflate
block table         per block: u64 offset, u32 compressed size, u32 size
bucket table        per bucket: u64 offset, u32 compressed size, u32 size
footer              JSON CompactDictionaryInfo (id, language, source, licence, attribution, counts, offsets),
                    u32 JSON length, "FOLIDIC1"
```

Keys are the headwords and inflected forms, NFC and lower-cased (`CompactDictionaryFormat.normalizedKey`).
A lookup binary-searches the bucket table (inflating about 2 KiB per step), scans one or two buckets and
inflates one definition block: a few reads of small ranges, never the whole file. Measured on Linux: under
2 ms per lookup. Entries are a small length-prefixed binary encoding of `DictionaryEntry`.

## Lookup (watch)

`OfflineDictionaryService` tries the dictionary of the book's language first, then the other installed ones.
In each it tries `WordNormalizer.candidates` (cleaned form, lower case, German capitalised noun, simple
de-inflections). When several entries share a key it prefers the exact headword, then the lower-case one, then
base forms of an inflected form, then capitalised names ("maisons" gives "maison", not the town "Maisons").

Known limits: Japanese and Chinese text is tokenised by runs of letters, so a selected run often is not a
headword; definitions are shortened.

## Adding a source

1. Find a StarDict dictionary (`.ifo`, `.idx`, `.dict` or `.dict.dz`, optional `.syn`) with a licence that
   allows this use, served over HTTPS at a stable URL, ideally as a ZIP. Record its licence, attribution
   requirements and terms of use here.
2. Add a `DictionaryDescriptor` to `DictionaryCatalog.all` (`DictionaryCatalog.swift`): a new unique `id`,
   language, URL, approximate sizes (measure them by converting the real file once, outside the unit tests),
   `sha256` if the source publishes one, data source, publisher and licence.
3. If its HTML differs from reader.dict's (`<p>` heading + `<ol>` of senses), extend `StarDictDefinition` and
   add a fixture case to `scripts/make_dictionary_fixtures.py`. Other formats need their own converter feeding
   `CompactDictionaryWriter`.
4. Update the credits text if the licence or authors differ, the privacy documents (new download host) and
   this file.

Unit tests never download dictionaries: they use the tiny fixtures written by
`scripts/make_dictionary_fixtures.py` (`Packages/ReaderCore/Tests/Fixtures/Dictionary`).
