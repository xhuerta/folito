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

**Colour and contrast.** Only semantic system colours (`.primary`, `.secondary`, `.green`, `.orange`,
`.red`, `.tint`) and the AccentColor are used in UI chrome; the only hard-coded colours are the reader
themes in the preview (shared with the watch). Coloured status labels colour only the symbol; the text
stays primary/secondary, because coloured text such as system green on white falls below 4.5:1.
Increase Contrast, Reduce Transparency, Bold Text, Smart Invert and Dark Mode are handled by the system
components; nothing overrides them. There are no custom animations, so Reduce Motion needs no special
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
