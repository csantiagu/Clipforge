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

## Pull requests

Keep them focused, describe what you tested, and make sure CI is green.
By contributing you agree that your contribution is licensed under GPL-3.0.
