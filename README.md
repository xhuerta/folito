<p align="center">
  <img src="docs/readme/icon.svg" width="128" height="128" alt="Folito app icon">
</p>

<h1 align="center">Folito</h1>

<p align="center">
  An EPUB reader for Apple Watch. Bring your own books; no account needed.
</p>

<p align="center">
  <a href="https://folito.app/"><b>Website</b></a>
  &nbsp;·&nbsp;
  <a href="https://folito.app/privacy.html"><b>Privacy</b></a>
  &nbsp;·&nbsp;
  <a href="https://folito.app/support.html"><b>Support</b></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/readme/chips-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/readme/chips-light.svg">
    <img src="docs/readme/chips-light.svg" width="582" height="30" alt="Reads offline on the watch · Optional KOReader Sync · VoiceOver &amp; Dynamic Type">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/xhuerta/folito/actions/workflows/linux.yml"><img src="https://github.com/xhuerta/folito/actions/workflows/linux.yml/badge.svg" alt="Linux CI status"></a>
  <a href="https://github.com/xhuerta/folito/actions/workflows/macos.yml"><img src="https://github.com/xhuerta/folito/actions/workflows/macos.yml/badge.svg" alt="macOS CI status"></a>
</p>

## What it does

A full reading app, designed for the smallest screen you own.

<table>
  <tr>
    <td width="33%" valign="top">
      <img src="docs/readme/books.svg" width="44" height="44" alt=""><br>
      <b>Your books, on your wrist</b><br>
      Import <code>.epub</code> books on your iPhone (Files, share sheet or the import button); they are sent to your watch, where you read them, offline.
    </td>
    <td width="33%" valign="top">
      <img src="docs/readme/typography.svg" width="44" height="44" alt=""><br>
      <b>Typography your way</b><br>
      Adjustable typography (typeface, size, spacing, themes) from the watch or the iPhone.
    </td>
    <td width="33%" valign="top">
      <img src="docs/readme/lookup.svg" width="44" height="44" alt=""><br>
      <b>Look up any word</b><br>
      Word lookup on the watch using online dictionaries (Wiktionary, and dictionaryapi.dev for English).
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <img src="docs/readme/sync.svg" width="44" height="44" alt=""><br>
      <b>Optional progress sync</b><br>
      Continue in apps that speak the KOReader Sync protocol, such as KOReader and Readest. Off unless you connect a server you choose; the app does not provide one.
    </td>
    <td width="33%" valign="top">
      <img src="docs/readme/accessibility.svg" width="44" height="44" alt=""><br>
      <b>Built for everyone</b><br>
      VoiceOver, larger text sizes and Dark Mode are supported.
    </td>
    <td width="33%" valign="top">
      <img src="docs/readme/privacy.svg" width="44" height="44" alt=""><br>
      <b>Private by design</b><br>
      No DRM-protected books. No accounts with the developer, no ads, no analytics.
    </td>
  </tr>
</table>

Folito works **without an account and offline** with your own EPUB files. Reading progress can optionally be synced with any server that speaks the **KOReader Sync** protocol (KOReader's, Readest's, or your own). It installs on your watch with a free Apple account (Personal Team): no paid developer program and no special capabilities (no iCloud, App Groups or push notifications).

## Contents

