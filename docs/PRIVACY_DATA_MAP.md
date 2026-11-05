# Folito: privacy data map

Source of truth for what data leaves the device, to whom and why. The privacy policy and the App Store
"App Privacy" answers must match this file. Audited against the code (every `URLSession` use,
`UserDefaults`, Keychain, file and WatchConnectivity use). Re-audit when networking code changes.

Summary: the developer operates **no server** and receives **no data**. The App Store label still declares the
optional sync data (section 3). There is no analytics, advertising,
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
| Readest, `https://web.readest.com/api/sync?type=books` (iPhone Library) | Access token of the iPhone's own library session | yes | Reads the account's book list (titles, authors, hashes, upload state). |
| Readest, `https://web.readest.com/api/storage/download`, `list`, `stats` (iPhone) | File keys (`{user id}/Readest/Books/{book hash}/…`) | yes | Download of a cover or EPUB only when shown / tapped; storage usage in Settings. |
| Readest's storage (presigned URLs returned by the API) | The EPUB file | **only on explicit user action**: *Upload to Readest*, or the opt-in *Upload Imported Books Automatically* (off by default) | The original file as imported, and its cover as `cover.png` (taken from that file). Plus, in `POST /api/sync`, that book's row: `hash`, `metaHash`, `format`, `title`, `author`, `uploadedAt`. |
| Readest, `DELETE /api/storage/delete` + `POST /api/sync` (tombstone) | File keys, book row | only when the user confirms *Delete from Readest* | |

Endpoints: `POST /auth/v1/token` (password and refresh grants), `POST /auth/v1/logout?scope=local` (sign out,
best effort), `GET /api/sync?type=configs&book=…&meta_hash=…`, `POST /api/sync` (configs; from the iPhone
Library also `books` rows), `GET /api/sync?type=books`, `/api/storage/upload|download|list|delete|stats`
(iPhone only). No notes or statistics are sent. Recipient: Readest (the user's own account, governed by
Readest's privacy policy). The developer is not a party and receives nothing. At sign-in the iPhone signs in
twice: one session goes to the watch for sync, the other stays in the iPhone Keychain for the Library (see
`docs/READEST_SYNC.md`, "The iPhone's own session"). Signing out on the iPhone removes both sessions from both
devices and asks Supabase to revoke them.

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
  paired devices. Books carry a small JPEG of their cover (taken from the EPUB) when they have one.
- Apple Watch to iPhone (same channel, the `library` report): the hashes of the books and dictionaries on the
  watch, the watch's typography, the estimated reading time left per book (seconds, rounded to whole
  minutes) and the percentage read of each book opened on the watch, shown in the iPhone library and book details. The learned reading speed itself never leaves the watch.
- No iCloud, CloudKit, Keychain access groups or app groups are used.

## 2. Data stored on device only

| Data | Where | Notes |
|---|---|---|
| Active sync service id | iPhone: UserDefaults (`sync.connector`); watch: Keychain (`sync_connector`) | |
| KOSync server URL, username, password | Keychain (iPhone and watch each have their own item; no access groups) | Never leaves the device except as described in 1a/1c. |
| Readest email and session (access + refresh token) | Keychain (iPhone and watch; the watch updates its copy when the session is refreshed) | No password. Removed on Sign Out. |
| Readest library session (access + refresh token) | iPhone Keychain only (`readest_library_session`) | Never sent to the watch. Removed and revoked on Sign Out. |
| Library (processed books and, on the iPhone, the original EPUB) | `Application Support/Folito/Books` (iPhone), watch app's Application Support (processed books only) | Files the user imports or downloads from Readest. Uploaded only as described in 1a-bis. |
| Covers and book details of local books (description, series, publisher, year, language, ISBN) | iPhone: `Application Support/Folito/Books/<hash>.cover.jpg` and `<hash>.watch.jpg`, details in `library.json`; watch: `Books/<hash>.cover.jpg` | Read from the EPUB at import; nothing is looked up online. Removed with the book. |
| Readest book list and covers (cache) | iPhone: `Application Support/Folito/readest-library.json`, `Caches/ReadestCovers` | So the Library can show Readest books offline. Removed on Sign Out. |
| "Upload Imported Books Automatically", Library filter | UserDefaults | Off / All by default. |
| Reading position, typography, device UUID, pending sync queue | UserDefaults | |
| Complication snapshot (book id, title, chapter title, percentage, minutes left in the chapter when *Show Time Remaining* is on) | watch: App Group UserDefaults (`group.<bundle id>`, key `complication.snapshot`), shared only with the watch app's own widget extension | Written by the watch app, read by the complications. Never leaves the watch. Cleared when the book is deleted or on Settings › Reset. |
| Learned reading speed and estimated time left per book | Watch: UserDefaults (`reading.speed`, `reading.timeRemaining`) | Computed on the watch from the time spent per page; used only to show "time left" (in the reader, the iPhone library and the complications). Cleared by *Settings › Reset* (and per book when the book is deleted). |
| Offline dictionaries | `Application Support/Folito/Dictionaries` (iPhone and watch) | Downloaded/converted files; deleted from *Settings › Dictionaries* on the iPhone (removes them from the watch too). Download validators (ETag) and checksums in UserDefaults. |

