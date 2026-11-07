#!/usr/bin/env bash
# Hand already-identified, in-scope backlog items off from the main juggernaut
# backlog to a squad_lead's own home backlog. Use this when a squad_lead is
# created (or whenever an existing queued item should become its domain's work)
# so the squad_lead owns its queue from day one instead of the item staying
# stranded in the main backlog.
#
# Scope-matching is juggernaut's JUDGMENT: you pass the task-id keys you have
# already judged in-scope for the squad_lead. This script performs only the
# fleet-level validation that the backlog cannot know, then DELEGATES the actual
# row move to the Beads store: bd export and bd import move the rows (stage, take
# and drop writes), and a rerun settles a crash. A remote handoff stages the
# rows in the outbox file.
#
# What this script still owns (never delegated):
#   - resolving the squad_lead home from data/squad_leads.md;
#   - proving the destination is a genuine seeded squad_lead home
#     (.jg-squad-lead-home marker, AGENTS.md + bin/), never a project clone, the
#     active home, or the juggernaut repo;
#   - moving only `## Queued` items, refusing `## In flight` and historical
#     `## Done` records, which must stay with their home for pruning or
#     archiving;
#   - the multi-key classification and idempotent per-key reporting: a key
#     already present in the squad_lead backlog is reported and skipped, and if
#     any key matches neither backlog nothing is moved;
#   - warning, after a successful move, when a moved key still owes a public
#     relay reply bound to main/<key>, or when this home has an open public loop
#     with nothing owed, because routing work out does not close that loop. The
#     move is not blocked: rebinding or rechain is a relay-side decision the
#     caller makes.
#
# The Beads writes own moving each full row with its body, a whole connected set
# (a blocker and its dependents) together with links preserved, and refusing a
# move that would strand a dependency across the two stores; that error is
# surfaced verbatim. Idempotent: re-running converges.
# See AGENTS.md project management and task lifecycle.
# Rows are classified on a rendered copy of each store: the target files them
# first, and only then does the source let them go. A failure between the two
# leaves the prepared wake in place, and rerunning the same handoff finishes the
# release.
# Remote routes use an outbox handoff: one atomic local stage selects the set into
# data/handoff/<id>.outbox.md, then an idempotent confined transfer and
# jg-backlog-receive.sh deliver it.
# A present outbox remains the remote retry trigger only until backlog receipt
# is confirmed, then it is released independently of the best-effort receiver
# wake. The wake remains separately tracked by one pending-reply correlation and
# is retried by later resumes and handoffs without blocking new backlog work.
# An undelivered wake stays retryable under that same correlation even after the
# watcher escalates its unknown delivery; only confirmed delivery prevents a
# resend. A prepared local wake is bound to the exact sorted
# requested-key batch; an unrelated handoff to that mate refuses until the
# original batch is retried, so it cannot discard wake intent for work that
# already moved. No two-phase journal exists.
# Every newly durable backlog delivery attempts one marked wake to the receiving
# endpoint. A local route moves directly into the destination backlog, and a
# missing or rejected local wake makes that command fail with the move intact so
# rerunning the same handoff retries its prepared wake intent. After a durable
# remote receipt, the outbox is released and the handoff succeeds regardless of
# the best-effort wake outcome; an undelivered remote wake remains separately
# tracked in wake-pending state and is retried under the same correlation by
# later resumes and handoffs. If wake-pending state cannot be recorded, the wake
# is reported as DROPPED and marker removal is attempted while the mate still
# owns reconciliation from its durable backlog. Any unsafe, invalid, delivered,
# or undeletable stale marker is reported and ignored by later resumes and
# handoffs, so wake-state cleanup neither suppresses a new wake nor fails a
# completed remote handoff.
# Usage: jg-backlog-handoff.sh <squad-lead-id> <item-key>...
#        jg-backlog-handoff.sh --resume-pending
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
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
REG="$DATA/squad_leads.md"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
MOVE_DIR=
MAIN_BACKLOG=
# shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-lib.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-public-followup-lib.sh
. "$SCRIPT_DIR/jg-public-followup-lib.sh"
# shellcheck source=bin/jg-pending-reply-lib.sh
. "$SCRIPT_DIR/jg-pending-reply-lib.sh"

RECEIVER_WAKE_MESSAGE='New routed work is in your backlog. Run bin/jg-session-start.sh now, then act on the routed task.'

ACTIVE_HANDOFF_LOCK=
ACTIVE_REGISTRY_LOCK=
RECEIVER_WAKE_IGNORE_ID=
release_remote_locks() {
  if [ -n "$ACTIVE_HANDOFF_LOCK" ]; then
    jg_lock_release "$ACTIVE_HANDOFF_LOCK"
    ACTIVE_HANDOFF_LOCK=
  fi
  if [ -n "$ACTIVE_REGISTRY_LOCK" ]; then
    jg_lock_release "$ACTIVE_REGISTRY_LOCK"
    ACTIVE_REGISTRY_LOCK=
  fi
}
trap 'release_remote_locks; [ -z "$MOVE_DIR" ] || rm -rf -- "$MOVE_DIR"' EXIT
trap 'exit 1' HUP INT TERM

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

