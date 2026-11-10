#!/usr/bin/env bash
# Self-update a running juggernaut and its squad_leads to the latest origin.
#
# Mechanical half of the /resupply skill. Fast-forwards the running
# juggernaut repo's default branch from origin, then fast-forwards every
# registered squad_lead home. Local homes are treehouse worktrees or standalone
# clones; remote routes update their configured code root on that host and then
# fast-forward the persistent home to that root. FAST-FORWARD ONLY, exactly like
# jg-fleet-sync.sh: never force, never create a merge commit, never stash.
# A squad_lead divergence whose complete local tree result is already present at
# the target is reconciled with reset --keep; every other unsafe target is
# skipped and reported, with divergence recorded durably by jg-ff-lib.sh.
# A tracked-files update never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a squad_lead's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. SquadLead homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch. The primary home can
# be leased the same way, so a detached HEAD at an ancestor of the target is
# advanced rather than skipped, and a primary holding a unique commit is still
# skipped.
#
# The fast-forward mechanics live in bin/jg-ff-lib.sh (base_mode "origin" here);
# the same library drives local and remote parent-targeted squad_lead sync, so
# there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge squad_leads itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-juggernaut: yes|no    (did the running juggernaut's instructions change)
#   - restart-squad-leads: jg-<id>...|none (every live squad_lead this pass left
#     on origin's tip - advanced OR already there - whose recorded runtime can
#     prove a restart)
#   - nudge-squad-leads: jg-<id>...|none   (the residual: live squad_leads on
#     that same tip whose runtime CANNOT prove a restart, so the older re-read
#     steer is all that is honest for them)
#
# The two sets are disjoint, and restart is UNCONDITIONAL on a successful update
# of that home. It is deliberately not gated on the git diff: replacing the agent
# is the only thing that re-resolves the launch-time wiring - turn-end hooks,
# harness flags, per-harness feature switches - which a running agent froze when
# it started and which no changed_instr list describes. An unchanged tracked
# surface therefore is NOT evidence that the running agent is already on the
# current behavior, so an ALREADY-CURRENT home restarts too.
#
# Only two things keep a live mate out of the restart set, and neither is papered
# over as a reload:
#   - its home was SKIPPED (dirty, uniquely diverged, offline, unsafe). It is not
#     on the new bytes, nothing here forces, stashes, or discards it, and it gets
#     no action at all. A divergence remains in the durable reconciliation record
#     that this or a later bootstrap/update pass surfaces.
#   - its runtime cannot prove the old agent stopped and a replacement came up
#     (bin/jg-squad-lead-restart-lib.sh owns that test), so it falls to the
#     honest re-read steer and is reported as a nudge, never as a reload.
# A positively dead or missing endpoint has no agent to replace and is left to
# the ordinary startup recovery.
#
# A fast-forward that lands changes bytes under bin/ in place, which desyncs
# the trust binding of any locally armed jg-procevent-when watch whose action
# executable lives in the updated repo; left alone, the watch's next fire
# would be wrongly refused. After each home's own update (primary and every
# local squad_lead), this script best-effort runs that home's own
# jg-procevent-when.sh rebind-all to republish those bindings against the new
# bytes; a failure there is swallowed rather than failing the update.
#
# After the fast-forward it runs bin/jg-stack.sh up, so the release arrives with its services, and
# bin/jg-host-wiring.sh, so every installed host copy (the merge watcher included) equals core again.
#
# FLEET LIVE MOVE (--base): a project registered local-trunk is moved from its LOCAL trunk, never from origin.
# `jg-trunk.sh live` exports the trunk tip's own bin/ and runs this script from that copy:
#   jg-update.sh --base <sha> --project <project-dir> --branch <trunk-branch> [--home <lead-home>]
# One home at a time, registered Squad Lead homes first and Main's clone LAST (pool worktrees and lane branches are not
# homes and are never touched). The homes are Main's registry plus Main, whichever home runs this: a lead home follows its
# parent record up to Main (bin/jg-fleet-homes-lib.sh), so a go-live run from a lead moves every home, itself included.
# The last line printed names every home that is not at the base (`fleet: not every home is at <sha>: <ids>`) and the exit is
# 1; a go-live records its `live` row only on exit 0. Each home gets exactly one row in data/trunk-live.tsv:
#   <project>:<home-id> <sha> <epoch> <status> <pre-move HEAD>      (Main's home id is "primary")
#   live                        fast-forwarded, or already there
#   live,re-pointed-from:<sha>  HEAD was not an ancestor but the tip holds its whole tree: reset --keep, never a merge
#   skipped:dirty | skipped:unlanded:<paths> | skipped:<other reason>   not touched
#   live,pinned-back-from:<sha> the base is BEHIND the home (a red CI) and the home holds only trunk commits: reset --keep to the base
#   rolled-back:<reason>        the health check failed: the home is pinned back to its pre-move HEAD and the rollout stops
#                               (a missing-guard reason carries the refusal of the guard install that ran first)
#   <status>,wiring-failed:<steps>   the home stands on <sha> but these host wiring steps failed (the move itself stands)
# After a home moves, bin/jg-home-guard.sh install <home> and bin/jg-home-health.sh check <home> <sha> run when present.
# Then every home that stands on <sha> (moved, or rolled back to a pre-move HEAD that already was <sha>) runs its own
# bin/jg-host-wiring.sh --changed: only the steps whose sources changed since that home last wired, so its installed host
# copies equal its core/ and a move that changed no wired source runs no wiring. A failed step never blocks the move or
# the rollout; it is named in the home's row.
# Moving anything clears state/squad-lead-summary-cache (an observational cache). Main's move writes
# state/trunk-live-restart-pending for the next locked session start. --home moves that one lead only (the canary).
# Without --base a local-trunk project is refused: its code comes from its trunk, not from origin.
#
# Usage: jg-update.sh [--help]
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
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
SQUAD_LEADS_MD="$(jg_compat_pick "$JG_HOME/data/squad_leads.md")"
# shellcheck source=bin/jg-ff-lib.sh
. "$SCRIPT_DIR/jg-ff-lib.sh"
# shellcheck source=bin/jg-squad-lead-restart-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-restart-lib.sh"
# shellcheck source=bin/jg-squad-lead-parent-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-parent-lib.sh"
# shellcheck source=bin/jg-fleet-homes-lib.sh
. "$SCRIPT_DIR/jg-fleet-homes-lib.sh"