## 3. Privacy manifest declarations (`iOSApp/PrivacyInfo.xcprivacy`, `WatchApp/PrivacyInfo.xcprivacy`, `WatchWidgets/PrivacyInfo.xcprivacy`)

- `NSPrivacyTracking` = false, `NSPrivacyTrackingDomains` = empty. The app does not track.
- Required-reason APIs actually used: **UserDefaults** only, reason `CA92.1` (read/write the app's own
  preferences, not shared with other apps). The watch app and its widget extension also declare `1C8F.1`
  (the complication snapshot in their shared App Group); the extension collects no data types. Audited and **not used**: file timestamp APIs (`creationDate`,
  `modificationDate`, `stat`, `getattrlist`...; the code only copies, writes and deletes files), disk space
  APIs, system boot time (`systemUptime`, `mach_absolute_time`), active keyboard APIs. Re-check if code that
  uses these is added.
- Collected data types (owner decision, see `docs/appstore/APP_PRIVACY.md`): **Email Address**, **User ID**,
  **Device ID** and **Other User Content**, each linked to the user, not used for tracking, purpose App
  Functionality. Both manifests declare the same set.
  Rationale: Apple defines "collect" as data transmitted off device to the developer or its third-party partners.
  Sync data (username or Readest email, book hashes, reading position, device UUID) goes only to a service the
  user chooses and signs in to with their own account (a KOSync server, or Readest Cloud), never to the
  developer, so a strict reading would declare nothing. It is declared anyway (conservative reading) so the label
  cannot look inconsistent with a visible email/password sign-in. Because those services store it per account,
  it is declared **linked**. Not declared: the password hash and session tokens (credentials, not a listed data
  type), the IP address (inherent to any request), and dictionary downloads from reader.dict, which send no user
  data beyond the request itself. Lookups are on device. (Before the offline dictionaries, looked-up words went
  to Wiktionary / dictionaryapi.dev and were declared as Search History.)

| Declared type | What it is in Folito | Sent to |
|---|---|---|
| Contact Info › Email Address | Readest account email | Readest's Supabase auth, once at sign-in (iPhone) |
| Identifiers › User ID | KOSync username; the Readest account (via its access token) | the KOSync server; Readest |
| Identifiers › Device ID | random UUID generated on first launch | the KOSync server only |
| User Content › Other User Content | book hashes and reading positions; with Readest also the EPUB files the user uploads and their title/author | the KOSync server or Readest |

## 4. App Store Connect "App Privacy" answers

Final answers and click-through: `docs/appstore/APP_PRIVACY.md`. In short: data collected (the four types
above), all linked to the user, all App Functionality only, no tracking. Privacy policy URL:
`https://folito.app/privacy.html` (translations under `/<lang>/`).

## 5. Items needing owner verification

1. The download User-Agent contains the GitHub project URL; replace it with a real contact URL/email if the repo moves.
2. Local network permission: iOS shows a prompt the first time the app contacts a LAN address
   (`NSLocalNetworkUsageDescription`, localised en/es, in the iOS and watch Info.plists).
