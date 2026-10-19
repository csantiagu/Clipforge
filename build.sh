#!/bin/bash
# Builds build/Clipforge.app with ffmpeg + ffprobe inside it.
#
#   ./build.sh                     download static ffmpeg for this Mac's CPU (cached in vendor/)
#   FFMPEG_DIR=/path ./build.sh    use your own ffmpeg + ffprobe binaries from /path
#
# App icon: put a 1024×1024 PNG at Resources/AppIcon.png (or a ready-made Resources/AppIcon.icns).
#
# Needs the Xcode Command Line Tools (xcode-select --install). Full Xcode is not required.
set -euo pipefail
cd "$(dirname "$0")"

ARCH=$(uname -m)                                   # arm64 or x86_64
case "$ARCH" in
  arm64)  DL_ARCH=arm64 ;;
  x86_64) DL_ARCH=amd64 ;;
  *) echo "Unsupported CPU: $ARCH"; exit 1 ;;
esac

APP=build/Clipforge.app
VENDOR=vendor/$ARCH

echo "==> Compiling (release, $ARCH)"
swift build -c release --arch "$ARCH"
BIN_DIR=$(swift build -c release --arch "$ARCH" --show-bin-path)

echo "==> Getting ffmpeg"
mkdir -p "$VENDOR"
if [ -n "${FFMPEG_DIR:-}" ]; then
  cp "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" "$VENDOR/"
elif [ ! -x "$VENDOR/ffmpeg" ] || [ ! -x "$VENDOR/ffprobe" ]; then
  # Static builds by Martin Riedl (https://ffmpeg.martin-riedl.de), signed and notarized.
  for tool in ffmpeg ffprobe; do
    url="https://ffmpeg.martin-riedl.de/redirect/latest/macos/$DL_ARCH/release/$tool.zip"
    echo "    $url"
    curl -fL --retry 3 -o "$VENDOR/$tool.zip" "$url"
    unzip -o -q "$VENDOR/$tool.zip" -d "$VENDOR"
    rm "$VENDOR/$tool.zip"
  done
fi
chmod +x "$VENDOR/ffmpeg" "$VENDOR/ffprobe"

# A Homebrew ffmpeg links to dozens of Homebrew dylibs and would break on any other Mac.
NONSYSTEM=$(otool -L "$VENDOR/ffmpeg" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/)' || true)
if [ -n "$NONSYSTEM" ]; then
  echo "WARNING: this ffmpeg is not standalone. It needs:"
  echo "$NONSYSTEM" | sed 's/^/    /'
  echo "The app will only work on Macs that have these libraries installed."
fi

echo "==> Encoders available in this ffmpeg:"
for enc in libx264 libx265 h264_videotoolbox hevc_videotoolbox aac; do
  if "$VENDOR/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q " $enc "; then
    echo "    ✓ $enc"
  else
    echo "    ✗ $enc (the app will hide it)"
  fi
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clipforge" "$APP/Contents/MacOS/Clipforge"
cp "$VENDOR/ffmpeg" "$VENDOR/ffprobe" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The bundled ffmpeg is GPL: ship the licence and notices with every copy of the app.
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif [ -f Resources/AppIcon.png ]; then
  echo "==> Making AppIcon.icns from Resources/AppIcon.png"
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "    (no Resources/AppIcon.png yet, using the default icon)"
fi

# Ad-hoc signature: required to run on Apple Silicon. Not notarized, so the first
# launch on another Mac needs right-click → Open.
xattr -cr "$APP"
codesign --force --sign - "$APP/Contents/MacOS/ffmpeg"
codesign --force --sign - "$APP/Contents/MacOS/ffprobe"
codesign --force --sign - "$APP"

echo "==> Done: $APP ($(du -sh "$APP" | cut -f1))"
echo "    Open it with:  open $APP"
echo "    Install it:    cp -R $APP /Applications/"
