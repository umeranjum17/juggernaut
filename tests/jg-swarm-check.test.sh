#!/usr/bin/env bash
# Journey: the swarm check shows one line of progress, speaks once when a swarm ends or waits on the owner or stalls,
# and puts each armed home's dispatch switch back when the home's last armed swarm is done.
# Real: bin/jg-swarm-check.sh, bin/jg-backlog.sh (strict intake, the Beads store), bin/jg-captain-hold.sh. By hand: the
# records swarm.json, plan.json and arm.json (the form of the swarm interface), and rows.tsv.
# a) status (long, --short, no record); b) a stall, quiet while a row is in flight; c) the owner wait, once;
# d) the owner's answer; e) the finish, once; f) the restore in a lead home; g) two swarms, a changed switch, the lane target.
# Usage: bin/jg-test-run.sh tests/jg-swarm-check.test.sh (the store test needs the two store tool variables the runner names)
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(jg_test_tmproot swarm-check)
M=$T/main L=$T/lead CHECK=$ROOT/bin/jg-swarm-check.sh
fails=0
say() { printf '%s\n' "$*"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }

mkhome() { # <dir>
  jg_test_beads_home "$1"
  rm -f "$1/config/backlog-intake-loose" # strict intake, as a live home
  mkdir -p "$1/state" "$1/projects/proj"
  ln -sn "$ROOT/bin" "$1/bin"; ln -sn "$ROOT/core" "$1/core"; ln -sn "$ROOT/toolchain.versions" "$1/toolchain.versions"
  printf -- '- proj [local-trunk +yolo] - the one project (added 2026-11-19)\n' > "$1/data/projects.md"
  : > "$1/data/squad_leads.md"
}
mkhome "$M"; mkhome "$L"
run() { local h=$1; shift; env HOME="$T" TMPDIR="$T" JG_HOME="$h" "$@"; } # the home's own config and data, as a live home
sections() {
  printf '## Captain\nThe owner wants this plan run as a swarm.\n\n## Ask\n%s\n\n## Why\nFixture of plan jg-plan.\n\n## Done when\nThe check prints its line.\n\n## Acceptance Criteria\nThe check output.\n' "$1"
}
add() { # <home> <id> <title>
  run "$1" "$ROOT/bin/jg-backlog.sh" add "$2" "$3" --priority 2 --kind ship --repo proj --body "$(sections "Build $2.")" > /dev/null \
    || { say "FAIL: could not file $2"; exit 1; }
}
done_() { run "$1" "$ROOT/bin/jg-backlog.sh" "done" "$2" > /dev/null; }
now=1800000000
chk() { run "$1" env JG_SWARM_NOW="${2:-$now}" "$CHECK" check "$1"; }
status() { run "$M" env JG_SWARM_NOW="$now" "$CHECK" status "$@"; }

# Six slice rows under a plan row: A to E in Main, F in the lead home with an owner word.
add "$M" jg-plan "Run the plan as swarm"; add "$L" jg-plan "Run the plan as swarm"
for s in a b c d e; do add "$M" "jg-plan-$s" "Build part $s of it"; done
add "$L" jg-plan-f "Build part f of it"
add "$L" jg-plan-g "Build part g of it"
for h in "$M" "$L"; do add "$h" jg-plan-word-f "Owner pick before slice"; done
for h in "$M" "$L"; do
  run "$h" "$ROOT/bin/jg-captain-hold.sh" design-card card-1 --raised-by jg-plan-word-f --title "Which colour should the button be?" > /dev/null
done

P=$M/data/swarm/jg-plan
mkdir -p "$P" "$L/data/swarm/jg-plan" "$L/config" "$M/config"
jq -n --arg m "$M" --arg l "$L" '{plan:"jg-plan", main_home:$m, owner_homes:{main:$m, lead:$l},
  slices:([{id:"a"},{id:"b"},{id:"c"},{id:"d"},{id:"e"}] | map(. + {owner_home:"main", row:("jg-plan-" + .id)}))
    + [{id:"f", owner_home:"lead", row:"jg-plan-f", word_row:"jg-plan-word-f"}]}' > "$P/plan.json"
jq -n --arg p "$P/plan.json" --argjson t "$now" '{plan:"jg-plan", plan_file:$p, started_at:$t, state:"running", steps:[], owners:{}}' > "$P/swarm.json"
arm() { # <home dir> <owner> <switch_before> <lane_before> <lane_wrote> <rows json> [<plan>]
  mkdir -p "$1/data/swarm/${7:-jg-plan}"
  jq -n --arg p "${7:-jg-plan}" --arg o "$2" --arg sb "$3" --arg lb "$4" --argjson lw "$5" --argjson rows "$6" --argjson t "$now" \
    '{plan:$p, plan_file:"x", home:$o, armed_at:$t, state:"armed", switch_before:$sb, switch_wrote:"on", lane_target_before:$lb,
      lane_target_wrote:$lw, agents:null, rows:$rows, words:[], gated:[]}' > "$1/data/swarm/${7:-jg-plan}/arm.json"
}
arm "$L" lead off absent null '["jg-plan-f"]'
printf 'on\n' > "$L/config/auto-dispatch"

