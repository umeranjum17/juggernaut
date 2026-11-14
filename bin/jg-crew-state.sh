#!/usr/bin/env bash
# jg-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After juggernaut resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, re-validates), the
# log's last line stays stale. This helper never infers the current state from
# a tail of the log: it reads the authoritative source (the pane
# busy-signature) and reconciles the possibly-stale log against it.
# A ship `done:` is current-state done only when bin/jg-dod-lib.sh accepts the
# named head as reachable outside the worker's disposable copy; otherwise blocked.
#
# The determinism lives entirely here - pane / log reads and fixed mapping
# logic, with no heuristics and no LLM.
# Output is one stable, parseable, token-tight line juggernaut can read every
# heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <pane|status-log|remote-endpoint|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta. A meta
#      recording remote_host= is a remote squad_lead: its worktree and endpoint
#      live on that host, so the local worktree and pane reads are skipped and
#      the remote host is asked for the endpoint's recovery-grade state
#      (jg-on.sh + jg-remote-squad-lead-control.sh state). alive falls through
#      to the routed status log; dead/missing report the remote verdict; an
#      unreachable or unreadable remote reports unknown-remote, never a false
#      gone/dead.
#   2. Read the recorded backend's pane busy state, then the resolved status
#      declaration when its verb maps to a recognized run-state. Decision-only
#      events such as `resolved` never become current state or detail.
#   3. Missing meta or torn-down worktree: report unknown · none. A dead
#      endpoint also reports unknown · none rather than trusting a stale
#      status log. On tmux and herdr, which own a
#      recovery-grade classifier, only its positive death evidence reads as gone
#      (the endpoint is authoritatively absent, or its pane holds no agent); an
#      endpoint that merely failed to answer reports unknown · none as
#      unreachable, and an alive endpoint whose scrollback read failed is still
#      classified by step 2. Backends with no classifier keep reading a failed
#      capture as gone. The fallback's own comment owns the per-verdict rules.
#
# Read-only, with one sanctioned repair: when the task's recorded Herdr pane is
# gone because a muxr account move replaced it, and the same task's agent is
# positively live in another pane of its worktree, the task record's endpoint
# lines follow it (bin/jg-endpoint-follow-lib.sh). Nothing else is written.
# Always exits 0 on a successful read regardless of state; exit 2 only on a
# usage error (no id).
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
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"

# shellcheck source=bin/jg-tmux-lib.sh
. "$SCRIPT_DIR/jg-tmux-lib.sh"
# shellcheck source=bin/jg-backend.sh
. "$SCRIPT_DIR/jg-backend.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"
# shellcheck source=bin/jg-busy-lib.sh
. "$SCRIPT_DIR/jg-busy-lib.sh"
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"
# shellcheck source=bin/jg-endpoint-follow-lib.sh
. "$SCRIPT_DIR/jg-endpoint-follow-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: jg-crew-state.sh <id>" >&2; exit 2; }