- [Using it without an account](#using-it-without-an-account)
- [Architecture](#architecture)
- [Building](#building) · [Signing](#signing-with-a-free-personal-team) · [Installing](#installing-on-iphone-and-apple-watch)
- [Progress sync (optional)](#progress-sync-optional)
- [Typography](#typography) · [Dictionary](#dictionary-word-lookup) · [Importing EPUBs](#importing-epubs) · [Languages](#languages)
- [Releasing to TestFlight / App Store](#releasing-to-testflight--app-store-without-a-mac)
- [Limitations](#limitations) · [Development](#development) · [Documentation](#documentation)
- [License](#license) · [Third-party components](#third-party-components)

## Using it without an account

Sync is **optional**; you don't need any account (Readest, KOReader or otherwise) to read.

1. Import your EPUBs in the iPhone app (the **+** button, or "Open in Folito" from Files or the share sheet). They are sent to the watch automatically.
2. Read on the watch. Your position is stored on the watch itself and everything works offline.
3. With no username and password saved, the app makes no sync requests and shows no sync prompts or indicators. The only feature that uses the network at your request is dictionary lookup.
4. If you later want to sync, go to *Settings › Progress Sync* on the iPhone (see [below](#progress-sync-optional)). You can turn it off at any time with *Turn Off Sync and Remove Login*, which deletes the credentials from the iPhone and the watch and clears pending progress (also available in the watch's Settings → *Remove credentials*).

## Architecture

```
Packages/ReaderCore   SwiftPM package (pure logic, also tested on Linux):
                      EPUB parsing, XPointer, KOReader Sync client, document hash.
iOSApp/               iPhone app (SwiftUI): imports EPUBs and sends them to the watch.
WatchApp/             watchOS app (SwiftUI): reader and sync.
Config/               Build settings (xcconfig).
project.yml           XcodeGen spec (the .xcodeproj is not checked in).
```

- The watch app is a single-target watchOS app (`WKApplication = true`) paired with the iPhone app via `WKCompanionAppBundleIdentifier`. The iPhone app embeds the watch app.
- Both apps depend on `ReaderCore`.
- Optional sync talks directly to a KOReader Sync–compatible server that you configure (the suggested default URL is `https://sync.koreader.rocks`, but it is not used until you save a username and password).

## Building

Requirements: macOS with Xcode 15 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # edit it (see below)
xcodegen generate
open Folito.xcodeproj
```

### Signing with a free Personal Team

1. In Xcode: Settings → Accounts → add your Apple ID. Note your **Team ID** (10 characters).
2. Edit `Config/Local.xcconfig` (ignored by git):
   ```
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   WR_BUNDLE_ID = com.yourname.folito
   ```
   The identifier must be **globally unique**; the watch app's will be `WR_BUNDLE_ID.watchkitapp`. You can also pass `DEVELOPMENT_TEAM=...` to `xcodebuild`.
3. Run `xcodegen generate` again if you changed anything.

With automatic signing, Xcode creates the provisioning profiles. No entitlements that require a paid account are used.

### Installing on iPhone and Apple Watch

1. Enable **Developer Mode** on the iPhone (Settings → Privacy & Security → Developer Mode) and on the Apple Watch (Settings → Privacy & Security → Developer Mode, or from the Watch app on the iPhone). Both restart.
2. Connect the iPhone by cable and trust the computer. The watch must be paired and unlocked.
3. In Xcode select the `Folito` scheme and your iPhone as the destination, then Run. This also installs the watch app.
4. If it doesn't appear on the watch, open the Watch app on the iPhone → Folito → "Install". Alternatively, choose the `FolitoWatch` scheme and your watch as the destination.
5. On the iPhone: Settings → General → VPN & Device Management → trust your developer certificate.

> [!NOTE]
> **7-day limit:** with a Personal Team, the signature expires after 7 days. Reinstall from Xcode (Run) to renew it; data is kept if you reinstall without deleting the app. There is also a limit of 3 active apps and of new identifiers per week.

## Progress sync (optional)

Only needed if you want to continue the same book in other readers. Folito uses the same server and matching method as your other readers so progress is shared.

| Reader | Where | Document matching method |
| --- | --- | --- |
| **Readest** | Settings → Integrations → **KOReader Sync**: same server as in Folito (default `https://sync.koreader.rocks`), plus that server's username and password | **File Content** (hash of the file content) |
| **KOReader** | Tools → **Progress sync** → set the custom server and account | **Binary** (hash of the binary file) |

Both methods compute the same partial MD5 hash of the file content, so the same EPUB is recognized on every device. It must be the **same file** (not repackaged).

**Server.** Use the public `https://sync.koreader.rocks` or host your own with [koreader-sync-server](https://github.com/koreader/koreader-sync-server). Enter the same URL in every app.

### HTTP servers (ATS)

**https** is used by default. iOS and watchOS block `http://` via App Transport Security (ATS), so Folito declares only `NSAllowsLocalNetworking` in both `Info.plist` files (via `project.yml`): it allows `http://` to the **local network** (IP addresses, `.local` names and dotless names such as `http://nas:5200`) without disabling ATS for anything else.

- LAN server over http: works as is. The iPhone app shows an orange warning when it sees `http://` (traffic is not encrypted; use it only on a trusted network).
- Public domain name over **http**: iOS blocks it. A reverse proxy with https is recommended. If you still need it, add an exception for that domain only in `project.yml` (in both targets, `Folito` and `FolitoWatch`) and run `xcodegen generate`:

```yaml
NSAppTransportSecurity:
  NSAllowsLocalNetworking: true
  NSExceptionDomains:
    sync.example.org:
      NSExceptionAllowsInsecureHTTPLoads: true
```

`NSAllowsArbitraryLoads` is not used.

## Typography

On the watch (reader menu, list icon → *Typography*, or Settings) and in the iPhone app (*Reading* tab, with live preview) you can change: typeface (SF, serif/New York, rounded, monospaced), size, line spacing, margins, paragraph spacing, alignment (left/centered), bold, heading scale, letter spacing and theme (dark, dim, sepia, high contrast), plus several presets and "Reset to defaults". On the watch, *Match System Text Size* makes the book's text size follow the system text size.

- Changes made on the iPhone are sent to the watch over the settings channel (`updateApplicationContext`) and changes made on the watch are published to the iPhone. The **latest change** wins (by timestamp). See [docs/WATCH_CONNECTIVITY.md](docs/WATCH_CONNECTIVITY.md).
- When a setting changes, the reader keeps the current block as the anchor; fonts are computed once per change and styled text is cached per block, so the `LazyVStack` is not rebuilt entirely.
- Font size: the old setting is migrated automatically.
- SwiftUI limitations on watchOS: no justified text or automatic hyphenation (left/centered alignment and letter spacing are offered instead). No custom fonts are bundled: they would increase the app size and their licenses would need review; only system fonts are used.

## Dictionary (word lookup)

watchOS doesn't allow selecting text in `Text` or showing the system dictionary, so there is a "lookup mode": tap a paragraph (or reader menu → *Look up a word*), turn the **Digital Crown** to move the cursor between words (there are also ‹ › buttons) and press *Look up*. It shows part of speech, definitions and an example, with scrolling.

- **Requires a network connection** (the watch's Wi-Fi/LTE or through the iPhone). Words already looked up are kept in an on-disk LRU cache (max 200 entries / ~600 KB) and work offline.
- Source: the Wiktionary REST API (English edition, `en.wiktionary.org/api/rest_v1/page/definition/{word}`), which covers words from all languages; the book's language (`dc:language`) is used. Definitions are **in English** even for books in other languages, because other Wiktionary editions don't offer this endpoint (they return HTTP 501). For English there is a fallback to `api.dictionaryapi.dev`.
- If the exact form doesn't exist, lowercase and simple reductions (plurals, -ed, -ing) are retried.
- Clear errors: offline, not found, service busy (rate limited).
- Wiktionary content is licensed under CC BY-SA.
- Watch settings: *Tap paragraph to look up* and *Clear dictionary cache*.

## Importing EPUBs

- From the iPhone: open an `.epub` with "Open in Folito" (share sheet in Files, Safari, etc.) or use the import button in the app. The app transfers them to the watch.
- If the watch app wasn't installed yet, nothing is lost: sync settings and pending books are resent automatically when the session activates, the watch app is installed, connectivity changes or you open the iPhone app. The watch reports which books it has, so missing ones are resent.
- The app exposes its Documents folder in the Files app (`UIFileSharingEnabled`).

## Languages

The iPhone and watch apps are localized in English (base), Spanish, French, German, Italian, Portuguese (Brazil), Japanese and Simplified Chinese, using Xcode String Catalogs (`Localizable.xcstrings` and `InfoPlist.xcstrings` in `iOSApp/Resources` and `WatchApp/Resources`). `python3 scripts/check_strings.py` (also run in Linux CI) checks that no translation is missing; how to add strings or languages: [docs/LOCALIZATION.md](docs/LOCALIZATION.md).

## Releasing to TestFlight / App Store without a Mac

The whole process (build, sign with cloud signing and upload to TestFlight) runs in GitHub Actions on a macOS runner, with a paid Apple Developer Program membership and an App Store Connect API key (Admin role). Step-by-step guide: [docs/RELEASE.md](docs/RELEASE.md).

- Workflow: `.github/workflows/release.yml` (*Actions → Release → Run workflow*). With `dry_run = true` (the default) it needs no secrets: it generates the project with XcodeGen, makes an unsigned Release archive and shows what would be uploaded. With `dry_run = false` (or when pushing a `v1.0.0` tag) it signs and uploads the build.
- Secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the .p8 in plain text or base64), `APPLE_TEAM_ID`. Variables: `BUNDLE_ID_BASE` (your identifier; the watch app uses `.watchkitapp`) and, optionally, `APP_NAME`.
- App Store Connect metadata (English and Spanish), privacy answers, reviewer notes and rejection risks: [docs/appstore/](docs/appstore/). Privacy policy and support page (the project website, in the app's 8 languages): [docs/site/](docs/site/), generated from [docs/site-src/](docs/site-src/) by `python3 scripts/site/build.py`.

## Limitations

- Position granularity is the **start of the paragraph** (XPointer): syncing with KOReader/Readest lands on the paragraph, not the exact word or line.
- If the remote XPointer can't be resolved (for example, the book reflows differently), the progress **percentage** is used instead.
- The app doesn't use iCloud or App Groups because of the free-account restriction.
- DRM-protected EPUBs are not supported.

## Development

Test the core (works on macOS and Linux):

```sh
cd Packages/ReaderCore
swift test
```

CI on GitHub Actions:

| Workflow | What it runs |
| --- | --- |
| [`linux.yml`](.github/workflows/linux.yml) | `ReaderCore` tests in `swift:6.0` |
| [`macos.yml`](.github/workflows/macos.yml) | iOS and watchOS apps built (XcodeGen, unsigned) and their unit tests run on simulators, as two parallel jobs; skipped for docs-only changes and draft PRs; `.xcresult` bundles are uploaded as artifacts. `ReaderCore` tests run on Linux |
| [`accessibility.yml`](.github/workflows/accessibility.yml) | Accessibility audit with UI tests (slow): on every push to `main`, manually from Actions, or on PRs labeled `accessibility`; does not block PRs |

What runs where: [docs/TESTING.md](docs/TESTING.md). Future plans: [ROADMAP.md](ROADMAP.md).

## Documentation

| Document | Contents |
| --- | --- |
| [RELEASE.md](docs/RELEASE.md) | TestFlight / App Store release pipeline |
| [TESTING.md](docs/TESTING.md) | Test suites and where they run |
| [ACCESSIBILITY.md](docs/ACCESSIBILITY.md) | Accessibility support and audit |
| [LOCALIZATION.md](docs/LOCALIZATION.md) | Adding strings and languages |
| [WATCH_CONNECTIVITY.md](docs/WATCH_CONNECTIVITY.md) | iPhone ↔ watch transfer and settings sync |
| [DISCREPANCIES.md](docs/DISCREPANCIES.md) | Compatibility notes vs. KOReader/Readest: document hash, XPointer, KOSync |
| [PRIVACY_DATA_MAP.md](docs/PRIVACY_DATA_MAP.md) | What data is stored and sent, and where |
| [EXPORT_COMPLIANCE.md](docs/EXPORT_COMPLIANCE.md) | Export compliance (encryption) |
| [ROADMAP.md](ROADMAP.md) | Future plans |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute, CLA |

## License

Folito is **source-available**, not open source in the OSI sense. It is licensed under the [Functional Source License 1.1, ALv2 Future License](LICENSE.md) (SPDX: `FSL-1.1-ALv2`), © 2026 Xabier Lahuerta.

- **You can** read the code, modify it, build the app for yourself, use it for non-commercial education or research, and [contribute](CONTRIBUTING.md).
- **You can't** ship a competing product: a commercial app or service that substitutes for Folito or offers substantially the same functionality.
- **Each release becomes Apache-2.0** two years after it is published.
- The Folito name and icon are not covered by the license; forks need their own. See [TRADEMARKS.md](TRADEMARKS.md).

Contributions require signing the [CLA](CLA.md) (a one-line comment on your first pull request). [LICENSE.md](LICENSE.md) is the authoritative text.

## Third-party components

The apps link these packages, fetched by Swift Package Manager (not vendored in this repository). Their licenses are unaffected by Folito's license; their full license and NOTICE texts ship inside the iPhone app (*Settings › About › Acknowledgements*, from [`iOSApp/Resources/Acknowledgements`](iOSApp/Resources/Acknowledgements)).

| Component | License |
| --- | --- |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | MIT |
| [Swift Crypto](https://github.com/apple/swift-crypto) | Apache-2.0 |
| [SwiftASN1](https://github.com/apple/swift-asn1) | Apache-2.0 |

---

<sub>Folito is an independent app. KOReader and Readest are names of third-party projects, used only to describe compatibility; Folito is not affiliated with or endorsed by them. Apple, Apple Watch and iPhone are trademarks of Apple Inc.</sub>
