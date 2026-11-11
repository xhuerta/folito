# App Store screenshots

Source of the sizes: Apple, [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) (App Store Connect Help, read 2026-11-11; re-check before uploading, Apple adds sizes with each device generation). The same list is in `scripts/ci/check_screenshot_sizes.py` (`ACCEPTED`): change both together.

General: 1 to 10 screenshots per device size and localization; `.jpeg`, `.jpg` or `.png`; **no alpha/transparency**; use the same Apple Watch size in every localization. If you supply only the largest required size, App Store Connect scales it down for smaller devices.

## Where the screenshots come from

CI takes them: nobody needs a Mac or a device. The UI tier of `macos.yml` (every push to `main`, and pull requests labelled `ui`; see [TESTING.md](../TESTING.md)) runs two screenshot suites on simulators whose screens are accepted sizes: the iPhone sets in a job of their own, `app-store-iphone` (in parallel with the `ios` job, which they would otherwise push past its time limit), the watch set at the end of the `watch` job. The job `app-store-screenshots` merges them into one artifact, **`app-store-screenshots`**:

| Directory | Display class | Simulator (first one the runner has) | Pixels | Suite |
|---|---|---|---|---|
| `iphone-medium/` | iPhone with Dynamic Island, medium display (**required**) | iPhone 17 Pro, 17, 16 Pro; else 16, 15 Pro, 15, 14 Pro | 1206 × 2622 (else 1179 × 2556) | `iOSApp/UITests/AppStoreScreenshotTests.swift` |
| `iphone-large/` | iPhone with Dynamic Island, large display (given so that the older Face ID large size is not required) | iPhone 17 Pro Max, 16 Pro Max; else 16 Plus, 15 Pro Max, 15 Plus, 14 Pro Max; else iPhone Air | 1320 × 2868 (else 1290 × 2796, 1260 × 2736) | the same suite |
| `watch/` | Apple Watch (**required**) | Apple Watch Ultra 3; else Ultra 2, Ultra; else Series 11 / 10 (46mm); else Series 9, 8, 7 (45mm) | 422 × 514 (else 410 × 502, 416 × 496, 396 × 484) | `WatchApp/UITests/WatchAppStoreScreenshotTests.swift` |

| File | Shows |
|---|---|
| `watch/watch-1-reader.png` | The reader: the opening of *Pride and Prejudice*, the English sample book |
| `watch/watch-2-word-lookup.png` | Word lookup: the definition of the selected word |
| `watch/watch-2a-word-picker.png` | Word lookup: choosing the word in its paragraph |
| `watch/watch-3-library.png` | The Library |
| `iphone-*/iphone-1-library.png` | The Library with covers and each book's Apple Watch state |
| `iphone-*/iphone-2-book-details.png` | A book's details |
| `iphone-*/iphone-3-reading.png` | The Reading tab with its live preview |

How it works:

* `scripts/ci/appstore_simulator.py <class>` picks the simulator, or creates one when the runner has the device type but no such device. It lists only models whose screen is an accepted size (the 42 mm and 41 mm watches are not), and fails when the runner has none: nothing is scaled or padded to reach a size.
* `scripts/ci/appstore_screenshots.sh <class> <suite>` boots it, overrides the status bar (`xcrun simctl status_bar`: 9:41, Wi-Fi, full battery, no carrier name), runs the suite and exports the named attachments.
* **The watch clock is not overridden.** `simctl status_bar` does not support watchOS simulators: with Xcode 26.3 (watchOS 26 runtime) it fails with "Status bar overrides not supported on this platform" (POSIX error 45). The watch captures therefore show the time at which CI ran them (the runner's clock, UTC). The script still tries, and prints a `::notice::` when the override is refused, so a later Xcode that supports it is used without a change. Nothing is drawn over the capture to fake a time; if a fixed time matters for the listing, retake the watch set on a Mac at the wanted time.
* `scripts/ci/check_screenshot_sizes.py` then fails the job if a capture is not an accepted size for its class, if a class mixes sizes (so the watch size is the same in every set), if a required class is missing, or if an image has an alpha channel. The job `app-store-screenshots` repeats the check on the merged artifact. The script's own test and the simulator choice run on Linux (`linux.yml`, job `ci-scripts`).
* The content is seeded by launch arguments that exist in Debug builds only (`-UITestingSeedCovers` on the iPhone, `-UITestingSeedAppStore` on the watch): public-domain titles, generated covers, and on the watch the opening of the English sample book. No book file, cover art or dictionary is added to the shipped apps.
* iPhone Library: the seeded books hold the full public-domain texts of *The Gods of Mars*, *Emma* and *Alice's Adventures in Wonderland* (Project Gutenberg #64, #158, #11, without the Gutenberg header and licence; built by `scripts/make_appstore_books.py`). They live in the UI test bundle only (`iOSApp/UITests/AppStoreBooks`), and the test passes their folder to the app in `UITESTING_BOOK_TEXTS`, so the sizes in the Library are those of real books.
* iPhone Library: a simulator has no paired Apple Watch, so the Library would open with a "No Apple Watch" card and every book "Waiting for Apple Watch". `-UITestingSimulateWatch` (Debug builds only, `PhoneConnectivity.activate()`) makes the Library show what a user with a paired, reachable watch sees: "Apple Watch connected" and the books on the watch. The real WatchConnectivity session is not activated, so nothing is sent; Release builds have no such code.
* The definitions in the word-lookup capture come from a four-word sample dictionary written for the screenshots, so its source line reads "Sample dictionary". The real dictionaries are Wiktionary data that each user downloads (see [DICTIONARIES.md](../DICTIONARIES.md)); they are not bundled or downloaded in CI.

### Regenerating

1. Add the `ui` label to a pull request, or push to `main` (or run the *macOS* workflow by hand).
2. When the run is done, download the `app-store-screenshots` artifact from the run's page.
3. Upload each directory to its display size in App Store Connect.

On a Mac: `xcodegen generate`, then for instance
`xcodebuild test -project Folito.xcodeproj -scheme FolitoWatch -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' -only-testing:FolitoWatchUITests/WatchAppStoreScreenshotTests CODE_SIGNING_ALLOWED=NO`
and export the attachments of the result bundle (`xcrun xcresulttool export attachments`). Check a directory with `python3 scripts/ci/check_screenshot_sizes.py <root> --require iphone-medium,iphone-large,watch`.

### Other languages

The sets are English. A localized set needs: the suites launched in that language (`-AppleLanguages`), element lookups by identifier instead of English labels (`Library`, `Reading`, `Next Word`, `Look Up`), the sample text and sample dictionary entries of that language on the watch (the iPhone app already bundles one sample book per language), and one directory level per language in the artifact. The simulator choice already keeps one watch size for all of them.

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
