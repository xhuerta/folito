# App Privacy ("nutrition label") answers

Source of truth: `docs/PRIVACY_DATA_MAP.md` (added by PR #17, `store/assets-compliance`; not on this branch yet) and the two `PrivacyInfo.xcprivacy` files. This file, `docs/site/privacy.html` and `docs/site/es/privacy.html` were cross-checked item by item against that map on 2026-10-28. Re-check whenever networking code changes. You (the account holder) make the declaration; this is a proposal, not legal advice.

Apple's definition ([App privacy details](https://developer.apple.com/app-store/app-privacy-details/)): "collect" means transmitting data off the device in a way that allows you and/or your third-party partners to access it for longer than needed to service the request in real time.

## Facts (from the data map)

* No account is needed to use the app. The developer operates no server and receives nothing. No SDKs, no analytics, no ads, no crash reporting, no IDFA, no tracking. No iCloud/CloudKit, App Groups or Keychain access groups.
* **Sync (optional, off by default, user-supplied KOReader Sync server)**: username (header), lowercase MD5 hex of the password (never the password), book identifier (KOReader partial-MD5 of the EPUB), reading position (XPointer + percentage), device name constant `Folito`, and a random UUID generated on first launch (not a hardware, vendor or advertising ID). No timestamp is sent (server-assigned). Sent **only to the server the user configured**; nothing is sent while no login is saved. The app has no account creation and no account with the developer.
* **Sync with Readest Cloud (optional, off by default, the user's own Readest account)**: the Readest account email and password, once, at sign-in, to Readest's authentication provider (Supabase, `vbsyxfusjjqdxkjqlysc.supabase.co`); afterwards only the session tokens (access token as `Authorization` header, refresh token about hourly to renew it). To `web.readest.com`: book identifiers (KOReader partial-MD5 of the EPUB and Readest's metadata hash, an MD5 of title, authors and identifier; not the title or file), reading position (XPointer, `[paragraph, paragraph count]`, time it was reached). No device ID. The password is never stored; the email and session are stored in the Keychain. Sign Out removes them from both devices and revokes the session. Only one sync service is active at a time.
* **Dictionary (on user action only)**: the looked-up word and simple variants (lower-cased, de-inflected) go over HTTPS to `en.wiktionary.org` and, only for English words Wiktionary lacks, to `api.dictionaryapi.dev`, with a `User-Agent` naming the app and its project URL, over an ephemeral session (no cookies, no persistent cache). Not sent: title, author, surrounding text, position, sync login, device UUID.
* **Between the user's own devices (WatchConnectivity)**: processed books, typography settings and, when sync is on, the active service's credentials: for KOReader Sync the server URL, username and password (the watch computes the MD5 itself); for Readest the email and session tokens (never the password). Not a transmission to the developer or a third party.
* **On device only**: login or Readest session in the Keychain (iPhone and watch, separate items); library files in Application Support; reading positions, typography, device UUID and pending-sync queue in UserDefaults; dictionary cache file.

## Proposed answers in App Store Connect → App Privacy

1. **Do you or your third-party partners collect data from this app?** **Yes**, conservatively, for the dictionary requests (third-party services that may log them), matching the privacy manifests. Declare only:
   * **Search History** (the words the user looks up). Linked to the user: **No**. Used for tracking: **No**. Purpose: **App Functionality**.
2. **Sync data** (KOSync: username, password hash, book hash, reading position, device UUID; Readest: email, session token, book and metadata hashes, reading position): optional and sent only to a service the user chooses and signs in to with their own account, never to the developer or a partner of the developer. Not declared (the data map's reading). The conservative alternative, an owner decision listed in the data map section 5, is stronger now that Readest Cloud is a fixed, named third-party service: additionally declare **Email Address** and **User ID** (Readest account), **Device ID** (KOSync), and **Other User Content** (book hashes and reading positions), all *not linked to the user's identity by the developer, no tracking, App Functionality*. Recommendation: take the conservative alternative before shipping Readest sync.
3. **Tracking**: **No**. No data linked to the user. Tracking domains: none.
4. **Privacy Policy URL**: `https://folito.app/privacy.html` (Spanish: `…/es/privacy.html`). It must be the same URL as the in-app link (`AppLinks.privacyPolicy` in `iOSApp/Support/AppLinks.swift`, PR #20, currently `https://example.com/...`).
5. **Privacy choices URL**: leave empty.

## Privacy manifest (in the app bundle)

`iOSApp/PrivacyInfo.xcprivacy` and `WatchApp/PrivacyInfo.xcprivacy` (PR #17): `NSPrivacyTracking = false`, no tracking domains, required-reason API `UserDefaults` (`CA92.1`) only, collected type Search History (not linked, no tracking, App Functionality). The answers above match those files.

## Accessibility (App Store "Accessibility Nutrition Labels")

See `ACCESSIBILITY_LABELS.md` in this folder.
