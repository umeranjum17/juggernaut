#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: jg-bootstrap.sh
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)",
#                 "NEEDS_GH_AUTH" (skipped when every registered project is
#                 local-only with a clone and no clone is unregistered),
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>",
#                 "SENTINEL: jg-sentinel is not running ... (install: <command>)",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "HOME_SUMMARY: <ledger never published|not republished since
#                 <stamp>>; <n> failed attempt(s) ... last: <recorded failure>",
#                 "BACKLOG_RECONCILE: <id>: <what this home could not reconcile>",
#                 "BACKLOG_RECONCILE: code-root <file> is not this home's <file>; ...",
#                 "TANGLE: <remediation>",
#                 "SQUAD_LEAD_SYNC: squad_lead <id>: skipped: <reason>",
#                 "NUDGE_SQUAD_LEADS: squad_lead <id>: send failed: <reason>",
#                 "BOOTSTRAP_INFO: nudged jg-<id> with '<message>'",
#                 "SQUAD_LEAD_LIVENESS: squad_lead <id>: skipped: <reason>|respawn failed after <cause>: <reason>",
#                 "SQUAD_LEAD_HANDOFF: squad_lead <id>: pending delivery: <n> item(s)",
#                 "FMX: X mode on ..." or "FMX: X mode off ...".
#          When a RUNNING squad_lead home is fast-forwarded, its target is
#          juggernaut's own current default-branch commit. A local worktree uses
#          a purely local fast-forward with no origin fetch; a remote route hands
#          the same commit to its host, which imports that commit into the home
#          without moving the host's Juggernaut copy. If either placement changes
#          its loaded instruction surface
#          (AGENTS.md, bin/, or .agents/skills/), bootstrap immediately nudges it
#          via JG_HOME=<active-home> bin/jg-send.sh jg-<id> so meta resolves the
#          current route and the standard from-juggernaut marker is applied. A
#          successful send prints one BOOTSTRAP_INFO line with the exact target
#          and message sent; a failed send leaves an idempotent retry marker
#          under state/.squad-lead-nudge-pending/ and prints an actionable
#          NUDGE_SQUAD_LEADS line.
#          Already-current or no-instruction-change homes are silently left alone.
#          The squad_lead sweep also propagates declared inherited local material
#          into each validated live squad_lead home.
#          SQUAD_LEAD_SYNC lines report actionable skipped placement-specific
#          syncs or inheritance failures for live squad_lead homes, plus
#          quarantine diagnostics for divergent shared captain-preference
#          copies; no-op/current and successful updates stay quiet.
#          SQUAD_LEAD_LIVENESS lines report only actionable failures from the
#          recovery-grade state owned by bin/jg-backend.sh's
#          jg_backend_agent_state: skipped distinguishes an existing ambiguous
#          process, an unreadable target, and an unverified backend; respawn
#          failed names whether the endpoint was missing or agent-less.
#          Already-live and successfully relaunched squad_leads are silent
#          unless JG_BOOTSTRAP_VERBOSE_FACTS=1 requests BOOTSTRAP_INFO facts.
#          A TANGLE line means the juggernaut primary checkout (JG_ROOT) is stranded
#          on a feature branch instead of its default branch - a operator's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.46.0 (structured pipeline attestation floor; see CONTRIBUTING.md).
#          The AXI-family floor policy is owned beside GH_AXI_MIN below; the
#          per-tool owners point there. An installed essential build below its
#          floor reports MISSING like no-mistakes.
#          tasks-axi feature probes remain a separate defense-in-depth check.
#          tasks-axi and quota-axi are essential bootstrap tools.
#          A compatible tasks-axi default backend is silent.
#          quota-axi is required for the agent-owned dispatch-profile array
#          procedure in .agents/skills/quota-array-dispatch/SKILL.md.
#          done-done and sign-off-axi are the published proof and decision tools;
#          each install line is the exact build its toolchain.versions row names,
#          never a git install, and that row is their floor too. The locked
#          mutable path also wires them through bin/jg-tool-wiring.sh: the skill
#          the package ships, the done-done brief include as one managed block,
#          and config/merge-gate when the home has none. Sign-off arming stays per
#          home and is never done there; the first wiring prints one line naming
#          bin/jg-procevent-signoff.sh arm, so the user is told instead of
#          remembering it.
#          On a primary home, the locked mutable path materializes the visible
#          default config/startup-memory-budget=7500 when absent. It never
#          guesses at malformed or unsafe existing files, and squad_lead homes
#          await the primary-authoritative inherited value instead of creating
#          their own.
#          X mode is OPTIONAL and inert unless JG_HOME/.env has a non-empty
#          FMX_PAIRING_TOKEN. When opted in, bootstrap requires curl+jq, writes
#          the relay poll shim and 30s cadence config, and prints an FMX line.
#          Fleet sync fetches, fast-forwards safe default-branch states, reports
#          recovered and STUCK clone drift, and prunes gone local branches; it is
#          bounded by JG_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed jg-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set JG_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          BACKLOG_RECONCILE lines report what backlog_record_reconcile could not
#          settle in THIS home. Every ordinary dispatch and completion now moves
#          the backlog row inside the script that moves the task's record
#          (bin/jg-backlog-transition-lib.sh), so this sweep exists for the
#          crash window inside those scripts and for drift a home was already
#          carrying: it finishes the authoritative close or captain-call
#          retention an interrupted cleanup recorded, and marks In flight any
#          item this home already owns a worker for. The worker-record sweep
#          never starts a captain-held or closed item, and reconciliation never
#          reads or writes another home; the fleet snapshot's classifier and
#          bin/jg-squad-lead-reconcile.sh's nudge stay as backstops. Replayed
#          transitions and restored In-flight rows print BOOTSTRAP_INFO facts.
#          The `code-root <file>` variant is a detect-only local check that runs
#          even in a read-only session; detect_code_root_backlog_fork owns what
#          it reports.
#          Set JG_BOOTSTRAP_DETECT_ONLY=1 to skip the six MUTATING sweeps
#          (backlog_record_reconcile, squad_lead_sync,
#          squad_lead_liveness_sweep, squad_lead_handoff_resume, x_mode_setup,
#          fleet_sync) while still
#          printing every read-only detect line
#          above; the TANGLE line switches to advisory-only wording with no
#          checkout command. Used by
#          jg-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          squad_lead homes, pending handoff outboxes and receiver wakes,
#          X-mode artifacts, project clones, or repair instructions.
#          Unset/0 (the default) runs all six sweeps - this flag is purely
#          additive.
#          Set JG_BOOTSTRAP_NETWORK to split this run by whether a step talks to
#          the network, so a session start can print its digest from local reads
#          alone and run the network half off the digest's blocking path:
#            all  (default, and any unrecognized value) - every local and network
#                 step. Unrecognized values fall back here on purpose: a typo
#                 must never silently skip a safety sweep.
#            skip - every LOCAL step, and none of the network ones. Skips
#                 `gh auth status`, squad_lead_liveness_sweep, squad_lead_sync,
#                 squad_lead_handoff_resume, and fleet_sync.
#            only - ONLY those network steps and nothing else. No tool detection,
#                 no version floors, no tangle check, no backlog
#                 reconciliation, no x_mode_setup: those already ran on the
#                 local pass.
#          JG_BOOTSTRAP_DETECT_ONLY composes with it unchanged, so `only` plus
#          detect-only is the read-only `gh auth status` probe on its own.
#          bin/jg-startup-network.sh owns the deferral: it runs the `only` phase
#          in a detached bounded worker and publishes the result. This file stays
#          the single owner of every sweep, and the split changes only WHEN each
#          runs, never WHETHER. During the network phase, project clone refresh
#          overlaps the independent squad_lead work. Per-squad-lead remote
#          liveness workers run concurrently and finish before per-squad-lead
#          remote convergence workers run concurrently, because convergence
#          consumes respawned ids. Worker output is captured separately and
#          replayed in spawn order; failure to create that private capture
#          directory selects the sequential fallback.
#          A relaunch that the liveness sweep performs during an `only` run is
#          always reported, because a digest composed before that run already
#          printed the superseded endpoint record.
#          Set JG_BOOTSTRAP_LOCKED=1 alongside it when the sweeps are skipped
#          because THIS session already ran them while holding the fleet lock,
#          rather than because it has no lock at all. The two cases differ in
#          exactly one place: repair ownership. A locked session is told to
#          restore a tangled primary checkout itself, while an unlocked one is
#          told to leave that work to the lock holder. Unset/0 (the default)
#          keeps detect-only meaning unlocked, exactly as before.
#        jg-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
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
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
PROJECTS="${JG_PROJECTS_OVERRIDE:-$JG_HOME/projects}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
# shellcheck source=bin/jg-pin-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-pin-lib.sh"
# shellcheck source=bin/jg-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-tasks-axi-lib.sh"
# shellcheck source=bin/jg-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-transition-lib.sh"
# shellcheck source=bin/jg-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-quota-axi-lib.sh"
# shellcheck source=bin/jg-control-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-control-lib.sh"
# shellcheck source=bin/jg-env-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-env-lib.sh"
# shellcheck source=bin/jg-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-tangle-lib.sh"
# shellcheck source=bin/jg-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-ff-lib.sh"
# shellcheck source=bin/jg-cursor-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-cursor-lib.sh"
# shellcheck source=bin/jg-config-inherit-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-config-inherit-lib.sh"
# shellcheck source=bin/jg-squad-lead-nudge-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-squad-lead-nudge-lib.sh"
# Parked-home guard (juggernaut-addons/parked-homes): a parked home gets no
# config push or reread nudge. The shim answers not parked when the add-on is absent.
# shellcheck source=bin/jg-parked-homes-lib.sh
. "$SCRIPT_DIR/jg-parked-homes-lib.sh"
# shellcheck source=bin/jg-startup-memory-budget-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-startup-memory-budget-lib.sh"
# shellcheck source=bin/jg-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-x-lib.sh"
# shellcheck source=bin/jg-backend.sh disable=SC1091
. "$SCRIPT_DIR/jg-backend.sh"
# shellcheck source=bin/jg-remote-readiness-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-remote-readiness-lib.sh"
# Shared squad_lead endpoint probe + guarded relaunch; the watcher's poll tick
# drives the same library so session start and ordinary supervision recover
# from identical evidence through an identical path.
# shellcheck source=/dev/null # Analyzed separately as a canonical lint root.
. "$SCRIPT_DIR/jg-squad-lead-liveness-lib.sh"
# Dormant-lead record reader: a stopped lead is not probed or relaunched here either.
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"
# jg-timing-lib.sh is inert unless JG_TIMING_LOG names a file, which only the
# deferred network stage sets, so an ordinary bootstrap run records nothing.
# shellcheck source=bin/jg-timing-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-timing-lib.sh"

