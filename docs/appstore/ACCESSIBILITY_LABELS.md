# Accessibility Nutrition Labels (App Store Connect)

App Store Connect → your app → **Accessibility** lets you declare, per device (iPhone, Apple Watch), which features users can rely on to complete the app's **common tasks** (here: import a book, read it, change typography, look up a word, optionally set up sync). Apple asks you to claim a feature only if those tasks work with it; see the "Accessibility Nutrition Labels" pages in [App Store Connect Help](https://developer.apple.com/help/app-store-connect/) and the per-feature evaluation criteria linked from there (link not verified from here; re-read them before declaring).

Evidence: `docs/ACCESSIBILITY.md` (PR #20, `feat/native-polish`; not on this branch yet). That document's *Known gaps* says the apps had **not yet been run on a simulator or device** when it was written, so every "Yes" below is conditional on the owner running the manual checklists in `docs/ACCESSIBILITY.md` and the `WristReaderUITests` audit passing in CI.

| Feature | iPhone | Apple Watch | Basis in `docs/ACCESSIBILITY.md` |
|---|---|---|---|
| **VoiceOver** | Yes | Yes | iPhone: rows are single elements, all swipe/context actions also exposed as accessibility actions, labelled icon buttons, announced results. Watch: rows, reader blocks with heading levels (Headings rotor), adjustable word cursor (no Crown needed), labelled sync glyph. |
| **Larger Text** | Yes | Yes | iPhone: text styles only, layouts adapt at accessibility sizes (the reading preview is content and intentionally fixed). Watch: chrome uses text styles; book text follows the system size when *Typography › Match System Text Size* is on (off by default: the reader keeps the user's chosen size). |
| **Dark Interface** | Yes | Yes | iPhone: system components and semantic colours, Dark Mode not overridden. Watch: dark UI; dark, dim and high-contrast reader themes (sepia is a user choice). |
| **Sufficient Contrast** | Yes | Yes | Watch: `ReaderAccessibilityTests` checks WCAG 2 contrast of every theme (body ≥ 7:1, secondary/accent ≥ 4.5:1) and Increase Contrast variants. iPhone: semantic system colours; coloured status text avoided. Accepted audit finding: the iPhone reading preview renders the chosen theme as content. |
| **Reduced Motion** | Yes | Yes | No custom animations on either platform; position jumps on the watch scroll without animation. |
| Differentiate Without Color Alone | (optional) Yes | (optional) Yes | Watch state on iPhone is text + icon; sync error glyph differs in shape; highlighted word is bold, not only coloured. Documented but not requested in the brief; declare only after checking Apple's criteria. |
| Voice Control | **Do not claim** | **Do not claim** | Not covered by `docs/ACCESSIBILITY.md`. |
| Captions, Audio Descriptions | Not applicable | Not applicable | The app has no audio or video. |
