#!/usr/bin/env bash
# Build, sign, install Echo to /Applications and launch it via LaunchServices.
#
# Deliberately NOT a launchd agent: on macOS 26 a launchd-exec'd process gets
# its listen-only event tap auto-DENIED by TCC (Input Monitoring), which
# silently kills the hotkey - and the deny sticks for all later launches
# until `tccutil reset ListenEvent com.mathiassivertsen.jarvisvoice`. Echo
# registers itself as a login item instead (SMAppService) and self-heals
# internally - see README "Stabilitet".
set -euo pipefail
cd "$(dirname "$0")"

./build.sh release

DEST="/Applications/Echo.app"
LABEL="com.mathiassivertsen.jarvisvoice"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Installing to $DEST"

# Remove the legacy launchd agent if present (see header) and quit any
# running copy so we can replace the bundle.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$AGENT"
pkill -f "/Applications/Echo.app" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R build/JarvisVoice.app "$DEST"

# Re-sign in place with the stable identity if available, so macOS keeps TCC
# (mic/accessibility/input-monitoring) grants across installs.
IDENTITY="Echo Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$DEST"
fi

open "$DEST"
echo "==> Installed and launched."
echo "Logs: ~/.jarvis-voice/logs/echo.log"
