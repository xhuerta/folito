# OPDS catalogs

The iPhone app can browse OPDS 1.2 catalogs and download DRM-free EPUBs from them (issue #159, part 1 of #64), including
self-hosted servers that ask for a user name and password (issue #160, part 2), and searches catalogs that offer
OpenSearch (issue #161, part 3).
Downloads go through the normal import, so a book from a catalog is processed, kept and sent to the Apple Watch
like any EPUB the user imports.

## Where

| Part | File |
| --- | --- |
| Feed model, acquisition rules, page merging | `Packages/ReaderCore/Sources/ReaderCore/OPDS/OPDSFeed.swift` |
| Atom/OPDS parser | `Packages/ReaderCore/Sources/ReaderCore/OPDS/OPDSParser.swift` |
| OpenSearch: search links, description documents, filling templates | `Packages/ReaderCore/Sources/ReaderCore/OPDS/OPDSSearch.swift` |
| Client (feeds, search, covers, EPUB downloads) and errors | `Packages/ReaderCore/Sources/ReaderCore/OPDS/OPDSClient.swift` |
| Sign-in: credentials, origins, where they may be sent, the in-memory vault | `Packages/ReaderCore/Sources/ReaderCore/OPDS/OPDSAuth.swift` |
| Presets, address normalisation | `Packages/ReaderCore/Sources/ReaderCore/OPDS/OPDSCatalog.swift` |
| Catalog list, sign-ins (Keychain), downloads, page and search-results model | `iOSApp/Library/CatalogStore.swift` |
| Screens | `iOSApp/Views/CatalogsView.swift` (Library › + › Catalogs), `iOSApp/Views/CatalogFormViews.swift` (Add Catalog, Edit Catalog, Sign In) |
| Tests | `Packages/ReaderCore/Tests/ReaderCoreTests/OPDSTests.swift`, `OPDSAuthTests.swift` and `OPDSSearchTests.swift`, fixtures in `Tests/Fixtures/OPDS/`; `iOSApp/Tests/CatalogTests.swift`; `iOSApp/UITests/CatalogsUITests.swift` and the `catalogs` and `signin` shards of `AccessibilityAuditTests` (`testCatalogSearchAudit` is in `signin`) |

## Behaviour

- **Presets.** Standard Ebooks and Project Gutenberg are listed but contacted only when opened. Standard Ebooks'
  full OPDS catalog (`/feeds/opds`) is a benefit of their Patrons Circle and answers 401 without a membership
  login, so the preset is their **new releases** Atom feed (`/feeds/atom/new-releases`), which is open to
  everyone and lists EPUB downloads as `enclosure` links. Project Gutenberg's preset is `https://www.gutenberg.org/ebooks.opds/`.
- **Custom catalogs.** Added by address (`https://` is assumed when no scheme is typed; `opds://` becomes
  `https://`; other schemes and addresses with a user name or password are refused). The address is read once to
  check that it is a feed (with the sign-in, if one was entered); the name defaults to the feed's title. *Edit…*
  (context menu and VoiceOver action on the row, or the pencil on the catalog's page) renames it, changes or removes
  its sign-in, or removes it.
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

## Sign-in (part 2, #160)

Self-hosted servers: Calibre's content server, Calibre-Web, Komga (HTTP Basic auth), and Kavita (no sign-in: its OPDS
address contains the user's API key, `https://host/api/opds/<key>`).

- **What.** An optional user name and password, sent as HTTP Basic auth (`Authorization: Basic`, UTF-8). Digest auth
  is not supported: Calibre's content server uses Basic over https with its default `--auth-mode=auto`.
- **Per server.** A sign-in belongs to a server: scheme, host and port (`OPDSOrigin`). Catalogs on the same server
  share it (a second catalog added on that server without a sign-in uses it).
- **Where it is sent.** Only to requests for that same `https` origin: the catalog's pages, and covers and EPUBs it
  serves itself. Covers or downloads on another host, another port or plain http get no `Authorization` header
  (`OPDSSignInPolicy.mayAuthorize`). A redirect that leaves the origin drops the header (`OPDSSignInPolicy.redirected`,
  applied by the transport's `willPerformHTTPRedirection`). TLS is validated by the system as usual.
- **Plain http: refused.** A sign-in is never accepted for an `http://` catalog, and nothing is sent: the form says
  "Folito sends a user name and password only over a secure connection. Use the catalog's https:// address."
  Warn-and-consent was the alternative; it was rejected as the less safe option, since Basic auth over http is
  readable by anyone on the network and the people most likely to accept the warning are the least able to judge
  it. An http catalog without a sign-in keeps working (local-network hosts only, as before); one that answers 401
  gets the same message. For a home server: put it behind a reverse proxy with a certificate, or use Calibre's
  `--ssl-certfile` / `--ssl-keyfile`, Komga's `server.ssl.*` or Calibre-Web's certificate settings.
- **Asking for it.** A 401 (or 403 without a sign-in) is `authenticationRequired`; the page then offers *Sign In…*
  if it belongs to an added https catalog. A 401 with a sign-in is `credentialsRejected` ("didn't accept the user
  name and password"), a 403 with one `accessDenied`. Nothing is retried on its own.
- **Checked before it is saved.** Adding a catalog or saving a new sign-in reads the catalog once with exactly the
  entered credentials (`OPDSClient.checkFeed`); only if that succeeds is it saved.
- **Storage.** iPhone Keychain only: generic password, service `com.xlahuerta.folito.opds`, account
  `https://host:port`, value the JSON `{username, password}`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not
  synchronizable (no iCloud Keychain; not restored onto another device). Never in UserDefaults (`catalogs.custom`
  holds names and addresses only), files, logs or the watch. In memory, the client's `OPDSCredentialVault`, filled
  from the Keychain at launch. `OPDSCredentials.description` redacts the password; the client's request log holds
  addresses only.
- **Editing.** The edit screen shows the saved user name, never the password. An empty password keeps the saved one;
  both fields empty (or *Remove Sign-In*) deletes it. Removing the last catalog on a server deletes its Keychain item.
- **UI tests.** `-UITestingMockCatalogs` adds "Home Library" (signed in) and "Family Server" (answers 401) with an
  in-memory Keychain; the fixture sign-in is `reader` / `fixture-password` (Debug builds only). "Home Library" offers
  search through a description: "mars" finds two books and a next page, anything else nothing.

## Search (part 3, #161)

- **Where.** A page whose feed has a `rel="search"` link gets a search field (`.searchable`, always shown under the
  title). Submitting it pushes *Search Results*, the same screen as a catalog page: book and section rows, *Load
  More* (`rel="next"`), errors, and *Sign In…* after a 401. The heading says what was searched ("Results for
  “mars”"); nothing found shows the system's "No Results" view. The results screen has no search field of its own.
- **Two forms of the link.** An OpenSearch description document (`type="application/opensearchdescription+xml"`:
  Calibre-Web, Project Gutenberg, Komga, Kavita, Standard Ebooks), or a template given directly
  (`type="application/atom+xml"` and an `href` with `{searchTerms}`: Calibre's content server, Calibre-Web). When a
  feed has both, the direct template is used (one request fewer). The `href` of a template is kept as written and
  resolved only after it is filled (resolving it first would percent-encode the braces).
- **Description documents.** The template is the first `Url` whose `type` is `application/atom+xml` (any parameters;
  one with `profile=opds-catalog` wins) and whose `rel` is `results` (the default). `text/html`, RSS and
  `suggestions` templates are ignored. Relative templates are resolved against the address the description was
  served from. A description is read the first time the user searches and kept in memory (per client, so per
  launch). One without a usable Atom template is `OPDSError.searchNotSupported` ("Folito can't use this catalog's
  search").
- **Filling.** `{searchTerms}` gets the trimmed terms with everything but `A–Z a–z 0–9 - . _ ~` percent-encoded
  (UTF-8; a space is `%20`, `/` is `%2F`), so a term is safe in a path segment (`/opds/search/{searchTerms}`) as in
  a query. Optional parameters (`{name?}`) are left empty. Required standard ones get first-page values:
  `{startIndex}` the `indexOffset` (default 1), `{startPage}` the `pageOffset` (default 1), `{language}` `*`,
  `{inputEncoding}` / `{outputEncoding}` `UTF-8`. A template with another required parameter (`{count}`, or a
  server's own extension), without `{searchTerms}`, or whose result is not an `http`/`https` address is not used.
- **Requests and sign-in.** The description and the results are read by the same `OPDSClient` as any page, so the
  rules of part 2 apply unchanged: a saved sign-in goes only to its own `https` server (a template on another host
  or on plain http gets no `Authorization`), and a redirect off the origin drops it. Nothing is requested while the
  user types: only when a search is submitted (empty terms send nothing).
- **Standard Ebooks.** The new releases feed links their description; its Atom template
  (`/feeds/atom/all?query=`) may, like their full OPDS catalog, be limited to Patrons Circle members, in which case
  the results screen shows the sign-in message.

## Privacy

Requests use an ephemeral `URLSession` (no cookies, no disk cache, no credential storage) with the User-Agent
`Folito/1.0 (https://folito.app; OPDS catalog browser)`. The only credential ever sent is a sign-in the user saved,
to its own server over https (above). See `docs/PRIVACY_DATA_MAP.md` 1b-ter and the privacy
policy (`docs/site-src`, "Book catalogs").

## Fixtures

`standardebooks-new-releases.xml` is Standard Ebooks' new releases feed as served on 2026-11-21, cut to three
entries. Project Gutenberg answered 503 (maintenance) on that day and Calibre-Web is self-hosted, so the
`gutenberg-*.xml` and `calibreweb-*.xml` fixtures are written by hand in the shape those servers produce, and
`edge-cases.xml` holds the acquisition cases of the OPDS 1.2 specification that must be skipped. `calibre-*.xml`
(content server: links without `rel`, `/get/epub/<id>/<library>`, the older `opds-spec.org/cover` and `/thumbnail`
rels, XHTML content), `komga-*.xml` (`/opds/v1.2/...`, a CBZ comic with an OPDS-PSE page stream next to an EPUB) and
`kavita-series.xml` (API key in the path, `acquisition/open-access`) are written by hand in the shape those servers
produce. The search fixtures, `opensearch-*.xml` (description documents of Calibre-Web, Project Gutenberg, Komga,
Kavita and Standard Ebooks, plus `opensearch-unusable.xml` with templates Folito must refuse) and
`search-*-results.xml` (Calibre-Web, Project Gutenberg and Komga result pages), are also written by hand in the shape
those servers produce. No live server is contacted by the tests; the client's sign-in rules and the URLSession transport are
tested with a mock transport and a mocked `URLProtocol` (`OPDSAuthTests`, `CatalogTests`).

## Not yet (later parts of #64)

OPDS authentication documents, Digest auth, search suggestions and OpenSearch paging parameters beyond the first page
(results pages are followed through `rel="next"`), facets, OPDS 2.0 (JSON), download progress. Kavita's API key is
part of the catalog address and so is stored with the address (UserDefaults), not in the Keychain.
