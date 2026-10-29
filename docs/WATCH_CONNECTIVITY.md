# iPhone <-> Watch message schema

Transport: WatchConnectivity only (no App Groups / iCloud). Every dictionary carries `type`.
Values are property-list types (String/Int).

## Book transfer (`WCSession.transferFile`)
File: `<documentHash>.wrbook` = JSON-encoded `ProcessedBook`, compressed with LZFSE
(`(data as NSData).compressed(using: .lzfse)`; decode with `decompressed(using: .lzfse)`).

Metadata keys:
| key | type | meaning |
|---|---|---|
| `type` | String | `"book"` |
| `documentHash` | String | KOReader partial MD5 (identity, also the sync document id) |
| `title` | String | display title |
| `author` | String | authors joined by ", " |
| `size` | Int | compressed file size in bytes |
| `formatVersion` | Int | `ProcessedBook.formatVersion` |

The watch should replace any existing book with the same `documentHash`.

## Settings (`WCSession.updateApplicationContext`)
Latest-state semantics: only the newest settings matter, and a watch app installed later still receives
them (`session.receivedApplicationContext`, applied on activation). Older phone builds sent the same
dictionary with `transferUserInfo`; the watch accepts both.

| key | type |
|---|---|
| `type` | `"settings"` |
| `settingsVersion` | Int, `2` (generic connector keys). Absent in version 1 (KOSync keys only). |
| `sync_connector` | String, active connector id (`"kosync"`, `"readest"`, see [SYNC_CONNECTORS.md](SYNC_CONNECTORS.md)) |
| `sync_credentials` | String, JSON object `{storageKey: value}` of that connector (`SyncCredentials`); KOSync: `kosync_server`, `kosync_user`, `kosync_password`; Readest: `readest_email`, `readest_session` (JSON session with access + refresh token) |
| `kosync_server` | String, base URL (default `https://sync.koreader.rocks`); only when the connector is KOSync, for watch builds before connectors |
| `kosync_user` | String; idem |
| `kosync_password` | String, plain password; idem |
| `sync_cleared` / `kosync_cleared` | Bool `true` (both are sent), only when the user turned sync off on the phone (see below); never together with the keys above |
| `settingsStamp` | Int, Unix time of the user's last Save on the phone (optional) |
| `typography` | String, JSON-encoded `ReaderTypography` (optional, see "Typography") |
| `typographyStamp` | Int, `ReaderTypography.stamp` (optional, same value as inside the JSON) |

The message is generic: any connector travels as `{sync_connector, sync_credentials}`; there are no
per-connector message types. The watch stores each credential under its storage key in its Keychain, plus the
active id under `sync_connector`; applying a new connector first removes every other connector's keys, so
switching service never leaves stale credentials (and the watch drops queued positions recorded for the old
service). A watch from before connectors ignores the generic keys and keeps using the `kosync_*` keys, which
the phone still sends for KOSync; a phone from before connectors sends only `kosync_*`, which a new watch
maps to the KOSync connector.

**Readest sessions.** The phone signs in and sends the session; from then on the watch is the only device
that refreshes it (Supabase refresh tokens rotate and are single use) and saves rotated tokens in its own
Keychain. Because resends reuse the stamp, the phone's older copy never overwrites the watch's rotated one.
If the watch app is reinstalled, the resent session may already be rotated away; the watch then reports
"sign in again" and a new sign-in on the phone (new stamp) fixes it. The password is never sent or stored.

The sync keys are omitted when no valid credentials are saved; a context may therefore carry only
`type` + typography. Each `updateApplicationContext` replaces the previous context, so the phone always
sends the full state (credentials + typography).

Sync is optional. With no credentials saved and the user never having turned sync off, the context carries no
KOSync keys at all, and the watch makes no sync requests and queues no progress.

**Cleared state.** "Turn off sync and remove credentials" (or "Sign Out" for Readest) on the phone deletes its
Keychain items, revokes a Readest session on the server (best effort) and sends
`{ type: "settings", sync_cleared: true, kosync_cleared: true, settingsVersion: 2, settingsStamp: <clear time> }`
(plus typography as usual). The clear
stamp is `max(now, previous stamp + 1)`, so it is strictly newer than the last save. The watch, on a
`sync_cleared` or `kosync_cleared == true` context whose stamp passes the usual newer-than check, removes its Keychain
credentials, empties its pending-progress queue and hides all sync UI. Older watch builds ignore the unknown
key and keep their credentials (no breakage). The phone keeps resending the cleared state (same stamp, so it
is applied once) until credentials are saved again; saving uses a stamp newer than the clear, which
re-provisions the watch. The watch can also remove its credentials locally (Settings > Remove credentials);
that does not notify the phone, and the phone's resend is ignored because its stamp was already applied.

