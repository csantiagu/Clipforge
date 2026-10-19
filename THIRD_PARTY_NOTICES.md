# Third-party software

Clipforge's own code is licensed under the GNU General Public License v3.0 (see `LICENSE`).

## FFmpeg

The built `Clipforge.app` contains the `ffmpeg` and `ffprobe` programs from the FFmpeg project
(https://ffmpeg.org). Clipforge runs them as separate programs; it does not link against them.

The binaries that `build.sh` downloads are static builds by Martin Riedl
(https://ffmpeg.martin-riedl.de). They include GPL components such as x264 and x265,
so they are licensed under the **GNU General Public License** (version 2 or later, or version 3,
depending on the build configuration; run `ffmpeg -version` and check the `--enable-gpl` /
`--enable-version3` flags).

- FFmpeg source code: https://ffmpeg.org/download.html
- FFmpeg licence and legal notes: https://ffmpeg.org/legal.html
- x264: https://www.videolan.org/developers/x264.html (GPL-2.0-or-later)
- x265: https://www.x265.org (GPL-2.0-or-later)

### If you distribute Clipforge.app

The GPL requires that whoever distributes the FFmpeg binaries also makes the matching source code
available. When you publish a release that contains the app, attach (or link to) the FFmpeg source
for the exact version that is inside it, as printed by `Clipforge.app/Contents/MacOS/ffmpeg -version`.
