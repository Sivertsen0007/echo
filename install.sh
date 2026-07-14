#!/usr/bin/env bash
# Build, sign, and install Echo to /Applications, then hand it to launchd so
# it starts at login and is restarted automatically if it ever crashes.
# A normal Quit (exit 0) is respected - launchd only restarts abnormal exits.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh release

DEST="/Applications/Echo.app"
LABEL="com.mathiassivertsen.jarvisvoice"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Installing to $DEST"

# Stop launchd supervision first so killing the running copy doesn't trigger
# an instant restart mid-install, then quit any running copy.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "/Applications/Echo.app" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R build/JarvisVoice.app "$DEST"

# Re-sign in place with the stable identity if available.
IDENTITY="Echo Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$DEST"
fi

# LaunchAgent: RunAtLoad starts Echo at login; KeepAlive/SuccessfulExit=false
# restarts it after a crash but leaves a deliberate Quit alone.
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$DEST/Contents/MacOS/JarvisVoice</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "==> Installed and started under launchd (auto-restart on crash)."
echo "Logs:  ~/.jarvis-voice/logs/echo.log"
echo "First launch only: grant Accessibility + Microphone in System Settings."
