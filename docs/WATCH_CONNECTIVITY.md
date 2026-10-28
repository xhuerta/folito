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
| `kosync_server` | String, base URL (default `https://sync.koreader.rocks`) |
| `kosync_user` | String |
| `kosync_password` | String, plain password |
| `settingsStamp` | Int, Unix time of the user's last Save on the phone (optional) |

The phone does not rely on a single send at Save time. It re-runs `syncWatchState()` (settings + unsent
books) on: session activation, `sessionWatchStateDidChange` (e.g. `isWatchAppInstalled` becoming true),
`sessionReachabilityDidChange` to reachable, app foreground, and every `library` report from the watch.
Nothing is sent until the session is activated, paired and the watch app is installed; books stay
`sentToWatch == false` meanwhile and go out on the next trigger.

`settingsStamp` makes resends idempotent: the watch applies settings only when the stamp is newer than the
last applied one (messages without a stamp are always applied). So a "Reset" on the watch is not undone by
the phone's periodic resend; saving again on the phone (new stamp) re-provisions it.

Tradeoff: the plain password crosses WatchConnectivity (encrypted, paired devices) so the watch can sync
standalone. Both sides store it in their own Keychain (`kSecClassGenericPassword`, no access group).
The watch generates its own `device_id` UUID; it is never sent from the phone.

## Delete (`WCSession.transferUserInfo`)
`{ "type": "delete_book", "documentHash": "<hash>" }` — watch removes the book (and local progress).

## Library report (watch -> phone, `WCSession.updateApplicationContext`)
`{ "type": "library", "hashes": ["<documentHash>", ...] }` — published by the watch on activation and after
every import/delete. The phone reconciles `sentToWatch` with it (skipping transfers still in flight) and
sends whatever is missing, which covers a reinstalled watch app, books deleted on the watch and transfers
lost in transit. The phone also reads `receivedApplicationContext` on its own activation.
