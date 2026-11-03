# Sample books

The iPhone app bundles one small EPUB per app language (`iOSApp/Resources/SampleBooks/sample-<lang>.epub`), so a new user, or App Review, can see a book reach the watch within seconds: **Add a Sample Book** on the welcome tour's "Try It Now" page, or in the empty Library. The sample is chosen by the app's current language (`SampleBooks.preferredLanguage`), with English as the fallback (also for Traditional Chinese, which the app is not localized into).

A sample is imported through the normal EPUB import pipeline (`LibraryStore.addSample` calls `importEPUB`), so it is converted and sent to the watch exactly like the user's own books. The library entry records `sampleLanguage`, which shows a **Sample** badge on the row; otherwise it is an ordinary book and can be deleted like any other.

## Building

The EPUBs are generated, never edited by hand:

```sh
python3 scripts/samples/build_samples.py          # rebuild iOSApp/Resources/SampleBooks/*.epub
python3 scripts/samples/build_samples.py --check  # CI (linux.yml, job "samples"): committed EPUBs match the sources
```

Sources are plain text in `docs/samples-src/<lang>.txt` (front matter, `## ` chapter headings, one paragraph per line; the format is described at the top of the script). The script is standard-library Python and reproducible (fixed timestamps, order and identifiers). Each EPUB is EPUB 3 with an EPUB 2 NCX: `mimetype` first and stored, `META-INF/container.xml`, an OPF with `dc:language`, `dc:source`, `dc:rights` and `dc:date`, a navigation document, a text-only SVG cover, and one XHTML file per chapter. The last chapter, "About this sample", is written in the book's language and names the source.

`Packages/ReaderCore/Tests/ReaderCoreTests/SampleBooksTests.swift` (Linux CI, job `test-core`) parses every bundled sample with the app's `EPUBParser` and checks its language, title, author, size and structural invariants.

## Texts and rights

Every text is in its original language (no modern translation) and by an author who died more than 70 years ago (public domain in the EU, life + 70) and was first published before 1930 (public domain in the US). Project Gutenberg's header, footer, licence and trademark text were removed, as Project Gutenberg allows for public-domain texts that do not use its trademark; illustrations, transcriber's notes, prefaces and essays by other people were left out. Line breaks were joined into paragraphs and Project Gutenberg's `--` turned into dashes; nothing else was changed.

| Language | Book | Author (died) | Excerpt | Source | Size |
|---|---|---|---|---|---|
| en | *Pride and Prejudice* (1813) | Jane Austen (1817) | Chapters I–VI | [Project Gutenberg #42671](https://www.gutenberg.org/ebooks/42671), text of the first edition | 25 KB |
| es | *Don Quijote de la Mancha* (1605) | Miguel de Cervantes Saavedra (1616) | Part one, chapters I–III | [Project Gutenberg #2000](https://www.gutenberg.org/ebooks/2000) | 20 KB |
| fr | *Les Misérables* (1862) | Victor Hugo (1885) | Tome I, livre premier, chapters I–IV | [Project Gutenberg #17489](https://www.gutenberg.org/ebooks/17489) | 22 KB |
| de | *Die Verwandlung* (1915) | Franz Kafka (1924) | Chapter I (of III) | [Project Gutenberg #22367](https://www.gutenberg.org/ebooks/22367), Kurt Wolff Verlag 1917 | 19 KB |
| it | *I promessi sposi* (1840) | Alessandro Manzoni (1873) | Chapter I | [Project Gutenberg #45334](https://www.gutenberg.org/ebooks/45334), Hoepli, text of the 1840 edition (Scherillo's essay and Previati's illustrations left out) | 19 KB |
| pt-BR | *Dom Casmurro* (1899) | Machado de Assis (1908) | Chapters I–XII | [Project Gutenberg #55752](https://www.gutenberg.org/ebooks/55752), H. Garnier 1899, original spelling | 26 KB |
| ja | 『吾輩は猫である』 (1905) | 夏目漱石 Natsume Sōseki (1916) | Chapter 一 | [Aozora Bunko, card 789](https://www.aozora.gr.jp/cards/000148/card789.html) (底本：「夏目漱石全集1」ちくま文庫、筑摩書房) | 18 KB |
| zh-Hans | 《狂人日记》 (1918) | 鲁迅 Lu Xun (1936) | Complete story | [Wikisource](https://zh.wikisource.org/zh-hans/%E7%8B%82%E4%BA%BA%E6%97%A5%E8%A8%98) (《呐喊》 text, Simplified-character rendering) | 18 KB |

Notes:

- **Japanese**: Aozora Bunko's ruby (furigana) annotations, emphasis-dot notes and input notes were removed; the one JIS X 0213 character given as a note (譃) was written as the character itself. Indented diary passages are block quotations. Aozora's text follows its source edition's modern kana usage.
- **Chinese**: Wikisource's Simplified-character rendering of the 《呐喊》 text; the untitled classical-Chinese preface has no heading in the original, so its chapter is labelled with the book title in the table of contents.
- Each EPUB repeats the source URL (`dc:source`), the rights statement (`dc:rights`) and the excerpt (`dc:description`) in its metadata, and in its final "About this sample" chapter.

## Changing or adding a sample

Edit `docs/samples-src/<lang>.txt`, bump `MODIFIED` in the script if the content changed, run the script and commit the source and the EPUB together. A new app language needs a new source file and an entry in `LANGUAGES` (script), `SampleBooks.languages` (app) and `SampleBooksTests.expected` (ReaderCore tests).
