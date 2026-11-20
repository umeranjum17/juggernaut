#!/usr/bin/env bash
# Present durable watcher wake records, retire rows no actor could ever consume,
# optionally acknowledge handled records,
# annotate every unread line for validated signal status keys, surface unread
# informational status lines, latest captain-facing statuses not covered by a
# newer branch outcome, OPEN DECISIONS, and on
# a supervision-host home the supervision session's new and unprocessed
# outcomes (BRANCH OUTCOMES), then assert liveness.
#
# Keep sequence-bound row consumption independent from generation-bound episode
# retirement; docs/watcher-continuity.md owns the recovery contract.
# Every scratch file this script mints (.main-eligible-rows.tmp.*,
# .wake-rows.consume.*, .wake-queue.actor-view.*) is created and removed under the
# queue lock, so one found while taking that lock was left by a drain that died
# mid-write; each locked drain rotates such leftovers away before doing anything
# else. The wake rows themselves are the bus's now (docs/bus-live.md), so no
# scratch here holds a copy of the queue.
# JG_STATUS_PRESENTATION_LOCK_TIMEOUT sets the positive whole-second wait for
# presentation-path locks (default 10); queue mutation locks remain blocking.
# Every signalled status span replays until acknowledgement. OUTCOME_REQUIRED
# ids must first be handled with --outcome ID --relayed REFERENCE or
# --outcome ID --classified REASON (nonblank, recorded per actor and home);
# --outcomes-before EPOCH --classified REASON classifies, in one locked pass, every
# open outcome first presented before EPOCH (bin/jg-wake-status-lib.sh owns the rule).
# CAPTAIN NOTES lead every presentation, and they gate the acknowledgement:
# bin/jg-captain-note-lib.sh owns what counts as an unhandled captain inbox
# note, lists every one of them at the top of this drain, and refuses an
# acknowledgement whose batch still holds one with no reply and no drain
# acknowledgement. A note is read from state/inbox/, not from the queue, so a
# note whose row an earlier acknowledgement retired cannot disappear again.
# With config/item-store-reads in the main home (Main writes it after the store switch lands) the drain presents Main's
# store pages instead of re-printing status lines: QUEUED (each queued record's reason line, capped), PAGES (`jg-item pages
# main`, capped, from Main's cursor), OPEN DECISIONS (the store's open questions) and RECORD DIVERGENCE (`owner.py compare`).
# Its one acknowledgement also moves the page cursor (--pages-ack, the ack= of the PAGES count line). Remove the file to
# get the status-line presentation back; a Squad Lead home and a home without the file keep it.
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

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"
# shellcheck source=bin/jg-line-cap-lib.sh
. "$SCRIPT_DIR/jg-line-cap-lib.sh"
# shellcheck source=bin/jg-timeout-lib.sh
. "$SCRIPT_DIR/jg-timeout-lib.sh"
# shellcheck source=bin/jg-lease-lib.sh
. "$SCRIPT_DIR/jg-lease-lib.sh"
# shellcheck source=bin/jg-supervision-engine-lib.sh
. "$SCRIPT_DIR/jg-supervision-engine-lib.sh"
# shellcheck source=bin/jg-afk-contract.sh
. "$SCRIPT_DIR/jg-afk-contract.sh"
# shellcheck source=bin/jg-wake-status-lib.sh
. "$SCRIPT_DIR/jg-wake-status-lib.sh"
# shellcheck source=bin/jg-captain-note-lib.sh
. "$SCRIPT_DIR/jg-captain-note-lib.sh"

DRAIN_TMP=
DRAIN_VIEW_TMP=
DRAIN_LOCK_HELD=false
STATUS_LOCK_HELD=false
RAW_ROWS=
STATUS_ROWS=
RECOVERY_MARKER="$STATE/.watcher-down"
RECOVERY_MARKER_TOKEN=
RECOVERY_ACK_REQUIRED=false
RECOVERY_ACK_MOVED=false
ACK_THROUGH=
ACK_GENERATION=
PAGES_ACK_ARG=
PAGES_OUT=
PAGES_ACK=0
STORE_MODE=false
ACK_REMOVED=0
PRESENTED_MAX=0
ACK_FINGERPRINTS=
ACK_NOTICE_FINGERPRINTS=
OPEN_DECISIONS_ALL=0
PRESENTATION_LOCK_TIMEOUT=${JG_STATUS_PRESENTATION_LOCK_TIMEOUT:-10}
BRANCH_OUTCOMES_RC=0
case "$PRESENTATION_LOCK_TIMEOUT" in ''|*[!0-9]*|0) PRESENTATION_LOCK_TIMEOUT=10 ;; esac

# --- per-actor consume (docs/watcher-continuity.md "Per-actor acknowledgement") --
# main (JG_SUPERVISION_ACTOR unset or "main", via jg-lease-lib.sh's jg_lease_actor
# - the same actor identity jg-send.sh/jg-control.sh/jg-teardown.sh already use)
# claims every row not already granted to branch, then drains and acks only
# that claimed set. branch (JG_SUPERVISION_ACTOR=branch, injected
# deterministically by the Pi branch extension's bash tool - never agent
# memory) drains and acks only the row set the extension granted to it.
# .pi/extensions/lib/jg-branch-dispatch.ts is the single owner of that
# eligibility classification (which signal/stale rows resolve to a known
# project, and the existing all-unread-rows-safe rule for a heartbeat); this
# script never reclassifies a row itself, it only consumes the extension's
# already-computed verdict. The extension writes the exact eligible sequence
# numbers to ELIGIBLE_ROWS_FILE under the queue lock, immediately before every
# branch prompt, so the file is always fresh for the one wake that prompt is about to
# handle (the branch drains and acks exactly once per prompt, serialized by
# its own branchChain, before the next wake can overwrite the file).
# A row whose sequence number is not in that file is left completely
# untouched by a branch-actor drain or ack, no matter its sequence number
# relative to what the branch presents or consumes - that per-row scoping,
# not a cutoff comparison, is what makes a mixed main-only + task-local queue
# safe to split: the branch's ack can never remove a row it was not granted,
# so it can never swallow a main-owned row still waiting for main.
ACTOR=$(jg_lease_actor) || exit 2
ELIGIBLE_ROWS_FILE="$STATE/.branch-eligible-rows"
ELIGIBLE_OWNER_FILE="$STATE/.branch-eligible-owner"
MAIN_ROWS_FILE="$STATE/.main-eligible-rows"

rows_file_valid() { jg_wake_grant_rows_valid "$1"; }

# rotate_scratch_locked: remove scratch a dead drain left behind (header).
rotate_scratch_locked() {
  local scratch
  for scratch in "$STATE"/.main-eligible-rows.tmp.* "$STATE"/.wake-rows.consume.* \
    "$STATE"/.wake-queue.actor-view.*; do
    [ -e "$scratch" ] || [ -L "$scratch" ] || continue
    rm -f -- "$scratch"
  done
}

reclaim_stale_branch_grant_locked() {
  [ -e "$ELIGIBLE_ROWS_FILE" ] || [ -L "$ELIGIBLE_ROWS_FILE" ] || return 0
  if ! jg_wake_branch_grant_live "$ELIGIBLE_ROWS_FILE" "$ELIGIBLE_OWNER_FILE"; then
    rm -f -- "$ELIGIBLE_ROWS_FILE" "$ELIGIBLE_OWNER_FILE"
  fi
}

# One bounded line naming the rows a live branch grant is holding, so a main
# drain with nothing of its own never looks like a silently swallowed wake.
print_branch_held_notice() {
  local held seqs
  held=$(jg_wake_actor_pending_count branch "$ELIGIBLE_ROWS_FILE" "$ELIGIBLE_OWNER_FILE") || return 0
  [ "$held" -gt 0 ] || return 0
  seqs=$(jg_wake_grant_rows_valid "$ELIGIBLE_ROWS_FILE" \
    && awk 'NR <= 20 { printf "%s%s", (NR > 1 ? "," : ""), $1 } END { if (NR > 20) printf ",..." }' \
      "$ELIGIBLE_ROWS_FILE")
  printf 'WAKE ROWS HELD BY SUPERVISION BRANCH: %s queued row(s) (%s) are granted to the live supervision branch, which presents and acknowledges them.\n' \
    "$held" "${seqs:-unknown}"
}

write_rows_file_locked() { # <target> <source>
  local target=$1 source=$2
  if [ ! -s "$source" ]; then
    rm -f -- "$target" "$source"
    return
  fi
  chmod 0600 "$source" || return 1
  _jg_atomic_replace "$source" "$target"
}