# Network-phase selection (see the header). An unrecognized value resolves to
# `all` so a malformed override runs every step rather than silently dropping a
# safety sweep.
case "${JG_BOOTSTRAP_NETWORK:-all}" in
  skip|only) JG_BOOTSTRAP_NETWORK_PHASE=${JG_BOOTSTRAP_NETWORK:-all} ;;
  *) JG_BOOTSTRAP_NETWORK_PHASE=all ;;
esac
local_phase() { [ "$JG_BOOTSTRAP_NETWORK_PHASE" != only ]; }
network_phase() { [ "$JG_BOOTSTRAP_NETWORK_PHASE" != skip ]; }

network_mutation_authorized() {
  local expected=${JG_BOOTSTRAP_NETWORK_LOCK_PID:-} current
  [ -n "$expected" ] || return 0
  case "$expected" in *[!0-9]*) return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

network_sweep_authorized() {
  local label=$1
  if network_mutation_authorized; then
    return 0
  fi
  echo "NETWORK_CHECKS: fleet lock ownership changed before $label, so this stale worker skipped that sweep"
  return 1
}

# Concurrent per-item runner for the deferred network sweeps. Each worker's
# stdout and stderr are captured to private files and replayed in original
# order after every worker finishes, so concurrent probes cannot interleave
# or mis-attribute SQUAD_LEAD_LIVENESS / SQUAD_LEAD_SYNC lines. Respawned ids
# are collected from per-id files because background workers cannot mutate
# the parent's SQUAD_LEAD_RESPAWNED_IDS.
bootstrap_parallel_begin() {
  BOOTSTRAP_PAR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/jg-bootstrap-par.XXXXXX") || return 1
  BOOTSTRAP_PAR_N=0
  JG_BOOTSTRAP_PARALLEL_DIR=$BOOTSTRAP_PAR_DIR
  export JG_BOOTSTRAP_PARALLEL_DIR
}

bootstrap_parallel_spawn() {
  BOOTSTRAP_PAR_N=$((BOOTSTRAP_PAR_N + 1))
  (
    "$@"
  ) >"$BOOTSTRAP_PAR_DIR/$BOOTSTRAP_PAR_N.out" 2>"$BOOTSTRAP_PAR_DIR/$BOOTSTRAP_PAR_N.err" &
  printf '%s\n' "$!" > "$BOOTSTRAP_PAR_DIR/$BOOTSTRAP_PAR_N.pid"
}

bootstrap_parallel_finish() {
  local i pid f
  i=1
  while [ "$i" -le "$BOOTSTRAP_PAR_N" ]; do
    pid=$(cat "$BOOTSTRAP_PAR_DIR/$i.pid")
    wait "$pid" || true
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le "$BOOTSTRAP_PAR_N" ]; do
    cat "$BOOTSTRAP_PAR_DIR/$i.out"
    cat "$BOOTSTRAP_PAR_DIR/$i.err" >&2
    i=$((i + 1))
  done
  for f in "$BOOTSTRAP_PAR_DIR"/respawned.*; do
    [ -f "$f" ] || continue
    SQUAD_LEAD_RESPAWNED_IDS="$SQUAD_LEAD_RESPAWNED_IDS $(tr -d '\n' < "$f")"
  done
  rm -rf "$BOOTSTRAP_PAR_DIR"
  unset JG_BOOTSTRAP_PARALLEL_DIR BOOTSTRAP_PAR_DIR BOOTSTRAP_PAR_N
}

squad_lead_note_respawned() {  # <id>
  SQUAD_LEAD_RESPAWNED_IDS="$SQUAD_LEAD_RESPAWNED_IDS $1"
  [ -n "${JG_BOOTSTRAP_PARALLEL_DIR:-}" ] || return 0
  printf '%s\n' "$1" > "$JG_BOOTSTRAP_PARALLEL_DIR/respawned.$1"
}

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

