#!/usr/bin/env bash
# jg-lease-lib.sh - the per-task supervision lease contract (one owner), on the
# key-value bus.
#
# WHY. A supervision branch (docs/pi-supervision-branch.md) is a second LLM
# actor beside MAIN (the captain's chat) in one juggernaut home - on Pi, a
# persistent conversation inside the same pi process; beside another primary,
# a headless engine session run by the supervision host
# (docs/supervision-host.md) - and nothing in this contract assumes the two
# actors share a process. Most records have exactly one natural owner, but the
# overlap set - steering or stopping a worker, post-landing cleanup, backlog
# status for a task, stuck-worker recovery - could otherwise be mutated by both
# actors at once. The lease is the merge-conflict analog: a small per-task record
# saying which actor is changing that task right now, and the mutating
# entrypoints refuse the other actor while it is live.
#
# CONTRACT.
#   - Record: one JetStream key-value key per task in the bucket `JG_LEASES`,
#     `lease/<home>/<task>`, and its value is one line
#     "<actor>\t<pid>\t<epoch>". <home> is the home directory's name plus the
#     first eight hex digits of its path hash, so two homes that both run a task
#     named `lane-a` never share a key and the key stays inside the charset a KV
#     key accepts. The key layout, the client and the value bytes are owned by
#     bin/jg-kv-lib.sh; this library owns what a lease means.
#   - Write: the bucket's revision is the writer lock the file path used to spell
#     with a home-local lock directory. A first claim is a create, which fails
#     when the key already exists; a takeover of a stale record, or a refresh of
#     the holder's own, is an update pinned to the revision that was just read.
#     Two actors claiming one task at one instant therefore cannot both win: the
#     loser's write is refused by the server and it re-reads the winner's record
#     and refuses. There is no lock file, no steal mutex, no temporary file and
#     no sweep of lock scratch, because there is nothing left to sweep.
#   - Actors: exactly "main" and "branch". The current actor is
#     $JG_SUPERVISION_ACTOR when set, else "main". The branch's shell gets
#     JG_SUPERVISION_ACTOR=branch injected deterministically by the process
#     hosting it (on Pi, the branch extension's bash tool; elsewhere, the
#     supervision host's engine environment), not by agent memory. Any other
#     value is refused loudly - an unknown actor is a wiring bug, not a third
#     role.
#   - Staleness: the recorded pid is the long-lived supervising process (the
#     session-lock holder, or JG_LEASE_HOLDER_PID - see bin/jg-lease.sh), so a
#     dead recorded pid means the supervising session died; the lease is
#     cleared at the next claim, guard, or sweep. Liveness is the pure record
#     test, identical in every calling context: the recorded pid is alive and
#     IS the current state/.lock holder. So a lease left by an exited session
#     goes stale for every reader, whichever harness now owns the home, and an
#     unmarked main honors a live branch lease exactly as a Pi main does. The
#     one residual is a recorded pid recycled onto the next session-lock holder
#     itself; the host that owns a branch conversation releases that actor's
#     leases when it activates a new one (the Pi branch extension's
#     generation-activation cleanup; the supervision host also releases them
#     after every engine turn), which also recovers a lease held by the live
#     session but an abandoned branch conversation.
#   - The store is required exactly where a lease decision is needed. A home in
#     no supervision context, holding no lease, that runs no supervision host
#     never asks the bus anything, so it behaves as before and needs no bus. A
#     home that does need to decide refuses rather than guessing when the store
#     cannot answer: a guard that cannot read the record would let two actors
#     mutate one task at once, so it stops before anything is changed.
#   - The guard is a read, not a claim. It refuses while the other actor's lease
#     is live and leaves no record behind, so a guarded action that is abandoned
#     halfway leaves nothing to expire. What serializes a takeover is the claim's
#     compare-and-set, which is why the guard no longer holds a home-local lock
#     across the caller's mutation: the record it would have held the lock for is
#     now created only by an actual claim.
#
# THREAT MODEL (deliberate, captain-decided): these guards are
# CONFUSED-AGENT-GRADE, the same grade bin/jg-gate-refuse-lib.sh documents
# for the gate refusal. They stop non-deliberate misuse - the injected actor
# identity, the loud refusals, and the session-bound staleness make every
# accidental cross-actor mutation fail loudly. A deliberately forging shell
# running as the same uid inside the same pi process can evade any in-process
# discriminator (it can rewrite env, spawn fresh shells, and write the bucket
# itself with the same client), so adversarial-grade separation is explicitly out
# of scope here and tracked as separate follow-up design work. The branch's shell
# prelude makes the actor variables readonly (see the Pi branch extension), so an
# ACCIDENTAL override fails loudly inside the branch's own shell as well.
#   - Guard semantics (jg_lease_guard): no lease, a same-actor lease, or a
#     provably stale lease passes; a live lease held by the OTHER actor refuses
#     with exit JG_LEASE_REFUSE_EXIT; a store that cannot answer refuses with
#     exit 1, because a guard that cannot read the record has not decided
#     anything. The guard engages in a supervision context (Pi, or an explicit
#     actor) and in a home that runs the supervision host
#     (jg_supervision_host_enabled, whose host can claim a task that has no lease
#     yet), and there it reads the bucket. An unmarked caller in any other home
#     returns before reading anything, so a home that never runs a branch is
#     unchanged and needs no bus.
#   - Role partition (jg_lease_forbid_branch): actions MAIN alone owns -
#     merging a PR, landing local-only work, spawning workers, answering a
#     decision, retiring a squad_lead - refuse the branch actor outright,
#     lease or no lease, while the home is attended. While a confirmed,
#     readable, live away record exists (bin/jg-afk-contract.sh validate and
#     mode, never quiet mode's record, whose captain is present; docs/pi-
#     supervision-branch.md "Postures"), main is parked and its STANDING authority
#     relocates to the branch for exactly the actions whose guarded script
#     opts in with --away-relocated: a PR merge, a fresh spawn of queued work,
#     and a decision answer. Each guarded script keeps its own mechanical gate;
#     bin/jg-branch-prompt.sh "Postures" owns how the branch judges the
#     captain's away words before invoking one. The
#     relocation grants nothing beyond what main could do attended: it only
#     changes which actor may reach the guarded script's own gate. An action
#     that has no record-side gate of its own - landing local-only work or
#     retiring a squad_lead - is never relocated and keeps refusing the branch
#     in both postures. An archived, absent, unconfirmed, or unreadable record
#     is absence: the
#     attended refusal, byte for byte. The record is validated immediately
#     before the guarded script's first persistent side effect and no lock is
#     held across the operation, so a return's archive is never blocked by
#     a long spawn; a spawn or answer that completes seconds after archive is
#     standing-authority work the captain had queued anyway (accepted,
#     confused-agent-grade, like the merge residuals jg-pr-merge.sh documents).
#   - "backlog" is a reserved claimable resource name used by the branch
#     prompt around its own data/backlog.md writes. This is deliberately
#     branch-side containment only; main's tasks-axi path has no executable
#     backlog lease guard in this scope.
#
# Sourced by bin/jg-send.sh, bin/jg-control.sh, bin/jg-teardown.sh,
# bin/jg-pr-merge.sh, bin/jg-merge-local.sh, bin/jg-spawn.sh, and bin/jg-lease.sh.
# Callers must have $STATE resolved before calling. No side effects on source.
# set -u / set -e safe.

