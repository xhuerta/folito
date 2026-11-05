# App Privacy ("nutrition label"): final answers

**Decision (owner, 2026-11):** declare the optional sync data, the conservative option that App Review is most
likely to accept. This file is the click-through for App Store Connect → *App Privacy*. It matches
`docs/PRIVACY_DATA_MAP.md` (the audited list of what leaves the device), both `PrivacyInfo.xcprivacy` files and
the privacy policy at <https://folito.app/privacy.html>. Re-check all of them whenever networking code changes.

Apple's terms ([App privacy details](https://developer.apple.com/app-store/app-privacy-details/)):

* "Collect" means transmitting data off the device in a way that allows you and/or your third-party partners
  to access it for longer than needed to service the request in real time.
* Data is "linked to the user" when it is linked to the user's identity (via their account, device or other
  details) by you and/or your third-party partners, unless it is de-identified before collection.
  "Personal Information" and "Personal Data" under privacy laws are always considered linked.

## Why declare data that the developer never receives

The developer runs no server and receives nothing. The only data that leaves the device for a service goes to
the progress-sync service the user picks and signs in to with their own account: a KOReader Sync server or
Readest Cloud (Readest's sign-in runs on Supabase). Under a strict reading those services are not the
developer's "third-party partners" (Apple means SDKs and vendors whose code is in the app), so nothing would
have to be declared. We declare it anyway:

* Readest Cloud is a fixed, named service the app talks to, and a reviewer who sees an email/password sign-in
  next to a "Data Not Collected" label may reject the build for a mismatch (guideline 5.1.1/5.1.2). Declaring
  costs nothing: the data is optional, used only for the feature the user turned on, and never for tracking.
* The privacy policy already describes all of it, so the label, the manifests and the policy agree.

Not declared, and why: the hashed KOSync password and the Readest session tokens are authentication
credentials, not a data type in Apple's list; the IP address is inherent to any request and the app does not
send or store it; a dictionary download from reader.dict (`www.reader-dict.com`) is a plain file request that
reveals only the chosen language and is kept by nobody on the developer's behalf; word lookups are offline.

## Online book details (Open Library): no change to the answers

*Find Details Online* and the opt-in *Find Missing Details Online* (off by default) send the book's **ISBN**, or
its **title and first author**, from the iPhone to **Open Library** (openlibrary.org / covers.openlibrary.org, run by
the Internet Archive) to fetch a missing cover, description, year, publisher or subjects
(`docs/ONLINE_METADATA.md`, `docs/PRIVACY_DATA_MAP.md` 1b-bis). Evaluated against Apple's definition:

* **Is it "collected"?** Apple: collecting means transmitting data off the device "in a way that allows you
  and/or your third-party partners to access it for longer than necessary to service the transmitted request in
  real time". The request goes straight from the iPhone to Open Library and is answered at once; nothing is sent
  to the developer, who runs no server and never receives the ISBN, title, author or the answer. Open Library is
  **not a third-party partner** of the developer: there is no SDK, no contract, no data sharing, no account; it is a
  public service the app calls on the user's behalf, like a web page the user opens. Whatever Open Library logs
  (the Internet Archive says it encrypts IP addresses with a daily key) is its own processing under its own
  policy, not access by the developer or a partner. So by the definition the data is **not collected**.
* **Even on the conservative reading used for sync** (treating a fixed, named service as the collecting party), the
  data is not a user data type that the label covers: an ISBN or a published book's title and author is
  bibliographic data about a commercially published work, not the user's content (the EPUB, the reading position,
  or anything the user wrote), not an identifier, and not *Search History* (the user types no query; the app sends
  metadata it already has, and no history is kept or associated with an account). Unlike the sync services, there
  is no sign-in, no account and nothing stored per user, so there is nothing for "Linked to You" to describe.
* **Tracking**: none. Open Library is not an advertising or data-broker service; no identifier is sent.

**Conclusion: no App Privacy answer changes.** The four declared types, their purposes (App Functionality), *Linked
to You* and *Tracking: No* stay exactly as below; no new type is ticked. The privacy manifests do not change either:
`NSPrivacyTrackingDomains` lists tracking domains only, and openlibrary.org / archive.org are not tracking domains;
no required-reason API is added (the lookup uses UserDefaults for its setting, already declared with `CA92.1`). The
privacy policy describes the lookup (section "Book details from Open Library"), so the policy, the label and the
manifests stay consistent. Re-evaluate if the lookup ever sends anything about the user or goes through a server
of the developer.

**Readest.** A cover the user accepted from Open Library (only for a book whose EPUB has none) is uploaded as that
book's `cover.png` when the user uploads the book to their own Readest account. That upload is already covered by
**Other User Content** (the EPUB files the user uploads and their library row); no change.

## Why "Linked to You" (changed from the first draft's "not linked")

The first draft said *not linked to the user's identity by the developer*. That is true of the developer, but
the label asks about "you and/or your third-party partners", and once we treat the sync services as the
collecting party (the whole point of over-declaring), every declared item is stored in, or sent with, the
user's account on that service:

* the Readest **email address** is the account itself, and an email address is personal data, which Apple
  always counts as linked;
* the KOSync **username** and the Readest account (identified by its access token) are account IDs by
  definition;
* the KOSync **device UUID** is sent together with the username and stored with the progress record of that
  account;
* the **book hashes and reading positions** are stored per account (that is how the other device finds them).

