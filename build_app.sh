#!/bin/bash
# Builds SpyProtect and packages it into a proper .app bundle with a stable bundle
# identifier, so macOS treats it as a real app (own entry in System Settings >
# Notifications, own TCC identity for CGSessionCopyCurrentDictionary/IOKit, etc.)
# instead of a bare unsigned executable.
#
# Usage: ./build_app.sh [debug|release]  (defaults to debug, for local dev iteration)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

APP="SpyProtect.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/SpyProtect" "$APP/Contents/MacOS/SpyProtect"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/*.icns Resources/*.png "$APP/Contents/Resources/"

# Ad-hoc sign so the bundle has a stable identity (matching CFBundleIdentifier) that
# TCC/Notification Center can key permissions off of across relaunches. This is NOT a
# Developer ID signature - Gatekeeper will still flag downloaded builds as being from
# an unidentified developer (see README for the right-click-Open workaround).
codesign --force --deep --sign - --identifier dev.stefanguericke.SpyProtect "$APP"

echo "Built $APP ($CONFIG)"
