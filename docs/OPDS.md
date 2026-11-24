# OPDS catalogs

The iPhone app can browse OPDS 1.2 catalogs and download DRM-free EPUBs from them (issue #159, part 1 of #64).
Downloads go through the normal import, so a book from a catalog is processed, kept and sent to the Apple Watch
like any EPUB the user imports.

## Where

| Part | File |
| --- | --- |
| Feed model, acquisition rules, page merging | `Packages/ReaderCore/Sources/ReaderCore/OPDS/OPDSFeed.swift` |
| Atom/OPDS parser | `Packages/ReaderCore/Sources/ReaderCore/OPDS/OPDSParser.swift` |
| Client (feeds, covers, EPUB downloads) and errors | `Packages/ReaderCore/Sources/ReaderCore/OPDS/OPDSClient.swift` |
| Presets, address normalisation | `Packages/ReaderCore/Sources/ReaderCore/OPDS/OPDSCatalog.swift` |
| Catalog list, downloads, page model | `iOSApp/Library/CatalogStore.swift` |
| Screens | `iOSApp/Views/CatalogsView.swift` (Library › + › Catalogs) |
| Tests | `Packages/ReaderCore/Tests/ReaderCoreTests/OPDSTests.swift`, fixtures in `Tests/Fixtures/OPDS/`; `iOSApp/Tests/CatalogTests.swift` |

## Behaviour

- **Presets.** Standard Ebooks and Project Gutenberg are listed but contacted only when opened. Standard Ebooks'
  full OPDS catalog (`/feeds/opds`) is a benefit of their Patrons Circle and answers 401 without a membership
  login, so the preset is their **new releases** Atom feed (`/feeds/atom/new-releases`), which is open to
  everyone and lists EPUB downloads as `enclosure` links. Project Gutenberg's preset is `https://www.gutenberg.org/ebooks.opds/`.
- **Custom catalogs.** Added by address (`https://` is assumed when no scheme is typed; `opds://` becomes
  `https://`; other schemes and addresses with a user name or password are refused). The address is read once to
  check that it is a feed; the name defaults to the feed's title. No sign-in yet: a 401/403 answer says so.
- **Feeds.** Atom feeds and single entry documents. Elements are matched by namespace (Atom, Dublin Core terms and
  elements, OPDS, Media RSS); the DOCTYPE is dropped before parsing; relative links are resolved against the address
  the page was finally served from (after redirects); only `http`/`https` links are kept; at most 500 entries per
  page and 10 MB per feed.
- **Entries.** An entry with acquisition links is a book; one with only a link to another Atom feed (not
  `type=entry`) leads to that feed (`related` links are used only when nothing else is there). Shown: title,
  authors, summary (else content; HTML and XHTML become plain text), publisher, year (`dcterms:issued`, else
  `published`), language, cover (`http://opds-spec.org/image`, older `/cover`) and thumbnail (`/image/thumbnail`,
  `media:thumbnail`).
- **Which file.** The first link, in the catalog's order, that is `application/epub+zip` with the rel
  `http://opds-spec.org/acquisition`, `…/acquisition/open-access` or `enclosure`, and no `opds:indirectAcquisition`.
  Skipped: other formats (kepub, PDF, Kindle, HTML), DRM licences (Adobe ACSM, Readium LCP), indirect acquisitions,
  `buy`, `borrow`, `subscribe` and `sample`. Catalogs list their recommended edition first (Standard Ebooks'
  "Recommended compatible epub", Project Gutenberg's EPUB3). A book without such a link says so and offers no
  Download. The downloaded bytes must start with a ZIP signature (an HTML login page is reported as such), at most
  200 MB.
- **Pagination.** `rel="next"` is followed only when the user taps *Load More*; entries already shown are not
  repeated, and a page that points to itself ends the list.

## Privacy

Requests use an ephemeral `URLSession` (no cookies, no disk cache, no credential storage) with the User-Agent
`Folito/1.0 (https://folito.app; OPDS catalog browser)`. See `docs/PRIVACY_DATA_MAP.md` 1b-ter and the privacy
policy (`docs/site-src`, "Book catalogs").

## Fixtures

`standardebooks-new-releases.xml` is Standard Ebooks' new releases feed as served on 2026-11-21, cut to three
entries. Project Gutenberg answered 503 (maintenance) on that day and Calibre-Web is self-hosted, so the
`gutenberg-*.xml` and `calibreweb-*.xml` fixtures are written by hand in the shape those servers produce, and
`edge-cases.xml` holds the acquisition cases of the OPDS 1.2 specification that must be skipped.

## Not yet (later parts of #64)

Sign-in (HTTP Basic, OPDS authentication documents), OpenSearch, facets, OPDS 2.0 (JSON), download progress.
