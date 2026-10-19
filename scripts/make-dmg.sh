#!/bin/bash
# Packs build/Clipforge.app into a drag-to-Applications disk image.
#   scripts/make-dmg.sh 1.0.0               →   build/Clipforge-1.0.0.dmg
#   scripts/make-dmg.sh 1.0.0 AppleSilicon  →   build/Clipforge-1.0.0-AppleSilicon.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/make-dmg.sh VERSION [LABEL]}
LABEL=${2:-}
APP=build/Clipforge.app
DMG=build/Clipforge-$VERSION${LABEL:+-$LABEL}.dmg
STAGE=build/dmg

[ -d "$APP" ] || { echo "Build the app first: ./build.sh"; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp THIRD_PARTY_NOTICES.md "$STAGE/Licenses and FFmpeg source.md"

hdiutil create -volname "Clipforge $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "$DMG ($(du -h "$DMG" | cut -f1))"
