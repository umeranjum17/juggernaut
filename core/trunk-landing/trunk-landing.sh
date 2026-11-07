#!/usr/bin/env bash
# trunk-landing watcher check: land a task into the local trunk by itself once its done-done proof passed.
# Usage: trunk-landing.sh check <jg-home>
#        trunk-landing.sh run <jg-home> <task-id> <head>      (what `check` starts in the background)
#
# For each state/<task>.meta in the home with mode=local-only whose project is registered local-trunk and has a trunk
# (state/trunk-tip-<project>, made by bin/jg-trunk.sh init), whose ship branch is not on the trunk yet and whose
# state/<task>.run-receipt.json is a PASS for the branch's exact head, `check` starts
# `bin/jg-trunk.sh land <task>` detached (the gate chain is far longer than a check's time limit) and records
# the outcome in <home>/data/jg-trunk-landing/<task>.<head>.state. No human or lead step lands a task, and the
# check never goes live: that stays the captain's word (jg-trunk.sh live). A landed task is then cleaned up with
# bin/jg-teardown.sh, never forced: a refusal is reported and the worktree stays. The watcher runs this check on
# its fast tick, so a worker's done starts the landing within seconds in every home; the outcome line of a landing
# already cleaned up (its record is gone) comes from data/jg-trunk-landing/outbox.
# A sweep prints one line per outcome, once: `landed ... cleaned up`, or `not landed: <reason>`. A refusal that only needs time
# (away mode, a decision still open on linked work, a red trunk) is retried each sweep without repeating the line;
# any other refusal (a conflict, a second commit, a failing gate) stays until the lane rebases and proves a new
# head, because the same head can never pass. bin/jg-trunk.sh owns every refusal and names the conflicting paths.
set -u
case "${1:-}" in
  check) [ "$#" -eq 2 ] || { echo "usage: trunk-landing.sh check <jg-home>" >&2; exit 2; } ;;
  run) [ "$#" -eq 4 ] || { echo "usage: trunk-landing.sh run <jg-home> <task-id> <head>" >&2; exit 2; } ;;
  *) echo "usage: trunk-landing.sh check <jg-home> | run <jg-home> <task-id> <head>" >&2; exit 2 ;;
esac
[ -d "$2/state" ] || { echo "trunk-landing: $2 has no state directory" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
DATA_DIR=$FMH/data
MEM=$FMH/data/jg-trunk-landing
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
umask 077
mkdir -p "$MEM" || exit 0
mval() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

if [ "$1" = run ]; then
  id=$3; head=$4; out=; rc=0; why=
  printf 'running %s\n' "$(date +%s)" > "$MEM/$id.$head.state"
  out=$(JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" land "$id" 2>&1) || rc=$?
  printf '%s\n' "$out" > "$MEM/$id.$head.log"
  if [ "$rc" -eq 0 ]; then
    printf 'landed\n' > "$MEM/$id.$head.state"
    out=$(JG_HOME="$FMH" "$FMH/bin/jg-teardown.sh" "$id" 2>&1) && out='cleaned up' || out="cleanup refused, nothing was forced: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    printf 'trunk-landing: landed %s on the local trunk (not live: that needs the captain'"'"'s word); %s\n' "$id" "$out" >> "$MEM/outbox"
    exit 0
  fi
  why=$(printf '%s\n' "$out" | grep -E '^(REFUSED|error):' | tail -n 1 | cut -c1-300)
  case $why in
    *'away mode'*|*'linked to a decision'*|*' is red'*|*'still held'*) printf 'wait %s\n' "$why" > "$MEM/$id.$head.state" ;;
    *) printf 'final %s\n' "${why:-landing failed; see $MEM/$id.$head.log}" > "$MEM/$id.$head.state" ;;
  esac
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
export JG_HOME=$FMH JG_CONFIG_OVERRIDE=$FMH/config
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$FMH/bin/jg-trunk-policy-lib.sh"
if [ -s "$MEM/outbox" ]; then mv -f -- "$MEM/outbox" "$MEM/outbox.$$" && cat "$MEM/outbox.$$" && rm -f -- "$MEM/outbox.$$"; fi
# Only a project registered local-trunk is ever touched; no-mistakes, direct-PR and local-only projects keep their own rules.
local_trunk() { [ "$(JG_HOME="$FMH" "$FMH/bin/jg-project-mode.sh" --raw "$(basename "$1")" 2>/dev/null | cut -d' ' -f1)" = local-trunk ] && echo yes || echo no; }
# Once a project's release PR has merged, cut its next trunk version (bin/jg-trunk.sh rollover); looked at every 5 minutes.
for tip in "$STATE"/trunk-tip-*; do
  [ -f "$tip" ] || continue
  pn=${tip##*/trunk-tip-}; proj=$FMH/projects/$pn
  [ -d "$proj" ] && [ -s "$DATA_DIR/trunk-releases.tsv" ] && [ "$(local_trunk "$proj")" = yes ] || continue
  [ ! -e "$MEM/.rollover-$pn" ] || [ -n "$(find "$MEM/.rollover-$pn" -mmin +4 2>/dev/null)" ] || continue
  : > "$MEM/.rollover-$pn"
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" rollover "$proj" 2>/dev/null | sed 's/^/trunk-landing: /'
done
report() { [ "$(cat "$MEM/$1.reported" 2>/dev/null)" = "$3" ] || { echo "trunk-landing: $2"; printf '%s\n' "$3" > "$MEM/$1.reported"; }; }
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  [ "$(mval "$meta" mode)" = local-only ] || continue
  proj=$(mval "$meta" project); [ -d "$proj" ] || continue
  [ -e "$STATE/trunk-tip-$(basename "$proj")" ] || continue
  [ "$(local_trunk "$proj")" = yes ] || continue
  branch=$(mval "$meta" branch); branch=${branch:-fm/$id}
  head=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || continue
  st=$MEM/$id.$head.state; line=$(cat "$st" 2>/dev/null || true)
  [ "$line" != landed ] || continue
  git -C "$proj" merge-base --is-ancestor "$head" "refs/heads/$(jg_trunk_branch "$(basename "$proj")" "$STATE")" 2>/dev/null && continue
  rcpt=$STATE/$id.run-receipt.json
  [ "$(jq -r '.verdict // ""' "$rcpt" 2>/dev/null)" = PASS ] && [ "$(jq -r '.head // ""' "$rcpt" 2>/dev/null)" = "$head" ] || continue
  case $line in
    running*) [ $(( $(date +%s) - $(printf '%s' "${line#running }" | tr -dc 0-9 | grep . || echo 0) )) -gt 21600 ] || continue ;;
    final*) report "$id.$head" "$id not landed: ${line#final }" "${line#final }"; continue ;;
    wait*) report "$id.$head" "$id waits to land: ${line#wait }" "${line#wait }" ;;
  esac
  printf 'running %s\n' "$(date +%s)" > "$st"
  setsid nohup "$SELF" run "$FMH" "$id" "$head" >/dev/null 2>&1 < /dev/null &
done
exit 0
