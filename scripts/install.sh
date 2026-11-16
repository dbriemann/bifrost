#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" == Darwin ]]; then
  APP_DIR="${APP_DIR:-$HOME/Applications}"
  BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
  [[ -x build/Bifrost.app/Contents/MacOS/bifrost ]] || { echo 'Run make first.' >&2; exit 1; }
  mkdir -p "$APP_DIR" "$BIN_DIR"
  # ditto preserves the bundle signature and overwrites the previous build.
  ditto build/Bifrost.app "$APP_DIR/Bifrost.app"
  /usr/bin/python3 - "$APP_DIR/Bifrost.app" "$BIN_DIR/bifrost" <<'PY'
import pathlib, shlex, sys
bundle, wrapper = sys.argv[1:]
path = pathlib.Path(wrapper)
if path.is_symlink():
    path.unlink()
launcher = pathlib.Path('scripts/macos-launcher.sh').read_text().split('\n', 1)[1]
path.write_text('#!/bin/sh\nBIFROST_APP=' + shlex.quote(str(pathlib.Path(bundle).resolve())) + '\n' + launcher)
path.chmod(0o755)
PY
  printf 'Installed %s/Bifrost.app and %s/bifrost\n' "$APP_DIR" "$BIN_DIR"
  printf 'Enable Bifrost in System Settings > Privacy & Security > Accessibility.\nThen run: bifrost doctor; bifrost toggle\n'
  exit 0
fi
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DATA_DIR="${DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}}"
EXTENSION_DIR="$DATA_DIR/gnome-shell/extensions/bifrost@dlb.local"
[[ -x build/bifrost && -x build/bifrost-icon-resolver ]] || { echo 'Run make first.' >&2; exit 1; }
install -d "$BIN_DIR" "$EXTENSION_DIR"
install -m755 build/bifrost "$BIN_DIR/bifrost"
install -m755 build/bifrost-icon-resolver "$BIN_DIR/bifrost-icon-resolver"
install -m644 extension/metadata.json extension/extension.js "$EXTENSION_DIR/"
printf 'Installed %s/bifrost and %s\n' "$BIN_DIR" "$EXTENSION_DIR"
printf 'On first install, log out/in if GNOME does not discover the extension.\nThen run: gnome-extensions enable bifrost@dlb.local\n'
