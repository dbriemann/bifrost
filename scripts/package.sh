#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
/usr/bin/python3 - <<'PY'
import pathlib, zipfile
with zipfile.ZipFile('dist/bifrost@dlb.local.shell-extension.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for name in ['metadata.json', 'extension.js']:
        z.write(pathlib.Path('extension') / name, name)
PY
printf 'Created dist/bifrost@dlb.local.shell-extension.zip\n'
