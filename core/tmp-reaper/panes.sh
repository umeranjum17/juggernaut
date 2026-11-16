#!/usr/bin/env bash
# Close the Herdr panes that this home's fleet opened and then left with no owner.
# Usage: panes.sh [--dry-run] check|list <jg-home>
#
# What it may touch. A pane is the fleet's only when ALL of these hold, read live from Herdr each tick:
#   - its workspace id is recorded by a task record of this home (state/<id>.meta, herdr_workspace_id=, with the record's
#     herdr_session=). A record of kind squad_lead names the workspace of a CHILD home; that home reaps it, never this one.
#     A workspace no record names belongs to somebody else and is never touched, whatever its label says.
#   - no task record of this home names the pane (herdr_pane_id=): it has no owner.
#   - Herdr reports it has no agent (jg_backend_herdr_pane_agent_state = no-agent), and the process table proves it holds
#     one lone idle shell (jg_backend_herdr_pane_idle_shell_pid). A pane that runs anything else is never an orphan.
#   - it is not the pane this process runs in ($HERDR_PANE_ID of the same session).
# A pane that stays such an orphan for JG_PANE_REAPER_LIMIT_SEC (default 3600) is closed through
# jg_backend_herdr_projection_close_pane_focus_preserving, the one owner of a close that keeps the focus, with the agent
# state `no-agent` required again at the close. Only the sessions that this home's records name are read; no session is
# searched for by name, and a session that cannot be read is skipped (Herdr is never started or stopped from here).
# The clock is state/orphan-panes/<session>/<terminal-id>.seen (the epoch it was first seen). The terminal id is Herdr's
# own and is not reused, where a pane id (w1:p2) can be. A record whose pane is gone, owned, or in use again is removed.
# Every move is appended to state/panes-reaper.log.
# list also prints each orphan, as `orphan <session> <pane> <workspace> <seconds>`, with the same closing as check.
# check is the watcher-check form (silent). Exit is always 0 for check and list.
set -u
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
case "${1:-}" in check|list) ;; *) echo "usage: panes.sh [--dry-run] check|list <jg-home>" >&2; exit 2 ;; esac
[ "$#" -eq 2 ] && [ -d "$2/state" ] || { echo "usage: panes.sh [--dry-run] check|list <jg-home>" >&2; exit 2; }
MODE=$1
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
DIR=$STATE/orphan-panes
LOG=$STATE/panes-reaper.log
ATOM_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
PANE_RE='^[A-Za-z0-9][A-Za-z0-9._:-]*$'
case ${JG_PANE_REAPER_LIMIT_SEC:-} in ''|*[!0-9]*|0) LIMIT=3600 ;; *) LIMIT=$JG_PANE_REAPER_LIMIT_SEC ;; esac
command -v jq >/dev/null 2>&1 || exit 0
[ -r "$FMH/bin/jg-backend.sh" ] || exit 0
export JG_HOME=$FMH
unset JG_STATE_OVERRIDE
# shellcheck source=bin/jg-backend.sh
. "$FMH/bin/jg-backend.sh" && jg_backend_source herdr >/dev/null 2>&1 || exit 0

note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
field() { sed -n "s/^$2=//p" "$1" | head -1; }

# The records of this home, as three lists: sessions (one per line), "<session> <workspace>" the fleet made, and
# "<session> <pane>" with an owner. Only a record that names all of its endpoint is read.
SESSIONS=""; FLEET_WS=""; OWNED=""
read_records() {
  local meta s w p kind
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(field "$meta" backend)" = herdr ] || continue
    s=$(field "$meta" herdr_session); w=$(field "$meta" herdr_workspace_id); p=$(field "$meta" herdr_pane_id)
    [[ $s =~ $ATOM_RE && $w =~ $PANE_RE && $p =~ $PANE_RE ]] || continue
    SESSIONS+="$s"$'\n'
    OWNED+="$s $p"$'\n'
    kind=$(field "$meta" kind)
    [ "$kind" = squad_lead ] || FLEET_WS+="$s $w"$'\n'
  done
  SESSIONS=$(printf '%s' "$SESSIONS" | sort -u)
}

# Orphans of one session, one `<pane> <workspace> <terminal-id>` line each: the panes of a fleet workspace that no record
# names and that Herdr reports with no agent. The shell proof runs later, only on these.
candidates() {  # <session>
  local session=$1 panes pane ws term
  panes=$(jg_backend_herdr_cli "$session" pane list 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e '.result.panes | type == "array"' >/dev/null 2>&1 || return 1
  while IFS=$'\t' read -r pane ws term; do
    [[ $pane =~ $PANE_RE && $ws =~ $PANE_RE && $term =~ $ATOM_RE ]] || continue
    grep -qxF -- "$session $ws" <<< "$FLEET_WS" || continue
    ! grep -qxF -- "$session $pane" <<< "$OWNED" || continue
    [ "$session:$pane" != "$session:${HERDR_PANE_ID:-}" ] || continue
    [ "$(jg_backend_herdr_pane_agent_state "$session" "$pane" </dev/null)" = no-agent ] || continue
    printf '%s %s %s\n' "$pane" "$ws" "$term"
  done < <(printf '%s' "$panes" | jq -r '.result.panes[] | [.pane_id, .workspace_id, .terminal_id] | map(. // "") | @tsv')
}

reap_session() {  # <session>
  local session=$1 now found seen first pane ws term rec out keep=""
  now=$(date +%s)
  found=$(candidates "$session") || return 0   # unreadable: change nothing, keep every clock
  while read -r pane ws term; do
    [ -n "$pane" ] || continue
    jg_backend_herdr_pane_idle_shell_pid "$session" "$pane" >/dev/null 2>&1 </dev/null || continue   # in use: no clock
    rec=$DIR/$session/$term.seen
    keep+="$rec"$'\n'
    first=$(cat "$rec" 2>/dev/null); [[ $first =~ ^[0-9]+$ ]] || first=""
    if [ -z "$first" ]; then
      first=$now
      [ "$DRY" = 1 ] || { mkdir -p "$DIR/$session" && printf '%s\n' "$now" > "$rec"; }
    fi
    seen=$(( now - first ))
    [ "$MODE" = list ] && printf 'orphan %s %s %s %s\n' "$session" "$pane" "$ws" "$seen"
    [ "$seen" -ge "$LIMIT" ] || continue
    if [ "$DRY" = 1 ]; then printf 'would close %s %s (no owner for %ss)\n' "$session" "$pane" "$seen"; continue; fi
    if out=$(jg_backend_herdr_projection_close_pane_focus_preserving "$session" "$pane" no-agent 2>&1 </dev/null); then
      rm -f -- "$rec"; note "closed $session $pane workspace=$ws no-owner-for=${seen}s"
    else
      note "close-refused $session $pane workspace=$ws: $(printf '%s' "$out" | tr '\n' ' ')"
    fi
  done <<< "$found"
  # A clock of this session whose pane is gone, owned, or in use again is not an orphan any more.
  [ "$DRY" = 1 ] || for rec in "$DIR/$session"/*.seen; do
    [ -f "$rec" ] || continue
    grep -qxF -- "$rec" <<< "$keep" || rm -f -- "$rec"
  done
}

read_records
while read -r s; do
  [ -n "$s" ] || continue
  reap_session "$s"
done <<< "$SESSIONS"
exit 0
