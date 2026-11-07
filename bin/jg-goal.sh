#!/usr/bin/env bash
# jg-goal.sh - declare, show and cancel a Goal: an end state the system works toward until it is live.
#
# Usage: jg-goal.sh declare --ask <text> --repo <repo> [--released <how>] [--where <home or service>]
#                           [--attempts <n>] [--fix-steps <n>] [--priority <0-4>] -- <proof argv...>
#        jg-goal.sh show [<goal-id>]
#        jg-goal.sh cancel <goal-id> --reason <text>
#        jg-goal.sh rows
#
# A Goal is a Beads epic labelled `goal` in a small Goal-only store of its own, reached only through
# bin/jg-beads.sh. The store folder is the absolute BEADS_DIR in `config/goal-beads-dir` (or GOAL_BEADS_DIR),
# never derived, because a store inside a git clone is refused. The pinned bd and dolt must be in place:
# when the wrapper refuses, its refusal is printed and nothing falls back to another bd.
#
# declare makes the epic and its five steps, ship, merged, released, running and proven, each blocked by
# the one before. The epic's metadata.goal holds the ask, the finish line (finish.repo, finish.released,
# finish.where and finish.proof, the argv of a read-only command), limits.attempts (default 3) and
# limits.fix_steps (default 5), and a hash of the finish line. The finish line cannot shrink: a changed
# hash is a stop, never a pass. The finish line is also written to data/goals/<id>/finish.json, with the
# proof script copied beside it when the proof names a file.
# declare runs the proof once and refuses a Goal whose proof is missing, already exits 0 (it proves
# nothing), cannot run (exit 126 or 127), or does not end within 30 seconds.
# show prints one Goal's ask, state, steps and open stops, or one line per open Goal.
# rows prints every Goal-labelled row as one JSON list, for core/goal-loop's check (one read, no write).
# cancel closes the Goal's open rows and the epic on the owner's word. It tears nothing down and sends
# no message, so unlanded work stays under the normal cleanup rules.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
BEADS="${JG_GOAL_BEADS_BIN:-$SCRIPT_DIR/jg-beads.sh}"
STEPS='ship merged released running proven'

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { printf 'jg-goal: %s\n' "$*" >&2; exit 2; }

store() {
  local dir=${GOAL_BEADS_DIR:-}
  [ -n "$dir" ] || dir=$(tr -d '[:space:]' < "$CONFIG/goal-beads-dir" 2>/dev/null)
  [ -n "$dir" ] || die "no Goal store: put an absolute BEADS_DIR in $CONFIG/goal-beads-dir"
  printf '%s\n' "$dir"
}

goalstore() { BEADS_DIR=$BEADS_STORE "$BEADS" "$@"; }

# The wrapper's own refusal, such as a missing pinned tool, is the message: the store has no other way in.
need_store() {
  BEADS_STORE=$(store) || exit $?
  local out
  out=$(BEADS_DIR=$BEADS_STORE "$BEADS" check 2>&1) || { printf '%s\n' "$out" >&2; die "the Goal store is not ready"; }
}

sha_of() { { sha256sum || shasum -a 256; } | cut -d' ' -f1; }

# The proof must fail now, run, and end.
proof_check() {  # <argv...>
  local code
  [ "$#" -gt 0 ] || die "declare needs a proof command after --"
  (cd "$JG_HOME" && timeout 30 "$@" >/dev/null 2>&1 < /dev/null)
  code=$?
  case "$code" in
    0) die "the proof already exits 0, so it proves nothing: write a proof that fails until the Goal is live" ;;
    126|127) die "the proof cannot run (exit $code): $1" ;;
    124) die "the proof did not end within 30 seconds: $1" ;;
  esac
}

