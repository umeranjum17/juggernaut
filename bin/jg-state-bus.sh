#!/usr/bin/env bash
# jg-state-bus.sh - the per-task leases and busy events on NATS JetStream
# key-value, in shadow: both paths run at once and the files stay authoritative.
#
# WHY THIS EXISTS (migration step 5e). A lease (state/.lease-<task>) and a busy
# event (state/<id>.busy-state plus its <id>.busy-gen sidecar) are two small
# records a second supervision actor and every adapter hook contend for, and each
# carries expiry semantics. Today that costs a directory lock, a gen validation,
# an atomic replace and a sweep that clears the stale records. The decided shape
# is a JetStream key-value bucket: one key per record, its revision replacing the
# writer lock, its own delete replacing the stale sweep, and a watch replacing
# the poll. This step only proves the bucket reproduces what the file path
# reports; nothing switches, and this script writes nothing to the file path.
#
# docs/state-shadow.md owns the record model, the parity contract, the measured
# line count of each path and what a switch would remove. This script is the one
# owner of the shadow's mechanics: the snapshot of the file path, the key layout,
# the mirror, the bucket-side claim, and the replay that compares them.
#
# CONTRACT (this header is the one owner of the shadow's shape).
#   config   a home enables the mirror with config/state-bus; the same file may
#            set `nats-url <url>`, and JG_STATE_BUS_URL overrides both. No file
#            means off and every command says so and exits 0, so a home without
#            a bus behaves exactly as before.
#   buckets  JG_LEASES carries jg.leases.>, JG_BUSY carries jg.busy.>, both file
#            storage with KV_HISTORY revisions kept per key, so a watcher can see
#            the transitions a record went through. The bucket names are fixed
#            here so a replay reads the buckets a mirror wrote.
#   keys     lease/<home>/<task> and busy/<home>/<task>. <home> is the home's
#            directory name plus the first 8 hex digits of its path hash, so two
#            homes that both run a task named `lane-a` never share a key and the
#            key stays inside the charset a KV key accepts.
#   values   the file path's own bytes, never a re-encoding: a lease key holds the
#            lease line unchanged, and a busy key holds the gen sidecar's line
#            followed by the record's line. So "the same owner identity at the
#            same instant" is a byte comparison, and both sides are judged by the
#            same reader functions rather than by a second copy of the rules.
#   expiry   the file path's expiry rule is the lease's liveness (recorded pid
#            alive and the session-lock holder) and the busy record's armed gen,
#            never a clock. The mirror therefore expires nothing on its own: it
#            carries the record and deletes the key when the file path deletes the
#            record. A bucket TTL would be a different behaviour - a live holder
#            would expire - so it belongs to the switch, not to this step, and
#            docs/state-shadow.md names that gap.
#   write    nothing here writes to the file path. No lease, gen sidecar, record,
#            progress marker or lock is created, changed or removed; the replay
#            writes only into a snapshot copy under the temporary directory. A
#            missing client or server prints `skip: ...` and exits 0.
#
# Usage:
#   jg-state-bus.sh sync                     mirror this home's leases and busy records
#   jg-state-bus.sh parity [--corrupt]       replay both paths and compare them
#
# Options: --home DIR (repeatable) resolves a home and its state directory and
# never writes to it; --corrupt tampers with one bucket value before the
# comparison, which parity must then report as a difference, so a green run is
# never vacuous.
#
# Env: JG_STATE_BUS_URL, JG_STATE_BUS_SHADOW=on, JG_NATS_BIN.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-${JG_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-${STATE:-$JG_HOME/state}}"
# shellcheck source=bin/jg-lease-lib.sh
. "$SCRIPT_DIR/jg-lease-lib.sh"
# shellcheck source=bin/jg-busy-lib.sh
. "$SCRIPT_DIR/jg-busy-lib.sh"

LEASE_BUCKET=JG_LEASES
BUSY_BUCKET=JG_BUSY
KV_HISTORY=8
CORRUPT=0
CMD=
HOMES=()

# config_get <home> <key> <default>: the value in force, from JG_STATE_BUS_<KEY>,
# then the home's config/state-bus, then the default this function's caller names.
config_get() { # <home-dir> <key> <default>
  local var value
  var="JG_STATE_BUS_$(printf '%s' "$2" | tr 'a-z-' 'A-Z_')"
  value=$(eval "printf '%s' \"\${$var:-}\"")
  if [ -z "$value" ] && [ -f "$1/config/state-bus" ]; then
    value=$(awk -v k="$2" '$1 == k { sub(/^[^ ]+[ \t]+/, ""); print; exit }' "$1/config/state-bus" 2>/dev/null)
  fi
  printf '%s\n' "${value:-$3}"
}

