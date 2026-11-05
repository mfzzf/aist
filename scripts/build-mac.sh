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
# Swift 6.2 back-deployment: the binary loads libswiftCompatibilitySpan.dylib via @rpath. macOS 26 has it
# in /usr/lib/swift; macOS 15 doesn't, so the app crashes at launch unless it carries its own copy.
# (Xcode embeds it automatically; SwiftPM doesn't.) Also drop the toolchain rpath SwiftPM leaves in.
TOOLCHAIN_SWIFT=$(dirname "$(xcrun --find swift)")/../lib/swift-6.2/macosx
mkdir -p "$APP/Contents/Frameworks"
for lib in $(otool -L "$APP/Contents/MacOS/aist" | awk '/@rpath\/libswift/ {sub("@rpath/", "", $1); print $1}'); do
    cp "$TOOLCHAIN_SWIFT/$lib" "$APP/Contents/Frameworks/"
done
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/aist"
otool -l "$APP/Contents/MacOS/aist" | awk '/path .*xctoolchain/ {print $2}' | while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/aist"
done
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
# macOS 26 draws icons from the asset catalog (CFBundleIconName) and puts a legacy icon that doesn't
# fill its square on a grey plate. Resources/Mac/AppIcon.icon is the full-bleed artwork in Icon
# Composer format; the system applies the shape. The .icns above stays for older systems.
ICONCAR=$(mktemp -d)
xcrun actool Resources/Mac/AppIcon.icon --compile "$ICONCAR" --platform macosx --target-device mac \
    --minimum-deployment-target 15.0 --app-icon AppIcon --include-all-app-icons \
    --output-partial-info-plist "$ICONCAR/partial.plist" --errors >/dev/null
cp "$ICONCAR/Assets.car" "$APP/Contents/Resources/"
rm -rf "$ICONCAR"

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
    LIB_FLAGS="--force --options runtime --timestamp"
    SIGN_FLAGS="$LIB_FLAGS --entitlements $ENTITLEMENTS"
else
    LIB_FLAGS="--force --timestamp=none"
    SIGN_FLAGS=$LIB_FLAGS
fi
# Nested code first: codesign doesn't sign Contents/Frameworks for us.
SIGN_CMD="/usr/bin/codesign $LIB_FLAGS --sign \"$IDENTITY\" \"$APP\"/Contents/Frameworks/*.dylib && /usr/bin/codesign $SIGN_FLAGS --sign \"$IDENTITY\" \"$APP\""

# Over SSH the keychain is locked; gui-run.sh signs from the GUI session instead.
if eval "$SIGN_CMD" 2>/dev/null || scripts/gui-run.sh "$SIGN_CMD"; then
    :
else
    echo "warning: signing with '$IDENTITY' failed; falling back to ad-hoc (screen-recording permission will reset)" >&2
    codesign --force --sign - "$APP"
fi
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier=|Signature=" | head -1
echo "built $APP"