# 0 when at least one project is registered and every registered project is
# local-only with a clone present, and no clone is unregistered, so no project
# needs GitHub and the sign-in probe has nothing to protect. A registered project
# with no clone keeps the probe. bin/jg-project-mode.sh owns the posture lookup;
# an unregistered clone resolves to no-mistakes and keeps the probe.
every_project_local_only() {
  local proj name mode seen=0
  [ -f "$DATA/projects.md" ] || return 1
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    mode=$(JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/jg-project-mode.sh" "${proj##*/}" 2>/dev/null) || return 1
    [ "${mode%% *}" = local-only ] || return 1
  done
  while IFS= read -r name; do
    [ -d "$PROJECTS/$name" ] || return 1
    mode=$(JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/jg-project-mode.sh" "$name" 2>/dev/null) || return 1
    [ "${mode%% *}" = local-only ] || return 1
    seen=1
  done < <(sed -nE 's/^- (.+)$/\1/p' "$DATA/projects.md" | sed -E 's/ (\[| - ).*//')
  [ "$seen" = 1 ]
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${JG_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$JG_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$JG_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$JG_ROOT/bin/jg-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/jg-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$JG_ROOT/bin/jg-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}

squad_lead_sync() {
  # shellcheck source=bin/jg-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/jg-wake-lib.sh"
  # Placement-specific squad_lead sync: EVERY home, local or remote, follows the
  # primary checkout's current default-branch commit. The local path is purely
  # LOCAL - no fetch, no origin dependency: a linked-worktree home already holds
  # the primary's commit (jg-ff-lib.sh), while a standalone clone without it is
  # skipped until /resupply refreshes it from origin. A remote home is on
  # another machine, so its host is handed that same commit and imports it there
  # (bin/jg-remote-squad-lead-control.sh); this side still fetches nothing.
  # Startup sends reread nudges only for RUNNING squad_leads whose instruction
  # surface (AGENTS.md, bin/, or .agents/skills/) actually changed, so a squad_lead already on the primary's
  # version is never disturbed (AGENTS.md bootstrap + supervision). Unlike
  # /resupply, startup owns the live-convergence send itself because it is
  # a deterministic locked sweep and can report success as BOOTSTRAP_INFO while
  # preserving failed sends as NUDGE_SQUAD_LEADS retry markers.
  [ -d "$STATE" ] || return 0
  local primary_head
  if ! primary_head=$(primary_head_commit "$JG_ROOT"); then
    local meta id
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      jg_compat_meta_is_squad_lead "$meta" || continue
      id=$(basename "$meta" .meta)
      echo "SQUAD_LEAD_SYNC: squad_lead $id: skipped: primary default-branch commit cannot be resolved"
    done
    return 0
  fi
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  SECOND_MATE_NUDGE_MESSAGE=$JG_SECOND_MATE_NUDGE_MESSAGE
  REMOTE_SECOND_MATE_NUDGE_MESSAGE=$JG_REMOTE_SECOND_MATE_NUDGE_MESSAGE
  SECOND_MATE_NUDGE_PENDING_DIR="$STATE/.squad-lead-nudge-pending"

  squad_lead_nudge_marker_path() {
    jg_squad_lead_nudge_marker_path "$STATE" "$1"
  }

  squad_lead_write_nudge_marker() {
    local id=$1 home=$2 commit=$3 instr=$4 message=${5:-$SECOND_MATE_NUDGE_MESSAGE} remote=${6:-0}
    jg_squad_lead_nudge_write "$STATE" "$id" "$home" "$commit" "$instr" "$message" "$remote"
  }

  squad_lead_send_nudge() {
    local id=$1 home=$2 commit=$3 instr=$4 selector marker out
    selector="jg-$id"
    marker=$(squad_lead_nudge_marker_path "$id") || {
      echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: unsafe id"
      return 0
    }
    if ! squad_lead_write_nudge_marker "$id" "$home" "$commit" "$instr"; then
      echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: cannot record retry marker"
      return 0
    fi
    if out=$(JG_HOME="$JG_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
      rm -f "$marker"
      echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
    else
      echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: $(first_line "$out")"
    fi
  }

  jg_ff_after_instruction_update() {
    local id=$1 home=$2 _window=$3 instr=$4
    squad_lead_send_nudge "$id" "$home" "$primary_head" "$instr"
  }

  squad_lead_retry_pending_nudges() {
    local marker id selector home commit message remote expected_marker meta meta_home home_real head out
    [ -d "$SECOND_MATE_NUDGE_PENDING_DIR" ] || return 0
    for marker in "$SECOND_MATE_NUDGE_PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      id=$(jg_meta_get "$marker" id)
      if ! expected_marker=$(squad_lead_nudge_marker_path "$id"); then
        echo "NUDGE_SQUAD_LEADS: squad_lead ${id:-unknown}: send failed: retry marker has unsafe id"
        continue
      fi
      [ "$expected_marker" = "$marker" ] || {
        echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: retry marker filename mismatch"
        continue
      }
      selector=$(jg_meta_get "$marker" selector)
      home=$(jg_meta_get "$marker" home)
      commit=$(jg_meta_get "$marker" commit)
      message=$(jg_meta_get "$marker" message)
      remote=$(jg_meta_get "$marker" remote)
      [ -n "$remote" ] || remote=0
      [ "$selector" = "jg-$id" ] || {
        echo "NUDGE_SQUAD_LEADS: squad_lead ${id:-unknown}: send failed: retry marker selector mismatch"
        continue
      }
      case "$remote" in
        0) [ "$message" = "$SECOND_MATE_NUDGE_MESSAGE" ] || {
          echo "NUDGE_SQUAD_LEADS: squad_lead ${id:-unknown}: send failed: retry marker message mismatch"
          continue
        } ;;
        1) [ "$message" = "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" ] || {
          echo "NUDGE_SQUAD_LEADS: squad_lead ${id:-unknown}: send failed: remote retry marker message mismatch"
          continue
        } ;;
        *)
          echo "NUDGE_SQUAD_LEADS: squad_lead ${id:-unknown}: send failed: retry marker placement is invalid"
          continue
          ;;
      esac
      [ "$remote" -ne 1 ] || continue
      meta="$STATE/$id.meta"
      [ -f "$meta" ] && [ "$(jg_meta_get "$meta" kind)" = squad_lead ] || {
        echo "NUDGE_SQUAD_LEADS: squad_lead ${id:-unknown}: send failed: retry target has no live squad_lead metadata"
        continue
      }
      meta_home=$(jg_meta_get "$meta" home)
      [ -n "$meta_home" ] || meta_home=$(squad_lead_registry_field "$(jg_compat_pick "$DATA/squad_leads.md")" "$id" home || true)
      if ! validate_squad_lead_home "$id" "$meta_home"; then
        echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: retry target home unsafe: $VALIDATION_ERROR"
        continue
      fi
      home_real="$VALIDATED_HOME"
      [ "$home_real" = "$home" ] || {
        echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: retry target home changed"
        continue
      }
      head=$(git -C "$home_real" rev-parse HEAD 2>/dev/null || true)
      [ -n "$head" ] && [ "$head" = "$commit" ] || {
        echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: retry target is not at recorded instruction commit"
        continue
      }
      if out=$(JG_HOME="$JG_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
        rm -f "$marker"
        echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
      else
        echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: $(first_line "$out")"
      fi
    done
  }

  local tmp line
  squad_lead_retry_pending_nudges
  tmp=$(mktemp "${TMPDIR:-/tmp}/jg-squad-lead-sync.XXXXXX" 2>/dev/null) || return 0
  sweep_live_squad_lead_metas "$STATE" "$primary_head" yes "$(jg_compat_pick "$DATA/squad_leads.md")" >"$tmp"
  while IFS= read -r line; do
    case "$line" in
      squad_lead\ *': skipped:'*) echo "SQUAD_LEAD_SYNC: $line" ;;
      BOOTSTRAP_INFO:\ *) echo "$line" ;;
      NUDGE_SQUAD_LEADS:\ *) echo "$line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  unset -f jg_ff_after_instruction_update
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into every VALIDATED live squad_lead home swept above.
  # FF_SEEN_HOMES is exactly that set, and jg-config-inherit-lib.sh owns the
  # declared config items plus data/captain-shared.md.
  # After a successful push that changes allowlisted config/* for an already-
  # running home, send its literal-content reread instruction pointer so the
  # live agent does not keep applying stale defaults. Spawn/respawn already
  # re-reads at launch and needs no redundant nudge unless files changed after launch.
  local id home home_real home_lock propagated_homes report reread_out reread_skip_pending
  propagated_homes=""
  SQUAD_LEAD_RESPAWNED_IDS=${SQUAD_LEAD_RESPAWNED_IDS:-}
  while IFS='|' read -r id home _window _meta; do
    validate_squad_lead_home "$id" "$home" || continue
    # Parked-home guard (juggernaut-addons/parked-homes): a parked home gets no
    # inherited config push and no reread nudge. No-op without the add-on.
    jg_parked_skip_meta "$STATE/$id.meta" "$id" config-reread && continue
    home_real="$VALIDATED_HOME"
    case " $FF_SEEN_HOMES " in
      *" $home_real "*) ;;
      *) continue ;;
    esac
    case " $propagated_homes " in
      *" $home_real "*) continue ;;
    esac
    propagated_homes="$propagated_homes $home_real"
    mkdir -p "$home_real/state" || {
      echo "CONFIG_REREAD: squad_lead $id: send failed: could not create state directory"
      continue
    }
    home_lock=$(jg_config_inherit_lock_path "$home_real") || {
      echo "CONFIG_REREAD: squad_lead $id: send failed: could not resolve per-home lock"
      continue
    }
    jg_lock_acquire_wait "$home_lock" || {
      echo "CONFIG_REREAD: squad_lead $id: send failed: could not acquire per-home lock"
      continue
    }
    reread_skip_pending=0
    case " $SQUAD_LEAD_RESPAWNED_IDS " in
      *" $id "*) reread_skip_pending=1 ;;
    esac
    if [ "$reread_skip_pending" -eq 0 ] \
      && jg_config_reread_retry_queue_is_full "$JG_HOME" "$id"; then
      jg_config_reread_retry_pending "$id" "$home_real" || true
      if jg_config_reread_retry_queue_is_full "$JG_HOME" "$id"; then
        echo "CONFIG_REREAD: squad_lead $id: send failed: retry instruction queue is full"
        jg_lock_release "$home_lock" || true
        continue
      fi
    fi
    report=$(mktemp "${TMPDIR:-/tmp}/jg-bootstrap-inherit.XXXXXX" 2>/dev/null) || {
      echo "SQUAD_LEAD_SYNC: squad_lead $id: skipped: inheritance failed"
      jg_lock_release "$home_lock" || true
      continue
    }
    if JG_CONFIG_INHERIT_REPORT="$report" JG_CONFIG_INHERIT_LIVE=1 \
      propagate_squad_lead_inheritance "$JG_HOME" "$home_real" "$CONFIG" "$DATA"; then
      :
    else
      echo "SQUAD_LEAD_SYNC: squad_lead $id: skipped: inheritance failed"
    fi
    if ! reread_out=$(JG_HOME="$JG_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" \
      JG_STATE_OVERRIDE="$STATE" \
      JG_CONFIG_REREAD_SKIP_PENDING="$reread_skip_pending" \
      jg_config_send_reread_nudge "$id" "$home_real" "$report" 2>&1); then
      if [ -n "$reread_out" ]; then
        printf '%s\n' "$reread_out"
      else
        echo "CONFIG_REREAD: squad_lead $id: send failed: unknown error"
      fi
    elif [ -n "$reread_out" ]; then
      printf '%s\n' "$reread_out"
    fi
    rm -f "$report"
    jg_lock_release "$home_lock" || true
  done < <(live_squad_lead_meta_records "$STATE" "$(jg_compat_pick "$DATA/squad_leads.md")")

  # One remote squad_lead's convergence, split out of the loop so each host is
  # individually timed; every `return` here was a `continue` and still means
  # "move on to the next squad_lead".
  squad_lead_sync_remote_one() {  # <id> <home> <remote-host>
    local id=$1 _home=$2 remote_host=$3
    local sync_out sync_rc inherit_out nudge_needed remote_marker remote_pending converged out remote_lock remote_generation
    remote_lock=$(jg_remote_inherit_transaction_lock_path "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_lock" ] || ! jg_lock_acquire_wait "$remote_lock"; then
      echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: cannot lock remote inheritance transaction"
      return 0
    fi
    if ! "$SCRIPT_DIR/jg-procevent-remote-reply.sh" arm "$id" >/dev/null 2>&1; then
      echo "SQUAD_LEAD_LIVENESS: squad_lead $id: skipped: remote reply source could not be registered"
    fi
    remote_generation=$(jg_remote_inherit_generation_next "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_generation" ]; then
      echo "SQUAD_LEAD_SYNC: squad_lead $id: skipped: remote inheritance generation could not be published"
      jg_lock_release "$remote_lock" || true
      return 0
    fi
    remote_marker=$(squad_lead_nudge_marker_path "$id" 2>/dev/null || true)
    remote_pending=0
    if [ -f "$remote_marker" ] && [ "$(jg_meta_get "$remote_marker" remote)" = 1 ]; then remote_pending=1; fi
    if ! squad_lead_write_nudge_marker "$id" "$_home" "" remote \
      "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" 1; then
      echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: cannot record remote retry marker"
      jg_lock_release "$remote_lock" || true
      return 0
    fi
    nudge_needed=0
    converged=1
    if sync_out=$("$SCRIPT_DIR/jg-on.sh" "$id" jg-remote-squad-lead-control.sh sync "$id" \
      "$primary_head" < /dev/null 2>&1); then
      case "$sync_out" in synced:*) nudge_needed=1 ;; esac
    else
      sync_rc=$?
      echo "SQUAD_LEAD_SYNC: squad_lead $id: skipped: remote tracked-file sync failed on $remote_host: $(remote_sync_failure_reason "$sync_rc" "$sync_out")"
      converged=0
    fi
    if inherit_out=$(JG_CONFIG_INHERIT_LIVE=1 \
      "$SCRIPT_DIR/jg-remote-inherit-push.sh" "$id" "$remote_generation" 2>&1); then
      if printf '%s\n' "$inherit_out" | grep -Eq '^(pushed|removed):'; then nudge_needed=1; fi
    else
      echo "SQUAD_LEAD_SYNC: squad_lead $id: skipped: remote inheritance failed on $remote_host: $(remote_inherit_failure_reason "$inherit_out")"
      converged=0
    fi
    [ "$remote_pending" -eq 0 ] || nudge_needed=1
    if [ "$converged" -eq 1 ] && [ "$nudge_needed" -eq 1 ]; then
      if out=$(JG_HOME="$JG_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" JG_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/jg-send.sh" "jg-$id" "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
        rm -f "$remote_marker"
        [ "${JG_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] || echo "BOOTSTRAP_INFO: nudged remote jg-$id after convergence"
      else
        echo "NUDGE_SQUAD_LEADS: squad_lead $id: send failed: $(first_line "$out")"
      fi
    elif [ "$converged" -eq 1 ]; then
      rm -f "$remote_marker"
    fi
    jg_lock_release "$remote_lock" || true
    return 0
  }

  squad_lead_sync_remote_one_timed() {  # <id> <home> <remote-host>
    local id=$1 home=$2 remote_host=$3 __jg_timing_stamp
    __jg_timing_stamp=$(jg_timing_now_ms)
    squad_lead_sync_remote_one "$id" "$home" "$remote_host"
    jg_timing_record squad_lead convergence "$__jg_timing_stamp" "$id@$remote_host"
  }

  # Remote routes converge through the generic transport. The primary commit is
  # authoritative for tracked files, while inherited files come from this
  # primary home; no local path probe or local fast-forward is attempted for
  # either remote surface.
  local remote_host __jg_timing_stamp parallel=0
  if bootstrap_parallel_begin; then
    parallel=1
  fi
  while IFS='|' read -r id _home _window meta; do
    # Parked-home guard (juggernaut-addons/parked-homes): a parked home gets no
    # remote inheritance push and no reread nudge. No-op without the add-on.
    jg_parked_skip_meta "$meta" "$id" sync && continue
    remote_host=$(jg_meta_get "$meta" remote_host)
    [ -n "$remote_host" ] || continue
    if [ "$parallel" -eq 1 ]; then
      bootstrap_parallel_spawn squad_lead_sync_remote_one_timed "$id" "$_home" "$remote_host"
    else
      squad_lead_sync_remote_one_timed "$id" "$_home" "$remote_host"
    fi
  done < <(live_squad_lead_meta_records "$STATE" "$(jg_compat_pick "$DATA/squad_leads.md")")
  [ "$parallel" -eq 0 ] || bootstrap_parallel_finish
  return 0
}

