# App Review information (paste into "App Review Information")

Fill the bracketed items. Guideline 2.1 requires working demo credentials and a live back end during review.

## Demo account (owner task, before submitting)

1. Pick a public KOSync-compatible server (for example `https://sync.koreader.rocks`, or a server you host that will stay online during review).
2. Create a dedicated account used for nothing else (it can be done in the app: Sync → "Create account"). Use a throw-away password.
3. Put the server URL, username and password in the **Sign-in required** fields of App Store Connect (demo account) and in the notes below.
4. Check the account works from the app (Sync → Test connection) the day you submit; public servers sometimes have outages. Consider hosting your own small `kosync` server (see `scripts/kosync-server`) so you control uptime.
5. Attach a small, freely licensed EPUB (e.g. a public-domain book) to the review notes or provide a direct download URL: reviewers may not have one.

## Notes text

```
WristReader is an EPUB reader for Apple Watch. The iPhone app imports books and sends them to the watch; the watch app reads them.

IMPORTANT: Reading works without any account. Reading-progress sync is optional and uses a KOReader Sync ("kosync") server chosen by the user; the app does not provide a server. For review we created a demo account:
  Server:   [SERVER_URL]
  Username: [DEMO_USERNAME]
  Password: [DEMO_PASSWORD]
Enter these in the iPhone app: Sync tab → Server URL, Username, Password → "Save & send to watch" → "Test connection" (should say the account is valid). The credentials are sent to the paired watch automatically.

How to test:
1. Install the iPhone app and OPEN IT ONCE with the paired Apple Watch nearby and unlocked. The watch app installs from the Watch app on the iPhone (or automatically) and receives the settings.
2. Import an EPUB: open the attached file [EPUB_FILE] from the Files app or the share sheet and choose WristReader ("Open in WristReader"), or tap + in the app and pick the file in Files. The book appears in the library and is transferred to the watch (a few seconds).
3. On the watch, open WristReader, choose the book, scroll with the Digital Crown. Menu → Look up a word needs internet (Wiktionary / dictionaryapi.dev).
4. Progress syncs to the demo server when reading; it can be seen from another device on the same account.

No sign-in with the developer is required, there are no purchases, and no user-generated content. The app collects no analytics. Dictionary lookups send only the selected word to Wiktionary / dictionaryapi.dev.
Contact: [CONTACT_EMAIL], [PHONE]
```

Also tick "Sign-in required" only if you want the credentials shown as a demo account; the app itself does not require sign-in.