kv() { # one client call against the bus; the server address is always explicit
  "$BUS_NATS" -s "$BUS_URL" --timeout 10s kv "$@"
}

# bus_gate: resolve the client and prove the server answers, or say why not. It
# never fails the caller: a home with no bus must behave exactly as before.
bus_gate() {
  if [ -n "${JG_NATS_BIN:-}" ]; then BUS_NATS=$JG_NATS_BIN; else BUS_NATS=$(command -v nats 2>/dev/null || true); fi
  if [ -z "${BUS_NATS:-}" ]; then
    printf 'skip: nats client not found (set JG_NATS_BIN)\n'
    return 1
  fi
  if ! kv ls >/dev/null 2>&1; then
    printf 'skip: no bus at %s\n' "$BUS_URL"
    return 1
  fi
}

bus_ensure_buckets() {
  local b
  for b in "$LEASE_BUCKET" "$BUSY_BUCKET"; do
    kv info "$b" >/dev/null 2>&1 || kv add "$b" --history "$KV_HISTORY" --storage file >/dev/null 2>&1 || return 1
  done
}

kv_get() { # <bucket> <key>: the value's bytes on stdout, failure when absent
  kv get "$1" "$2" --raw 2>/dev/null
}

kv_put() { # <bucket> <key>; the value arrives on stdin
  kv put "$1" "$2" >/dev/null 2>&1
}

kv_del() { # <bucket> <key>
  kv del -f "$1" "$2" >/dev/null 2>&1 || true
}

kv_keys() { # <bucket> <prefix>: the keys this bucket holds under one prefix
  kv ls "$1" 2>/dev/null | awk -v p="$2" 'index($0, p) == 1' || true
}

sha256_of() { # stdin
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

# home_key <state-dir>: a stable short name for one home, so one bucket keeps two
# homes' identical task names apart. A KV key admits no colon, so the path hash
# is joined to the directory name with a dash.
home_key() { # <state-dir>
  local home
  home=$(dirname "$1")
  printf '%s-%s\n' "$(basename "$home")" "$(printf '%s' "$home" | sha256_of | cut -c1-8)"
}

# dead_pid: a pid no process holds, so a replay can pin a definitely expired
# record without depending on what this machine happens to be running.
dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do p=$((p + 1)); done
  printf '%s\n' "$p"
}

# --- the file path's instant -------------------------------------------------
# snapshot_home <state-dir> <out-dir>: copy the records the file path holds, and
# the lock that gives them their liveness, into a directory of the same shape.
# Both sides of the replay are judged from this one instant, so a release or an
# expiry that lands while the check runs cannot be reported as a difference and
# does not need churn accounting. A torn or foreign record is not a claim and is
# not copied; the .lease-* surface also holds other homes' index files, and the
# lease reader's own validation is what keeps them out.
snapshot_home() { # <state-dir> <out-dir>
  local st=$1 out=$2 f task
  mkdir -p "$out" || return 1
  [ ! -f "$st/.lock" ] || cp "$st/.lock" "$out/.lock" 2>/dev/null || true
  STATE=$st
  for f in "$st"/.lease-*; do
    [ -f "$f" ] || continue
    task=${f##*/.lease-}
    jg_lease_valid_id "$task" || continue
    jg_lease_read "$task" || continue
    [ -n "$JG_LEASE_ACTOR" ] || continue
    [ -n "$JG_LEASE_PID" ] || continue
    case "$JG_LEASE_PID$JG_LEASE_EPOCH" in *[!0-9]*) continue ;; esac
    cp "$f" "$out/.lease-$task" || return 1
  done
  for f in "$st"/*.busy-gen; do
    [ -f "$f" ] || continue
    task=${f##*/}
    task=${task%.busy-gen}
    jg_busy_record_read "$st" "$task" >/dev/null 2>&1 || continue
    cat "$f" > "$out/$task.busy-gen" || return 1
    cat "$st/$task.busy-state" > "$out/$task.busy-state" || return 1
  done
}

