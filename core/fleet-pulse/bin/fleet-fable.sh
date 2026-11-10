#!/usr/bin/env bash
# Fable cadence check for the fleet pulse (captain 10 Oct: no Fable until the captain says so; 9 Nov: Juggernaut
# research may). Finds every Claude session log written in the last 20 minutes that ran claude-fable, including pi
# subagents through the Claude bridge that no task record shows, and names each one the model guard would refuse.
# The guard decides: a session whose working folder is a task's worktree (state/*.meta worktree= in any home
# fleet-homes.sh lists), or a quota-failover one-line test's folder for a task (jg-probe-<task-id>.XXXXXX), is
# skipped when `refuse-model.sh allowed <task-id>` passes, so allow-tasks beside the installed guard is the one list.
# A route-level test names no task, so it is named by its session folder like any session no task owns.
# With no guard installed this host has no Fable ban, so nothing is reported.
# Prints one wake line and exits 0 when due (at most once per 15 min); silent exit 1 otherwise.
# Usage: fleet-fable.sh <main-home>
# Overrides: JG_CLAUDE_PROJECTS (session logs, default ~/.claude/projects), JG_CLAUDE_MODEL_GUARD (the installed
# guard), JG_FABLE_NOW and JG_FABLE_WAKE_SECS (the wake mark).
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo 'usage: fleet-fable.sh <main-home>' >&2
  exit 2
fi
main=$(cd "$1" && pwd -P)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
projects=${JG_CLAUDE_PROJECTS:-$HOME/.claude/projects}
guard=${JG_CLAUDE_MODEL_GUARD:-$(bash "$here/../../claude-model-guard/wiring.sh" --where 2>/dev/null || true)}
now=${JG_FABLE_NOW:-$(date +%s)}
wake_limit=${JG_FABLE_WAKE_SECS:-900}
mark=$main/state/.fleet-fable.last
# shellcheck source=/dev/null # sibling feature path, resolved at runtime
. "$here/../../quota-failover/jg-probe-folder-lib.sh"

[ -x "$guard" ] || exit 1
[ -d "$projects" ] || exit 1

# wake <line>: print the line once per wake window, else stay silent.
wake() {
  if [ -f "$mark" ] && [ $((now - $(stat -c %Y "$mark"))) -lt "$wake_limit" ]; then
    exit 1
  fi
  mkdir -p "$main/state"
  touch -d "@$now" "$mark" 2>/dev/null || touch "$mark"
  echo "$1"
  exit 0
}

logs=$(find "$projects" -name '*.jsonl' -mmin -20 2>/dev/null | xargs -r grep -lE '"model":"claude-fable' 2>/dev/null || true)
[ -n "$logs" ] || exit 1

# A guard copy older than the allowed query answers as a hook instead; it must not decide anything.
rc=0
"$guard" allowed '' </dev/null >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || wake "fleet-fable: the installed model guard $guard cannot answer allowed <task-id>; rewire it with core/claude-model-guard/wiring.sh"

# "<worktree>\t<task-id>" for every task record in every known home.
tasks=$(while IFS= read -r home; do
  for meta in "$home"/state/*.meta; do
    [ -f "$meta" ] || continue
    sed -n "s|^worktree=\(.\{1,\}\)|\1\t$(basename "$meta" .meta)|p" "$meta"
  done
done < <("$here/fleet-homes.sh" "$main"))

names=()
while IFS= read -r log; do
  cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$log" | sed 's/^"cwd":"//; s/"$//' || true)
  task=$(awk -F'\t' -v c="$cwd" 'c != "" && (c == $1 || index(c, $1 "/") == 1) { print $2; exit }' <<<"$tasks")
  [ -n "$task" ] || task=$(jg_probe_folder_task "$cwd") || task=
  [ -n "$task" ] && "$guard" allowed "$task" </dev/null && continue
  name=${task:-$(basename "$(dirname "$log")")}
  case " ${names[*]} " in *" $name "*) ;; *) names+=("$name") ;; esac
done <<<"$logs"

[ "${#names[@]}" -gt 0 ] || exit 1
shown="${names[*]:0:3}"
[ "${#names[@]}" -le 3 ] || shown="$shown (+$((${#names[@]} - 3)) more)"
wake "fleet-fable: Fable ran outside the model guard's allow-tasks in: $shown - find the lane or supervision host (config/supervision-host), stop it, steer its lead"
