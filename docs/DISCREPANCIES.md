
## KOSync (Sync/KOSync.swift, Sync/SyncQueue.swift)

Verified against koreader/koreader-sync-server (`app/controllers/1/syncs_controller.lua`, `config/errors.lua`, `config/routes.lua`),
koreader `plugins/kosync.koplugin` (`api.json`, `KOSyncClient.lua`) and readest `src/services/sync/KOSyncClient.ts`.

- **`POST /users/create` password is the md5 key, not the plain password.** The spec only says `x-auth-key = md5(password)`; the server stores whatever `password` is sent in the body and compares it with `x-auth-key` later, so the body must carry `md5(password)` hex (KOReader and Readest do this). No auth headers are sent on create.
- **Status codes.** 401 unauthorized; 402 = username already registered *and* "registration disabled" (indistinguishable except by message; mapped to `.userExists`); 403 = invalid fields / bad `document` (mapped to `.server(status: 403)`); 502 = redis/internal. Expected-status lists in the plugin: create 201/402, auth 200/401, push 200/202/401, get 200/401.
- **`document` charset.** `PUT` rejects (403) documents that are empty, contain `:`, or fall outside `[A-Za-z0-9_]+` (the GET route cannot serve them). Partial-MD5 hex digests are fine.
- **GET with no stored progress returns 200 `{}`** (no `document` field), not 404. Client maps `{}`/empty body/404 to `nil`. Unlike the spec, a real GET reply may omit `document`, `device` or `device_id` (older entries have no `device_id`); the client falls back to the requested document and empty strings. `timestamp` is server-assigned (`os.time()`), so it is never sent on PUT.
- **PUT response** is `{document, timestamp}`, not an echo of the full record. Server requires `percentage`, `progress` and `device` (else 403); `device_id` is optional on the server but always sent here.
- **Authorize response** is `{"authorized":"OK"}`. The client treats a 200 with a non-JSON body as `.invalidResponse` (misconfigured base URL hitting a web UI; Readest guards the same way). Readest additionally auto-registers on a 401 and retries with HTTP Basic auth for Calibre-Web-Automation; WristReader does neither (registration is an explicit `createUser()`).
- **Accept header.** The server does not validate `Accept`, but the plugin always sends `application/vnd.koreader.v1+json`; we do too. `Content-Type: application/json` is sent only when there is a body.
- **Optional `metadata` field** (KOReader 2026.05+, ignored by the official server) is not sent.
- **Base URL.** Trailing slash and base paths (e.g. `https://host/kosync/`) are preserved by string concatenation, not `URL.appendingPathComponent`.
- **Offline mapping.** `URLError` notConnectedToInternet, timedOut, networkConnectionLost, cannotConnectToHost, cannotFindHost, dnsLookupFailed, dataNotAllowed, internationalRoamingOff -> `.offline`; other `URLError`s (e.g. TLS) are rethrown unchanged.
- **SyncQueue** retries only transient failures (`.offline`, URLError, HTTP 5xx/429); `.unauthorized` keeps the entry and stops the background loop; other errors (e.g. 403) drop the entry; entries are dropped after `maxAttempts` (10).
- Integration test against a real server is gated by `KOSYNC_TEST_URL` and was not run here (building the sync-server Docker image compiles OpenResty from source; skipped).
