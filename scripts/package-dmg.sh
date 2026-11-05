#!/bin/bash
# Builds Aist.app signed with the Developer ID certificate and wraps it in a signed DMG.
# Notarizes and staples too when a notarytool keychain profile exists:
#   xcrun notarytool store-credentials aist-notary --apple-id <id> --team-id <team> --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")/.."

# Defaults to the Developer ID Application certificate of team AIST_TEAM (the one the updater trusts).
AIST_TEAM=${AIST_TEAM:-7MNRRP3W76}
export AIST_SIGN_IDENTITY=${AIST_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' -v t="($AIST_TEAM)" '/Developer ID Application/ && index($2, t) {print $2; exit}')}
[ -n "$AIST_SIGN_IDENTITY" ] || { echo "no Developer ID Application certificate in the keychain" >&2; exit 1; }
NOTARY_PROFILE=${NOTARY_PROFILE:-aist-notary}

./scripts/build-mac.sh
APP=build/Aist.app
codesign --verify --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG=build/Aist-$VERSION.dmg
WORK=$(mktemp -d)
STAGE=$WORK/Aist
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Window background (artwork + install hint, 1x/2x in one TIFF) and the disk's icon.
swift scripts/dmg-background.swift "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null
rm -f "$DMG"

# Lay the window out on a writable image with Finder, then compress it. Without Finder automation
# (first run asks for permission) the DMG still works, just without the layout.
[ -d /Volumes/Aist ] && { echo "/Volumes/Aist is mounted; eject it first" >&2; exit 1; }
# Room for the volume icon and Finder's .DS_Store: -srcfolder alone makes a full disk.
hdiutil create -volname "Aist" -srcfolder "$STAGE" -fs HFS+ -format UDRW \
    -size "$(( $(du -sm "$STAGE" | cut -f1) + 20 ))m" -ov "$WORK/rw.dmg" >/dev/null
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk '/Apple_HFS/ {print $1}')
LAYOUT='tell application "Finder"
  tell disk "Aist"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 740, 508}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Aist.app" of container window to {108, 160}
    set position of item "Applications" of container window to {432, 160}
    update without registering applications
    delay 1
    close
  end tell
end tell'
osascript -e "$LAYOUT" 2>/dev/null || scripts/gui-run.sh "osascript -e '$(printf %s "$LAYOUT" | sed "s/'/'\\\\''/g")'" \
    || echo "warning: Finder layout skipped (allow automation of Finder and re-run)" >&2
# The disk's icon, flagged on the volume. After the layout: Finder's pass deletes .VolumeIcon.icns.
cp "$APP/Contents/Resources/AppIcon.icns" /Volumes/Aist/.VolumeIcon.icns
SetFile -c icnC /Volumes/Aist/.VolumeIcon.icns
SetFile -a C /Volumes/Aist
chmod -Rf go-w /Volumes/Aist 2>/dev/null || true
sync
hdiutil detach "$DEVICE" >/dev/null || hdiutil detach -force "$DEVICE" >/dev/null
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$WORK"

SIGN="/usr/bin/codesign --force --timestamp --sign \"$AIST_SIGN_IDENTITY\" \"$DMG\""
eval "$SIGN" 2>/dev/null || scripts/gui-run.sh "$SIGN"

NOTARIZE="xcrun notarytool submit \"$DMG\" --keychain-profile $NOTARY_PROFILE --wait && xcrun stapler staple \"$DMG\""
if eval "$NOTARIZE" 2>/dev/null || scripts/gui-run.sh "$NOTARIZE"; then
    echo "notarized $DMG"
else
    echo "warning: not notarized (no '$NOTARY_PROFILE' notarytool profile?). Gatekeeper will ask before first launch." >&2
fi
# Update feed for the app (Updater reads releases/latest/download/latest.json). Written after stapling,
# which changes the DMG. Release notes come from $NOTES_FILE (Markdown), if given.
REPO=${AIST_REPO:-mfzzf/aist}
SIZE=$(stat -f %z "$DMG")
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
NOTES=""
[ -n "${NOTES_FILE:-}" ] && NOTES=$(cat "$NOTES_FILE")
VERSION="$VERSION" NOTES="$NOTES" SIZE="$SIZE" SHA="$SHA" REPO="$REPO" DMGNAME=$(basename "$DMG") \
/usr/bin/python3 - > build/latest.json <<'PY'
import json, os
v, repo = os.environ["VERSION"], os.environ["REPO"]
print(json.dumps({
    "version": v,
    "notes": os.environ["NOTES"],
    "dmg": f"https://github.com/{repo}/releases/download/v{v}/{os.environ['DMGNAME']}",
    "size": int(os.environ["SIZE"]),
    "sha256": os.environ["SHA"],
    "page": f"https://github.com/{repo}/releases/tag/v{v}",
}, ensure_ascii=False, indent=2))
PY
echo "built $DMG"
echo "release: gh release create v$VERSION $DMG build/latest.json --notes-file <notes.md>"
