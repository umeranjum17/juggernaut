#!/usr/bin/env bash
# backlog-shipped-reconcile watcher check: move a backlog item out of in flight once its PR shipped. No model turn.
# Usage: backlog-shipped-reconcile.sh check <jg-home>
#
# A ship whose PR merged leaves its row In flight when teardown never ran (the worker was killed, the pane
# died, nobody tore the task down), so the board showed 49 items in progress while few ran. For every task
# record <home>/state/<id>.meta that names a PR (pr=), this closes the backlog row with `done --pr` through
# the home's backlog provider (tasks-axi, or the Beads store) when ALL of these hold:
#   - shipped evidence: the home's merge poll recorded the PR as merged (state/<id>.pr-poll-merge-notified
#     naming that PR), or the PR number is listed as prs= on a line of <home>/data/releases (it shipped), and
#   - the row reads exactly "in flight, not held, not blocked" (a held row is the captain's to move, and a
#     queued or already closed row needs nothing), and
#   - no live worker: bin/jg-crew-state.sh reports done or failed, or reports that the worker's endpoint is
#     gone (no endpoint, or no worktree left). Working, parked, paused, blocked and every unreadable state count as live and are left alone.
# It never touches a squad_lead record, a task with a pending close (state/<id>.backlog-close), a home on the
# manual backlog backend, or the worker's own record: teardown still owns removing the meta, worktree and
# branch, and its paired `done` on the already closed row only backfills links. A rerun converges, since a
# closed row no longer reads In flight. One info line is printed per row moved and nothing otherwise.
# A forge or backlog failure is silent and retried next sweep; this check reads no forge at all.
# merge-on-green.sh runs this after its own work and hands over its remaining time in JG_SHIPPED_RECONCILE_LIMIT.
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: backlog-shipped-reconcile.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state; DATA=$FMH/data; CONFIG=$FMH/config; BIN=$FMH/bin
LIMIT=${JG_SHIPPED_RECONCILE_LIMIT:-$(( $(date +%s) + ${JG_CHECK_TIMEOUT:-30} * 4 / 5 ))}
# The home's own libraries own the backlog transition; a home without them has nothing this can do.
[ -r "$BIN/jg-tasks-axi-lib.sh" ] && [ -r "$BIN/jg-backlog-transition-lib.sh" ] && [ -x "$BIN/jg-crew-state.sh" ] || exit 0
export JG_HOME=$FMH
# shellcheck source=bin/jg-tasks-axi-lib.sh disable=SC1091
. "$BIN/jg-tasks-axi-lib.sh"
# shellcheck source=bin/jg-backlog-transition-lib.sh disable=SC1091
. "$BIN/jg-backlog-transition-lib.sh"
jg_backlog_transition_applies "$CONFIG" "$DATA" ship || exit 0

meta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; } # <meta> <key>

# The PR numbers any release record carries, one per line.
released=''
[ ! -r "$DATA/releases" ] || released=$(awk '/^[[:space:]]*#/ { next } { for (i = 2; i <= NF; i++) if ($i ~ /^prs=/) { v = $i; sub(/^prs=/, "", v); gsub(/#/, "", v); gsub(/,/, " ", v); print v } }' "$DATA/releases" | tr ' ' '\n')

# shipped <id> <pr-url>: prints why the PR counts as shipped, nonzero when it does not.
shipped() {
  local id=$1 pr=$2 marker=$STATE/$1.pr-poll-merge-notified host repo num
  if [ -f "$marker" ] && [ "$(sed -n 1p "$marker")" = jg-pr-poll-merge-notified-v1 ]; then
    host=$(sed -n 3p "$marker"); repo=$(sed -n 4p "$marker"); num=$(sed -n 5p "$marker")
    [ "$pr" = "https://$host/$repo/pull/$num" ] && { echo merged; return 0; }
  fi
  case $pr in */pull/[0-9]*) num=${pr##*/pull/} ;; *) return 1 ;; esac
  case $num in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$released" | grep -qx -- "$num" && { echo released; return 0; }
  return 1
}

# worker_gone <id>: true when the worker is finished or its endpoint is gone; false for anything that may be live.
worker_gone() {
  local line state source detail
  line=$(JG_CREW_STATE_NO_FORGE=1 timeout 20 "$BIN/jg-crew-state.sh" "$1" 2>/dev/null | sed -n 1p) || return 1
  state=${line#state: }; state=${state%% *}
  source=${line#*source: }; source=${source%% *}
  detail=${line#* · source: * · }
  case "$state:$source" in
    done:*|failed:*) return 0 ;;
    unknown:none) case $detail in 'backend target gone'*|'worktree gone'*) return 0 ;; esac ;;
  esac
  return 1
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  [ "$(date +%s)" -lt "$LIMIT" ] || break
  id=${meta##*/}; id=${id%.meta}
  [ "$(meta_get "$meta" kind)" != squad_lead ] || continue
  pr=$(meta_get "$meta" pr); [ -n "$pr" ] || continue
  [ ! -e "$STATE/$id.backlog-close" ] || continue
  why=$(shipped "$id" "$pr") || continue
  jg_backlog_row_probe "$DATA" "$id" && [ "$JG_BACKLOG_ROW_STATE" = "in_flight no no" ] || continue
  worker_gone "$id" || continue
  jg_backlog_done "$DATA" "$id" --pr "$pr" >/dev/null 2>&1 || continue
  echo "backlog-shipped-reconcile: $id moved out of in flight: its PR $pr is $why and no worker is running it"
done
exit 0