"$SCRIPT_DIR/jg-guard.sh" || true

usage() { echo "usage: jg-update.sh [--help | --base <sha> --project <dir> --branch <trunk> [--home <lead-home>]]" >&2; }

BASE="" PROJECT="" TRUNK_BRANCH=trunk ONLY_HOME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --base) BASE=${2:-}; shift 2 || { usage; exit 1; } ;;
    --project) PROJECT=${2:-}; shift 2 || { usage; exit 1; } ;;
    --branch) TRUNK_BRANCH=${2:-}; shift 2 || { usage; exit 1; } ;;
    --home) ONLY_HOME=${2:-}; shift 2 || { usage; exit 1; } ;;
    *) usage; exit 1 ;;
  esac
done
if [ -n "$BASE" ]; then
  [ -n "$PROJECT" ] && [ -n "$TRUNK_BRANCH" ] || { usage; exit 1; }
elif [ -n "$PROJECT$ONLY_HOME" ]; then
  usage; exit 1
elif [ "$(env JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="${JG_DATA_OVERRIDE:-$JG_HOME/data}" "$SCRIPT_DIR/jg-project-mode.sh" --raw juggernaut 2>/dev/null | cut -d' ' -f1 || true)" = local-trunk ]; then
  echo "REFUSED: juggernaut is registered local-trunk; update this project from its trunk (jg-trunk.sh live), not from origin" >&2
  exit 1
fi

# --- main juggernaut repo ---------------------------------------------------

