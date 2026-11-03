# Readest Cloud progress sync

Folito can sync reading positions with **Readest Cloud**, the sync service of the
[Readest](https://github.com/readest/readest) apps and of `readest.koplugin`, the Readest plugin for KOReader
(for example on a Kobo). It is one connector of the generic connector system
(see [SYNC_CONNECTORS.md](SYNC_CONNECTORS.md)); this file records the Readest specifics.

Research date: 2026-10-29, against readest/readest `main` at `2f260ee`. Everything below was read from the
open-source code, not invented; file paths are relative to that repository.

## Sources

| What | File |
|---|---|
| Auth endpoints | `apps/readest.koplugin/supabase-auth-api.json`, `readest_supabaseauth.lua`, `readest_syncauth.lua` |
| Sync endpoints | `apps/readest.koplugin/readest-sync-api.json`, `readest_syncclient.lua` |
| Progress push / pull | `apps/readest.koplugin/readest_syncconfig.lua`, `docs/progress-sync.md` |
| Server merge rules | `apps/readest-app/src/pages/api/sync.ts` (`GET`, `POST`), `src/utils/transform.ts` |
| Token check on the server | `apps/readest-app/src/utils/access.ts` (`validateUserAndToken`) |
| How the Readest app applies progress | `apps/readest-app/src/app/reader/hooks/useProgressSync.ts`, `src/utils/xcfi.ts` |
| Book identity | `apps/readest-app/src/utils/md5.ts` (`partialMD5`), `src/utils/book.ts` (`getMetadataHashInfo`) |
| Row shapes | `apps/readest-app/src/types/records.ts` (`DBBookConfig`), `src/libs/sync.ts` |

## Authentication

- **Supabase GoTrue, email + password.** `POST https://vbsyxfusjjqdxkjqlysc.supabase.co/auth/v1/token?grant_type=password`
  with JSON `{email, password}` and header `apikey: <anon key>`. The koplugin also offers e-mail OTP
  (`sign_in_otp` / `verify_otp`); the Readest apps add OAuth (Google, Apple, GitHub...) through Supabase's
  hosted flow. Folito implements only email + password: OAuth would need Readest's registered redirect URLs,
  which a third-party app cannot use, and OTP adds a second screen for little gain.
- **Anon key.** A JWT with `role: anon` for project `vbsyxfusjjqdxkjqlysc`, valid until 2049, shipped
  base64-encoded in `main.lua` (`SUPABAE_ANON_KEY_BASE64`) and in every Readest client. It is public by
  design (Supabase row-level security protects the data); it is not a secret. It is sent only to the auth
  endpoints. No other secret is involved.
- **Response.** `{access_token, token_type: "bearer", expires_in, expires_at, refresh_token, user: {id, email, ...}}`.
  Supabase's default lifetime, also the value in the koplugin's test fixtures, is `expires_in = 3600` (one
  hour); clients must read `expires_in` rather than assume it.
- **Refresh.** `POST .../auth/v1/token?grant_type=refresh_token` with `{refresh_token}`. Refresh tokens
  **rotate and are single use**: reusing an old one fails (400 `refresh_token_already_used`) and, outside
  Supabase's short reuse interval, revokes the session. The koplugin refreshes when less than
  `max(60 s, expires_in / 2)` remains, tracks expiry on the local clock (`now + expires_in`), shares one
  in-flight refresh between concurrent requests, and on a rejected refresh stops syncing until the user signs
  in again (it keeps the account). Folito does the same (`ReadestAuth`).
- **Sign-out.** `POST .../auth/v1/logout` with the bearer token. Without a `scope` Supabase signs out every
  session of the user, so Folito sends `?scope=local` (this session only). Best effort: an expired access
  token cannot revoke anything, and the session then simply expires.
- **Server-side token check.** `/api/*` routes verify the bearer JWT with `supabase.auth.getClaims` and
  require `role == "authenticated"`. A bad or expired token gets **403** `{"error":"Not authenticated"}` (not
  401). Other 403s exist (quota, permission), so only that body means "refresh and retry once".

### Who refreshes the session

Only one device may refresh a session (rotation). In Folito the **watch owns the session**: the iPhone signs
in, stores the session in its Keychain only to resend it over WatchConnectivity, and never refreshes it (its
"Test Connection" button is hidden for Readest because the sign-in already checks the password). The watch
refreshes and stores rotated tokens in its own Keychain. Signing in again on the iPhone creates a new
session (new settings stamp) and revokes the previous one. The password is never stored on either device.

## Sync API

Base URL `https://web.readest.com/api`. Every request: `Authorization: Bearer <access_token>`,
`Accept: application/json`, `Content-Type: application/json` for bodies. No `apikey` header.

### Pull: `GET /sync?since=0&type=configs&book=<book_hash>&meta_hash=<meta_hash>`

`since` (epoch ms, required) filters on `updated_at > since OR deleted_at > since`; the koplugin always
passes `0` for a book. With both `book` and `meta_hash` the server returns rows matching **either**, so the
answer can include configs of sibling copies (same metadata, different file). Response:

```json
{"books": [], "notes": [], "statBooks": [], "statPages": [],
 "configs": [{"user_id": "…", "book_hash": "5d41…", "meta_hash": "7d79…",
              "location": "epubcfi(/6/24!/4/2/1:0)", "xpointer": "/body/DocFragment[12]/body/div/p[3]/text().42",
              "progress": "[120,300]", "rsvp_position": null, "search_config": null, "view_settings": null,
              "created_at": "2026-10-01T08:00:00.000Z", "updated_at": "2026-10-29T13:53:43.877Z", "deleted_at": null}]}
```

`progress` is a JSON **string** in `book_configs` (an array in `books`).

### Push: `POST /sync`

```json
{"books": [], "notes": [],
 "configs": [{"bookHash": "5d41…", "metaHash": "7d79…", "progress": [120, 300],
              "xpointer": "/body/DocFragment[12]/body/div/p[3]/text().42", "updatedAt": 1761000000123}]}
```

Exactly what the koplugin sends (`SyncConfig:getCurrentBookConfig`). The server (`upsertRecords`) looks up the
row by `(user_id, book_hash)`:

- no row: insert, with `updated_at` = **server time**;
- row exists: update only when the client's `updatedAt` is **strictly newer** than the stored `updated_at`
  (last writer wins; a tie keeps the server row); otherwise the server row is kept untouched;
- PostgREST upserts only the columns sent, so a push without `location` leaves the Readest app's CFI as is.

The response lists the authoritative rows (`{"books": [], "configs": [...], "notes": []}`). As a side effect
the server copies `progress` and `updated_at` onto the `books` row (library view of other devices) when it is
older.

Other change types exist on the same endpoint (`books`, `notes` = highlights/bookmarks, `statBooks`,
`statPages` = reading statistics, plus `/storage/*` for files). Folito uses only `configs`.

### Rate limits

Neither the terms nor the code document per-user rate limits for `/api/sync`; Supabase's auth endpoints have
their own limits (sign-in and refresh attempts per IP), answered with 429. Folito treats 429 as transient
(backoff), never signs in automatically, refreshes at most once per hour per session, and pushes at most once
per ~60 s while reading (debounced), on leaving a book and on going to background, which is less traffic than
the koplugin's 30 s debounce.

## Progress mapping

Readest keeps two position fields per book: `location` (an EPUB CFI, written only by the Readest apps) and
`xpointer` (a **KOReader/crengine XPointer**, written by the koplugin and by the Readest apps, which convert
their CFI with `getXPointerFromCFI`). Plus `progress = [current page, total pages]` in the writer's own
pagination.

Folito positions are already KOReader XPointers (the same strings Folito sends to KOSync), so:

- **Push**: `xpointer` = Folito's XPointer of the paragraph; `progress` = `[block index + 1, block count]`
  (Folito's "pages"), or `[round(percentage × 1000), 1000]` when unknown (never `[0, n]`: Readest ignores
  page 0); `updatedAt` = when the position was reached (epoch ms), not when it is sent; `location` is never
  sent.
- **Pull**: the row whose `book_hash` equals the file's partial MD5 gives the XPointer and
  `percentage = progress[0] / progress[1]`. A sibling row (same `meta_hash`, other `book_hash`) contributes
  only its fraction, and only when it is further than the exact row by more than 0.002, exactly like
  Readest's `applyRemoteProgress` (a sibling's XPointer belongs to a different file). Rows with `deleted_at`
  are ignored. The open-book offer then uses Folito's normal XPointer resolver with the percentage fallback.

