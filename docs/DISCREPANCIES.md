## Document identity (partialMD5 / metaHash)

Verified against koreader/koreader `frontend/util.lua` and readest/readest
`apps/readest-app/src/utils/book.ts` (`getMetadataHashInfo`, canonical) +
`apps/readest.koplugin/readest_syncconfig.lua` (`computeMetadataHashInfo`).

1. **partialMD5 first offset is 0, not 256.** The task description assumed
   `1024 << (2*-1) = 256`. In KOReader `lshift` is LuaJIT `bit.lshift`, which masks the
   shift count to 5 bits: `-2 & 31 = 30`, and `1024 << 30` wraps to 0 in 32 bits. Readest's
   `md5.ts` (JS `<<`) has the same quirk (offset 0). We use offsets
   `0, 1024, 4096, ..., 1024*4^10`. `scripts/partial_md5_reference.py` reproduces this.
2. **metaHash is not just `md5("title|authors|identifier")`.**
   - The hashed text is NFC-normalized first.
   - Authors joined with `,`; empty authors dropped. KOReader plugin trims each author, the
     TS side does not; we trim (equal for clean metadata).
   - Identifiers: only one is hashed when a preferred scheme is present, with priority
     `uuid > calibre > isbn` (substring match, case-insensitive, over the raw string; the first
     match for the best scheme wins). Otherwise all normalized, non-empty identifiers are
     joined by `,`.
   - `normalizeIdentifier`: contains `urn:` -> text after the last `:`; else contains `:` ->
     text after the first `:` (empty if scheme or remainder empty); else unchanged.
   - `BookIdentifier` with a non-nil `scheme` is treated like Readest's `Identifier` object
     (scheme equality, raw value, no normalization); with nil scheme like a plain string.
     Readest normally feeds plain strings, so prefer storing raw `dc:identifier` text with
     `scheme == nil` when exact parity matters.
3. **Not replicated:** the PDF filename salt (`|basename`, TS `filename` arg / Lua `.pdf`
   branch) and the empty-title fallback to the filename (Lua only); `BookMetadata` carries
   neither and the app reads EPUBs only. TS `altIdentifier` (preferred over `identifier`) is
   likewise not modelled.
