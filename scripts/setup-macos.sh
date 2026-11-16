#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]] || { echo 'This toolchain download is for Apple Silicon Macs.' >&2; exit 1; }
xcrun --find clang >/dev/null
[[ ! -e .tools/odin ]] || { echo '.tools/odin already exists; use ODIN_BIN to choose another compiler.' >&2; exit 1; }
mkdir -p .tools
stage="$(mktemp -d "$PWD/.tools/download.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
curl -fL https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-macos-arm64-dev-2026-11a.tar.gz -o "$stage/odin.tar.gz"
mkdir "$stage/odin"
tar -xzf "$stage/odin.tar.gz" -C "$stage/odin" --strip-components=1
"$stage/odin/odin" version
mv "$stage/odin" .tools/odin
printf 'Installed project-local Odin in .tools/odin; run make.\n'
