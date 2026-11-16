#!/usr/bin/env bash
# Sourced by build/test scripts; keep Darwin free of Linux linker flags.
# shellcheck disable=SC2034 # Consumed by scripts that source this file.
odin_platform_flags=()
if [[ "$(uname -s)" == Darwin ]]; then
  # Prefer the standalone Command Line Tools as one matching compiler/SDK pair.
  # Respect an explicitly selected Xcode installation.
  if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  fi
  export MACOSX_DEPLOYMENT_TARGET=12.0
  odin_platform_flags=(-minimum-os-version:12.0)
fi
resolve_odin() {
  if [[ -z "${ODIN_BIN:-}" && -x .tools/odin/odin ]]; then ODIN_BIN="$PWD/.tools/odin/odin"; fi
  ODIN_BIN="${ODIN_BIN:-$(command -v odin || true)}"
  [[ -n "$ODIN_BIN" ]] || { echo 'Install Odin with raylib 6.2 (macOS: scripts/setup-macos.sh).' >&2; return 1; }
  ODIN_ROOT="$("$ODIN_BIN" root)" || { echo 'Odin cannot run. On Apple Silicon, run scripts/setup-macos.sh.' >&2; return 1; }
  RAYLIB_DIR="${RAYLIB_DIR:-$ODIN_ROOT/vendor/raylib}"
}
platform_link_flags() {
  case "$(uname -s)" in
    Darwin) printf '%s' '-framework Cocoa -framework ApplicationServices -framework QuartzCore' ;;
    Linux) printf '%s' "$(pkg-config --libs gio-2.0) -Wl,--wrap=glfwDefaultWindowHints,--wrap=glfwGetWindowPos,--wrap=glfwSetWindowPos" ;;
    *) echo 'Bifrost supports Linux and macOS.' >&2; return 1 ;;
  esac
}
