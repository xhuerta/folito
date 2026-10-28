# Accessibility

WristReader aims to behave like Apple's built-in apps: standard SwiftUI components, system text styles and
colours, and the platform conventions described in the
[Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/accessibility).
Each platform has its own section below.

## iOS

### What was done

**Structure (HIG).** Three tabs, each a `NavigationStack`: *Library*, *Reading* and *Settings*. Settings
is an inset-grouped `Form` with *Progress Sync* (pushed screen) and *About* (Privacy Policy, Support,
Version, Acknowledgements with the full licence texts). Toolbar items use standard placements. Empty
states use `ContentUnavailableView`: an empty library ("No Books", with an *Import EPUB* button), no
Apple Watch paired, and WristReader not installed on the watch. All icons are SF Symbols. There are no
custom card styles, fonts or colours in the UI chrome.

**VoiceOver.**
- Library rows are a single element (`accessibilityElement(children: .combine)`) that reads
  "title, author, watch state, size", e.g. "Moby-Dick, Herman Melville, On Apple Watch, 1.2 MB". The
  watch state is text with an icon, never colour alone.
- Every swipe and context-menu action on a row (*Send to Apple Watch Again*, *Delete*) is also an
  accessibility action (VoiceOver Actions rotor: swipe up/down on the row).
- Deleting asks for confirmation (`confirmationDialog`, destructive button), so an accidental action from
  the rotor or a full swipe cannot remove a book. The swipe button is tinted red but has no destructive
  role, so the row stays visible until the deletion is confirmed.
- Icon-only toolbar buttons are `Label`s, so VoiceOver reads their title ("Import EPUB"). The spinner
  shown while importing is labelled "Importing book".
- Sliders in *Reading* are read once as "title, value" ("Size, 18 pt", "Headings, 125%"). The visual
  title/value row above each slider is hidden from VoiceOver to avoid reading it twice.
- The reading preview is one element: "Reading preview, Serif, 18 pt, Sepia".
- Errors use specific alert titles ("Couldn't Import Book", "Couldn't Open File") and a message that says
  what happened and what to do; there is no generic "Error" alert. Sync results appear inline with an icon
  and are announced (`UIAccessibility.post(.announcement)`), as is a finished import; failures are
  prefixed with "Error:" for VoiceOver.
- Section headers come from `Section` and are exposed as headers by the system.
- Links in *About* have the hint "Opens in your web browser."

