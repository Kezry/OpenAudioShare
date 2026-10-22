#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${CONFIG:-release}"
APP_NAME="AudioShare"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AudioShare" "$APP/Contents/MacOS/AudioShare"
if [[ -f "$ROOT/Resources/adb" ]]; then
  cp "$ROOT/Resources/adb" "$APP/Contents/Resources/adb"
else
  echo "warning: Resources/adb is missing (Wi-Fi still works; run scripts/fetch-resources.sh for USB support)"
fi
if [[ -f "$ROOT/Resources/AudioShare.apk" ]]; then
  cp "$ROOT/Resources/AudioShare.apk" "$APP/Contents/Resources/AudioShare.apk"
else
  echo "warning: Resources/AudioShare.apk is missing (auto-install is disabled)"
fi
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/AudioShare"
if [[ -f "$APP/Contents/Resources/adb" ]]; then chmod +x "$APP/Contents/Resources/adb"; fi

# Ad-hoc signature. This is enough for local use and gives TCC a stable app
# identity between launches (rebuilding still creates a new code signature).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
