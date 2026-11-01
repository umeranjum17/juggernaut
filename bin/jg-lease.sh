#!/usr/bin/env bash
# jg-lease.sh - claim, release, inspect, and sweep per-task supervision leases.
#
# The lease contract itself (record format, actors, staleness, guard semantics)
# is owned by bin/jg-lease-lib.sh; this is the command surface the two
# supervision actors use around the overlap set (steering, stopping, cleanup,
# backlog status, stuck-worker recovery). "backlog" is the reserved resource
# the branch prompt claims around its own backlog writes; main's tasks-axi path
# is deliberately unguarded in this scope.
#
# Usage:
#   jg-lease.sh claim <task> [--actor main|branch]
#       Take the lease for the calling actor. Idempotent for the holder (the
#       claim refreshes its own lease). Refuses with exit 6 while the other
#       actor holds a live lease. A stale lease (dead pid, or a torn record)
#       is taken over.
#   jg-lease.sh release <task> [--actor main|branch]
#       Drop the calling actor's lease. Releasing a lease the actor does not
#       hold is a silent no-op, so a retry after a partial failure is safe.
#       Naming the other actor is refused loudly.
#   jg-lease.sh check <task>
#       Print "<actor> <pid> <epoch> <live|stale>" for a held lease, or
#       nothing (exit 1) when the task is unleased. Exit 2 when the lease store
#       cannot answer, so "no lease" is never confused with "could not ask".
#   jg-lease.sh release-actor --actor main|branch
#       Drop every lease the named actor holds; the Pi branch extension runs
#       this at generation activation so a replaced branch conversation's
#       leases never outlive it.
#   jg-lease.sh sweep
#       Remove every provably stale lease of this home, printing each task it
#       removed. Run at session start (a lease held by a dead actor is cleared at
#       session start); safe to run any time - a live lease is never touched.
#
# The records live in the JetStream key-value bucket `JG_LEASES` and the bucket's
# revision is the writer lock, so this script has no lock file, no temporary
# file, and no lock scratch to sweep (bin/jg-lease-lib.sh owns the contract,
# bin/jg-kv-lib.sh owns the client).
#
# The default actor is $JG_SUPERVISION_ACTOR (else main); when --actor is
# supplied for a mutation, it must name that calling actor. Exit codes: 0 ok,
# 1 check-miss or an unusable store, 2 usage, 6 refused (other actor holds or
# actor mismatch).
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
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
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
JG_ROOT="${JG_ROOT_OVERRIDE:-${JG_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
# shellcheck source=bin/jg-lease-lib.sh
. "$SCRIPT_DIR/jg-lease-lib.sh"

usage() {
  echo "usage: jg-lease.sh claim|release <task> [--actor main|branch] | release-actor --actor main|branch | check <task> | sweep" >&2
  exit 2
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  claim|release)
    TASK=${1:-}
    shift 2>/dev/null || true
    jg_lease_valid_id "$TASK" || usage
    ACTOR=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --actor)
          ACTOR=${2:-}
          shift 2 || usage
          ;;
        *) usage ;;
      esac
    done
    if [ -z "$ACTOR" ]; then
      ACTOR=$(jg_lease_actor) || exit 2
    fi
    case "$ACTOR" in main|branch) ;; *) usage ;; esac
    ;;
  check)
    TASK=${1:-}
    [ "$#" -le 1 ] || usage
    jg_lease_valid_id "$TASK" || usage
    ;;
  release-actor)
    ACTOR=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --actor)
          ACTOR=${2:-}
          shift 2 || usage
          ;;
        *) usage ;;
      esac
    done
    case "$ACTOR" in main|branch) ;; *) usage ;; esac
    ;;
  sweep)
    [ "$#" -eq 0 ] || usage
    ;;
  *) usage ;;
esac

case "$CMD" in
  claim|release)
    # Loud accidental-override guard: naming the OTHER actor than the caller's
    # own injected identity is a wiring mistake, never a role change. Release
    # and bulk release enforce the same caller authorization below.
    CALLER=$(jg_lease_actor) || exit "$JG_LEASE_REFUSE_EXIT"
    if [ "$ACTOR" != "$CALLER" ]; then
      echo "error: $CMD refused - the $CALLER supervision actor cannot $CMD a lease as $ACTOR on '$TASK'" >&2
      exit "$JG_LEASE_REFUSE_EXIT"
    fi
    if [ "$CMD" = claim ]; then
      jg_lease_claim "$TASK" "$ACTOR" || exit "$?"
    else
      jg_lease_release "$TASK" "$ACTOR" || exit "$?"
    fi
    ;;
  check)
    jg_lease_bucket_ready || { jg_lease_unavailable check "$TASK"; exit 2; }
    jg_lease_read "$TASK" || exit 1
    if jg_lease_record_live; then LIVENESS=live; else LIVENESS=stale; fi
    printf '%s %s %s %s\n' "${JG_LEASE_ACTOR:-unreadable}" "${JG_LEASE_PID:-0}" "${JG_LEASE_EPOCH:-0}" "$LIVENESS"
    ;;
  release-actor)
    CALLER=$(jg_lease_actor) || exit "$JG_LEASE_REFUSE_EXIT"
    if [ "$ACTOR" != "$CALLER" ]; then
      echo "error: release-actor refused - the $CALLER supervision actor cannot release leases as $ACTOR" >&2
      exit "$JG_LEASE_REFUSE_EXIT"
    fi
    jg_lease_release_actor "$ACTOR" || exit "$?"
    ;;
  sweep)
    jg_lease_bucket_ready || { jg_lease_unavailable sweep ""; exit 1; }
    REMOVED=0
    for KEY in $(jg_kv_keys "$JG_LEASE_BUCKET" "lease/$(jg_kv_home_key "$STATE")/"); do
      [ -n "$KEY" ] || continue
      TASK=${KEY##*/}
      jg_lease_valid_id "$TASK" || continue
      jg_lease_live "$TASK" && continue
      jg_kv_del "$JG_LEASE_BUCKET" "$KEY"
      printf '%s\n' "$TASK"
      REMOVED=$((REMOVED + 1))
    done
    printf 'stale leases removed: %s\n' "$REMOVED"
    ;;
esac