The koplugin converts nothing: KOReader's `ui.rolling:getLastProgress()` *is* the XPointer, and
`applyBookConfig` trims it backwards until it resolves. The Readest apps convert XPointer ↔ CFI in
`utils/xcfi.ts`.

### Limitations

- **Paragraph granularity**: Folito's XPointers point at the start of a block (same as with KOSync).
- **The Readest apps move forward only on automatic pulls**: they apply the furthest of their CFI and the
  XPointer. Going back on the watch does not move an open Readest app back; KOReader behaves the same.
- **Positions written only as CFI**: when the Readest app fails to convert its CFI, it pushes `xpointer: ""`;
  Folito then has only `progress`, a page fraction of Readest's pagination, and lands by percentage.
- **Different files**: positions only match for the same EPUB file (same partial MD5). Re-downloads with a
  different file but the same metadata sync by fraction only.
- **Clock skew**: last-writer-wins uses device clocks. A device whose clock runs ahead can keep winning
  until real time catches up (also true for the koplugin).

## Book identity

| Readest | Folito | Notes |
|---|---|---|
| `book_hash` | `ProcessedBook.documentHash` = `DocumentIdentity.partialMD5` | Readest's `partialMD5` (md5.ts) and KOReader's `util.partialMD5` are the same algorithm, including the first sample at offset 0 (see DISCREPANCIES.md). The koplugin pushes `partial_md5_checksum` as `bookHash`. |
| `meta_hash` | `ProcessedBook.metaHash` = `DocumentIdentity.metaHash` | md5 of NFC `"title|authors|identifiers"`, preferred identifier uuid > calibre > isbn. Not replicated: PDF filename salt, empty-title fallback, `altIdentifier` (DISCREPANCIES.md). |