# Distinct from usage errors (2), the gate refusal (3), and jg-send's
# unconfirmed submit (3): recognizable as "the other supervision actor holds
# this task right now - retry after the lease clears".
JG_LEASE_REFUSE_EXIT=6
JG_LEASE_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
JG_LEASE_BUCKET=JG_LEASES
JG_LEASE_WHY=

# jg_lease_kv_lib: source the client library once per shell.
jg_lease_kv_lib() {
  command -v jg_kv_ready >/dev/null 2>&1 && return 0
  # shellcheck source=bin/jg-kv-lib.sh
  . "$JG_LEASE_LIB_DIR/jg-kv-lib.sh"
}

# jg_lease_home: the home this shell resolves records against.
jg_lease_home() {
  printf '%s\n' "$(dirname "$STATE")"
}

# jg_lease_bucket_ready: 0 iff this home's lease store can be read and written,
# with the reason in JG_LEASE_WHY when it cannot.
jg_lease_bucket_ready() {
  local home
  jg_lease_kv_lib
  home=$(jg_lease_home) || return 1
  jg_kv_ready "$home" || { JG_LEASE_WHY=$JG_KV_WHY; return 1; }
  jg_kv_ensure_bucket "$JG_LEASE_BUCKET" || { JG_LEASE_WHY=$JG_KV_WHY; return 1; }
  return 0
}