# Fleet snapshot composition supplies its captured metadata path here so every
# state read resolves the same task generation selected by that snapshot.
META=${JG_CREW_STATE_META_OVERRIDE:-"$STATE/$ID.meta"}
LOG=${JG_CREW_STATE_STATUS_OVERRIDE:-"$STATE/$ID.status"}
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
REMOTE_HOST=$(meta_value remote_host)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read. A
# remote squad_lead's recorded worktree is a path on ITS host, so the local
# probe proves nothing for it - the remote arm below reads the true source.
if [ -z "$REMOTE_HOST" ] && { [ -z "$WT" ] || [ ! -d "$WT" ]; }; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (jg-classify-lib.sh's JG_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
# A ship `done:` is not current-state done while bin/jg-dod-lib.sh refuses the
# named-head reachability gate: that claim is blocked so a disposable copy is
# not treated as finished-and-safe.
emit_ship_status_done() {  # [extra-detail]
  local extra=${1:-} reason
  if reason=$(jg_dod_accept_ship_done "$KIND" "$(meta_value mode)" "$WT" "$(meta_value project)" "$LOG_LINE" "$STATE" "$ID" "$META"); then
    emit "done" status-log "$(status_line_note "$LOG_LINE")${extra:+${SEP}$extra}"
  fi
  emit blocked status-log "$reason"
}

map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(status_current_line "$LOG" "$KIND")
LOG_VERB=$(status_line_verb "$LOG_LINE")

# --- remote squad_lead: the true source is the remote endpoint ---------------
# A remote mate's recorded worktree and backend target live on its own host, so
# the local worktree probe above and the local pane reads below would misreport
# a healthy remote mate as gone or dead. Ask the remote host for the endpoint's
# recovery-grade state over the same jg-on.sh transport jg-send uses, then read
# current activity from the routed status log exactly as for a local
# squad_lead (an idle endpoint is healthy for a squad_lead either way). An
# unreachable host or unreadable endpoint is reported as unknown-remote -
# explicitly NOT proof of death - so a transport blip never reads as a torn
# down or dead mate; only the remote host's own dead/missing verdict may say
# the endpoint is actually gone.
if [ -n "$REMOTE_HOST" ]; then
  if ! REMOTE_STATE=$(JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-on.sh" "$ID" \
    jg-remote-squad-lead-control.sh state "$ID" < /dev/null 2>/dev/null); then
    REMOTE_STATE=
  fi
  REMOTE_STATE=$(printf '%s\n' "$REMOTE_STATE" | tail -1)
  case "$REMOTE_STATE" in
    alive)
      if [ -n "$LOG_VERB" ]; then
        LOG_STATE=$(map_log_state "$LOG_LINE")
        if [ "$LOG_STATE" != unknown ]; then
          emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")${SEP}remote endpoint alive on $REMOTE_HOST"
        fi
      fi
      emit unknown remote-endpoint "alive on $REMOTE_HOST (an idle squad_lead is healthy)"
      ;;
    dead|missing)
      emit unknown remote-endpoint "remote endpoint $REMOTE_STATE on $REMOTE_HOST"
      ;;
    '')
      emit unknown remote-endpoint "unknown-remote: $REMOTE_HOST unreachable or endpoint unreadable (not proof of death)"
      ;;
    *)
      emit unknown remote-endpoint "unknown-remote: endpoint state '$REMOTE_STATE' on $REMOTE_HOST (not proof of death)"
      ;;
  esac
fi

# pane_readable is consulted before the busy and status-log reads below.
# Backend-aware
# (jg_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through jg_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(jg_backend_of_meta "$META")
BACKEND_TARGET=$(jg_backend_target_of_meta "$META")
# A muxr account move replaces the worker's Herdr pane; the record follows it
# here (bin/jg-endpoint-follow-lib.sh owns when, and what changes), so every
# state below reads the pane the worker runs in. The repair is of the live
# record, never of a snapshot copy; the target is re-read either way.
if [ "$TASK_BACKEND" = herdr ] && [ "$META" = "$STATE/$ID.meta" ]; then
  jg_endpoint_follow "$META" "$ID" "$STATE" || true
  BACKEND_TARGET=$(jg_backend_target_of_meta "$META")
fi
EXPECTED_LABEL="jg-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    tmux) tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 ;;
    *) jg_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_busy_verdict: the crew's semantic busy state from the one contract
