#!/usr/bin/env bash
# Builds [rgb].app from the Swift package, with its icon drawn from source.
set -euo pipefail
cd "$(dirname "$0")"

APP="[rgb].app"
# CI passes the release version; local builds keep a placeholder.
VERSION="${FFF3_VERSION:-0.1.0}"

swift build -c release --product Fff3

# A signed bundle must be replaced, not overwritten: copying over it keeps a stale signature.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Fff3 "$APP/Contents/MacOS/Fff3"

# The Now Playing helper runs inside the system Perl, so it is a plain arm64 dylib.
clang -dynamiclib -fobjc-arc -O2 -Wall -Wno-arc-performSelector-leaks -arch arm64 -mmacosx-version-min=14.0 \
    -framework Foundation Helpers/NowPlaying.m -o "$APP/Contents/Frameworks/libfff3nowplaying.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/libfff3nowplaying.dylib"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift tools/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>[rgb]</string>
    <key>CFBundleDisplayName</key><string>[rgb]</string>
    <key>CFBundleIdentifier</key><string>com.kernoeb.fff3.mac</string>
    <key>CFBundleExecutable</key><string>Fff3</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>[rgb] connects to your LED strips over Bluetooth to change their colour.</string>
    <key>NSAudioCaptureUsageDescription</key><string>[rgb] listens to what this Mac plays so your strips follow the music. Sound is analysed on this Mac and never recorded or sent anywhere.</string>
    <key>NSMicrophoneUsageDescription</key><string>[rgb] listens to the room so your strips follow the music. Sound is analysed on this Mac and never recorded or sent anywhere.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally, not enough to hand to anyone else.
if ! codesign --force --sign - "$APP"; then
    echo "warning: ad-hoc signing failed — macOS may refuse to launch the app" >&2
fi

echo "built $PWD/$APP"
