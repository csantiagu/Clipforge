# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Building

You need a Mac with the Xcode Command Line Tools (`xcode-select --install`).

```bash
swift test          # unit + integration tests (video integration tests need ffmpeg: brew install ffmpeg)
swift run Clipforge # run the app against Homebrew's ffmpeg
./build.sh          # build build/Clipforge.app with ffmpeg bundled
```

## Layout

| Path | What lives there |
|---|---|
| `Sources/ClipforgeCore` | Everything that isn't UI, fully covered by tests. Videos: reading files with ffprobe, building ffmpeg commands, size estimates, running processes. Images: `Images.swift` (reading, converting, resizing and removing metadata with ImageIO). Shared: output names (`OutputNamer`). |
| `Sources/Clipforge` | The SwiftUI app. Videos: `AppModel`, `ContentView`, `DetailView`. Images: `ImageModel`, `ImageViews`. `Glass.swift` holds the Liquid Glass / fallback styling. |
| `Tests/ClipforgeCoreTests` | Unit tests (no ffmpeg needed), video integration tests that encode real clips, and `ImageTests`, which build real photos with GPS and camera data and check what is written. |

## Rules of thumb

- New ffmpeg behaviour goes in `CommandBuilder` with a test that pins the exact arguments.
  If you change arguments, run the integration tests: they prove ffmpeg accepts them.
- Liquid Glass calls must sit behind `#if compiler(>=6.2)` and `if #available(macOS 26.0, *)`
  with a fallback, so the app still builds with older Xcode and runs on macOS 13.
- Never overwrite a user's file. Output names come from `OutputNamer`; images are written with `.withoutOverwriting`.
- Images: a re-encoded image gets its rotation applied to the pixels (and orientation 1); an image copied
  without re-encoding keeps its orientation tag. Either way the picture must stay upright, and
  `ImageTests` checks both. Never drop the colour profile.

## Releasing

1. In `CHANGELOG.md`, rename the top `## Unreleased` heading to the new version and date. Its bullet points become the release notes.
2. Run the **Release** workflow from the Actions tab and type the version (or tag and push: `git tag v1.2.0 && git push origin v1.2.0`).
3. GitHub builds `Clipforge-1.2.0-AppleSilicon.dmg` and `Clipforge-1.2.0-Intel.dmg` on macOS 26 (Xcode 26, so the
   app gets Liquid Glass) and publishes them on the Releases page.

To test the whole release without publishing, push to the `release-dry-run` branch: everything runs except the
publish step, and the DMGs appear as downloadable artifacts on the run.

If a run fails with "The job was not acquired by Runner", GitHub had no Mac free. Run it again; it isn't a code problem.

Signing and notarization switch on automatically when the Developer ID secrets listed at the top of
`.github/workflows/release.yml` are added to the repository.

## Pull requests

Keep them focused, describe what you tested, and make sure CI is green.
By contributing you agree that your contribution is licensed under GPL-3.0.
