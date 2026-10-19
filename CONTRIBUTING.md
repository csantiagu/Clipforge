# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Building

You need a Mac with the Xcode Command Line Tools (`xcode-select --install`).

```bash
swift test          # unit + integration tests (integration tests need ffmpeg: brew install ffmpeg)
swift run Clipforge # run the app against Homebrew's ffmpeg
./build.sh          # build build/Clipforge.app with ffmpeg bundled
```

## Layout

| Path | What lives there |
|---|---|
| `Sources/ClipforgeCore` | Everything that isn't UI: reading files with ffprobe, building ffmpeg commands, output names, size estimates, running processes. Fully covered by tests. |
| `Sources/Clipforge` | The SwiftUI app. `Glass.swift` holds the Liquid Glass / fallback styling. |
| `Tests/ClipforgeCoreTests` | Unit tests (no ffmpeg needed) and integration tests that encode real clips. |

## Rules of thumb

- New ffmpeg behaviour goes in `CommandBuilder` with a test that pins the exact arguments.
  If you change arguments, run the integration tests: they prove ffmpeg accepts them.
- Liquid Glass calls must sit behind `#if compiler(>=6.2)` and `if #available(macOS 26.0, *)`
  with a fallback, so the app still builds with older Xcode and runs on macOS 13.
- Never overwrite a user's file. Output names come from `OutputNamer`.

## Releasing

1. Move the "unreleased" notes in `CHANGELOG.md` under the new version number.
2. Tag and push: `git tag v1.0.0 && git push origin v1.0.0`
   (or run the **Release** workflow from the Actions tab and type the version).
3. GitHub builds `Clipforge-1.0.0-AppleSilicon.dmg` and `Clipforge-1.0.0-Intel.dmg` and publishes them on the Releases page.

Signing and notarization switch on automatically when the Developer ID secrets listed at the top of
`.github/workflows/release.yml` are added to the repository.

## Pull requests

Keep them focused, describe what you tested, and make sure CI is green.
By contributing you agree that your contribution is licensed under GPL-3.0.