# jg_lease_key <task>: the bucket key one task's lease lives at.
jg_lease_key() { # <task>
  local home_key
  jg_lease_kv_lib
  home_key=$(jg_kv_home_key "$STATE") || return 1
  printf 'lease/%s/%s\n' "$home_key" "$1"
}

# jg_lease_home_runs_host: 0 iff this home runs the supervision host
# (jg_supervision_host_enabled owns the gate).
jg_lease_home_runs_host() {
  if ! command -v jg_supervision_host_enabled >/dev/null 2>&1; then
    # shellcheck source=bin/jg-supervision-engine-lib.sh
    . "$JG_LEASE_LIB_DIR/jg-supervision-engine-lib.sh"
  fi
  jg_supervision_host_enabled "${JG_CONFIG_OVERRIDE:-${JG_HOME:-$STATE/..}/config}"
}

# jg_lease_actor: print the current actor after validating it. Returns 1 (with
# stderr) for an unknown JG_SUPERVISION_ACTOR value.
jg_lease_actor() {
  local actor=${JG_SUPERVISION_ACTOR:-main}
  case "$actor" in
    main|branch) printf '%s\n' "$actor" ;;
    *)
      echo "error: unknown JG_SUPERVISION_ACTOR '$actor' (expected main or branch)" >&2
      return 1
      ;;
  esac
}

# jg_lease_valid_id <id>: 0 iff the task/resource id is safe to embed in a
# bucket key.
jg_lease_valid_id() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# jg_lease_parse <line>: read one record line into JG_LEASE_ACTOR/JG_LEASE_PID/
# JG_LEASE_EPOCH. A malformed record (unreadable actor or pid) reads as actor ""
# so callers treat it as stale rather than blocking forever on a torn record.
jg_lease_parse() {
  local line=$1
  JG_LEASE_ACTOR=$(printf '%s' "$line" | cut -f1)
  JG_LEASE_PID=$(printf '%s' "$line" | cut -f2)
  # shellcheck disable=SC2034 # Consumed by sourcing callers (bin/jg-lease.sh check).
  JG_LEASE_EPOCH=$(printf '%s' "$line" | cut -f3)
  case "$JG_LEASE_ACTOR" in
    main|branch) ;;
    *) JG_LEASE_ACTOR= ;;
  esac
  case "$JG_LEASE_PID" in
    '' | *[!0-9]*) JG_LEASE_PID= ;;
  esac
}

# jg_lease_read <task>: read the task's record into JG_LEASE_ACTOR/JG_LEASE_PID/
# JG_LEASE_EPOCH. Returns 1 when no record exists or the store cannot answer, so
# a caller that must not treat "unreachable" as "unleased" asks
# jg_lease_bucket_ready first.
jg_lease_read() { # <task>
  local key value
  JG_LEASE_ACTOR=
  JG_LEASE_PID=
  # shellcheck disable=SC2034 # Consumed by sourcing callers (bin/jg-lease.sh check).
  JG_LEASE_EPOCH=
  jg_lease_kv_lib
  key=$(jg_lease_key "$1") || return 1
  value=$(jg_kv_get "$JG_LEASE_BUCKET" "$key") || return 1
  [ -n "$value" ] || return 1
  jg_lease_parse "$value"
  return 0
}

# jg_lease_record_live: 0 iff the record just parsed is live - a well-formed
# actor and pid, that pid alive, and that pid the current session-lock holder
# (the staleness contract above). The calling context never enters the verdict.
jg_lease_record_live() {
  local lock_pid
  [ -n "$JG_LEASE_ACTOR" ] || return 1
  [ -n "$JG_LEASE_PID" ] || return 1
  kill -0 "$JG_LEASE_PID" 2>/dev/null || return 1
  lock_pid=$(head -n 1 "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in '' | 0 | 1 | *[!0-9]*) return 1 ;; esac
  [ "$JG_LEASE_PID" = "$lock_pid" ]
}

# jg_lease_live <task>: 0 iff the task's record exists and is live.
jg_lease_live() { # <task>
  jg_lease_read "$1" || return 1
  jg_lease_record_live
}

# jg_lease_holder_pid: the pid a claim records as the holder - the long-lived
# supervising process. JG_LEASE_HOLDER_PID when the caller provides one (the Pi
# branch extension passes the session-lock holder), else the session-lock holder
# (state/.lock is the harness pid), else this shell; without a matching session
# lock the resulting lease is stale.
jg_lease_holder_pid() {
  local pid=${JG_LEASE_HOLDER_PID:-}
  case "$pid" in *[!0-9]*) pid= ;; esac
  if [ -z "$pid" ]; then
    pid=$(head -n 1 "$STATE/.lock" 2>/dev/null | tr -cd '0-9' || true)
  fi
  printf '%s\n' "${pid:-$$}"
}

