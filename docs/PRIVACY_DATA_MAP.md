# Folito: privacy data map

Source of truth for what data leaves the device, to whom and why. The privacy policy and the App Store
"App Privacy" answers must match this file. Audited against the code (every `URLSession` use,
`UserDefaults`, Keychain, file and WatchConnectivity use). Re-audit when networking code changes.

Summary: the developer operates **no server** and receives **no data**. There is no analytics, advertising,
crash-reporting or third-party SDK, and no tracking. Network traffic goes only to (a) a sync server the
user configures themselves and (b) two public dictionary APIs when the user looks up a word.

## 1. Network traffic (complete list)

Only two code paths use `URLSession`; there are no other networking APIs (no WebKit, no sockets, no Bonjour).

### 1a. KOReader Sync (KOSync) server: user-supplied, optional

Code: `Packages/ReaderCore/Sources/ReaderCore/Sync/KOSync.swift` (`KOSyncClient`, `URLSession.shared`).
Used by the iPhone app (connection test in Settings) and by the watch app (progress sync). Neither app
creates accounts: the user registers with their server elsewhere (e.g. in KOReader), so `POST /users/create`
is never called (`KOSyncClient.createUser()` exists in ReaderCore only for protocol completeness and tests).

| Item | Sent | Notes |
|---|---|---|
| Server URL | n/a (destination) | Typed by the user. `https://` by default; plain `http://` only works for local-network hosts (ATS `NSAllowsLocalNetworking`: IP addresses, `*.local`, dotless names). |
| Username | yes, as header `x-auth-user` | Entered by the user. |
| Password | **no, never in clear.** Only its lowercase MD5 hex, header `x-auth-key` | This is the KOReader sync protocol's required auth key. |
| Book identifier | yes, `document` | KOReader "partial MD5" of the EPUB file (a hash, not the file, title or text). |
| Reading position | yes, `progress` (XPointer string) and `percentage` | Per book. |
| Device name / ID | yes, `device` = constant "Folito", `device_id` = random UUID generated on first launch and stored in UserDefaults | Not derived from hardware identifiers; not the advertising ID or vendor ID. |
| Timestamp | no | Server-assigned. |

Endpoints: `GET /users/auth`, `PUT /syncs/progress`, `GET /syncs/progress/{document}`.
Recipient: whichever server the user configured (self-hosted or a third-party KOSync-compatible service the
user chose). The developer is not a party. The server operator sees the user's IP address and the data above.
Sync is optional. Without a configured server, nothing is sent and nothing is queued. With one, the watch
queues unsent progress locally (UserDefaults) and retries; turning sync off on the iPhone removes the
credentials from both devices and drops the watch's queue.

### 1b. Dictionary lookups: public APIs, on user action only

Code: `Packages/ReaderCore/Sources/ReaderCore/Dictionary/OnlineDictionary.swift`
(`URLSessionDictionaryFetcher`, ephemeral session: no cookies, no persistent cache, 10 s timeout). Triggered
only when the user taps a word and opens the definition (watch app; the lookup model is also compiled in
`WatchApp/Dictionary`). Results are cached on device so a repeated word is not requested again.

| Recipient | Request | Data sent |
|---|---|---|
| Wikimedia Foundation, `https://en.wiktionary.org/api/rest_v1/page/definition/{word}` | HTTPS GET | The looked-up word (and normalised variants, e.g. lower-cased or de-inflected candidates, tried in turn), the app's `User-Agent` (`Folito/1.0 (https://github.com/xhuerta/folito; ...)`, required by Wikimedia policy), `Accept: application/json`, plus the IP address inherent to any request. |
| api.dictionaryapi.dev, `https://api.dictionaryapi.dev/api/v2/entries/en/{word}` | HTTPS GET, English words only, used when Wiktionary has no entry | Same: the word, User-Agent, IP address. |

Not sent: book title, author, surrounding text, position, account data, device ID. The word does not
identify the user by itself, but a sequence of looked-up words could in principle reveal reading interests to
those services' logs; their own privacy policies apply to what they retain.

### 1c. Not network, but data movement to document

- iPhone to Apple Watch (WatchConnectivity, local to the user's paired devices, handled by Apple's frameworks):
  processed books, reading typography settings, and the KOSync server URL, username and password so the
  watch can sync on its own (see `docs/WATCH_CONNECTIVITY.md`). The password sent here is the real password
  (the watch computes the MD5 itself); it travels only between the user's own paired devices.
- No iCloud, CloudKit, Keychain access groups or app groups are used.

## 2. Data stored on device only

| Data | Where | Notes |
|---|---|---|
| KOSync server URL, username, password | Keychain (iPhone and watch each have their own item; no access groups) | Never leaves the device except as described in 1a/1c. |
| Library (processed EPUBs) | `Application Support/Folito/Books` (iPhone), watch app's Application Support | Files the user imports; never uploaded. |
| Reading position, typography, device UUID, pending sync queue | UserDefaults | |
| Dictionary cache | On-device cache file (Application Support) | |

## 3. Privacy manifest declarations (`iOSApp/PrivacyInfo.xcprivacy`, `WatchApp/PrivacyInfo.xcprivacy`)

- `NSPrivacyTracking` = false, `NSPrivacyTrackingDomains` = empty. The app does not track.
- Required-reason APIs actually used: **UserDefaults** only, reason `CA92.1` (read/write the app's own
  preferences, not shared with other apps). Audited and **not used**: file timestamp APIs (`creationDate`,
  `modificationDate`, `stat`, `getattrlist`...; the code only copies, writes and deletes files), disk space
  APIs, system boot time (`systemUptime`, `mach_absolute_time`), active keyboard APIs. Re-check if code that
  uses these is added.
- Collected data types: **Search History** (the dictionary words sent to Wiktionary / dictionaryapi.dev),
  not linked to identity, not used for tracking, purpose App Functionality.
  Rationale for what is *not* declared: Apple defines "collect" as data transmitted off device to the developer
  or third-party partners. Sync data (username, hashed password, reading position, device UUID) goes only to
  a server the user runs or chooses, not to the developer, so it is not declared as collected by the developer.
  **Owner to confirm** this reading against App Store Connect's App Privacy guidance (see section 5).

## 4. Suggested App Store Connect "App Privacy" answers

- Data collection: dictionary words are sent to third-party services: declare **Search History**
  (Other Data is also acceptable), not linked to the user, not used for tracking, purpose App Functionality.
- Tracking: No. No data types linked to the user.
- Privacy policy URL: required (policy to be written from this file).

## 5. Items needing owner verification

1. Whether Apple wants user-configured sync (username / reading position / device UUID going to the user's own
   server) listed under App Privacy. The conservative alternative is to also declare Other User Content /
   Device ID / User ID, "not linked", purpose App Functionality; the current files take the "developer
   receives nothing" reading. Verify with Apple's "App privacy details" documentation.
2. Wikimedia User-Agent contains the GitHub project URL; replace with a real contact URL/email if the repo moves.
3. Local network permission: iOS shows a prompt the first time the app contacts a LAN address
   (`NSLocalNetworkUsageDescription`, localised en/es, in the iOS and watch Info.plists).
