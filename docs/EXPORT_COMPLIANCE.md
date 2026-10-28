# Export compliance (encryption)

**Decision: `ITSAppUsesNonExemptEncryption = NO`** (set in `project.yml` for both targets).
**Flag: verify with Apple's current documentation before first submission** ("Complying with Encryption
Export Regulations" in App Store Connect help, and the EAR/BIS rules it links to). This is the project's
engineering reading, not legal advice.

Reasoning from the code:

- Network encryption is HTTPS via `URLSession`, i.e. the encryption built into the operating system. Apple's
  guidance treats use of only OS-provided standard encryption (HTTPS/TLS) as exempt.
- The only cryptographic primitive in app code is `CryptoKit` `Insecure.MD5`, used (a) as the KOReader sync
  protocol's required password hash/auth key and (b) for the KOReader "partial MD5" document identifier.
  MD5 here is a protocol-mandated digest/identifier, not used to encrypt user data or to provide
  confidentiality, and the app contains no proprietary or non-standard encryption, no custom TLS, no
  encryption libraries, no encrypted-file features.
- Keychain storage and WatchConnectivity are Apple system services.
- Plain `http://` is permitted only to local-network hosts (ATS `NSAllowsLocalNetworking`), which adds no encryption.

Consequences: no export-compliance document upload is expected, and the App Store Connect encryption question
is pre-answered by the plist key. Distribution in France historically required an additional declaration for
non-exempt encryption only; not applicable if the exemption holds. Re-evaluate if any encryption library,
custom crypto or end-to-end encrypted feature is added.
