#!/bin/bash
# Build PeripheralSpeed.app + release zip from a clean checkout.
# Needs only Command Line Tools. Output: build/PeripheralSpeed-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(grep 'static let version' Sources/PeripheralSpeed/Models.swift | sed 's/.*"\(.*\)".*/\1/')
swift build -c release

# assemble OUTSIDE any iCloud-synced folder: sync daemons re-stamp
# Finder/FileProvider metadata that strict codesigning rejects
STAGE=$(mktemp -d /tmp/peripheralspeed-build.XXXXXX)
APP="$STAGE/PeripheralSpeed.app"
rm -rf build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PeripheralSpeed "$APP/Contents/MacOS/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PeripheralSpeed</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>co.move-ment.peripheralspeed</string>
    <key>CFBundleName</key>
    <string>Peripheral Speed</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Notarize when a Developer ID certificate and a notarytool keychain
# profile ("peripheralspeed-notary") are present; ad-hoc sign otherwise.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
PROFILE="peripheralspeed-notary"
xattr -cr "$APP"   # strict signing rejects Finder metadata in the bundle
if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "signing with: $IDENTITY"
    codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
    ditto -c -k --keepParent "$APP" build/notarize.zip
    echo "submitting to Apple notary service…"
    xcrun notarytool submit build/notarize.zip --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm build/notarize.zip
    echo "notarized and stapled."
else
    echo "no Developer ID identity + notary profile — ad-hoc signing"
    echo "(installs will need: xattr -dr com.apple.quarantine /Applications/PeripheralSpeed.app)"
    codesign --force --deep -s - "$APP"
fi

# RELEASE GATE: never let an unassessable app become a release zip
# silently — this once shipped an ad-hoc build to real users when the
# notary keychain profile vanished. Dev builds: ALLOW_ADHOC=1 ./make-app.sh
if ! spctl -a -t exec "$APP" >/dev/null 2>&1; then
    if [ "${ALLOW_ADHOC:-0}" != "1" ]; then
        echo "ERROR: staged app is NOT Gatekeeper-acceptable (ad-hoc or unnotarized)."
        echo "Fix signing/notary credentials, or set ALLOW_ADHOC=1 for a dev build."
        exit 1
    fi
    echo "WARNING: shipping Gatekeeper-rejected build because ALLOW_ADHOC=1"
fi

ditto -c -k --keepParent "$APP" "build/PeripheralSpeed-$VERSION.zip"
echo "built: build/PeripheralSpeed-$VERSION.zip"
echo "signed app staged at: $APP"
