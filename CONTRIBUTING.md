# Contributing to Folito

Thanks for your interest! Bug reports, fixes, translations and improvements are
welcome.

## License in plain words

Folito is **source-available** under the
[Functional Source License 1.1, ALv2 Future License](LICENSE.md)
(`FSL-1.1-ALv2`). It is not "open source" in the OSI sense. In practice:

- **You can** read the code, modify it, build the app for yourself, use it for
  non-commercial education or research, and contribute changes back.
- **You can't** ship a competing product or service with it: a commercial app
  or service that substitutes for Folito or offers substantially the same
  functionality.
- **Every release becomes Apache-2.0** two years after it is published, with no
  restrictions beyond that license.
- The **Folito name and icon are not licensed** with the code; forks must
  use their own name and icon. See [TRADEMARKS.md](TRADEMARKS.md).

LICENSE.md is the authoritative text; this summary does not replace it.

## Contributor License Agreement (CLA)

Before a pull request can be merged, its author must sign the
[CLA](CLA.md). You keep the copyright to your contribution; you grant the
project owner a license to use it, including the right to relicense it (for
example, under the Apache License when a release converts, or under other
terms).

Signing takes one comment: when you open your first pull request, the CLA bot
replies with instructions. Comment exactly:

```
I have read the CLA Document and I hereby sign the CLA
```

You only sign once. If the check doesn't update, comment `recheck`.

## Building and testing

- Building the apps (macOS, Xcode, XcodeGen, signing with a free team):
  [README › Building](README.md#building).
- Running tests and CI overview: [README › Development](README.md#development)
  and [docs/TESTING.md](docs/TESTING.md).
- The core logic lives in `Packages/ReaderCore` and its tests run on macOS and
  Linux (`cd Packages/ReaderCore && swift test`).
- Adding strings or languages: [docs/LOCALIZATION.md](docs/LOCALIZATION.md).
- Accessibility expectations: [docs/ACCESSIBILITY.md](docs/ACCESSIBILITY.md).

## Branches and pull requests

- Branch from `main` with a short descriptive name, e.g. `fix/epub-toc`,
  `feat/reading-themes`, `docs/testing`.
- Keep pull requests focused on one change; open an issue first for larger
  features.
- Code, code comments and commit messages are written in **English**.
- Write commit messages in the imperative mood ("Add …", "Fix …").
- Add or update tests for behaviour changes, and make sure the Linux and macOS
  CI workflows pass.
- Don't commit secrets, signing material or `Config/Local.xcconfig`.

## Contact

Questions about licensing, the CLA or trademarks: xlahuerta@protonmail.com.
