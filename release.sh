#!/usr/bin/env bash
# Build Echo.app, package it into a DMG with an installer script, and drop
# the result in dist/. Share that DMG with anyone running macOS 13+.
set -euo pipefail

cd "$(dirname "$0")"

VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
DIST=dist
STAGING="$DIST/dmg-staging"
DMG_PATH="$DIST/Echo-$VERSION.dmg"
VOLUME_NAME="Install Echo"

echo "==> Echo $VERSION release"
./build.sh release

echo "==> Staging DMG contents"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"

# Copy and rename .app for end-user friendliness. The binary inside is still
# called JarvisVoice (internal name); only the bundle directory is renamed.
cp -R build/JarvisVoice.app "$STAGING/Echo.app"

cp "release/Install Echo.command" "$STAGING/Install Echo.command"
chmod +x "$STAGING/Install Echo.command"

cp release/README.txt "$STAGING/README.txt"

# Optional: drop a symlink to /Applications so users can also drag-install.
ln -s /Applications "$STAGING/Applications"

echo "==> Creating DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

echo ""
echo "==> Built $DMG_PATH"
ls -lh "$DMG_PATH"
echo ""
echo "Share that file. Recipients double-click it, then run Install Echo.command."
