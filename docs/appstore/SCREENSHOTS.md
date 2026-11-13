# App Store screenshots

Source of the sizes: Apple, [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) (App Store Connect Help, read 2026-11-11; re-check before uploading, Apple adds sizes with each device generation). The same list is in `scripts/ci/check_screenshot_sizes.py` (`ACCEPTED`): change both together.

General: 1 to 10 screenshots per device size and localization; `.jpeg`, `.jpg` or `.png`; **no alpha/transparency**; use the same Apple Watch size in every localization. If you supply only the largest required size, App Store Connect scales it down for smaller devices.

## Where the screenshots come from

CI takes them: nobody needs a Mac or a device. The UI tier of `macos.yml` (every push to `main`, and pull requests labelled `ui`; see [TESTING.md](../TESTING.md)) runs two screenshot suites on simulators whose screens are accepted sizes: the iPhone sets in a job of their own, `app-store-iphone`, one runner per size (`app-store-iphone-medium`, `app-store-iphone-large`, in parallel with the `ios` job, which they would otherwise push past its time limit), the watch set at the end of the `watch` job. The job `app-store-screenshots` merges them into one artifact, **`app-store-screenshots`**, with the English set in `en/` (every language: see [Localized sets](#localized-sets)):

| Directory | Display class | Simulator (first one the runner has) | Pixels | Suite |
|---|---|---|---|---|
| `<lang>/iphone-medium/` | iPhone with Dynamic Island, medium display (**required**) | iPhone 17 Pro, 17, 16 Pro; else 16, 15 Pro, 15, 14 Pro | 1206 × 2622 (else 1179 × 2556) | `iOSApp/UITests/AppStoreScreenshotTests.swift` |
| `<lang>/iphone-large/` | iPhone with Dynamic Island, large display (given so that the older Face ID large size is not required) | iPhone 17 Pro Max, 16 Pro Max; else 16 Plus, 15 Pro Max, 15 Plus, 14 Pro Max; else iPhone Air | 1320 × 2868 (else 1290 × 2796, 1260 × 2736) | the same suite |
| `<lang>/watch/` | Apple Watch (**required**) | Apple Watch Ultra 3; else Ultra 2, Ultra; else Series 11 / 10 (46mm); else Series 9, 8, 7 (45mm) | 422 × 514 (else 410 × 502, 416 × 496, 396 × 484) | `WatchApp/UITests/WatchAppStoreScreenshotTests.swift` |

The frames are the raw captures of the screenshot spec: the Apple Watch frames are uploaded as they are; the iPhone captures are the screens that the composed iPhone images (brand background, headline, drawn devices; a later step) place inside a drawn phone.

| File | Shows |
|---|---|
| `watch/watch-1-reader.png` | The reader at the opening of chapter 1 of the language's sample book, scrolled just enough for the top bar to hide, then to the next paragraph so no line is cut under the clock band: the system time above the page-coloured clock band, no book title |
| `watch/watch-2-word-lookup.png` | Word lookup: the language's word with its entry in the language's sample dictionary |
| `watch/watch-2a-word-picker.png` | The same word selected in its paragraph (for iPhone frame 3; optional in the watch set) |
| `watch/watch-3-library.png` | The Library: the sample book (27 %, as its iPhone details show) and three public-domain titles of the language, with title covers and progress (43 %, 78 %, 12 %) |
| `watch/watch-4-sepia.png` | The reader in the "Comfortable" preset (serif) with the sepia theme, further on (mid chapter 2; in de, it and ja, which have one chapter of text, a later page of chapter 1), top bar hidden, a paragraph starting right under the clock band |
| `watch/watch-5-menu.png` | The reader menu scrolled to "Go to Synced Position" (an offline stand-in sync service: `-UITestingSimulateSync`), with "Look Up a Word" and the text size above it |
| `complications/complication-rectangular.png`, `complication-circular.png` | The rectangular and circular complications with the language's sample book (its short title, 27 % read, as on the iPhone book-details frame), at 3× (localized workflow only; input of iPhone frame 6, which falls back to `watch-3-library` without them). Not uploaded as they are |
| `iphone-*/iphone-1-library.png` | The Library: the sample book on top, the other three titles, each "On Apple Watch" (iPhone frames 1 and 4) |
| `iphone-*/iphone-2-book-details.png` | The sample book's details, with the reading progress synced from the watch (iPhone frame 2) |
| `iphone-*/iphone-3-reading.png` | The Reading tab with its live preview (the opening line of *Pride and Prejudice*, in every language: `TypographyPreview` in `Shared/TypographyRendering.swift`) (iPhone frame 5) |

The App Store upload order of the watch frames is 1, 2, 3, 4, 5. iPhone frames 3 and 6 have no iPhone screen.

| Language | Sample book (reader) | Word looked up | Rest of the Library | Short title (3.1; the sample book, shown 27 % read like the Library) |
|---|---|---|---|---|
| en | *Pride and Prejudice* | acknowledged | *Emma*; *Alice’s Adventures in Wonderland*; *The Gods of Mars* | *Pride and Prejudice* |
| es | *Don Quijote de la Mancha* | hidalgo | *La Regenta*; *Marianela*; *Lazarillo de Tormes* | *Don Quijote* |
| fr | *Les Misérables* | évêque | *Madame Bovary*; *Le Comte de Monte-Cristo*; *Germinal* | *Les Misérables* |
| de | *Die Verwandlung* | Ungeziefer | *Effi Briest*; *Der Process*; *Faust* | *Die Verwandlung* |
| it | *I promessi sposi* | lago | *Le avventure di Pinocchio*; *I Malavoglia*; *Cuore* | *I promessi sposi* |
| pt-BR | *Dom Casmurro* | trem | *Memórias Póstumas de Brás Cubas*; *O Cortiço*; *Iracema* | *Dom Casmurro* |
| ja | 『吾輩は猫である』 | 猫 | 『坊っちゃん』; 『こころ』; 『羅生門』 | 『吾輩は猫である』 |
| zh-Hans | 《狂人日记》 | 月光 | 《阿Q正传》; 《红楼梦》; 《西游记》 | 《狂人日记》 |

**No truncated titles.** No capture may show a cut title. The reader frames are taken with the top bar hidden (the tests fail unless the bar has hidden and the clock band is there), so they show no book title. On every other captured screen the suites compare each navigation title's text width with its element and fail when the title is cut (an ellipsis, or a watchOS marquee that runs past the screen). A future frame that shows the reader's bar must use the language's short title above; the complication snapshots already do.

How it works:

* `scripts/ci/appstore_simulator.py <class>` picks the simulator, or creates one when the runner has the device type but no such device. It lists only models whose screen is an accepted size (the 42 mm and 41 mm watches are not), and fails when the runner has none: nothing is scaled or padded to reach a size.
* `scripts/ci/appstore_screenshots.sh <class> <suite>` boots it, overrides the status bar (`xcrun simctl status_bar`: 9:41, Wi-Fi, full battery, no carrier name), runs the suite and exports the named attachments. It prints the test progress while the suite runs; an attempt that runs longer than `ATTEMPT_MINUTES` (iPhone 13, watch 7; the suite itself takes 1 to 2 minutes) is treated as a hang: the simulator screen is saved, the simulator rebooted and the suite run once more. A failing test is not retried. After a failure the log, the result bundle (failure screenshot, accessibility tree, screen recording) and any hang screenshot are uploaded as `appstore-diagnostics-<class>`.
* The suites wait for each screen with generous timeouts and fail with the screen they found, a screenshot ("failure screen") and the accessibility tree. On the watch, opening the reader taps the Library row again while the Library is still showing: right after launch a tap can be dropped before the list takes taps.
* **The watch clock is not overridden.** `simctl status_bar` does not support watchOS simulators: with Xcode 26.3 (watchOS 26 runtime) it fails with "Status bar overrides not supported on this platform" (POSIX error 45). The watch captures therefore show the time at which CI ran them (the runner's clock, UTC). The script still tries, and prints a `::notice::` when the override is refused, so a later Xcode that supports it is used without a change. The raw watch frames are left as they are; only the composed iPhone images (below) draw 10:09 over the watch clock.
* `scripts/ci/check_screenshot_sizes.py` then fails the job if a capture is not an accepted size for its class, if a class mixes sizes (so the watch size is the same in every set), if a required class is missing, or if an image has an alpha channel. The job `app-store-screenshots` repeats the check on the merged artifact. The script's own test and the simulator choice run on Linux (`linux.yml`, job `ci-scripts`).
* The content is seeded by launch arguments that exist in Debug builds only (`-UITestingSeedCovers` on the iPhone, `-UITestingSeedAppStore` on the watch) from the language's seed, `AppStoreSeeds/<lang>.json`, which the suites pass to the app in `UITESTING_APPSTORE_SEED`. The seeds are built by `scripts/make_appstore_seeds.py` from the texts of the bundled sample books (`docs/samples-src/<lang>.txt`, the same text as `sample-<lang>.epub`) plus the Library titles and the sample dictionary of each language; `linux.yml` (job `ci-scripts`) fails when a committed seed is stale. The folder is in the UI test bundles only: no book file, cover art or dictionary is added to the shipped apps.
* The suites take the language from `SCREENSHOT_LANG` (`appstore_screenshots.sh` passes `TEST_RUNNER_SCREENSHOT_LANG`; default `en`), launch the app with `-AppleLanguages`/`-AppleLocale`, and find every element by accessibility identifier (or the tab bar item's position), never by an English label.
* Watch Library: every book has a cover drawn in code with its title and author (`UITesting.titleCover`, 72 × 108 px like the thumbnails the iPhone sends), and three of them a stored reading position (43 %, 78 %, 12 %), so the rows show the progress of a library in use. The sample book, the book of the reader screenshot, is at its opening (0 %). The other titles are metadata seeds: only their rows show.
* Watch screens are captured once two consecutive screenshots are identical (nothing scrolling, no covers still loading).
* iPhone Library: the sample book holds the language's sample text; the other titles hold that text repeated (so their sizes look like books'), except in English, where they hold the full public-domain texts of *Emma*, *Alice's Adventures in Wonderland* and *The Gods of Mars* (Project Gutenberg #158, #11, #64, without the Gutenberg header and licence; built by `scripts/make_appstore_books.py`, in the UI test bundle only, `iOSApp/UITests/AppStoreBooks`, passed in `UITESTING_BOOK_TEXTS`). The simulated watch reports the watch Library's progress, and 27 % for the sample book, which its details show as the synced progress.
* iPhone Library: a simulator has no paired Apple Watch, so the Library would open with a "No Apple Watch" card and every book "Waiting for Apple Watch". `-UITestingSimulateWatch` (Debug builds only, `PhoneConnectivity.activate()`) makes the Library show what a user with a paired, reachable watch sees: "Apple Watch connected" and the books on the watch. The real WatchConnectivity session is not activated, so nothing is sent; Release builds have no such code.
* The definitions in the word-lookup capture come from a four-word sample dictionary per language written for the screenshots (in the seed), so its source line reads "Sample dictionary". The real dictionaries are Wiktionary data that each user downloads (see [DICTIONARIES.md](../DICTIONARIES.md)); they are not bundled or downloaded in CI.

### Regenerating

1. Add the `ui` label to a pull request, or push to `main` (or run the *macOS* workflow by hand).
2. When the run is done, download the `app-store-screenshots` artifact from the run's page (the English set, in `en/`).
3. Upload each directory to its display size in App Store Connect.

On a Mac: `xcodegen generate`, then for instance
`TEST_RUNNER_SCREENSHOT_LANG=fr xcodebuild test -project Folito.xcodeproj -scheme FolitoWatch -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' -only-testing:FolitoWatchUITests/WatchAppStoreScreenshotTests CODE_SIGNING_ALLOWED=NO`
and export the attachments of the result bundle (`xcrun xcresulttool export attachments`). Check a directory with `python3 scripts/ci/check_screenshot_sizes.py <root> --require iphone-medium,iphone-large,watch` (a root of language directories is checked language by language, and the watch size must be the same in all of them).

### Composed iPhone images

`scripts/compose_appstore_screenshots.py` turns the raw captures into the designed iPhone images: the brand gradient (#061E59 → #074F9D → #0A6CD8), a localized headline and subline, and drawn devices (an iPhone with its Dynamic Island, an Apple Watch case with crown and straps) around the captures. Download and unzip `app-store-screenshots-all` from a run of `app-store-localized.yml`, then:

```sh
python3 -I scripts/compose_appstore_screenshots.py <unzipped root> <out dir> [--langs en,ja]
```

It writes `<out>/<lang>/6.9/` (1320 × 2868) and `<out>/<lang>/6.3/` (1206 × 2622), five RGB PNGs each, in upload order: `01-hero` (watch reader), `02-lookup` (word picker and lookup), `03-send` (iPhone Library with the watch Library), `04-typography` (iPhone Reading tab with the sepia reader), `05-progress` (book details with a watch face showing the complications; the watch menu when a set has no complication snapshots). It also writes `contact_6.9.png` and `contact_6.3.png` (every language and slide) for a quick look. The output is not committed.

* The texts are in `TEXT` in the script, five (headline, subline) pairs per language; a `\n` forces a line break. Headlines wrap into at most two balanced lines (by word, by character in Japanese and Chinese) and shrink until they fit.
* On the watch captures, the CI runner's time in the status area is covered with 10:09 at the same place and size (dark brown on the sepia frame, where the system draws it washed out), and a reader line cut in half under the clock band is blanked. Nothing else in the captures is changed.
* Fonts come from `fc-list`: Inter (else Noto Sans or DejaVu Sans), and for ja / zh-Hans Noto Sans CJK JP / SC when installed, else IPAPGothic / WenQuanYi Zen Hei with a slight faux bold. Install the Noto CJK fonts for the best result.

### The website's watch image

The home page hero (`docs/site-src/templates/index.html`) shows `en/watch/watch-1-reader.png` from this artifact, so the site shows the reader as it is. Only the case around it is drawn in CSS (`.watch` in `docs/site/style.css`). It lives in `docs/site/assets/watch-reader.webp` (lossless WebP, 422 × 514; `scripts/site/build.py` leaves `docs/site/assets/` as it is). To refresh it after the reader changes:

1. Download `app-store-screenshots` from the latest successful *macOS* run on `main` (or a run of a PR labelled `ui`) and look at `en/watch/watch-1-reader.png`: the text should be the opening of the chapter with the time above it and no top bar.
2. Convert it without loss and replace the file:
   `python3 -c "from PIL import Image; Image.open('watch-1-reader.png').convert('RGB').save('docs/site/assets/watch-reader.webp', lossless=True, method=6)"`
3. If the size changed, update `width` and `height` on the `<img class="screen">` in the template, run `python3 scripts/site/build.py`, and commit `docs/site/`.

The clock in the image is the CI runner's time (see above); the alt text (`index.watch_label` in `docs/site-src/i18n/*.json`) describes the screen, so keep it in step if the capture shows something else.

### Localized sets

The UI tier captures only English. All eight languages (en, es, fr, de, it, pt-BR, ja, zh-Hans) are captured by the workflow **`app-store-localized.yml`**, which runs only by hand (Actions tab > "App Store screenshots (localized)" > Run workflow, any branch), or through the API:

```sh
gh workflow run app-store-localized.yml --ref main -f languages="en,es,fr,de,it,pt-BR,ja,zh-Hans" -f devices="iphone,watch"
```

Inputs (plain strings): `languages`, comma-separated, default all eight; `devices`, `iphone` (both iPhone sizes) and/or `watch` (the watch frames and the complication snapshots), default both. It builds each platform once (`build-ios`, `build-watch`: build-for-testing, uploaded with the `.xctestrun` file) and runs `test-without-building` per language and device class, at most four macOS runners at a time (about 20 jobs of a few minutes each for the full set). It uploads **`app-store-screenshots-<lang>`** per language (`<lang>/{iphone-medium,iphone-large,watch,complications}/`) and **`app-store-screenshots-all`**, after `check_screenshot_sizes.py` has checked every language. es-ES and es-MX share the `es` set.

## iPhone (the iOS target is iPhone-only: `TARGETED_DEVICE_FAMILY = 1`, so **no iPad screenshots**)

* **Mandatory:** at least one screenshot for **"iPhone with Dynamic Island (medium display)"**: **1206 × 2622** or **1179 × 2556** px portrait (landscape: swap).
* **"iPhone with Face ID (large display)"**, 1284 × 2778 or 1242 × 2688, is required **only** if no "Dynamic Island (large display)" size is given: 1320 × 2868, 1290 × 2796 or 1260 × 2736. CI gives one, so the Face ID size is not needed.
* Every other class is optional; App Store Connect scales the nearest larger set down: Face ID medium (1170 × 2532, 1125 × 2436, 1080 × 2340), Home Button (1242 × 2208, 750 × 1334 and the older 640-wide sizes).
* iPhone Duo (1398 × 2034 outer, 2007 × 2853 inner): Apple's page says screenshots become required in April 2027 for apps built with the iOS 27.1 SDK or later. Not needed for the first submission; no capture exists yet.

## Apple Watch (required, because the app has a watch app)

Provide **one** of these sizes and use it in every language:

| Pixels | Devices |
|---|---|
| 422 × 514 | Ultra 4, Ultra 3 |
| 410 × 502 | Ultra 2, Ultra |
| 416 × 496 | Series 12, 11, 10 |
| 396 × 484 | Series 9, 8, 7 |
| 368 × 448 | Series 6, 5, 4, SE 3, SE 2, SE |
| 312 × 390 | Series 3, 2, 1 |

The deployment target is watchOS 10 / iOS 17 (raised in PR #20), so the oldest Series 1–3 size is not needed; one size is enough.

## Suggested content

1. Watch: reading view with a paragraph of public-domain text.
2. Watch: word lookup with a definition.
3. Watch: library list.
4. iPhone: Library with a public-domain book and its "On Apple Watch" state.
5. iPhone: Reading (typography) tab with live preview.
6. Optional: iPhone *Settings › Progress Sync* with a placeholder server and fake username (never real credentials). Prefer screenshots that show the app working with no account; sync is optional.

Rules: use only public-domain or your own book text and covers; do not show KOReader/Readest logos or UI; no status bars with real names/carrier; no claims that are not in the app (e.g. "free dictionary offline"). An optional app preview video is not required.

Screenshots from real devices, as an alternative to the CI set: take them on your iPhone (Side + Volume Up; they come out at the device's native size, e.g. 1206 × 2622 on iPhone 16/17 Pro) and on the watch (Settings → General → Screenshots enabled, then Side + Digital Crown; they sync to the iPhone Photos app). Check the pixel size against the table before uploading.