declare_goal() {
  local ask='' repo='' released=tag where='this home' attempts=3 fix_steps=5 priority=2 proof=() id step prev n meta finish hash dir
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ask) ask=${2-}; shift 2 || die "--ask needs a value" ;;
      --repo) repo=${2-}; shift 2 || die "--repo needs a value" ;;
      --released) released=${2-}; shift 2 || die "--released needs a value" ;;
      --where) where=${2-}; shift 2 || die "--where needs a value" ;;
      --attempts) attempts=${2-}; shift 2 || die "--attempts needs a value" ;;
      --fix-steps) fix_steps=${2-}; shift 2 || die "--fix-steps needs a value" ;;
      --priority) priority=${2-}; shift 2 || die "--priority needs a value" ;;
      --) shift; proof=("$@"); break ;;
      *) die "declare: unknown argument $1" ;;
    esac
  done
  [ -n "$ask" ] || die "declare needs --ask"
  [ -n "$repo" ] || die "declare needs --repo"
  for n in "$attempts" "$fix_steps"; do case "$n" in ''|*[!0-9]*|0) die "limits must be whole numbers above 0" ;; esac; done
  case "$priority" in [0-4]) ;; *) die "--priority is 0 to 4" ;; esac
  proof_check "${proof[@]+"${proof[@]}"}"
  need_store
  finish=$(printf '%s\0' "${proof[@]}" | jq -Rs --arg repo "$repo" --arg released "$released" --arg where "$where" -Sc \
    '{repo:$repo, released:$released, where:$where, proof:(split("\u0000")[:-1])}')
  hash=$(printf '%s' "$finish" | sha_of)
  meta=$(jq -nc --arg ask "$ask" --argjson finish "$finish" --arg hash "$hash" --argjson a "$attempts" --argjson f "$fix_steps" \
    '{goal:{ask:$ask, finish:$finish, finish_hash:$hash, limits:{attempts:$a, fix_steps:$f}}}')
  id=$(goalstore create "Goal: $ask" -t epic --labels goal --priority "$priority" --metadata "$meta" --silent 2>/dev/null) \
    || die "the Goal store did not take the Goal"
  prev=
  for step in $STEPS; do
    if n=$(goalstore create "$step" -t task --parent "$id" --priority "$priority" --metadata "{\"kind\":\"$step\"}" --silent 2>/dev/null) \
      && { [ -z "$prev" ] || goalstore dep add "$n" "$prev" >/dev/null 2>&1; }; then prev=$n
    else goalstore close "$id" --force --reason "declare failed" >/dev/null 2>&1; die "the Goal store did not take the step $step"; fi
  done
  dir=$DATA/goals/$id
  mkdir -p "$dir" || die "cannot write $dir"
  printf '%s\n' "$finish" > "$dir/finish.json" || die "cannot write $dir"
  [ ! -f "${proof[0]}" ] || cp -- "${proof[0]}" "$dir/proof-script" 2>/dev/null
  printf '%s\n' "$id"
}

show_goal() {
  local id=${1-} json
  need_store
  if [ -z "$id" ]; then
    goalstore list --label goal --type epic --json 2>/dev/null \
      | jq -r '.[] | "\(.id)\t\(.status)\t\(.metadata.goal.ask // .title)"'
    return 0
  fi
  json=$(goalstore show "$id" --json 2>/dev/null | jq -c '.[0] // empty') && [ -n "$json" ] || die "no Goal $id"
  jq -r '.metadata.goal as $g | "goal: \(.id)\nask: \($g.ask)\nstate: \(.status)\nfinish: repo \($g.finish.repo), released \($g.finish.released), where \($g.finish.where)\nproof: \($g.finish.proof | join(" "))"' <<< "$json"
  goalstore list --parent "$id" --all --json 2>/dev/null \
    | jq -r 'sort_by(.id | split(".") | last | tonumber? // 0) | .[] |
        if .status == "on_hold" or .status == "blocked"
        then "stop: \(.id) \(.status) \(.metadata.hold_kind // "") - \(.metadata.hold_reason // "")"
        else "step: \(.id) \(.title) \(.status)" end'
}

rows_goal() { need_store; goalstore list --label goal --all -n 0 --json 2>/dev/null; }

cancel_goal() {
  local id=${1-} reason='' row
  [ -n "$id" ] || die "cancel needs a Goal id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=${2-}; shift 2 || die "--reason needs a value" ;;
      *) die "cancel: unknown argument $1" ;;
    esac
  done
  [ -n "$reason" ] || die "cancel needs --reason"
  need_store
  goalstore show "$id" --json 2>/dev/null | jq -e '.[0].labels | index("goal")' >/dev/null || die "no Goal $id"
  while read -r row; do
    [ -z "$row" ] || goalstore close "$row" --force --reason "goal cancelled: $reason" >/dev/null 2>&1 || die "could not close $row"
  done < <(goalstore list --parent "$id" --status open,in_progress,blocked,on_hold,deferred --json 2>/dev/null \
    | jq -r 'sort_by(.id | split(".") | last | tonumber? // 0) | .[].id')
  goalstore close "$id" --force --reason "goal cancelled: $reason" >/dev/null 2>&1 || die "could not close $id"
  printf 'cancelled %s\n' "$id"
}

case "${1:-}" in
  ''|-h|--help) usage ;;
  declare) shift; declare_goal "$@" ;;
  show) shift; show_goal "$@" ;;
  cancel) shift; cancel_goal "$@" ;;
  rows) rows_goal ;;
  *) die "unknown verb $1 (declare, show, cancel, rows)" ;;
esac