# rows_of <snapshot-dir> <home-key>: one canonical row per record this directory
# holds, read by the same functions the file path uses.
#   lease <home> <task> <actor> <pid> <live|stale>
#   busy  <home> <task> <gen> <state> <source> <event> <seq>
#   busy  <home> <task> <gen> <reason>
rows_of() { # <dir> <home-key>
  local dir=$1 hk=$2 f task out gen liv
  local -a field
  STATE=$dir
  for f in "$dir"/.lease-*; do
    [ -f "$f" ] || continue
    task=${f##*/.lease-}
    jg_lease_valid_id "$task" || continue
    jg_lease_read "$task" || continue
    [ -n "$JG_LEASE_ACTOR" ] || continue
    if jg_lease_live "$task"; then liv=live; else liv=stale; fi
    printf 'lease\t%s\t%s\t%s\t%s\t%s\n' "$hk" "$task" "$JG_LEASE_ACTOR" "$JG_LEASE_PID" "$liv"
  done
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

# claim_rows <dir> <home-key> <file|bus>: replay the recorded claims. For every
# recorded lease, each actor claims it in turn: the holder's own claim is a
# refresh and must be granted, and the other actor's claim must be refused while
# the record is live and granted once it has expired. A file-side claim runs the
# shipped bin/jg-lease.sh against a copy of the state, so its refusal reason is
# the shipped one; a bus-side claim is the bucket's own claim, judged by the same
# expiry rule. The liveness context is the record's pid when that pid is alive and
# a definitely dead pid otherwise, because a recorded pid is a fact about the
# recording session, not about the claim.
claim_rows() { # <dir> <home-key> <file|bus>
  local dir=$1 hk=$2 source=$3 f task pid ctx lock_pid claimant rc out key reason
  STATE=$dir
  for f in "$dir"/.lease-*; do
    [ -f "$f" ] || continue
    task=${f##*/.lease-}
    jg_lease_valid_id "$task" || continue
    jg_lease_read "$task" || continue
    [ -n "$JG_LEASE_ACTOR" ] || continue
    pid=$JG_LEASE_PID
    if kill -0 "$pid" 2>/dev/null; then lock_pid=$pid; else lock_pid=$(dead_pid); fi
    for claimant in main branch; do
      ctx=$(mktemp -d "${TMPDIR:-/tmp}/jg-state-bus-claim.XXXXXX") || return 1
      printf '%s\n' "$lock_pid" > "$ctx/.lock"
      cp "$f" "$ctx/.lease-$task"
      if [ "$source" = file ]; then
        JG_STATE_OVERRIDE="$ctx" JG_SUPERVISION_ACTOR=$claimant \
          "$SCRIPT_DIR/jg-lease.sh" claim "$task" --actor "$claimant" >/dev/null 2>&1
        rc=$?
        case "$rc" in
          0)
            out=$(JG_STATE_OVERRIDE="$ctx" "$SCRIPT_DIR/jg-lease.sh" check "$task" 2>/dev/null || true)
            printf 'claim\t%s\t%s\t%s\tgranted\t%s\n' "$hk" "$task" "$claimant" "${out%% *}"
            ;;
          6) printf 'claim\t%s\t%s\t%s\trefused\theld-by-other\n' "$hk" "$task" "$claimant" ;;
          *) printf 'claim\t%s\t%s\t%s\trefused\terror-%s\n' "$hk" "$task" "$claimant" "$rc" ;;
        esac
      else
        key="replay/lease/$hk/$task/$claimant"
        kv_put "$LEASE_BUCKET" "$key" < "$f" || { rm -rf -- "$ctx"; return 1; }
        out=$(kv_claim "$key" "$task" "$claimant" "$ctx")
        kv_del "$LEASE_BUCKET" "$key"
        case "$out" in
          "granted "*) printf 'claim\t%s\t%s\t%s\tgranted\t%s\n' "$hk" "$task" "$claimant" "${out#granted }" ;;
          "refused "*) reason=${out#refused }; printf 'claim\t%s\t%s\t%s\trefused\t%s\n' "$hk" "$task" "$claimant" "$reason" ;;
          *) printf 'claim\t%s\t%s\t%s\trefused\terror-empty\n' "$hk" "$task" "$claimant" ;;
        esac
      fi
      rm -rf -- "$ctx"
    done
  done
}

