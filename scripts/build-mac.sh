#!/bin/bash
# Builds build/Aist.app from the SwiftPM targets and signs it.
# A stable signing identity matters: macOS ties the screen-recording permission to the signature,
# so ad-hoc builds would lose the permission on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
# Defaults to the maintainer's Apple Development certificate (by SHA-1, so no name lives here);
# set AIST_SIGN_IDENTITY to use your own.
IDENTITY=${AIST_SIGN_IDENTITY:-1697C2D75BB941996DAA8250E5875583981C4384}
[ -n "$IDENTITY" ] || { echo "no signing identity; set AIST_SIGN_IDENTITY" >&2; exit 1; }

# Keep the build machine's paths (home folder, user name) out of the binary.
ROOT=$(pwd)
MAP=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT=." -Xcc "-ffile-prefix-map=$ROOT=." -Xcc "-fmacro-prefix-map=$ROOT=.")
swift build -c "$CONFIG" "${MAP[@]}" --product AistMac
swift build -c "$CONFIG" "${MAP[@]}" --product aist-cli
BIN=$(swift build -c "$CONFIG" "${MAP[@]}" --show-bin-path)

APP=build/Aist.app
rm -rf build/aist.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AistMac" "$APP/Contents/MacOS/aist"
# SwiftPM records the deployment target as the SDK version (sdk 15.0), so AppKit runs the app
# in its old-look compatibility mode (no Liquid Glass toolbar / floating sidebar). Stamp the real SDK.
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
MIN_VERSION=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Mac/Info.plist)
vtool -set-build-version macos "$MIN_VERSION" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/aist" "$APP/Contents/MacOS/aist"
cp Resources/Mac/Info.plist "$APP/Contents/Info.plist"
# The lproj folders tell AppKit the app speaks Chinese, so system controls (date pickers, menus,
# dialogs) render in the user's locale instead of falling back to English.
cp -R Resources/Mac/*.lproj "$APP/Contents/Resources/"
cp -R Resources/Mac/ProviderIcons "$APP/Contents/Resources/"
cp "$BIN/aist-cli" build/aist-cli

# App icon: Resources/Mac/AppIcon.png (1024², already on the macOS icon grid) → AppIcon.icns
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/Mac/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/Mac/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Developer ID builds are for distribution: hardened runtime + secure timestamp, as notarization requires.
# iCloud sync needs a Developer ID provisioning profile granting iCloud + push for this app ID; kept out
# of the repo (it carries the certificate), at $AIST_PROFILE.
PROFILE=${AIST_PROFILE:-$HOME/.config/aist/Aist_DeveloperID.provisionprofile}
if [[ $IDENTITY == "Developer ID"* ]]; then
    ENTITLEMENTS=Resources/Mac/Aist.entitlements
    if [ -f "$PROFILE" ]; then
        cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
        ENTITLEMENTS=Resources/Mac/Aist-iCloud.entitlements
        echo "embedding $(basename "$PROFILE"): iCloud sync on"
    else
        echo "no provisioning profile at $PROFILE: iCloud sync off in this build" >&2
    fi
    SIGN_FLAGS="--force --options runtime --timestamp --entitlements $ENTITLEMENTS"
else
    SIGN_FLAGS="--force --timestamp=none"
fi
SIGN_CMD="/usr/bin/codesign $SIGN_FLAGS --sign \"$IDENTITY\" \"$APP\""

# Over SSH the keychain is locked; gui-run.sh signs from the GUI session instead.
if eval "$SIGN_CMD" 2>/dev/null || scripts/gui-run.sh "$SIGN_CMD"; then
    :
else
    echo "warning: signing with '$IDENTITY' failed; falling back to ad-hoc (screen-recording permission will reset)" >&2
    codesign --force --sign - "$APP"
fi
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier=|Signature=" | head -1
echo "built $APP"
