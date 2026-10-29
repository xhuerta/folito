# Folito: privacy data map

Source of truth for what data leaves the device, to whom and why. The privacy policy and the App Store
"App Privacy" answers must match this file. Audited against the code (every `URLSession` use,
`UserDefaults`, Keychain, file and WatchConnectivity use). Re-audit when networking code changes.

Summary: the developer operates **no server** and receives **no data**. There is no analytics, advertising,
crash-reporting or third-party SDK, and no tracking. Network traffic goes only to (a) the progress-sync
service the user chooses and signs in to (a KOReader Sync server, or Readest Cloud; at most one at a time) and
(b) the reader.dict website when the user downloads a dictionary on the iPhone. Word lookups are offline.

## 1. Network traffic (complete list)

Only the sync connectors and the dictionary use `URLSession`; there are no other networking APIs (no WebKit,
no sockets, no Bonjour). Sync connectors are listed in `SyncConnectorRegistry.standard`
(`Packages/ReaderCore/Sources/ReaderCore/Sync/Connectors/SyncConnector.swift`).

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

### 1a-bis. Readest Cloud: optional, user's own Readest account

Code: `Packages/ReaderCore/Sources/ReaderCore/Sync/Readest/` (`ReadestAuth`, `ReadestSyncClient`,
`ReadestConnector`, `URLSession.shared`). Details: `docs/READEST_SYNC.md`. Used only when the user picks
**Readest** in Settings › Progress Sync and signs in with an existing Readest account (the app creates no
accounts). The iPhone signs in once; the watch then syncs and refreshes the session on its own.

