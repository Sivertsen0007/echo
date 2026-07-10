#!/bin/bash
# One-click installer for Echo. Run by double-clicking from the mounted DMG.
# Copies Echo.app to /Applications, removes the macOS quarantine flag so
# Gatekeeper doesn't block first launch, re-signs ad-hoc, and opens the app.

set -e

cd "$(dirname "$0")"

echo "======================================"
echo "  Installing Echo"
echo "======================================"
echo ""

if [ ! -d "Echo.app" ]; then
    echo "Error: Echo.app not found next to this script."
    echo "Make sure you opened the DMG and double-clicked Install Echo.command from inside it."
    read -p "Press enter to close..."
    exit 1
fi

if [ -d "/Applications/Echo.app" ]; then
    echo "→ Removing previous /Applications/Echo.app..."
    rm -rf "/Applications/Echo.app"
fi

echo "→ Copying Echo.app to /Applications..."
cp -R "Echo.app" "/Applications/Echo.app"

echo "→ Removing macOS quarantine flag..."
xattr -dr com.apple.quarantine "/Applications/Echo.app" 2>/dev/null || true

echo "→ Signing app (ad-hoc)..."
codesign --force --deep --sign - "/Applications/Echo.app" 2>/dev/null || true

echo "→ Launching Echo..."
open "/Applications/Echo.app"

echo ""
echo "======================================"
echo "  Done!"
echo "======================================"
echo ""
echo "Look for the mic icon in your menubar (top-right of screen)."
echo ""
echo "Next steps inside Echo:"
echo "  1. Grant microphone permission when prompted"
echo "  2. Grant Accessibility permission in System Settings"
echo "  3. Paste your OpenAI API key"
echo "  4. Double-tap Fn in any text field to start dictating"
echo ""
echo "This window will close in 8 seconds..."
sleep 8
