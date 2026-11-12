#!/usr/bin/env bash
# jg land [--wait] [--bound <secs>]: where this lane's landing stands, read from the lander's own
# records (core/trunk-landing: <home>/data/jg-trunk-landing/<ticket>.<head>.state) and the proof
# check (bin/jg-trunk.sh proof). It starts nothing: the landing check lands a lane by itself once
# its done line and whole proof are there. --wait returns when the lane has landed or been refused,
# or when the bound passes (default 600 s). Exit: 0 landed, 1 refused, 2 usage, 3 not yet.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/wait-lib.sh"
wait=0 bound=600
while [ $# -gt 0 ]; do
  case $1 in
    --wait) wait=1; shift ;;
    --bound) [ $# -ge 2 ] || jg_cli_die "--bound takes whole seconds. Next: jg help"; bound=$(jg_cli_bound_arg "$2") || exit 2; shift 2 ;;
    *) jg_cli_die "unknown argument $1. Next: jg help" ;;
  esac
done
jg_cli_context
mode=$(jg_cli_meta_get mode)
case $mode in local*) ;; *) jg_cli_die "mode ${mode:-unknown} has no landing queue; its delivery is the pull request. Next: jg status" ;; esac
proj=$(jg_cli_meta_get project); branch=$(jg_cli_meta_get branch)
head=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || jg_cli_die "branch $branch is not in $proj. Next: jg status"
mem=$JG_CLI_HOME/data/jg-trunk-landing

done_at() {  # epoch of the done line that is last in a ticket's status file, else nothing
  tail -n1 "$JG_CLI_STATE/$1.status" 2>/dev/null | sed -n 's/^done[^[]*\[at=\([0-9]*\)\].*/\1/p'
}
# ahead_of_me: other ready lanes of this project with no result yet and an earlier done line
ahead_of_me() {
  local mine m id at h n=0 p b
  mine=$(done_at "$JG_CLI_TASK"); [ -n "$mine" ] || { echo 0; return; }
  for m in "$JG_CLI_STATE"/*.meta; do
    [ -e "$m" ] || continue; id=$(basename "$m" .meta); [ "$id" != "$JG_CLI_TASK" ] || continue
    p=$(sed -n 's/^project=//p' "$m" | head -n1); [ "$p" = "$proj" ] || continue
    case $(sed -n 's/^mode=//p' "$m" | head -n1) in local*) ;; *) continue ;; esac
    at=$(done_at "$id"); [ -n "$at" ] && [ "$at" -lt "$mine" ] || continue
    b=$(sed -n 's/^branch=//p' "$m" | head -n1)
    h=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$b^{commit}") || continue
    case $(cat "$mem/$id.$h.state" 2>/dev/null) in landed*) ;; *) n=$((n + 1)) ;; esac
  done
  echo "$n"
}

# landing_state: print `<kind>|<text>` for this head; kind is landed, refused, running, waiting or notready
landing_state() {
  local line gaps n why
  line=$(cat "$mem/$JG_CLI_TASK.$head.state" 2>/dev/null || true)
  case $line in
    landed*) echo "landed|${line#landed }"; return ;;
    final*) echo "refused|${line#final }"; return ;;
    running*) echo "running|landing in progress (${line#running })"; return ;;
    env-wait*|retry*) echo "waiting|${line#* }"; return ;;
  esac
  [ -n "$(done_at "$JG_CLI_TASK")" ] || { echo "notready|no done line yet"; return; }
  if gaps=$("$JG_CLI_TOOLS/bin/jg-trunk.sh" proof "$JG_CLI_TASK" 2>&1); then :; else
    echo "notready|proof inputs missing: $(printf '%s' "$gaps" | tr '\n' ';')"; return
  fi
  n=$(ahead_of_me); why=$(cat "$mem/$JG_CLI_TASK.$head.queue-why" 2>/dev/null || true)
  echo "waiting|queued, $n lane(s) ahead${why:+; it waited: $why}"
}
settled() { case $(landing_state) in landed\|*|refused\|*) return 0 ;; *) return 1 ;; esac; }

[ "$wait" = 0 ] || jg_cli_wait "$bound" settled || true
st=$(landing_state); kind=${st%%|*}; text=${st#*|}
printf 'landing: %s\nhead: %s\nwhy: %s\n' "$kind" "${head:0:12}" "$text"
case $kind in
  landed) echo "Next: stop; the lane is on the trunk"; exit 0 ;;
  refused) echo "Next: fix it in the lane, commit, jg proof, jg done"; exit 1 ;;
  notready) echo "Next: fix what is named, then jg proof and jg done"; exit 3 ;;
  *) [ "$wait" = 1 ] && echo "Next: bound of $bound s passed; jg land --wait again" || echo "Next: jg land --wait"; exit 3 ;;
esac
