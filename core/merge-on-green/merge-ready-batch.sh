#!/usr/bin/env bash
# merge-ready batch: one lead turn per ten-minute batch of merge-ready outcomes, not one per outcome.
# Usage: merge-ready-batch.sh check <jg-home>
#
# A merge-ready outcome is a ship whose newest status line is its PR-ready `done`/`ready` line naming a PR
# (the task record's pr=, else the URL on the line), not yet merged. The first unreported outcome opens a window;
# when the window is JG_MERGE_READY_SECONDS old (default 600) the check prints ONE line listing every
# outstanding outcome, so the lead acts on all of them in one turn. An outcome that arrives while the window
# is open rides this batch's end; nothing is dropped, and none waits past the window.
# Each listed outcome carries its own authority verdict, and the batch merges nothing itself:
#   mergeable        authority (yolo=on or merge=approved, never merge=manual), a PASS run receipt for this
#                    head, and no blocker from bin/jg-pr-state.sh --all. The merge itself stays with
#                    bin/jg-pr-merge.sh, whose live green check and head pin are unchanged.
#   needs the captain's word   no standing authority, or merge=manual.
#   NOT mergeable: <reason>    a red or pending check, a draft, a conflict, a missing or stale receipt, an
#                    unreadable state. An outcome that turns unmergeable is named, never dropped.
#   no longer waiting: <state> merged or closed.
# A listed outcome repeats only when its head or verdict changes; a mergeable one still unmerged is re-read every batch. Nothing is printed when nothing happened.
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: merge-ready-batch.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
DATA=$FMH/data/jg-merge-on-green/merge-ready-batch
WINDOW=${JG_MERGE_READY_SECONDS:-600}
case "$WINDOW" in ''|*[!0-9]*) WINDOW=600 ;; esac
PR_STATE=${JG_MRB_PR_STATE:-$FMH/bin/jg-pr-state.sh}
BUDGET=$(( ${JG_CHECK_TIMEOUT:-30} / 3 )); [ "$BUDGET" -ge 5 ] || BUDGET=5
now=${JG_MERGE_READY_NOW:-$(date +%s)}
umask 077

meta_get() { # <meta-file> <key> -> last value
  local line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1"
  printf '%s' "$value"
}

# outcomes: one "task<TAB>pr<TAB>head" per merge-ready outcome.
outcomes() {
  local m task kind pr head last
  for m in "$STATE"/*.meta; do
    [ -f "$m" ] || continue
    task=$(basename "$m" .meta)
    case "$task" in [A-Za-z0-9]*) ;; *) continue ;; esac
    kind=$(meta_get "$m" kind); [ -z "$kind" ] || [ "$kind" = ship ] || continue
    last=$(awk 'NF { l = $0 } END { print l }' "$STATE/$task.status" 2>/dev/null)
    # The lead records pr= and pr_head= when it checks the PR; until then the done line is the only name of it.
    pr=$(meta_get "$m" pr); head=$(meta_get "$m" pr_head)
    [ -n "$pr" ] || pr=$(printf '%s' "$last" | grep -Eo 'https://[^ ]+/(pull|merge_requests)/[0-9]+' | head -1)
    [ -n "$pr" ] || continue
    [ -n "$head" ] || head=unrecorded
    case "$last" in
      "done "*"merged "*|"merged"*) continue ;;
      "done"*|"ready"*) case "$last" in *"$pr"*) printf '%s\t%s\t%s\n' "$task" "$pr" "$head" ;; esac ;;
    esac
  done
}

# verdict <task> <pr> <head>: the authority check. Prints the verdict text.
verdict() {
  local m=$STATE/$1.meta yolo merge rcpt blockers
  yolo=$(meta_get "$m" yolo); merge=$(meta_get "$m" merge)
  if [ "$merge" = manual ] || { [ "$yolo" != on ] && [ "$merge" != approved ]; }; then
    echo "needs the captain's word"; return
  fi
  blockers=$(JG_HOME="$FMH" timeout "$BUDGET" "$PR_STATE" --all "$2" 2>/dev/null) || { echo "NOT mergeable: PR state unreadable, retrying next batch"; return; }
  case "$blockers" in
    *[Mm]erged*|*[Cc]losed*) echo "no longer waiting: $(printf '%s' "$blockers" | head -1)"; return ;;
  esac
  if [ -n "$blockers" ]; then echo "NOT mergeable: $(printf '%s' "$blockers" | head -1 | cut -c1-120)"; return; fi
  rcpt=$STATE/$1.run-receipt.json
  if [ ! -f "$rcpt" ] || ! command -v jq >/dev/null 2>&1; then echo "NOT mergeable: no run receipt"; return; fi
  if [ "$(jq -r '.verdict // ""' "$rcpt" 2>/dev/null)" != PASS ] || [ "$(jq -r '.head // ""' "$rcpt" 2>/dev/null)" != "$3" ]; then
    echo "NOT mergeable: no PASS run receipt for this head"; return
  fi
  echo "mergeable"
}

list=$(outcomes)
[ -n "$list" ] || { rm -f "$DATA/window" 2>/dev/null || :; exit 0; }

# An outcome is unreported until its head+verdict was listed. Only a new head opens the window (cheap, no forge call).
fresh=0
while IFS=$'\t' read -r task pr head; do
  [ "$(cat "$DATA/$task.head" 2>/dev/null)" = "$head" ] || fresh=1
  # A mergeable outcome still unmerged is read again each batch, so one that turns red is named, not dropped.
  case "$(cat "$DATA/$task.verdict" 2>/dev/null)" in *" mergeable") fresh=1 ;; esac
done <<< "$list"
if [ ! -f "$DATA/window" ]; then
  [ "$fresh" -eq 1 ] || exit 0
  mkdir -p "$DATA" 2>/dev/null && printf '%s\n' "$now" > "$DATA/window" 2>/dev/null || exit 0
  exit 0
fi
opened=$(cat "$DATA/window" 2>/dev/null)
case "$opened" in ''|*[!0-9]*) opened=$now ;; esac
[ $(( now - opened )) -ge "$WINDOW" ] || exit 0

lines=''; n=0
while IFS=$'\t' read -r task pr head; do
  v=$(verdict "$task" "$pr" "$head")
  [ "$(cat "$DATA/$task.verdict" 2>/dev/null)" = "$head $v" ] && continue
  printf '%s\n' "$head $v" > "$DATA/$task.verdict" 2>/dev/null || :
  printf '%s\n' "$head" > "$DATA/$task.head" 2>/dev/null || :
  lines="$lines $task $pr: $v;"
  n=$((n + 1))
done <<< "$list"
rm -f "$DATA/window" 2>/dev/null || :
[ "$n" -gt 0 ] || exit 0
echo "merge-on-green: merge-ready batch, $n outcome(s):$lines lead: merge each mergeable one through bin/jg-pr-merge.sh; the rest wait as named"
