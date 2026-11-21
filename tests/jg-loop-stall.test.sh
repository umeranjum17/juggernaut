#!/usr/bin/env bash
# Journey: a Blitz plan or a Goal with ready work that makes no progress for 10 minutes raises one P1 that only progress clears (jg-8ci).
# Real: core/loop-stall/loop-stall.sh, bin/jg-swarm-check.sh (the Blitz feed, over the real Beads store), bin/jg-alert.sh, core/goal-loop/goal-loop.sh
# (the Goal feed, its rows read through the JG_GOAL_BIN hook the goal-loop tests use), bin/jg-delivery-tick.sh wiring by grep. By hand: swarm.json and
# plan.json (the form of the swarm interface) and the Goal rows.
# a) a plan with a startable slice: quiet at 599 s, one P1 at 601 s, an acknowledgement and a repeat tick keep it open
# b) progress closes it: a slice started, with its proof; a slice landed with more ready restarts the clock; an unreadable home changes nothing
# c) a Goal whose step waits: the same clock, the same P1, closed only when the step is taken; a stopped Goal raises nothing
# Usage: bin/jg-test-run.sh tests/jg-loop-stall.test.sh (the store test needs the two store tool variables the runner names)
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(jg_test_tmproot loop-stall)
M=$T/main TICK=$ROOT/core/loop-stall/loop-stall.sh
fails=0
say() { printf '%s\n' "$*"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }

jg_test_beads_home "$M"
rm -f "$M/config/backlog-intake-loose"
mkdir -p "$M/state" "$M/projects/proj"
ln -sn "$ROOT/bin" "$M/bin"; ln -sn "$ROOT/core" "$M/core"; ln -sn "$ROOT/toolchain.versions" "$M/toolchain.versions"
printf -- '- proj [local-trunk +yolo] - the one project (added 2026-11-19)\n' > "$M/data/projects.md"
: > "$M/data/squad_leads.md"
run() { env HOME="$T" TMPDIR="$T" JG_HOME="$M" "$@"; }
sections() {
  printf '## Captain\nThe owner wants this plan run as a swarm.\n\n## Ask\n%s\n\n## Why\nFixture of plan jg-plan.\n\n## Done when\nThe tick stays quiet.\n\n## Acceptance Criteria\nThe alert.\n' "$1"
}
add() { run "$ROOT/bin/jg-backlog.sh" add "$1" "$2" --priority 2 --kind ship --repo proj --body "$(sections "Build $1.")" > /dev/null || { say "FAIL: could not file $1"; exit 1; }; }
now=1800000000
tick() { run env JG_LOOP_STALL_NOW="${1:-$now}" bash "$TICK" tick "$M"; }
alertcmd() { run bash "$ROOT/bin/jg-alert.sh" "$@"; }
word() { alertcmd word "$1" 2> /dev/null || true; }

# a) one plan, two slices, none started
add jg-plan "Run the plan as swarm"; add jg-plan-a "Build part a"; add jg-plan-b "Build part b"
P=$M/data/swarm/jg-plan
mkdir -p "$P"
jq -n --arg m "$M" '{plan:"jg-plan", main_home:$m, owner_homes:{main:$m},
  slices:[{id:"a", owner_home:"main", row:"jg-plan-a"}, {id:"b", owner_home:"main", row:"jg-plan-b"}]}' > "$P/plan.json"
jq -n --arg p "$P/plan.json" --argjson t "$now" '{plan:"jg-plan", plan_file:$p, started_at:$t, state:"running", steps:[], owners:{}}' > "$P/swarm.json"
K=fleet-blocked--blitz-jg-plan-stalled
check "the plan's ready feed" "$(run bash "$ROOT/bin/jg-swarm-check.sh" ready "$M" | cut -f1,2)" "$(printf 'jg-plan\t0 0 2 0')"
tick; check "the first sight starts a clock and raises nothing" "$(word $K)" ""
tick $((now + 599)); check "599 s is quiet" "$(word $K)" ""
tick $((now + 601)); check "601 s raises the P1" "$(word $K)" open
case $(alertcmd show $K) in *precedence=P1*) say "ok: it is a P1" ;; *) say "FAIL: it is not a P1"; fails=$((fails + 1)) ;; esac
alertcmd ack $K > /dev/null
tick $((now + 700)); tick $((now + 900))
check "an acknowledgement and later ticks never close it" "$(word $K | grep -c -E '^(open|acknowledged|waiting)$' || true)" 1

