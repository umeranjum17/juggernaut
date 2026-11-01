#!/usr/bin/env bash
# jg-state-bus.sh - the per-task busy events on NATS JetStream key-value, in
# shadow: both paths run at once and the files stay authoritative.
#
# WHY THIS EXISTS (migration step 5e). The task leases and the busy events are
# two small records with expiry semantics that a second supervision actor and
# every adapter hook contend for, and each cost a directory lock, a gen
# validation, an atomic replace and a sweep. The decided shape is a JetStream
# key-value bucket: one key per record, its revision in place of the writer lock,
# its own delete in place of the stale sweep, and a watch in place of the poll.
#
# The lease half of this step has SWITCHED: a task lease now lives in the bucket
# as its only record and the file path that mirrored it is gone
# (docs/state-shadow.md, "The lease path, live"). This script is what remains of
# the shadow - the busy events - and it proves the bucket reports the same busy
# record the file path holds before that half switches too.
#
# CONTRACT (this header is the one owner of the busy shadow's shape).
#   config   a home enables the mirror with config/state-bus; the same file may
#            set `nats-url <url>`. No file means off and every command says so and
#            exits 0, so a home without a bus behaves exactly as before.
#   bucket   JG_BUSY carries jg.busy.>, file storage with JG_KV_HISTORY revisions
#            kept per key, so a watcher can see the transitions a record went
#            through. The bucket name is fixed here so a replay reads the bucket a
#            mirror wrote; the client, the URL and the bucket creation belong to
#            bin/jg-kv-lib.sh.
#   keys     busy/<home>/<task>. <home> is the home's directory name plus the
#            first 8 hex digits of its path hash, so two homes that both run a
#            task named `lane-a` never share a key and the key stays inside the
#            charset a KV key accepts.
#   values   the file path's own bytes, never a re-encoding: the gen sidecar's
#            line followed by the record's line, so "the same record" is a byte
#            comparison and both sides are judged by the same reader functions
#            rather than by a second copy of the rules.
#   expiry   the busy record's expiry rule is its armed gen, never a clock. The
#            mirror therefore expires nothing on its own: it carries the record
#            and deletes the key when the file path deletes the record, so a
#            retire arrives as the delete a watcher observes.
#   write    nothing here writes to the file path. No gen sidecar, record or
#            progress marker is created, changed or removed; the replay writes
#            only into a snapshot copy under the temporary directory. A missing
#            client or server prints `skip: ...` and exits 0.
#
# Usage:
#   jg-state-bus.sh sync                     mirror this home's busy records
#   jg-state-bus.sh parity [--corrupt]       replay both paths and compare them
#
# Options: --home DIR (repeatable) resolves a home and its state directory and
# never writes to it; --corrupt tampers with one bucket value before the
# comparison, which parity must then report as a difference, so a green run is
# never vacuous.
#
# Env: JG_KV_URL / JG_STATE_BUS_URL, JG_STATE_BUS_SHADOW=on, JG_NATS_BIN.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-${JG_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-${STATE:-$JG_HOME/state}}"
# shellcheck source=bin/jg-busy-lib.sh
. "$SCRIPT_DIR/jg-busy-lib.sh"
# shellcheck source=bin/jg-kv-lib.sh
. "$SCRIPT_DIR/jg-kv-lib.sh"

BUSY_BUCKET=JG_BUSY
CORRUPT=0
CMD=
HOMES=()

# kv_gate: resolve the client and prove the server answers. The mirror is a
# shadow, so a home with no bus skips instead of failing; it never becomes a
# dependency.
kv_gate() {
  jg_kv_ready "$(dirname "${HOMES[0]}")" || { printf 'skip: %s\n' "$JG_KV_WHY"; return 1; }
  jg_kv_ensure_bucket "$BUSY_BUCKET" || { printf 'skip: %s\n' "$JG_KV_WHY"; return 1; }
}

# --- the file path's instant -------------------------------------------------
# snapshot_home <state-dir> <out-dir>: copy every busy record the file path holds
# into a directory of the same shape. Both sides of the replay are judged from
# this one instant, so a retire that lands while the check runs cannot be
# reported as a difference and does not need churn accounting.
snapshot_home() { # <state-dir> <out-dir>
  local st=$1 out=$2 f task
  mkdir -p "$out" || return 1
  for f in "$st"/*.busy-gen; do
    [ -f "$f" ] || continue
    task=${f##*/}
    task=${task%.busy-gen}
    jg_busy_record_read "$st" "$task" >/dev/null 2>&1 || continue
    cat "$f" > "$out/$task.busy-gen" || return 1
    cat "$st/$task.busy-state" > "$out/$task.busy-state" || return 1
  done
}

