# Releasing Folito without a Mac

## Owner TODO (every remaining placeholder and decision)

Placeholders still in the repository (search for the bracketed text):

* [x] `[CONTACT_EMAIL]`: `docs/site/{privacy,support}.html`, `docs/site/es/{privacy,support}.html`, `docs/appstore/REVIEW_NOTES.md`, `docs/appstore/metadata-en.md` (Support URL note). Filled: xlahuerta@protonmail.com.
* [x] `[DEVELOPER_NAME]`: `docs/site/privacy.html`, `docs/site/es/privacy.html` (responsible party), `docs/appstore/metadata-en.md` (copyright). Filled: Xabier Lahuerta.
* [x] `[DATE]`: "Last updated" in `docs/site/privacy.html` and `docs/site/es/privacy.html` set to 28 October 2026; update it whenever the policy changes.
* [x] In-app links: `iOSApp/Support/AppLinks.swift` (PR #20) points to the GitHub Pages site (Spanish pages for Spanish speakers).
* [ ] GitHub: `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` secrets and the `BUNDLE_ID_BASE` variable (step 5; optional, the default is `com.xlahuerta.folito` from `Config/Base.xcconfig`).

Decisions and checks only the owner can make (details in [What only the owner can decide](#what-only-the-owner-can-decide)):

* [ ] Final app name, bundle id, SKU, price and territories.
* [ ] Sample EPUB for App Review: attach one or keep the Project Gutenberg link in `docs/appstore/REVIEW_NOTES.md` (no demo account is needed).
* [ ] App Privacy answers (`docs/appstore/APP_PRIVACY.md`), including whether to also declare the optional sync data.
* [ ] Accessibility Nutrition Labels (`docs/appstore/ACCESSIBILITY_LABELS.md`), only after the manual checks in `docs/ACCESSIBILITY.md`.
* [ ] Age rating (`docs/appstore/AGE_RATING.md`) and export compliance (`docs/appstore/EXPORT_COMPLIANCE.md`).
* [ ] Publish the site ([Publishing the site](#9-publishing-the-site)).

This guide takes you from "nothing" to a build on your iPhone and Apple Watch through TestFlight, and then to App Store review, using only a browser and GitHub. All building, signing and uploading happens on a GitHub-hosted macOS runner (`.github/workflows/release.yml`).

Contents: [1 Enrol](#1-enrol-in-the-apple-developer-program) · [2 Bundle ids](#2-register-the-two-bundle-ids) · [3 App record](#3-create-the-app-record-in-app-store-connect) · [4 API key](#4-create-an-app-store-connect-api-key) · [5 GitHub config](#5-configure-github) · [6 Run](#6-run-the-workflow) · [7 TestFlight](#7-install-with-testflight) · [8 App Store](#8-submit-for-app-store-review) · [9 Site](#9-publishing-the-site) · [Owner decisions](#what-only-the-owner-can-decide) · [Design notes](#why-xcodebuild-cloud-signing-and-not-fastlane) · [Sources](#sources)

## 1. Enrol in the Apple Developer Program

TestFlight and the App Store need a paid membership (individual or organisation; the free Personal Team cannot upload). Enrol at <https://developer.apple.com/programs/enroll/> from an iPhone (Apple Developer app) or a browser. Apple lists the current fee on that page (US$99 per year at time of writing). Approval can take from minutes to a few days. Then sign in at <https://appstoreconnect.apple.com> and accept any pending agreements (**Business**); an app record cannot be created until the Account Holder has signed the latest agreement.

Note your **Team ID** (10 characters): developer.apple.com → Account → Membership details. It becomes the `APPLE_TEAM_ID` secret.

## 2. Register the two bundle ids

At <https://developer.apple.com/account/resources/identifiers/list> → **+** → *App IDs* → *App*:

| App | Bundle id | Example |
|---|---|---|
| iPhone app | your base id | `com.yourname.folito` |
| Watch app | base id + `.watchkitapp` | `com.yourname.folito.watchkitapp` |

Use an *Explicit* id. No capabilities are needed (the app uses no iCloud, App Groups or push). The base id is what you will store in the `BUNDLE_ID_BASE` variable; the watch id is derived by `project.yml` and must be exactly `<base>.watchkitapp`. Registering them up front avoids relying on automatic creation during the first CI run.

## 3. Create the app record in App Store Connect

App Store Connect → **Apps** → **+** → **New App** (role: Account Holder, Admin or App Manager). Choose platform **iOS** (a watch app shipped inside the iPhone app belongs to the iOS record), the name, primary language, the iPhone bundle id from step 2 and a SKU (any unique string). The name must be unique on the App Store; if it is taken, pick another from `docs/appstore/` candidates. The app record must exist before the first upload.

## 4. Create an App Store Connect API key

App Store Connect → **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys** → **Generate API Key**. Only the Account Holder or an Admin can create team keys.

* **Access role: Admin.** Xcode's cloud signing (creating/using Apple-managed distribution certificates from the command line) works by default only for Admin/Account Holder; Apple's WWDC21 session "Distribute apps in Xcode with cloud signing" says that Developer-role users need the extra "Access to Cloud Managed Distribution Certificate" permission, and that permission cannot be set on an API key. Community reports confirm that App Manager keys fail with a cloud-signing permission error. Revoke the key if it ever leaks.
* Download the `AuthKey_XXXXXXXXXX.p8` **immediately**: Apple lets you download it once.
* Note the **Key ID** and the **Issuer ID** shown on that page.

## 5. Configure GitHub

Repository → Settings → Secrets and variables → Actions.

**Secrets**

| Name | Value |
|---|---|
| `ASC_KEY_ID` | Key ID from step 4 |
| `ASC_ISSUER_ID` | Issuer ID (a UUID) from step 4 |
| `ASC_KEY_P8` | The `.p8` file contents, **either** pasted as-is (including the `-----BEGIN PRIVATE KEY-----` lines) **or** base64-encoded (`base64 -w0 AuthKey_XXXX.p8` on Linux, `base64 -i AuthKey_XXXX.p8` on macOS). The workflow detects which. |
| `APPLE_TEAM_ID` | Team ID from step 1 |

**Variables** (not secret)

| Name | Value |
|---|---|
| `BUNDLE_ID_BASE` | Your base bundle id (step 2). Overrides `WR_BUNDLE_ID`. Must not be `com.example.*` and must not end in `.watchkitapp`. |
| `APP_NAME` | Optional. Home-screen display name (`CFBundleDisplayName`) for both apps, e.g. the final App Store name. Leave empty to keep `Folito`. |

The key is written to a temporary `600` file, passed to `xcodebuild` by path, masked in logs, and deleted in an `always()` step. Secrets are only exposed to the steps that need them.

## 6. Run the workflow

Actions → **Release** → *Run workflow*.

1. **Dry run first** (`dry_run = true`, the default). Needs no secrets. It runs XcodeGen and an *unsigned* Release archive and prints (job summary) the bundle ids, versions and `ExportOptions.plist` it would use, and checks that the watch app is embedded, ids match and versions agree. The same dry run runs automatically on pull requests that touch the pipeline.
2. **Real run**: `dry_run = false` (optionally set `marketing_version`, e.g. `1.0.0`). Or push a tag: `git tag v1.0.0 && git push origin v1.0.0` (tag `v1.0.0` becomes version `1.0.0`; tags with suffixes such as `-rc1` are rejected because the App Store requires numeric versions). If a required secret or variable is missing, the job fails in its first step and lists exactly which ones.
   * Build number = `github.run_number` (monotonic). A re-run of the same run keeps the same number, which App Store Connect rejects as a duplicate: start a new run instead.
   * `lane`: `testflight` and `appstore-metadata-none` perform the identical upload; the pipeline never touches store metadata or submits for review (you do that by hand, step 8). The second name exists to make that intent explicit in the logs.
3. Wait for the upload, then for App Store Connect processing (usually minutes; you get an email). The archive is attached to the run as an artifact (14 days). With `destination = upload` Xcode uploads directly, so no standalone `.ipa` is produced.

Apple requires uploads to be built with the current major Xcode/SDK (since 28 April 2026: Xcode 26 / iOS 26 and watchOS 26 SDKs); the workflow selects the newest stable Xcode on the runner.

## 7. Install with TestFlight

* **Internal testing** (up to 100 App Store Connect users, no review): App Store Connect → your app → **TestFlight** → *Internal Testing* → create a group, add yourself, assign the build. Install **TestFlight** from the App Store on your iPhone, sign in with the same Apple ID and install Folito.
* **The watch app** installs through the iPhone: open the **Watch** app on the iPhone → scroll to Folito → *Install* (or enable *Automatic App Install*). TestFlight itself shows the watch app as part of the iPhone app; the watch needs to be paired, unlocked and on the same iPhone.
* **External testing** (up to 10,000 people via email or a public link): the first build of a version goes through *Beta App Review* (Apple checks it against the App Review Guidelines) and needs test information including contact details; reuse `docs/appstore/REVIEW_NOTES.md` (no sign-in or demo account needed). Builds expire after 90 days.

## 8. Submit for App Store review

1. Pages must be live (step 9) so you can fill in the **Privacy Policy URL** and **Support URL**.
2. App Store Connect → your app → the version page. Paste metadata from `docs/appstore/metadata-en.md` and `metadata-es.md`. Upload screenshots (checklist in `docs/appstore/SCREENSHOTS.md`).
3. **App Privacy**, **Accessibility**, **Age Rating**, **Export compliance** and **App Review information** answers: `docs/appstore/APP_PRIVACY.md`, `ACCESSIBILITY_LABELS.md`, `AGE_RATING.md`, `EXPORT_COMPLIANCE.md`, `REVIEW_NOTES.md`. Read `docs/appstore/REVIEW_RISKS.md` first. In *App Review Information* leave **Sign-in required** unticked: the app needs no account; sync is optional and uses a server the user supplies.
   URLs: Support `https://folito.app/support.html`, Privacy Policy `https://folito.app/privacy.html`, Marketing (optional) `https://folito.app/` (Spanish localisation: same paths under `es/`).
4. Select the processed build, set pricing/availability, choose release method, **Add for Review** → **Submit**.

## 9. Publishing the site

The support, privacy policy and landing pages are static HTML in `docs/site/` (English at the root; Spanish, French, German, Italian, Brazilian Portuguese, Japanese and Simplified Chinese under `es/`, `fr/`, `de/`, `it/`, `pt-br/`, `ja/` and `zh-hans/`; no trackers, and the few inline scripts are optional enhancements). The pages are **generated**: edit the templates in `docs/site-src/templates/` and the strings in `docs/site-src/i18n/<lang>.json`, run `python3 scripts/site/build.py`, and commit `docs/site/` (CI fails if it is stale or a strings file is missing keys). To add a language, add `docs/site-src/i18n/<code>.json` and the code to `LANGUAGES` in `scripts/site/build.py`, then extend `AppLinks.siteFolder`. They are served from a separate **public** repository, `xhuerta/folito-site`, so this repository can stay private.

1. Fill the placeholders (`[CONTACT_EMAIL]`, `[DEVELOPER_NAME]`, `[DATE]`; see Owner TODO) in `docs/site-src/i18n/` and rebuild.
2. Copy the **contents** of `docs/site/` to the **root** of `xhuerta/folito-site` (so `index.html`, `privacy.html`, `support.html`, `style.css`, `CNAME` and the language folders sit at the top level) and push to `main`. Re-copy whenever `docs/site/` changes; this repository is the source. Keep `CNAME` (it holds the custom domain `folito.app`; the build writes `docs/site/CNAME` so a sync never deletes it), `.nojekyll` and the site repo's own `README.md`.
3. In `xhuerta/folito-site`: Settings → **Pages** → *Build and deployment* → Source **Deploy from a branch** → branch **`main`**, folder **`/ (root)`** → Save. Custom domain: `folito.app` (DNS at the registrar points the apex and `www` at GitHub Pages), with **Enforce HTTPS** on.
4. After a minute the pages are live:
   * Marketing / home: `https://folito.app/`
   * Privacy policy: `https://folito.app/privacy.html` (translations: `…/es/privacy.html`, `…/fr/privacy.html`, …)
   * Support: `https://folito.app/support.html` (translations: `…/es/support.html`, `…/fr/support.html`, …)
5. Use the same privacy and support URLs in App Store Connect and in the app (`AppLinks.swift`, PR #20). Guideline 5.1.1(i) requires the policy to be reachable inside the app too; Settings › About links to it once `AppLinks` is updated.
6. Re-read the policy against `docs/PRIVACY_DATA_MAP.md` whenever networking code changes.

## What only the owner can decide

* Final **app name** and whether it is available (the name must be unique in the App Store; 30 characters max). "Folito" is a working title; see candidates in `docs/appstore/metadata-*.md`.
* **Bundle id** (permanent once the app is created) and the SKU.
* **Contact e-mail and developer name** (`[CONTACT_EMAIL]`, `[DEVELOPER_NAME]`). The site URLs are fixed at `https://folito.app/`.
* **Price and availability** (free vs paid, territories), and the seller/developer name shown (individual name vs organisation).
* **No demo account is needed**: sync is optional (PR #18) and reviewers test by importing an EPUB. Decide only which public-domain EPUB to attach or link for review, and whether to bundle a sample book in a future version.
* "Create account" was removed (PR #18), so guideline 5.1.1(v) account deletion does not apply; do not reintroduce it.
* Age-rating, App Privacy and Accessibility Nutrition Label answers (proposed in `docs/appstore/`; you are the one making the declaration).
* Whether to mention KOReader/Readest by name in store text (nominative use only; see risks).
* Which Apple ID / role holds the API key, and when to rotate it.

## Why `xcodebuild` cloud signing and not fastlane

Chosen: plain `xcodebuild archive` + `xcodebuild -exportArchive` with `-allowProvisioningUpdates` and the App Store Connect API key flags, and `ExportOptions.plist` with `method = app-store-connect`, `destination = upload`.

* **Fewer moving parts.** The project already builds with `xcodebuild` in CI; no Ruby/Bundler/gem pinning, no `Fastfile`, no extra dependency to maintain.
* **No certificates or profiles to manage.** Cloud signing keeps the distribution certificate and key at Apple. fastlane's `cert`/`sigh` (or `match`) would create certificates and private keys that must live somewhere (a private git repo or the runner), and are subject to Apple's certificate limits and revocation hazards on ephemeral runners.
* **Single credential.** One API key does signing and upload; fastlane `pilot` would need the same key anyway.
* **Trade-offs**, honestly: it requires an Admin-role API key, error messages are terse, and automatic signing can create "Apple Development" certificates during `archive`. fastlane would add retry handling, changelog and metadata upload (`deliver`) and TestFlight group management; if you later want those, add them in a separate lane without replacing this one. `xcodebuild` flags are documented in Apple's `man xcodebuild`; the export option keys come from `xcodebuild -help` (see sources) and could not be verified on a Mac here, so **the first real run is the real test**; keep `dry_run` for everything before that.

## Sources

* `xcodebuild` man page (flags `-allowProvisioningUpdates`, `-authenticationKeyPath`, `-authenticationKeyID`, `-authenticationKeyIssuerID`, `-exportArchive`, `-exportOptionsPlist`): <https://keith.github.io/xcode-man-pages/xcodebuild.1.html> (mirror of Apple's man page; run `man xcodebuild` on a Mac).
* Distribute apps in Xcode with cloud signing (WWDC21, command-line flow, Admin/Account Holder role, "Access to Cloud Managed Distribution Certificate"): <https://developer.apple.com/videos/play/wwdc2021/10204/>
* Export option keys come from `xcodebuild -help`. Forum threads confirming `app-store-connect` replaces the deprecated `app-store`: <https://developer.apple.com/forums/thread/773749>; `manageAppVersionAndBuildNumber` (default YES): <https://developer.apple.com/forums/thread/693862>.
* App Store Connect API keys (who can create team keys; one-time download): <https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api>
* Create an app record: <https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app>
* TestFlight overview (internal 100 / external 10,000 testers, beta review, 90 days): <https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview>
* Upcoming requirements (Xcode 26 SDK since 28 April 2026): <https://developer.apple.com/news/upcoming-requirements/>
* Screenshot specifications: <https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications>
* App Review Guidelines: <https://developer.apple.com/app-store/review/guidelines/>
* App privacy details: <https://developer.apple.com/app-store/app-privacy-details/>
* Age ratings: <https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions>
* Encryption export compliance: <https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations>
