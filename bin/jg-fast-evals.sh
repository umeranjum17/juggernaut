#!/usr/bin/env bash
# Fast behaviour evals: the deterministic checks the thin pull request gate runs.
#
# Usage: jg-fast-evals.sh [--smoke] [--help]
#
# Each eval drives a real entry point in a throwaway home and asserts what a user
# of that command sees. Nothing here mocks a command, calls a model, or touches
# the network, so one run finishes in seconds and either passes or fails.
#
# --smoke runs only the first eval, the one that proves a home boots and its fleet
# view renders. The pull request gate runs it as its own job so a build that
# cannot start at all fails in seconds, before the evals job is judged.
#
# The heavy behaviour suite is not part of this set and never becomes a pull
# request gate: .github/workflows/behavior.yml runs it nightly and after every
# main push, and bin/jg-post-merge-ci.sh files one fix item when it goes red.
#
# Output is one `ok - <eval>` or `not ok - <eval>: <reason>` line per eval and a
# closing summary. Exit 0 when every selected eval passed, 1 when any failed, and
# 2 on misuse. The scratch home is removed on exit, so a run leaves nothing
# behind.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

ALL_EVALS='home-boots brief-scaffold ticket-round-trip claim-needs-release'
SMOKE_EVAL=home-boots

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'
}

SMOKE=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --smoke) SMOKE=1 ;;
  '') ;;
  *) echo "error: unknown argument $1; run --help" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "error: at most one argument; run --help" >&2; exit 2; }

command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/jg-fast-evals.XXXXXX") || exit 1
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() { rm -rf -- "${SCRATCH:?}"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# One throwaway home per run: its own config, state and data, never the caller's.
mkdir -p "$SCRATCH/home/data" "$SCRATCH/home/state" "$SCRATCH/tmp" || exit 1
EVAL_HOME="$SCRATCH/home"

# eval_home <command...>: run a repo command against the throwaway home.
eval_home() {
  ( cd "$JG_ROOT" && \
    JG_HOME="$EVAL_HOME" JG_STATE_OVERRIDE="$EVAL_HOME/state" JG_DATA_OVERRIDE="$EVAL_HOME/data" \
    TMPDIR="$SCRATCH/tmp" "$@" )
}

# A fresh home renders its fleet view.
eval_home_boots() {
  local out
  out=$(eval_home bin/jg-fleet-view.sh 2>&1) || { echo "fleet view exited nonzero: $out"; return 1; }
  printf '%s\n' "$out" | grep -qx '# Fleet View' || { echo "fleet view has no '# Fleet View' heading"; return 1; }
  printf '%s\n' "$out" | grep -qF "Home: $EVAL_HOME" || { echo "fleet view does not name the home it read"; return 1; }
}

# A generated ship brief carries the isolation assertion that stops work in a
# primary checkout, and stops rather than continuing when it is launched there.
eval_brief_scaffold() {
  local out brief
  out=$(eval_home bin/jg-brief.sh eval-one juggernaut --mode direct-PR 2>&1) \
    || { echo "jg-brief.sh exited nonzero: $out"; return 1; }
  brief="$EVAL_HOME/data/eval-one/brief.md"
  [ -f "$brief" ] || { echo "jg-brief.sh wrote no brief at $brief"; return 1; }
  grep -q 'Verify isolation before anything else' "$brief" \
    || { echo "the brief does not open with the isolation assertion"; return 1; }
  grep -q 'not the primary checkout' "$brief" \
    || { echo "the brief does not name the primary checkout as the refusal case"; return 1; }
  grep -q 'launched in primary checkout, not an isolated worktree' "$brief" \
    || { echo "the brief does not carry the stop line it must report"; return 1; }
}

# A ticket added through the backlog wrapper is the ticket the list returns.
eval_ticket_round_trip() {
  local out
  eval_home bin/jg-tasks-axi.sh add eval-one '[feature] eval ticket' \
    --body 'why: the fast evals prove the backlog wrapper keeps a ticket' >"$SCRATCH/ticket-add.log" 2>&1 \
    || { echo "ticket add exited nonzero: $(tail -n 1 "$SCRATCH/ticket-add.log")"; return 1; }
  out=$(eval_home bin/jg-tasks-axi.sh list 2>&1) || { echo "ticket list exited nonzero: $out"; return 1; }
  printf '%s\n' "$out" | grep -q 'count: 1' || { echo "the list does not count the ticket just added"; return 1; }
  printf '%s\n' "$out" | grep -q 'eval-one' || { echo "the list does not show the ticket just added"; return 1; }
}

# A claim that a user-visible fix is done without a released ref is downgraded
# rather than passed through.
eval_claim_needs_release() {
  local out rc=0 claim
  claim='the login is fixed'
  out=$(eval_home bin/jg-live-claim.sh 'done' "$claim" 2>/dev/null) || rc=$?
  [ "$rc" -eq 3 ] || { echo "the claim exited $rc, not 3 (downgraded)"; return 1; }
  case $out in
    'merged-not-released: '*) ;;
    *) echo "the claim was not rewritten as merged-not-released: $out"; return 1 ;;
  esac
}

eval_one() {  # <eval-name>
  case $1 in
    home-boots) eval_home_boots ;;
    brief-scaffold) eval_brief_scaffold ;;
    ticket-round-trip) eval_ticket_round_trip ;;
    claim-needs-release) eval_claim_needs_release ;;
    *) echo "unknown eval $1"; return 1 ;;
  esac
}

SELECTED=$ALL_EVALS
[ "$SMOKE" -eq 0 ] || SELECTED=$SMOKE_EVAL
STARTED=$(date +%s)
PASSED=0
TOTAL=0
FAILED=''
for name in $SELECTED; do
  TOTAL=$((TOTAL + 1))
  if reason=$(eval_one "$name"); then
    echo "ok - $name"
    PASSED=$((PASSED + 1))
  else
    echo "not ok - $name: $reason"
    FAILED="$FAILED $name"
  fi
done
WALL=$(( $(date +%s) - STARTED ))

if [ "$PASSED" -eq "$TOTAL" ]; then
  printf 'fast-evals: %s/%s passed in %ss\n' "$PASSED" "$TOTAL" "$WALL"
  exit 0
fi
printf 'fast-evals: %s/%s passed in %ss; failed:%s\n' "$PASSED" "$TOTAL" "$WALL" "$FAILED"
exit 1