# rows_of <snapshot-dir> <home-key>: one canonical row per busy record this
# directory holds, read by the same functions the file path uses.
#   busy  <home> <task> <gen> <state> <source> <event> <seq>
#   busy  <home> <task> <gen> <reason>
rows_of() { # <dir> <home-key>
  local dir=$1 hk=$2 f task out gen
  local -a field
  STATE=$dir
  for f in "$dir"/*.busy-gen; do
    [ -f "$f" ] || continue
    task=${f##*/}
    task=${task%.busy-gen}
    gen=$(jg_busy_current_gen "$dir" "$task" 2>/dev/null || printf -- '-')
    if out=$(jg_busy_record_read "$dir" "$task"); then
      IFS=' ' read -r -a field <<< "$out"
      printf 'busy\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$hk" "$task" "$gen" "${field[0]}" "${field[1]}" "${field[2]}" "${field[3]}"
    else
      printf 'busy\t%s\t%s\t%s\t%s\n' "$hk" "$task" "$gen" "$out"
    fi
  done
}

# --- the bus path ------------------------------------------------------------
# restore_bus <snapshot-dir> <out-dir> <home-key>: pull every busy key this home
# holds from the bucket into a directory of the file path's shape, so the readers
# that judge the file path judge the bucket's answer too.
restore_bus() { # <snapshot-dir> <out-dir> <home-key>
  local out=$2 hk=$3 key task val
  mkdir -p "$out" || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    task=${key##*/}
    val=$(jg_kv_get "$BUSY_BUCKET" "$key" || true)
    [ -n "$val" ] || continue
    printf '%s\n' "$val" | head -n 1 > "$out/$task.busy-gen"
    printf '%s\n' "$val" | tail -n +2 > "$out/$task.busy-state"
  done <<EOF
$(jg_kv_keys "$BUSY_BUCKET" "busy/$hk/")
EOF
}

# sync_snapshot <state-dir> <snapshot-dir>: publish every busy record the
# snapshot holds and delete the keys the file path no longer holds, so a retire
# reaches the bucket as the delete a watcher would see. Prints the record count on
# stdout. A value that already matches is not republished, so a poll cannot flood
# a watcher with unchanged records.
sync_snapshot() { # <state-dir> <snapshot-dir>
  local st=$1 out=$2 hk f task key val nbusy=0
  hk=$(jg_kv_home_key "$st")
  for f in "$out"/*.busy-gen; do
    [ -f "$f" ] || continue
    task=${f##*/}
    task=${task%.busy-gen}
    key="busy/$hk/$task"
    val=$(jg_kv_get "$BUSY_BUCKET" "$key" || true)
    if [ "$val" != "$(cat "$out/$task.busy-gen" "$out/$task.busy-state")" ]; then
      { cat "$out/$task.busy-gen"; cat "$out/$task.busy-state"; } \
        | jg_kv_put "$BUSY_BUCKET" "$key" || return 1
    fi
    nbusy=$((nbusy + 1))
  done
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    task=${key##*/}
    [ -f "$out/$task.busy-gen" ] || jg_kv_del "$BUSY_BUCKET" "$key"
  done <<EOF
$(jg_kv_keys "$BUSY_BUCKET" "busy/$hk/")
EOF
  printf '%s\n' "$nbusy"
}

# corrupt_one: rewrite one published busy record's state, so a run that still
# reported no difference would be a vacuous check.
corrupt_one() {
  local key val
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    val=$(jg_kv_get "$BUSY_BUCKET" "$key" || true)
    [ -n "$val" ] || continue
    printf '%s\n' "$val" | sed 's/ state=[^ ]*/ state=unknown/' | jg_kv_put "$BUSY_BUCKET" "$key" && return 0
  done <<EOF
$(jg_kv_keys "$BUSY_BUCKET" 'busy/')
EOF
  return 1
}

# --- subcommands -------------------------------------------------------------
cmd_sync() {
  local st out counts
  kv_gate || return 0
  for st in "$@"; do
    out=$(mktemp -d "${TMPDIR:-/tmp}/jg-state-bus-sync.XXXXXX") || return 1
    if ! snapshot_home "$st" "$out"; then
      rm -rf -- "$out"
      return 1
    fi
    if ! counts=$(sync_snapshot "$st" "$out"); then
      rm -rf -- "$out"
      return 1
    fi
    rm -rf -- "$out"
    printf 'state shadow mirror: busy=%s home=%s\n' "$counts" "$(dirname "$st")"
  done
}

# cmd_parity: replay the instant through both paths and compare them row by row.
# Every row names the record and the field, so a difference is readable where it
# is printed. --corrupt tampers with one bucket value first, so a run that still
# reported no difference would mean the check cannot see anything.
cmd_parity() {
  local base st hk compared diffs=0
  # Unlike the mirror, this is an explicit check, so a bus it cannot reach is a
  # failure rather than a skip: a parity that did not run has proven nothing.
  kv_gate || { printf 'state shadow parity: not run, so nothing is proven\n'; return 1; }
  base=$(mktemp -d "${TMPDIR:-/tmp}/jg-state-bus-parity.XXXXXX") || return 1
  for st in "${HOMES[@]}"; do
    hk=$(jg_kv_home_key "$st")
    if ! snapshot_home "$st" "$base/snap/$hk" || ! sync_snapshot "$st" "$base/snap/$hk" >/dev/null; then
      rm -rf -- "$base"
      return 1
    fi
  done
  if [ "$CORRUPT" -eq 1 ] && ! corrupt_one; then
    printf 'state shadow parity: corrupt_target=none\n'
  fi
  : > "$base/file-rows"
  : > "$base/bus-rows"
  for st in "${HOMES[@]}"; do
    hk=$(jg_kv_home_key "$st")
    rows_of "$base/snap/$hk" "$hk" >> "$base/file-rows"
    restore_bus "$base/snap/$hk" "$base/bus/$hk" "$hk" || { rm -rf -- "$base"; return 1; }
    rows_of "$base/bus/$hk" "$hk" >> "$base/bus-rows"
  done
  LC_ALL=C sort -o "$base/file-rows" "$base/file-rows"
  LC_ALL=C sort -o "$base/bus-rows" "$base/bus-rows"
  compared=$(awk 'END { print NR }' "$base/file-rows")
  if ! diff -u "$base/file-rows" "$base/bus-rows" > "$base/diff" 2>&1; then
    diffs=$(grep -cE '^[+-][^+-]' "$base/diff" || true)
    grep -E '^[+-][^+-]' "$base/diff" | head -n 20
  fi
  printf 'state shadow parity: homes=%s records_compared=%s differences=%s\n' \
    "${#HOMES[@]}" "$compared" "${diffs:-0}"
  rm -rf -- "$base"
  # A run that compared nothing proves nothing, so it is not a pass: an empty
  # fleet must never be able to read a green parity as the switch's evidence.
  [ "$compared" -gt 0 ] || return 1
  [ "${diffs:-0}" -eq 0 ]
}

# --- arguments ---------------------------------------------------------------
h=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ -n "${2:-}" ] || { printf 'jg-state-bus.sh: --home needs a directory\n' >&2; exit 2; }
      h=$(cd "$2/state" 2>/dev/null && pwd) || {
        printf 'jg-state-bus.sh: no state directory under %s\n' "$2" >&2
        exit 2
      }
      HOMES+=("$h")
      shift 2
      ;;
    --corrupt) CORRUPT=1; shift ;;
    sync|parity) CMD=$1; shift ;;
    *) printf 'jg-state-bus.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$CMD" ] || { printf 'usage: jg-state-bus.sh [--home DIR] sync|parity [--corrupt] (see the header)\n' >&2; exit 2; }
if [ "${#HOMES[@]}" -eq 0 ]; then HOMES=("$STATE"); fi
for h in "${HOMES[@]}"; do
  [ -d "$h" ] || { printf 'jg-state-bus.sh: no state directory at %s\n' "$h" >&2; exit 2; }
done

# The mirror is opt-in: a home turns it on with config/state-bus, or with
# JG_STATE_BUS_SHADOW=on for a run that must not write into that home.
if [ "$CMD" = sync ] && [ ! -f "$(dirname "${HOMES[0]}")/config/state-bus" ] \
  && [ "${JG_STATE_BUS_SHADOW:-}" != on ]; then
  printf 'skip: state bus shadow not enabled (config/state-bus)\n'
  exit 0
fi

case "$CMD" in
  sync) cmd_sync "${HOMES[@]}" ;;
  parity) cmd_parity ;;
esac
