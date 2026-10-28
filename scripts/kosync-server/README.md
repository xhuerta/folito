# Real KOSync server for integration tests

Uses the original `koreader/kosync` image (koreader-sync-server: OpenResty + Redis).

```sh
docker compose -f scripts/kosync-server/docker-compose.yml up -d --wait   # or: docker run -d -p 17200:17200 koreader/kosync
cd Packages/ReaderCore
KOSYNC_TEST_URL=http://localhost:17200 swift test --filter KOSync
docker compose -f ../../scripts/kosync-server/docker-compose.yml down
```

Notes learned from the real server (see docs/TESTING.md):
- Port **17200 is plain HTTP**, 7200 is HTTPS with a self-signed cert (URLSession will reject it).
- Registration is open; usernames/document ids containing `:` are rejected with 403.
- Every request needs `Accept: application/vnd.koreader.v1+json` (otherwise 412).
- `PUT /syncs/progress` is last-write-wins and stamps `timestamp` (seconds) server-side.
