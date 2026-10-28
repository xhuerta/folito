# App Review information (paste into "App Review Information")

**No sign-in is required and no demo account is needed.** In App Store Connect leave **"Sign-in required" unticked** and the demo username/password fields empty. The app works fully with books the reviewer imports; reading-progress sync is optional, off by default, and talks only to a KOReader Sync server the user supplies (the developer runs no server). There is no in-app account creation (accounts live on the user's own sync server), so guideline 5.1.1(v) account deletion does not apply.

## Before submitting (owner)

1. Reviewers need an EPUB. The App Store build ships **no sample book** (the built-in sample in `UITestingSupport.swift` exists only in Debug builds for UI tests). Either attach a small public-domain EPUB to the App Review notes (App Store Connect allows an attachment) or give a direct HTTPS download link, e.g. a Project Gutenberg "EPUB (no images)" file such as <https://www.gutenberg.org/ebooks/11.epub.noimages> (Alice's Adventures in Wonderland). Check the link works the day you submit.
2. Fill `xlahuerta@protonmail.com` below (and a phone number in the App Store Connect contact fields, which are not part of the notes).

## Notes text

```
WristReader is an EPUB reader for Apple Watch. The iPhone app imports the user's own EPUB files and sends them to the watch; the watch app reads them.

NO ACCOUNT IS NEEDED. Everything can be reviewed without signing in: import a book, read it on the watch, change typography, look up a word. There is no account with the developer and no account creation in the app.

How to test:
1. Install the iPhone app and open it once with the paired Apple Watch nearby and unlocked. The watch app installs from the Watch app on the iPhone (or automatically).
2. Import an EPUB: download the attached public-domain book (or https://www.gutenberg.org/ebooks/11.epub.noimages) and either open it from the Files app / share sheet and choose WristReader, or tap "Import EPUB" (+) in the Library tab and pick the file in Files. Any DRM-free .epub works. The book appears in the Library and is sent to the watch within a few seconds.
3. On the watch, open WristReader, choose the book and scroll with the Digital Crown. Reading Options (top-right button) has text size, typography, chapters and dictionary. Look up a word needs an internet connection (Wiktionary / dictionaryapi.dev).
4. On the iPhone, the Reading tab changes typography for the watch with a live preview. Settings > About has the privacy policy, support link and open-source licences.

Optional progress sync: Settings > Progress Sync connects to a KOReader Sync ("kosync") server that the USER supplies (self-hosted or one they already use with KOReader). It is off by default, needs an existing account on that server, and can be turned off at any time ("Turn Off Sync and Remove Login" removes the login from the iPhone and the watch). It is not required to evaluate the app. Plain http:// is allowed only for the user's own local-network server (NSAllowsLocalNetworking); all internet traffic is HTTPS.

No in-app purchases, no user-generated content shared with others, no analytics, no ads, no tracking. Dictionary lookups send only the selected word to Wiktionary / dictionaryapi.dev.
Contact: xlahuerta@protonmail.com
```

For TestFlight external testing reuse the same text in "Beta App Review Information".