# A relaunch replaces the endpoint record a digest may already have printed. On
# the local pass that digest has not been composed yet, so the fact stays behind
# JG_BOOTSTRAP_VERBOSE_FACTS as before; on the deferred network pass the digest
# is already out, so reporting it is what keeps the superseded record from being
# acted on.
report_relaunch() {  # <id> <cause> <where>
  [ "${JG_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] || ! local_phase || return 0
  echo "BOOTSTRAP_INFO: squad_lead $1 relaunched after $2 ($3)"
}

squad_lead_liveness_sweep() {
  # Idempotent squad_lead liveness guarantee at session start; the watcher's
  # squad_lead_liveness_tick owns the same guarantee mid-session. The detailed
  # state machine and its only recovery-authorizing states are owned by
  # jg_backend_agent_state. A missing tmux pane is not enough: tmux must prove
  # the window or session absent. This preserves duplicate prevention for
  # existing ambiguous processes and every transiently unreadable target while
  # adding the missing-session path the original bare-shell and Herdr-husk sweep
  # lacked.
  # A meta with no window remains owned by squad-lead-provisioning recovery.
  # SquadLead homes never contain kind=squad_lead meta, so this is naturally a
  # primary-only no-op there. The probe/relaunch mechanics live in
  # bin/jg-squad-lead-liveness-lib.sh; this sweep keeps the reporting.
  [ -d "$STATE" ] || return 0
  local meta id remote_host label __jg_timing_stamp parallel=0
  SQUAD_LEAD_RESPAWNED_IDS=""
  if bootstrap_parallel_begin; then
    parallel=1
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    jg_compat_meta_is_squad_lead "$meta" || continue
    # Identity for the timing record is read here, in the loop, so the per-meta
    # body below keeps its single-exit-per-outcome shape.
    id=$(basename "$meta" .meta)
    # Parked-home guard (juggernaut-addons/parked-homes): a parked home gets no
    # liveness probe and no session-start relaunch - one line names the skip.
    # No-op without the add-on checkout.
    jg_parked_skip_meta "$meta" "$id" bootstrap-liveness && continue
    if squad_lead_dormant "$STATE" "$id"; then
      echo "SQUAD_LEAD_LIVENESS: squad_lead $id: skipped: dormant with no open work"
      continue
    fi
    remote_host=$(jg_meta_get "$meta" remote_host)
    label=$id
    [ -z "$remote_host" ] || label="$id@$remote_host"
    if [ "$parallel" -eq 1 ]; then
      bootstrap_parallel_spawn squad_lead_liveness_one_timed "$meta" "$id" "$label"
    else
      squad_lead_liveness_one_timed "$meta" "$id" "$label"
    fi
  done
  [ "$parallel" -eq 0 ] || bootstrap_parallel_finish
  return 0
}

squad_lead_liveness_one_timed() {  # <meta> <id> <label>
  local meta=$1 id=$2 label=$3 __jg_timing_stamp
  __jg_timing_stamp=$(jg_timing_now_ms)
  squad_lead_liveness_one "$meta" "$id"
  jg_timing_record squad_lead liveness "$__jg_timing_stamp" "$label"
}

# One squad_lead's liveness check. Split out of the sweep so each is individually
# timed; every `return` here was a `continue` in the loop and means exactly the
# same thing - move on to the next squad_lead. Respawned ids are recorded through
# squad_lead_note_respawned so a concurrent sweep can collect them after wait.
# Probe classification, kill, and spawn live in jg-squad-lead-liveness-lib.sh;
# this function keeps this sweep's exact reporting.
squad_lead_liveness_one() {  # <meta> <id>
  local meta=$1 id=$2
  if ! jg_squad_lead_liveness_lock "$id"; then
    echo "SQUAD_LEAD_LIVENESS: squad_lead $id: skipped: another liveness check is already in progress"
    return 0
  fi
  jg_squad_lead_liveness_probe "$meta" "$id" full
  case "$JG_SM_LIVE_STATUS" in
    silent)
      ;;
    alive)
      [ "${JG_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] || echo "BOOTSTRAP_INFO: $JG_SM_LIVE_LINE"
      ;;
    relaunchable)
      if jg_squad_lead_liveness_relaunch "$meta" "$id"; then
        squad_lead_note_respawned "$id"
        report_relaunch "$id" "$JG_SM_LIVE_CAUSE" "$JG_SM_LIVE_WHERE"
      elif [ "$JG_SM_LIVE_STATUS" = skipped ] || [ "$JG_SM_LIVE_STATUS" = deferred ]; then
        echo "SQUAD_LEAD_LIVENESS: squad_lead $id: skipped: $JG_SM_LIVE_REASON"
      else
        echo "SQUAD_LEAD_LIVENESS: squad_lead $id: respawn failed after $JG_SM_LIVE_CAUSE: $(first_line "$JG_SM_LIVE_OUT")"
      fi
      ;;
    skipped)
      echo "SQUAD_LEAD_LIVENESS: squad_lead $id: skipped: $JG_SM_LIVE_REASON"
      ;;
  esac
  jg_squad_lead_liveness_unlock "$id"
  return 0
}

squad_lead_handoff_resume() {
  [ -d "$DATA/handoff" ] || return 0
  "$SCRIPT_DIR/jg-backlog-handoff.sh" --resume-pending >/dev/null 2>&1 || true
}

