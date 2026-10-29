## Document identity (partialMD5 / metaHash)

Verified against koreader/koreader `frontend/util.lua` and readest/readest
`apps/readest-app/src/utils/book.ts` (`getMetadataHashInfo`, canonical) +
`apps/readest.koplugin/readest_syncconfig.lua` (`computeMetadataHashInfo`).

1. **partialMD5 first offset is 0, not 256.** The task description assumed
   `1024 << (2*-1) = 256`. In KOReader `lshift` is LuaJIT `bit.lshift`, which masks the
   shift count to 5 bits: `-2 & 31 = 30`, and `1024 << 30` wraps to 0 in 32 bits. Readest's
   `md5.ts` (JS `<<`) has the same quirk (offset 0). We use offsets
   `0, 1024, 4096, ..., 1024*4^10`. `scripts/partial_md5_reference.py` reproduces this.
2. **metaHash is not just `md5("title|authors|identifier")`.**
   - The hashed text is NFC-normalized first.
   - Authors joined with `,`; empty authors dropped. KOReader plugin trims each author, the
     TS side does not; we trim (equal for clean metadata).
   - Identifiers: only one is hashed when a preferred scheme is present, with priority
     `uuid > calibre > isbn` (substring match, case-insensitive, over the raw string; the first
     match for the best scheme wins). Otherwise all normalized, non-empty identifiers are
     joined by `,`.
   - `normalizeIdentifier`: contains `urn:` -> text after the last `:`; else contains `:` ->
     text after the first `:` (empty if scheme or remainder empty); else unchanged.
   - `BookIdentifier` with a non-nil `scheme` is treated like Readest's `Identifier` object
     (scheme equality, raw value, no normalization); with nil scheme like a plain string.
     Readest normally feeds plain strings, so prefer storing raw `dc:identifier` text with
     `scheme == nil` when exact parity matters.
3. **Not replicated:** the PDF filename salt (`|basename`, TS `filename` arg / Lua `.pdf`
   branch) and the empty-title fallback to the filename (Lua only); `BookMetadata` carries
   neither and the app reads EPUBs only. TS `altIdentifier` (preferred over `identifier`) is
   likewise not modelled.


## XPointer (feat/xpointer)

Sources: koreader/crengine `lvtinydom.cpp` (`ldomXPointer::toStringV2`, `createXPointerV2`), readest/readest `utils/xcfi.ts`, `useKOSync.ts`, `KOSyncClient.ts`, koreader `plugins/kosync.koplugin`.

- **`[1]` indices.** crengine (DOM version < 20260812) omits `[k]` when an element is the only one of its name, writes `name[1]` for the first of several, and `name[k]` otherwise. Newer DOM versions always emit `[1]`. The generator only knows `PathStep.index`, so it omits `[1]` always and emits `[k]` for k>1 (matches the task example `/div/p[3]`). KOReader parses both. The resolver treats `p` and `p[1]` as equal.
- **Offsets are code points.** crengine `text().N` counts UTF-32 code points of the text node; `BookPosition.characterOffset` counts Swift `Character`s. Both generator input (`textOffset`) is passed through raw; `locate`/`resolve` convert between the two.
- **`text()[k]`.** crengine emits it only when the parent has several text nodes; Readest does the same. We cannot map text node k>1 into a flattened block, so offsets for `k>1` and for xpointers pointing into inline children (`p/span/text().3`) resolve to block start (offset 0).
- **Element points.** `div[1].0` (no `text()`) is a valid crengine element point whose number is a child index, not a character offset; we ignore it (block start). Readest's `normalizeProgressXPointer` strips trailing `/text()...` and `.N` before pushing to KOReader, so Readest-written progress commonly has no `text()` part.
- **Path trimming.** The task describes the Readest plugin trimming the path backwards; in the Readest sources inspected (`xcfi.ts`, `useKOSync.ts`, `readest.koplugin/main.lua`) no such trimming exists. Readest converts XPointer -> CFI and, on failure, shows "Sync failed" and does NOT fall back to percentage for XPointer progress (percentage only used when progress is not an XPointer). Trimming and the percentage fallback here are our own design, as specified.
- **DocFragment index.** Missing `[N]` means 1 (Readest uses 0-based section 0 likewise). Since crengine 20240114 every spine item gets a DocFragment (not only XHTML), so `N` equals the spine index including non-XHTML items; old bookmarks may be shifted.
- **Unsupported forms.** `/html/body/...` (MOBI) and `/FictionBook/...` (FB2) xpointers are treated as malformed and go to the percentage fallback.
- **Percentage scale.** KOReader/kosync send 0...1; values are clamped to that range, NaN/inf are unusable.


