# Testing against real software

Everything below was run on Linux (Swift 6.0.3, Docker 29) from `Packages/ReaderCore`. Unit tests (`swift test`) need
nothing external; the checks in this document are gated by environment variables and skip when not configured.

## 0. What runs where

Counts are the "Executed N tests" lines of the CI run for PR #20 (unit tests) and the test methods of the UI
test targets.

| Suite | Where | Command / job | Executed |
|---|---|---|---|
| ReaderCore unit tests | Linux (`linux.yml`); on macOS only compiled, as part of both apps | `swift test` in `Packages/ReaderCore` | 190 (14 skipped: env-gated) |
| KOSync integration | Linux, service container | job `kosync-integration` (`KOSYNC_TEST_URL`) | see section 1 |
| Readest Cloud integration (live) | Linux | job `readest-integration`, only with secrets `READEST_TEST_EMAIL` / `READEST_TEST_PASSWORD` | skipped otherwise; see docs/READEST_SYNC.md |
| Sync connector conformance | Linux + macOS | `SyncConnectorConformance.verify` per connector (`*ConnectorConformanceTests`) | see docs/SYNC_CONNECTORS.md |
| iOS app tests (`FolitoTests`: LogicTests, PresentationTests, TypographySyncTests, SecondaryTextContrastTests, …) | macOS runner, iPhone simulator | `xcodebuild test -scheme Folito -skip-testing:FolitoUITests` | 35 (1 skipped) |
| watchOS app tests (`FolitoWatchTests`: LogicTests, TypographyDictionaryTests, AccessibilityTests) | macOS runner, Apple Watch simulator | `xcodebuild test -scheme FolitoWatch -skip-testing:FolitoWatchUITests` | 64 |
| iOS accessibility audit (`FolitoUITests`) | macOS runner, iPhone simulator; **not on every PR** (see below) | `accessibility.yml`, `xcodebuild test -scheme Folito -only-testing:FolitoUITests` | 5 |
| watchOS accessibility UI tests (`FolitoWatchUITests`: audit + label / trait / AX5 checks) | macOS runner, Apple Watch simulator; **not on every PR** (see below) | `accessibility.yml`, `xcodebuild test -scheme FolitoWatch -only-testing:FolitoWatchUITests` | 15 |

### CI: which workflow runs when

| Workflow | Runs on | Triggers | Typical time |
|---|---|---|---|
| `linux.yml`: `test-core` (ReaderCore `swift test`), `kosync-integration`, `strings` | `ubuntu-latest` | every push to `main` and every PR | 1-2 min |
| `macos.yml`: jobs `ios` and `watch` in parallel (build + unit tests on simulators, String Catalog comparison in `ios`) | `macos-15` (arm64) | push to `main` and PRs, **except** docs-only changes (`docs/**`, `*.md`, scripts and workflows that do not affect the build); **draft PRs skip it** and it runs when the PR is marked ready for review; manual (`workflow_dispatch`, optional runner label) | 5-9 min per job, run in parallel (was 15-20 min in one Intel job) |
| `release-check.yml`: Release archive of both apps + `validate_release.py` | `macos-15` (arm64) | every push to `main`; PRs (not drafts) only when they touch `project.yml`, `Config/**`, asset catalogs, Info/plist/entitlements/privacy manifests, `InfoPlist.xcstrings`, the package manifest/pins, `scripts/validate_release.py` or the workflow; manual | 2-3 min |
| `accessibility.yml`: accessibility audit UI tests | `macos-15` (arm64) | push to `main`, manual, PRs labelled `accessibility` | 10-30 min |
| `release.yml`: signed build + TestFlight upload | `macos-15` (arm64) | tag `v*`, manual; dry run on PRs touching the pipeline | |

`main` has no branch protection or required checks, so path-filtered workflows simply do not run for docs-only PRs. If
a macOS check is ever made required, replace `paths-ignore` with a job-level `if` (e.g. a paths-filter step) so the
check still reports on docs-only PRs.

How `macos.yml` stays fast:

- ReaderCore's `swift test` runs only on Linux. The package has no Apple-only code paths (only `canImport`
  shims for `FoundationNetworking`/`FoundationXML` on Linux) and is compiled on macOS as part of both apps.
