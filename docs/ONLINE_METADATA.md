# Online book details (Open Library)

Covers and details come from the EPUB itself (`EPUBMetadataReader`, PR #46). For books whose EPUB has no cover
or no description, the iPhone app can look the book up on [Open Library](https://openlibrary.org). This is
**always the user's choice**: nothing goes online by default, and the Apple Watch app never does it.

## What the user sees

* **Settings › Book Details** (iPhone):
  * **Find Missing Details Online**, a toggle, **off by default**. When on, every book imported from then on that
    lacks a cover or a description is looked up **once**, in the background. Only an unambiguous match is applied
    (an ISBN match, or a title-and-author match that scores at least 0.85 and clearly beats the runner-up). Errors
    and uncertain matches are silent: the book just keeps its EPUB data.
  * **Look Up Missing Details Now**: the same lookup for the books already in the library (those missing a cover
    or a description and without online details yet), one at a time, with a progress row, **Stop Looking Up**,
    and a summary ("Added details to 3 of 8 books."). An error (offline, Open Library unavailable) stops it with
    a clear message.
  * **Internet Archive Privacy Policy**, a link, and a footer that says exactly what is sent (the ISBN, or the title
    and author) and to whom (Open Library, a service of the Internet Archive).
* **Book detail › Find Details Online**: an explicit, one-off lookup, available whether or not the toggle is on
  (shown while the book misses a cover, a description, or year/publisher/subjects). A sheet shows the match (cover,
  title, authors, year, publisher, subjects, description) or, for several, up to **five** to choose from; with
  none, a "No Matches Found" empty state; offline or on errors, "Couldn't Reach Open Library" with **Try Again**.
  Nothing is applied until the user taps one of the separate actions: **Use This Cover**, **Use Description**,
  **Use Year, Publisher and Subjects**. Each one turns into a check mark ("Cover Added") once applied.
* Online values are marked subtly: "Cover from Open Library" under the cover, "From Open Library" under the
  description and the year/publisher/subjects rows, and an attribution line ("Book details from Open Library, a
  project of the Internet Archive.") with **View on Open Library**, a link to the record the details came from.
* **Remove Online Details** (book detail) drops everything that came from Open Library: the book shows its
  EPUB-only data again and, if the cover was Open Library's, the generated placeholder.

## Rules

* **Never overwrite EPUB data.** Online values are stored apart from the EPUB's (`LibraryEntry.online`,
  `OnlineBookDetails`), and only for fields the EPUB lacks: cover (the generated placeholder counts as missing; an
  EPUB with only an SVG cover counts as missing too), description, year, publisher, subjects. The detail screen
  shows the EPUB value whenever there is one (`OnlineMetadataMerge.merged`). Title, authors, series, language and
  ISBN are never taken from Open Library.
* **The EPUB file is never modified.** The online values live in `library.json` and the cover thumbnails next to
  the book (`<hash>.cover.jpg`, `<hash>.watch.jpg`). The document hash (KOReader partial MD5) and therefore
  progress sync are unaffected.
* **The watch** gets a new cover the same way as covers today: `LibraryStore.onCoverAdded` sends the small
  thumbnail (`book_cover` message) to a watch that already has the book. Removing an online cover re-sends the
  book (as *Send to Apple Watch Again*), which replaces the watch's thumbnail with the placeholder.
* **Not tied to sync or Readest.** The lookup never runs as part of progress sync, a Readest download or upload.
* **Readest.** When the user uploads a book to Readest and its EPUB has no cover but the user accepted an Open
  Library cover, that cover is uploaded as the book's `cover.png` (`CoverStore.readestPNG(epubAt:fallback:)`). This
  is the user's own, private Readest storage; it is the same image the user chose to show in their own library, it
  is not redistributed publicly, and Open Library's API pages ask for no more than a courtesy link (see "Terms").
  The privacy policy says so.

## Requests

All requests are HTTPS GETs from the iPhone, through `OpenLibraryClient` (ReaderCore,
`Sources/ReaderCore/OnlineMetadata/`) and an ephemeral `URLSession` (no cookies, no disk cache).

| Step | Request | Sent |
|---|---|---|
| 1. By ISBN, when the EPUB has a valid one | `https://openlibrary.org/api/books?bibkeys=ISBN:{isbn13}[,ISBN:{isbn10}]&format=json&jscmd=data` | The ISBN, normalised (separators removed, check digit verified), as ISBN-13; an ISBN-10 is sent together with its ISBN-13 in the same request. |
| 2. Otherwise by title and author | `https://openlibrary.org/search.json?title={title}&author={first author}&limit=10&fields=key,title,author_name,first_publish_year,cover_i,subject` | The title and the first author only. Solr syntax characters become spaces; values are strictly percent-encoded. |
| 3. Description (only when needed) | `https://openlibrary.org/books/OL…M.json`, then its work `https://openlibrary.org/works/OL…W.json` | The Open Library key of the match. |
| 4. Cover (only when shown or applied) | `https://covers.openlibrary.org/b/id/{cover id}-L.jpg?default=false` | The cover id. `default=false` makes a missing cover a 404 instead of a blank image. The image is often served by a redirect to `archive.org` / `ia*.us.archive.org`. |

Every request carries `User-Agent: Folito/1.0 (https://folito.app; book details lookup)` and
`Accept: application/json, image/*`, nothing else. No personal data, no device identifier, no account data, no
reading data, nothing about other books in the library.

Matches from the search are scored (`MatchScoring`): Dice similarity of normalised title words (70 %) and author
similarity (30 %; same surname counts as a full match), case and accents folded, leading articles dropped. Results
below 0.5 are not offered; at most five are listed.

### API etiquette

From Open Library's [Developers / API page](https://openlibrary.org/developers/api) (checked 2026-11-05):
"Identify your application with a `User-Agent` header"; unidentified clients get 1 request per second, identified
ones 3; do not use the APIs for bulk downloads (use the monthly dumps instead), do not make hundreds of single-book
requests, cache where possible, and violations "may result in aggressive rate limiting or blocking". The client
therefore:

* sends the descriptive User-Agent above (app name and https://folito.app);
* makes **one request at a time**, with at least **1 second** between requests (`minimumInterval`), across the
  whole app (one shared client);
* on **429 or 503** backs off (honouring `Retry-After`, otherwise 2 s, 4 s), at most 2 retries, then gives up;
* looks a book up once in the background (`LibraryEntry.onlineLookupAt`), fetches descriptions and covers only for
  the match being shown or applied, and keeps what the user accepted on the device, so nothing is asked twice;
* requests covers by cover id, which the [Covers API](https://openlibrary.org/dev/docs/api/covers) does not
  rate-limit (lookups by ISBN/OCLC/LCCN are limited to 100 per IP per 5 minutes), and never crawls it.

The Books API page ([Books API](https://openlibrary.org/dev/docs/api/books)) calls `/api/books` a legacy endpoint
that "may be phased out in the future" and recommends `jscmd=data` as the stable format, which is what the app uses;
if it goes away, the lookup falls back to the [Search API](https://openlibrary.org/dev/docs/api/search) (step 2).
The live smoke test (below) is meant to notice such a change.

### Terms and attribution

* Open Library's data: the [licensing page](https://openlibrary.org/developers/licensing) says the Internet Archive
  "does not assert any new copyright or other proprietary rights" over the database, and notes that "there may be
  existing rights issues on some contributions and in some jurisdictions" (the dumps are commonly described as
  public domain / CC0). The app takes only bibliographic facts (year, publisher, subjects) and a description.
* Covers: the Covers API page states no licence; it asks that "a courtesy link back to Open Library is
  appreciated" and "please, do not crawl our cover API". The app shows "Cover from Open Library" and a **View on
  Open Library** link on the book's page, and only fetches covers one at a time on the user's behalf.
* Site terms and privacy: the Internet Archive's [Terms of Use, Privacy Policy and Copyright
  Policy](https://archive.org/about/terms) (linked from Open Library's footer and from Settings › Book Details).

No other provider (Google Books or similar) is used.

## Privacy

See `docs/PRIVACY_DATA_MAP.md` (section 1b-bis) and `docs/appstore/APP_PRIVACY.md` ("Online book details"): the
lookup sends the ISBN or the title and first author to Open Library, in real time, on the user's request; the
developer receives nothing. The App Privacy answers and the privacy manifests do not change.

## Tests

* ReaderCore (Linux, `OnlineMetadataTests`): ISBN normalisation and ISBN-10 → 13, request building and escaping,
  parsing of fixture JSON trimmed from real answers, match scoring, the merge rules (never overwrite EPUB data,
  cover and description as separate choices), and the client's etiquette (sequential and spaced requests, backoff on
  429/503, header set) with a mocked transport. No unit test touches the network.
* `OpenLibraryLiveTests` (linux.yml job `openlibrary-smoke`): one live Books API request by ISBN; skipped unless
  `OPENLIBRARY_LIVE_TEST=1`, and skipped (not failed) on network errors.
* iOS UI tests (`OnlineMetadataUITests`, `-UITestingMockOnlineMetadata`, no network): Settings, the bulk lookup,
  the detail action, the confirmation sheet with one/several/no matches and offline, Remove Online Details, the
  largest text size. Screenshots: artifact `online-metadata-screenshots` (macos.yml). The sheet is also audited in
  `AccessibilityAuditTests.testOnlineMatchSheetAudit` (accessibility.yml).