# a) status
check "status long" "$(status)" "jg-plan: 0/6 landed, 0 working, 6 queued (1 wait for the owner), started 0h00m ago"
check "status short" "$(status jg-plan --short)" "jg-plan 0/6 landed, 0 working, 1 wait for the owner"
check "status of another plan" "$(status nothing)" "no swarm is running"
mv "$P/swarm.json" "$P/swarm.off"
check "status with no record" "$(status)" "no swarm is running"
mv "$P/swarm.off" "$P/swarm.json"

# b) stall: nothing in flight 31 minutes after the last change; a row in flight keeps it quiet
check "the first beat is quiet" "$(chk "$M")" ""
mkdir -p "$M/data/auto-dispatch"; printf '%s\tjg-plan-a\tskipped\tno brief\n' "$now" > "$M/data/auto-dispatch/rows.tsv"
out=$(chk "$M" $((now + 1860)))
check "stall names its rows once" "$(printf '%s\n' "$out" | wc -l)" 1
case $out in *"swarm jg-plan: no slice moved for 31 min; open: jg-plan-a (no brief); jg-plan-b (no dispatch row);"*) say "ok: stall line" ;; *) say "FAIL: stall line: $out"; fails=$((fails + 1)) ;; esac
check "a second beat is quiet" "$(chk "$M" $((now + 1900)))" ""
run "$M" "$ROOT/bin/jg-backlog.sh" start jg-plan-b > /dev/null
check "one row in flight is quiet" "$(chk "$M" $((now + 4000)))" ""
check "status counts the row in flight" "$(status --short)" "jg-plan 0/6 landed, 1 working, 1 wait for the owner"

# c) owner wait: every row done but F
alert() { run "$M" "$ROOT/bin/jg-alert.sh" "$@"; }
key=fleet-blocked--swarm-lane-jg-plan-f
printf 'blocked [at=%s] [key=fixture]: waiting for access\n' "$now" > "$L/state/jg-plan-f.status"
printf 'blocked [at=%s] [key=fixture]: outside this swarm\n' "$now" > "$L/state/jg-plan-g.status"
chk "$M" $((now + 600)) > /dev/null
check "exactly ten minutes is quiet" "$(alert list)" ""
chk "$M" $((now + 601)) > /dev/null
check "the cross-home blocker raises one alert" "$(alert list)" "$key"
check "the P1 names the lane and owner" \
  "$(alert show "$key" 2> /dev/null | grep -Ec '^(precedence=P1|note=.*jg-plan-f.*lead)' || true)" 2
printf 'working [at=%s]: still investigating\n' "$((now + 602))" >> "$L/state/jg-plan-f.status"
chk "$M" $((now + 602)) > /dev/null
check "routine progress leaves the blocker open" "$(alert word "$key" 2> /dev/null || true)" open
check "only one blocked lane notification across scans" "$(grep -Fc "$key" "$M/state/.wake-queue" 2> /dev/null || true)" 1
printf 'resolved [at=%s] [key=fixture]: access restored\n' "$((now + 603))" >> "$L/state/jg-plan-f.status"
chk "$M" $((now + 604)) > /dev/null
check "the alert clears when the blocker resolves" "$(alert word "$key" 2> /dev/null || true)" resolved
printf 'blocked [key=fixture]: waiting again; old status format\n' >> "$L/state/jg-plan-f.status"
chk "$M" $((now + 605)) > /dev/null
check "an unstamped recurrence starts a new wait" "$(alert list)" ""
chk "$M" $((now + 1206)) > /dev/null
check "an unstamped blocker eventually raises a fresh alert" "$(alert list)" "$key"
printf 'resolved [key=fixture]: access restored again\n' >> "$L/state/jg-plan-f.status"
chk "$M" $((now + 1207)) > /dev/null
check "the second alert clears independently" "$(alert word "$key" 2> /dev/null || true)" resolved

# The lead can claim a steer stored by Main, while the lane actions stay in the lead home.
arm "$L" lead off absent null '["jg-plan-f","jg-plan-g","jg-plan-g-extra"]'
# shellcheck disable=SC2016 # the fixture shell expands its own positional arguments
run "$M" bash -c '. "$1/bin/jg-task-inbox-lib.sh"; jg_task_inbox_write "$2" lead "$3"' \
  _ "$ROOT" "$M/state" 'Check jg-plan-f, then jg-plan-g.' > /dev/null
inbox=$M/state/lead.inbox
mv "$inbox/001.msg" "$inbox/handled/"
handled() {
  run "$L" env JG_TASK_INBOX="$inbox" "$ROOT/bin/jg-delivery.sh" handled lead 001 --evidence reply:fixture \
    --action jg-plan-f "Access restored" --action jg-plan-g "Worker steered"
}
if handled >/dev/null && handled >/dev/null &&
   run "$L" env JG_TASK_INBOX="$inbox" "$ROOT/bin/jg-delivery.sh" handled lead 001 --evidence reply:fixture >/dev/null; then
  for row in jg-plan-f jg-plan-g; do
    if [ "$row" = jg-plan-f ]; then action="Access restored"; else action="Worker steered"; fi
    check "one action for $row in the lead home after retry" \
      "$(jq -r --arg row "$row" 'select(.lane == $row) | [.action, .evidence] | @tsv' "$L/state/swarm-actions/$row/"*.json)" \
      "$action"$'\treply:fixture'
  done
