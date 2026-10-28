
## XPointer (feat/xpointer)

Sources: koreader/crengine `lvtinydom.cpp` (`ldomXPointer::toStringV2`, `createXPointerV2`), readest/readest `utils/xcfi.ts`, `useKOSync.ts`, `KOSyncClient.ts`, koreader `plugins/kosync.koplugin`.

- **`[1]` indices.** crengine (DOM version < 20260812) omits `[k]` when an element is the only one of its name, writes `name[1]` for the first of several, and `name[k]` otherwise. Newer DOM versions always emit `[1]`. The generator only knows `PathStep.index`, so it omits `[1]` always and emits `[k]` for k>1 (matches the task example `/div/p[3]`). KOReader parses both. The resolver treats `p` and `p[1]` as equal.
- **Offsets are code points.** crengine `text().N` counts UTF-32 code points of the text node; `BookPosition.characterOffset` counts Swift `Character`s. Both generator input (`textOffset`) is passed through raw; `locate`/`resolve` convert between the two.
- **`text()[k]`.** crengine emits it only when the parent has several text nodes; Readest does the same. We cannot map text node k>1 into a flattened block, so offsets for `k>1` and for xpointers pointing into inline children (`p/span/text().3`) resolve to block start (offset 0).
- **Element points.** `div[1].0` (no `text()`) is a valid crengine element point whose number is a child index, not a character offset; we ignore it (block start). Readest's `normalizeProgressXPointer` strips trailing `/text()...` and `.N` before pushing to KOReader, so Readest-written progress commonly has no `text()` part.
- **Path trimming.** The task describes the Readest plugin trimming the path backwards; in the Readest sources inspected (`xcfi.ts`, `useKOSync.ts`, `readest.koplugin/main.lua`) no such trimming exists. Readest converts XPointer -> CFI and, on failure, shows "Sync failed" and does NOT fall back to percentage for XPointer progress (percentage only used when progress is not an XPointer). Trimming and the percentage fallback here are our own design, as specified.
- **DocFragment index.** Missing `[N]` means 1 (Readest uses 0-based section 0 likewise). Since crengine 20240114 every spine item gets a DocFragment (not only XHTML), so `N` equals the spine index including non-XHTML items; old bookmarks may be shifted.
- **Unsupported forms.** `/html/body/...` (MOBI) and `/FictionBook/...` (FB2) xpointers are treated as malformed and go to the percentage fallback.
- **Percentage scale.** KOReader/kosync send 0...1; values are clamped to that range, NaN/inf are unusable.