# b) progress closes it, with its proof
run "$ROOT/bin/jg-backlog.sh" start jg-plan-a > /dev/null
check "a slice in flight is no ready feed" "$(run bash "$ROOT/bin/jg-swarm-check.sh" ready "$M")" ""
tick $((now + 1000)); check "a slice started: the P1 resolves" "$(word $K)" resolved
case $(alertcmd show $K) in *proof=source:progress-ready-work-gone*) say "ok: the resolve names progress as its proof" ;; *) say "FAIL: no progress proof"; fails=$((fails + 1)) ;; esac
check "the clock is dropped" "$([ -e "$M/data/loop-stall/blitz--jg-plan.tsv" ] && echo yes || echo no)" no
run "$ROOT/bin/jg-backlog.sh" "done" jg-plan-a > /dev/null
tick $((now + 1100)); tick $((now + 1100 + 599)); check "a slice landed, one still ready: a fresh clock, quiet" "$(word $K)" resolved
tick $((now + 1100 + 601)); check "the fresh clock raises it again" "$(word $K)" open
# an unreadable home changes nothing: the alert neither resolves nor re-arms
mv "$P/plan.json" "$P/plan.off"; jq '.slices[0].row = "jg-plan-a"' "$P/plan.off" | jq '.owner_homes.main = "/nonexistent-home"' > "$P/plan.json"
tick $((now + 3000)); check "an unreadable plan is not progress" "$(word $K)" open
mv "$P/plan.off" "$P/plan.json"
run "$ROOT/bin/jg-backlog.sh" "done" jg-plan-b > /dev/null
tick $((now + 3100)); check "every slice landed: closed" "$(word $K)" resolved

# c) a Goal
cat > "$T/goal-bin" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = rows ] && cat "$T/goal-rows.json"
SH
chmod +x "$T/goal-bin"
goal_rows() { # <epic status> <step status>
  jq -n --arg es "$1" --arg ss "$2" '[{id:"goal-1", issue_type:"epic", status:$es, title:"Ship it", metadata:{goal:{ask:"Ship it"}}},
    {id:"goal-1.1", parent:"goal-1", status:$ss, metadata:{kind:"ship"}}]' > "$T/goal-rows.json"
}
export JG_GOAL_BIN=$T/goal-bin
G=fleet-blocked--goal-goal-1-stalled
goal_rows open open
g=$((now + 10000))
tick $g; tick $((g + 599)); check "a Goal step waiting 599 s is quiet" "$(word $G)" ""
tick $((g + 601)); check "a Goal step waiting 601 s raises the P1" "$(word $G)" open
alertcmd ack $G > /dev/null; tick $((g + 800))
check "an acknowledgement never closes it" "$(word $G | grep -c -E '^(open|acknowledged|waiting)$' || true)" 1
goal_rows open in_progress
tick $((g + 900)); check "the step taken: the P1 resolves" "$(word $G)" resolved
goal_rows open on_hold
tick $((g + 5000)); tick $((g + 6000)); check "a Goal stopped for its owner raises nothing new" "$(word $G)" resolved

# the delivery tick runs it, with no model
check "the delivery tick runs the check" "$(grep -c 'core/loop-stall/loop-stall.sh" tick' "$ROOT/bin/jg-delivery-tick.sh")" 1

if [ "$fails" = 0 ]; then say "loop-stall: all passed"; else say "loop-stall: $fails failed"; exit 1; fi
