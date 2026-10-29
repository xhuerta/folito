# Progress sync connectors

Folito syncs reading positions through **connectors**: one per sync service. Today there are two,
**KOReader Sync** (`kosync`, any KOSync-compatible server) and **Readest** (`readest`, Readest Cloud; see
[READEST_SYNC.md](READEST_SYNC.md)). The design makes a new service (Calibre-Web/OPDS progress, Kavita, Komga,
Moon+ Reader, a WebDAV file...) a self-contained addition.

## Design

All of it lives in ReaderCore (`Packages/ReaderCore/Sources/ReaderCore/Sync/`), Linux-testable.

| Type | Role |
|---|---|
| `BookIdentity` | Every id Folito knows for a book: KOReader partial MD5 (= Readest `book_hash`), Readest `meta_hash`, file name, title, authors. Each connector picks what it needs. |
| `ReadingPosition` | Connector-neutral position: KOReader XPointer, percentage (0...1), chapter, page / page count (Folito: block index + 1 / block count), timestamp, device id and name. |
| `SyncConnectorDescriptor` | Static description: stable `id`, English `displayName` and `summary` (the apps localize them), `capabilities` (progress pull / push; `annotations` reserved), `authKind` (none, username/password, email/password, token, OAuth), declarative `credentialFields` (the settings form), `storageKeys` (Keychain accounts), `staleCheckRequiresDeviceID`, `hosts`. |
| `SyncConnector` | A signed-in connection: `authorize()`, `fetchProgress(for: BookIdentity)`, `pushProgress(_:for:)`. |
| `SyncConnectorFactory` | Builds connectors: `signIn(fields:)` turns the form into the credentials to store (KOSync: validation only; Readest: a password grant returning a session), `makeConnector(credentials:store:)`, `signOut`, `formValues`, `accountLabel`. |
| `SyncCredentials` / `SyncCredentialStore` | A flat `[storageKey: String]` map; the store lets a connector persist rotated tokens. |
| `SyncConnectorRegistry.standard` | The list of factories, in picker order. |
| `SyncQueue` | Connector-agnostic: latest entry per book, debounce, exponential backoff, attempt cap, dedupe of unchanged positions, stale check, persistence. Every entry (`SyncEntry`) records the `connectorID` it was made for. |
| `SyncErrors` / `SyncErrorClassifying` | Maps any connector error to transient (retry), unauthorized (keep, stop) or permanent (drop). |
| `SyncSettingsWire` | The generic phone -> watch payload: `sync_connector` + `sync_credentials` (JSON of `SyncCredentials`). |

### One active connector

Only **one connector is active at a time**. Positions are queued per book with the connector id they were
recorded for; when the active connector changes, entries for any other id are dropped (`retainOnly`) and a
flush never sends an entry to a service it was not made for. Running several connectors at once is not
supported: it would need one queue per connector and a merge policy across services, for a use case nobody
has asked for (KOReader and Readest already talk to each other).

### Staleness and conflicts

- Entries that waited more than `staleCheckAge` (60 s) are compared with the server first: when another
  device saved a newer position (`remote.timestamp > entry.timestamp`), the entry is dropped as superseded.
  KOSync only trusts remote positions carrying another device id (`staleCheckRequiresDeviceID`); Readest has no
  device ids but its `updated_at` is the writer's own clock, so any newer row is another write.
- Connectors should also keep the server from going backwards when the service allows it. Readest does:
  Folito pushes `updatedAt` = when the position was reached, and the server keeps the newer row.
- On opening a book the watch fetches the remote position and offers it when another device is ahead
  (`DefaultSyncConflictPolicy`, neutral `decide(localPercentage:remote: ReadingPosition?, ownDeviceID:)`).

### Apps

- **iPhone** (`iOSApp/Settings/SyncSettings.swift`, `iOSApp/Views/SyncSettingsView.swift`): the screen is
  generated from the registry: a picker (None + every descriptor), the descriptor's `credentialFields` as
  text / secure fields, "Test Connection" only when `descriptor.supportsConnectionTest`, and the account plus
  "Sign Out" for session-based connectors (`descriptor.usesSession`). Credentials go to the Keychain under
  the descriptor's `storageKeys`. Localized names and footers come from `SyncText` (one `case` per
  connector); a connector without cases falls back to its English descriptor text.
- **Watch** (`WatchApp/Services/CredentialsStore.swift`, `SyncCoordinator.swift`): receives
  `{connectorId, credentials}` over the existing settings channel (no per-connector message types), stores
  them under the same `storageKeys`, builds the connector through the registry and caches it until the next
  settings change. `ActiveSyncConnector` resolves the current connector on every queue call.
