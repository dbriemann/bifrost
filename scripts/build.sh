#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ODIN_BIN="${ODIN_BIN:-$(command -v odin)}"
ODIN_ROOT="$("$ODIN_BIN" root)"
RAYLIB_DIR="${RAYLIB_DIR:-$ODIN_ROOT/vendor/raylib}"
mkdir -p build/rl
# Odin bundles raylib 6.2 with an X11-only GLFW. Keep its matching raylib modules,
# and link GLFW 3.4's public ABI from the system instead. Never edit the toolchain.
[[ -f "$RAYLIB_DIR/linux/libraylib.a" ]] || { echo 'Expected Odin raylib 6.2 Linux archive' >&2; exit 1; }
cp "$RAYLIB_DIR/linux/libraylib.a" build/libraylib-wayland.a
ar d build/libraylib-wayland.a rglfw.o
GLFW_LIBRARY="${GLFW_LIBRARY:-$(ldconfig -p | awk '/libglfw.so.3 / && /x86-64/ {library=$NF} END {print library}')}"
[[ -f "$GLFW_LIBRARY" ]] || { echo 'Install GLFW 3.4 with Wayland support (Fedora: glfw)' >&2; exit 1; }
ln -sf "$GLFW_LIBRARY" build/libglfw.so
/usr/bin/python3 - "$RAYLIB_DIR/raylib.odin" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
if 'VERSION_MAJOR :: 6' not in s or 'VERSION_MINOR :: 2' not in s:
    raise SystemExit('This build requires the Odin raylib 6.2 binding/archive pair')
a = s.index('when ODIN_OS == .Windows {')
b = s.index('VERSION_MAJOR ::', a)
s = s[:a] + '''foreign import lib {
    "../libraylib-wayland.a",
    "../libglfw.so",
    "system:dl", "system:pthread", "system:m", "system:GL", "system:X11",
}

''' + s[b:]
pathlib.Path('build/rl/raylib.odin').write_text(s)
PY
cc -std=c11 -O2 -Wall -Wextra -Werror native/icon-resolver.c \
  $(pkg-config --cflags --libs gio-2.0) -ldl -o build/bifrost-icon-resolver
cc -std=c11 -fPIC -O2 -Wall -Wextra -Werror -c native/platform.c -o build/platform.o $(pkg-config --cflags gio-unix-2.0)
ar rcs build/libplatform.a build/platform.o
build_flags=(-o:speed)
if [[ "${BIFROST_DEBUG:-0}" == 1 ]]; then build_flags=(-debug -o:none); fi
"$ODIN_BIN" build src -out:build/bifrost "${build_flags[@]}" -extra-linker-flags:"$(pkg-config --libs gio-2.0) -Wl,--wrap=glfwDefaultWindowHints,--wrap=glfwGetWindowPos,--wrap=glfwSetWindowPos"
printf 'Built %s/build/bifrost\n' "$PWD"
