#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
source scripts/common.sh
resolve_odin
GSETTINGS_BACKEND=memory BIFROST_ICON_RESOLVER="$PWD/build/bifrost-icon-resolver" "$ODIN_BIN" test src "${odin_platform_flags[@]}" -extra-linker-flags:"$(platform_link_flags)"
node --input-type=module --check < extension/extension.js
node tests/bridge.test.mjs
if [[ "$(uname -s)" == Darwin ]]; then
  cc -std=c11 -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=12.0 tests/native-macos.m \
    -framework Cocoa -framework ApplicationServices -framework QuartzCore -o build/native-macos-test
  build/native-macos-test
  plutil -lint build/Bifrost.app/Contents/Info.plist
  codesign --verify --strict build/Bifrost.app
  launch_test_dir="$(mktemp -d "$PWD/build/launch-test.XXXXXX")"
  trap 'rm -rf "$launch_test_dir"' EXIT
  BIFROST_LAUNCH_DIR="$launch_test_dir" ./build/bifrost --help >"$launch_test_dir/out"
  [[ "$(cat "$launch_test_dir/status")" == 0 && -s "$launch_test_dir/pid" ]]
  if BIFROST_LAUNCH_DIR="$launch_test_dir" ./build/bifrost --unknown >"$launch_test_dir/out" 2>"$launch_test_dir/err"; then
    echo 'Launcher must receive parser failures' >&2; exit 1
  fi
  [[ "$(cat "$launch_test_dir/status")" == 1 ]]
  BIFROST_LAUNCH_DIR="$launch_test_dir" ./build/bifrost hide --demo
  [[ "$(cat "$launch_test_dir/status")" == 0 ]]
  if ./build/bifrost --workspace current >/dev/null 2>&1; then
    echo 'macOS Space filters must fail explicitly' >&2; exit 1
  fi
else
cc -std=c11 -Wall -Wextra -Werror tests/native-smoke.c build/libplatform.a \
  $(pkg-config --cflags --libs gio-2.0) -Wl,--wrap=glfwDefaultWindowHints,--wrap=glfwGetWindowPos,--wrap=glfwSetWindowPos -l:libglfw.so.3 -ldl -o build/native-smoke
GSETTINGS_BACKEND=memory build/native-smoke
cc -std=c11 -Wall -Wextra -Werror tests/window-position.c build/libplatform.a \
  $(pkg-config --libs gio-2.0) -Wl,--wrap=glfwDefaultWindowHints -l:libglfw.so.3 -ldl -o build/window-position-test
build/window-position-test
fi
./build/bifrost --help >/dev/null
for value in 0 -1 3.1 NaN Inf invalid; do
  if ./build/bifrost --scale "$value" >/dev/null 2>&1; then
    echo "Invalid UI scale should fail: $value" >&2; exit 1
  fi
done
if ./build/bifrost --unknown >/dev/null 2>&1; then
  echo 'Unknown CLI options should fail' >&2; exit 1
fi
