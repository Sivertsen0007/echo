#!/usr/bin/env bash
# Build, sign, and install Echo to /Applications so it runs standalone (no
# terminal). After the first launch you grant Accessibility + Microphone once;
# with the stable signing identity (scripts/setup-signing.sh) those grants
# persist across future installs.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh release

DEST="/Applications/Echo.app"
echo "==> Installing to $DEST"

# Quit a running copy so we can replace it.
pkill -f "/Applications/Echo.app" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R build/JarvisVoice.app "$DEST"

# Re-sign in place with the stable identity if available.
IDENTITY="Echo Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$DEST"
fi

echo "==> Installed."
echo "Launch with: open \"$DEST\""
echo "First launch: grant Accessibility (System Settings > Privacy & Security >"
echo "Accessibility) and Microphone. With the stable identity these persist."
