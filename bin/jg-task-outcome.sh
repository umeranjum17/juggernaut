#!/usr/bin/env bash
# jg-task-outcome.sh - append one durable task-outcome line to
# <home>/data/metrics/task-outcomes.tsv for per-model fleet statistics.
# Usage: jg-task-outcome.sh <task-id> [--force]
#
# Called best-effort by bin/jg-teardown.sh before the task's status and record are
# retired; a write failure never blocks or fails teardown, and this script itself
# only ever exits non-zero on a usage error.
#
# One tab-separated row per ended task; the first line is the header:
#   home     the home that ran the task: "main" or the squad_lead id whose home
#            has the .jg-squad-lead-home marker.
#   task     the task id.
#   kind     ship | scout (squad_lead retirements are not tasks and are skipped).
#   project  the project directory basename, or "-" when none is recorded.
#   models   every harness:model:effort the task ran on, in launch order, joined by
#            ";", read from state/<id>.models, which bin/jg-spawn.sh starts anew on
#            every fresh spawn and appends to on every relaunch; falls back to the
#            record's final harness/model/effort when no history file exists.
#   started  unix seconds of the first recorded launch (history file first line,
#            else the spawn_gen epoch, else the record's mtime); empty when unknown.
#   ended    unix seconds when this cleanup ran.
#   outcome  merged | closed | cancelled | scout | failed: a non-forced teardown only
#            proceeds on landed work, so "merged" also covers a local-only landing;
#            "closed" is a discarded task with a recorded PR, "cancelled" one with
#            none, "failed" one whose last status verb was failed, "scout" a scout
#            whose report is the product.
#   pr       the recorded PR URL, else empty.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -eq 0 ] || [ -f "${JG_STATE_OVERRIDE:-${JG_HOME:-${JG_ROOT_OVERRIDE:-$SCRIPT_DIR/..}}/state}/$1.meta" ] || exit 0
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"

usage() {
  echo "usage: jg-task-outcome.sh <task-id> [--force]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
ID=$1
shift
FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    *) usage ;;
  esac
  shift
done
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) usage ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0

meta_get() {  # <key>
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$META" 2>/dev/null || true
}

clean_field() {  # collapse tabs/newlines so one task stays one row
  printf '%s' "$1" | tr '\t\n' '  '
}

KIND=$(meta_get kind)
[ -n "$KIND" ] || KIND=ship
[ "$KIND" = squad_lead ] && exit 0
case "$KIND" in ship | scout) ;; *) KIND=ship ;; esac

PROJECT=$(meta_get project)
PROJECT=${PROJECT%/}
PROJECT=${PROJECT##*/}
[ -n "$PROJECT" ] || PROJECT=-

PR=$(awk -F= '$1 == "pr" { sub(/^[^=]*=/, ""); v=$0 } END { print v }' "$META" 2>/dev/null || true)

if [ -f "$(jg_compat_marker "$JG_HOME")" ] && [ ! -L "$(jg_compat_marker "$JG_HOME")" ]; then
  HOME_NAME=$(head -n 1 "$(jg_compat_marker "$JG_HOME")" 2>/dev/null | tr -d '\r\n')
else
  HOME_NAME=main
fi
[ -n "$HOME_NAME" ] || HOME_NAME=main

HISTORY="$STATE/$ID.models"
MODELS=
STARTED=
if [ -f "$HISTORY" ] && [ ! -L "$HISTORY" ]; then
  MODELS=$(awk -F'\t' 'NF >= 4 { gsub(/[\t\n]/, "", $2); gsub(/[\t\n]/, "", $3); gsub(/[\t\n]/, "", $4);
    printf "%s%s:%s:%s", (n++ ? ";" : ""), ($2 == "" ? "default" : $2), ($3 == "" ? "default" : $3), ($4 == "" ? "default" : $4) }' "$HISTORY" 2>/dev/null || true)
  STARTED=$(awk -F'\t' 'NF >= 1 && $1 ~ /^[0-9]+$/ { print $1; exit }' "$HISTORY" 2>/dev/null || true)
fi
if [ -z "$MODELS" ]; then
  H=$(meta_get harness); M=$(meta_get model); E=$(meta_get effort)
  MODELS="${H:-default}:${M:-default}:${E:-default}"
fi
if [ -z "$STARTED" ]; then
  SPAWN_GEN=$(meta_get spawn_gen)
  case "$SPAWN_GEN" in
    s[0-9]*)
      STARTED=${SPAWN_GEN#s}
      STARTED=${STARTED%%.*}
      case "$STARTED" in ''|*[!0-9]*) STARTED= ;; esac
      ;;
  esac
fi
if [ -z "$STARTED" ]; then
  STARTED=$(stat -c %Y "$META" 2>/dev/null || stat -f %m "$META" 2>/dev/null || true)
  case "$STARTED" in ''|*[!0-9]*) STARTED= ;; esac
fi

ENDED=$(date +%s)

OUTCOME=merged
if [ "$KIND" = scout ]; then
  OUTCOME=scout
elif [ "$FORCE" = 1 ]; then
  STATUS="$STATE/$ID.status"
  LAST_VERB=
  if [ -f "$STATUS" ] && [ ! -L "$STATUS" ]; then
    LAST_VERB=$(awk 'NF { last = $0 } END {
      if (last == "") exit
      sub(/^[0-9]+[ \t]+/, "", last)
      sub(/:.*/, "", last)
      sub(/\[.*/, "", last)
      gsub(/^[ \t]+|[ \t]+$/, "", last)
      print last }' "$STATUS" 2>/dev/null || true)
  fi
  if [ "$LAST_VERB" = failed ]; then
    OUTCOME=failed
  elif [ -n "$PR" ]; then
    OUTCOME=closed
  else
    OUTCOME=cancelled
  fi
fi

OUT="$DATA/metrics/task-outcomes.tsv"
mkdir -p "$DATA/metrics" 2>/dev/null || exit 0
LOCK="$OUT.lock"
jg_lock_acquire_wait_max "$LOCK" 30 2>/dev/null || exit 0
trap 'jg_lock_release "$LOCK" 2>/dev/null || true' EXIT
if [ -f "$OUT" ] && awk -F'\t' -v h="$(clean_field "$HOME_NAME")" -v t="$(clean_field "$ID")" -v s="$STARTED" \
  'NR > 1 && $1 == h && $2 == t && $6 == s { found = 1 } END { exit !found }' "$OUT" 2>/dev/null; then
  exit 0
fi
if [ ! -f "$OUT" ]; then
  printf 'home\ttask\tkind\tproject\tmodels\tstarted\tended\toutcome\tpr\n' > "$OUT" 2>/dev/null || exit 0
fi
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(clean_field "$HOME_NAME")" "$(clean_field "$ID")" "$KIND" "$(clean_field "$PROJECT")" \
    "$(clean_field "$MODELS")" "$STARTED" "$ENDED" "$OUTCOME" "$(clean_field "$PR")"
} >> "$OUT" 2>/dev/null || exit 0