else
  check "the lead can claim its parent steer" "refused" "handled"
fi
check "the parent has no action copies" "$([ -e "$M/state/swarm-actions" ] && echo yes || echo no)" no
check "an unmentioned lane has no action" "$([ -e "$L/state/swarm-actions/jg-plan-g-extra" ] && echo yes || echo no)" no
arm "$L" lead off absent null '["jg-plan-f"]'

for r in a b c d e; do done_ "$M" "jg-plan-$r"; done
out=$(chk "$M")
check "owner wait line" "$out" "swarm jg-plan: all runnable slices landed; 1 wait for the owner: jg-plan-f"
check "owner wait is said once" "$(chk "$M")" ""

# d) the owner's answer: F no longer waits, and the check changes no row
run "$M" "$ROOT/bin/jg-captain-hold.sh" design-pick card-1 --words "a" > /dev/null
check "answered: no wait" "$(status)" "jg-plan: 5/6 landed, 0 working, 1 queued (0 wait for the owner), started 0h00m ago"
chk "$M" > /dev/null
check "the check closed no row" "$(status --short)" "jg-plan 5/6 landed, 0 working, 0 wait for the owner"

# e) finish
done_ "$L" jg-plan-f
out=$(chk "$M" $((now + 3600 + 120)))
check "finish line" "$out" "swarm jg-plan: all 6 slices landed in 1h02m"
check "swarm state finished" "$(jq -r .state "$P/swarm.json")" finished
check "finish is said once" "$(chk "$M" $((now + 7200)))" ""
check "status after the finish" "$(status)" "no swarm is running"

# f) restore in the lead home
out=$(chk "$L")
check "restore line" "$out" "swarm jg-plan: lead restored its dispatch switch to off"
check "switch written back" "$(cat "$L/config/auto-dispatch")" off
check "arm record finished" "$(jq -r .state "$L/data/swarm/jg-plan/arm.json")" finished
check "restore is said once" "$(chk "$L")" ""

# g) two swarms in one home; switch_before absent in both records
rm -f "$L/config/auto-dispatch" "$L/config/lane-target"
add "$L" jg-plan2-a "Build part a of it"; add "$L" jg-plan2-b "Build part b of it"
arm "$L" lead absent absent 8 '["jg-plan-f"]'; arm "$L" lead absent absent 8 '["jg-plan2-a"]' jg-plan2
printf 'on\n' > "$L/config/auto-dispatch"; printf '8\n' > "$L/config/lane-target"
check "another armed swarm: no restore" "$(chk "$L")" ""
check "the switch stays" "$(cat "$L/config/auto-dispatch")" on
check "the other swarm stays armed" "$(jq -r .state "$L/data/swarm/jg-plan2/arm.json")" armed
done_ "$L" jg-plan2-a
check "the last swarm restores its own before" "$(chk "$L")" "swarm jg-plan2: lead restored its dispatch switch to absent"
check "the switch file is gone" "$([ -e "$L/config/auto-dispatch" ] && echo yes || echo no)" no
check "the lane target file is gone" "$([ -e "$L/config/lane-target" ] && echo yes || echo no)" no
# a switch the owner changed since the arm is left alone, and so is a lane target that holds another number
arm "$L" lead off 5 12 '["jg-plan2-a"]' jg-plan3
printf 'off\n' > "$L/config/auto-dispatch"; printf '9\n' > "$L/config/lane-target"
check "a changed switch: no restore line" "$(chk "$L")" ""
check "a changed switch stays" "$(cat "$L/config/auto-dispatch")" off
check "a changed lane target stays" "$(cat "$L/config/lane-target")" 9
# an unreadable home is named on stderr and skipped: its ticket store is not a database (a home with no store reads as empty)
mkdir -p "$T/broken/data/swarm/jg-plan" "$T/broken/config" "$T/broken/state/item-store"
printf 'not a database\n' > "$T/broken/state/item-store/fleet.db"
cp "$P/swarm.json" "$T/broken/data/swarm/jg-plan/swarm.json"; jq '.state = "running"' "$P/swarm.json" > "$T/broken/data/swarm/jg-plan/swarm.json"
jq --arg h "$T/broken" '.main_home = $h | .owner_homes.main = $h' "$P/plan.json" > "$T/broken/data/swarm/jg-plan/plan.json"
check "an unreadable home is skipped" "$(env JG_HOME="$T/broken" JG_SWARM_NOW="$now" "$CHECK" check "$T/broken" 2> "$T/err")" ""
check "an unreadable home is named" "$(grep -c "$T/broken" "$T/err")" 1

[ "$fails" -eq 0 ] || { say "swarm-check: $fails failed"; exit 1; }
say "swarm-check: all passed"
