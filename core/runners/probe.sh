#!/usr/bin/env bash
# runners probe: ask one registered runner whether it can take work, and write one health row (H30a).
# Usage: probe.sh <jg-home> <id>      exit 0 and print `ok <id> free_cores=<n>`; exit 1 and print `failed <id>: <why>`
# The probe runs bin/jg-remote-doctor.sh on the runner through bin/jg-on.sh (the runner's record is the route), then checks:
#   the doctor exits 0 (every required tool resolves on the runner), reports `arch=` equal to the record's arch, and reports `cores=`
#   and `load1=`. Free cores = cores - load1, rounded down, never below 0. A runner with no free core still passes: it is busy, not lost.
# Any other outcome (ssh exit 255, doctor gap, arch mismatch, missing figure) is `failed` with the reason, and registry.sh usable then
# leaves the runner out until a later probe passes. Health file and its row format: registry.sh header.
# JG_RUNNER_PROBE_NOW is the clock (a test stand-in).
set -u
[ "$#" -eq 2 ] && [ -d "$1" ] || { echo "usage: probe.sh <jg-home> <id>" >&2; exit 2; }
HOME_DIR=$1
ID=$2
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${JG_ROOT_OVERRIDE:-$(cd "$DIR/../.." && pwd)}"
STATE="${JG_STATE_OVERRIDE:-$HOME_DIR/state}"
HEALTH="$STATE/runner-health.tsv"

record=$("$DIR/registry.sh" get "$HOME_DIR" "$ID" 2>&1) || { echo "failed $ID: ${record#error: }" >&2; exit 1; }
want_arch=$(printf '%s\n' "$record" | sed -n 's/^arch=//p')

row() { # <ok|failed> <free cores> <why>
  mkdir -p "$STATE" || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "${JG_RUNNER_PROBE_NOW:-$(date +%s)}" "$ID" "$1" "$2" "$3" >> "$HEALTH"
}
fail() {
  row failed 0 "$1" || echo "error: could not write $HEALTH" >&2
  echo "failed $ID: $1"
  exit 1
}

out=$(JG_HOME="$HOME_DIR" "$ROOT/bin/jg-on.sh" "$ID" jg-remote-doctor.sh 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || fail "the doctor exited $rc$([ "$rc" -eq 255 ] && echo ' (no connection)')"
got_arch=$(printf '%s\n' "$out" | sed -n 's/^arch=//p' | head -n1)
cores=$(printf '%s\n' "$out" | sed -n 's/^cores=//p' | head -n1)
load1=$(printf '%s\n' "$out" | sed -n 's/^load1=//p' | head -n1)
[ "$got_arch" = "$want_arch" ] || fail "arch is '${got_arch:-unreported}', the record says $want_arch"
case "$cores" in ''|*[!0-9]*) fail "the doctor reported no core count" ;; esac
case "$load1" in ''|*[!0-9.]*|*.*.*) fail "the doctor reported no load" ;; esac
free=$(awk -v c="$cores" -v l="$load1" 'BEGIN { f = int(c - l); print (f < 0 ? 0 : f) }')
row ok "$free" "" || { echo "failed $ID: could not write $HEALTH"; exit 1; }
echo "ok $ID free_cores=$free"
