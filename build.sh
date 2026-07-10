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

# Sign with the stable self-signed identity if present, so macOS keeps TCC
# (mic/accessibility) grants across rebuilds. Falls back to ad-hoc otherwise
# (grants won't persist - run scripts/setup-signing.sh once to fix).
IDENTITY="Echo Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> Signing with '$IDENTITY'"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "==> No stable identity - ad-hoc signing (permissions won't persist; run scripts/setup-signing.sh)"
  codesign --force --deep --sign - "$APP"
fi

echo "==> Done: $APP"
echo "Run with: open $APP   (or: $APP/Contents/MacOS/JarvisVoice for console logs)"
