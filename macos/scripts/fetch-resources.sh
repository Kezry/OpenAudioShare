#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Resources

if [[ ! -x Resources/adb ]]; then
  echo "Downloading Android platform-tools (adb)…"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -L --fail --retry 3 -o "$tmp/platform-tools.zip" \
    https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
  unzip -q "$tmp/platform-tools.zip" -d "$tmp"
  cp "$tmp/platform-tools/adb" Resources/adb
  chmod +x Resources/adb
fi

if [[ ! -f Resources/AudioShare.apk ]]; then
  echo "Downloading AudioShare.apk from the upstream release…"
  curl -L --fail --retry 3 -o Resources/AudioShare.apk \
    https://github.com/Kezry/OpenAudioShare/releases/latest/download/AudioShare.apk
fi

echo "Resources ready:"
ls -lh Resources/adb Resources/AudioShare.apk
