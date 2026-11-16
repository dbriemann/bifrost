#!/usr/bin/env python3
"""Install the optional native Command+^ login helper, preserving the picker."""
import argparse
import copy
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--replace-shortcut', metavar='UUID', help='Remove this Bifrost Shortcuts key assignment.')
options = parser.parse_args()
if os.uname().sysname != 'Darwin':
    parser.error('This helper requires macOS.')
root = Path(__file__).resolve().parent.parent
source = root / 'build/Bifrost Hotkey.app'
app_dir = Path(os.environ.get('APP_DIR', str(Path.home() / 'Applications'))).resolve()
picker = app_dir / 'Bifrost.app'
picker_executable = picker / 'Contents/MacOS/bifrost'
if not source.is_dir() or not picker_executable.is_file():
    parser.error('Build the hotkey helper and install Bifrost first.')
picker_hash = hashlib.sha256(picker_executable.read_bytes()).digest()
helper = app_dir / 'Bifrost Hotkey.app'
logs = Path.home() / 'Library/Logs/Bifrost'
logs.mkdir(mode=0o700, parents=True, exist_ok=True)
agent_dir = Path.home() / 'Library/LaunchAgents'
agent_dir.mkdir(parents=True, exist_ok=True)
agent = agent_dir / 'org.bifrost.hotkey.plist'
log = logs / 'hotkey.log'
label = f'gui/{os.getuid()}/org.bifrost.hotkey'

def read_pbs():
    return plistlib.loads(subprocess.check_output(['defaults', 'export', 'pbs', '-']))

def write_service(key, entry):
    xml = plistlib.dumps(entry).decode()
    dictionary = xml[xml.index('<dict>'):xml.rindex('</dict>') + len('</dict>')] if entry else '<dict/>'
    # defaults parses dictionary keys as plist literals too. Service names start
    # with '(null)', so pass an explicitly quoted string, not a bare key.
    subprocess.run(['defaults', 'write', 'pbs', 'NSServicesStatus', '-dict-add', f"'{key}'", dictionary], check=True)

service = original_service = expected = None
if options.replace_shortcut:
    if not re.fullmatch(r'[0-9A-Fa-f-]{36}', options.replace_shortcut):
        parser.error('Expected a shortcut UUID.')
    shortcuts = subprocess.check_output(['/usr/bin/shortcuts', 'list', '--show-identifiers'], text=True)
    if f'Bifrost ({options.replace_shortcut})' not in shortcuts.splitlines():
        parser.error('That UUID does not identify the Bifrost shortcut.')
    before = read_pbs()
    service = f'(null) - {options.replace_shortcut} - runShortcutAsService'
    original_service = before.get('NSServicesStatus', {}).get(service)
    if original_service and 'key_equivalent' in original_service:
        if original_service['key_equivalent'].replace(chr(92), '') != '@^':
            parser.error('Bifrost uses a different shortcut; stopping before changing it.')
        with tempfile.NamedTemporaryFile(prefix='shortcuts-before-', suffix='.plist', dir=logs, delete=False) as backup:
            backup.write(plistlib.dumps(before))
        expected = copy.deepcopy(before)
        entry = expected['NSServicesStatus'][service]
        del entry['key_equivalent']

subprocess.run(['ditto', str(source), str(helper)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
agent.write_bytes(plistlib.dumps({
    'Label': 'org.bifrost.hotkey',
    'ProgramArguments': [str(helper / 'Contents/MacOS/bifrost-hotkey'), str(picker)],
    'RunAtLoad': True,
    'KeepAlive': {'SuccessfulExit': False},
    'ProcessType': 'Interactive',
    'StandardOutPath': str(log),
    'StandardErrorPath': str(log),
}))
agent.chmod(0o600)
subprocess.run(['launchctl', 'bootout', label], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    if expected:
        write_service(service, expected['NSServicesStatus'][service])
        if read_pbs() != expected:
            raise RuntimeError('Shortcuts settings did not match the intended change.')
        subprocess.run(['/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings', '-u'], check=True)
    subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(agent)], check=True)
    ready = False
    for _ in range(50):
        status = subprocess.run(['launchctl', 'print', label], capture_output=True, text=True)
        pid = re.search(r'\bpid = (\d+)', status.stdout)
        if pid and log.exists() and f'registered Command+^ (PID {pid[1]})' in log.read_text()[-8192:]:
            ready = True
            break
        time.sleep(0.1)
    if not ready:
        raise RuntimeError(f'The hotkey helper did not register. See {log}.')
except Exception:
    subprocess.run(['launchctl', 'bootout', label], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    agent.unlink(missing_ok=True)
    if service and original_service:
        write_service(service, original_service)
        subprocess.run(['/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings', '-u'], check=True)
    raise
assert hashlib.sha256(picker_executable.read_bytes()).digest() == picker_hash
print('Native Command+^ is active and starts automatically at login.')
print('Bifrost.app was preserved; its Accessibility grant is unchanged.')
if service:
    print('Removed the Bifrost Shortcuts key assignment; the shortcut itself is retained.')