reread_juggernaut="no"
# A home whose code root is a leased worktree runs on a DETACHED HEAD at the default
# branch tip; that is this platform's ordinary home shape, not drift, so the primary
# takes the same allowance a Squad Lead home already takes. Nothing else relaxes: a
# dirty tree, a named branch that is not the default, a fetch failure, and a unique
# local commit are all still skipped, so nothing is forced, merged, or stashed.
if [ -n "$BASE" ]; then FF_STATUS=skipped; FF_INSTR=""; else ff_target "$JG_ROOT" "juggernaut" origin yes no; fi
if [ "$FF_STATUS" = "updated" ]; then
  if [ -n "$FF_INSTR" ]; then
    reread_juggernaut="yes"
  fi
  # A fast-forward changes bin/'s bytes out from under any locally armed
  # jg-procevent-when watch's trust binding, with no tampering involved; left
  # alone, the very next fire is refused and the watch dies silently. Refresh
  # every such watch now, right after the update that broke it. JG_ROOT_OVERRIDE
  # is passed explicitly rather than relying on the script's own location: this
  # process's own JG_ROOT is the repo that was just updated, which is not
  # always where this very script file happens to live (JG_ROOT_OVERRIDE, as
  # this test suite uses to point jg-update.sh at a fixture checkout).
  JG_HOME="$JG_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" "$SCRIPT_DIR/jg-procevent-when.sh" rebind-all || true
fi

# The bus is a SERVICE, not a process someone remembers to start: a release that lands
# the bus code on a home - or lands on a home that never had it - otherwise goes live
# with no message server, and every steer and lead restart is refused until somebody
# starts one by hand, which a reboot then takes away again. So every pass asks the
# updated home's own command to install or start it, and prints its one line. Best
# effort: a home whose bus cannot start still finishes its update.
ensure_bus_service() {  # <home>
  local home=$1 out
  [ -f "$home/bin/jg-bus.sh" ] || return 0
  if out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$home" "$home/bin/jg-bus.sh" install-service 2>&1); then
    [ -z "$out" ] || printf '%s\n' "$out"
  else
    echo "bus: could not start in $home: ${out:-unknown error}"
  fi
}

# (--base mode moves code only: the services below stay with a release; host wiring runs per moved home in move_home.)
if [ -z "$BASE" ]; then
# The services come with the release: run the updated checkout's own install command so a
# release never lands on a machine without them. A failure is reported, never fatal to the update.
# A Squad Lead home runs none of the machine's services (Main owns them, bin/jg-unit-claim.sh
# owns why), so it only registers its own bus account below.
if [ "${JG_STACK_SKIP:-0}" != 1 ] && [ -x "$JG_ROOT/bin/jg-stack.sh" ] \
  && [ ! -e "$JG_HOME/.jg-squad-lead-home" ] && [ ! -L "$JG_HOME/.jg-squad-lead-home" ]; then
  JG_HOME="$JG_HOME" "$JG_ROOT/bin/jg-stack.sh" up || echo "stack: not whole after the update (see the STACK_FAILED line above)" >&2
  # Prove it after the release: one line per service, and the verdict a live claim reads.
  [ ! -x "$JG_ROOT/bin/jg-live-services.sh" ] || JG_HOME="$JG_HOME" "$JG_ROOT/bin/jg-live-services.sh" || true
else
  # No stack run (JG_STACK_SKIP or an older checkout): the bus alone still comes up.
  ensure_bus_service "$JG_ROOT"
fi

# The host wiring comes with the release too: every fleet check a core feature installs outside the
# checkout (the merge watcher is the one that drifted, three days behind core, so no merge in that home
# got a no-model merge) is rewritten from the updated checkout, so an installed copy never outlives the
# core it was copied from. Each fragment is idempotent; a step that fails is named by the wiring itself
# and is reported here, never fatal to the update. JG_HOST_WIRING_SKIP=1 turns it off for a fixture.
if [ "${JG_HOST_WIRING_SKIP:-0}" != 1 ] && [ -x "$JG_ROOT/bin/jg-host-wiring.sh" ]; then
  env JG_HOME="$JG_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" "$JG_ROOT/bin/jg-host-wiring.sh" "$JG_HOME" >&2 \
    || echo "host wiring: not whole after the update (see the jg-host-wiring lines above)" >&2
