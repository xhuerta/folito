# App Store metadata: English (U.S.)

Paste into App Store Connect → your app → version page / App Information. Character limits: name and subtitle 30 (verified in Apple's docs); promotional text 170, description 4000, keywords 100, what's new 4000 (commonly cited limits, confirmed by the App Store Connect form itself when you paste). Checked lengths are in brackets.

## Name (pick one; availability is decided by Apple when you create the app record)

1. `WristReader` (11) – working title, matches the bundle/project name
2. `WristReader: EPUB Reader` (24)
3. `Wrist EPUB Reader` (17)

Do not put "KOReader", "Readest", "Kindle", "Apple" or other third-party marks in the name (see REVIEW_RISKS.md, 5.2).

## Subtitle (≤ 30)

`EPUB reader for Apple Watch` (27)

## Promotional text (≤ 170)

`Read your own EPUB books on your wrist. No account needed. Optional: keep your place in sync with KOReader Sync-compatible apps.` (128)

## Description

```
WristReader is an EPUB reader for Apple Watch. Bring your own books: import them on your iPhone and read them on your wrist. No account is needed.

READ ON YOUR WRIST
• Import DRM-free .epub files from Files, the share sheet or the in-app import button; they are sent to your watch automatically.
• Read offline. Scroll with the Digital Crown, jump between chapters, and keep a library of your books.
• Adjust typeface, size, line spacing, margins, alignment, weight and theme (dark, dim, sepia, high contrast), from the watch or the iPhone, with live preview.
• Look up a word: move through the paragraph with the Digital Crown and see its definition (requires a network connection; definitions are in English and come from Wiktionary and dictionaryapi.dev).

ACCESSIBLE
• VoiceOver on iPhone and Apple Watch, with headings you can jump between in a book.
• Larger text sizes (Dynamic Type); on the watch, book text can follow your system text size.
• Reading themes meet WCAG contrast ratios and adapt to Increase Contrast and Bold Text.

OPTIONAL: SYNC YOUR PLACE
• If you want, sync reading progress with a KOReader Sync (kosync) server, the protocol used by KOReader and Readest, to continue on another device. Sync is off by default; you bring your own server and an existing account on it. The app does not provide a server or create accounts, and you can turn sync off and remove your login at any time.
• Progress is matched per paragraph. For devices to match, they need the same, unmodified EPUB file.
• The watch syncs on its own once it has your books and settings.

PRIVATE BY DESIGN
• No ads, no analytics, no tracking, no account with us.
• Your books stay on your devices. If you turn sync on, your login is kept in the Keychain and sent only to the server you choose.

GOOD TO KNOW
• Open the iPhone app at least once so the watch can be set up.
• DRM-protected books are not supported.
• KOReader and Readest are independent projects; WristReader is not affiliated with them.
```

## Keywords (≤ 100, comma-separated, no spaces)

`ebook,book,books,wrist,offline,dictionary,ereader,reading,library,smartwatch,voiceover,sync,kosync` (98)

(Words already in the name/subtitle, such as "EPUB", "reader" and "Apple Watch", are indexed automatically; do not repeat them. Do not add competitor or third-party trademarks.)

## What's New (version 1.0)

```
First release: read your own EPUB books on Apple Watch without an account, with adjustable typography, word lookup, VoiceOver and Dynamic Type support, and optional reading-progress sync with KOReader Sync servers.
```

## Other fields

| Field | Value |
|---|---|
| Primary category | Books |
| Secondary category (optional) | Productivity or Reference (owner choice) |
| Support URL | `https://xhuerta.github.io/wristreader-site/support.html` (live once the site repo is published, see `docs/RELEASE.md`; fill `xlahuerta@protonmail.com` first) |
| Marketing URL | `https://xhuerta.github.io/wristreader-site/` (optional field) |
| Privacy Policy URL | `https://xhuerta.github.io/wristreader-site/privacy.html` (must equal the in-app link, `AppLinks.privacyPolicy`) |
| Copyright | `© 2026 Xabier Lahuerta` |
| Price | owner decision |
