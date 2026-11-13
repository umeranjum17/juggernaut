#!/usr/bin/env bash
# task.sh - observer of the task machine (core/machines/tables/task.tsv): one state word per task, from records that already exist.
#
# Usage:
#   task.sh <id> [--forge]          print the state word
#   task.sh --plain <id> [--forge]  print "<id>: <the state's captain sentence>"
#   task.sh sweep [--forge]         print "<state><TAB><id>" for each task whose records disagree, one line each
#   task.sh columns                 filter for jg-fleet-view.sh: add a State column (the captain sentence) to the Under Way table,
#                                   and pass the text through unchanged unless config/machine-view exists
#
# A trunk lane (meta mode local, or its old words) whose status log says done reads from the trunk flow, never as done:
#   ready-to-land (waits in the landing queue), landed (on the trunk, cleanup runs), cleaned, or rework (the lander refused this
#   head, or the suite found a red the commit caused and it was reverted). Records read: data/jg-trunk-landing/<task>.<head>.state
#   and data/trunk-landings.tsv. A moved trunk changes nothing: the lander rebases, the worker waits.
# Any other task is the word jg-crew-state.sh prints, except one whose backlog row is open (queued or in_flight) while:
#   - the work is merged or landed (a landed record in data/jg-trunk-landing, or with --forge a merged PR):
#     finished-elsewhere when the worker's own status log says done, else stale;
#   - with --forge, its PR was closed without a merge: abandoned, the owner decides.
# The forge is read only with --forge or JG_MACHINE_FORGE=1 (github, 5 seconds per PR; the env form is for jg-machine, which passes no flag).
# Without it no PR state is read.
# The command only reads: it never writes a record, runs no move, and takes its ids from state/*.meta.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}; DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
FORGE=0; [ "${JG_MACHINE_FORGE:-}" = 1 ] && FORGE=1; args=(); for a in "$@"; do if [ "$a" = --forge ]; then FORGE=1; else args+=("$a"); fi; done
set -- "${args[@]+"${args[@]}"}"
# shellcheck source=bin/jg-classify-lib.sh
. "$root/bin/jg-classify-lib.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$root/bin/jg-pr-lib.sh"
# shellcheck source=bin/jg-timeout-lib.sh
. "$root/bin/jg-timeout-lib.sh"