fi
fi

# --- squad_leads -----------------------------------------------------------
# Every live squad_lead this pass leaves on origin's tip is restarted, whether it
# advanced or was already there. The header above owns why the git diff does not
# gate that, and which two conditions - a skipped home, an unprovable runtime -
# are the only ways a live mate stays out of the restart set.

# FF_NUDGE_WINDOWS and FF_SEEN_HOMES are the sweep's own accumulators and are
# reset here per its contract; the instruction-gated nudge set is the session-start
# sweep's threshold, not this command's, so only the two sets below are read.
FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""
FF_RESTART_WINDOWS=""
FF_STEER_WINDOWS=""

squad_lead_agent_may_be_alive() {  # <id>
  local id=$1 meta="$STATE/$1.meta" remote_host state=unreadable
  remote_host=$(jg_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    state=$("$SCRIPT_DIR/jg-on.sh" "$id" \
      jg-remote-squad-lead-control.sh state "$id" < /dev/null 2>/dev/null) || state=unreadable
  elif jg_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
    state=$(jg_backend_agent_state "$JG_BACKEND_VALIDATED_BACKEND" \
      "$JG_BACKEND_VALIDATED_TARGET" 2>/dev/null) || state=unreadable
  fi
  case "$state" in
    dead|missing) return 1 ;;
    *) return 0 ;;
  esac
}

