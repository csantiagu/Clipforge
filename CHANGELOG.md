# Changelog

## 1.0.0 (unreleased)

- First release under the Clipforge name.
- Convert and shrink videos with presets: Compatible (H.264), Small · fast (HEVC hardware),
  Small · best (x265), Fix audio only, Remux.
- Pick audio and subtitle tracks per file, or by language across many files.
- Size estimates: calculated for bitrate and target-size modes, sampled for quality mode.
- Output next to the source as `name.ext`, or `name_new.ext` when the format stays the same.
- Liquid Glass interface on macOS 26, frosted fallback on macOS 13–15.
- ffmpeg bundled inside the app.
