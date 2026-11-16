#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'The native hotkey helper requires macOS.' >&2; exit 1; }
source scripts/common.sh
mkdir -p 'build/Bifrost Hotkey.app/Contents/MacOS'
cc -std=c11 -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=12.0 \
  native/hotkey_macos.m -framework Cocoa -framework Carbon \
  -o 'build/Bifrost Hotkey.app/Contents/MacOS/bifrost-hotkey'
cp native/hotkey-Info.plist 'build/Bifrost Hotkey.app/Contents/Info.plist'
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier org.bifrost.hotkey 'build/Bifrost Hotkey.app'
plutil -lint 'build/Bifrost Hotkey.app/Contents/Info.plist'
codesign --verify --strict 'build/Bifrost Hotkey.app'
