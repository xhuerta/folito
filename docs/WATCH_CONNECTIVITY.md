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

## Settings (`WCSession.transferUserInfo`)
| key | type |
|---|---|
| `type` | `"settings"` |
| `kosync_server` | String, base URL (default `https://sync.koreader.rocks`) |
| `kosync_user` | String |
| `kosync_password` | String, plain password |

Tradeoff: the plain password crosses WatchConnectivity (encrypted, paired devices) so the watch can sync
standalone. Both sides store it in their own Keychain (`kSecClassGenericPassword`, no access group).
The watch generates its own `device_id` UUID; it is never sent from the phone.

## Delete (`WCSession.transferUserInfo`)
`{ "type": "delete_book", "documentHash": "<hash>" }` — watch removes the book (and local progress).