# claim_main_rows_locked [<cutoff>]: claim every unreserved queued row for main,
# or with a cutoff only the unreserved rows at or below it. Rows main already
# owns stay owned either way.
claim_main_rows_locked() {
  DRAIN_TMP=$(mktemp "$STATE/.main-eligible-rows.tmp.XXXXXX") || return 1
  awk -F '\t' -v branch="$ELIGIBLE_ROWS_FILE" -v main="$MAIN_ROWS_FILE" -v cutoff="${1:-}" '
    BEGIN {
      while ((getline line < branch) > 0) reserved[line]=1
      while ((getline line < main) > 0) owned[line]=1
    }
    NF >= 5 && $2 ~ /^[0-9]+$/ {
      present[$2]=1
      if (!($2 in reserved) && (cutoff == "" || $2 + 0 <= cutoff + 0)) owned[$2]=1
    }
    END { for (seq in owned) if (seq in present) print seq }
  ' "$JG_WAKE_QUEUE" | LC_ALL=C sort -n > "$DRAIN_TMP" || return 1
  write_rows_file_locked "$MAIN_ROWS_FILE" "$DRAIN_TMP" || return 1
  DRAIN_TMP=
}

consume_actor_rows_locked() { # <rows-file> <cutoff>
  local rows=$1 cutoff=$2
  if [ ! -e "$rows" ] && [ ! -L "$rows" ]; then
    return 0
  fi
  DRAIN_TMP=$(mktemp "$STATE/.wake-rows.consume.XXXXXX") || return 1
  awk -v cutoff="$cutoff" '$1 ~ /^[0-9]+$/ && $1 > cutoff { print $1 }' "$rows" > "$DRAIN_TMP" || return 1
  write_rows_file_locked "$rows" "$DRAIN_TMP" || return 1
  DRAIN_TMP=
}

# A branch-actor drain or ack requires a snapshot to already exist and name at
# least one row. The extension always writes a non-empty snapshot before it
# ever prompts the branch (an empty eligible set means no prompt at all), so a
# missing or empty file here means this ran outside that handoff - a wiring
# bug, never "nothing eligible" - and must fail loudly rather than silently
# draining or acking nothing.
require_branch_eligible_rows() {
  rows_file_valid "$ELIGIBLE_ROWS_FILE" || {
    echo "wake drain: no branch-eligible row snapshot at $ELIGIBLE_ROWS_FILE; refusing to guess what this actor may consume" >&2
    return 1
  }
}

# The highest sequence this actor has already been presented: the branch's
# grant is exactly its current prompt's rows, and main's claim file is what its
# last drain printed. Read BEFORE an ack re-claims, so a row that arrived since
# presentation is never named as "the current wake" the caller may acknowledge
# unseen. 0 when nothing is on record.
presented_max_row() { # <rows-file>
  if rows_file_valid "$1" 2>/dev/null; then
    awk '$1 ~ /^[0-9]+$/ && $1 > max { max=$1 } END { print max + 0 }' "$1"
  else
    printf '0\n'
  fi
}

case "${1:-}" in
  '') ;;
  --outcome)
    if [ "$#" -ne 4 ] || { [ "$3" != --relayed ] && [ "$3" != --classified ]; }; then
      echo 'usage: jg-wake-drain.sh --outcome ID --relayed REFERENCE|--classified REASON' >&2
      exit 2
    fi
    jg_lock_acquire_wait "$STATE/.status-presentation-lock" || exit 1
    outcome_rc=0
    jg_wake_status_handle "$2" "${3#--}" "$4" || outcome_rc=$?
    jg_lock_release "$STATE/.status-presentation-lock"
    [ "$outcome_rc" -eq 0 ] || echo 'wake drain: outcome handling failed; use a presented id and a nonblank reference or reason' >&2
    exit "$outcome_rc"
    ;;
  --outcomes-before)
    if [ "$#" -ne 4 ] || [ "$3" != --classified ]; then
      echo 'usage: jg-wake-drain.sh --outcomes-before EPOCH --classified REASON' >&2
      exit 2
    fi
    jg_lock_acquire_wait "$STATE/.status-presentation-lock" || exit 1
    outcome_rc=0
    jg_wake_status_classify_before "$2" "$4" || outcome_rc=$?
    jg_lock_release "$STATE/.status-presentation-lock"
    [ "$outcome_rc" -eq 0 ] || echo 'wake drain: bulk classification failed; use a whole-second epoch and a nonblank reason' >&2
    exit "$outcome_rc"
    ;;
  --ack-through)
    ACK_THROUGH=${2:-}
    case "$ACK_THROUGH" in ''|*[!0-9]*) echo "wake drain: invalid acknowledgement sequence" >&2; exit 2 ;; esac
    [ "${3:-}" = --recovery-generation ] \
      || { echo "wake drain: acknowledgement requires its recovery generation" >&2; exit 2; }
    ACK_GENERATION=${4:-}
    case "$ACK_GENERATION" in ''|*[!A-Za-z0-9._-]*) echo "wake drain: invalid recovery generation" >&2; exit 2 ;; esac
    if [ "$#" -eq 6 ] && [ "${5:-}" = --pages-ack ]; then
      PAGES_ACK_ARG=$6
      case "$PAGES_ACK_ARG" in ''|*[!0-9]*) echo "wake drain: invalid page acknowledgement sequence" >&2; exit 2 ;; esac
    elif [ "$#" -ne 4 ]; then
      echo "wake drain: unexpected acknowledgement arguments" >&2
      exit 2
    fi
    ;;
  --open-decisions)
    # Read-only: every open decision, newest first, none cut. It takes no lock and moves no
    # cursor, so the digest's "all of them" pointer is safe to run at any time.
    [ "$#" -eq 1 ] || { echo "wake drain: --open-decisions takes no other argument" >&2; exit 2; }
    OPEN_DECISIONS_ALL=1
    ;;
  *) echo "usage: jg-wake-drain.sh [--ack-through SEQUENCE --recovery-generation GENERATION [--pages-ack SEQUENCE] | --outcome ID --relayed REFERENCE|--classified REASON | --outcomes-before EPOCH --classified REASON | --open-decisions]" >&2; exit 2 ;;
esac

[ "$ACTOR" != branch ] || require_branch_eligible_rows || exit 1

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert supervision health here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (jg-peek/jg-send/...) happens to run.
# Reuse jg-guard.sh's model-aware alarm and JG_GUARD_GRACE instead of duplicating
# its supervision verdict. Under Claude's between-turns auto-arm model, a normal
# fire leaves a recent beacon well inside grace and stays silent mid-turn. Under
# the Pi extension model, a fresh beacon also stays silent during a genuinely
# unheld-lock hand-off only while the live session proves extension ownership.
# Persistent-watcher models still require the live identity-matched watcher.
# Never let a guard hiccup change the drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/jg-guard.sh" || true
}

# Mark presentation-stage inactive terminal outcomes only after the handling
# turn has completed and before this acknowledgement consumes its queue rows.
# The helper ignores non-presentation and legacy keys, so this is a narrow
# receipt path rather than a second interpretation of general check wakes.
inactive_outcome_fingerprints() { # <sequence> <key-prefix> [<rows-file>]
  # shellcheck disable=SC2034  # epoch and payload are read from each row, not used
  local cutoff=$1 prefix=$2 rows=${3:-} epoch seq kind payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = check ] || continue
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    [ "$seq" -le "$cutoff" ] || continue
    if [ -n "$rows" ] && ! grep -qxF "$seq" "$rows"; then continue; fi
    case "$key" in
      "$prefix"*) printf '%s\n' "${key#"$prefix"}" ;;
    esac
  done < "$JG_WAKE_QUEUE"
}

acknowledge_inactive_outcomes() { # <mode> <newline-separated-fingerprints>
  local mode=$1 fingerprints=$2 fingerprint
  while IFS= read -r fingerprint; do
    [ -n "$fingerprint" ] || continue
    "$SCRIPT_DIR/jg-inactive-reconcile.sh" "$mode" "$fingerprint" || return 1
  done <<< "$fingerprints"
}

BRANCH_OUTCOME_INDEX_VERSION=jg-branch-outcome-index-v1
BRANCH_OUTCOME_INDEX_MAX_BYTES=512
BRANCH_OUTCOME_INDEX_STATE=ok
BRANCH_OUTCOME_INDEX_ENDPOINT=
BRANCH_OUTCOME_INDEX_IDENT=
STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED=
outcome_index_ready_ok() { # <ready-path>
  local seq
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ] || return 1
  seq=$(LC_ALL=C command cat "$1" 2>/dev/null) || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

