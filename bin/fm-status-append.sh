#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: fm-status-append.sh [--once] <absolute-status-file> <one-line-event>" >&2
  exit 2
}

ONCE=0
if [ "${1:-}" = --once ]; then
  ONCE=1
  shift
fi
[ "$#" -eq 2 ] || usage
STATUS_FILE=$1
LINE=$2
case "$STATUS_FILE" in /*.status) ;; *) usage ;; esac
STATE=$(cd "$(dirname "$STATUS_FILE")" 2>/dev/null && pwd -P) || {
  echo "error: status directory does not exist: $(dirname "$STATUS_FILE")" >&2
  exit 1
}
[ "$STATUS_FILE" = "$STATE/${STATUS_FILE##*/}" ] || {
  echo "error: status path must use its canonical state directory" >&2
  exit 1
}

FM_STATE_OVERRIDE="$STATE"
export FM_STATE_OVERRIDE
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$ONCE" -eq 1 ]; then
  append_rc=0
  fm_wake_status_append_once "$STATE" "$STATUS_FILE" "$LINE" || append_rc=$?
  [ "$append_rc" -eq 1 ] && exit 0
else
  append_rc=0
  fm_wake_status_append "$STATE" "$STATUS_FILE" "$LINE" || append_rc=$?
fi
[ "$append_rc" -eq 0 ] || {
  echo "error: status event could not be appended safely" >&2
  exit 1
}
