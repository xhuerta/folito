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
| `cover` | Data (optional) | the book's cover as a JPEG for the watch's Library row: at most 108 px on the longer side and 6 KB (usually 2–4 KB). Omitted when the EPUB has no usable cover. The watch stores at most 64 KB. |

The watch should replace any existing book with the same `documentHash`.

**Covers of books already on the watch** (`WCSession.transferUserInfo`):
`{ "type": "book_cover", "documentHash": "<hash>", "cover": <JPEG Data> }`. Sent once when a book imported before
covers existed gains its cover on the phone (lazy fill from the kept EPUB). If it is lost, the next resend of the
book carries the cover anyway.

## Settings (`WCSession.updateApplicationContext`)
Latest-state semantics: only the newest settings matter, and a watch app installed later still receives
them (`session.receivedApplicationContext`, applied on activation).

**The settings context never carries credentials.** WatchConnectivity keeps the latest application context on
disk on both devices, outside the Keychain, for as long as the apps are installed. Credentials travel in their
own message (next section).

| key | type |
|---|---|
| `type` | `"settings"` |
| `settingsVersion` | Int, `1`. A watch ignores the sync keys of a payload with a higher version. |
| `sync_cleared` | Bool `true`, only while sync is turned off on the phone (see "Cleared state") |
| `settingsStamp` | Int, time of the turn-off; only with `sync_cleared` |
| `typography` | String, JSON-encoded `ReaderTypography` (optional, see "Typography") |
| `typographyStamp` | Int, `ReaderTypography.stamp` (optional, same value as inside the JSON) |

The phone always publishes a context (at least `type` + `settingsVersion`); each `updateApplicationContext`
replaces the previous one.

## Sync credentials (`WCSession.transferUserInfo`)

| key | type |
|---|---|
| `type` | `"credentials"` |
| `settingsVersion` | Int, `1` |
| `sync_connector` | String, active connector id (`"kosync"`, `"readest"`, see [SYNC_CONNECTORS.md](SYNC_CONNECTORS.md)) |
| `sync_credentials` | String, JSON object `{storageKey: value}`: the connector's `watchCredentials(from:)`. KOSync: `kosync_server`, `kosync_user`, `kosync_key` (lowercase hex MD5 of the password, the protocol's `x-auth-key`). Readest: `readest_email`, `readest_session` (JSON session with access + refresh token). |
| `settingsStamp` | Int, Unix time of the user's Save / sign-in on the phone (required) |

The message is generic: any connector travels as `{sync_connector, sync_credentials}`; there are no
per-connector message types.

**No password crosses the link.** The watch only needs what it sends to the server. For KOSync that is
`md5(password)`, so the phone derives it (`KOSyncConnectorFactory.watchCredentials`) and the watch never sees or
stores the password. For Readest it is the session; the Readest password is never stored on either device. The
iPhone keeps the KOSync password in its own Keychain because its Sync form shows and re-uses the saved login
(edit the server, "Test Connection").

**Why `transferUserInfo`, and how it is made reliable.** A userInfo transfer is queued by the system, delivered
in the background even if the watch is unreachable at sign-in time, and removed from the queue once delivered;
on receipt the watch moves the credentials straight into its Keychain (each value under its storage key, plus
the active id under `sync_connector`) and keeps nothing else. So the secret is on disk outside the Keychain only
while a transfer is pending, not indefinitely as in the application context. A queue has no latest-state
semantics, so the watch acknowledges: its `library` report (below) carries the `settingsStamp` it last applied,
and on every `syncWatchState()` the phone sends the credentials message when that stamp is lower than the stamp
of its saved credentials (or the watch has not reported yet). This also covers:

- the watch app installed later: nothing is sent until it is installed; then its report (stamp 0) or
  `sessionWatchStateDidChange` triggers the send;
- the watch app reinstalled: its `UserDefaults` are gone, it reports stamp 0 and gets the credentials again;
- no duplicates piling up: the phone never queues a second message with the same stamp, cancels queued messages
  with another stamp (and all of them when sync is turned off), and does not resend for 60 s after a delivery,
  the time the watch needs to apply it and report back. A duplicate that does arrive is ignored by its stamp.