RESUME_PENDING=0
if [ "${1:-}" = --resume-pending ]; then
  [ "$#" -eq 1 ] || {
    echo "usage: jg-backlog-handoff.sh --resume-pending" >&2
    exit 1
  }
  RESUME_PENDING=1
  ID=
  shift
else
  [ "$#" -ge 2 ] || {
    echo "usage: jg-backlog-handoff.sh <squad-lead-id> <item-key>..." >&2
    exit 1
  }
  ID=$1
  case "$ID" in '' | *[!A-Za-z0-9._-]*)
    echo "error: unsafe squad_lead id: $ID" >&2
    exit 1
    ;;
  esac
  shift
fi

squad_lead_home() {
  local id=$1 home
  [ -f "$REG" ] || {
    echo "error: no squad_lead registry at $REG" >&2
    return 1
  }
  home=$(squad_lead_registry_field "$REG" "$id" home || true)
  [ -n "$home" ] || {
    echo "error: squad_lead $id has no home in $REG" >&2
    return 1
  }
  printf '%s\n' "$home"
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
  "$ancestor"/*) return 0 ;;
  esac
  return 1
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || {
    echo "error: juggernaut home does not exist or is not a directory: $path" >&2
    return 1
  }
  cd "$path" && pwd -P
}

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: squad_lead $name directory must resolve inside the squad_lead home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: squad_lead $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: squad_lead $name directory must resolve inside the squad_lead home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: squad_lead $name directory cannot be inside the active juggernaut home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: squad_lead $name directory cannot be inside the juggernaut repo: $dir" >&2
      return 1
    fi
  done
}

validate_squad_lead_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$JG_HOME")
  abs_root=$(resolved_existing_dir "$JG_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: squad_lead home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: squad_lead home cannot be the active juggernaut home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: squad_lead home cannot be the juggernaut repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: squad_lead home cannot be inside the active juggernaut home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: squad_lead home cannot be inside the juggernaut repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: squad_lead home cannot be an ancestor of the active juggernaut home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: squad_lead home cannot be an ancestor of the juggernaut repo: $home" >&2
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$(jg_compat_marker "$abs_home")" ]; then
    echo "error: juggernaut home $home is not a seeded squad_lead home" >&2
    return 1
  fi
  marker_id=$(cat "$(jg_compat_marker "$abs_home")" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: juggernaut home $home is marked for squad_lead ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a juggernaut home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a juggernaut home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_backlog_file() {
  local label=$1 path=$2
  if [ -L "$path" ]; then
    echo "error: $label must not be a symlink: $path" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "error: $label is not a regular file: $path" >&2
    return 1
  fi
}

# Classify a single key by the section it lives under (## In flight /
# ## Queued / ## Done), or return non-zero if no `- [ ] <key>` / `- [x] <key>`
# header exists in the file. This reads only section headings and item header
# lines - never item bodies - so it drives the fleet-level classification (in-
# flight refusal, already-present idempotency, missing-key abort) without
# re-implementing the row move semantics that the Beads writes own.
backlog_key_section() {
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "## ", section)
      sub(/[[:space:]]+$/, "", section)
      next
    }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

backlog_key_noncanonical_body_lines() {
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { capturing = 1 }
      next
    }
    capturing && /^##[[:space:]]+/ { exit }
    capturing && /^[[:space:]]/ && !/^  / && /[^[:space:]]/ { print }
  ' "$file"
}

seed_backlog_scaffold() { # <path>
  mkdir -p "$(dirname "$1")"
  [ -f "$1" ] || printf '## In flight\n\n## Queued\n\n## Done\n' >"$1"
}

render_store() { # <config> <name>: renders that home's store to MOVE_DIR/<name>.md
  [ -n "$MOVE_DIR" ] || MOVE_DIR=$(mktemp -d) || return 1
  jg_backlog_beads_read "$1" markdown >"$MOVE_DIR/$2.md"
}

read_main_store() {
  render_store "$CONFIG" main || return 1
  MAIN_BACKLOG=$MOVE_DIR/main.md
}

# Exit 3 says the target may hold rows the source still holds, so the wake stays prepared.
move_rows() { # <keys...>
  local rows="$MOVE_DIR/rows.jsonl" rc=0
  jg_backlog_beads_write "$CONFIG" stage --native "$@" >"$rows" || {
    cat -- "$rows"
    return 1
  }
  jg_backlog_beads_write "$SUB_HOME/config" take "$rows" "$@" || rc=$?
  [ "$rc" -ne 2 ] || return 1
  [ "$rc" -eq 0 ] || return 3
  jg_backlog_beads_write "$CONFIG" drop "$@" || return 3
}

# A public commitment made through the relay binds its work by home AND id, so an
# item that leaves this home takes that binding out of sync: reconciliation would
# still look for main/<key> while the work now lives in the squad_lead's home.
# The move itself stays safe and is never blocked - rebinding is a relay-side
# decision the caller owns - but this is the one moment the staleness is
# detectable, so report it loudly instead of letting the promise go quiet.
# A home that never opted into the relay pays one presence check per key here.
warn_stale_public_commitments() { # <squad-lead-id> <moved-key>...
  local id=$1 key out rc
  shift
  for key in "$@"; do
    rc=0
    out=$("$SCRIPT_DIR/jg-public-followup.sh" guard-work main "$key" 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ] || continue
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    printf 'warning: %s still owes a public reply bound to main/%s; rebind it to squad_lead:%s (bin/jg-backlog.sh public-followup bind-work, then bin/jg-public-followup.sh register <obligation-id> --relation <relation-id> --work-home squad_lead:%s --work-id %s --generation <n>) or the promised reply will be reconciled against work this home no longer owns.\n' \
      "$key" "$key" "$id" "$id" "$key" >&2
  done
  if jg_pf_relay_active "$JG_HOME" && jg_pf_has_delivered_open_loops "$STATE"; then
    printf 'warning: this home has an open public loop with nothing owed; routing work to squad_lead:%s does not close it. Hand it on with bin/jg-public-followup.sh rechain or close it with retire --reason.\n' \
      "$id" >&2
  fi
  # Reporting never changes the handoff's own success: the move already landed.
  return 0
}

# Wake a live receiver after its backlog has become durable. The marked message
# uses the normal endpoint route and verified submit for both placements. A
# failed local wake fails that local handoff, while a failed remote wake is
# handled as the best-effort state described in the script contract above. A
# seeded but not-yet-spawned home is a valid handoff destination, but its missing
# endpoint is reported rather than pretending the task was started.
receiver_wake_batch_id() { # <item-key>...
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s\n' "$@" | LC_ALL=C sort | shasum -a 256 2>/dev/null | awk '{print $1}')
  else
    digest=$(printf '%s\n' "$@" | LC_ALL=C sort | sha256sum 2>/dev/null | awk '{print $1}')
  fi
  printf '%s' "$digest" | grep -Eq '^[a-f0-9]{64}$' || return 1
  printf '%s' "${digest:0:16}"
}

receiver_wake_state_write() { # <squad-lead-id> <state>
  local id=$1 value=$2 marker="$STATE/.backlog-handoff-$1.wake-pending" tmp
  case "$id" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$value" in
  pending | confirmed) ;;
  prepared:*) printf '%s' "$value" | grep -Eq '^prepared:[a-f0-9]{16}:[a-f0-9]{16}$' || return 1 ;;
  pending:*) printf '%s' "$value" | grep -Eq '^pending:[a-f0-9]{16}$' || return 1 ;;
  confirmed:*) printf '%s' "$value" | grep -Eq '^confirmed:[a-f0-9]{16}$' || return 1 ;;
  *) return 1 ;;
  esac
  tmp=$(
    umask 077
    mktemp "$STATE/.backlog-handoff-wake.XXXXXX"
  ) || return 1
  if ! printf '%s\n' "$value" >"$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

receiver_wake_mark() { # <squad-lead-id> <prepared|pending> [batch-id]
  local id=$1 wake_phase=$2 batch=${3:-} marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec
  local wake_state
  case "$wake_phase" in prepared | pending) ;; *) return 1 ;; esac
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    value=$(cat "$marker" 2>/dev/null || true)
    case "$value" in
    prepared:*)
      corr=${value#*:}
      corr=${corr%%:*}
      rec=$(jg_pending_reply_path "$STATE" "$corr")
      [ -f "$rec" ] && [ ! -L "$rec" ] &&
        [ "$(jg_pending_reply_get "$rec" task_id)" = "$id" ]
      return $?
      ;;
    pending:*)
      receiver_wake_pending_valid "$id"
      return $?
      ;;
    pending) ;;
    *) return 1 ;;
    esac
  fi
  corr=$(jg_pending_reply_create "$JG_HOME" "$STATE" "$id" "$RECEIVER_WAKE_MESSAGE") || return 1
  wake_state="$wake_phase:$corr"
  if [ "$wake_phase" = prepared ]; then
    printf '%s' "$batch" | grep -Eq '^[a-f0-9]{16}$' || return 1
    wake_state="$wake_state:$batch"
  fi
  if ! receiver_wake_state_write "$id" "$wake_state"; then
    jg_pending_reply_discard_undelivered "$STATE" "$corr" || true
    return 1
  fi
}

receiver_wake_mark_pending() { # <squad-lead-id>
  receiver_wake_mark "$1" pending
}

receiver_wake_mark_prepared() { # <squad-lead-id> <batch-id>
  receiver_wake_mark "$1" prepared "$2"
}

receiver_wake_discard_prepared() { # <squad-lead-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
  prepared:*)
    corr=${value#prepared:}
    corr=${corr%%:*}
    ;;
  *) return 1 ;;
  esac
  jg_pending_reply_discard_undelivered "$STATE" "$corr" || return 1
  rm -f -- "$marker"
}

receiver_wake_promote_prepared() { # <squad-lead-id> <batch-id>
  local id=$1 batch=$2 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
  prepared:*:"$batch")
    corr=${value#prepared:}
    corr=${corr%%:*}
    ;;
  pending:*) return 0 ;;
  *) return 1 ;;
  esac
  receiver_wake_state_write "$id" "pending:$corr"
}

receiver_wake_pending_valid() { # <squad-lead-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec delivered
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in pending:*) corr=${value#pending:} ;; *) return 1 ;; esac
  printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || return 1
  rec=$(jg_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] &&
    [ "$(jg_pending_reply_get "$rec" task_id)" = "$id" ] || return 1
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  jg_pending_reply_corr_reusable "$STATE" "$corr" "$id"
}

receiver_wake_pending_delivered_valid() { # <squad-lead-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in pending:*) corr=${value#pending:} ;; *) return 1 ;; esac
  printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || return 1
  rec=$(jg_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] &&
    [ "$(jg_pending_reply_get "$rec" task_id)" = "$id" ] &&
    [ -n "$(jg_pending_reply_get "$rec" delivered_epoch)" ]
}

receiver_wake_confirmed_valid() { # <squad-lead-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  [ "$value" != confirmed ] || return 0
  case "$value" in confirmed:*) corr=${value#confirmed:} ;; *) return 1 ;; esac
  printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || return 1
  rec=$(jg_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] &&
    [ "$(jg_pending_reply_get "$rec" task_id)" = "$id" ] &&
    [ -n "$(jg_pending_reply_get "$rec" delivered_epoch)" ]
}

receiver_wake_drop_marker() { # <squad-lead-id> <reason>
  local id=$1 reason=$2 marker="$STATE/.backlog-handoff-$1.wake-pending"
  printf 'receiver wake state: DROPPED marker=%s\n' "$marker"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    if rm -f -- "$marker"; then
      printf 'warning: best-effort receiver wake for squad_lead %s was dropped; removed stale wake marker %s because %s\n' "$id" "$marker" "$reason" >&2
    else
      printf 'warning: best-effort receiver wake for squad_lead %s was dropped; stale wake marker remains at %s because %s\n' "$id" "$marker" "$reason" >&2
    fi
  else
    printf 'warning: best-effort receiver wake for squad_lead %s was dropped; no wake marker remains at %s because %s\n' "$id" "$marker" "$reason" >&2
  fi
  return 0
}

receiver_wake_clear_confirmed() { # <squad-lead-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending"
  RECEIVER_WAKE_IGNORE_ID=
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  if receiver_wake_pending_valid "$id"; then
    return 0
  fi
  if receiver_wake_pending_delivered_valid "$id" || receiver_wake_confirmed_valid "$id"; then
    if ! rm -f -- "$marker"; then
      RECEIVER_WAKE_IGNORE_ID=$id
      printf 'warning: confirmed receiver wake left a stale marker at %s; later handoffs will ignore it\n' "$marker" >&2
    fi
    return 0
  fi
  receiver_wake_drop_marker "$id" 'wake-pending state is unsafe or invalid'
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    RECEIVER_WAKE_IGNORE_ID=$id
  fi
}

wake_squad_lead_receiver() { # <squad-lead-id> <correlation-id>
  local id=$1 corr=$2 meta="$STATE/$1.meta" out rc=0
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    printf 'error: handed off work to squad_lead %s, but no live receiver endpoint is recorded; the destination backlog is durable and the receiver was not woken\n' "$id" >&2
    return 1
  fi
  [ "$(jg_compat_kind "$(grep '^kind=' "$meta" | cut -d= -f2-)")" = squad_lead ] || {
    printf 'error: squad_lead %s has non-squad-lead endpoint metadata; backlog is durable but the receiver was not woken\n' "$id" >&2
    return 1
  }
  out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" JG_ROOT_OVERRIDE="$JG_ROOT" \
    JG_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/jg-send.sh" "$id" "$RECEIVER_WAKE_MESSAGE" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    printf 'error: backlog delivery to squad_lead %s succeeded, but its receiver wake failed; retry a tracked remote wake with --resume-pending or a later new handoff, and retry a local wake by rerunning its handoff\n' "$id" >&2
    return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

wake_pending_squad_lead_receiver() { # <squad-lead-id> [retain-confirmed]
  local id=$1 retain=${2:-0} marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec delivered
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  if [ ! -f "$marker" ] || [ -L "$marker" ]; then
    printf 'error: receiver wake state for squad_lead %s is unsafe or invalid\n' "$id" >&2
    return 1
  fi
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
  confirmed | confirmed:*) return 0 ;;
  prepared | prepared:*)
    printf 'error: receiver wake for squad_lead %s was prepared before its backlog became durable\n' "$id" >&2
    return 1
    ;;
  pending)
    receiver_wake_mark_pending "$id" || return 1
    value=$(cat "$marker" 2>/dev/null || true)
    ;;
  esac
  case "$value" in pending:*) corr=${value#pending:} ;; *)
    printf 'error: receiver wake state for squad_lead %s is unsafe or invalid\n' "$id" >&2
    return 1
    ;;
  esac
  rec=$(jg_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] &&
    [ "$(jg_pending_reply_get "$rec" task_id)" = "$id" ] || return 1
  jg_pending_reply_reconcile_delivery "$STATE" "$corr" >/dev/null 2>&1 || true
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    jg_pending_reply_corr_reusable "$STATE" "$corr" "$id" || {
      printf 'error: receiver wake delivery for squad_lead %s is unresolved; refusing to resend correlation %s\n' "$id" "$corr" >&2
      return 1
    }
    wake_squad_lead_receiver "$id" "$corr" || return 1
  fi
  if [ "$retain" = 1 ]; then
    receiver_wake_state_write "$id" "confirmed:$corr" || {
      printf 'error: receiver wake for squad_lead %s was confirmed, but confirmed state could not be recorded\n' "$id" >&2
      return 1
    }
  else
    rm -f -- "$marker" || {
      printf 'error: receiver wake for squad_lead %s was confirmed, but pending state could not be cleared\n' "$id" >&2
      return 1
    }
  fi
}

outbox_item_count() { # <path>
  awk '/^- \[[ x]\] / { count++ } END { print count + 0 }' "$1"
}

remote_deliver_outbox() { # <squad-lead-id> <outbox-path>
  local id=$1 outbox=$2 remote_rel receive_out snapshot bytes hash generation counter counter_tmp current marker wake_rc=0 wake_state=pending
  [ -f "$outbox" ] && [ ! -L "$outbox" ] || {
    echo "error: pending outbox is unavailable or unsafe: $outbox" >&2
    return 1
  }
  snapshot=$(
    umask 077
    mktemp "${TMPDIR:-/tmp}/jg-handoff-payload.XXXXXX"
  ) || return 1
  if ! cp -p -- "$outbox" "$snapshot"; then
    rm -f -- "$snapshot"
    return 1
  fi
  bytes=$(LC_ALL=C wc -c <"$snapshot" | tr -d ' ')
  hash=$(sha256_file "$snapshot") || {
    rm -f -- "$snapshot"
    return 1
  }
  counter="$STATE/.remote-handoff-$id.generation"
  current=0
  if [ -e "$counter" ] || [ -L "$counter" ]; then
    [ -f "$counter" ] && [ ! -L "$counter" ] || {
      rm -f -- "$snapshot"
      return 1
    }
    IFS= read -r current <"$counter" || {
      rm -f -- "$snapshot"
      return 1
    }
    case "$current" in '' | *[!0-9]*)
      rm -f -- "$snapshot"
      return 1
      ;;
    esac
    [ "${#current}" -le 17 ] || {
      rm -f -- "$snapshot"
      return 1
    }
  fi
  generation=$((current + 1))
  counter_tmp=$(
    umask 077
    mktemp "$STATE/.remote-handoff-generation.XXXXXX"
  ) ||
    {
      rm -f -- "$snapshot"
      return 1
    }
  printf '%s\n' "$generation" >"$counter_tmp" ||
    {
      rm -f -- "$snapshot" "$counter_tmp"
      return 1
    }
  chmod 600 "$counter_tmp" ||
    {
      rm -f -- "$snapshot" "$counter_tmp"
      return 1
    }
  mv -f -- "$counter_tmp" "$counter" ||
    {
      rm -f -- "$snapshot" "$counter_tmp"
      return 1
    }
  remote_rel="state/handoff/$id.outbox.md"
  if ! "$SCRIPT_DIR/jg-on.sh" --stdin "$id" jg-remote-file.sh put "$remote_rel" 1048576 \
    "$bytes" "$hash" "$generation" <"$snapshot"; then
    rm -f -- "$snapshot"
    echo "error: handoff transfer to $id was unavailable or completion is unknown; outbox preserved at $outbox" >&2
    return 1
  fi
  rm -f -- "$snapshot"
  if ! receive_out=$("$SCRIPT_DIR/jg-on.sh" "$id" jg-backlog-receive.sh \
    "$remote_rel" "$bytes" "$hash" "$generation" </dev/null 2>&1); then
    [ -z "$receive_out" ] || printf '%s\n' "$receive_out" >&2
    echo "error: handoff receipt by $id was unavailable or completion is unknown; outbox preserved at $outbox" >&2
    return 1
  fi
  marker="$STATE/.backlog-handoff-$id.wake-pending"
  if [ "$RECEIVER_WAKE_IGNORE_ID" = "$id" ]; then
    wake_state=dropped
    wake_rc=1
  elif ! receiver_wake_pending_valid "$id" && ! receiver_wake_confirmed_valid "$id"; then
    receiver_wake_mark_pending "$id" || {
      wake_state=dropped
      wake_rc=1
    }
  fi
  if [ "$wake_rc" -eq 0 ]; then
    wake_pending_squad_lead_receiver "$id" 1 || wake_rc=$?
  fi
  rm -f -- "$outbox" || {
    echo "error: remote backlog is durable at $id, but local outbox cleanup failed: $outbox" >&2
    return 1
  }
  if [ "$wake_rc" -eq 0 ]; then
    if ! rm -f -- "$marker"; then
      RECEIVER_WAKE_IGNORE_ID=$id
      echo "warning: remote outbox and receiver wake completed, but a stale confirmed wake marker remains at $marker; later handoffs will ignore it" >&2
    fi
  elif [ "$wake_state" = dropped ]; then
    receiver_wake_drop_marker "$id" 'wake-pending state could not be recorded'
    echo "warning: remote backlog is durable at $id and its outbox was released after the best-effort receiver wake was dropped" >&2
  else
    echo "warning: remote backlog is durable at $id and its outbox was released; the best-effort receiver wake remains pending for a later resume or handoff" >&2
  fi
  printf '%s\n' "$receive_out"
}

remove_interrupted_source_duplicates() { # <outbox> <keys...>
  local outbox=$1 key
  local -a staged=()
  shift
  for key in "$@"; do
    if backlog_key_section "$outbox" "$key" >/dev/null 2>&1 &&
      backlog_key_section "$MAIN_BACKLOG" "$key" >/dev/null 2>&1; then staged+=("$key"); fi
  done
  [ "${#staged[@]}" -gt 0 ] || return 0
  jg_backlog_beads_write "$CONFIG" drop "${staged[@]}" >&2 && return 0
  echo "error: could not complete source removal; outbox remains authoritative at $outbox" >&2
  return 1
}

remote_handoff() { # <squad-lead-id> <keys...>
  local id=$1 outbox main_section out_section key check_out check_rc=0
  local -a requested to_move already missing in_flight done_items not_queued
  shift
  requested=("$@")
  outbox="$DATA/handoff/$id.outbox.md"
  read_main_store || return 1
  validate_backlog_file "main backlog" "$MAIN_BACKLOG" || return 1
  validate_backlog_file "remote handoff outbox" "$outbox" || return 1
  if [ ! -e "$outbox" ] && [ ! -L "$outbox" ]; then
    receiver_wake_clear_confirmed "$id" || {
      echo "error: stale receiver wake state for squad_lead $id could not be cleared" >&2
      return 1
    }
  fi
  to_move=()
  already=()
  missing=()
  in_flight=()
  done_items=()
  not_queued=()
  for key in "${requested[@]}"; do
    out_section=$(backlog_key_section "$outbox" "$key" 2>/dev/null || true)
    main_section=$(backlog_key_section "$MAIN_BACKLOG" "$key" 2>/dev/null || true)
    if [ -n "$out_section" ]; then
      [ "$out_section" = '## Queued' ] || not_queued+=("$key")
      already+=("$key")
      continue
    fi
    case "$main_section" in
    '## Queued') to_move+=("$key") ;;
    '## In flight') in_flight+=("$key") ;;
    '## Done') done_items+=("$key") ;;
    '') missing+=("$key") ;;
    *) not_queued+=("$key") ;;
    esac
  done
  if [ "${#in_flight[@]}" -gt 0 ] || [ "${#done_items[@]}" -gt 0 ] ||
    [ "${#not_queued[@]}" -gt 0 ] || [ "${#missing[@]}" -gt 0 ]; then
    [ "${#in_flight[@]}" -eq 0 ] || echo "error: refusing to hand off in-flight backlog items: ${in_flight[*]}" >&2
    [ "${#done_items[@]}" -eq 0 ] || echo "error: refusing to hand off Done backlog items: ${done_items[*]}" >&2
    [ "${#not_queued[@]}" -eq 0 ] || echo "error: refusing to hand off non-Queued outbox or backlog items: ${not_queued[*]}" >&2
    [ "${#missing[@]}" -eq 0 ] || echo "error: no backlog or pending outbox item matched: ${missing[*]}" >&2
    echo "       nothing new was staged." >&2
    return 1
  fi
  for key in "${to_move[@]+"${to_move[@]}"}"; do
    while IFS= read -r line; do
      printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' "$key" "$line" >&2
      return 1
    done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
  done
  # Do not append a fresh handoff to an older recovery batch. In particular, a
  # confirmed wake can survive when outbox cleanup fails; if new work were
  # staged into that outbox, the old confirmation would suppress the wake for
  # the new work. Finish receipt, wake reconciliation, and cleanup for the old
  # batch first. A failure leaves the fresh items dispatchable in main.
  if [ "${#to_move[@]}" -gt 0 ] && [ -f "$outbox" ] &&
    [ "$(outbox_item_count "$outbox")" -gt 0 ]; then
    remote_deliver_outbox "$id" "$outbox" || {
      echo "error: previous remote handoff for squad_lead $id could not be completed; nothing new was staged" >&2
      return 1
    }
  fi
  # Exit 3 is the receiver's own no: nothing is staged. Anything else, such as an
  # unreachable host or an older receiver, keeps the outbox retry that follows.
  if [ "${#to_move[@]}" -gt 0 ]; then
    check_out=$("$SCRIPT_DIR/jg-on.sh" "$id" jg-backlog-receive.sh --check </dev/null 2>&1) || check_rc=$?
    if [ "$check_rc" -eq 3 ]; then
      [ -z "$check_out" ] || printf '%s\n' "$check_out" >&2
      echo "error: squad_lead $id cannot receive rows now; nothing new was staged" >&2
      return 1
    fi
  fi
  seed_backlog_scaffold "$outbox"
  if [ "${#to_move[@]}" -gt 0 ]; then
    if ! jg_backlog_beads_write "$CONFIG" stage "${to_move[@]}" >"$outbox.staging"; then
      cat -- "$outbox.staging" >&2
      rm -f -- "$outbox.staging"
      echo "error: atomic outbox staging failed; nothing new was handed off" >&2
      return 1
    fi
    mv -f -- "$outbox.staging" "$outbox" || return 1
  fi
  # A hard local kill can land the outbox before the source drop. The outbox is
  # already authoritative in that state, so converge by deleting only the rows
  # the outbox already holds from the source.
  remove_interrupted_source_duplicates "$outbox" "${requested[@]}" || return 1
  remote_deliver_outbox "$id" "$outbox" || return 1
  echo "handed off ${#requested[@]} item(s) to remote squad_lead $id: ${requested[*]}"
  [ "${#already[@]}" -eq 0 ] || echo "  already staged (recovered): ${already[*]}"
  warn_stale_public_commitments "$id" "${requested[@]}"
}

with_remote_route_locks() { # <squad-lead-id> <function> <args...>
  local id=$1 operation=$2 rc
  shift 2
  case "$id" in '' | *[!A-Za-z0-9._-]*)
    echo "error: unsafe remote handoff id: $id" >&2
    return 1
    ;;
  esac
  ACTIVE_REGISTRY_LOCK=$(squad_lead_registry_lock_path "$STATE")
  jg_lock_acquire_wait "$ACTIVE_REGISTRY_LOCK"
  if [ "$(squad_lead_registry_field "$REG" "$id" remote 2>/dev/null || true)" != 1 ]; then
    echo "error: pending outbox has no matching remote squad_lead route: $id" >&2
    release_remote_locks
    return 1
  fi
  ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$id.lock"
  jg_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
  if "$operation" "$@"; then rc=0; else rc=$?; fi
  release_remote_locks
  return "$rc"
}

resume_remote_outbox() { # <squad-lead-id> <outbox-path>
  local id=$1 outbox=$2
  [ -e "$outbox" ] || [ -L "$outbox" ] || return 0
  if [ ! -f "$outbox" ] || [ -L "$outbox" ]; then
    echo "error: unsafe pending handoff outbox: $outbox" >&2
    return 1
  fi
  remote_deliver_outbox "$id" "$outbox"
}

resume_pending_outboxes() {
  local outbox id failed=0
  [ -d "$DATA/handoff" ] || return 0
  for outbox in "$DATA/handoff"/*.outbox.md; do
    [ -e "$outbox" ] || [ -L "$outbox" ] || continue
    id=$(basename "$outbox" .outbox.md)
    case "$id" in '' | *[!A-Za-z0-9._-]*)
      echo "error: unsafe pending handoff id: $id" >&2
      failed=1
      continue
      ;;
    esac
    with_remote_route_locks "$id" resume_remote_outbox "$id" "$outbox" || failed=1
  done
  return "$failed"
}

resume_remote_wake() { # <squad-lead-id>
  local id=$1
  [ -e "$DATA/handoff/$id.outbox.md" ] || [ -L "$DATA/handoff/$id.outbox.md" ] || {
    receiver_wake_clear_confirmed "$id"
    receiver_wake_pending_valid "$id" || return 0
    wake_pending_squad_lead_receiver "$id"
  }
}

resume_pending_wakes() {
  local marker name id failed=0
  [ -d "$STATE" ] || return 0
  for marker in "$STATE"/.backlog-handoff-*.wake-pending; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    name=$(basename "$marker")
    id=${name#.backlog-handoff-}
    id=${id%.wake-pending}
    case "$id" in '' | *[!A-Za-z0-9._-]*)
      echo "error: unsafe pending wake id: $id" >&2
      failed=1
      continue
      ;;
    esac
    [ "$(squad_lead_registry_field "$REG" "$id" remote 2>/dev/null || true)" = 1 ] || continue
    with_remote_route_locks "$id" resume_remote_wake "$id" || failed=1
  done
  return "$failed"
}

if [ "$RESUME_PENDING" -eq 1 ]; then
  FAILED=0
  resume_pending_wakes || FAILED=1
  resume_pending_outboxes || FAILED=1
  exit "$FAILED"
fi

ACTIVE_REGISTRY_LOCK=$(squad_lead_registry_lock_path "$STATE")
jg_lock_acquire_wait "$ACTIVE_REGISTRY_LOCK"
REMOTE=$(squad_lead_registry_field "$REG" "$ID" remote 2>/dev/null || true)
if [ "$REMOTE" = 1 ]; then
  ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
  jg_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
  if remote_handoff "$ID" "$@"; then rc=0; else rc=$?; fi
  release_remote_locks
  exit "$rc"
fi
ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
jg_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
jg_lock_release "$ACTIVE_REGISTRY_LOCK"
ACTIVE_REGISTRY_LOCK=

RAW_HOME=$(squad_lead_home "$ID") || exit 1
[ -n "$RAW_HOME" ] || {
  echo "error: squad_lead $ID has no home in $REG" >&2
  exit 1
}
SUB_HOME=$(validate_squad_lead_home "$ID" "$RAW_HOME") || exit 1
read_main_store || exit 1
render_store "$SUB_HOME/config" sub || exit 1
SUB_BACKLOG=$MOVE_DIR/sub.md
SUB_SHOWN="the Beads store of squad_lead $ID"
validate_backlog_file "main backlog" "$MAIN_BACKLOG" || exit 1
validate_backlog_file "squad_lead backlog" "$SUB_BACKLOG" || exit 1

# Classify every key before changing anything: move-from-main, already-in-sub, or
# missing. Abort with no changes if any key matches neither backlog.
TO_MOVE=()
ALREADY=()
MISSING=()
IN_FLIGHT=()
DONE=()
NOT_QUEUED=()
for key in "$@"; do
  if backlog_key_section "$SUB_BACKLOG" "$key" >/dev/null; then
    ALREADY+=("$key")
  elif section=$(backlog_key_section "$MAIN_BACKLOG" "$key"); then
    case "$section" in
    "## Queued") TO_MOVE+=("$key") ;;
    "## In flight") IN_FLIGHT+=("$key") ;;
    "## Done") DONE+=("$key") ;;
    *) NOT_QUEUED+=("$key") ;;
    esac
  else
    MISSING+=("$key")
  fi
done

FAILED=0
if [ "${#IN_FLIGHT[@]}" -gt 0 ]; then
  echo "error: refusing to hand off in-flight backlog items: ${IN_FLIGHT[*]}" >&2
  FAILED=1
fi
if [ "${#DONE[@]}" -gt 0 ]; then
  echo "error: refusing to hand off Done (historical) backlog items: ${DONE[*]}; handoffs move in-scope queued work only - Done records stay with their home and are pruned/archived." >&2
  FAILED=1
fi
if [ "${#NOT_QUEUED[@]}" -gt 0 ]; then
  echo "error: refusing to hand off non-queued backlog items: ${NOT_QUEUED[*]}; handoffs move in-scope queued work only." >&2
  FAILED=1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: no backlog item matched these keys in the Beads store: ${MISSING[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

REQUESTED_BATCH=$(receiver_wake_batch_id "$@") || {
  echo "error: receiver wake batch identity could not be recorded; nothing was moved" >&2
  exit 1
}

# This batch's prepared wake proves a row on both sides is a move cut short, so it
# rejoins the set and the source lets it go; the writes that repeat change nothing.
case "$(cat "$STATE/.backlog-handoff-$ID.wake-pending" 2>/dev/null || true)" in
prepared:*:"$REQUESTED_BATCH")
  for key in "${ALREADY[@]+"${ALREADY[@]}"}"; do
    if [ "$(backlog_key_section "$MAIN_BACKLOG" "$key" 2>/dev/null)" = '## Queued' ]; then TO_MOVE+=("$key"); fi
  done
  ;;
esac

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  WAKE_PENDING_MARKER="$STATE/.backlog-handoff-$ID.wake-pending"
  case "$(cat "$WAKE_PENDING_MARKER" 2>/dev/null || true)" in
  prepared:*:"$REQUESTED_BATCH") receiver_wake_promote_prepared "$ID" "$REQUESTED_BATCH" || exit 1 ;;
  prepared:*)
    echo "error: a prepared receiver wake for squad_lead $ID belongs to a different routed batch; retry that original handoff before handling ${ALREADY[*]}" >&2
    exit 1
    ;;
  esac
  echo "nothing to move: ${ALREADY[*]:-no keys} already present in $SUB_SHOWN"
  wake_pending_squad_lead_receiver "$ID" || exit 1
  exit 0
fi

FAILED=0
for key in "${TO_MOVE[@]}"; do
  while IFS= read -r line; do
    printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' \
      "$key" "$line" >&2
    FAILED=1
  done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
done
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

WAKE_PENDING_MARKER="$STATE/.backlog-handoff-$ID.wake-pending"
if [ -e "$WAKE_PENDING_MARKER" ] || [ -L "$WAKE_PENDING_MARKER" ]; then
  case "$(cat "$WAKE_PENDING_MARKER" 2>/dev/null || true)" in
  prepared:*:"$REQUESTED_BATCH") receiver_wake_discard_prepared "$ID" || exit 1 ;;
  prepared:*)
    echo "error: a prepared receiver wake for squad_lead $ID belongs to a different routed batch; retry that original handoff before moving ${TO_MOVE[*]}" >&2
    exit 1
    ;;
  *)
    wake_pending_squad_lead_receiver "$ID" || {
      echo "error: previous receiver wake for squad_lead $ID is unresolved; nothing new was moved" >&2
      exit 1
    }
    ;;
  esac
fi
receiver_wake_mark_prepared "$ID" "$REQUESTED_BATCH" || {
  echo "error: receiver wake state for squad_lead $ID could not be recorded; nothing was moved" >&2
  exit 1
}

# Delegate the move to the Beads writes (stage, take, drop). Capture their output
# and surface it only on failure.
MV_RC=0
MV_OUT=$(move_rows "${TO_MOVE[@]}" 2>&1) || MV_RC=$?
if [ "$MV_RC" -eq 3 ]; then
  [ -z "$MV_OUT" ] || printf '%s\n' "$MV_OUT" >&2
  echo "error: the move to $ID stopped partway; rerun this same handoff to finish it" >&2
  exit 1
fi
if [ "$MV_RC" -ne 0 ]; then
  receiver_wake_discard_prepared "$ID" || {
    echo "error: the move failed and receiver wake state could not be cleared" >&2
    exit 1
  }
  if [ -n "$MV_OUT" ]; then
    printf '%s\n' "$MV_OUT" >&2
  fi
  echo "error: the move failed; nothing was moved." >&2
  exit 1
fi

echo "handed off ${#TO_MOVE[@]} item(s) to $ID: ${TO_MOVE[*]}"
echo "  into $SUB_SHOWN"
receiver_wake_promote_prepared "$ID" "$REQUESTED_BATCH" || {
  echo "error: handed off work to squad_lead $ID, but durable receiver wake state could not be recorded" >&2
  exit 1
}
wake_pending_squad_lead_receiver "$ID" || exit 1
if [ "${#ALREADY[@]}" -gt 0 ]; then
  echo "  already present (skipped): ${ALREADY[*]}"
fi
warn_stale_public_commitments "$ID" "${TO_MOVE[@]}"