## KOSync (Sync/KOSync.swift, Sync/SyncQueue.swift)

Verified against koreader/koreader-sync-server (`app/controllers/1/syncs_controller.lua`, `config/errors.lua`, `config/routes.lua`),
koreader `plugins/kosync.koplugin` (`api.json`, `KOSyncClient.lua`) and readest `src/services/sync/KOSyncClient.ts`.

- **`POST /users/create` password is the md5 key, not the plain password.** The spec only says `x-auth-key = md5(password)`; the server stores whatever `password` is sent in the body and compares it with `x-auth-key` later, so the body must carry `md5(password)` hex (KOReader and Readest do this). No auth headers are sent on create.
- **Status codes.** 401 unauthorized; 402 = username already registered *and* "registration disabled" (indistinguishable except by message; mapped to `.userExists`); 403 = invalid fields / bad `document` (mapped to `.server(status: 403)`); 502 = redis/internal. Expected-status lists in the plugin: create 201/402, auth 200/401, push 200/202/401, get 200/401.
- **`document` charset.** `PUT` rejects (403) documents that are empty, contain `:`, or fall outside `[A-Za-z0-9_]+` (the GET route cannot serve them). Partial-MD5 hex digests are fine.
- **GET with no stored progress returns 200 `{}`** (no `document` field), not 404. Client maps `{}`/empty body/404 to `nil`. Unlike the spec, a real GET reply may omit `document`, `device` or `device_id` (older entries have no `device_id`); the client falls back to the requested document and empty strings. `timestamp` is server-assigned (`os.time()`), so it is never sent on PUT.
- **PUT response** is `{document, timestamp}`, not an echo of the full record. Server requires `percentage`, `progress` and `device` (else 403); `device_id` is optional on the server but always sent here.
- **Authorize response** is `{"authorized":"OK"}`. The client treats a 200 with a non-JSON body as `.invalidResponse` (misconfigured base URL hitting a web UI; Readest guards the same way). Readest additionally auto-registers on a 401 and retries with HTTP Basic auth for Calibre-Web-Automation; Folito does neither (registration is an explicit `createUser()`).
- **Accept header.** The server does not validate `Accept`, but the plugin always sends `application/vnd.koreader.v1+json`; we do too. `Content-Type: application/json` is sent only when there is a body.
- **Optional `metadata` field** (KOReader 2026.05+, ignored by the official server) is not sent.
- **Base URL.** Trailing slash and base paths (e.g. `https://host/kosync/`) are preserved by string concatenation, not `URL.appendingPathComponent`.
- **Offline mapping.** `URLError` notConnectedToInternet, timedOut, networkConnectionLost, cannotConnectToHost, cannotFindHost, dnsLookupFailed, dataNotAllowed, internationalRoamingOff -> `.offline`; other `URLError`s (e.g. TLS) are rethrown unchanged.
- **SyncQueue** retries only transient failures (`.offline`, URLError, HTTP 5xx/429); `.unauthorized` keeps the entry and stops the background loop; other errors (e.g. 403) drop the entry; entries are dropped after `maxAttempts` (10).
- Integration test against a real server is gated by `KOSYNC_TEST_URL` and was not run here (building the sync-server Docker image compiles OpenResty from source; skipped).