Applying credentials first removes every connector's keys from the watch Keychain, so switching service never
leaves stale credentials (and the watch drops queued positions recorded for the old service).

**Readest sessions.** The phone signs in and sends the session; from then on the watch is the only device
that refreshes it (Supabase refresh tokens rotate and are single use) and saves rotated tokens in its own
Keychain. Because resends reuse the stamp, the phone's older copy never overwrites the watch's rotated one.
If the watch app is reinstalled, the resent session may already be rotated away; the watch then reports
"sign in again" and a new sign-in on the phone (new stamp) fixes it.

Sync is optional. With no credentials saved, no credentials message exists, and the watch makes no sync
requests and queues no progress.

**Cleared state.** "Turn off sync and remove credentials" (or "Sign Out" for Readest) on the phone deletes its
Keychain items, revokes a Readest session on the server (best effort), cancels any credentials message still
queued and publishes
`{ type: "settings", sync_cleared: true, settingsVersion: 1, settingsStamp: <clear time> }`
(plus typography as usual) in the settings context. The clear
stamp is `max(now, previous stamp + 1)`, so it is strictly newer than the last save. The watch, on a
`sync_cleared == true` context whose stamp passes the newer-than check, removes its Keychain
credentials, empties its pending-progress queue and hides all sync UI. The cleared marker stays in the context
(it is not a secret; same stamp, so it is applied once) until credentials are saved again; saving uses a stamp
newer than the clear, which re-provisions the watch. The watch can also remove its credentials locally
(Settings > Remove credentials); that does not notify the phone, and the phone does not resend because the
watch still reports the stamp it applied.

The phone does not rely on a single send at Save time. It re-runs `syncWatchState()` (settings, credentials,
unsent books) on: session activation, `sessionWatchStateDidChange` (e.g. `isWatchAppInstalled` becoming true),
`sessionReachabilityDidChange` to reachable, app foreground, and every `library` report from the watch.
Nothing is sent until the session is activated, paired and the watch app is installed; books stay
`sentToWatch == false` meanwhile and go out on the next trigger.

`settingsStamp` orders the two channels: the watch applies a credentials message or a cleared context only when
its stamp is strictly newer than the last one applied, and ignores one without a stamp. So a "Reset" on the
watch is not undone by a resend, and a turn-off that arrives after newer credentials (or the reverse) cannot
win; saving again on the phone (new stamp) re-provisions the watch.

Both sides store credentials in their own Keychain (`kSecClassGenericPassword`, no access group,
`kSecAttrAccessibleAfterFirstUnlock` on the watch so background sync works).
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
`{ "type": "library", "hashes": ["<documentHash>", ...], "dictionaries": ["<dictionaryId>", ...], "settingsStamp": <Int> }` — published
by the watch on activation, after every import/delete (books or dictionaries) and after applying sync settings.
`settingsStamp` is the stamp of the credentials or turn-off it last applied (0 = none); the phone uses it to
decide whether to send the credentials (see "Sync credentials"). For dictionaries the phone
waits for the first report and does not resend a file delivered in the last
10 minutes, which the watch may still be verifying. The phone reconciles `sentToWatch` with it (skipping transfers still in flight) and
sends whatever is missing, which covers a reinstalled watch app, books deleted on the watch and transfers
lost in transit. The phone also reads `receivedApplicationContext` on its own activation.

Optional key `timeRemaining`: `{ "<documentHash>": <seconds>, ... }`, the watch's estimate of the reading time
left in each book it has opened (`ReadingTimeRemaining.bookSeconds`, rounded to whole minutes), shown in the
iPhone library row. Absent until a book has been opened; the phone ignores invalid values. The watch also
publishes the report when the library list reappears (back from the reader).

Optional key `progress`: `{ "<documentHash>": <Int percent 0...100>, ... }`, the percentage read of each book with a
reading position on the watch (whole percent, so small moves do not produce a new context), shown in the iPhone's
book details.

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