The phone does not rely on a single send at Save time. It re-runs `syncWatchState()` (settings + unsent
books) on: session activation, `sessionWatchStateDidChange` (e.g. `isWatchAppInstalled` becoming true),
`sessionReachabilityDidChange` to reachable, app foreground, and every `library` report from the watch.
Nothing is sent until the session is activated, paired and the watch app is installed; books stay
`sentToWatch == false` meanwhile and go out on the next trigger.

`settingsStamp` makes resends idempotent: the watch applies settings only when the stamp is newer than the
last applied one (messages without a stamp are always applied). So a "Reset" on the watch is not undone by
the phone's periodic resend; saving again on the phone (new stamp) re-provisions it.

Tradeoff: for KOSync the plain password crosses WatchConnectivity (encrypted, paired devices) so the watch can
sync standalone; for Readest only the session tokens do. Both sides store it in their own Keychain (`kSecClassGenericPassword`, no access group).
The watch generates its own `device_id` UUID; it is never sent from the phone.

## Delete (`WCSession.transferUserInfo`)
`{ "type": "delete_book", "documentHash": "<hash>" }` — watch removes the book (and local progress).

## Dictionary transfer (`WCSession.transferFile`)
File: a compact dictionary (`.folidict`, format in docs/DICTIONARIES.md), converted on the phone.

| key | type | meaning |
|---|---|---|
| `type` | String | `"dictionary"` |
| `dictionaryId` | String | catalog id, e.g. `readerdict-en` (also the file name on both devices) |
| `sha256` | String | lower-case hex SHA-256 of the file |
| `size` | Int64 | file size in bytes |

The watch moves the file out of the inbox, checks size and SHA-256 and that the footer opens, then replaces
any dictionary with the same id. A file that fails the checks is dropped; the phone resends whatever the
watch does not list. A newly installed or updated dictionary is sent right away; a transfer of the same id
still in flight is cancelled first.

Delete (`transferUserInfo`): `{ "type": "delete_dictionary", "dictionaryId": "<id>" }`. Dictionaries are
managed on the phone only; the watch lists them read-only.

## Library report (watch -> phone, `WCSession.updateApplicationContext`)
`{ "type": "library", "hashes": ["<documentHash>", ...], "dictionaries": ["<dictionaryId>", ...] }` — published
by the watch on activation and after every import/delete (books or dictionaries). For dictionaries the phone
waits for the first report (older watch builds send none) and does not resend a file delivered in the last
10 minutes, which the watch may still be verifying. The phone reconciles `sentToWatch` with it (skipping transfers still in flight) and
sends whatever is missing, which covers a reinstalled watch app, books deleted on the watch and transfers
lost in transit. The phone also reads `receivedApplicationContext` on its own activation.

## Typography (both directions, last writer wins)
`ReaderTypography` (ReaderCore) is a versioned, clamped, tolerant-decoding Codable: font family, size, line
spacing, margins, paragraph spacing, alignment, bold, heading scale, tracking, theme and `stamp`.
Unknown or out-of-range values decode to defaults, so differing app versions never fail to apply it.
Version 2 adds `matchSystemTextSize` (Bool, default false; version-1 JSON decodes with it off). The
iPhone has no control for it yet but preserves the value when it re-encodes the JSON.

Wire format: `typography` (JSON string) + `typographyStamp` (Int, Unix time of the last edit; every local
edit uses `max(now, previousStamp + 1)`, so edits within the same second still order).

- Phone -> watch: part of the `settings` context above. Sent only once the stamp is > 0 (the user changed
  something on some device); a never-edited phone does not overwrite the watch.
- Watch -> phone: the `library` context also carries `typography` / `typographyStamp`. Readers of that
  context must keep treating it as `library` (extra keys are ignored by `libraryHashes(from:)`).
- Merge rule on both sides: apply the incoming copy only if `incoming.stamp > local.stamp`; a tie keeps the
  local copy. That makes the phone's periodic resends idempotent: after the phone adopts a newer watch copy
  it resends the same stamp, which the watch ignores. A "Reset" on either side is a normal edit (default
  look, new stamp) and therefore propagates.
- The pre-typography watch setting `settings.fontSize` (a bare Double in `UserDefaults`) is migrated into
  `ReaderTypography.fontSize` on first launch and then removed.

## Dictionary (watch only, no phone involvement)
The watch queries the network itself (Wi-Fi, or through the paired iPhone). Nothing about it crosses
WatchConnectivity.

