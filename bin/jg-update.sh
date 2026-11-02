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
# After the fast-forward it runs bin/jg-stack.sh up, so the release arrives with its services.
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
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
SQUAD_LEADS_MD="$(jg_compat_pick "$JG_HOME/data/squad_leads.md")"
# shellcheck source=bin/jg-ff-lib.sh
. "$SCRIPT_DIR/jg-ff-lib.sh"
# shellcheck source=bin/jg-squad-lead-restart-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-restart-lib.sh"

"$SCRIPT_DIR/jg-guard.sh" || true

usage() { echo "usage: jg-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main juggernaut repo ---------------------------------------------------

reread_juggernaut="no"
# A home whose code root is a leased worktree runs on a DETACHED HEAD at the default
# branch tip; that is this platform's ordinary home shape, not drift, so the primary
# takes the same allowance a Squad Lead home already takes. Nothing else relaxes: a
# dirty tree, a named branch that is not the default, a fetch failure, and a unique
# local commit are all still skipped, so nothing is forced, merged, or stashed.
ff_target "$JG_ROOT" "juggernaut" origin yes no
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

# The services come with the release: run the updated checkout's own install command so a
# release never lands on a machine without them. A failure is reported, never fatal to the update.
if [ "${JG_STACK_SKIP:-0}" != 1 ] && [ -x "$JG_ROOT/bin/jg-stack.sh" ]; then
  JG_HOME="$JG_HOME" "$JG_ROOT/bin/jg-stack.sh" up || echo "stack: not whole after the update (see the STACK_FAILED line above)" >&2
else
  # No stack run (JG_STACK_SKIP or an older checkout): the bus alone still comes up.
  ensure_bus_service "$JG_ROOT"
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

# --- caller action summary -------------------------------------------------

# claim_settled_squad_lead puts each live settled mate in exactly one set, so the
# two lines below are disjoint by construction: no mate is ever restarted and
# then also steered about the instructions it just relaunched on.

echo "reread-juggernaut: $reread_juggernaut"
echo "restart-squad-leads:${FF_RESTART_WINDOWS:- none}"
echo "nudge-squad-leads:${FF_STEER_WINDOWS:- none}"