load_branch_outcome_index() { # <task>
  local task=$1 path data version seq endpoint ident extra size
  BRANCH_OUTCOME_INDEX_STATE=ok
  BRANCH_OUTCOME_INDEX_ENDPOINT=
  BRANCH_OUTCOME_INDEX_IDENT=
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  path="$STATE/.$task.branch-outcome-index"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if [ ! -f "$path" ] || [ ! -r "$path" ] || [ -L "$path" ]; then
    BRANCH_OUTCOME_INDEX_STATE=invalid
    return 0
  fi
  size=$(_jg_status_file_size "$path") || { BRANCH_OUTCOME_INDEX_STATE=invalid; return 0; }
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  if [ "$size" -gt "$BRANCH_OUTCOME_INDEX_MAX_BYTES" ]; then
    BRANCH_OUTCOME_INDEX_STATE=invalid
    return 0
  fi
  data=$(LC_ALL=C command cat "$path" 2>/dev/null) \
    || { BRANCH_OUTCOME_INDEX_STATE=invalid; return 0; }
  case "$data" in *$'\n'*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  IFS=$(printf '\t') read -r version seq endpoint ident extra <<EOF
$data
EOF
  if [ "$version" != "$BRANCH_OUTCOME_INDEX_VERSION" ] || [ -n "$extra" ]; then
    BRANCH_OUTCOME_INDEX_STATE=invalid
    return 0
  fi
  case "$seq:$endpoint" in *[!0-9:]*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  [ -n "$seq" ] && [ -n "$endpoint" ] && [ -n "$ident" ] \
    && [ "${#seq}" -le 16 ] && [ "${#endpoint}" -le 16 ] \
    && [ "$seq" -le 9007199254740991 ] && [ "$endpoint" -le 9007199254740991 ] \
    || { BRANCH_OUTCOME_INDEX_STATE=invalid; return 0; }
  BRANCH_OUTCOME_INDEX_ENDPOINT=$endpoint
  BRANCH_OUTCOME_INDEX_IDENT=$ident
}

print_status_outcome_backstop_section() {  # <task-and-endpoint-snapshot>
  local snapshot=$1 task endpoint ident event event_endpoint line verb key receipt store lock ready
  local output='' used=0 shown=0 omitted=0 bytes item_bytes=220 global_bytes=4000 rc=0
  [ "$ACTOR" = main ] || return 0

  store="$STATE/branch-outcomes.jsonl"
  lock="$STATE/.branch-outcomes.lock"
  if [ -e "$store" ] || [ -L "$store" ]; then
    if [ ! -f "$store" ] || [ ! -r "$store" ] || [ -L "$store" ]; then
      printf 'STATUS OUTCOME BACKSTOP SKIPPED: branch outcome history could not be read safely; repair it before relying on drain recovery.\n'
      return 0
    fi
    if ! jg_lock_acquire_wait_bounded "$lock" "$PRESENTATION_LOCK_TIMEOUT"; then
      printf 'STATUS OUTCOME BACKSTOP SKIPPED: branch outcome history is busy; retry on the next drain.\n'
      return 0
    fi
    ready="$STATE/.branch-outcome-index-ready"
    if ! outcome_index_ready_ok "$ready"; then
      if ! "$SCRIPT_DIR/jg-branch-outcome.sh" processed-init --held-lock >/dev/null 2>&1 \
        || ! outcome_index_ready_ok "$ready"; then
        jg_lock_release "$lock"
        printf 'STATUS OUTCOME BACKSTOP SKIPPED: bounded outcome indexes could not be rebuilt because the outcome store is unsafe; repair it before relying on drain recovery.\n'
        return 0
      fi
    fi
  fi

  STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED=
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    receipt=$(status_outcome_backstop_cursor_offset "$STATE/$task.status") || { rc=1; break; }
    [ "$receipt" -lt "$endpoint" ] || continue
    status_snapshot_latest_event "$STATE/$task.status" "$endpoint" "$ident" || continue
    event=$JG_STATUS_SNAPSHOT_EVENT_LINE
    event_endpoint=$JG_STATUS_SNAPSHOT_EVENT_ENDPOINT
    [ "$receipt" -lt "$event_endpoint" ] || continue
    status_is_captain_relevant "$event" || continue
    verb=$(status_line_verb "$event")
    case "$verb" in
      needs-decision|blocked)
        key=$(_jg_decision_key "$event") || key=
        # Parseable decisions belong exclusively to the durable fold. That
        # includes reserved-key transitions the fold rejects; resurfacing one
        # here would let a foreign writer bypass the namespace guard. A line
        # with malformed key syntax has no fold representation, so the
        # captain-facing backstop remains its only safe presentation path.
        [ -z "$key" ] || continue
        ;;
    esac
    load_branch_outcome_index "$task"
    if [ "$BRANCH_OUTCOME_INDEX_STATE" != ok ]; then
      rc=2
      break
    fi
    if [ -n "$BRANCH_OUTCOME_INDEX_ENDPOINT" ] \
      && [ "$BRANCH_OUTCOME_INDEX_IDENT" = "$ident" ] \
      && [ "$BRANCH_OUTCOME_INDEX_ENDPOINT" -ge "$event_endpoint" ]; then
      continue
    fi

    line="$task $event"
    jg_cap_line_var "$line" $((item_bytes - 1))
    line=$JG_LINE_CAP_LINE
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED="$STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED$task$(printf '\t')$event_endpoint
"
    used=$((used + bytes))
    shown=$((shown + 1))
  done <<EOF
$snapshot
EOF

  if [ -e "$store" ] || [ -L "$store" ]; then jg_lock_release "$lock"; fi
  if [ "$rc" -eq 1 ]; then return 1; fi
  if [ "$rc" -eq 2 ]; then
    printf 'STATUS OUTCOME BACKSTOP SKIPPED: a bounded task outcome index could not be read safely; repair it before relying on drain recovery.\n'
    STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED=
    return 0
  fi
  [ "$shown" -gt 0 ] || [ "$omitted" -gt 0 ] || return 0
  printf 'STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):\n' || return 1
  printf '%s' "$output" || return 1
  if [ "$omitted" -gt 0 ]; then
    printf 'STATUS OUTCOME BACKSTOP: %d more omitted (byte cap); every lane with its last status line: juggernaut-axi lanes\n' "$omitted" || return 1
  fi
}

# Print still-unread informational status lines (note: answers and pending-reply
# resolutions) that the OPEN DECISIONS fold never carries. Uses the same
# cursor-backed unread span as the annotation path, and runs on every drain -
# including the empty-queue fast path - so a buried answer cannot be swallowed
# when the fold later advances the cursor. Prints nothing when nothing is
# unread, which is the common case.
UNREAD_STATUS_CAP_DEFAULT=20

print_unread_status_section() {
  local snapshot=${1:-} unread task line shown=0 seen=0 total skip

  if [ -n "$snapshot" ]; then
    unread=$(scan_unread_surface_snapshot "$STATE" "$snapshot") || return 1
  else
    unread=$(scan_unread_surface_lines "$STATE") || return 1
  fi
  [ -n "$unread" ] || return 0

  # The newest UNREAD_STATUS_CAP lines print, then one line counts the rest: these lines surface once, and a status log
  # nobody drained for days holds thousands. The status logs keep every line.
  total=$(printf '%s\n' "$unread" | grep -c .) || true
  skip=$((total - ${UNREAD_STATUS_CAP:-$UNREAD_STATUS_CAP_DEFAULT}))
  [ "$skip" -gt 0 ] || skip=0
  while IFS=$(printf '\t') read -r task line; do
    [ -n "$task" ] || continue
    [ -n "$line" ] || continue
    seen=$((seen + 1))
    if [ "$seen" -le "$skip" ]; then continue; fi
    line="$task $line"
    if [ "$shown" -eq 0 ]; then
      printf 'UNREAD STATUS (new since last drain, not re-printed after this presentation):\n' || return 1
      [ "$skip" -eq 0 ] || printf 'UNREAD STATUS: %d earlier unread line(s) not shown; each stays in its state/<task>.status\n' "$skip" || return 1
    fi
    printf '%s\n' "$line" || return 1
    shown=$((shown + 1))
  done <<EOF
$unread
EOF

  [ "$shown" -gt 0 ] || return 0
}

# order_open_decisions <rows>: the folded "<task>\t<key>\t<verb>\t<note>" rows newest first - tasks by
# the time of their last status line, and within a task the decision opened last first - so a cut
# keeps what was raised most recently. A task whose log cannot be statted sorts last.
order_open_decisions() {
  local rows=$1 task stamps='' tab
  tab=$(printf '\t')
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    stamps="$stamps$(jg_path_mtime "$STATE/$task.status" || printf 0)$tab$task
"
  done <<EOF
$(printf '%s\n' "$rows" | cut -f1 | awk '!seen[$0]++')
EOF
  printf '%s\n' "$rows" | awk -F '\t' -v stamps="$stamps" '
    BEGIN {
      n = split(stamps, l, "\n")
      for (i = 1; i <= n; i++) { split(l[i], p, "\t"); if (p[2] != "") m[p[2]] = p[1] }
    }
    { printf "%d\t%d\t%s\n", (m[$1] + 0), NR, $0 }' \
    | sort -s -t "$tab" -k1,1nr -k2,2nr | cut -f3-
}

