#!/bin/sh
# Installed with BIFROST_APP set to the bundle's absolute path.
: "${BIFROST_APP:?BIFROST_APP must point to Bifrost.app}"

# Launch Services gives the app its own Accessibility permission identity.
# /dev/stdout cannot be passed to Launch Services reliably, so relay private
# output files after the invocation finishes, then remove them.
bifrost_cli_dir=$(mktemp -d "${TMPDIR:-/tmp}/bifrost-cli.XXXXXX") || exit 1
trap 'rm -rf "$bifrost_cli_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# open -W races with applications that exit before Launch Services finds their
# PID. Use the app's own start/completion receipts instead, including exit codes.
/usr/bin/open -n -g -a "$BIFROST_APP" \
  --stdout "$bifrost_cli_dir/stdout" --stderr "$bifrost_cli_dir/stderr" \
  --env "BIFROST_LAUNCH_DIR=$bifrost_cli_dir" --args "$@"
bifrost_launch_status=$?
if [ "$bifrost_launch_status" -eq 0 ]; then
  bifrost_start_ticks=0
  while [ ! -f "$bifrost_cli_dir/status" ]; do
    if [ -f "$bifrost_cli_dir/pid" ]; then
      bifrost_app_pid=$(cat "$bifrost_cli_dir/pid")
      case "$bifrost_app_pid" in
        ''|*[!0-9]*) bifrost_launch_status=1; break ;;
      esac
      if ! kill -0 "$bifrost_app_pid" 2>/dev/null; then
        # Prefer a completion receipt that arrived with the exit notification.
        [ -f "$bifrost_cli_dir/status" ] && break
        echo 'bifrost: application exited without reporting completion' >&2
        bifrost_launch_status=1; break
      fi
    else
      bifrost_start_ticks=$((bifrost_start_ticks+1))
      if [ "$bifrost_start_ticks" -ge 200 ]; then
        echo 'bifrost: timed out waiting for application startup' >&2
        bifrost_launch_status=1; break
      fi
    fi
    sleep 0.05
  done
  if [ -f "$bifrost_cli_dir/status" ]; then
    bifrost_launch_status=$(cat "$bifrost_cli_dir/status")
    case "$bifrost_launch_status" in
      0|1) ;;
      *) bifrost_launch_status=1 ;;
    esac
  fi
fi
if [ -f "$bifrost_cli_dir/stdout" ]; then cat "$bifrost_cli_dir/stdout"; fi
if [ -f "$bifrost_cli_dir/stderr" ]; then cat "$bifrost_cli_dir/stderr" >&2; fi
exit "$bifrost_launch_status"
