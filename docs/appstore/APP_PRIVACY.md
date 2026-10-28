# App Privacy ("nutrition label") answers

Consistent with `docs/site/privacy.html` and, on the parallel branch `store/assets-compliance`, `docs/PRIVACY_DATA_MAP.md` and the two `PrivacyInfo.xcprivacy` files. **Re-check this file against `docs/PRIVACY_DATA_MAP.md` once both are on main**, and again whenever networking code changes. You (the account holder) make the declaration; this is a proposal, not legal advice.

Apple's definition ([App privacy details](https://developer.apple.com/app-store/app-privacy-details/)): "collect" means transmitting data off the device in a way that allows you and/or your third-party partners to access it for longer than needed to service the request in real time. "Third-party partners" are analytics tools, ad networks, SDKs or other external vendors whose code you added.

## Facts (from the code)

* The developer operates no server and receives nothing. No SDKs, no analytics, no ads, no IDFA.
* Sync (KOReader Sync protocol): username, MD5 of the password, book hash, reading position, constant device name and a random per-install UUID go **only to the server the user typed in**.
* Dictionary: the looked-up word (plus simple variants) goes to `en.wiktionary.org` and, for English, `api.dictionaryapi.dev`, on user action only, over an ephemeral session.

## Proposed answers in App Store Connect → App Privacy

1. **Do you or your third-party partners collect data from this app?**
   * Recommended: **Yes**, to be conservative about the dictionary requests, which go to third-party services that may log them (this is the choice made in `PRIVACY_DATA_MAP.md`). Declare only:
     * **Search History** (the words the user looks up). Linked to the user: **No**. Used for tracking: **No**. Purpose: **App Functionality**.
   * The alternative reading is "Data Not Collected": the services are public APIs the user's request is addressed to, not partners whose code is in the app, and the developer can never access the data. It is defensible but riskier if Apple disagrees; the conservative declaration costs nothing.
2. **Sync data (username, password hash, reading position, device UUID)**: sent to a server chosen and operated by the user, never to the developer or a partner. Not declared. If you prefer the most conservative reading, additionally declare **User ID** (username), **Other User Content** (reading position) and **Device ID** (the random UUID), all *not linked, no tracking, App Functionality*. Owner decision.
3. **Tracking**: **No**. No data linked to the user. "Tracking domains": none.
4. **Privacy Policy URL**: `https://<owner>.github.io/<repo>/site/privacy.html` (required).
5. **Privacy choices URL**: leave empty.

## Privacy manifest (in the app bundle)

Declared in `iOSApp/PrivacyInfo.xcprivacy` and `WatchApp/PrivacyInfo.xcprivacy` by the other branch: no tracking, `UserDefaults` required-reason API (CA92.1), collected type Search History. The App Store Connect answers above must match those files.
