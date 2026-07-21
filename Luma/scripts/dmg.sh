#!/bin/bash
# Build a drag-to-install Luma.dmg from build/Luma.app.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> Luma/

VOL="Luma"
DMG="build/Luma.dmg"
STAGE="build/dmg"
RW="build/Luma-rw.dmg"

[ -d build/Luma.app ] || { echo "build/Luma.app missing — run make app first"; exit 1; }

rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE"
cp -R build/Luma.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Writable image, laid out, then converted to a compressed read-only .dmg.
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -format UDRW -fs HFS+ -ov "$RW" >/dev/null
DEV=$(hdiutil attach "$RW" -nobrowse -noautoopen | grep -E '^/dev/' | head -1 | awk '{print $1}')

# Pretty layout: app on the left, Applications alias on the right, drag across.
# Best-effort — a Finder automation prompt or headless run shouldn't fail the
# build; the /Applications symlink already makes it a real drag installer.
osascript <<EOF || true
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 150, 660, 460}
    set vopts to icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 96
    set position of item "Luma.app" of container window to {120, 150}
    set position of item "Applications" of container window to {340, 150}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

sync
hdiutil detach "$DEV" >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"
echo "wrote $DMG ($(du -h "$DMG" | cut -f1))"