# jg_lease_unavailable <verb> <task>: the one refusal text for a store that
# cannot answer, so every caller stops the same way instead of guessing.
jg_lease_unavailable() { # <verb> <task>
  echo "error: $1 refused - no task-lease store answers at ${JG_KV_URL_RESOLVED:-the configured bus} (${JG_LEASE_WHY:-not reachable}). Nothing was changed. Start the home's bus with bin/jg-bus.sh serve, then retry." >&2
}

# jg_lease_claim <task> <actor>: take the lease. Returns 0 granted, 6 refused
# (the other actor's live lease), 1 when the store cannot decide. A refresh of
# the holder's own lease is a claim like any other, so a holder never has to
# release first.
jg_lease_claim() { # <task> <actor>
  local task=$1 actor=$2 key line attempt value revision
  key=$(jg_lease_key "$task") || return 1
  jg_lease_bucket_ready || { jg_lease_unavailable claim "$task"; return 1; }
  line=$(printf '%s\t%s\t%s' "$actor" "$(jg_lease_holder_pid)" "$(date +%s)")
  attempt=0
  while [ "$attempt" -lt 6 ]; do
    attempt=$((attempt + 1))
    if value=$(jg_kv_get "$JG_LEASE_BUCKET" "$key"); then
      if [ -n "$value" ]; then
        jg_lease_parse "$value"
        if [ -n "$JG_LEASE_ACTOR" ] && [ "$JG_LEASE_ACTOR" != "$actor" ] && jg_lease_record_live; then
          echo "error: claim refused - task '$task' is leased to the $JG_LEASE_ACTOR supervision actor, which is handling that task right now; retry after that actor releases it, which it does when its handling ends" >&2
          return "$JG_LEASE_REFUSE_EXIT"
        fi
      fi
      revision=$(jg_kv_revision "$JG_LEASE_BUCKET" "$key" 2>/dev/null || true)
      [ -n "$revision" ] || continue
      jg_kv_update "$JG_LEASE_BUCKET" "$key" "$line" "$revision" && return 0
    else
      jg_kv_create "$JG_LEASE_BUCKET" "$key" "$line" && return 0
    fi
  done
  jg_lease_unavailable claim "$task"
  return 1
}

# jg_lease_release <task> <actor>: drop the actor's lease. A task with no record
# is a silent no-op, so a retry after a partial failure is safe; a record held by
# another actor is left alone.
jg_lease_release() { # <task> <actor>
  local task=$1 actor=$2 key
  key=$(jg_lease_key "$task") || return 1
  jg_lease_bucket_ready || { jg_lease_unavailable release "$task"; return 1; }
  jg_lease_read "$task" || return 0
  [ -z "$JG_LEASE_ACTOR" ] || [ "$JG_LEASE_ACTOR" = "$actor" ] || return 0
  jg_kv_del "$JG_LEASE_BUCKET" "$key"
}

