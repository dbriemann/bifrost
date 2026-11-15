#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
GSETTINGS_BACKEND=memory BIFROST_ICON_RESOLVER="$PWD/build/bifrost-icon-resolver" "${ODIN_BIN:-odin}" test src -extra-linker-flags:"$(pkg-config --libs gio-2.0) -Wl,--wrap=glfwDefaultWindowHints,--wrap=glfwGetWindowPos,--wrap=glfwSetWindowPos"
node --input-type=module --check < extension/extension.js
node tests/bridge.test.mjs
cc -std=c11 -Wall -Wextra -Werror tests/native-smoke.c build/libplatform.a \
  $(pkg-config --cflags --libs gio-2.0) -Wl,--wrap=glfwDefaultWindowHints,--wrap=glfwGetWindowPos,--wrap=glfwSetWindowPos -l:libglfw.so.3 -ldl -o build/native-smoke
GSETTINGS_BACKEND=memory build/native-smoke
cc -std=c11 -Wall -Wextra -Werror tests/window-position.c build/libplatform.a \
  $(pkg-config --libs gio-2.0) -Wl,--wrap=glfwDefaultWindowHints -l:libglfw.so.3 -ldl -o build/window-position-test
build/window-position-test
./build/bifrost --help >/dev/null
if ./build/bifrost --unknown >/dev/null 2>&1; then
  echo 'Unknown CLI options should fail' >&2; exit 1
fi
