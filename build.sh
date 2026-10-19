#!/bin/bash
# Builds build/Clipforge.app with ffmpeg + ffprobe inside it.
#
#   ./build.sh                     download static ffmpeg for this Mac's CPU (cached in vendor/)
#   FFMPEG_DIR=/path ./build.sh    use your own ffmpeg + ffprobe binaries from /path
#   UNIVERSAL=1 ./build.sh         one app for Apple Silicon and Intel (needs full Xcode)
#   VERSION=1.2.0 ./build.sh       stamp the version shown in Finder and About
#   SIGN_IDENTITY="Developer ID Application: …" ./build.sh
#                                  sign for distribution (hardened runtime); default is ad-hoc
#
# App icon: put a 1024×1024 PNG at Resources/AppIcon.png (or a ready-made Resources/AppIcon.icns).
#
# Needs the Xcode Command Line Tools (xcode-select --install). Full Xcode is not required.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Clipforge.app
SIGN_IDENTITY=${SIGN_IDENTITY:--}

# Downloads static ffmpeg + ffprobe for one CPU type into vendor/<arch> (cached).
# Builds by Martin Riedl (https://ffmpeg.martin-riedl.de), signed and notarized.
fetch_ffmpeg() {
  local arch=$1 dl_arch
  case "$arch" in
    arm64)  dl_arch=arm64 ;;
    x86_64) dl_arch=amd64 ;;
    *) echo "Unsupported CPU: $arch"; exit 1 ;;
  esac
  mkdir -p "vendor/$arch"
  if [ -x "vendor/$arch/ffmpeg" ] && [ -x "vendor/$arch/ffprobe" ]; then return; fi
  for tool in ffmpeg ffprobe; do
    local url="https://ffmpeg.martin-riedl.de/redirect/latest/macos/$dl_arch/release/$tool.zip"
    echo "    $url"
    curl -fL --retry 3 -o "vendor/$arch/$tool.zip" "$url"
    unzip -o -q "vendor/$arch/$tool.zip" -d "vendor/$arch"
    rm "vendor/$arch/$tool.zip"
  done
  chmod +x "vendor/$arch/ffmpeg" "vendor/$arch/ffprobe"
}

if [ "${UNIVERSAL:-0}" = 1 ]; then
  echo "==> Compiling (release, universal)"
  swift build -c release --arch arm64 --arch x86_64
  BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
  echo "==> Getting ffmpeg (arm64 + x86_64)"
  fetch_ffmpeg arm64
  fetch_ffmpeg x86_64
  VENDOR=vendor/universal
  mkdir -p "$VENDOR"
  for tool in ffmpeg ffprobe; do
    lipo -create "vendor/arm64/$tool" "vendor/x86_64/$tool" -output "$VENDOR/$tool"
  done
else
  ARCH=$(uname -m)
  echo "==> Compiling (release, $ARCH)"
  swift build -c release --arch "$ARCH"
  BIN_DIR=$(swift build -c release --arch "$ARCH" --show-bin-path)
  echo "==> Getting ffmpeg"
  VENDOR=vendor/$ARCH
  if [ -n "${FFMPEG_DIR:-}" ]; then
    mkdir -p "$VENDOR"
    cp "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" "$VENDOR/"
  else
    fetch_ffmpeg "$ARCH"
  fi
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
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
fi
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

# Sign the helpers first, then the app. Ad-hoc ("-") is enough to run on Apple Silicon;
# a Developer ID signature with the hardened runtime is what notarization needs.
xattr -cr "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
  SIGN_FLAGS=(--force --sign -)
else
  SIGN_FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/ffmpeg"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/ffprobe"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP ($(du -sh "$APP" | cut -f1))"
echo "    Open it with:  open $APP"
echo "    Install it:    cp -R $APP /Applications/"