# owner (bin/jg-busy-lib.sh), as "<busy|idle|unknown> <source>". A converted
# adapter answers from its own lifecycle record; Grok answers from its
# isolated rendered-tail fallback; a herdr crew's native `busy` is accepted
# when no record exists, but its native `idle` is NOT, because agent.get
# reports generation state (idle while a crew blocks on its own long-running
# foreground tool call) rather than turn state. The tail is captured
# unconditionally (not just for Grok) so this authoritative read also sees
# jg_busy_lib's launch-prompt backstop: without it, a launch parked on a
# recognized interactive prompt would report `working` here while the
# watcher's own poll (which always captures a tail) already classifies it
# unknown - the exact split issue #1792 describes for a different cause.
crew_busy_verdict() {  # <target>
  local tail40
  tail40=$(jg_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || tail40=''
  jg_busy_classify "$TASK_BACKEND" "$1" "$HARNESS" "$ID" "$STATE" "$tail40"
}

# --- pane and status-log reads ---------------------------------------------
# Only positive evidence that the target is gone may
# read as death - a backend that failed to answer is unknown, never death, for
# both classifier-backed backends (tmux and herdr) - and every death-class
# verdict reports unknown rather than trusting a possibly-stale status log as
# the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
if ! pane_readable "$BACKEND_TARGET"; then
  # A failed probe is not itself evidence the pane is gone: the herdr CLI can
  # error or stall under load, and tmux can fail to be executed at all (a
  # trimmed PATH) or answer non-definitively, while the pane is alive - a busy
  # box would otherwise score dozens of live claims dead. Both backends own a
  # recovery-grade classifier (jg_backend_agent_state), which separates the
  # outcomes:
  #   missing - the endpoint is authoritatively absent: herdr's pane get
  #             answered pane_not_found; tmux's successful window inventory
  #             omitted the exact recorded window, or tmux gave one of its
  #             definitive no-session/no-server/no-socket responses (which
  #             jg_backend_tmux_agent_state owns as death, since jg-bootstrap
  #             and jg-session-start depend on it to license a respawn after a
  #             genuine server death - a socket-connection failure is NOT
  #             covered by the unknown-never-death rule above).
  #   dead    - the endpoint exists but confidently has no agent (herdr's agent
  #             get answered agent_not_found, or its registration lingers over a
  #             pane whose processes are nothing but shells - issue #4115;
  #             tmux's readable foreground process group is nothing but
  #             shells), still positive death evidence.
  #   alive   - the endpoint and its agent answered and only the heavy
  #             scrollback read failed, so the live state is classified by the
  #             normal flow below instead of being discarded.
  #   anything else - the cheap probes themselves failed to answer or
  #             contradicted themselves, which is unknown, never death.
  # Backends with no classifier (orca, zellij, and cmux all report unverified)
  # keep their historical capture-failure-means-gone reading.
  case "$TASK_BACKEND" in
    tmux|herdr) AGENT_STATE=$(jg_backend_agent_state "$TASK_BACKEND" "$BACKEND_TARGET") ;;
    *) AGENT_STATE=none ;;
  esac
  case "$TASK_BACKEND:$AGENT_STATE" in
    tmux:alive|herdr:alive)
      ;;
    tmux:missing|herdr:missing)
      emit unknown none "backend target gone: $BACKEND_TARGET"
      ;;
    tmux:dead|herdr:dead)
      emit unknown none "backend target gone: $BACKEND_TARGET (agent gone, pane shell remains)"
      ;;
    tmux:*|herdr:*)
      emit unknown none "backend unreachable ($TASK_BACKEND endpoint state: $AGENT_STATE)"
      ;;
    *)
      emit unknown none "backend target gone: $BACKEND_TARGET"
      ;;
  esac
fi

# SquadLeads idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown.
if [ "$KIND" != squad_lead ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy) emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
    idle) ;;
    dead) emit unknown pane "agent not running under its busy record ($BUSY_VERDICT)" ;;
    *) emit unknown pane "harness state unavailable ($BUSY_VERDICT)" ;;
  esac
fi

# A lead whose runtime fails every turn (the watcher's errors wait source,
# bin/jg-stuck-gate-lib.sh) is blocked, steadily: its pane never settles and its
# status log says nothing. The source is rewritten on every sighting and lapses
# with the cause, so a repaired lead leaves this state within a few polls.
if [ "$KIND" = squad_lead ]; then
  ERRORS_SRC="$STATE/.wait-sources/$ID.errors"
  if [ -f "$ERRORS_SRC" ] && [ ! -L "$ERRORS_SRC" ]; then
    ERRORS_AT=$(stat -c %Y "$ERRORS_SRC" 2>/dev/null || stat -f %m "$ERRORS_SRC" 2>/dev/null || echo 0)
    ERRORS_FRESH=${JG_POLL:-15}; ERRORS_FRESH=${ERRORS_FRESH%%.*}
    ERRORS_FRESH=$(( ${ERRORS_FRESH:-0} * 3 + 30 ))
    if [ $(( $(date +%s) - ERRORS_AT )) -le "$ERRORS_FRESH" ]; then
      emit blocked pane "runtime failing every turn: $(head -n 1 "$ERRORS_SRC" | tr '\t' ' ' | cut -c1-200)"
    fi
  fi
fi

# Fall back to the resolved status declaration, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (jg-classify-lib.sh's
# JG_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a squad_lead, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  if [ "$LOG_VERB" = "done" ]; then
    emit_ship_status_done
  fi
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
