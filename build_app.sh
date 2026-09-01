#!/bin/bash
# Builds SpyProtect and packages it into a proper .app bundle with a stable bundle
# identifier, so macOS treats it as a real app (own entry in System Settings >
# Notifications, own TCC identity for CGSessionCopyCurrentDictionary/IOKit, etc.)
# instead of a bare unsigned executable.
set -euo pipefail
cd "$(dirname "$0")"

swift build

APP="SpyProtect.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/SpyProtect "$APP/Contents/MacOS/SpyProtect"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so the bundle has a stable identity (matching CFBundleIdentifier) that
# TCC/Notification Center can key permissions off of across relaunches.
codesign --force --deep --sign - --identifier dev.stefanguericke.SpyProtect "$APP"

echo "Built $APP"