selector_claimed() {  # <selector>
  case " $FF_RESTART_WINDOWS $FF_STEER_WINDOWS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Route one squad_lead whose home this pass left on the target commit. Restart is
# the outcome unless its runtime cannot prove one, in which case it keeps the
# re-read steer and is reported as a nudge rather than as a reload. A stopped
# endpoint has no agent to replace and is left to startup recovery.
claim_settled_squad_lead() {  # <id>
  local id=$1
  selector_claimed "jg-$id" && return 0
  squad_lead_agent_may_be_alive "$id" || return 0
  if jg_squad_lead_restart_capable "$STATE/$id.meta"; then
    FF_RESTART_WINDOWS="$FF_RESTART_WINDOWS jg-$id"
  else
    FF_STEER_WINDOWS="$FF_STEER_WINDOWS jg-$id"
  fi
}

# bin/jg-ff-lib.sh calls this for each local home it left AT the base with a live
# endpoint - status "updated" or "current" alike. A skipped home never gets here.
jg_ff_after_squad_lead_settled() {  # <id> <home> <window> <status> <instr>
  # Same bin/-changed-out-from-under-a-watch problem as the primary home
  # above, for a local squad_lead's own worktree; "current" means bin/ did
  # not move there this pass, so there is nothing to rebind. Run the
  # squad_lead's OWN copy of the script, explicitly overriding JG_ROOT to its
  # own worktree rather than letting an outer JG_ROOT_OVERRIDE (this process's
  # own, if the caller set one) leak into the child and misscope it.
  if [ "${4:-}" = "updated" ] && [ -x "$2/bin/jg-procevent-when.sh" ]; then
    JG_HOME="$2" JG_ROOT_OVERRIDE="$2" "$2/bin/jg-procevent-when.sh" rebind-all || true
  fi
  claim_settled_squad_lead "$1"
}

# --- fleet live move (--base): see the header ---------------------------------
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
FLEET_RC=0 FLEET_VERDICT=""

# The home's own wiring (bin/jg-host-wiring.sh --changed from the code the home now holds) re-runs every step whose
# sources changed since that home last wired, so an installed sync.py equals the home's core/ after a live move and a
# move that changed no wired source runs nothing. Run after the move and its health check; a failure never blocks the
# move or the rollout and sets WIRE_FAILED to the failed steps for the row. JG_HOST_WIRING_SKIP=1 turns it off for a fixture.
wire_home() {  # <dir> <label>
  local dir=$1 label=$2 out rc=0
  WIRE_FAILED=
  [ "${JG_HOST_WIRING_SKIP:-0}" != 1 ] && [ -x "$dir/bin/jg-host-wiring.sh" ] || return 0
  out=$(env -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE -u JG_CONFIG_OVERRIDE JG_HOME="$dir" JG_ROOT_OVERRIDE="$dir" \
    "$dir/bin/jg-host-wiring.sh" --changed "$dir" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ "$rc" -ne 0 ] || return 0
  WIRE_FAILED=$(printf '%s\n' "$out" | sed -n 's/.*, failed: *//p' | tail -n 1 | tr -s ' ' ',')
  WIRE_FAILED=${WIRE_FAILED:-exit-$rc}
  echo "$label: host wiring not whole after the move: $WIRE_FAILED failed (see the jg-host-wiring lines above)" >&2
}

# Move one home to $BASE and write its row. Sets MOVE_RESULT=moved|skipped|stopped.
move_home() {  # <home-id> <dir> <label> <ignore-seed-marker>
  local key=$1 dir=$2 label=$3 seed=$4 pre out mb paths status tmp guard_why
  MOVE_RESULT=skipped
  pre=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
  if ! git -C "$dir" cat-file -e "$BASE^{commit}" 2>/dev/null; then
    git -C "$dir" fetch -q "$PROJECT" "refs/heads/$TRUNK_BRANCH" 2>/dev/null || true
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/jg-live-move.XXXXXX") || return 0
  # A pin-back (a red CI): BASE is behind this home and everything the home holds is on the trunk, so the home steps
  # back by reset --keep (the home guard admits it with JG_TRUNK_PINBACK=1); a dirty home is skipped, never forced.
  if [ "$pre" != "$BASE" ] && git -C "$dir" merge-base --is-ancestor "$BASE" "$pre" 2>/dev/null \
    && git -C "$PROJECT" merge-base --is-ancestor "$pre" "refs/heads/$TRUNK_BRANCH" 2>/dev/null \
    && [ -z "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ] \
    && JG_TRUNK_PINBACK=1 git -C "$dir" reset -q --keep "$BASE" 2>/dev/null; then
    FF_STATUS=updated; FF_INSTR=""; echo "$label: pinned back ${pre:0:12}..${BASE:0:12}" > "$tmp"
  else
    ff_target "$dir" "$label" "$BASE" yes "$seed" "" "" yes > "$tmp"
  fi
  out=$(cat "$tmp"); rm -f -- "$tmp"; printf '%s\n' "$out"
  case "$FF_STATUS" in
    updated|current)
      status=live
      case "$out" in *"reconciled redundant divergence"*) status="live,re-pointed-from:${pre:0:12}" ;; esac
      case "$out" in *": pinned back "*) status="live,pinned-back-from:${pre:0:12}" ;; esac
      MOVE_RESULT=moved ;;
    *)
      case "$out" in
        *"dirty working tree"*) status="skipped:dirty" ;;
        *"diverged from"*)
          mb=$(git -C "$dir" merge-base "$pre" "$BASE" 2>/dev/null || true)
          paths=$(comm -12 <(git -C "$dir" diff --name-only "$mb" "$pre" 2>/dev/null | sort) \
            <(git -C "$dir" diff --name-only "$BASE" "$pre" 2>/dev/null | sort) | head -n 5 | paste -sd, -)
          status="skipped:unlanded:${paths:-diverged}" ;;
        *) status="skipped:$(first_line "${out#*skipped: }")" ;;
      esac ;;
  esac
  if [ "$MOVE_RESULT" = moved ]; then
    [ "$FF_STATUS" != updated ] || [ ! -x "$dir/bin/jg-procevent-when.sh" ] \
      || JG_HOME="$dir" JG_ROOT_OVERRIDE="$dir" "$dir/bin/jg-procevent-when.sh" rebind-all || true
    # A refused guard install is what a missing-guard health failure means, so its own reason goes in the row.
    guard_why=""
    if [ -x "$SCRIPT_DIR/jg-home-guard.sh" ]; then
      out=$("$SCRIPT_DIR/jg-home-guard.sh" install "$dir" 2>&1) || guard_why=$(first_line "$(printf '%s\n' "$out" | tail -n 1)")
      [ -z "$out" ] || printf '%s\n' "$out"
    fi
    if [ -x "$SCRIPT_DIR/jg-home-health.sh" ] && ! out=$("$SCRIPT_DIR/jg-home-health.sh" check "$dir" "$BASE" 2>&1); then
      JG_TRUNK_PINBACK=1 git -C "$dir" reset -q --keep "$pre" || true
      out=$(first_line "$(printf '%s\n' "$out" | tail -n 1)")
      case $out in missing-guard:*) [ -z "$guard_why" ] || out="missing-guard: the guard install refused: ${guard_why#jg-home-guard: }" ;; esac
      status="rolled-back:$out"; MOVE_RESULT=stopped
      echo "$label: health check failed, pinned back to ${pre:0:12}: $status"
    fi
  fi
  if [ "$MOVE_RESULT" != skipped ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$(git -C "$dir" rev-parse --verify -q "$BASE^{commit}" 2>/dev/null)" ]; then
    wire_home "$dir" "$label"
    [ -z "$WIRE_FAILED" ] || status="$status,wiring-failed:$WIRE_FAILED"
  fi
  mkdir -p "$DATA"
  printf '%s:%s\t%s\t%s\t%s\t%s\n' "$(basename "$PROJECT")" "$key" "$BASE" "$(date +%s)" "$status" "$pre" >> "$DATA/trunk-live.tsv"
}

