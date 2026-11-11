#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DATA_DIR="${DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}}"
EXTENSION_DIR="$DATA_DIR/gnome-shell/extensions/bifrost@dlb.local"
[[ -x build/bifrost ]] || { echo 'Run make first.' >&2; exit 1; }
install -d "$BIN_DIR" "$EXTENSION_DIR"
install -m755 build/bifrost "$BIN_DIR/bifrost"
install -m644 extension/metadata.json extension/extension.js "$EXTENSION_DIR/"
printf 'Installed %s/bifrost and %s\n' "$BIN_DIR" "$EXTENSION_DIR"
printf 'On first install, log out/in if GNOME does not discover the extension.\nThen run: gnome-extensions enable bifrost@dlb.local\n'
