#!/usr/bin/env bash
# jg-whats-left.sh - the standing view of what is left.
#
# Usage: jg-whats-left.sh [write|show]
#
#   write  (default) render state/whats-left.md and print nothing.
#   show   print the view; first re-render it when any backlog or status record
#          is newer than the file, so a look never shows a stale list. A home on
#          Beads re-renders on every look.
#
# The view is a projection of jg-bearings-snapshot.sh, which reads the records
# that already exist (backlog, task status, captain holds). It keeps no list of
# its own. It has three sections: open work, what queued work waits on, and what
# waits on a person. jg-home-summary-refresh.sh calls `write` after every
# publication, so the view follows a record change with no manual step.
# Publication is atomic: a reader sees the old file or the new one, never a torn one.
# JG_WHATS_LEFT_TIMEOUT (default 45 seconds) bounds one render.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
VIEW="$STATE/whats-left.md"
TIMEOUT=${JG_WHATS_LEFT_TIMEOUT:-45}
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=45 ;; esac
# shellcheck source=bin/jg-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-timeout-lib.sh"
# shellcheck source=bin/jg-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-tasks-axi-lib.sh"

case "${1:-write}" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  write|show) MODE=${1:-write} ;;
  *) echo "usage: jg-whats-left.sh [write|show]" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "jg-whats-left: jq not found" >&2; exit 1; }

render() {
  local json tmp
  mkdir -p "$STATE" || return 1
  json=$(mktemp "$STATE/.whats-left.json.XXXXXX") || return 1
  tmp=$(mktemp "$STATE/.whats-left.md.XXXXXX") || { rm -f -- "$json"; return 1; }
  if ! jg_run_timed "$TIMEOUT" env JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
      JG_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/jg-bearings-snapshot.sh" --json \
      --all-in-flight --all-queued --all-decisions >"$json" 2>/dev/null; then
    rm -f -- "$json" "$tmp"; echo "jg-whats-left: the bearings read failed" >&2; return 1
  fi
  if ! jq -r '
    def row($a): "- " + $a;
    def or_dash: if . == null or . == "" or . == "-" then null else . end;
    "# What is left\n",
    "Updated " + (.generated // "unknown") + ". Built from the backlog, task status and captain holds; edit those, not this file.\n",
    "## Waiting on a person (\(.decisions_open | length))",
    (if (.decisions_open | length) == 0 then "- nothing" else
      (.decisions_open[] | row("\(.summary // .id)  [\(.id)]")) end),
    "",
    "## Open work (\(.in_flight | length))",
    (if (.in_flight | length) == 0 then "- nothing under way" else
      (.in_flight[] | row("\(.name // .id)  [\(.id)] - \(.doing // .state // "under way")")) end),
    "",
    "## Queued, and what each waits on (\(.gates | length))",
    (if (.gates | length) == 0 then "- nothing queued" else
      (.gates[] | row("\(.title // .id)  [\(.id)] - waits on "
        + ((.blocked_by | or_dash) // (.reason | or_dash) // "a free slot"))) end)
  ' "$json" >"$tmp"; then
    rm -f -- "$json" "$tmp"; echo "jg-whats-left: render failed" >&2; return 1
  fi
  rm -f -- "$json"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$VIEW" || { rm -f -- "$tmp"; return 1; }
}

stale() {
  [ -s "$VIEW" ] || return 0
  ! jg_backlog_backend_beads "$CONFIG" || return 0  # A store has no file age to compare, so each look renders.
  [ -n "$(find "$DATA/backlog.md" "$STATE" -maxdepth 1 \( -name backlog.md -o -name '*.status' -o -name '*.meta' \) -newer "$VIEW" -print -quit 2>/dev/null)" ]
}

if [ "$MODE" = show ]; then
  if stale; then render || [ -s "$VIEW" ] || exit 1; fi
  cat -- "$VIEW"
else
  render
fi