- Connector-specific UI that does not fit the generic form (an OAuth web flow, a QR code) would be a custom
  view selected by connector id in `SyncSettingsView.connectorSections`; none is needed yet.

## How to add a connector

Checklist, in order. Use the existing connectors as templates (`Sync/Connectors/KOSyncConnector.swift` for a
password service, `Sync/Readest/` for a token/session service).

### 1. Research (before code)

- [ ] Read the service's protocol from its source or official docs (endpoints, auth, request/response
      shapes, timestamps, conflict rules). Record it, with file/URL sources, in `docs/<SERVICE>_SYNC.md`.
- [ ] Check the terms of service, licence and API stability statements: are third-party clients allowed?
      Does the API need secrets a public client cannot hold? Are there rate limits? Stop if any is a blocker.
- [ ] Decide how a position maps to `ReadingPosition` (XPointer? CFI? page? percentage only?) and which
      `BookIdentity` ids identify a book. Write down the limitations.

### 2. ReaderCore

- [ ] Add `Sync/<Service>/` with the HTTP client, a `SyncConnector` and a `SyncConnectorFactory`.
      - `descriptor.id`: short, lowercase, **never changed once shipped** (it is persisted and sent to the
        watch).
      - `credentialFields`: one per form input, with `kind` (`url`, `username`, `email`, `password`,
        `token`); `defaultValue` for prefilled values.
      - `storageKeys`: prefixed with the id (`<id>_...`) so they never collide (the conformance test checks).
      - Store tokens, not passwords, when the service has sessions; if the session cannot be shared between
        devices, let the watch own it (see READEST_SYNC.md, "Who refreshes the session").
      - Errors: conform the error type to `SyncErrorClassifying` (`transient` for offline / 5xx / 429,
        `unauthorized` for rejected credentials, `permanent` otherwise).
      - `pushProgress` must never move the server backwards when the service can tell (send the position's
        own timestamp, or compare first).
- [ ] Register the factory in `SyncConnectorRegistry.standard`.
- [ ] If the connector needs an id `BookIdentity` lacks, add the field there and fill it in
      `ReaderViewModel.bookIdentity` (watch).

### 3. Tests (ReaderCore, Linux)

- [ ] A fake server for `MockURLProtocol` built from **real payloads** (copied from the service's source or
      captured traffic), next to `FakeKOSyncServer` / `FakeReadestServer` in
      `Tests/ReaderCoreTests/SyncConnectorConformance.swift`.
- [ ] A conformance test case:
      ```swift
      final class FooConnectorConformanceTests: XCTestCase {
          func testConformance() async throws {
              let server = FakeFooServer()
              try await SyncConnectorConformance.verify(ConnectorHarness(
                  factory: FooConnectorFactory(), form: ["foo_user": "alice", "foo_password": "secret"],
                  session: mockSession(server.handle)))
          }
      }
      ```
      It checks the descriptor, form validation, sign-in, push/fetch round trip, that a stale queued entry
      never overwrites a newer remote position, and that entries for other connectors are never sent.
- [ ] Unit tests for the exact request/response shapes, auth refresh (if any) and the position mapping.
- [ ] Optional live test gated on env vars (`<SERVICE>_TEST_...`), skipped when unset, wired into
      `.github/workflows/linux.yml` with repository secrets of the same names (see `readest-integration`).
      Never print credentials.

### 4. Apps and strings

- [ ] iPhone `SyncText` (`iOSApp/Views/SyncSettingsView.swift`): add cases for `serviceName`, `summary`,
      `formFooter` and `privacyFooter`; error messages in `UserFacingError.syncMessage`.
- [ ] Watch `WatchMessages.syncServiceName`.
- [ ] Every new string in `iOSApp/Resources/Localizable.xcstrings` and/or
      `WatchApp/Resources/Localizable.xcstrings`, translated into all 8 languages;
      `python3 scripts/check_strings.py` must pass. Give fields and buttons VoiceOver labels/hints.
- [ ] A custom view only if the generic form cannot express the sign-in (OAuth...).

### 5. Privacy and docs

- [ ] `docs/PRIVACY_DATA_MAP.md`: every item sent, to which host, and what is stored where.
- [ ] Privacy policy `docs/site/privacy.html` and `docs/site/es/privacy.html`.
- [ ] App Store answers `docs/appstore/APP_PRIVACY.md` (and review notes if it changes what reviewers see).
- [ ] `docs/WATCH_CONNECTIVITY.md` if the payload changes (it should not: credentials are generic).
- [ ] README features and the sync section.