squad_lead_handoff_detect() {
  local outbox id count
  [ -d "$DATA/handoff" ] || return 0
  for outbox in "$DATA/handoff"/*.outbox.md; do
    [ -e "$outbox" ] || continue
    id=$(basename "$outbox" .outbox.md)
    case "$id" in ''|*[!A-Za-z0-9._-]*) id=unknown ;; esac
    if [ ! -f "$outbox" ] || [ -L "$outbox" ]; then
      echo "SQUAD_LEAD_HANDOFF: squad_lead $id: pending delivery: unsafe outbox"
      continue
    fi
    count=$(awk '/^- \[[ x]\] / { count++ } END { print count + 0 }' "$outbox" 2>/dev/null || printf unknown)
    echo "SQUAD_LEAD_HANDOFF: squad_lead $id: pending delivery: $count item(s)"
  done
}

install_cmd() {
  local spec
  case "$1" in
    tmux|node|git|gh|curl|jq|orca|zellij) echo "brew install $1  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    learn-from-mistakes) echo "npm install -g $(jg_pin_npm learn-from-mistakes) && ln -sf learn-from-mistakes-axi \"\$(dirname \"\$(command -v learn-from-mistakes-axi)\")/learn-from-mistakes\"" ;;
    *)
      # Every npm tool installs the exact build its toolchain.versions row names, so this
      # command and the installer cannot disagree about a version.
      spec=$(jg_pin_npm "$1") || return 1
      case "$1" in
        gh-axi|chrome-devtools-axi) echo "npm install -g $spec && $1 setup hooks" ;;
        *) echo "npm install -g $spec" ;;
      esac
      ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    cursor-agent) echo "https://cursor.com/cli" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# jg_backend_required_tools (bin/jg-backend.sh). So a herdr/zellij/cmux home is
# never told tmux is missing, and only orca drops treehouse. A backend value with
# no verified dependency set is reported before the universal checks continue.
COMMON_TOOLS="node git gh no-mistakes gh-axi chrome-devtools-axi tasks-axi quota-axi learn-from-mistakes done-done sign-off-axi"
BACKEND=$(jg_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(jg_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
# Every floor below is read from its toolchain.versions row, so a bump moves installation, detection and
# this diagnostic together.
NO_MISTAKES_MIN=$(jg_pin_version no-mistakes) || NO_MISTAKES_MIN=0.0.0
# AXI-FAMILY FLOOR POLICY. Every axi-family floor is the CURRENT LATEST published
# version of that tool, captain-bumped periodically to keep the whole fleet on the
# newest axi tools. It is NOT the minimum feature-introduced version. These floors
# are expected to drift upward as new versions ship. Never lower a floor to the
# earliest release that happens to satisfy some depended-on behavior. The
# tasks-axi feature probes are an independent defense-in-depth concern, not part
# of its floor.
GH_AXI_MIN=$(jg_pin_version gh-axi) || GH_AXI_MIN=0.0.0
LEARN_FROM_MISTAKES_AXI_MIN=$(jg_pin_version learn-from-mistakes) || LEARN_FROM_MISTAKES_AXI_MIN=0.0.0
# The proof and decision tools Juggernaut publishes install at the exact build
# their toolchain.versions rows name, and that row is their floor too, so one bump
# moves installation, detection and this diagnostic together.
DONE_DONE_AXI_MIN=$(jg_pin_version done-done) || DONE_DONE_AXI_MIN=0.0.0
SIGN_OFF_AXI_MIN=$(jg_pin_version sign-off-axi) || SIGN_OFF_AXI_MIN=0.0.0

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

# Shared semantic-version floor for the tool gates below. A version string that
# cannot be parsed into exactly one major.minor.patch triple is incompatible,
# never assumed current, so a development or vendored build cannot pass a floor
# it was never checked against.
tool_version_parts() {  # <tool>
  local tool=$1 output parts major minor patch extra
  command -v "$tool" >/dev/null 2>&1 || return 1
  output=$("$tool" --version 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  printf '%s %s %s\n' "$major" "$minor" "$patch"
}

version_parts_at_least() {  # <major minor patch> <min-version>
  local major minor patch min=$2 min_major min_minor min_patch min_extra
  IFS=' ' read -r major minor patch <<< "$1"
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

tool_version_at_least() {  # <tool> <min-version>
  local parts
  parts=$(tool_version_parts "$1") || return 1
  version_parts_at_least "$parts" "$2"
}

x_mode_write_if_changed() {
  local dest=$1 content=$2 mode=$3 parent tmp parent_device current_mode
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    parent_device=$(/usr/bin/stat -f %d "$parent" 2>/dev/null) || return 1
  else
    parent_device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fmx_single_link_file_valid "$dest" "$parent_device" || return 1
    if [ "$(uname)" = Darwin ]; then
      current_mode=$(/usr/bin/stat -f %Lp "$dest" 2>/dev/null) || return 1
    else
      current_mode=$(stat -c %a "$dest" 2>/dev/null) || return 1
    fi
    if [ "$current_mode" = "$mode" ] && cmp -s "$dest" <(printf '%s\n' "$content"); then
      return 0
    fi
  fi
  tmp=$(umask 077; mktemp "$parent/.jg-x-mode.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod "$mode" "$tmp" \
    || ! fmx_single_link_file_mode_valid "$tmp" "$mode" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fmx_single_link_file_valid "$dest" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fmx_single_link_file_mode_valid "$dest" "$mode" "$parent_device" \
    || ! cmp -s "$dest" <(printf '%s\n' "$content"); then
    rm -f -- "$dest"
    return 1
  fi
}

x_mode_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

x_mode_remove_artifact() {
  local artifact=$1 parent=${1%/*}
  x_mode_artifact_present "$artifact" || return 0
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  rm -f -- "$artifact" 2>/dev/null || return 1
  ! x_mode_artifact_present "$artifact"
}

# X mode (opt-in): when this home's .env carries a non-empty FMX_PAIRING_TOKEN,
# wire the relay poll into the existing authenticated watcher dispatch.
# Drops two idempotent, gitignored artifacts:
#   state/x-watch.check.sh - byte-static identity shim; the watcher validates
#                            its bytes and invokes bin/jg-x-poll.sh directly
#   config/x-mode.env      - exports JG_CHECK_INTERVAL=30, sourced by the watcher
#                            arm so only an X instance polls at the 30s cadence
# On opt-out (no token, or empty) it removes any such artifacts so the instance
# reverts to the default 300s no-poll behavior. Absent a token AND with no leftover
# artifacts it is a complete no-op (nothing written, nothing printed), so a non-X
# user sees zero change. Prints one confirmation line on opt-in, and one on opt-out
# only when it actually removed artifacts. It never touches the watcher itself;
# applying a cadence transition to a running watcher is the caller's job via
# the emitted harness-aware supervision repair instruction.
x_mode_setup() {
  local env_file token shim cadence shim_body cadence_body tool missing shim_home
  env_file="$JG_HOME/.env"
  shim="$STATE/x-watch.check.sh"
  cadence="$CONFIG/x-mode.env"

  token=
  [ -f "$env_file" ] && token=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")

  x_mode_remove_artifacts() {
    local failed=0
    x_mode_remove_artifact "$shim" || failed=1
    x_mode_remove_artifact "$cadence" || failed=1
    [ "$failed" -eq 0 ]
  }

  x_mode_supervision_repair() {
    local out
    out=$("$SCRIPT_DIR/jg-supervision-instructions.sh" --repair-line 2>/dev/null) \
      || out='repair missing watcher supervision according to the session-start operating block.'
    printf '%s\n' "$out"
  }

  if [ -z "$token" ]; then
    # Opt-out (or never opted in): drop any X artifacts; stay silent unless we
    # actually removed something.
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - removed relay poll shim and 30s cadence; default cadence applies on the next supervision cycle; $(x_mode_supervision_repair)"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence"
      fi
    fi
    return 0
  fi

  missing=0
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "MISSING: $tool (install: $(install_cmd "$tool"))"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - missing relay poll dependencies; install them and rerun bootstrap"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence after missing relay poll dependencies"
      fi
    fi
    return 0
  fi

  fmx_arm_failed() {
    if x_mode_remove_artifacts; then
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence"
    else
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence; stale artifacts remain"
    fi
  }

  mkdir -p "$STATE" "$CONFIG" 2>/dev/null || { fmx_arm_failed; return 0; }

  case "$JG_HOME" in
    /*) shim_home=$JG_HOME ;;
    *)
      shim_home=$(CDPATH='' cd -- "$JG_HOME" 2>/dev/null && pwd -P) \
        || { fmx_arm_failed; return 0; }
      ;;
  esac
  shim_body=$(fmx_poll_shim_content "$shim_home" "$JG_ROOT")
  x_mode_write_if_changed "$shim" "$shim_body" 700 || { fmx_arm_failed; return 0; }
  fmx_poll_shim_valid "$shim" "$shim_home" "$JG_ROOT" \
    || { fmx_arm_failed; return 0; }

  cadence_body=$(cat <<'EOF'
# Auto-generated by jg-bootstrap.sh - X mode watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# jg-watch.sh polls the X check every 30s. Non-X instances have no such file and
# keep the default 300s cadence.
export JG_CHECK_INTERVAL=30
EOF
)
  x_mode_write_if_changed "$cadence" "$cadence_body" 600 || { fmx_arm_failed; return 0; }

  echo "FMX: X mode on - relay poll armed via state/x-watch.check.sh; 30s watcher cadence in config/x-mode.env"
}

crew_dispatch_validate() {
  local file err verified_harnesses typed_key typed_active=false
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  typed_key=$TYPESAFE_API_KEY_PRIVATE
  [ -n "$typed_key" ] || typed_key=$(fmx_env_get TYPESAFE_API_KEY "$JG_HOME/.env")
  [ -z "$typed_key" ] || typed_active=true
  if $typed_active; then
    verified_harnesses=$(jg_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')
  else
    verified_harnesses='["claude","codex","opencode","pi","pi-signed","grok","kimi","cursor","agy","muse","rovo","omp","devin"]'
  fi
  err=$(jq -r --argjson typed "$typed_active" --argjson verified_harnesses "$verified_harnesses" --arg provider_re "$JG_QUOTA_PROVIDER_ID_RE" '
    def verified($h): $verified_harnesses | index($h);
    def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
    def effort_ok($h; $m; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "agy" then (["low","medium","high"] | index($e))
      elif $h == "pi" or $h == "pi-signed" or $h == "omp" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "muse" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "rovo" then (["low","medium","high","max"] | index($e))
      elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + [(.tiers // {})[]? | profiles(.)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)))
      or ($typed and ($items | any(has("provider") and (provider_id(.provider) | not))));
    # A quota floor, on a rule or a profile: bin/jg-dispatch-resolve.sh applies
    # it in code against one quota-axi row, so scope and min_percent must be
    # concrete; a rule floor also names the provider whose row it reads.
    def floor_bad($f; $need_provider):
      ($f | type) != "object"
      or (($f.scope | type) != "string") or (($f.scope | length) == 0)
      or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
      or (if $need_provider
          then (provider_id($f.provider) | not)
          else ($f | has("provider"))
          end);
    def malformed_profile_floors($items):
      ($items | any(has("floor") and floor_bad(.floor; false)));
    def tier_names: ["easy", "standard", "hard", "frontier"];
    def tier_profiles: [((.tiers // {})[]? | profiles(.)[]?)];
    def bad_efforts:
      configured_profiles
      | map({h: .harness, m: .model, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.m; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    (.tiers // {}) as $tier_map |
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array" and (has("tier") | not))] | length > 0 then "each rule needs use or a tier"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0 and (has("tier") | not))] | length > 0 then "each rule needs at least one use profile or a tier"
    elif [(.rules // [])[]? | select(has("tier") and ((.tier? | type) != "string" or (.tier | length) == 0))] | length > 0 then "rule tier must be a non-empty string when present"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then
      if $typed then "use profile model and effort must be non-empty strings, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
      else "use profile model and effort must be non-empty strings when present"
      end
    elif $typed and malformed_profile_floors([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile floor needs scope and min_percent 0..100"
    elif $typed and ([(.rules // [])[]? | select(has("approval") and .approval != "captain")] | length > 0) then "approval must be \"captain\" when present"
    elif $typed and ([(.rules // [])[]? | select(has("floor") and floor_bad(.floor; true))] | length > 0) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
    elif $typed and ([(.rules // [])[]? | select(has("min_confidence") and ((.min_confidence | type) != "number" or .min_confidence < 0 or .min_confidence > 1))] | length > 0) then "min_confidence must be a number from 0 through 1 when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("tiers") and (.tiers | type) != "object" then "tiers must be an object"
    elif [$tier_map | keys[] | . as $t | select((tier_names | index($t)) == null)] | length > 0 then
      "unknown tier: " + ([$tier_map | keys[] | . as $t | select((tier_names | index($t)) == null)] | unique | join(", ")) + " (tiers are easy, standard, hard, and frontier)"
    elif [(.rules // [])[]? | select(has("tier")) | .tier as $t | select((($tier_map) | has($t)) | not) | $t] | length > 0 then
      "each rule tier needs a tiers entry: " + ([(.rules // [])[]? | select(has("tier")) | .tier as $t | select((($tier_map) | has($t)) | not) | $t] | unique | join(", "))
    elif [$tier_map[] | select((profiles(.) | length) == 0)] | length > 0 then "each tier needs at least one profile"
    elif [tier_profiles[]? | select(type != "object")] | length > 0 then "each tier profile must be an object"
    elif [tier_profiles[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each tier profile needs harness"
    elif malformed_optional_fields(tier_profiles) then
      if $typed then "tier profile model and effort must be non-empty strings, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
      else "tier profile model and effort must be non-empty strings when present"
      end
    elif $typed and malformed_profile_floors(tier_profiles) then "tier profile floor needs scope and min_percent 0..100"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then
      if $typed then "default profile model and effort must be non-empty strings, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
      else "default profile model and effort must be non-empty strings when present"
      end
    elif $typed and has("default") and malformed_profile_floors([profiles(.default)[]?]) then "default profile floor needs scope and min_percent 0..100"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  if [ "${JG_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end);
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "quota-balanced") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    def rule_route($r):
      if $r | has("tier") then "tier " + ($r.tier | tostring)
      else profile_set($r.use; $r.select?)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + rule_route(.)]
      + [(.tiers // {}) | to_entries[]? | "BOOTSTRAP_INFO: crew dispatch tier: " + .key + " -> " + profile_set(.value; null)]
      + (if has("default") then ["BOOTSTRAP_INFO: crew dispatch default: " + profile_set(.default; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

# Same-home record reconciliation. Every ordinary dispatch and completion now
# moves the backlog row inside the script that moves the task's record
# (bin/jg-backlog-transition-lib.sh), so remaining recovery cases include a
# process killed mid-transition and drift this home was already carrying. Heal
# this home's OWN books on its own
# restart rather than waiting for a parent's cross-home nudge; the fleet
# snapshot's classifier and bin/jg-squad-lead-reconcile.sh's nudge stay as
# backstops for what this cannot see. Never reads or writes another home.
backlog_record_reconcile() {
  local marker meta control_lock meta_lock id row label has_record=0 gate_status
  # A fresh home with no state directory has no physical task records to pair.
  # Keep bootstrap diagnostics working without creating state just for a no-op.
  [ -e "$STATE" ] || [ -L "$STATE" ] || return 0
  if ! jg_backlog_directory_present "$STATE" "state directory"; then
    echo "error: backlog reconciliation refused: $JG_BACKLOG_TRANSITION_ERROR" >&2
    return 2
  fi
  if jg_backlog_transition_applies "$CONFIG" "$DATA" "$BOOTSTRAP_BACKLOG_GATE_KIND"; then
    :
  else
    gate_status=$?
    if [ "$gate_status" -eq 2 ]; then
      echo "error: backlog reconciliation cannot access configured data directory $DATA ($JG_BACKLOG_TRANSITION_ERROR)" >&2
      return 2
    fi
    return 0
  fi
  # Keep the wake/lock library's source-time state-directory creation inside
  # this mutating sweep, so JG_BOOTSTRAP_DETECT_ONLY remains read-only.
  # shellcheck source=bin/jg-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/jg-wake-lib.sh"

  # Finish any close an interrupted cleanup recorded but never landed.
  for marker in "$STATE"/*.backlog-close; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    if ! jg_backlog_record_present "$marker" "pending-close record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe pending close refused: $JG_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    label=$(basename "$marker" .backlog-close)
    control_lock="$STATE/.control-$label.lock"
    meta_lock=$(jg_meta_lock_path "$STATE/$label.meta") || continue
    jg_lock_try_acquire "$control_lock" || continue
    if ! jg_lock_try_acquire "$meta_lock"; then
      jg_lock_release "$control_lock"
      continue
    fi
    if jg_backlog_close_marker_replay "$STATE" "$marker" "$DATA"; then
      case "$JG_BACKLOG_CLOSE_REPLAY_RESULT" in
        closed)
          echo "BOOTSTRAP_INFO: closed the backlog item for $label that an interrupted cleanup left open"
          ;;
        closed_incomplete)
          echo "BOOTSTRAP_INFO: closed the backlog item for $label after interrupted cleanup; its endpoint or local copy may remain and should be reconciled"
          ;;
        retained)
          echo "BOOTSTRAP_INFO: kept the captain call for $label open with its deliverable recorded after an interrupted cleanup"
          ;;
        retained_incomplete)
          echo "BOOTSTRAP_INFO: kept the captain call for $label open with its deliverable recorded after interrupted cleanup; its endpoint or local copy may remain and should be reconciled"
          ;;
        answered)
          echo "BOOTSTRAP_INFO: finished the interrupted cleanup for $label; the captain had already answered its call"
          ;;
      esac
    else
      echo "BACKLOG_RECONCILE: $label: recorded backlog close could not be replayed: $JG_BACKLOG_TRANSITION_ERROR"
    fi
    jg_lock_release "$meta_lock"
    jg_lock_release "$control_lock"
  done

  # A home that owns no records has nothing to pair, so it never pays for a
  # backlog read. A pending close remains authoritative even when replay failed:
  # the record sweep below must not start that item while its marker survives.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if ! jg_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe worker record refused: $JG_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    has_record=1
    break
  done
  [ "$has_record" = 1 ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if ! jg_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe worker record refused: $JG_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    id=$(basename "$meta" .meta)
    meta_lock=$(jg_meta_lock_path "$meta") || continue
    jg_lock_try_acquire "$meta_lock" || continue
    if [ -e "$STATE/$id.backlog-close" ] || [ -L "$STATE/$id.backlog-close" ]; then
      jg_lock_release "$meta_lock"
      continue
    fi
    if ! jg_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: $id: post-lock worker record check refused: $JG_BACKLOG_TRANSITION_ERROR"
      jg_lock_release "$meta_lock"
      return 2
    fi
    if [ "$(jg_meta_get "$meta" kind)" != squad_lead ] \
       && [ "$(jg_meta_get "$meta" cleanup_recovery)" != orca ]; then
      row=
      if jg_backlog_row_probe "$DATA" "$id"; then
        row=$JG_BACKLOG_ROW_STATE
      elif [ "$JG_BACKLOG_ROW_RESULT" != not_found ]; then
        echo "BACKLOG_RECONCILE: $id: worker record exists but its backlog item could not be read: $JG_BACKLOG_ROW_ERROR"
      fi
      # Heal only the unambiguous case: a queued row for a record this home
      # already owns. A held row is the captain's to move, and a closed row is a
      # contradiction this sweep must not resolve by resurrecting the item.
      if [ "$row" = "queued no no" ]; then
        if jg_backlog_start "$DATA" "$id"; then
          echo "BOOTSTRAP_INFO: marked $id in flight to match the worker this home already owns"
        else
          echo "BACKLOG_RECONCILE: $id: worker record exists but its backlog item could not be moved to In flight: $JG_BACKLOG_TRANSITION_ERROR"
        fi
      fi
    fi
    jg_lock_release "$meta_lock"
  done
}

startup_memory_budget_setup() {
  # Primary bootstrap owns default publication. A squad_lead is deliberately
  # passive here because its setting must converge from the primary through the
  # inherited-local-material contract rather than becoming a local authority.
  if [ -e "$(jg_compat_marker "$JG_HOME")" ] || [ -L "$(jg_compat_marker "$JG_HOME")" ]; then
    return 0
  fi
  if ! jg_startup_memory_budget_materialize "$CONFIG"; then
    echo "STARTUP_MEMORY_BUDGET: invalid config/$JG_STARTUP_MEMORY_BUDGET_FILE - $JG_STARTUP_MEMORY_BUDGET_ERROR"
  fi
}

# An install is not wiring: the proof and decision tools also need the skill
# their package ships, the brief include, and the merge gate.
# bin/jg-tool-wiring.sh owns each write and is idempotent, so this runs on every
# locked session - a home that already has its tool installed gets wired - and
# prints nothing once a home is complete. A successful first wiring prints what
# it wrote, including sign-off's one-line arming reminder; arming itself stays
# per home and is never done here.
companion_tool_wiring() {
  local tool out
  for tool in done-done sign-off; do
    if out=$("$SCRIPT_DIR/jg-tool-wiring.sh" "$tool" 2>&1); then
      [ -z "$out" ] || printf '%s\n' "$out"
      continue
    fi
    echo "BOOTSTRAP_INFO: $tool wiring not applied: ${out:-unknown error}"
  done
}

if [ "${1:-}" = "version" ]; then
  # The one owner of version parsing, so the installer never carries its own copy.
  parts=$(tool_version_parts "${2:?usage: jg-bootstrap.sh version <tool>}") || exit 1
  printf '%s\n' "${parts// /.}"
  exit 0
fi

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: jg-bootstrap.sh install <tool>..." >&2; exit 1; }
  # Installs stay user-local and need no sudo: a package-manager prefix the user owns, and the tool
  # callable in this same shell straight after its install. An explicit NPM_CONFIG_PREFIX wins.
  export NPM_CONFIG_PREFIX=${NPM_CONFIG_PREFIX:-$HOME/.local}
  export PATH=$NPM_CONFIG_PREFIX/bin:$PATH
  for t in "$@"; do
    # Manual guidance is checked before the install command, because a tool with manual
    # instructions has no row in toolchain.versions: probing install_cmd first would surface
    # the pin table's refusal ahead of the guidance the user actually needs.
    if instructions=$(manual_install_url "$t"); then
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    if ! cmd=$(install_cmd "$t"); then
      echo "error: unknown tool $t" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd" || { echo "error: installing $t failed: $cmd" >&2; exit 1; }
    case $t in
      done-done) "$SCRIPT_DIR/jg-tool-wiring.sh" done-done || exit 1 ;;
      sign-off-axi) "$SCRIPT_DIR/jg-tool-wiring.sh" sign-off || exit 1 ;;
    esac
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. Detect-only
# sessions never touch state, and the deferred network pass never repeats it:
# the local pass that ran first already closed that window.
if [ "${JG_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ] && local_phase; then
  BOOTSTRAP_BACKLOG_GATE_KIND=squad_lead
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    if ! jg_backlog_directory_present "$STATE" "state directory"; then
      echo "error: bootstrap cannot reconcile task state ($JG_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
    for BOOTSTRAP_BACKLOG_MARKER in "$STATE"/*.backlog-close; do
      [ -e "$BOOTSTRAP_BACKLOG_MARKER" ] || [ -L "$BOOTSTRAP_BACKLOG_MARKER" ] || continue
      if ! jg_backlog_record_present "$BOOTSTRAP_BACKLOG_MARKER" "pending-close record" "$STATE"; then
        echo "error: bootstrap refused unsafe pending close ($JG_BACKLOG_TRANSITION_ERROR)" >&2
        exit 1
      fi
      BOOTSTRAP_BACKLOG_GATE_KIND=ship
      break
    done
    if [ "$BOOTSTRAP_BACKLOG_GATE_KIND" = squad_lead ]; then
      for BOOTSTRAP_BACKLOG_META in "$STATE"/*.meta; do
        [ -e "$BOOTSTRAP_BACKLOG_META" ] || [ -L "$BOOTSTRAP_BACKLOG_META" ] || continue
        if ! jg_backlog_record_present "$BOOTSTRAP_BACKLOG_META" "task record" "$STATE"; then
          echo "error: bootstrap refused unsafe worker record ($JG_BACKLOG_TRANSITION_ERROR)" >&2
          exit 1
        fi
        if [ "$(jg_meta_get "$BOOTSTRAP_BACKLOG_META" kind)" != squad_lead ] \
           && [ "$(jg_meta_get "$BOOTSTRAP_BACKLOG_META" cleanup_recovery)" != orca ]; then
          BOOTSTRAP_BACKLOG_GATE_KIND=ship
          break
        fi
      done
    fi
  fi
  if jg_backlog_transition_applies "$CONFIG" "$DATA" "$BOOTSTRAP_BACKLOG_GATE_KIND"; then
    :
  else
    BOOTSTRAP_BACKLOG_GATE_STATUS=$?
    if [ "$BOOTSTRAP_BACKLOG_GATE_STATUS" -eq 2 ]; then
      echo "error: bootstrap cannot access configured backlog data directory $DATA ($JG_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
  fi
  startup_memory_budget_setup
  companion_tool_wiring
  if backlog_record_reconcile; then
    :
  else
    BOOTSTRAP_BACKLOG_RECONCILE_STATUS=$?
    if [ "$BOOTSTRAP_BACKLOG_RECONCILE_STATUS" -eq 2 ]; then
      exit 1
    fi
  fi
fi

# Local detection: presence, version floors, and configuration. Nothing here
# leaves this machine, so it stays on the session-start critical path.
detect_local_tools() {
  if [ "$BACKEND_VALID" -eq 0 ]; then
    echo "BACKEND_INVALID: $BACKEND (known: $JG_BACKEND_KNOWN)"
  fi
  for t in $BACKEND_TOOLS; do
    jg_backend_required_tool_available "$BACKEND" "$t" \
      || missing_tool_diagnostic "$t"
  done
  for t in $COMMON_TOOLS; do
    command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
  done
  # The treehouse lease-support upgrade check is only relevant when the resolved
  # backend actually requires treehouse (every backend except orca, which owns its
  # own worktrees); an orca home must not be told to upgrade a provider it never uses.
  if jg_backend_list_contains "$TOOLS" treehouse \
    && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
    echo "MISSING: treehouse (install: $(install_cmd treehouse))"
  fi
  if command -v no-mistakes >/dev/null 2>&1 && ! tool_version_at_least no-mistakes "$NO_MISTAKES_MIN"; then
    echo "MISSING: no-mistakes (install: $(install_cmd no-mistakes))"
  fi
  if command -v gh-axi >/dev/null 2>&1 && ! tool_version_at_least gh-axi "$GH_AXI_MIN"; then
    echo "MISSING: gh-axi (install: $(install_cmd gh-axi))"
  fi
  if command -v learn-from-mistakes >/dev/null 2>&1 && ! tool_version_at_least learn-from-mistakes "$LEARN_FROM_MISTAKES_AXI_MIN"; then
    echo "MISSING: learn-from-mistakes (install: $(install_cmd learn-from-mistakes))"
  fi
  if command -v done-done >/dev/null 2>&1 && ! tool_version_at_least done-done "$DONE_DONE_AXI_MIN"; then
    echo "MISSING: done-done (install: $(install_cmd done-done))"
  fi
  if command -v sign-off-axi >/dev/null 2>&1 && ! tool_version_at_least sign-off-axi "$SIGN_OFF_AXI_MIN"; then
    echo "MISSING: sign-off-axi (install: $(install_cmd sign-off-axi))"
  fi
  if command -v quota-axi >/dev/null 2>&1 && ! jg_quota_axi_compatible; then
    echo "MISSING: quota-axi (install: $(install_cmd quota-axi))"
  fi
  if command -v tasks-axi >/dev/null 2>&1 && ! jg_tasks_axi_compatible; then
    echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
  fi
}

detect_local_config() {
  # Worktree-tangle check: the juggernaut primary checkout (JG_ROOT) must sit on its
  # default branch, not a feature branch (see jg-tangle-lib.sh). Scoped to the
  # primary only; detached-HEAD worktrees and squad_lead homes never trip it.
  tangle_branch=$(jg_primary_tangle_branch "$JG_ROOT" 2>/dev/null || true)
  if [ -n "$tangle_branch" ]; then
    tangle_default=$(jg_default_branch "$JG_ROOT" 2>/dev/null || echo main)
    if [ "${JG_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ] && [ "${JG_BOOTSTRAP_LOCKED:-0}" != 1 ]; then
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
    else
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $JG_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
    fi
  fi
  crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ "${JG_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
    echo "BOOTSTRAP_INFO: crew harness override active: $crew"
  fi
  # A configured cursor crew harness needs a cursor executable present, and
  # cursor ships under EITHER installed name. Resolution runs through the
  # verified owner rather than a bare `command -v`, so a home that merely has
  # some unrelated executable named `agent` on PATH is still reported missing
  # instead of failing at the first spawn.
  if [ "$crew" = cursor ] && ! jg_cursor_resolve_binary >/dev/null 2>&1; then
    echo "MISSING_MANUAL: cursor-agent (instructions: $(manual_install_url cursor-agent))"
  fi
  crew_dispatch_validate
  if [ "${JG_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
    && ! jg_backlog_backend_manual "$CONFIG" && jg_tasks_axi_compatible; then
    echo "BOOTSTRAP_INFO: tasks-axi available"
  fi
  detect_code_root_backlog_fork
  detect_home_summary_publication
  detect_sentinel_service
}

# Restart recovery (bin/jg-sentinel.sh) must run outside the Herdr server it
# recovers from, as a systemd user service someone installs once. Without it a
# killed server leaves supervision and every worker down until noticed, so a
# primary Herdr home on a systemd host says so on every start until installed.
detect_sentinel_service() {
  [ "$BACKEND" = herdr ] || return 0
  [ -e "$(jg_compat_marker "$JG_HOME")" ] || [ -L "$(jg_compat_marker "$JG_HOME")" ] && return 0
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1 || return 0
  systemctl --user is-active --quiet jg-sentinel && return 0
  local quoted_home quoted_sentinel
  printf -v quoted_home %q "$JG_HOME"
  printf -v quoted_sentinel %q "$JG_ROOT/bin/jg-sentinel.sh"
  echo "SENTINEL: jg-sentinel is not running, so a killed Herdr server leaves supervision and workers down until someone notices (install: mkdir -p ~/.config/systemd/user && JG_HOME=$quoted_home $quoted_sentinel unit > ~/.config/systemd/user/jg-sentinel.service && systemctl --user enable --now jg-sentinel)"
}

# Shadow-backlog check. When this home's data directory is not the code root's,
# a code-root data/backlog.md or data/done-archive.md that is not this home's
# own file is a queue a cwd-relative tasks-axi write has already forked; a link
# into the home does not survive such a write (docs/configuration.md "Backlog
# backend" owns why). Detect-only: neither copy is a safe winner, so nothing is
# merged here.
detect_code_root_backlog_fork() {
  local name root_copy
  [ "$JG_ROOT/data" -ef "$DATA" ] && return 0
  for name in backlog.md done-archive.md; do
    root_copy="$JG_ROOT/data/$name"
    [ -e "$root_copy" ] || [ -L "$root_copy" ] || continue
    [ "$root_copy" -ef "$DATA/$name" ] && continue
    echo "BACKLOG_RECONCILE: code-root $root_copy is not this home's $DATA/$name; tasks-axi wrote the code root instead of this home, so rows in it may be missing here - merge it into this home's copy and move it aside"
  done
}

# This home's ledger publication is deliberately best-effort: every lifecycle
# trigger calls it with --best-effort so a failure can never change the result
# of a session start, a spawn, a teardown, or a watcher poll. That is correct,
# and it also means a home that never manages to publish says nothing at all -
# the failures land only in the bounded home-local record nobody reads.
#
# So read that same record here, where a session start already looks, and say so
# once when the evidence is a pattern rather than a blip: the ledger has not
# been (re)published, and at least JG_HOME_SUMMARY_FAILURE_REPORT attempts have
# failed since whenever it last was. No new record, no new state, no retry
# policy - just the existing evidence, surfaced.
detect_home_summary_publication() {
  local log="$STATE/.home-summary-refresh.log" ledger="$STATE/home-summary.json"
  local since='' counted failures last threshold
  threshold=${JG_HOME_SUMMARY_FAILURE_REPORT:-2}
  case "$threshold" in ''|*[!0-9]*|0) threshold=2 ;; esac
  [ -f "$log" ] && [ -r "$log" ] && [ ! -L "$log" ] || return 0
  if [ -f "$ledger" ] && [ -r "$ledger" ] && [ ! -L "$ledger" ]; then
    since=$(LC_ALL=C sed -n 's/.*"generated"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$ledger" 2>/dev/null | head -1)
  fi
  # Publication and failure stamps have whole-second precision, so failures in
  # the publication's own second remain quiet until a later failure advances
  # the record. That bounded delay avoids a precision dependency in bootstrap.
  counted=$(LC_ALL=C awk -v since="$since" '
    match($0, /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\]/) {
      stamp = substr($0, 2, RLENGTH - 2)
      if (since == "" || stamp > since) {
        n += 1
        last = substr($0, RLENGTH + 2)
      } else if (stamp == since) {
        same_second += 1
      }
    }
    END {
      if (since != "" && n > 0) n += same_second
      printf "%d\t%s", n + 0, last
    }' "$log" 2>/dev/null) || return 0
  failures=${counted%%$'\t'*}
  last=${counted#*$'\t'}
  case "$failures" in ''|*[!0-9]*) return 0 ;; esac
  [ "$failures" -ge "$threshold" ] || return 0
  last=$(printf '%s' "$last" | cut -c1-200)
  if [ -z "$since" ]; then
    echo "HOME_SUMMARY: this home has never published state/home-summary.json; $failures failed attempt(s) recorded in state/.home-summary-refresh.log, last: $last"
  else
    echo "HOME_SUMMARY: state/home-summary.json has not been republished since $since; $failures failed attempt(s) recorded in state/.home-summary-refresh.log, last: $last"
  fi
}

# The order below is the order the diagnostics have always printed in, so a
# `skip` run is the same output with the network lines removed rather than a
# reshuffle. `gh auth status` sits between the two local blocks because that is
# where it has always been.
# Each network owner below is bracketed by an elapsed-time record, so a deferred
# stage that ran long can be attributed to the phase that spent the time.
# jg-timing-lib.sh discards the record unless the caller asked for timings, and
# every sweep is still called directly. Per-squad-lead remote probes run
# concurrently; clone refresh overlaps them. Diagnostic lines are replayed in
# original order so attribution is unchanged.
# The stamp variable is named for the library rather than `start` on purpose:
# fleet_sync and others assign plain names like `start` without `local`, and
# bash's dynamic scoping would let them overwrite a stamp held by a caller.
local_phase && detect_local_tools
if network_phase; then
  __jg_timing_stamp=$(jg_timing_now_ms)
  every_project_local_only || gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
  jg_timing_record phase gh-auth "$__jg_timing_stamp"
fi
local_phase && detect_local_config

if [ "${JG_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  # squad_lead_sync consumes SQUAD_LEAD_RESPAWNED_IDS from the liveness sweep, so
  # those two always run together in the same phase. Clone refresh does not
  # depend on them, so it starts in the background and overlaps their wall clock.
  fleet_sync_pid=
  fleet_sync_out=
  if network_phase && network_sweep_authorized 'project clone refresh'; then
    fleet_sync_out=$(mktemp "${TMPDIR:-/tmp}/jg-bootstrap-fleet.XXXXXX") || fleet_sync_out=
    if [ -n "$fleet_sync_out" ]; then
      (
        __jg_timing_stamp=$(jg_timing_now_ms)
        fleet_sync
        jg_timing_record phase fleet-sync "$__jg_timing_stamp"
      ) >"$fleet_sync_out" 2>&1 &
      fleet_sync_pid=$!
    else
      __jg_timing_stamp=$(jg_timing_now_ms)
      fleet_sync
      jg_timing_record phase fleet-sync "$__jg_timing_stamp"
    fi
  fi
  if network_phase; then
    if network_sweep_authorized 'dead-squad-lead relaunch'; then
      __jg_timing_stamp=$(jg_timing_now_ms)
      squad_lead_liveness_sweep
      jg_timing_record phase squad-lead-liveness "$__jg_timing_stamp"
    fi
    if network_sweep_authorized 'squad_lead convergence'; then
      __jg_timing_stamp=$(jg_timing_now_ms)
      squad_lead_sync
      jg_timing_record phase squad-lead-sync "$__jg_timing_stamp"
    fi
    if network_sweep_authorized 'pending handoff delivery'; then
      __jg_timing_stamp=$(jg_timing_now_ms)
      squad_lead_handoff_resume
      jg_timing_record phase handoff-delivery "$__jg_timing_stamp"
    fi
  fi
  # x_mode_setup writes local Relay artifacts only and never leaves the machine.
  local_phase && x_mode_setup
  # Adopt existing durable contribution links without making a network call.
  # Detection-only startup must never publish a check registration.
  if local_phase && command -v jq >/dev/null 2>&1 \
    && [ -d "$DATA" ] && [ -x "$SCRIPT_DIR/jg-contributions.sh" ]; then
    "$SCRIPT_DIR/jg-contributions.sh" arm --if-owned >/dev/null \
      || echo "MISSING: contribution observation could not be armed; coverage is unconfirmed"
  fi
  # A primary home always runs the fleet heartbeat, so a stalled or idle home
  # wakes Main without anyone arming it; config/fleet-heartbeat-off opts out.
  if local_phase && [ ! -e "$(jg_compat_marker "$JG_HOME")" ] \
    && [ ! -e "$CONFIG/fleet-heartbeat-off" ] && [ "$STATE" = "$JG_HOME/state" ] && [ -d "$STATE" ]; then
    JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-fleet-heartbeat.sh" arm >/dev/null 2>&1 \
      || echo "MISSING: the fleet heartbeat could not be armed; idle or stalled homes will not wake Main"
  fi
  # The board gate: only a must ask reaches the captain's board, and a merge
  # lands with its Evidence card. Same primary-home guard as the fleet heartbeat.
  if local_phase && [ ! -e "$(jg_compat_marker "$JG_HOME")" ] \
    && [ "$STATE" = "$JG_HOME/state" ] && [ -d "$STATE" ]; then
    JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-board-gate.sh" arm >/dev/null 2>&1 \
      || echo "MISSING: the board gate could not be armed; non-must asks stay on the board and merges go unproven"
  fi
  # The peak-price window end is a deterministic event: the watcher runs this
  # check, which wakes the leads to dispatch the work that waited, with no model
  # in the loop. config/peak-guard-off opts a home out.
  if local_phase && [ ! -e "$(jg_compat_marker "$JG_HOME")" ] \
    && [ ! -e "$CONFIG/peak-guard-off" ] && [ "$STATE" = "$JG_HOME/state" ] && [ -d "$STATE" ]; then
    JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-peak-gate.sh" arm >/dev/null 2>&1 \
      || echo "MISSING: the peak-price window check could not be armed; work deferred for off-peak will not wake a lead"
  fi
  if [ -n "$fleet_sync_pid" ]; then
    wait "$fleet_sync_pid" || true
    cat "$fleet_sync_out"
    rm -f "$fleet_sync_out"
  fi
fi
local_phase && squad_lead_handoff_detect
exit 0