# Print the consolidated OPEN DECISIONS section: every still-open
# needs-decision/blocked, fleet-wide, folded from the durable status logs by
# jg-classify-lib.sh's status_open_decisions fold (via its cursor-backed
# scan_open_decisions_incremental wrapper) rather than from the annotations
# above, so a decision buried under later unrelated appends cannot be silently
# missed. Informational `note:` lines and pending-reply resolutions are not
# decisions; print_unread_status_section owns their one-shot surface. Runs on
# every drain - including the empty-queue fast path - because the decision can
# still be open even when nothing new is queued for
# its task this turn. The incremental wrapper bounds this scan's cost to bytes
# appended to each task's status log since the LAST drain, not that log's whole
# lifetime, while still never dropping an old buried decision (see
# jg-classify-lib.sh's "incremental (cursor-backed) open-decisions fold").
# Bounded and silent: prints nothing when no decision is open, which is the
# common case.
print_open_decisions_section() {
  local snapshot=${1:-} open task key verb note line item_bytes=220 global_bytes=4000 total
  local output='' used=0 shown=0 omitted=0 bytes

  if [ -n "$snapshot" ]; then
    open=$(scan_open_decisions_snapshot "$STATE" "$snapshot") || return 1
  else
    open=$(scan_open_decisions_incremental "$STATE") || return 1
  fi
  [ -n "$open" ] || return 0
  total=$(printf '%s\n' "$open" | grep -c .)
  open=$(order_open_decisions "$open")

  while IFS=$(printf '\t') read -r task key verb note; do
    [ -n "$task" ] || continue
    line="$task"
    [ "$key" = default ] || line="$line [key=$key]"
    line="$line $verb: $note"
    # The shared cut counts the item's own characters; the trailing newline this
    # section's global budget also pays for is this caller's, so the per-item
    # allowance passed down is one short of the cap.
    jg_cap_line_var "$line" $((item_bytes - 1))
    line=$JG_LINE_CAP_LINE
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
    shown=$((shown + 1))
  done <<EOF
$open
EOF

  [ "$shown" -gt 0 ] || [ "$omitted" -gt 0 ] || return 0
  printf 'OPEN DECISIONS (%d still open, newest first, folded from the durable status logs - not just the latest line):\n' "$total" || return 1
  printf '%s' "$output" || return 1
  if [ "$omitted" -gt 0 ]; then
    printf 'OPEN DECISIONS: %d of %d shown (byte cap); all of them, newest first: bin/jg-wake-drain.sh --open-decisions\n' "$shown" "$total" || return 1
  fi
  # Answerer-closes hint, printed at exactly the moment an answer gets written:
  # the send that answers a listed decision also closes it, so closure never
  # depends on the busy worker writing a matching resolved line (contract:
  # bin/jg-send.sh header).
  printf "OPEN DECISIONS: close one by answering it: bin/jg-send.sh <task> --resolve-key <key> '<answer>'\n" || return 1
}