| Recipient | Item | Sent | Notes |
|---|---|---|---|
| Supabase (Readest's auth provider), `https://vbsyxfusjjqdxkjqlysc.supabase.co/auth/v1/*` | Email and password | yes, once, at sign-in (iPhone), HTTPS | The password is **never stored**, on either device. |
| same | Refresh token | yes, when the session is refreshed (watch, about hourly while syncing) | |
| same | Public `apikey` | yes | Readest's public anon key, identical in every Readest client; not user data. |
| Readest, `https://web.readest.com/api/sync` | Access token | yes, `Authorization: Bearer` header | Identifies the user's Readest account. |
| same | Book identifiers | yes, `bookHash` (KOReader partial MD5 of the file) and `metaHash` (MD5 of title, authors and identifier) | Hashes; title, author and the file are not sent. Note that a metadata hash of a well-known book could be matched by someone who hashes the same metadata. |
| same | Reading position | yes, `xpointer` (paragraph XPointer), `progress` (`[paragraph number, paragraph count]`) and `updatedAt` (time the position was reached) | Per book. |
| same | Device name / ID | no | |

Endpoints: `POST /auth/v1/token` (password and refresh grants), `POST /auth/v1/logout?scope=local` (sign out,
best effort), `GET /api/sync?type=configs&book=…&meta_hash=…`, `POST /api/sync` (configs only; no books,
notes, statistics or files). Recipient: Readest (the user's own account, governed by Readest's privacy
policy). The developer is not a party and receives nothing. Signing out on the iPhone removes the session from
both devices and asks Supabase to revoke it.

### 1b. Dictionary downloads (iPhone only, on user action only)

Code: `iOSApp/Dictionaries/DictionaryManager.swift` (`FileDownload`, ephemeral `URLSession`: no cookies, no
persistent cache). Triggered only when the user taps *Download*, *Update* or *Download Again* in
*Settings › Dictionaries*, plus a HEAD request per installed dictionary while that screen is open (update check).
**Word lookups make no network request**: they run on the watch against the installed files
(`OfflineDictionaryService`, docs/DICTIONARIES.md). The watch app has no dictionary networking at all.

| Recipient | Request | Data sent |
|---|---|---|
| reader.dict, `https://www.reader-dict.com/file/{lang}/dict-{lang}-{lang}-noetym.zip` | HTTPS GET (download), HTTPS HEAD (update check) | The file URL (reveals the chosen dictionary language), `User-Agent: Folito/1.0 (https://github.com/xhuerta/folito; dictionary download)`, plus the IP address inherent to any request. |

Not sent: any looked-up word, book title, author, text, position, account data or device ID.

### 1c. Not network, but data movement to document

- iPhone to Apple Watch (WatchConnectivity, local to the user's paired devices, handled by Apple's frameworks):
  processed books, converted dictionaries, reading typography settings, and the active sync connector's
  credentials so the watch can sync on its own (see `docs/WATCH_CONNECTIVITY.md`): for KOSync the server URL,
  username and password (the real password; the watch computes the MD5 itself), for Readest the account email
  and the session (access + refresh token, never the password). They travel only between the user's own
  paired devices.
- No iCloud, CloudKit, Keychain access groups or app groups are used.

## 2. Data stored on device only

| Data | Where | Notes |
|---|---|---|
| Active sync service id | iPhone: UserDefaults (`sync.connector`); watch: Keychain (`sync_connector`) | |
| KOSync server URL, username, password | Keychain (iPhone and watch each have their own item; no access groups) | Never leaves the device except as described in 1a/1c. |
| Readest email and session (access + refresh token) | Keychain (iPhone and watch; the watch updates its copy when the session is refreshed) | No password. Removed on Sign Out. |
| Library (processed EPUBs) | `Application Support/Folito/Books` (iPhone), watch app's Application Support | Files the user imports; never uploaded. |
| Reading position, typography, device UUID, pending sync queue | UserDefaults | |
| Offline dictionaries | `Application Support/Folito/Dictionaries` (iPhone and watch) | Downloaded/converted files; deleted from *Settings › Dictionaries* on the iPhone (removes them from the watch too). Download validators (ETag) and checksums in UserDefaults. |

## 3. Privacy manifest declarations (`iOSApp/PrivacyInfo.xcprivacy`, `WatchApp/PrivacyInfo.xcprivacy`)

- `NSPrivacyTracking` = false, `NSPrivacyTrackingDomains` = empty. The app does not track.
- Required-reason APIs actually used: **UserDefaults** only, reason `CA92.1` (read/write the app's own
  preferences, not shared with other apps). Audited and **not used**: file timestamp APIs (`creationDate`,
  `modificationDate`, `stat`, `getattrlist`...; the code only copies, writes and deletes files), disk space
  APIs, system boot time (`systemUptime`, `mach_absolute_time`), active keyboard APIs. Re-check if code that
  uses these is added.
- Collected data types: **none**. (Until the offline dictionaries, looked-up words went to Wiktionary /
  dictionaryapi.dev and were declared as Search History; lookups are now on device.) Downloading a dictionary
  file from reader.dict sends no user data beyond the request itself, like any file download.
  Rationale for what is *not* declared: Apple defines "collect" as data transmitted off device to the developer
  or third-party partners. Sync data (username or Readest email, hashed password or session token, book hashes,
  reading position, device UUID) goes only to a service the user runs or chooses and signs in to with their own
  account (a KOSync server, or Readest Cloud), not to the developer or a partner of the developer, so it is not
  declared as collected by the developer.
  **Owner to confirm** this reading against App Store Connect's App Privacy guidance (see section 5).

## 4. Suggested App Store Connect "App Privacy" answers

- Data collection: **Data Not Collected** (see section 5, item 1, for the sync reading).
- Tracking: No. No data types linked to the user.
- Privacy policy URL: required (policy to be written from this file).

## 5. Items needing owner verification

1. Whether Apple wants user-configured sync (username or Readest email / book hashes / reading position /
   device UUID going to the user's own server or Readest account) listed under App Privacy. Readest Cloud is a
   fixed, named third party (not user-run), which makes the conservative reading more likely to be expected. The conservative alternative is to also declare Other User Content /
   Device ID / User ID, "not linked", purpose App Functionality; the current files take the "developer
   receives nothing" reading. Verify with Apple's "App privacy details" documentation.
2. The download User-Agent contains the GitHub project URL; replace it with a real contact URL/email if the repo moves.
3. Local network permission: iOS shows a prompt the first time the app contacts a LAN address
   (`NSLocalNetworkUsageDescription`, localised en/es, in the iOS and watch Info.plists).
