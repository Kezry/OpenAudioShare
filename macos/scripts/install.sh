#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIG=release ./scripts/build-app.sh
APP="$ROOT/build/AudioShare.app"
TARGET="/Applications/AudioShare.app"

pkill -f "$TARGET/Contents/MacOS/AudioShare" 2>/dev/null || true
sleep 0.3
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
defaults write com.picapico.audioshare.mac AudioShare.permissionGuideShown -bool true

open -a "$TARGET"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"

echo "Installed $TARGET"
echo "如果系统录音没有声音：在“仅系统录音”中关闭再打开 AudioShare，然后退出并重开应用。"