# Print BRANCH OUTCOMES: what the supervision host's session recorded since
# main last drained (docs/supervision-host.md "Captain outcomes"). Off Pi this
# presentation is what the Pi branch's transcript entries are. It runs only for
# main, only where jg_supervision_host_outcomes_drained holds (the Pi branch
# extension owns this path on Pi), and never while an away record exists,
# because those outcomes wait for the return; quiet mode's record is a present
# captain (bin/jg-afk-contract.sh AWAY OR QUIET). Bounded, and silent when
# nothing is new or unprocessed.
#   - Captain outcomes come first and never wait behind routine ones. Every
#     unprocessed captain row is presented on every drain until main
#     acknowledges it, collapsed to one line per task: the task's newest
#     presented summary, naming how many unprocessed captain outcomes it
#     carries, with tasks in order of their oldest unprocessed row. The byte
#     cap presents only the oldest contiguous run of captain rows and counts
#     the newer ones it holds back, so the printed bin/jg-branch-outcome.sh
#     mark-processed target, the newest presented row, acknowledges exactly
#     what was presented and always at least the oldest row. An unprocessed
#     captain row is never adopted as processed, so a home that opts in
#     mid-session cannot lose its first captain outcome. Each line names how
#     long ago its row was recorded (the store's "recordedAgo"), because a row
#     main never acknowledged can come back long after its situation settled
#     (after a harness or posture switch, or an upgrade whose earlier
#     presenter never advanced the read cursor), and the section asks main to
#     check the task's current state first and reply to the captain only
#     about outcomes still open, as if settled ones had never been listed,
#     then acknowledge every presented outcome, settled and open alike.
#   - Visible routine outcomes are listed once, for awareness, the way the Pi
#     branch's routine notes reach main's transcript without a turn; silent
#     routine outcomes never appear. The newest visible rows that fit a byte
#     cap are listed, and older visible rows collapse into a count, since
#     bin/jg-branch-outcome.sh list keeps them all.
# Once the section is printed, the store's read cursor advances through every
# presented row, which is what lets mark-processed accept main's
# acknowledgement and keeps a routine row from repeating; a drain stopped
# before it prints leaves every row unread. The budgets count bytes. When jq is
# missing, the store cannot be read or projected, the section cannot be printed, or its read
# cursor cannot advance, the section says so on stderr and fails, and the drain exits
# nonzero after the rest of its presentation, so a caller such as the return
# (bin/jg-afk-return.sh) keeps its catch-up gated instead of clearing over
# outcomes a later drain would present again.
print_branch_outcomes_section() {
  local config rows through captain routine line seq task task_line target i
  local text='' used=0 shown=0 held=0 bytes item_bytes=600 captain_bytes=4000 routine_bytes=2000
  local routine_lines='' routine_count=0 routine_shown=0
  local -a captain_tasks=() captain_lines=() captain_line_bytes=()
  [ "$ACTOR" = main ] || return 0
  config=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
  jg_supervision_host_outcomes_drained "$config" || return 0
  [ -s "$STATE/branch-outcomes.jsonl" ] || return 0
  ! jg_afk_contract_away_present "$STATE" || return 0
  if ! command -v jq >/dev/null 2>&1; then
    printf 'BRANCH OUTCOMES SKIPPED: jq is not installed, so the outcome store cannot be presented; nothing was marked read, and these outcomes are presented once jq is back.\n' >&2
    return 1
  fi
  if ! rows=$("$SCRIPT_DIR/jg-branch-outcome.sh" present 2>/dev/null); then
    printf 'BRANCH OUTCOMES SKIPPED: the outcome store could not be read safely; repair it before relying on this section.\n' >&2
    return 1
  fi
  [ -n "$rows" ] || return 0
  if ! through=$(printf '%s\n' "$rows" | jq -s 'map(select(.unread) | .seq) | max // 0' 2>/dev/null) \
    || ! captain=$(printf '%s\n' "$rows" | jq -rs '
      map(select(.verdict == "captain")) | sort_by(.seq)
      | reduce .[] as $r ({count: {}, lines: []};
          .count[$r.task] += 1
          | .lines += ["\($r.seq)\t\($r.task)\t[seq \($r.seq)\(if .count[$r.task] > 1 then ", newest of \(.count[$r.task]) for this task" else "" end), recorded \($r.recordedAgo) ago] \($r.task): \($r.summary | gsub("[\t\n\r]"; " "))"])
      | .lines[]' 2>/dev/null) \
    || ! routine=$(printf '%s\n' "$rows" | jq -rs 'map(select(.unread and .verdict == "routine" and .silent != true)) | sort_by(.seq) | reverse | .[]
      | "[seq \(.seq)] \(.task): \(.summary | gsub("[\t\n\r]"; " "))"' 2>/dev/null) \
    || case "$through" in ''|*[!0-9]*) true ;; *) false ;; esac; then
    printf 'BRANCH OUTCOMES SKIPPED: the outcome store could not be projected safely; nothing was marked read, so these outcomes are presented again on the next drain.\n' >&2
    return 1
  fi

  target=0
  while IFS=$(printf '\t') read -r seq task task_line; do
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    if [ "$held" -gt 0 ]; then
      held=$((held + 1))
      continue
    fi
    cap_outcome_line "$task_line" $((item_bytes - 1))
    i=0
    while [ "$i" -lt "$shown" ] && [ "${captain_tasks[$i]}" != "$task" ]; do i=$((i + 1)); done
    bytes=$(( used + OUTCOME_LINE_BYTES + 1 ))
    [ "$i" -eq "$shown" ] || bytes=$(( bytes - captain_line_bytes[i] - 1 ))
    if [ "$bytes" -gt "$captain_bytes" ]; then
      held=1
      continue
    fi
    captain_tasks[i]=$task
    captain_lines[i]=$OUTCOME_LINE
    captain_line_bytes[i]=$OUTCOME_LINE_BYTES
    [ "$i" -lt "$shown" ] || shown=$((shown + 1))
    used=$bytes
    target=$seq
  done <<ROWS
$captain
ROWS
  if [ "$shown" -gt 0 ]; then
    text="BRANCH OUTCOMES (captain outcomes the supervision session recorded for you, one line per task, oldest first; each says what was true when it was recorded, so check the task's current state first, including its still-open decisions listed above under OPEN DECISIONS, and sort them into still open and already settled, such as a decision since answered, a PR since merged, or a task since finished - process the still-open ones as juggernaut: tell the captain, land or merge what is ready, answer or escalate a decision, or act on a blocker; your reply to the captain covers only those, as if the settled ones had never been listed, and a settled one needs only the acknowledgement):
"
    for line in "${captain_lines[@]}"; do
      text="$text$line
"
    done
    [ "$held" -eq 0 ] || text="${text}BRANCH OUTCOMES: $held newer captain outcome(s) are held back (byte cap); they follow on the next drain once these are acknowledged
"
    text="${text}BRANCH OUTCOMES: after processing them run bin/jg-branch-outcome.sh mark-processed --through $target; until then every drain presents them again
"
  fi

  used=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    routine_count=$((routine_count + 1))
  done <<ROWS
$routine
ROWS
  # Newest first against the cap, printed oldest first.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cap_outcome_line "$line" $((item_bytes - 1))
    bytes=$(( OUTCOME_LINE_BYTES + 1 ))
    [ $((used + bytes)) -le "$routine_bytes" ] || break
    routine_lines="$OUTCOME_LINE
$routine_lines"
    used=$((used + bytes))
    routine_shown=$((routine_shown + 1))
  done <<ROWS
$routine
ROWS
  if [ "$routine_count" -gt 0 ]; then
    text="${text}BRANCH OUTCOMES, ROUTINE (handled by the supervision session since your last drain; for your awareness, nothing to acknowledge):
"
    [ "$routine_shown" -eq "$routine_count" ] || text="${text}($((routine_count - routine_shown)) earlier routine outcome(s) not shown; bin/jg-branch-outcome.sh list keeps them)
"
    text="$text$routine_lines"
  fi
  if [ -n "$text" ]; then
    printf '%s' "$text" || return 1
  fi
  [ "$through" -gt 0 ] || return 0
  if ! "$SCRIPT_DIR/jg-branch-outcome.sh" mark-read --through "$through" >/dev/null 2>&1; then
    printf 'BRANCH OUTCOMES: the store could not record this presentation, so these outcomes are presented again on the next drain and an acknowledgement above is refused until then.\n' >&2
    return 1
  fi
}

# BRANCH OUTCOMES' per-item cut: the shared digest marker in place of the
# tail once the line passes <max> bytes, cut bytewise whatever the caller's
# locale and backed off to the last whole UTF-8 character, so a multibyte
# summary keeps the section inside its byte budgets and stays valid text. Sets
# OUTCOME_LINE and OUTCOME_LINE_BYTES.
cap_outcome_line() {  # <line> <max-bytes>
  local LC_ALL=C line=$1 max=$2 keep body tail rest need
  if [ "${#line}" -le "$max" ]; then
    OUTCOME_LINE=$line
    OUTCOME_LINE_BYTES=${#line}
    return 0
  fi
  keep=$((max - ${#JG_LINE_CAP_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  body=${line:0:keep}
  tail=${body##*[!$'\x80'-$'\xbf']}
  rest=${body%"$tail"}
  case "${rest: -1}" in
    [$'\xc0'-$'\xdf']) need=1 ;;
    [$'\xe0'-$'\xef']) need=2 ;;
    [$'\xf0'-$'\xf7']) need=3 ;;
    *) need=0 ;;
  esac
  [ "${#tail}" -ge "$need" ] || body=${rest%?}
  OUTCOME_LINE=$body$JG_LINE_CAP_SUFFIX
  OUTCOME_LINE_BYTES=${#OUTCOME_LINE}
}

print_status_sections() {
  local snapshot=${1:-} fully_presented=${2:-} acknowledged prepared
  if [ -z "$snapshot" ]; then snapshot=$(status_presentation_snapshot "$STATE") || return 1; fi
  [ -n "$snapshot" ] || return 0
  acknowledged=$(status_acknowledge_presented_snapshot "$STATE" "$snapshot" "$fully_presented") || return 1
  prepared=$(mktemp "$STATE/.status-presentation.prepared.XXXXXX") || return 1
  if ! {
    print_unread_status_section "$snapshot" \
      && print_status_outcome_backstop_section "$snapshot" \
      && print_open_decisions_section "$snapshot"
  } > "$prepared"; then
    rm -f -- "$prepared"
    return 1
  fi
  # Prepare every section before presentation, but do not commit its receipt
  # until the prepared bytes reach stdout. If the consumer closes or fails,
  # leave the receipt behind so the next drain can recover the presentation.
  if ! command cat "$prepared"; then
    rm -f -- "$prepared"
    return 1
  fi
  if ! status_commit_presentation_snapshot "$STATE" "$acknowledged"; then
    rm -f -- "$prepared"
    return 1
  fi
  rm -f -- "$prepared"
}

print_status_presentation() {  # [<deduped-raw-rows>]
  local rows=${1:-} lock="$STATE/.status-presentation-lock" snapshot annotation_manifest fully_presented='' rc=0
  local lock_rc holder_pid
  if jg_lock_acquire_wait_bounded "$lock" "$PRESENTATION_LOCK_TIMEOUT"; then
    :
  else
    lock_rc=$?
    if [ "$lock_rc" -eq 124 ]; then
      holder_pid=${JG_LOCK_HELD_PID:-unknown}
      printf 'STATUS PRESENTATION SKIPPED: lock remains held by live pid %s after %ss; retry on the next drain.\n' \
        "$holder_pid" "$PRESENTATION_LOCK_TIMEOUT"
    else
      printf 'wake drain: status presentation lock could not be acquired safely\n' >&2
    fi
    return 1
  fi
  snapshot=$(status_presentation_snapshot "$STATE") || {
    printf 'STATUS PRESENTATION INCOMPLETE: status snapshot could not be read.\n'
    rc=1
  }
  if [ "$rc" -eq 0 ] && [ -n "$rows" ]; then
    jg_wake_status_present "$rows" "$snapshot" || rc=1
    if [ "$rc" -eq 0 ]; then
      annotation_manifest=$(jg_wake_annotation_manifest "$rows") || rc=1
      fully_presented=$(printf '%s\n' "$annotation_manifest" | awk -F '\t' '$2 == "direct" { sub(/\.status$/, "", $1); print $1 }') || rc=1
    fi
  fi
  if [ "$rc" -eq 0 ] && [ -n "$snapshot" ]; then print_status_sections "$snapshot" "$fully_presented" || rc=1; fi
  jg_lock_release "$lock"
  return "$rc"
}

# --- the store presentation (docs/item-store.md) ------------------------------------------------------------------------
STORE_CLI="$SCRIPT_DIR/../core/item-store/jg-item"
STORE_OWNER="$SCRIPT_DIR/../core/item-store/adapters/owner.py"
QUEUED_TEXT=
QUEUED_N=0
QUEUED_CUT=0

# 0 when this drain presents the store: Main's home with the store on and its reads switched on.
store_reads_on() {
  local cfg=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
  [ "$ACTOR" = main ] && [ -e "$cfg/item-store" ] && [ -e "$cfg/item-store-reads" ] && [ ! -e "$JG_HOME/.jg-squad-lead-home" ]
}

store_jg_item() { JG_HOME="$JG_HOME" python3 -I "$STORE_CLI" "$@"; }

# Every open owner question, newest first, one `<key>\t<subject>\t<text>` row each.
store_open_questions() {
  local db
  db=$(store_jg_item where) || return 1
  python3 -I -c 'import sqlite3, sys
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
for k, s, o in c.execute("SELECT key, subject, owes FROM item WHERE kind = '"'"'question'"'"' AND state = '"'"'open'"'"' ORDER BY id DESC"):
    print("\t".join((k, s or "-", " ".join((o or "").split()))))' "$db"
}

# Cut the deduped queued rows to what one drain shows: each record's reason line (its first line), at most 200 lines and
# 32 KiB, oldest first. Sets QUEUED_TEXT, QUEUED_N (every queued record) and QUEUED_CUT (the sequence of the last line shown
# when records were left over, else 0): the acknowledgement then stops there and the rest come on the next drain.
build_queued_view() {  # <rows>
  local LC_ALL=C rows=$1 epoch seq kind key payload line used=0 shown=0 cap_lines=200 cap_bytes=32768 last=0 over=false
  QUEUED_TEXT='' QUEUED_N=0 QUEUED_CUT=0
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    QUEUED_N=$((QUEUED_N + 1))
    if [ "$over" = true ]; then continue; fi
    jg_cap_line_var "${payload%%$'\n'*}" 299
    line=$JG_LINE_CAP_LINE
    if [ "$shown" -ge "$cap_lines" ] || [ $((used + ${#line} + 1)) -gt "$cap_bytes" ]; then
      over=true
      QUEUED_CUT=$last
      continue
    fi
    QUEUED_TEXT="$QUEUED_TEXT$line
"
    used=$((used + ${#line} + 1))
    shown=$((shown + 1))
    last=$seq
  done <<EOF
$(printf '%s\n' "$rows" | sort -s -t "$(printf '\t')" -k2,2n)
EOF
}

# Cut the deduped queued rows to what one drain prints: oldest first, at most WAKE_ROWS_CAP_LINES rows and
# WAKE_ROWS_CAP_BYTES bytes (a fifth of the digest cap: the queue is never cut by the digest), and always the first row. A queue that grew while no drain finished held thousands of
# wakes and one drain printed them all, tens of megabytes. Sets RAW_TEXT, RAW_N (every queued row) and RAW_CUT (the
# sequence of the last row shown when rows were left over, else 0): the acknowledgement then stops there and the rest
# come on the next drain.
WAKE_ROWS_CAP_LINES=60
WAKE_ROWS_CAP_BYTES=10240

build_raw_view() {  # <rows>
  local out meta
  out=$(printf '%s\n' "$1" | LC_ALL=C sort -s -t "$(printf '\t')" -k2,2n | LC_ALL=C awk -F '\t' \
    -v cap_lines="$WAKE_ROWS_CAP_LINES" -v cap_bytes="$WAKE_ROWS_CAP_BYTES" '
    $2 !~ /^[0-9]+$/ { next }
    { n++ }
    over { next }
    { len = length($0) + 1 }
    shown > 0 && (shown >= cap_lines || used + len > cap_bytes) { over = 1; cut = last; next }
    { print; used += len; shown++; last = $2 }
    END { print "@@meta " n + 0 " " cut + 0 }') || return 1
  meta=${out##*$'\n'}
  RAW_TEXT=${out%$'\n'*}
  [ "$out" != "$meta" ] || RAW_TEXT=''
  meta=${meta#@@meta }
  RAW_N=${meta% *}
  RAW_CUT=${meta#* }
}

# Read Main's pages once, before anything prints. Sets PAGES_OUT, and PAGES_ACK to the ack= of the count line when the read
# listed or counted a page (0 when nothing waits, so a quiet drain asks for no acknowledgement; -1 when the store cannot answer).
load_store_pages() {
  local count listed closed
  PAGES_OUT='' PAGES_ACK=0
  PAGES_OUT=$(store_jg_item pages main 2>&1) || { PAGES_ACK=-1; return 0; }
  count=$(printf '%s\n' "$PAGES_OUT" | tail -n 1)
  listed=${count#pages: }; listed=${listed%% listed*}
  closed=${count#*listed, }; closed=${closed%% closed*}
  case "$listed:$closed" in *[!0-9:]*|:*|*:) return 0 ;; esac
  [ $((listed + closed)) -gt 0 ] || return 0
  PAGES_ACK=${count##*ack=}
  case "$PAGES_ACK" in ''|*[!0-9]*) PAGES_ACK=0 ;; esac
}

print_pages_section() {
  if [ "$PAGES_ACK" = -1 ]; then
    jg_cap_line_var "$(printf '%s' "$PAGES_OUT" | tr '\n' ' ')" 200
    printf 'PAGES SKIPPED: the item store could not be read (%s); nothing was marked read.\n' "$JG_LINE_CAP_LINE"
    return 0
  fi
  [ "$PAGES_ACK" -gt 0 ] || return 0
  printf 'PAGES (unread store pages for Main from its cursor, at most 200 lines and 32 KiB; act on each, then acknowledge):\n'
  printf '%s\n' "$PAGES_OUT"
}

print_store_decisions_section() {
  local rows key subject text line total item_bytes=220 global_bytes=4000 output='' used=0 shown=0 bytes
  rows=$(store_open_questions) || { printf 'OPEN DECISIONS SKIPPED: the item store could not be read.\n'; return 0; }
  [ -n "$rows" ] || return 0
  total=$(printf '%s\n' "$rows" | grep -c .)
  while IFS=$(printf '\t') read -r key subject text; do
    [ -n "$key" ] || continue
    line="$subject [key=$key] decision: $text"
    jg_cap_line_var "$line" $((item_bytes - 1))
    line=$JG_LINE_CAP_LINE
    bytes=$((${#line} + 1))
    [ $((used + bytes)) -le "$global_bytes" ] || break
    output="$output$line
"
    used=$((used + bytes))
    shown=$((shown + 1))
  done <<EOF
$rows
EOF
  printf 'OPEN DECISIONS (%d still open, newest first, from the item store):\n' "$total"
  printf '%s' "$output"
  [ "$shown" -ge "$total" ] || printf 'OPEN DECISIONS: %d of %d shown (byte cap); all of them, newest first: bin/jg-wake-drain.sh --open-decisions\n' "$shown" "$total"
}

print_divergence_section() {
  local out rc=0 line used=0 global_bytes=4000
  out=$(env JG_HOME="$JG_HOME" python3 -I "$STORE_OWNER" compare "$JG_HOME" 2>&1) || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) ;;
    *) printf 'RECORD DIVERGENCE SKIPPED: the owner records could not be compared.\n'; return 0 ;;
  esac
  printf "RECORD DIVERGENCE (today's records and the store disagree; one line per difference):\n"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    jg_cap_line_var "$line" 219
    if [ $((used + ${#JG_LINE_CAP_LINE} + 1)) -gt "$global_bytes" ]; then
      printf 'RECORD DIVERGENCE: more differences not shown; run python3 core/item-store/adapters/owner.py compare <home>\n'
      break
    fi
    printf '%s\n' "$JG_LINE_CAP_LINE"
    used=$((used + ${#JG_LINE_CAP_LINE} + 1))
  done <<EOF
$out
EOF
}

# What one store drain prints after QUEUED: the pages it already read, then the store's open questions and the divergence.
print_store_sections() {
  print_pages_section
  print_store_decisions_section
  print_divergence_section
}

# The line that tells Main how to acknowledge: the queue generation, and with a page waiting the page cursor too.
print_ack_required() {  # <through> <generation>
  local suffix=
  [ "$PAGES_ACK" -le 0 ] || suffix=" --pages-ack $PAGES_ACK"
  printf 'WAKE_ACK_REQUIRED: after handling completes run bin/jg-wake-drain.sh --ack-through %s --recovery-generation %s%s\n' "$1" "$2" "$suffix" >&2
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  [ -z "$DRAIN_TMP" ] || rm -f -- "$DRAIN_TMP" 2>/dev/null || true
  [ -z "$DRAIN_VIEW_TMP" ] || rm -f -- "$DRAIN_VIEW_TMP" 2>/dev/null || true
  if [ "$STATUS_LOCK_HELD" = true ]; then
    jg_lock_release "$STATE/.status-presentation-lock"
  fi
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    jg_lock_release "$JG_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

# The store presentation decides here, and reads Main's pages once before any lock is taken.
if store_reads_on; then STORE_MODE=true; fi
if [ "$STORE_MODE" = true ] && [ -z "$ACK_THROUGH" ] && [ "$OPEN_DECISIONS_ALL" -eq 0 ]; then load_store_pages; fi
if [ -n "$PAGES_ACK_ARG" ] && [ "$STORE_MODE" != true ]; then
  echo "wake drain: --pages-ack needs Main's item-store reads (config/item-store-reads)" >&2
  exit 2
fi

# --open-decisions: fold every status log whole (status_open_decisions reads the log itself and
# keeps no cursor), print every open decision newest first, and stop - before any lock or queue read.
if [ "$OPEN_DECISIONS_ALL" -eq 1 ] && [ "$STORE_MODE" = true ]; then
  all_rows=$(store_open_questions) || { echo 'wake drain: the item store could not be read' >&2; exit 1; }
  if [ -z "$all_rows" ]; then
    printf 'OPEN DECISIONS: none\n'
    exit 0
  fi
  printf 'OPEN DECISIONS (%d still open, newest first):\n' "$(printf '%s\n' "$all_rows" | grep -c .)"
  printf '%s\n' "$all_rows" | while IFS=$(printf '\t') read -r key subject text; do
    printf '%s [key=%s] decision: %s\n' "$subject" "$key" "$text"
  done
  exit 0
fi
if [ "$OPEN_DECISIONS_ALL" -eq 1 ]; then
  all_open=
  for status_file in "$STATE"/*.status; do
    [ -f "$status_file" ] && [ ! -L "$status_file" ] || continue
    task=$(basename "$status_file" .status)
    folded=$(status_open_decisions "$status_file" 2>/dev/null) || continue
    [ -n "$folded" ] || continue
    while IFS=$(printf '\t') read -r key verb note; do
      [ -n "$key" ] || continue
      all_open="$all_open$task$(printf '\t')$key$(printf '\t')$verb$(printf '\t')$note
"
    done <<EOF
$folded
EOF
  done
  if [ -z "$all_open" ]; then
    printf 'OPEN DECISIONS: none\n'
    exit 0
  fi
  printf 'OPEN DECISIONS (%d still open, newest first):\n' "$(printf '%s' "$all_open" | grep -c .)"
  order_open_decisions "${all_open%
}" | while IFS=$(printf '\t') read -r task key verb note; do
    line="$task"
    [ "$key" = default ] || line="$line [key=$key]"
    printf '%s %s: %s\n' "$line" "$verb" "$note"
  done
  exit 0
fi

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "$ACK_THROUGH" ]; then
  jg_lock_acquire_wait "$JG_WAKE_QUEUE_LOCK"
elif jg_lock_acquire_wait_bounded "$JG_WAKE_QUEUE_LOCK" "$PRESENTATION_LOCK_TIMEOUT"; then
  :
else
  lock_rc=$?
  if [ "$lock_rc" -eq 124 ]; then
    printf 'WAKE DRAIN SKIPPED: queue lock remains held by live pid %s after %ss; retry on the next drain.\n' \
      "${JG_LOCK_HELD_PID:-unknown}" "$PRESENTATION_LOCK_TIMEOUT"
    exit 0
  fi
  printf 'wake drain: queue lock could not be acquired safely\n' >&2
  exit 1
fi
DRAIN_LOCK_HELD=true
rotate_scratch_locked
reclaim_stale_branch_grant_locked || exit 1
[ "$ACTOR" != branch ] || require_branch_eligible_rows || exit 1

if [ -n "$ACK_THROUGH" ]; then
  if [ "$ACTOR" = branch ]; then
    PRESENTED_MAX=$(presented_max_row "$ELIGIBLE_ROWS_FILE") || exit 1
  else
    PRESENTED_MAX=$(presented_max_row "$MAIN_ROWS_FILE") || exit 1
  fi
  if [ "$ACTOR" = main ]; then
    # Preserve main's original whole-cutoff acknowledgement contract: a direct
    # or replayed main ack still owns every unreserved row through its cutoff,
    # so claim those again under the queue lock and none is stranded merely
    # because it was not present during the earlier drain. A row above the
    # cutoff arrived after presentation and was never shown to main, so it
    # stays unowned for whichever actor presents it next; claiming it here
    # would hand every later away-session wake back to main. A live branch
    # grant remains excluded by claim_main_rows_locked.
    claim_main_rows_locked "$ACK_THROUGH" || exit 1
  fi
  if [ "$ACTOR" = branch ]; then
    # An away-posture grant can name check-kind rows - the attended
    # partition's check/decision exclusions lift under the away record
    # (docs/pi-supervision-branch.md "Postures") - so a branch ack must retire
    # the inactive-outcome and notice receipts carried by the exact granted
    # sequences it consumes. Otherwise the receipt stays pending and every
    # later reconcile scan re-queues the same fingerprint. Attended, a grant
    # names no check row and both scans find nothing.
    ACK_ROWS_FILE=$ELIGIBLE_ROWS_FILE
    ACK_FINGERPRINTS=$(inactive_outcome_fingerprints "$ACK_THROUGH" 'inactive-outcome:' "$ACK_ROWS_FILE") || exit 1
    ACK_NOTICE_FINGERPRINTS=$(inactive_outcome_fingerprints "$ACK_THROUGH" 'inactive-reconcile:' "$ACK_ROWS_FILE") || exit 1
  else
    if { [ -e "$MAIN_ROWS_FILE" ] || [ -L "$MAIN_ROWS_FILE" ]; } \
      && ! rows_file_valid "$MAIN_ROWS_FILE"; then
      echo "wake drain: main acknowledgement has an invalid presented-row claim" >&2
      exit 1
    fi
    ACK_ROWS_FILE=$MAIN_ROWS_FILE
    ACK_FINGERPRINTS=$(inactive_outcome_fingerprints "$ACK_THROUGH" 'inactive-outcome:' "$ACK_ROWS_FILE") || exit 1
    ACK_NOTICE_FINGERPRINTS=$(inactive_outcome_fingerprints "$ACK_THROUGH" 'inactive-reconcile:' "$ACK_ROWS_FILE") || exit 1
  fi
  # Refuse before anything is consumed: a batch that carries an unanswered
  # captain note is not handled, however green everything else in it looks.
  # bin/jg-captain-note-lib.sh owns the test and the refusal text; the rows stay
  # queued, so the next drain presents the note again.
  if ! jg_captain_note_ack_gate "$STATE" "$JG_WAKE_QUEUE" "$ACK_ROWS_FILE" "$ACK_THROUGH"; then
    jg_lock_release "$JG_WAKE_QUEUE_LOCK"
    DRAIN_LOCK_HELD=false
    exit 1
  fi
  jg_lock_release "$JG_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  if ! acknowledge_inactive_outcomes acknowledge "$ACK_FINGERPRINTS" \
    || ! acknowledge_inactive_outcomes acknowledge-notice "$ACK_NOTICE_FINGERPRINTS"; then
    echo "wake drain: inactive outcome receipt could not be recorded safely" >&2
    exit 1
  fi
  jg_lock_acquire_wait "$JG_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=true
  # An acknowledgement is one event per row on the bus. Only rows at or below the
  # cutoff AND named in this actor's own snapshot are acknowledged, so a row
  # another actor owns - even one numbered below the cutoff - is never consumed.
  if [ "$ACTOR" = branch ]; then
    require_branch_eligible_rows || exit 1
    jg_wake_commit_squad_lead_stall_receipts_through "$ACK_THROUGH" "$ACK_ROWS_FILE" || {
      echo "wake drain: squad_lead stall receipt could not be recorded safely" >&2
      exit 1
    }
  else
    jg_wake_commit_squad_lead_stall_receipts_through "$ACK_THROUGH" "$ACK_ROWS_FILE" || {
      echo "wake drain: squad_lead stall receipt could not be recorded safely" >&2
      exit 1
    }
  fi
  jg_lock_acquire_wait "$STATE/.status-presentation-lock" || exit 1
  STATUS_LOCK_HELD=true
  jg_wake_status_ack check "$ACK_ROWS_FILE" "$ACK_THROUGH" || exit 1
  ACK_IDS=$(jg_wake_bus ids-through "$ACK_THROUGH" "$ACK_ROWS_FILE") || {
    echo 'wake drain: acknowledgement ids could not be read safely' >&2
    exit 1
  }
  ACK_REMOVED=0
  if [ -n "$ACK_IDS" ]; then
    ACK_REMOVED=$(printf '%s\n' "$ACK_IDS" | awk 'END { print NR }')
    # shellcheck disable=SC2086  # one id per line, each one event id
    jg_wake_bus ack $ACK_IDS || {
      echo "wake drain: acknowledged wakes could not be consumed safely" >&2
      exit 1
    }
  fi
  if [ "$ACK_REMOVED" -gt 0 ]; then
    jg_wake_status_ack commit "$ACK_ROWS_FILE" "$ACK_THROUGH" || exit 1
  fi
  jg_lock_release "$STATE/.status-presentation-lock"
  STATUS_LOCK_HELD=false
  ACK_QUEUE_LEFT=$(jg_wake_bus count 2>/dev/null || printf '0')
  if [ "$ACK_GENERATION" = none ]; then
    :   # a page-only acknowledgement: no queue generation was handed out, so none is retired
  elif [ "${ACK_QUEUE_LEFT:-0}" -eq 0 ]; then
    jg_recovery_marker_ack "$RECOVERY_MARKER" "$ACK_GENERATION"
    RECOVERY_ACK_STATUS=$?
    case "$RECOVERY_ACK_STATUS" in
      0) ;;
      3) RECOVERY_ACK_MOVED=true ;;
      *)
        echo "wake drain: recovery episode could not be retired safely; re-run bin/jg-wake-drain.sh and use the new WAKE_ACK_REQUIRED command" >&2
        exit 1
        ;;
    esac
  else
    jg_recovery_marker_snapshot "$RECOVERY_MARKER" || exit 1
    RECOVERY_MARKER_TOKEN=$JG_RECOVERY_MARKER_TOKEN
    if [ "${RECOVERY_MARKER_TOKEN##*:}" != "$ACK_GENERATION" ]; then
      RECOVERY_ACK_MOVED=true
    fi
  fi
  if [ "$ACTOR" = branch ]; then
    consume_actor_rows_locked "$ELIGIBLE_ROWS_FILE" "$ACK_THROUGH" || exit 1
  else
    consume_actor_rows_locked "$MAIN_ROWS_FILE" "$ACK_THROUGH" || exit 1
  fi
  jg_lock_release "$JG_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  if [ -n "$PAGES_ACK_ARG" ]; then
    if ! pages_ack_out=$(store_jg_item ack main "$PAGES_ACK_ARG" 2>&1); then
      echo "wake drain: the queue is acknowledged but Main's page cursor did not move: $pages_ack_out" >&2
      exit 1
    fi
  fi
  # A main acknowledgement that leaves nothing queued and no newer recovery episode is the
  # baseline bin/jg-wake-settled.sh compares the fleet against (docs/turnend-guard.md).
  if [ "$ACTOR" = main ] && [ "${ACK_QUEUE_LEFT:-0}" -eq 0 ] && [ "$RECOVERY_ACK_MOVED" != true ]; then
    jg_wake_core fleet-fp-record "$STATE/.wake-ack-fleet-fp" >/dev/null 2>&1 || true
  fi
  if [ "$ACK_REMOVED" -eq 0 ] && [ "$PRESENTED_MAX" -gt "$ACK_THROUGH" ]; then
    # Nothing at or below the cutoff was this actor's to consume, while a
    # presented row above it is still waiting: the caller acknowledged an
    # earlier wake, not the one it is handling. Say so, and name the exact
    # command for the current wake, so the remedy is never "drain again" (which
    # re-presents the same row and invites the same stale acknowledgement).
    # The generation is the marker's current one; only a retired marker cannot
    # be named because the next drain opens a fresh generation for it.
    case "$RECOVERY_MARKER_TOKEN" in
      pending:*|announced:*)
        printf 'wake drain: nothing was acknowledged through %s (none of your presented wake rows is at or below it); the current wake is row %s: run bin/jg-wake-drain.sh --ack-through %s --recovery-generation %s after handling it\n' \
          "$ACK_THROUGH" "$PRESENTED_MAX" "$PRESENTED_MAX" "${RECOVERY_MARKER_TOKEN##*:}" >&2
        ;;
      *)
        printf 'wake drain: nothing was acknowledged through %s (none of your presented wake rows is at or below it); the current wake is row %s: re-run bin/jg-wake-drain.sh and use the WAKE_ACK_REQUIRED command it prints\n' \
          "$ACK_THROUGH" "$PRESENTED_MAX" >&2
        ;;
    esac
  elif [ "$RECOVERY_ACK_MOVED" = true ]; then
    printf 'wake drain: acknowledged wakes through %s (%s row(s) consumed), but a newer recovery episode is pending; re-run bin/jg-wake-drain.sh and use the new WAKE_ACK_REQUIRED command\n' \
      "$ACK_THROUGH" "$ACK_REMOVED" >&2
  fi
  exit 0
fi

# The rows are the bus's now: bring the read model up to date before any actor
# reads it. Rendering outside the queue lock is safe - the renderer replaces the
# file atomically and nothing else writes it.
jg_wake_bus render >/dev/null 2>&1 || true

if [ ! -s "$JG_WAKE_QUEUE" ]; then
  : > "$JG_WAKE_QUEUE"
  jg_recovery_marker_snapshot "$RECOVERY_MARKER" || true
  RECOVERY_MARKER_TOKEN=$JG_RECOVERY_MARKER_TOKEN
  case "$RECOVERY_MARKER_TOKEN" in
    pending:downtime:*|announced:downtime:*)
      jg_recovery_marker_begin_handling "$RECOVERY_MARKER" || {
        echo "wake drain: decision recovery could not begin handling safely" >&2
        exit 1
      }
      RECOVERY_MARKER_TOKEN=$JG_RECOVERY_MARKER_TOKEN
      RECOVERY_ACK_REQUIRED=true
      ;;
    pending:handling:*|announced:handling:*) RECOVERY_ACK_REQUIRED=true ;;
  esac
  jg_lock_release "$JG_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  jg_captain_notes_must_answer "$STATE" || true
  if [ "$STORE_MODE" = true ]; then print_store_sections; else (print_status_presentation) || true; fi
  print_branch_outcomes_section || BRANCH_OUTCOMES_RC=1
  if [ "$RECOVERY_ACK_REQUIRED" = true ]; then
    print_ack_required 0 "${RECOVERY_MARKER_TOKEN##*:}"
  elif [ "$PAGES_ACK" -gt 0 ]; then
    print_ack_required 0 none
  fi
  assert_watcher_liveness
  exit "$BRANCH_OUTCOMES_RC"
fi

if [ "$ACTOR" = main ]; then
  if [ -e "$ELIGIBLE_ROWS_FILE" ] || [ -L "$ELIGIBLE_ROWS_FILE" ]; then
    require_branch_eligible_rows || exit 1
  fi
  claim_main_rows_locked || exit 1
  if [ ! -s "$MAIN_ROWS_FILE" ]; then
    # Every remaining row is reserved by the live branch grant, which presents
    # and acknowledges them itself. Say so rather than exiting silently: a
    # drain that prints nothing while the queue is visibly non-empty reads as a
    # lost wake, and leaves the caller with no idea who owns what is queued.
    jg_captain_notes_must_answer "$STATE" || true
    print_branch_held_notice
    jg_lock_release "$JG_WAKE_QUEUE_LOCK"
    DRAIN_LOCK_HELD=false
    if [ "$STORE_MODE" = true ]; then print_store_sections; else (print_status_presentation) || true; fi
    print_branch_outcomes_section || BRANCH_OUTCOMES_RC=1
    if [ "$PAGES_ACK" -gt 0 ]; then print_ack_required 0 none; fi
    assert_watcher_liveness
    exit "$BRANCH_OUTCOMES_RC"
  fi
fi

jg_recovery_marker_snapshot "$RECOVERY_MARKER" || true
RECOVERY_MARKER_TOKEN=$JG_RECOVERY_MARKER_TOKEN
if [ -z "$RECOVERY_MARKER_TOKEN" ]; then
  if [ -e "$RECOVERY_MARKER" ] || [ -L "$RECOVERY_MARKER" ]; then
    echo "wake drain: durable wakes have invalid recovery state" >&2
    exit 1
  fi
  jg_recovery_marker_publish "$RECOVERY_MARKER" downtime || {
    echo "wake drain: legacy durable wakes could not be adopted safely" >&2
    exit 1
  }
elif [ "${RECOVERY_MARKER_TOKEN%%:*}" = acked ]; then
  jg_recovery_marker_publish "$RECOVERY_MARKER" downtime || {
    echo "wake drain: durable wakes could not enter a fresh recovery generation" >&2
    exit 1
  }
fi
jg_recovery_marker_begin_handling "$RECOVERY_MARKER" || {
  echo "wake drain: durable wakes could not begin handling safely" >&2
  exit 1
}
RECOVERY_MARKER_TOKEN=$JG_RECOVERY_MARKER_TOKEN

DRAIN_VIEW_TMP=$(mktemp "$STATE/.wake-queue.actor-view.XXXXXX") || exit 1
if [ "$ACTOR" = branch ]; then
  ACTOR_ROWS_FILE=$ELIGIBLE_ROWS_FILE
else
  ACTOR_ROWS_FILE=$MAIN_ROWS_FILE
fi
awk -F '\t' -v seqs="$ACTOR_ROWS_FILE" '
  BEGIN { while ((getline line < seqs) > 0) keep[line]=1 }
  NF >= 5 && ($2 in keep)
' "$JG_WAKE_QUEUE" > "$DRAIN_VIEW_TMP" || exit 1
STATUS_ROWS=$(cat "$DRAIN_VIEW_TMP") || exit 1
RAW_ROWS=$(jg_wake_print_deduped "$DRAIN_VIEW_TMP") || exit "$?"
rm -f -- "$DRAIN_VIEW_TMP" || exit 1
DRAIN_VIEW_TMP=
ACK_THROUGH=$(printf '%s\n' "$RAW_ROWS" | awk -F '\t' '$2 ~ /^[0-9]+$/ && $2 > max { max=$2 } END { print max + 0 }') || exit 1
case "${JG_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT:-0}" in
  0) ;;
  ''|*[!0-9]*) ;;
  *) sleep "$JG_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT" ;;
esac
jg_captain_notes_must_answer "$STATE" || true
if [ "$STORE_MODE" = true ]; then
  build_queued_view "$RAW_ROWS"
  [ "$QUEUED_CUT" -eq 0 ] || ACK_THROUGH=$QUEUED_CUT
  printf 'QUEUED (each queued wake record'"'"'s reason line, oldest first):\n%squeued: %d\n' "$QUEUED_TEXT" "$QUEUED_N" || exit "$?"
  [ "$QUEUED_CUT" -eq 0 ] || printf 'QUEUED: more records follow; they are presented on the next drain once you acknowledge these\n' || exit "$?"
elif [ -n "$RAW_ROWS" ]; then
  build_raw_view "$RAW_ROWS" || exit "$?"
  [ -z "$RAW_TEXT" ] || printf '%s\n' "$RAW_TEXT" || exit "$?"
  if [ "$RAW_CUT" -gt 0 ]; then
    ACK_THROUGH=$RAW_CUT
    STATUS_ROWS=$(printf '%s\n' "$STATUS_ROWS" | awk -F '\t' -v cut="$RAW_CUT" '$2 + 0 <= cut') || exit 1
    printf 'WAKE QUEUE: %d queued event(s), the oldest shown; the rest follow on the next drain once you acknowledge these (they stay in state/.wake-queue)\n' "$RAW_N" || exit "$?"
  fi
fi
jg_recovery_marker_snapshot "$RECOVERY_MARKER" || exit 1
RECOVERY_MARKER_TOKEN=$JG_RECOVERY_MARKER_TOKEN
case "$RECOVERY_MARKER_TOKEN" in
  pending:*|announced:*|acked:*) ;;
  *) echo "wake drain: durable wakes have no recovery generation" >&2; exit 1 ;;
esac
jg_lock_release "$JG_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false
print_ack_required "$ACK_THROUGH" "${RECOVERY_MARKER_TOKEN##*:}"

if [ "$STORE_MODE" = true ]; then
  print_store_sections
elif ! (print_status_presentation "$STATUS_ROWS"); then
  echo 'wake drain: status presentation incomplete; acknowledgement remains gated until a successful drain' >&2
  exit 1
fi
print_branch_outcomes_section || BRANCH_OUTCOMES_RC=1
assert_watcher_liveness
exit "$BRANCH_OUTCOMES_RC"
