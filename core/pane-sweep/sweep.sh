#!/usr/bin/env bash
# pane-sweep: close the bare shells in a home's own Herdr workspace that no record names.
# Usage: sweep.sh check|run <jg-home>
# A pane is closed only when ALL hold at the moment of the close:
#   - it sits in this home's own workspace (never another workspace, home or session);
#   - no state/*.meta window= names it, and it is not the pane this sweep runs in;
#   - it holds one lone idle shell and nothing else (the adapter's idle-shell proof, so an agent never qualifies);
#   - it has been seen in that state on every sweep for at least JG_PANE_SWEEP_IDLE_S seconds (default 1800).
# The first sighting is written to data/pane-sweep/seen.tsv; a pane that fails any test is forgotten at once.
# The close is jg_backend_kill through bin/jg-backend.sh, and is confirmed by a follow-up read of the pane.
# At most JG_PANE_SWEEP_MAX panes are closed per sweep (default 3). Output: one line per close or refusal.
# The spawn map (data/copy-tasks.tsv, slice 29) names the task that made the pane, printed in the close line.
set -u
MODE=${1:-}; H=${2:-}
case "$MODE" in check|run) ;; *) echo "usage: sweep.sh check|run <jg-home>" >&2; exit 2 ;; esac
[ -n "$H" ] && [ -d "$H/state" ] && [ -r "$H/bin/jg-backend.sh" ] || { echo "usage: sweep.sh check|run <jg-home>" >&2; exit 2; }
H=$(cd "$H" && pwd -P)
STATE=$H/state; DATA=$H/data/pane-sweep; SEEN=$DATA/seen.tsv
IDLE=${JG_PANE_SWEEP_IDLE_S:-1800}; MAX=${JG_PANE_SWEEP_MAX:-3}
case "$IDLE$MAX" in *[!0-9]*) echo "pane-sweep: refused: JG_PANE_SWEEP_IDLE_S and JG_PANE_SWEEP_MAX must be whole numbers" >&2; exit 2 ;; esac

export JG_HOME=$H
# shellcheck source=/dev/null
. "$H/bin/jg-backend.sh"
[ "$(jg_backend_name 2>/dev/null)" = herdr ] || exit 0
command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
jg_backend_source herdr || exit 0
SESSION=$(jg_backend_herdr_session)
# A stopped session is read as nothing to sweep, never started by a sweep.
[ "$(jg_backend_herdr_server_running_state "$SESSION")" = running ] || exit 0
WS=$(jg_backend_herdr_workspace_find "$SESSION") || exit 0
[ -n "$WS" ] || exit 0
PANES=$(jg_backend_herdr_cli "$SESSION" pane list --workspace "$WS" 2>/dev/null | jq -r '.result.panes[]?.pane_id // empty' 2>/dev/null) || exit 0

recorded() {  # <session:pane>: a meta names it
  grep -qxF "window=$1" "$STATE"/*.meta 2>/dev/null
}
producer() {  # <session:pane>: the task the spawn map says started it, or none
  awk -F'\t' -v p="$1" '$2 == p { t = $3 } END { print (t == "" ? "no spawn-map row" : "spawned for " t) }' "$H/data/copy-tasks.tsv" 2>/dev/null
}

mkdir -p "$DATA"
now=$(date +%s); next=$(mktemp "$DATA/.seen.XXXXXX"); closed=0
trap 'rm -f -- "$next"' EXIT
for pane in $PANES; do
  target=$SESSION:$pane
  [ "$target" != "$SESSION:${HERDR_PANE_ID:-}" ] || continue
  recorded "$target" && continue
  jg_backend_herdr_pane_idle_shell_pid "$SESSION" "$pane" >/dev/null 2>&1 || continue
  first=$(awk -F'\t' -v p="$pane" '$1 == p { print $2; exit }' "$SEEN" 2>/dev/null)
  case "$first" in ''|*[!0-9]*) first=$now ;; esac
  if [ $((now - first)) -lt "$IDLE" ] || [ "$closed" -ge "$MAX" ]; then
    printf '%s\t%s\n' "$pane" "$first" >> "$next"; continue
  fi
  # Re-read both proofs right before the close: a record or an agent that appeared since must win.
  recorded "$target" && continue
  jg_backend_herdr_pane_idle_shell_pid "$SESSION" "$pane" >/dev/null 2>&1 || continue
  jg_backend_kill herdr "$target" >/dev/null 2>&1
  if [ "$(jg_backend_herdr_pane_presence_state "$SESSION" "$pane")" = dead ]; then
    closed=$((closed + 1))
    echo "pane-sweep: closed $target, a bare shell idle $(((now - first) / 60)) minutes that no record names ($(producer "$target"))"
  else
    printf '%s\t%s\n' "$pane" "$first" >> "$next"
    echo "pane-sweep: could not close $target; it stays and is tried again next sweep"
  fi
done
mv -f -- "$next" "$SEEN"