# Every home the registry of Main names, then Main (bin/jg-fleet-homes-lib.sh lists them, from whichever home runs this).
# The verdict names every home that is not at $BASE and is the last line printed: the caller records a live row only on none.
fleet_live_move() {
  local kind id dir moved=0 found=0 abs_only="" behind="" main_home main_state
  main_home=$(jg_fleet_root_home "$JG_HOME"); main_state=$STATE
  [ "$main_home" = "$(resolve_path "$JG_HOME")" ] || main_state=$main_home/state
  [ -z "$ONLY_HOME" ] || abs_only=$(resolve_path "$ONLY_HOME")
  while IFS=$'\t' read -r kind id dir; do
    if [ -n "$abs_only" ]; then
      [ "$kind" != primary ] && [ "$(resolve_path "$dir")" = "$abs_only" ] || continue
      found=1
    fi
    case "$kind" in
      lead)
        if ! validate_squad_lead_home "$id" "$dir"; then
          echo "squad_lead $id: skipped: unsafe home: $VALIDATION_ERROR"
          printf '%s:%s\t%s\t%s\tskipped:unsafe-home\t\n' "$(basename "$PROJECT")" "$id" "$BASE" "$(date +%s)" >> "$DATA/trunk-live.tsv"
          behind="$behind $id"; continue
        fi
        move_home "$id" "$VALIDATED_HOME" "squad_lead $id" yes ;;
      self) move_home "$id" "$dir" "squad_lead $id" yes ;;
      primary)
        # Main last: its move leaves a marker for the next locked session start.
        move_home primary "$dir" juggernaut no
        if [ "$MOVE_RESULT" = moved ]; then
          [ -z "$FF_INSTR" ] || reread_juggernaut=yes
          printf 'sha=%s\nat=%s\n' "$BASE" "$(date +%s)" > "$main_state/trunk-live-restart-pending"
        fi ;;
    esac
    [ "$MOVE_RESULT" != moved ] || { moved=1; [ "$kind" = primary ] || claim_settled_squad_lead "$id"; }
    [ "$MOVE_RESULT" = moved ] || behind="$behind $id"
    [ "$MOVE_RESULT" != stopped ] || { behind="$behind (rollout stopped there)"; break; }
  done < <(jg_fleet_homes "$JG_HOME" "$JG_ROOT")
  if [ -n "$abs_only" ] && [ "$found" -eq 0 ]; then
    echo "error: no registered lead home at $ONLY_HOME" >&2; behind="$behind $ONLY_HOME"
  fi
  if [ "$moved" -eq 1 ] && [ -d "$main_state/squad-lead-summary-cache" ] && [ ! -L "$main_state/squad-lead-summary-cache" ]; then
    find "$main_state/squad-lead-summary-cache" -maxdepth 1 -type f -name '*.json' -delete
  fi
  [ -z "$behind" ] || FLEET_VERDICT="fleet: not every home is at ${BASE:0:12}:$behind"
}

