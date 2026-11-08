#!/usr/bin/env bash
# trunk-landing watcher check: land a task into the local trunk by itself once its done-done proof passed.
# Usage: trunk-landing.sh check <jg-home>
#        trunk-landing.sh run <jg-home> <task-id> <head>      (what `check` starts in the background)
#
# For each state/<task>.meta in the home with mode=local-trunk (or legacy local-only) whose project is registered local-trunk and has a trunk
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
# Other refusals are rechecked through jg-trunk admission, which caches unchanged failing contexts and
# bounds transient read retries; its per-attempt logs are retained. bin/jg-trunk.sh owns every refusal and names the conflicting paths.
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
export JG_HOME=$FMH JG_STATE_OVERRIDE=$FMH/state JG_CONFIG_OVERRIDE=$FMH/config
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
umask 077
mkdir -p "$MEM" || exit 0
# shellcheck source=bin/jg-wake-lib.sh
. "$FMH/bin/jg-wake-lib.sh"
mval() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

if [ "$1" = run ]; then
  id=$3; head=$4; out=; rc=0; why=
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $head =~ ^[0-9a-f]{40,64}$ ]] || exit 2
  run_lock=$STATE/.trunk-run-$id-$head.lock
  jg_lock_try_acquire "$run_lock" || exit 0
  trap 'jg_lock_release "$run_lock"' EXIT
  printf 'running %s %s\n' "$(date +%s)" "$$" > "$MEM/$id.$head.state"
  out=$(JG_HOME="$FMH" JG_TRUNK_RUN_HELD_BY="$$" JG_TRUNK_EXPECT_HEAD="$head" "$FMH/bin/jg-trunk.sh" land "$id" 2>&1) || rc=$?
  request_log=$(mktemp "$MEM/$id.$head.request-XXXXXX.log") || exit 1
  printf '%s\n' "$out" > "$request_log"
  printf '%s\n' "$out" > "$MEM/$id.$head.log"
  if [ "$rc" -eq 0 ]; then
    out=$(JG_HOME="$FMH" "$FMH/bin/jg-teardown.sh" "$id" 2>&1) && out='cleaned up' || out="cleanup refused, nothing was forced: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    printf 'landed %s\n' "$out" > "$MEM/$id.$head.state"
    jg_lock_acquire_wait "$MEM/.outbox.lock"
    printf 'trunk-landing: landed %s (local-trunk) on the local trunk (not live: that needs the captain'"'"'s word); %s\n' "$id" "$out" >> "$MEM/outbox"
    jg_lock_release "$MEM/.outbox.lock"
    exit 0
  fi
  why=$(printf '%s\n' "$out" | grep -E '^(REFUSED|error|IN_PROGRESS):' | tail -n 1 | cut -c1-300)
  case $rc in
    74|75) printf 'wait %s\n' "${why:-landing in progress or transient read failure; see $request_log}" > "$MEM/$id.$head.state"; exit 0 ;;
  esac
  case $why in
    *'away mode'*|*'linked to a decision'*|*' is red'*|*'still held'*) printf 'wait %s\n' "$why" > "$MEM/$id.$head.state" ;;
    *) printf 'final %s\n' "${why:-landing failed; see $request_log}" > "$MEM/$id.$head.state" ;;
  esac
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
export JG_HOME=$FMH JG_CONFIG_OVERRIDE=$FMH/config
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$FMH/bin/jg-trunk-policy-lib.sh"
if jg_lock_try_acquire "$MEM/.outbox.lock"; then
  if [ -s "$MEM/outbox" ]; then mv -f -- "$MEM/outbox" "$MEM/outbox.$$" && cat "$MEM/outbox.$$" && rm -f -- "$MEM/outbox.$$"; fi
  jg_lock_release "$MEM/.outbox.lock"
fi
# Only a project registered local-trunk is ever touched; no-mistakes, direct-PR and local-only projects keep their own rules.
local_trunk() { [ "$(JG_HOME="$FMH" "$FMH/bin/jg-project-mode.sh" --raw "$(basename "$1")" 2>/dev/null | cut -d' ' -f1)" = local-trunk ] && echo yes || echo no; }
# Once a project's release PR has merged, cut its next trunk version (bin/jg-trunk.sh rollover) and clean the old trunk
# up unforced (retire); looked at every 5 minutes.
for tip in "$STATE"/trunk-tip-*; do
  [ -f "$tip" ] || continue
  pn=${tip##*/trunk-tip-}; proj=$FMH/projects/$pn
  [ -d "$proj" ] && [ -s "$DATA_DIR/trunk-releases.tsv" ] && [ "$(local_trunk "$proj")" = yes ] || continue
  [ ! -e "$MEM/.rollover-$pn" ] || [ -n "$(find "$MEM/.rollover-$pn" -mmin +4 2>/dev/null)" ] || continue
  : > "$MEM/.rollover-$pn"
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" rollover "$proj" 2>/dev/null | sed 's/^/trunk-landing: /'
  # An old trunk kept for unlanded work is looked at again; a changed listing is reported, an unchanged one is not.
  out=$(JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" retire "$proj" 2>/dev/null | sed 's/^/trunk-landing: /')
  if [ "$out" != "$(cat "$MEM/.retire-$pn" 2>/dev/null)" ]; then printf '%s\n' "$out" > "$MEM/.retire-$pn"; [ -z "$out" ] || printf '%s\n' "$out"; fi
done
report() {
  local reason=${3%%; full log:*}
  [ "$(cat "$MEM/$1.reported" 2>/dev/null)" = "$reason" ] || { echo "trunk-landing: $2"; printf '%s\n' "$reason" > "$MEM/$1.reported"; }
}
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  # Compatibility is read-only and applies only to registered local-trunk projects below.
  case $(mval "$meta" mode) in local-trunk|local-only) ;; *) continue ;; esac
  proj=$(mval "$meta" project); [ -d "$proj" ] || continue
  [ -e "$STATE/trunk-tip-$(basename "$proj")" ] || continue
  [ "$(local_trunk "$proj")" = yes ] || continue
  branch=$(mval "$meta" branch); branch=${branch:-fm/$id}
  head=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || continue
  st=$MEM/$id.$head.state; line=$(cat "$st" 2>/dev/null || true)
  case $line in landed*) continue ;; esac
  rcpt=$STATE/$id.run-receipt.json
  [ "$(jq -r '.verdict // ""' "$rcpt" 2>/dev/null)" = PASS ] && [ "$(jq -r '.head // ""' "$rcpt" 2>/dev/null)" = "$head" ] || continue
  case $line in
    running*) read -r _ _ owner_pid <<<"$line"; jg_pid_alive "${owner_pid:-}" && continue ;;
    final*) report "$id.$head" "$id not landed: ${line#final }" "${line#final }" ;;
    wait*) report "$id.$head" "$id waits to land: ${line#wait }" "${line#wait }" ;;
  esac
  printf 'running %s\n' "$(date +%s)" > "$st"
  launch_log=$(mktemp "$MEM/$id.$head.launch-XXXXXX.log") || exit 1
  setsid nohup "$SELF" run "$FMH" "$id" "$head" >"$launch_log" 2>&1 < /dev/null &
  launch_pid=$!
  # The outer watcher stops a completed check's process group. Do not return
  # until the child has detached and published ownership of this attempt.
  for _ in {1..100}; do
    line=$(cat "$st" 2>/dev/null || true)
    read -r phase _ owner_pid <<<"$line"
    [ "$phase" = running ] && [ -z "${owner_pid:-}" ] || break
    kill -0 "$launch_pid" 2>/dev/null || break
    sleep 0.01
  done
done
exit 0
