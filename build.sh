#!/usr/bin/env bash
# Build JarvisVoice.app bundle from SPM output.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/JarvisVoice.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/JarvisVoice" "$APP/Contents/MacOS/JarvisVoice"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f Resources/menubar-icon.png ] && cp Resources/menubar-icon.png "$APP/Contents/Resources/menubar-icon.png"

# Ad-hoc sign so the OS will remember TCC (mic/accessibility) grants.
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "Run with: open $APP   (or: $APP/Contents/MacOS/JarvisVoice for console logs)"
