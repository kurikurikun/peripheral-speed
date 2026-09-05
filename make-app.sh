#!/bin/bash
# Build PeripheralSpeed.app + release zip from a clean checkout.
# Needs only Command Line Tools. Output: build/PeripheralSpeed-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(grep 'static let version' Sources/PeripheralSpeed/Models.swift | sed 's/.*"\(.*\)".*/\1/')
swift build -c release

APP=build/PeripheralSpeed.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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

codesign --force --deep -s - "$APP"
ditto -c -k --keepParent "$APP" "build/PeripheralSpeed-$VERSION.zip"
echo "built: build/PeripheralSpeed-$VERSION.zip"