None of it can be de-identified before it is sent: the feature cannot work without the account. So the
accurate answer is **Linked to You** for all four types. Linked is not tracking: there is no tracking, no
advertising and no data broker, so *Tracking* stays **No**.

## Step by step in App Store Connect → App Privacy

1. **Privacy Policy URL**: `https://folito.app/privacy.html`. Localized versions are at
   `https://folito.app/<lang>/privacy.html` (`es`, `fr`, `de`, `it`, `pt-br`, `ja`, `zh-hans`); enter them in
   the matching App Store localizations if you want. The in-app link (`AppLinks.privacyPolicy` in
   `iOSApp/Support/AppLinks.swift`) opens the same page in the user's language.
2. **User Privacy Choices URL**: leave empty.
3. **Get Started** → *Do you or your third-party partners collect data from this app?* → **Yes, we collect
   data from this app**.
4. Tick exactly these data types, then **Save**:
   * **Contact Info › Email Address** (the Readest account email, sent at sign-in);
   * **Identifiers › User ID** (the KOReader Sync username and the Readest account);
   * **Identifiers › Device ID** (the random UUID the app generates on first launch and sends to a KOReader
     Sync server; not a hardware, vendor or advertising identifier);
   * **User Content › Other User Content** (book identifiers, which are hashes of the file and of its title,
     authors and identifier, and reading positions; with Readest also the EPUB files the user uploads to their
     own Readest account, and the title and author in that book's library row).

   Leave everything else unticked. Previous builds declared *Search History* for online word lookups; make
   sure it is not ticked, lookups are offline now.
5. For **each** of the four types, answer the three questions the same way:
   * *How is this data used?* → **App Functionality** only (nothing else: no Analytics, Product
     Personalization, Developer's Advertising or Marketing, Third-Party Advertising, or Other Purposes).
   * *Is this data linked to the user's identity?* → **Yes** (see the section above).
   * *Is this data used for tracking purposes?* → **No**.
6. **Publish**. The product page should then show **Data Linked to You: Contact Info, Identifiers, User
   Content**, no *Data Used to Track You*, and no *Data Not Linked to You*.

## Facts behind the answers (summary of the data map)

* No account is needed to use the app. No SDKs, analytics, ads, crash reporting, IDFA or tracking. No iCloud,
  CloudKit, App Groups or Keychain access groups.
* **KOReader Sync** (optional, off by default, server chosen by the user): username (header `x-auth-user`),
  MD5 of the password (never the password), book identifier (KOReader partial MD5 of the EPUB), reading
  position (XPointer and percentage), device name `Folito` and the random device UUID. No timestamp.
* **Readest Cloud** (optional, off by default, the user's own Readest account): email and password once, at
  sign-in on the iPhone, to Readest's Supabase auth (`vbsyxfusjjqdxkjqlysc.supabase.co`); then only session
  tokens. To `web.readest.com`: book hash and metadata hash, reading position (XPointer, paragraph number and
  count, time reached). No device ID. The password is never stored. Only one sync service is active at a time.
  Readest library on the iPhone: the list of the account's books is read, covers and EPUB files are downloaded
  when the user taps them, and an EPUB file with its title, author and hashes is uploaded **only** when the user
  chooses *Upload to Readest* or turns on *Upload Imported Books Automatically* (off by default). Files go to the
  user's own Readest storage (presigned URLs on Readest's storage host). Already covered by **Other User Content**
  (linked, App Functionality, not tracking): no new data type and no change to the privacy manifests.
* **Online book details** (optional, iPhone only, off by default or on an explicit tap): the book's ISBN, or its
  title and first author, to Open Library; nothing about the user; not collected (see above), no new data type.
* **Dictionaries**: downloaded on the iPhone from `www.reader-dict.com` only when the user taps Download or
  Update (plus a HEAD update check while *Settings › Dictionaries* is open). Lookups run on the watch offline.
* **Between the user's own devices** (WatchConnectivity): books, dictionaries, typography and the active sync
  credentials; from the watch, the estimated reading time left per book. Not a transmission to anyone else.
* **Time remaining**: the reading speed is learned on the watch from the time spent per page and stored only
  there (UserDefaults); it is never sent over the network, so it adds no data type to the label.

## Privacy manifests (in the app bundles)

`iOSApp/PrivacyInfo.xcprivacy` and `WatchApp/PrivacyInfo.xcprivacy` declare the same: `NSPrivacyTracking = false`,
no tracking domains, required-reason API `UserDefaults` only (`CA92.1`; the watch app also `1C8F.1`, because it
writes the complication snapshot to the App Group shared with its own widget extension), and `NSPrivacyCollectedDataTypes` with
`EmailAddress`, `UserID`, `DeviceID` and `OtherUserContent`, each `Linked = true`, `Tracking = false`,
purpose `AppFunctionality`. Both apps declare the full set because the label covers the app record as a whole
(the watch app ships inside the iOS app) and the split between the devices may change; declaring the union in
each costs nothing.

`WatchWidgets/PrivacyInfo.xcprivacy` (the complications / Smart Stack widget extension inside the watch app):
`NSPrivacyTracking = false`, no tracking domains, **no collected data types**, required-reason API `UserDefaults`
(`1C8F.1`: it reads the snapshot the watch app writes to their shared App Group). The complications add **no data
collection**: the snapshot (book id, title, chapter title, percentage) stays on the watch and is never sent anywhere,
so the App Store privacy answers above do not change.

## Accessibility (App Store "Accessibility Nutrition Labels")

See `ACCESSIBILITY_LABELS.md` in this folder.