mval() { sed -n "s/^$2=//p" "$STATE/$1.meta" 2>/dev/null | tail -n 1; }
done_line() { [ "$(status_line_verb "$(status_current_line "$STATE/$1.status" "$(mval "$1" kind)" 2>/dev/null)")" = "done" ]; }
# shellcheck source=bin/jg-delivery-style.sh
. "$root/bin/jg-delivery-style.sh"
trunk_lane() { jg_delivery_style_is "$(mval "$1" mode)" local; }
# Where a finished local-trunk lane stands: cleaned, landed, rework or ready; nothing when no trunk record names it.
landing() {  # <id>
  local id=$1 f w rest head='' final=0 tsv="$DATA/trunk-landings.tsv"
  grep -q "^revert-$id"$'\t' "$tsv" 2>/dev/null && { echo rework; return; }
  w=$(mval "$id" worktree); [ -z "$w" ] || head=$(git -C "$w" rev-parse HEAD 2>/dev/null)
  for f in "$DATA/jg-trunk-landing/$id".*.state; do  # a one-head record; an admission record names two hashes
    [ -f "$f" ] || continue
    [[ ${f##*/} =~ \.[0-9a-f]{40,64}\.[0-9a-f]{40,64}\.state$ ]] && continue
    read -r w rest < "$f"
    case $w in landed) [ "$rest" = "cleaned up" ] && echo cleaned || echo landed; return ;; final) [ -z "$head" ] && final=1; [[ $f == *".$head.state" ]] && final=1 ;; esac
  done
  [ "$final" = 0 ] || { echo rework; return; }
  if [ ! -f "$STATE/$id.meta" ]; then awk -F'\t' -v i="$id" '$1 == i {f = 1} END {exit !f}' "$tsv" 2>/dev/null && echo cleaned
  elif trunk_lane "$id" && done_line "$id"; then echo ready; fi
}
# The state's captain sentence from the table; "#N" is the lane's place among the finished lanes still waiting to land.
sentence() {  # <state> <id>
  local t n=1 f i; t=$(awk -F'\t' -v s="$1" '$1=="state" && $2==s {print $4}' "$here/../tables/task.tsv")
  if [[ $t == *'#N'* ]]; then
    while read -r f; do i=$(basename "$f" .status); [ "$i" != "$2" ] || break
      [ "$(landing "$i")" != ready ] || n=$((n + 1)); done < <(ls -tr "$STATE"/*.status 2>/dev/null)
    t=${t//#N/#$n}
  fi
  printf '%s\n' "$t"
}
state_of() {  # <id> [crew word already known]
  local id=$1 word=${2:-} row url rec merged=0 closed=0 l
  crew() { [ -z "${SWEEP:-}" ] || { echo healthy; return; }; [ -n "$word" ] || word=$("$JG_HOME/bin/jg-crew-state.sh" "$id" 2>/dev/null | sed -n 's/^state: \([a-z]*\).*/\1/p'); echo "${word:-unknown}"; }
  if [ ! -f "$STATE/$id.meta" ] || trunk_lane "$id"; then
    l=$(landing "$id")
    case $l in cleaned|landed|rework) echo "$l"; return ;; ready) echo ready-to-land; return ;; esac
  else grep -qs '^landed' "$DATA/jg-trunk-landing/$id".*.state && merged=1; fi
  url=$(sed -n 's/^pr=//p' "$STATE/$id.meta" 2>/dev/null | tail -1)
  if [ "$FORGE" = 1 ] && [ "$merged" = 0 ] && jg_pr_url_parse "$url" && [ "$JG_PR_PROVIDER" = github ]; then
    # shellcheck disable=SC2016  # the inner script expands after bash -c receives its arguments
    rec=$(jg_run_timed 5 bash -c '. "$1"; jg_pr_github_read_record "$2" "$3" "$4" && printf "%s %s" "$JG_PR_RECORD_STATE" "$JG_PR_RECORD_MERGED"' \
      _ "$root/bin/jg-pr-lib.sh" "$JG_PR_OWNER" "$JG_PR_REPO" "$JG_PR_NUMBER" 2>/dev/null)
    case $rec in *\ true) merged=1 ;; [Cc][Ll][Oo][Ss][Ee][Dd]\ false) closed=1 ;; esac
  fi
  # The backlog row is read (show, about half a second) only for a task with merge or landing evidence.
  [ "$merged$closed" != 00 ] || { crew; return; }
  row=$("$JG_HOME/bin/jg-backlog.sh" show "$id" 2>/dev/null | sed -n 's/^  state: //p')
  case $row in queued|in_flight) ;; *) crew; return ;; esac
  if [ "$merged" = 1 ]; then
    if done_line "$id"; then echo finished-elsewhere; else echo stale; fi
  else echo abandoned; fi
}

case ${1:-} in
  sweep)
    SWEEP=1  # only the disagreeing states are listed, so the crew-state reader is not run
    for f in "$STATE"/*.meta; do
      [ -e "$f" ] || continue
      id=$(basename "$f" .meta); s=$(state_of "$id")
      case $s in stale|abandoned|finished-elsewhere) printf '%s\t%s\n' "$s" "$id" ;; esac
    done | sort ;;
  --plain)
    [ -n "${2:-}" ] || { echo "usage: task.sh --plain <id> [--forge]" >&2; exit 2; }
    s=$(state_of "$2")
    printf '%s: %s\n' "$2" "$(sentence "$s" "$2")" ;;
  columns)
    [ -e "$JG_HOME/config/machine-view" ] || exec cat
    section=
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in '## '*) section=$line ;; esac
      if [ "$section" = '## Under Way' ]; then
        case $line in
          '| ID |'*) line="$line State |" ;;
          '| --- |'*) line="$line --- |" ;;
          '| '*) id=${line#| }; id=${id%% *}; cur=${line#"| $id | "}
            line="$line $(sentence "$(state_of "$id" "${cur%% *}")" "$id") |" ;;
        esac
      fi
      printf '%s\n' "$line"
    done ;;
  ""|-*) echo "usage: task.sh <id> | --plain <id> | sweep | columns  [--forge]" >&2; exit 2 ;;
  *) state_of "$1" ;;
esac