if [ -n "$BASE" ]; then fleet_live_move; fi
if [ -z "$BASE" ]; then

# Live direct reports first: state/<id>.meta with kind=squad_lead carries the
# authoritative home= path.
sweep_live_squad_lead_metas "$STATE" origin yes

# Registry backstop: a squad_lead registered in data/squad_leads.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SQUAD_LEADS_MD" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! squad_lead_registry_parse_line "$line"; then
      echo "squad_lead registry: skipped malformed entry: $line" >&2
      continue
    fi
    id=$SQUAD_LEAD_REGISTRY_ID
    home=$SQUAD_LEAD_REGISTRY_HOME
    if [ "$SQUAD_LEAD_REGISTRY_REMOTE" -eq 1 ]; then
      if remote_out=$("$SCRIPT_DIR/jg-on.sh" "$id" jg-remote-squad-lead-control.sh update "$id" < /dev/null 2>&1); then
        remote_result=$(printf '%s\n' "$remote_out" | tail -1)
        case "$remote_result" in
          synced:*)
            remote_detail=${remote_result#synced: }
            # The host reports its advance as "<commit> instr=<paths>"; a host
            # whose Juggernaut copy predates that suffix reports the commit alone.
            # The suffix is now reporting detail only: the routing below no longer
            # reads it, so an older host's silence can no longer downgrade a
            # restartable mate to a steer.
            case "$remote_detail" in
              *' instr='*)
                remote_instr=${remote_detail##* instr=}
                remote_commit=${remote_detail%% instr=*}
                ;;
              *) remote_instr=""; remote_commit=$remote_detail ;;
            esac
            if [ -n "$remote_instr" ]; then
              echo "remote squad_lead $id: updated on $SQUAD_LEAD_REGISTRY_HOST ($remote_commit, instructions changed: $remote_instr)"
            else
              echo "remote squad_lead $id: updated on $SQUAD_LEAD_REGISTRY_HOST ($remote_commit)"
            fi
            if [ -f "$STATE/$id.meta" ] && jg_compat_meta_is_squad_lead "$STATE/$id.meta"; then
              claim_settled_squad_lead "$id"
            fi
            ;;
          current:*)
            echo "remote squad_lead $id: already current on $SQUAD_LEAD_REGISTRY_HOST (${remote_result#current: })"
            # Already on the target commit is a SUCCESSFUL update of that home,
            # so it earns the same restart as one that had to advance.
            if [ -f "$STATE/$id.meta" ] && jg_compat_meta_is_squad_lead "$STATE/$id.meta"; then
              claim_settled_squad_lead "$id"
            fi
            ;;
          *) echo "remote squad_lead $id: skipped on $SQUAD_LEAD_REGISTRY_HOST: malformed update result" >&2 ;;
        esac
      else
        echo "remote squad_lead $id: skipped on $SQUAD_LEAD_REGISTRY_HOST: ${remote_out%%$'\n'*}" >&2
      fi
    else
      process_squad_lead "$id" "$home" "" origin yes
    fi
  done < "$SQUAD_LEADS_MD"
fi
fi

# --- caller action summary -------------------------------------------------

# claim_settled_squad_lead puts each live settled mate in exactly one set, so the
# two lines below are disjoint by construction: no mate is ever restarted and
# then also steered about the instructions it just relaunched on.

echo "reread-juggernaut: $reread_juggernaut"
echo "restart-squad-leads:${FF_RESTART_WINDOWS:- none}"
echo "nudge-squad-leads:${FF_STEER_WINDOWS:- none}"
[ -z "$FLEET_VERDICT" ] || { echo "$FLEET_VERDICT"; FLEET_RC=1; }
exit "$FLEET_RC"
