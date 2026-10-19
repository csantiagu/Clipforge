# Changelog

## 1.1.0 (2026-10-19)

- Choose where converted videos are saved: next to the original (default) or any folder.
  The choice is remembered, and each video card shows the folder when it isn't next to the original.
- In another folder, files keep their exact name; `_new` is added only if the name is taken.
- A clear error when the chosen folder is missing or read-only (for example an unplugged drive).
- Settings panel: scrolled content no longer shows above the panel; it fades out at the edges.

## 1.0.0 (2026-10-19)

- First release under the Clipforge name.
- Convert and shrink videos with presets: Compatible (H.264), Small · fast (HEVC hardware),
  Small · best (x265), Fix audio only, Remux.
- Pick audio and subtitle tracks per file, or by language across many files.
- Size estimates: calculated for bitrate and target-size modes, sampled for quality mode.
- Output next to the source as `name.ext`, or `name_new.ext` when the format stays the same.
- Liquid Glass interface on macOS 26, frosted fallback on macOS 13–15.
- ffmpeg bundled inside the app.