Both are sent; the server ORs them on pull.

## Terms and licence

- **Terms of Service** (readest.com/terms-of-service, last updated 2024-11-29): no clause on third-party
  clients, API access, automated access or rate limits. Acceptable use forbids illegal/unauthorized use and
  distributing harmful content. It states Readest is AGPL-3.0 free software.
- **Privacy Policy** (readest.com/privacy-policy, last updated 2025-06-06): sync is optional and
  user-controlled; nothing about third-party clients.
- **Licence**: the repository (including the koplugin) is AGPL-3.0. Folito copies no Readest code: it
  implements the same public HTTP protocol from scratch. The only value taken verbatim is the public anon key
  (a configuration value, not code), which every Readest client ships.
- **API stability**: no published, versioned API. The endpoints are the ones Readest's own KOReader plugin
  and Calibre plugin use, so breaking them would break Readest's clients too, but they can change without
  notice. Folito's live integration test (below) catches that.
- **Verdict**: no blocker. A user signing in to their own Readest account from another client is allowed by
  the current terms. Folito must not imply it is a Readest product (the settings say so) and should respect
  the service (debounce, backoff, no automatic sign-in loops).

## Tests

- `ReadestSyncTests` (unit, Linux): request/response shapes above, token rotation and single shared refresh,
  403 "Not authenticated" retry, dead session, mapping (exact vs sibling), LWW, error dispositions.
- `ReadestConnectorConformanceTests`: the generic connector conformance suite against `FakeReadestServer`,
  which reimplements the `sync.ts` merge rules.
- `ReadestIntegrationTests` (live): skipped unless `READEST_TEST_EMAIL` and `READEST_TEST_PASSWORD` are set.
  CI runs it in the Linux workflow (`readest-integration` job) when the repository secrets of the same names
  exist. It writes one config row for the fake book hash `f0111070000000000000000000000001`, so use a
  dedicated test account. Credentials are never printed.