- iOS and watch are separate parallel jobs. Each runs `xcodebuild build-for-testing` for a generic simulator
  destination and the runner's architecture only, while `scripts/ci/boot_simulator.sh` picks (or creates) and boots
  the simulator in the background; then `test-without-building` on that simulator. The `ios` job also builds the
  embedded watch app, as the scheme requires.
- Only the SwiftPM checkouts (`SourcePackages`) are cached, keyed on `Package.resolved`. A DerivedData cache was
  tried and measured: repository sources get fresh mtimes on every checkout and are always recompiled, so it only
  spared the small third-party package compiles, and restoring/saving ~160 MB cost about as much. Every build is
  therefore clean: no stale build products can hide an error.
- No index store, `DEBUG_INFORMATION_FORMAT=dwarf`, `-skipPackagePluginValidation -skipMacroValidation`, unsigned;
  XcodeGen comes from its release zip instead of Homebrew.
- Runner: arm64 `macos-15` compiles 3-4x faster than `macos-15-intel` (measured on PR #25: iOS build-for-testing
  3.6-6.4 min on arm64 vs 15.5 min on Intel; the iOS job took 4.8-9.3 min on arm64 vs 20.4 min on Intel). Queue time is dominated by the account-wide limit on concurrent macOS
  jobs, which shorter jobs also relieve. If the arm64 pool is ever capacity-starved again (jobs "not acquired by
  Runner"), set the repository variable `MACOS_RUNNER` to `macos-15-intel`; every macOS workflow honours it.

Unit tests run with per-test time limits (`-test-timeouts-enabled YES`, 180 s default / 300 s maximum) and skip
`FolitoUITests` / `FolitoWatchUITests`. The accessibility UI tests are slow, so they run in
`accessibility.yml` (iOS and watch jobs in parallel) on pushes to `main`, manually (Actions › *Accessibility audit* › *Run workflow*) and on PRs labelled `accessibility`; it is not a
required check. Details in [ACCESSIBILITY.md](ACCESSIBILITY.md#automated-audit).

Each macOS job uploads `ios-tests.xcresult` / `watch-tests.xcresult` (plus its `build.log`) as artifacts and prints a
per-case summary. The watch UI tests are described in `docs/ACCESSIBILITY.md` (Apple Watch, *Automated checks*).
Notes on the watch bundle: the watch app's `PRODUCT_NAME` is `Folito`, so `TEST_HOST`/`BUNDLE_LOADER` are set
explicitly in `project.yml`; the app also sets `WKRunsIndependentlyOfCompanionApp` so it can be installed on a watch
simulator without a paired iPhone (otherwise the test host fails to launch: "Unknown application display identifier").
Locally on a Mac: `xcodegen generate && xcodebuild test -project Folito.xcodeproj -scheme FolitoWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' CODE_SIGNING_ALLOWED=NO`.

## 1. Real KOSync server (koreader-sync-server)

- Server: the original `koreader/kosync` image (OpenResty + Redis), see `scripts/kosync-server/` (compose file + README).
  Port **17200 is plain HTTP**, 7200 is HTTPS with a self-signed certificate.
- Run: `docker compose -f scripts/kosync-server/docker-compose.yml up -d --wait`, then
  `cd Packages/ReaderCore && KOSYNC_TEST_URL=http://localhost:17200 swift test --filter KOSync`.
- CI: job `kosync-integration` in `.github/workflows/linux.yml` runs the same against a service container.
- Readest Cloud (live, dedicated test account): `cd Packages/ReaderCore && READEST_TEST_EMAIL=… READEST_TEST_PASSWORD=… swift test --filter ReadestIntegrationTests`.
- Tests: `KOSyncClientTests.testIntegration` (existing) and `KOSyncIntegrationTests` (new, 10 tests): createUser,
  duplicate user (402 -> `.userExists`), authorize, wrong password -> `.unauthorized` on auth/push/fetch, unknown
  document -> `nil`, push/fetch round trip incl. slashes in xpointer, server-assigned timestamp (seconds, client value
  ignored), unicode device name / device_id, last-write-wins overwrite (even with a lower percentage), two device ids +
  `DefaultSyncConflictPolicy` from both viewpoints, per-user isolation, invalid document id / username (403), `SyncQueue`
  against the real server (valid sent, invalid dropped), wrong base path -> error.
- Result: all pass; no client bug found. Behaviours learned from the real server (not documented elsewhere):
  - `Accept: application/vnd.koreader.v1+json` is mandatory (412 otherwise) - the client sends it.
  - Document ids and usernames containing `:` or empty are rejected with 403 on PUT/create; GET of such an id is a
    plain nginx 404 (HTML) -> client returns `nil`.
  - Percentages outside 0...1 and unknown extra fields are accepted unchanged.

## 2. Real EPUBs (Project Gutenberg)

`scripts/check_real_books.sh [SCRATCH_DIR]` downloads 8 public-domain books to a scratch dir (never committed), runs
`RealWorldBooksTests` (env `FOLITO_EPUB_DIR`, optional `FOLITO_REPORT_DIR`, `FOLITO_SKIP_INVARIANTS`) and
cross-checks hashes. Invariants per book: parse OK, JSON round trip, spine order, `globalOffset` contiguous and sum ==
`totalCharacters`, no blank blocks / U+FFFD / control chars, spans inside text, unique xpointers, **every block xpointer
resolves back to its own (chapter, block) with 0 trimmed steps**, `locate()` -> `resolve()` round trip at mid-block
offsets, percentage monotonic and <= 1. (In a debug build the invariant pass takes ~4 min for all books; the resolver
re-parses the chapter's block xpointers on every call, ~1.3 ms/call in release - fine for one resolve per book open.)

| Book (Gutenberg id) | EPUB | chapters | blocks | chars | JSON raw | zlib-6 | lzma | parse debug / release |
|---|---|---|---|---|---|---|---|---|
| Alice, EN (11) | 183 KB | 13 | 875 | 162 k | 288 KB | 75 KB | 63 KB | 0.10 s |
| Faust, DE (2229) | 186 KB | 29 | 1170 | 204 k | 358 KB | 104 KB | 89 KB | 0.15 s |
| Rashomon, JA (1982) | 82 KB | 1 | 69 | 25 k | 45 KB | 15 KB | 13 KB | 0.02 s |
| Crime and Punishment (2554) | 765 KB | 43 | 4074 | 1.15 M | 1.68 MB | 494 KB | 380 KB | 0.55 s |
| Moby Dick (2701) | 817 KB | 27 | 2888 | 1.23 M | 1.60 MB | 545 KB | 432 KB | 0.64 s |
| Pride & Prejudice, illustrated (1342) | **24.3 MB** | 17 | 2461 | 731 k | 1.06 MB | 310 KB | 241 KB | 0.42 s / 0.19 s |
| Don Quijote, ES (2000) | 933 KB | 35 | 5394 | 2.12 M | 2.82 MB | 878 KB | 659 KB | 0.97 s / 0.47 s |
| Les Miserables (135) | 9.9 MB | 379 | 13995 | 3.21 M | 5.07 MB | 1.50 MB | 1.09 MB | 1.84 s / 0.76 s |

- JSON is ~1.3-1.6 bytes per text character (xpointer + offset per block); zlib shrinks it to ~30 %. For a 1-2 MB-text
  book expect 1.5-3 MB raw / 0.5-0.9 MB compressed on the watch transfer. Apple's LZFSE typically lands between zlib and
  lzma sizes; it could not be measured on Linux.
- Memory: peak RSS of the whole test process stayed ~125 MB (baseline of the XCTest driver) while parsing the 3.2 M-char
  Les Miserables (release), i.e. parser overhead is well below that.
- Unicode (DE umlauts, ES accents/dashes, JA, entities) comes through intact; titles come from nav/NCX.
- Findings: (a) **bug fixed** - Pride & Prejudice produced a block containing only `&nbsp;` (spacer table cell); blocks
  with only invisible characters (NBSP, ZWSP, soft hyphen, BOM...) are now dropped. (b) Not a bug but a limitation:
  Gutenberg splits books into a few large XHTML files with many TOC entries each; the chapter title is the first TOC
  label pointing into the file (for the illustrated Pride & Prejudice that can be an illustration caption), and the
  watch has no sub-chapter navigation. (c) Pride: `/body/DocFragment[2]/body/table/tbody/tr/td/...` paths contain
  `tbody` as in the source markup; whether crengine would insert/omit it could not be verified without KOReader.

## 3. Document hash (partialMD5)

- Swift == `scripts/partial_md5_reference.py` for all 8 real EPUBs and all fixtures.
- New `scripts/partial_md5_luajit.lua` runs KOReader's own offset loop (`bit.lshift(1024, 2*i)`, i = -1...10) on a real
  **LuaJIT 2.1** (md5 via `md5sum`): identical to Python and Swift for the 8 EPUBs, the 6 fixtures and all 10 synthetic
  vectors in `IdentityTests` (sizes 0...20 MB). This confirms the quirk that the first sample is at offset 0
  (`lshift(1024,-2) == 0` in LuaJIT).
- Real-world xpointers from public bug reports (komga#2482, grimmory#2881, CrossInk#853) are in
  `RealWorldSamplesTests`: index-less `/body/DocFragment/body/...` (single-spine books), `text()[1].N`, `section[1]/p[4]/b[1]/...`,
  and a client that dropped `<section>` (must fall back, not crash).

## 4. Robustness / fuzzing (`RobustnessTests`, `XPointerFuzzTests`, always run)

Run on a 512 KB thread stack with a 20-60 s deadline per case; the parser must return a typed `EPUBError` or succeed.
Covered: empty/tiny/garbage files, missing file, directory, truncation at ~70 lengths, deterministic byte-flip fuzzing of
6 fixtures (150 mutants), missing container/OPF, hostile `rootfile` paths, non-package root, empty/dangling spine,
non-XHTML or missing spine items, lying zip headers, zip bomb (100 MB of `a` in 100 KB; `FOLITO_HEAVY=1`), many
medium entries (total budget), 20 k entries, 3000 spine items, billion laughs, XXE, odd numeric/named entities,
nesting depth 200...300 000 (XHTML) and 100 000 (OPF), 20 000 attributes, 2 MB single paragraph, tag soup with 20 k PIs,
UTF-16 LE/BE, UTF-8 BOM, Latin-1, invalid UTF-8, zip-slip names; plus 3000 random/hostile XPointer strings
and out-of-range `locate()` positions.

Bugs found and fixed (all with regression tests):
1. `process(epubAt:)` on a **directory hangs forever** (ZIPFoundation) -> now `invalidArchive`.
2. **No total decompression budget**: many 60 MB entries each passed the per-entry cap -> new `EPUBError.archiveTooLarge`
   (256 MB cumulative per parse). Per-chapter oversize is still skipped silently; budget exhaustion is fatal.
3. **Stack overflow (SIGSEGV)** on deeply nested OPF/NCX (100 k elements; recursive `XMLNode` walks/deinit) -> tree depth capped (128).
4. **O(depth^2) hang** (> 60 s) on 50 k-deep XHTML (path arrays copied per level) -> depth beyond 256 is flattened into its ancestor (0.3 s at 50 k, 1.8 s at 300 k).
5. **O(n^2) tag-soup lenient reader**: every `<?`/`<!` scanned to the end of the document looking for `<!--` -> 20 k such tags
   took > 60 s, now 1.3 s (debug).
6. NBSP-only blocks (see section 2).

## Remaining gaps

- Not run against KOReader/crengine itself (no device/emulator): xpointer *fidelity* (e.g. `tbody` insertion, how crengine
  numbers DocFragments for non-XHTML spine items, text offsets in complex inline markup) is only checked via the
  third-party samples above and self-consistency. A KOReader emulator run on the same EPUBs would close this.
- Readest was not run; only the protocol-compatible original server. No HTTPS test (self-signed cert on 7200 is rejected by design),
  no test against the public sync.koreader.rocks.
- LZFSE size, real watchOS memory/time, and Apple's `XMLParser` (libxml2 on Linux via swift-corelibs-foundation differs from Darwin's) are not covered here.
- Text extraction is only checked structurally on the 8 books (no visual comparison with a reference renderer); EPUB 3
  fixed-layout, RTL/vertical Japanese and MathML-heavy books were not tested.
