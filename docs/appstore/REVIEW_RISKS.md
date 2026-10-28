# Likely App Review risks and mitigations

Checked against the [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) as fetched 2026-10-28 (Apple edits them regularly; re-read before submitting). This is analysis, not a guarantee of approval.

| # | Guideline | Risk | Mitigation |
|---|---|---|---|
| 1 | **2.1 App Completeness**: "include demo account info (and turn on your back-end service!)" | The app is mostly useless for sync testing without a KOSync account; a reviewer without one may reject with "unable to test". | Provide a working demo account and a sample EPUB in the review notes (`REVIEW_NOTES.md`); say clearly that reading works without any account; keep the server online during the whole review (self-host if needed). Test the demo credentials on the day you submit. |
| 2 | **2.1** | Watch app needs the iPhone app opened once and a paired watch; a reviewer may think the watch app is "empty". | Say it in the notes (done). The watch app shows an empty-library state; make sure it says what to do (open the iPhone app / import a book). Consider a bundled public-domain sample book for first run (owner decision; improves 2.1 and 4.2 at the same time). |
| 3 | **4.2 Minimum Functionality**: app must be "useful, unique, or app-like" and not a repackaged website | A "simple EPUB reader" can be questioned, especially a watch app. | It is a native app with parsing, typography controls, dictionary and background progress sync, which is more than a wrapper. List these concrete features in the description and notes. 4.2.3(i) says the app should work on its own without another app: the watch app declares `WKRunsIndependentlyOfCompanionApp`, so say it works standalone once books are loaded. |
| 4 | **5.1.1(i) Privacy policy** | Policy URL must be in App Store Connect **and within the app**. The app currently has no in-app link. | Add a "Privacy Policy" link in the iPhone app Settings (owner decision/another change) before submission; otherwise expect a rejection. Policy: `docs/site/privacy.html`; re-check it against `docs/PRIVACY_DATA_MAP.md`. |
| 5 | **5.1.1(v) Account sign-in / account deletion**: "If your app supports account creation, you must also offer account deletion within the app" | The Sync screen has a **"Create account"** button that creates an account on a third-party KOSync server. KOSync has no deletion endpoint, so deletion cannot be offered. | Preferred: remove the button from the App Store build and tell users to create accounts on the server/KOReader/Readest (the app then only signs in to an existing account). Otherwise explain in the notes that the account lives on the user's own server, outside the developer's control, and expect a possible rejection. **Owner decision.** |
| 6 | **5.1.1/5.1.2 data use and App Privacy accuracy** | A mismatch between the nutrition label, privacy manifest and real behaviour is a classic rejection. | `APP_PRIVACY.md` and `docs/PRIVACY_DATA_MAP.md` must agree (Search History declared; no tracking). Re-audit whenever networking code changes. |
| 7 | **5.2.1 Intellectual property** (no third-party trademarks or misleading metadata) and **5.2** generally | Naming KOReader/Readest could look like affiliation or endorsement; using their logos or UI is infringement. | Nominative use only: name them in the description solely to say the protocol is compatible ("KOReader Sync protocol, as used by KOReader and Readest"); never in the app name, subtitle, keywords or screenshots; no logos; keep the "not affiliated" sentence. Do not use "Kindle", "Kobo" etc. Fonts: only system fonts are used. Dictionary content: Wiktionary is CC BY-SA; keep a visible attribution in the app (the definitions come from Wiktionary) if you can; mention it in the notes. |
| 8 | **5.2.5 Apple products** | Using Apple watch/iPhone imagery in the icon or screenshots. | Icon must be original; no Apple logos; device frames only as allowed in Apple's marketing resources. |
| 9 | **4.0 Design** (introduction: apps must be "simple, refined … easy to use") and HIG | Small touch targets, clipped text with large Dynamic Type, missing empty states, or an unlocalised UI. | Test with the largest Dynamic Type, VoiceOver, light/dark; the UI strings are English only while a Spanish description is offered: either localise or limit the Spanish metadata. |
| 10 | **4.8 Login services** | None expected: there is no third-party social login. | n/a (4.8 applies only to apps using third-party or social login for a primary account). |
| 11 | **ATS / network** | `NSAllowsLocalNetworking` plus the local-network prompt may be questioned. | Explain in notes: plain `http://` works only for the user's own LAN server; all internet traffic is HTTPS. No `NSAllowsArbitraryLoads`. |
| 12 | **Beta review (TestFlight external)** | External testing triggers the same review of the first build. | Reuse `REVIEW_NOTES.md` for "Beta App Review Information". |
| 13 | **Content rights** | Users import their own books; the app has no DRM support and ships no copyrighted content. | Answer "does your app contain, show or access third-party content" accurately in App Store Connect (it displays user-imported files and Wiktionary definitions) and keep screenshots to public-domain text. |

## Pre-submission checklist

* [ ] Demo account works; sample EPUB attached; review notes filled.
* [ ] Privacy policy URL live, contact placeholders replaced, in-app link added.
* [ ] "Create account" decision made (risk 5).
* [ ] App Privacy answers entered; match the privacy manifests.
* [ ] Export compliance key present in the build.
* [ ] Screenshots at valid sizes (`SCREENSHOTS.md`).
* [ ] Names KOReader/Readest only in the compatibility sentence.
* [ ] Build tested on a real iPhone and watch via TestFlight (cold install, import, sync, offline reading).
