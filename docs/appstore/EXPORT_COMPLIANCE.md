# Export compliance (encryption)

**Answer: the app uses only encryption that is built into the operating system (HTTPS/TLS via `URLSession`, Keychain), which is exempt.** Info.plist key `ITSAppUsesNonExemptEncryption = NO` (set by `project.yml` on the `store/assets-compliance` branch; verify it is on main before the first upload, otherwise App Store Connect asks for every build).

If App Store Connect still asks per build:

1. "Does your app use encryption?" → **Yes** (HTTPS).
2. "Does your app qualify for any of the exemptions…?" → **Yes**: uses only encryption provided by Apple's OS / standard protocols.
3. No proprietary or non-standard encryption, no export-compliance document to upload, no French declaration.

MD5 is used only as the KOReader Sync protocol's required password digest and document identifier; it is not used to encrypt data. See `docs/EXPORT_COMPLIANCE.md` on the other branch for the code-level reasoning. Source: [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations). This is the engineering reading, not legal advice; the owner makes the declaration.
