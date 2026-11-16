#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
if [[ "$(uname -s)" == Darwin ]]; then
  [[ -x build/Bifrost.app/Contents/MacOS/bifrost ]] || { echo 'Run make first.' >&2; exit 1; }
  ditto -c -k --sequesterRsrc --keepParent build/Bifrost.app "dist/Bifrost-macos-$(uname -m).zip"
  printf 'Created dist/Bifrost-macos-%s.zip (local ad-hoc signature; not notarized)\n' "$(uname -m)"
  exit 0
fi
/usr/bin/python3 - <<'PY'
import pathlib, zipfile
with zipfile.ZipFile('dist/bifrost@dlb.local.shell-extension.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for name in ['metadata.json', 'extension.js']:
        z.write(pathlib.Path('extension') / name, name)
PY
printf 'Created dist/bifrost@dlb.local.shell-extension.zip\n'
