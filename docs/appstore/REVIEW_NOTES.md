# App Review information (paste into "App Review Information")

**No sign-in is required and no demo account is needed.** In App Store Connect leave **"Sign-in required" unticked** and the demo username/password fields empty. The app works fully with the bundled sample books or books the reviewer imports; reading-progress sync is optional, off by default, and talks only to a KOReader Sync server the user supplies (the developer runs no server). There is no in-app account creation (accounts live on the user's own sync server), so guideline 5.1.1(v) account deletion does not apply.

## Before submitting (owner)

1. Reviewers do not need to find an EPUB: the app bundles a short public-domain sample book per language (see docs/SAMPLE_BOOKS.md), added with **Add a Sample Book** on the welcome tour's "Try It Now" page or in the empty Library. Attaching an extra public-domain EPUB (or linking one, e.g. <https://www.gutenberg.org/ebooks/11.epub.noimages>) is optional, for reviewers who want to test the Files / share-sheet import too.
2. Fill `xlahuerta@protonmail.com` below (and a phone number in the App Store Connect contact fields, which are not part of the notes).

## Notes text

```
Folito is an EPUB reader for Apple Watch. The iPhone app imports the user's own EPUB files and sends them to the watch; the watch app reads them.

NO ACCOUNT IS NEEDED. Everything can be reviewed without signing in: import a book, read it on the watch, change typography, look up a word. There is no account with the developer and no account creation in the app.

How to test:
1. Install the iPhone app and open it once with the paired Apple Watch nearby and unlocked. The watch app installs from the Watch app on the iPhone (or automatically). A short welcome tour opens on first launch (it can be skipped, and reopened in Settings > About > Show Welcome Tour).
2. Add a book. Quickest: tap "Add a Sample Book" on the tour's "Try It Now" page, or in the empty Library. It adds a short public-domain book bundled with the app (in the app's language) through the normal import, marked "Sample" in the Library and deletable like any book. To test importing your own file: open any DRM-free .epub from the Files app / share sheet and choose Folito, or tap "Import EPUB" (+) in the Library tab and pick the file in Files (e.g. https://www.gutenberg.org/ebooks/11.epub.noimages). The book appears in the Library and is sent to the watch within a few seconds.
3. On the watch, open Folito, choose the book and scroll with the Digital Crown. Reading Options (top-right button) has text size, typography, chapters and dictionary. Look up a word works offline once a dictionary is installed: in the iPhone app, Settings > Dictionaries > Download (e.g. English, about 50 MB); it is sent to the watch automatically.
4. On the iPhone, the Reading tab changes typography for the watch with a live preview. Settings > About has the privacy policy, support link and open-source licences.

Optional progress sync: Settings > Progress Sync connects to a KOReader Sync ("kosync") server that the USER supplies (self-hosted or one they already use with KOReader). It is off by default, needs an existing account on that server, and can be turned off at any time ("Turn Off Sync and Remove Login" removes the login from the iPhone and the watch). It is not required to evaluate the app. Plain http:// is allowed only for the user's own local-network server (NSAllowsLocalNetworking); all internet traffic is HTTPS.

No in-app purchases, no user-generated content shared with others, no analytics, no ads, no tracking. Dictionary lookups happen on the watch and send nothing; the only dictionary traffic is the file download from reader-dict.com that the user starts on the iPhone.
Contact: xlahuerta@protonmail.com
```

For TestFlight external testing reuse the same text in "Beta App Review Information".
