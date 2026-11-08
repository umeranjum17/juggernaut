#!/usr/bin/env bash
# jg-owner-correction.sh - the owner-correction capture check the turn-end guard
# reads: has the newest recorded owner correction been captured by an owner rule
# or an enforcement ticket yet? docs/turnend-guard.md "Owner-correction capture
# rule" owns the contract.
#
# Usage: jg-owner-correction.sh pending
#   Print "<seq>\t<epoch>\t<kind>\t<text>" and exit 0 when the recorded
#   correction has no captured artefact yet; exit 1 when nothing is pending.
#   Exit 2 means the check could not run (no jq), never "nothing pending".
#
# The record is the newest captain message in data/overwatch-kpi.jsonl whose
# newest tag kind is feedback or micromanagement: a record, never a reading of his
# tone. The artefacts are data/owner-rules.md written at or after it
# (bin/jg-owner-rules.sh add), or an enforcement ticket (bin/jg-backlog.sh add).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

mtime_of() {  # <path> -> epoch, when the path exists
  [ -e "$1" ] || return 1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

captured() {  # <epoch> -> 0 when a rule or a ticket landed at or after it
  local stamp newest
  for stamp in "$DATA/owner-rules.md" "$DATA/ticket-counters.tsv"; do
    stamp=$(mtime_of "$stamp") || stamp=
    [ -n "$stamp" ] && [ "$stamp" -ge "$1" ] && return 0
  done
  # A row's creation is a date, so a ticket filed earlier the same UTC day counts.
  # ponytail: day-granularity ticket evidence; add a per-ticket created epoch if a
  # same-day false capture ever matters.
  newest=$("$SCRIPT_DIR/jg-backlog.sh" list --fields created --limit 500 2>/dev/null \
    | grep -oE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' 2>/dev/null | LC_ALL=C sort | tail -1)
  [ -n "$newest" ] || return 1
  [[ ! $newest < $(date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F) ]]
}

# The recorded correction as "<seq>\t<epoch>\t<kind>\t<text>", empty when the
# newest captain message is absent, untagged, or tagged something other than a
# correction.
recorded_correction() {
  [ -f "$DATA/overwatch-kpi.jsonl" ] || return 1
  jq -Rrs '[split("\n")[] | fromjson? | select(type == "object")] as $r
    | ([$r[] | select(.seq | numbers)] | last) as $m
    | if $m == null then empty else ([$r[] | select(.tag == $m.seq)] | last) as $t
      | if $t == null then empty
        elif ($t.kind == "feedback" or $t.kind == "micromanagement") then
          "\($m.seq)\t\($m.epoch // 0)\t\($t.kind)\t\($m.text | gsub("\\s+"; " "))"
        else empty end end' "$DATA/overwatch-kpi.jsonl" 2>/dev/null
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  pending) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { printf 'jg-owner-correction: jq is required to read the captain-message record\n' >&2; exit 2; }

record=$(recorded_correction) || record=
[ -n "$record" ] || exit 1
epoch=${record#*$'\t'}
epoch=${epoch%%$'\t'*}
case "$epoch" in ''|*[!0-9]*) exit 1 ;; esac
captured "$epoch" && exit 1
printf '%s\n' "$record"