# kv_claim <key> <task> <claimant> <context-dir>: the bucket's claim. It reads the
# one value the key holds and applies the file path's own expiry rule to it, so a
# live lease held by the other actor is refused and an expired one is replaced.
# Prints "granted <actor>" or "refused <reason>".
kv_claim() { # <key> <task> <claimant> <context-dir>
  local key=$1 task=$2 claimant=$3 ctx=$4 val lock_pid
  val=$(kv_get "$LEASE_BUCKET" "$key" || true)
  if [ -n "$val" ]; then
    printf '%s\n' "$val" > "$ctx/.lease-$task"
    STATE=$ctx
    if jg_lease_live "$task" && [ "$JG_LEASE_ACTOR" != "$claimant" ]; then
      printf 'refused held-by-other\n'
      return 0
    fi
  fi
  lock_pid=$(head -n 1 "$ctx/.lock" 2>/dev/null | tr -cd '0-9' || true)
  printf '%s\t%s\t%s\n' "$claimant" "${lock_pid:-0}" "$(date +%s)" \
    | kv_put "$LEASE_BUCKET" "$key"
  printf 'granted %s\n' "$claimant"
}

# --- the bus path ------------------------------------------------------------
# restore_bus <snapshot-dir> <out-dir> <home-key>: pull every key this home holds
# from the bucket into a directory of the file path's shape, with the instant's
# lock, so the readers that judge the file path judge the bucket's answer too.
restore_bus() { # <snapshot-dir> <out-dir> <home-key>
  local snap=$1 out=$2 hk=$3 key task val
  mkdir -p "$out" || return 1
  [ ! -f "$snap/.lock" ] || cp "$snap/.lock" "$out/.lock" 2>/dev/null || true
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    task=${key##*/}
    val=$(kv_get "$LEASE_BUCKET" "$key" || true)
    [ -n "$val" ] || continue
    printf '%s\n' "$val" > "$out/.lease-$task"
  done <<EOF
$(kv_keys "$LEASE_BUCKET" "lease/$hk/")
EOF
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    task=${key##*/}
    val=$(kv_get "$BUSY_BUCKET" "$key" || true)
    [ -n "$val" ] || continue
    printf '%s\n' "$val" | head -n 1 > "$out/$task.busy-gen"
    printf '%s\n' "$val" | tail -n +2 > "$out/$task.busy-state"
  done <<EOF
$(kv_keys "$BUSY_BUCKET" "busy/$hk/")
EOF
}

# sync_snapshot <state-dir> <snapshot-dir>: publish every record the snapshot
# holds and delete the keys the file path no longer holds, so a release and an
# expiry reach the bucket as the delete a watcher would see. Prints "<leases>
# <busy>" on stdout. A value that already matches is not republished, so a poll
# cannot flood a watcher with unchanged records.
sync_snapshot() { # <state-dir> <snapshot-dir>
  local st=$1 out=$2 hk f task key val nlease=0 nbusy=0
  hk=$(home_key "$st")
  for f in "$out"/.lease-*; do
    [ -f "$f" ] || continue
    task=${f##*/.lease-}
    key="lease/$hk/$task"
    val=$(kv_get "$LEASE_BUCKET" "$key" || true)
    if [ "$val" != "$(cat "$f")" ]; then
      kv_put "$LEASE_BUCKET" "$key" < "$f" || return 1
    fi
    nlease=$((nlease + 1))
  done
  for f in "$out"/*.busy-gen; do
    [ -f "$f" ] || continue
    task=${f##*/}
    task=${task%.busy-gen}
    key="busy/$hk/$task"
    val=$(kv_get "$BUSY_BUCKET" "$key" || true)
    if [ "$val" != "$(cat "$out/$task.busy-gen" "$out/$task.busy-state")" ]; then
      { cat "$out/$task.busy-gen"; cat "$out/$task.busy-state"; } \
        | kv_put "$BUSY_BUCKET" "$key" || return 1
    fi
    nbusy=$((nbusy + 1))
  done
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    task=${key##*/}
    [ -f "$out/.lease-$task" ] || kv_del "$LEASE_BUCKET" "$key"
  done <<EOF
$(kv_keys "$LEASE_BUCKET" "lease/$hk/")
EOF
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    task=${key##*/}
    [ -f "$out/$task.busy-gen" ] || kv_del "$BUSY_BUCKET" "$key"
  done <<EOF
$(kv_keys "$BUSY_BUCKET" "busy/$hk/")
EOF
  printf '%s %s\n' "$nlease" "$nbusy"
}

# corrupt_one: tamper with one published value, so a run that still reported no
# difference would be a vacuous check. A lease's actor is flipped, which moves
# both its own row and the verdicts of the claims replayed against it; a busy
# record's state is rewritten when the fleet holds no lease to flip.
corrupt_one() {
  local key val
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    val=$(kv_get "$LEASE_BUCKET" "$key" || true)
    [ -n "$val" ] || continue
    printf '%s\n' "$val" | awk -F'\t' -v OFS='\t' '{ $1 = ($1 == "main" ? "branch" : "main"); print }' \
      | kv_put "$LEASE_BUCKET" "$key" && return 0
  done <<EOF
$(kv_keys "$LEASE_BUCKET" 'lease/')
EOF
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    val=$(kv_get "$BUSY_BUCKET" "$key" || true)
    [ -n "$val" ] || continue
    printf '%s\n' "$val" | sed 's/ state=[^ ]*/ state=unknown/' | kv_put "$BUSY_BUCKET" "$key" && return 0
  done <<EOF
$(kv_keys "$BUSY_BUCKET" 'busy/')
EOF
  return 1
}

# --- subcommands -------------------------------------------------------------
cmd_sync() {
  local st out counts nlease nbusy
  bus_gate || return 0
  bus_ensure_buckets || { printf 'skip: cannot create the buckets on %s\n' "$BUS_URL"; return 0; }
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
    nlease=${counts%% *}
    nbusy=${counts##* }
    printf 'state shadow mirror: leases=%s busy=%s home=%s\n' \
      "$nlease" "$nbusy" "$(dirname "$st")"
  done
}

# cmd_parity: replay the instant through both paths and compare them row by row.
# Every row names the record and the field, so a difference is readable where it
# is printed. --corrupt tampers with one bucket value first, so a run that still
# reported no difference would mean the check cannot see anything.
cmd_parity() {
  local base st hk compared diffs=0
  # Unlike the mirror, this is an explicit check, so a bus it cannot reach is a
  # failure rather than a skip: a parity that did not run has proven nothing, and
  # must never be readable as the green run the switch waits for.
  bus_gate || { printf 'state shadow parity: not run, so nothing is proven\n'; return 1; }
  bus_ensure_buckets || {
    printf 'state shadow parity: not run, cannot create the buckets on %s\n' "$BUS_URL"
    return 1
  }
  base=$(mktemp -d "${TMPDIR:-/tmp}/jg-state-bus-parity.XXXXXX") || return 1
  for st in "${HOMES[@]}"; do
    hk=$(home_key "$st")
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
    hk=$(home_key "$st")
    rows_of "$base/snap/$hk" "$hk" >> "$base/file-rows"
    claim_rows "$base/snap/$hk" "$hk" file >> "$base/file-rows"
    restore_bus "$base/snap/$hk" "$base/bus/$hk" "$hk" || { rm -rf -- "$base"; return 1; }
    rows_of "$base/bus/$hk" "$hk" >> "$base/bus-rows"
    claim_rows "$base/bus/$hk" "$hk" bus >> "$base/bus-rows"
  done
  LC_ALL=C sort -o "$base/file-rows" "$base/file-rows"
  LC_ALL=C sort -o "$base/bus-rows" "$base/bus-rows"
  compared=$(awk 'END { print NR }' "$base/file-rows")
  if ! diff -u "$base/file-rows" "$base/bus-rows" > "$base/diff" 2>&1; then
    diffs=$(grep -cE '^[+-][^+-]' "$base/diff" || true)
    grep -E '^[+-][^+-]' "$base/diff" | head -n 20
  fi
  printf 'state shadow parity: homes=%s events_compared=%s differences=%s\n' \
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
HOME_DIR=$(dirname "${HOMES[0]}")
BUS_URL=$(config_get "$HOME_DIR" nats-url "nats://127.0.0.1:4222")
[ -n "${JG_STATE_BUS_URL:-}" ] && BUS_URL=$JG_STATE_BUS_URL

# The mirror is opt-in: a home turns it on with config/state-bus, or with
# JG_STATE_BUS_SHADOW=on for a run that must not write into that home.
if [ "$CMD" = sync ] && [ ! -f "$HOME_DIR/config/state-bus" ] \
  && [ "$(config_get "$HOME_DIR" shadow off)" != on ]; then
  printf 'skip: state bus shadow not enabled (config/state-bus)\n'
  exit 0
fi

case "$CMD" in
  sync) cmd_sync "${HOMES[@]}" ;;
  parity) cmd_parity ;;
esac
