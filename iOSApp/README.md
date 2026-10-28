# WristReader iOS app

SwiftUI, iOS 16+, target `WristReader` (sources in `iOSApp/`, excluding `Tests/`; tests in `iOSApp/Tests`).

- `Info.plist` declares EPUB document types (`org.idpf.epub-container`) so the share sheet / "Open in" works.
  XcodeGen: `info: path: iOSApp/Info.plist`. No entitlements are required.
- Pipeline: import (Files / share / onOpenURL) -> copy to temp (security-scoped) -> `EPUBParser` off main
  thread -> JSON -> LZFSE -> `Application Support/WristReader/Books/<hash>.wrbook`.
- WatchConnectivity schema: `docs/WATCH_CONNECTIVITY.md`.
- KOSync credentials live in the Keychain; they are also sent to the watch (see doc for the tradeoff).