# jg_lease_release_actor <actor>: drop every lease the named actor holds; the Pi
# branch extension and the supervision host run this when a branch conversation
# is replaced, so a stale holder never outlives it.
jg_lease_release_actor() { # <actor>
  local actor=$1 task key
  jg_lease_bucket_ready || { jg_lease_unavailable "lease release" "$actor"; return 1; }
  for key in $(jg_kv_keys "$JG_LEASE_BUCKET" "lease/$(jg_kv_home_key "$STATE")/"); do
    [ -n "$key" ] || continue
    task=${key##*/}
    jg_lease_valid_id "$task" || continue
    jg_lease_read "$task" || continue
    [ "$JG_LEASE_ACTOR" = "$actor" ] || continue
    jg_kv_del "$JG_LEASE_BUCKET" "$key"
  done
  return 0
}

# jg_lease_clear_stale <task>: drop the task's record when it exists but is not
# live. Silent; never touches a live lease.
jg_lease_clear_stale() { # <task>
  local key
  jg_lease_read "$1" || return 0
  jg_lease_record_live && return 0
  key=$(jg_lease_key "$1") || return 0
  jg_kv_del "$JG_LEASE_BUCKET" "$key"
  return 0
}

# jg_lease_guard <task> <action-label>: refuse (exit JG_LEASE_REFUSE_EXIT) when
# a live lease held by the OTHER actor exists for <task>, and refuse (exit 1)
# when the store cannot answer. Engaged in a supervision context, in a home that
# runs the supervision host, and otherwise by nothing at all - a home that never
# runs a branch never reads the store.
jg_lease_guard() {
  local task=$1 action=$2 actor
  jg_lease_valid_id "$task" || return 0
  actor=$(jg_lease_actor) || exit "$JG_LEASE_REFUSE_EXIT"
  case "${PI_CODING_AGENT:-}:${JG_SUPERVISION_ACTOR:-}" in
    true:* | *:main | *:branch) ;;
    *)
      jg_lease_home_runs_host || return 0
      ;;
  esac
  jg_lease_bucket_ready || {
    # Refusing here is deliberate: a guard that cannot read the record would
    # let two supervision actors mutate one task at once, so the caller stops
    # before it changes anything.
    jg_lease_unavailable "$action" "$task"
    exit 1
  }
  if ! jg_lease_live "$task"; then
    jg_lease_clear_stale "$task" || return 1
    return 0
  fi
  if [ "$JG_LEASE_ACTOR" != "$actor" ]; then
    echo "error: $action refused - task '$task' is leased to the $JG_LEASE_ACTOR supervision actor, which is handling that task right now; leave the lease alone (never remove or clear it) and retry after that actor releases it, which it does when its handling ends" >&2
    exit "$JG_LEASE_REFUSE_EXIT"
  fi
}

# jg_lease_guard_release: kept for the callers that still invoke it from their
# EXIT cleanup (bin/jg-send.sh, bin/jg-control.sh, bin/jg-teardown.sh). The guard
# takes no lock to release any more - the bucket's revision is what serializes a
# claim - so this is a no-op, and it disappears with the last call site.
jg_lease_guard_release() {
  return 0
}

# jg_lease_away_relocated: 0 iff main's standing authority is relocated to the
# branch actor right now - a confirmed, readable, live away record exists in
# $STATE, as bin/jg-afk-contract.sh's own validate and mode subcommands judge
# it (the header's role-partition paragraph). Read fresh on every call, never
# cached, because the record can be archived between two guarded actions.
jg_lease_away_relocated() {
  [ -f "$STATE/.afk-contract" ] || return 1
  JG_STATE_OVERRIDE="$STATE" "$JG_LEASE_LIB_DIR/jg-afk-contract.sh" validate >/dev/null 2>&1 || return 1
  [ "$(JG_STATE_OVERRIDE="$STATE" "$JG_LEASE_LIB_DIR/jg-afk-contract.sh" mode 2>/dev/null)" != quiet ]
}

# jg_lease_forbid_branch <action-label> [--away-relocated]: refuse (exit
# JG_LEASE_REFUSE_EXIT) when the current actor is the supervision branch.
# Guards the main-owned role partition; a home with no branch never sets the
# actor and always passes. With --away-relocated, the branch passes instead
# while jg_lease_away_relocated holds (main is parked under the away-posture
# record), and the calling script's own gate decides what may happen next;
# without the flag the action is never relocated in any posture.
jg_lease_forbid_branch() {
  local action=$1 relocatable=${2:-} actor
  actor=$(jg_lease_actor) || exit "$JG_LEASE_REFUSE_EXIT"
  [ "$actor" = branch ] || return 0
  if [ "$relocatable" = --away-relocated ] && jg_lease_away_relocated; then
    echo "note: $action proceeds for the supervision branch under the away-posture record: main is parked and its standing authority is relocated; this script's own gate still applies (docs/pi-supervision-branch.md \"Postures\")" >&2
    return 0
  fi
  echo "error: $action refused - the supervision branch never performs this action; report the outcome and leave it to main (role partition: docs/pi-supervision-branch.md)" >&2
  exit "$JG_LEASE_REFUSE_EXIT"
}

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
