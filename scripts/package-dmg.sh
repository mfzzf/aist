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
STAGE=$(mktemp -d)/Aist
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Aist" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

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