**Dynamic Type.** No fixed point sizes in UI chrome; only text styles. Layouts that would truncate switch
at accessibility sizes: the size/state line of library rows stacks vertically (`AnyLayout`), slider
title/value rows use `ViewThatFits`, and the segmented *Font*/*Alignment* pickers become menus. Multiline
text is never line-limited. The reading preview is content: it intentionally uses the reader's own font
size (the one sent to the watch) and keeps a fixed watch-like width.

**Colour and contrast.** UI chrome uses system colours (`.primary`, `.green`, `.orange`, `.red`, `.tint`),
the AccentColor and one app colour for supporting text, `secondaryText` (`iOSApp/Views/SecondaryText.swift`).
The system's `secondaryLabel` is a 60% gray that measures about 3.5:1 on white and 3.2:1 on the grouped
background, below WCAG AA's 4.5:1 for text at footnote/subheadline sizes, so every piece of text the app
colours itself (author line, file size and watch state in library rows, slider values, the sync explanations,
the watch connection note) uses `secondaryText` instead: opaque system grays, #636366 in light mode (5.3:1 on
the grouped background, 6.0:1 on white) and #AEAEB2 in dark mode (at least 6:1 on every dark background),
#48484A / #D1D1D6 with Increase Contrast. `SecondaryTextContrastTests` checks ≥ 4.5:1 against every system
background in light/dark, normal/increased contrast, base/elevated. Text whose colour a system component
chooses (section headers and footers, `LabeledContent` values, `ContentUnavailableView` descriptions) keeps
the system's colour, like in Apple's apps; see "Accepted audit findings". The only hard-coded colours besides
these are the reader themes in the preview (shared with the watch). Coloured status labels colour only the
symbol; the text stays primary or `secondaryText`, because coloured text such as system green on white falls
below 4.5:1. Increase Contrast, Reduce Transparency, Bold Text, Smart Invert and Dark Mode are handled by the
system components; nothing overrides them. There are no custom animations, so Reduce Motion needs no special
handling (any future custom animation must check `accessibilityReduceMotion`).

**Localizability.** Every user-facing string is a `LocalizedStringKey` literal or goes through
`String(localized:comment:)`; values are formatted with `FormatStyle` (`.percent`, `.number`,
`.byteCount`). ReaderCore's English-only option titles are not shown; the iPhone uses
`ReadingSettingsText` instead. Translations come next.

### Automated audit

`WristReaderUITests` (`iOSApp/UITests/AccessibilityAuditTests.swift`) launches the app and calls
`XCUIApplication.performAccessibilityAudit(for: .all)` on: the empty library, a library with one book,
Settings, Progress Sync, Acknowledgements and Reading. It runs in CI (`macos.yml`, step "iOS accessibility
audit") on the same iPhone simulator as the unit tests.

Launch arguments (handled only in Debug builds, see `iOSApp/Support/UITestingSupport.swift`):
- `-UITesting`: the library uses a fresh temporary directory (starts empty; the real library is untouched).
- `-UITestingSeedSampleBook`: the same, plus one tiny built-in public-domain sample book.

Run locally:

```sh
xcodegen generate
xcodebuild test -project WristReader.xcodeproj -scheme WristReader \
  -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WristReaderUITests
```

#### Accepted audit findings

| Element | Audit type | Why it is accepted |
|---|---|---|
| Reading preview (`typographyPreview`) | Dynamic Type, Contrast, Text clipped | It is content, not chrome: it renders the book text exactly as the watch will, at the reader's chosen point size and theme colours (for example the *Dim* theme). Scaling it with Dynamic Type would make the preview wrong. Its accessibility value describes the settings in words. |
| System-coloured secondary text: section headers ("Books", "About", "Preview", "Presets", "Font", "Layout", "Theme", "Server"), section footers, `LabeledContent` values ("On"/"Off", the version, licence names) and `ContentUnavailableView` descriptions ("No Apple Watch", "No Books") | Contrast, only "Contrast nearly passed" | The system draws these in its semantic `secondaryLabel` (about 3.5:1 on white, 3.2:1 on the grouped background); the app does not choose the colour, and it follows Dark Mode and Increase Contrast. Each of these texts is marked with `.systemSecondaryText()`, which only sets the accessibility identifier `systemSecondaryText`; the test accepts the finding only on elements with that identifier. A "Contrast failed" finding on them, or any contrast finding on text the app colours itself, still fails the test. |

Every finding (accepted or not) is printed in the CI log ("Accessibility audit issue (accepted|FAILS)") with
its element, frame, the audit's detailed description and, for contrast findings, the contrast measured from
a screenshot of the element; findings that fail also attach a screenshot to the result bundle.

The audit runs one audit type at a time (all the types `.all` covers), because a single `.all` audit of a
screen can exceed XCTest's internal time limit on slower CI simulators; a timed-out type is run again, up to
three attempts (a timeout is not a finding).

Anything else the audit reports fails the test. If a new finding must be accepted, add it to
`isAccepted(_:)` *and* to this table with the reason.

### Testing manually

**VoiceOver** (Settings › Accessibility › VoiceOver, or triple-click the side button if the shortcut is set):
1. Library: swipe through; each book must be one element with title, author, state and size. On a book,
   swipe up/down: *Send to Apple Watch Again* (only when the watch can receive it) and *Delete*. Choose
   *Delete* and check the confirmation is read and *Cancel* keeps the book.
2. Import an EPUB: "Imported “title”." is announced. Import a non-EPUB renamed to `.epub`: the alert reads
   "Couldn't Import Book" and the reason.
3. Reading: each slider reads its title and value; swipe up/down changes it by one step.
4. Settings › Progress Sync: Test Connection with a wrong password; the result is announced and starts
   with "Error".

**Dynamic Type** (Settings › Accessibility › Display & Text Size › Larger Text, enable *Larger
Accessibility Sizes*, drag to the maximum; or Xcode's Environment Overrides): every screen must scroll
without clipped or overlapping text; Font/Alignment become menus; library rows stack.

**Contrast and appearance:** turn on Increase Contrast, Reduce Transparency, Bold Text, Smart Invert and
Dark Mode one at a time and check every screen remains legible (the reading preview keeps its theme colours
by design).

**Accessibility Inspector** (Xcode › Open Developer Tool › Accessibility Inspector): target the simulator,
use *Audit* › *Run Audit* on each screen, and the inspection pointer to check labels, values and traits.

### Known gaps

- Reading progress is not shown in library rows: the iPhone does not know it (progress lives on the watch
  and the sync server). When the phone learns it, add it to the row text, formatted with `.percent`.
- The audit only checks what is on screen; alerts, the delete confirmation, the file importer and the
  context menu are checked manually.
- Licence texts are shown as provided (English, hard-wrapped at about 80 columns), so at the largest
  sizes the wrapping is uneven, but nothing is clipped.
- Not yet verified on a device or simulator (no macOS runner was available when this was written); see the
  CI step and the manual checklist above.

## Apple Watch

### What was done

**Structure (HIG).** One `NavigationStack`: *Library* → reader, with *Settings* behind a gear in the
`.topBarTrailing` toolbar placement and the reader's options (*Reading Options*: text size, typography,
dictionary, chapters) behind a `.topBarTrailing` button. Lists, pickers, steppers and toggles are standard
SwiftUI controls with system styles; there is no custom chrome. The empty library is a
`ContentUnavailableView` ("No Books"). Deleting a book (swipe, VoiceOver action, or the "can't open" screen),
Settings › Reset, Remove Credentials and Typography › Reset to Defaults all use `role: .destructive`
behind a `confirmationDialog`.

**VoiceOver.**
- Library rows are one element: "title, author, 43% read". *Delete* is also an accessibility action
  (Actions rotor), and it asks for confirmation like the swipe does.
- Icon-only buttons are `Label`s ("Settings", "Reading Options", "Previous Word", "Next Word"); decorative
  icons (error glyphs, the current-chapter bookmark, list bullets) are hidden, and the current chapter in
  *Contents* has the *Selected* trait instead.
- Reader: every block (paragraph, heading, quote, list item) is one element; headings carry `.isHeader`
  and their level (`accessibilityHeading(.h1…)`), so the rotor's *Headings* jumps between chapter titles.
  Every block also has the action *Look Up a Word*, even with *Tap Paragraph to Look Up* turned off.
- The sync status glyph has a label ("Syncing reading progress", "Offline. Progress will sync when you're
  connected.", "Sync failed. Check the server in Settings."); nothing is shown while idle.
- Word lookup: the word cursor is one *adjustable* element, "Selected word, *bright*, word 4 of 12". Swipe
  up/down moves to the next/previous word, so it works without the Digital Crown. Turning the crown
  still moves it (with the crown's own detent haptics); the buttons and VoiceOver play a click.
- Steppers read as "Text Size, 16 points", "Letter Spacing, +0.25 points", etc.
- Definitions: the entry word is a header; each sense (number, definition, examples) is one element.

**Dynamic Type.** UI chrome uses text styles only (`.headline`, `.footnote`, `.caption2`, `.title3`) and
scales. Library titles and authors allow more lines at accessibility sizes; the word picker, error screens
and the empty library scroll instead of clipping. The **reader body** keeps the user's chosen point size by
default (it is content, and the size is synced with the iPhone). *Typography › Match System Text Size*
(`ReaderTypography.matchSystemTextSize`, model version 2) scales that size with the watch's Text Size
setting (via `@ScaledMetric(relativeTo: .body)`), clamped to 10–40 pt; headings scale with it.

**Colour and contrast.** Reader theme colours live in ReaderCore (`ThemePalette`), and
`ReaderAccessibilityTests` checks WCAG 2 contrast for every theme: body text ≥ 7:1, secondary text
(quotes) and accent (links / glyphs over the page) ≥ 4.5:1. No theme was below 4.5:1 for body text;
the accent used to be the app tint everywhere, which on the sepia page would have been about 2.2:1, so
each theme now has its own accent.

| Theme | Body | Secondary | Accent | With Increase Contrast (body / secondary / accent) |
|---|---|---|---|---|
| Dark | 21.0 | 14.8 | 8.2 | 21.0 / 21.0 / 11.8 |
| Dim | 10.6 | 7.5 | 7.1 | 15.9 / 13.1 / 11.8 |
| Sepia | 11.6 | 7.5 | 7.1 | 15.6 / 11.6 / 10.3 |
| High Contrast | 21.0 | 21.0 | 11.8 | 21.0 / 21.0 / 11.8 |
| Always On (any theme) | 8.6 | 6.2 | 7.5 | (same) |

- **Increase Contrast** (`colorSchemeContrast == .increased`) switches the reader to the theme's
  high-contrast variant (same background, stronger text).
- **Bold Text** (`legibilityWeight == .bold`) makes the reader's body text semibold (headings stay bold).
- The highlighted word in the word picker is black on yellow (about 15:1 with the system yellow) and bold, so it does not rely on
  colour alone. The sync error glyph differs in shape, not only in colour.

**Always On.** While `isLuminanceReduced` (wrist down), the reader uses a dim palette on black (also for
sepia, so the page doesn't light up the screen) and hides the sync glyph. Changing colours does not move
the reading position (`ReaderRenderStyle.layoutKey`).

**Motion.** There are no custom animations. Jumps (restoring the position, chapters, the other device's
position) scroll without animation, so Reduce Motion needs nothing extra.

**Digital Crown.** The reader is a plain `ScrollView`, so the crown scrolls it with the system's
momentum and detents, like other system apps. In the word picker the crown moves the word cursor
(`digitalCrownRotation`, detent haptics); the page can still be scrolled by touch.

**Haptics.** `WKInterfaceDevice.play`: `.click` when the word cursor moves by a button or VoiceOver,
`.success` / `.failure` when a lookup succeeds or fails.

**Errors.** Messages say what happened and what to do (`WatchMessages`, unit-tested), for example "Can't
reach the server. Check that your watch or iPhone is online, then try again." or "This book's file is
damaged. Delete it here and send it again from WristReader on your iPhone." There is no bare "Error".

**Localizability.** Literal strings in `Text`/`Button`/`Label` are localizable keys; other strings use
`String(localized:comment:)`; sentences with values are single format strings ("%@ read"), never
concatenated; percentages and numbers use `FormatStyle` (`ReadingProgressFormat`, rounded down so an
unfinished book never shows 100%). ReaderCore's English option titles are not shown on the watch
(`localizedName` in `WatchApp/Logic/WatchStrings.swift`).

### Tests

- ReaderCore (`swift test`, also on Linux): `ReaderAccessibilityTests`: contrast of every palette,
  palette selection, Bold Text / Dynamic Type in `spec(for:accessibility:)`, migration of version-1
  typography JSON, tolerant decoding and the wire format of `matchSystemTextSize`.
- Watch (`WatchApp/Tests/AccessibilityTests.swift`): percent formatting, error-message mapping, the
  adjustable word cursor and its haptics (spy), accessibility-aware render styles and the style cache.

### Testing manually

**VoiceOver on the watch** (Watch app on iPhone › Accessibility › VoiceOver, or Settings › Accessibility on
the watch; triple-click the crown if the shortcut is on):
1. Library: swipe through rows; each reads "title, author, n% read". Swipe up/down on a row: *Delete*,
   then check the confirmation and *Cancel*.
2. Open a book: swipe through paragraphs; set the rotor (two-finger twist) to *Headings* and swipe
   up/down to jump between chapter titles. Check *Reading Options* and, if sync is on, the sync glyph label.
3. A paragraph's *Look Up a Word* action opens the word picker; on the cursor, swipe up/down: the new
   word and "word n of m" are announced, with a click. Look up a word offline: the failure message is read
   and the failure haptic plays.
4. Settings: steppers read their value; Reset and Remove Credentials ask for confirmation.

**Text size** (watch Settings › Display & Brightness › Text Size, and Accessibility › Bold Text): at the
largest size check that the library, Settings, menus and the word picker scroll without clipped text. Turn on
*Typography › Match System Text Size* and check the book text follows the Text Size slider.

**Increase Contrast** (Accessibility › Increase Contrast; or Xcode's Environment Overrides) with each theme.

**Always On:** lower the wrist while reading (or Xcode's watch simulator: Device › Always On): the page
dims, sepia turns dark, the sync glyph disappears, and raising the wrist keeps the same paragraph.

**Accessibility Inspector** (Xcode › Open Developer Tool) can inspect the watch simulator: check labels,
values and traits of the elements above and run *Audit* on each screen.

### Known gaps

- Not yet built or run on a simulator or device (no macOS runner was available); the checklist above and
  the watch unit tests must be run once CI is back.
- The reader is a `LazyVStack`: VoiceOver can only reach headings that are laid out (near the current
  position); use *Reading Options › Chapters* to jump further.
- The sync glyph keeps the `.cancellationAction` placement (top leading); its position next to the back
  button needs checking on watchOS 10 and 11.
- *Match System Text Size* is synced with the iPhone like the rest of the typography; the iPhone preview
  does not apply the watch's text size.
- No automated accessibility audit for the watch yet. `XCUIApplication.performAccessibilityAudit`
  exists on watchOS 10, but it needs a watch UI-test target in `project.yml` (follow-up).
