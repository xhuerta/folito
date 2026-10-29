# Localization

Folito (iPhone app and Apple Watch app) is localized with Xcode String Catalogs.

| Language | Code |
| --- | --- |
| English (source / development language) | `en` |
| Spanish | `es` |
| French | `fr` |
| German | `de` |
| Italian | `it` |
| Portuguese (Brazil) | `pt-BR` |
| Japanese | `ja` |
| Chinese, Simplified | `zh-Hans` |

## Files

| File | Contents |
| --- | --- |
| `iOSApp/Resources/Localizable.xcstrings` | Every UI string of the iPhone app, including the `Shared/` sources it compiles. |
| `iOSApp/Resources/InfoPlist.xcstrings` | Localized Info.plist values (`NSLocalNetworkUsageDescription`). |
| `WatchApp/Resources/Localizable.xcstrings` | Every UI string of the watch app, including `Shared/`. |
| `WatchApp/Resources/InfoPlist.xcstrings` | Localized Info.plist values of the watch app. |

`Shared/` has no catalog of its own: it is compiled into both app targets, so its strings are extracted into
each app's `Localizable.xcstrings` (a third catalog with the same table name in the same target would
collide). ReaderCore has no user-facing text: its English `title` properties are for logs and tests; the
apps use their own localized names (`WatchApp/Logic/WatchStrings.swift`, `iOSApp/Support/DisplayFormat.swift`).

The catalogs are resources of their targets because they live under each target's source path; XcodeGen
derives `knownRegions` from the catalogs' languages. `project.yml` sets `developmentLanguage: en`,
`LOCALIZATION_PREFERS_STRING_CATALOGS` and `SWIFT_EMIT_LOC_STRINGS`, and lists the languages in
`CFBundleLocalizations` of both apps.

## Writing localizable code

- SwiftUI string literals (`Text("…")`, `Button("…")`, `Label("…", systemImage:)`, `.navigationTitle("…")`,
  `.accessibilityLabel("…")`, …) are `LocalizedStringKey`s and are extracted automatically.
- Text built outside a view uses `String(localized: "…", comment: "…")`. Always add a comment that tells the
  translator where the text appears and what each placeholder is.
- A `String` variable passed to `Text(_:)` is shown verbatim, so it must already be localized.
- Interpolations become format specifiers in the key: `String` → `%@`, `Int` → `%lld`, `Double` → `%lf`.
- Counts use plural variations in the catalog (see `%lld points` in the watch catalog) instead of
  `"\(n) item(s)"`.
- Format numbers, percentages and sizes with `formatted(...)` (locale aware), never by hand.
- Text that must not be translated (data, identifiers, debug output) uses `Text(verbatim:)`, or a trailing
  `// i18n-ignore` comment on the line when the check below flags it.
- Keep watch strings short: they are read on a 40–49 mm screen.

## Checking (Linux, no Xcode needed)

```sh
python3 scripts/check_strings.py              # what CI runs (Linux workflow, "strings" job)
python3 scripts/check_strings.py --list-keys  # also print every string found in the sources
```

The script fails when:

- a key has no translation, or one not in state `translated`, in any of the languages above (each plural
  case is checked);
- the format specifiers of a translation differ from the source's (positional `%1$@` forms are allowed);
- a localizable literal in the Swift sources of a target is missing from that target's catalog;
- an obvious user-facing literal bypasses localization (`Text(verbatim: "Some words")`, or a sentence
  assigned to an `…error` / `…message` / `…title` / `…text` property).

Catalog keys no source uses any more are only warnings (Xcode marks them "stale"; delete them).

## Checking against Xcode's extraction (macOS CI)

The scanner above approximates what Xcode extracts. The macOS workflow also runs
`scripts/compare_extracted_strings.py` after building both apps: it reads the `.stringsdata` files the Swift
compiler writes (`SWIFT_EMIT_LOC_STRINGS`) and fails if Xcode extracts a key that is not, character for
character, in the target's `Localizable.xcstrings` (for example `%lld` for an interpolated `Int`, where a
hand-written key might say `%@`; such a key would never be found at run time). It also uploads the catalogs
as the build left them (artifact `xcstrings-after-build`). Locally:

```sh
xcodebuild build -project Folito.xcodeproj -scheme Folito -destination 'generic/platform=iOS Simulator'
python3 scripts/compare_extracted_strings.py ~/Library/Developer/Xcode/DerivedData
```

## Adding or changing a string

1. Write the code as above.
2. Build in Xcode once: it adds the new key to the catalog (state "New"). Without a Mac, add the entry to
   the `.xcstrings` JSON by hand, copying the shape of an existing entry.
3. Translate it in every language (Xcode's catalog editor, or the JSON) and mark each translation
   `translated`.
4. Run `python3 scripts/check_strings.py`.

Changing the English text of a key creates a new key: translate it again and delete the stale one.

## Adding a language

1. Add the language code to `LANGUAGES` in `scripts/check_strings.py`, to `CFBundleLocalizations` of both
   targets in `project.yml`, to the language loop in `scripts/validate_release.py`, and to the table above.
2. In Xcode, open each of the four catalogs and add the language (the "+" under the language list), or add a
   `"<code>" : { "stringUnit" : { "state" : "translated", "value" : "…" } }` entry to every key in the JSON.
   Plural keys need the plural categories of that language (CLDR), e.g. `one`/`few`/`many`/`other`.
3. Translate everything, run `python3 scripts/check_strings.py`, then `xcodegen generate` (new
   `knownRegions`) and test the app in that language (scheme › Run › Options › App Language).
4. App Store Connect: add the localized name, subtitle, description, keywords and screenshots for the new
   language (store metadata is not in this repository).

## Terminology

Use Apple's own terms for each language, as in the system apps: Settings = Ajustes / Réglages /
Einstellungen / Impostazioni / Ajustes / 設定 / 设置; Cancel = Cancelar / Annuler / Abbrechen / Annulla /
Cancelar / キャンセル / 取消; system settings referenced in text use their exact system names (Bold Text,
Increase Contrast, Text Size). German uses "du", French "vous", like Apple.
