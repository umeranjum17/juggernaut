#!/usr/bin/env bash
# Slice S9 of jg-q1b3n on a real Beads store, through the real callers: the verb `jg-backlog.sh trace record` writes the provenance
# event first and then the time on the row, found by a task id as well as by a ticket id; the delivery tick's ready step
# (bin/jg-ready-trace.sh) records ready, resumed and a newer ready from a lane's status file; the merge's post-merge step
# records the receipt it read; and the evidence list only grows. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the builds; without
# them the run skips plainly. It proves bin/jg-beads-trace.py, bin/jg-trace-lib.sh, bin/jg-ready-trace.sh and the receipt step of
# bin/jg-merge-gate-lib.sh, the files the changed-test selector maps to it.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

T=$(jg_test_tmproot jg-trace-writers)
WRAPPER=$ROOT/bin/jg-beads.sh CLI=$ROOT/bin/jg-backlog.sh
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
mkdir -p "$T/store" "$T/home/config" "$T/home/data" "$T/home/state"
export TZ=UTC TMPDIR=$T BEADS_DIR=$T/store/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT JG_HOME=$T/home
printf '%s\n' "$BEADS_DIR" > "$T/home/config/beads-dir"

bd() { "$WRAPPER" "$@"; }
axi() { "$CLI" "$@"; }
row() { bd show "$1" --json 2>/dev/null | jq -c 'if type == "array" then .[0] else . end'; }
meta() { row "$1" | jq -r --arg k "$2" '.metadata[$k] // ""'; }
kinds() { bd provenance log "$1" --json | jq -r 'sort_by(.occurred_at) | map(.kind + ":" + .source) | join(" ")'; }
events() { bd provenance log "$1" --json | jq length; }
ready() {  # <ticket>: ready by the row alone, as the stage rule reads it
  row "$1" | jq -r '(.metadata // {}) as $m | if ($m.ready_at // "") != "" and (($m.resumed_at // "") == "" or $m.ready_at > $m.resumed_at) then "ready" else "not-ready" end'
}
tick() { bash "$ROOT/bin/jg-ready-trace.sh" "$T/home" || fail "the ready step failed"; }

bd init --prefix jg >"$T/init.log" 2>&1 || fail "init the store: $(cat "$T/init.log")"
axi add jg-s9a "[feature] fixture lane" --priority 2 --body why >/dev/null || fail "file jg-s9a"
bd update jg-s9a --set-metadata task=lane-s9a >/dev/null || fail "name the task"

# The verb: a task id finds the ticket; the event is there when the row changes; a repeat adds nothing; a moment is never moved back.
axi trace record lane-s9a commit work-id lane-s9a@done-1 --source jg-done --at 1794000000 >/dev/null || fail "trace record by a task id"
[ "$(events jg-s9a)" = 1 ] && [ "$(kinds jg-s9a)" = "commit:jg-done" ] || fail "one commit event after the first record, got [$(kinds jg-s9a)]"
[ "$(meta jg-s9a ready_at)" = 2026-11-06T21:20:00Z ] || fail "ready_at is the event time, got [$(meta jg-s9a ready_at)]"
axi trace record jg-s9a commit work-id lane-s9a@done-1 --source jg-done --at 1794000000 >/dev/null || fail "trace record by a ticket id"
[ "$(events jg-s9a)" = 1 ] || fail "the same moment recorded twice must add no second event"
axi trace record jg-s9a commit work-id older --source jg-done --at 1793000000 >/dev/null 2>&1 && fail "an earlier moment must be refused"
[ "$(events jg-s9a)" = 1 ] || fail "a refused moment must write no event"
pass "trace record: found by task id and ticket id, event then time, a repeat adds nothing, no moving back"

# The evidence list only grows.
axi trace record jg-s9a used work-id card-1 --source jg-evidence >/dev/null || fail "evidence 1"
axi trace record jg-s9a used work-id card-2 --source jg-evidence >/dev/null || fail "evidence 2"
axi trace record jg-s9a used work-id card-1 --source jg-evidence >/dev/null || fail "evidence 1 again"
[ "$(meta jg-s9a evidence)" = card-1,card-2 ] || fail "evidence is the list of cards, once each, got [$(meta jg-s9a evidence)]"
pass "evidence: the list only grows"

# The ready step of the tick, over a lane whose status file goes done, working, done.
axi add jg-s9b "[feature] second fixture" --priority 2 --body why >/dev/null || fail "file jg-s9b"
printf 'ticket=jg-s9b\nmode=local\n' > "$T/home/state/lane-b.meta"
printf 'working [at=1794000100]: started\n' > "$T/home/state/lane-b.status"
tick; [ "$(kinds jg-s9b)" = "" ] || fail "a lane that never said done writes nothing, got [$(kinds jg-s9b)]"
printf 'done [at=1794000200]: ready in branch x\n' >> "$T/home/state/lane-b.status"
tick; [ "$(kinds jg-s9b)" = "commit:jg-done" ] && [ "$(ready jg-s9b)" = ready ] || fail "done must record commit and ready_at, got [$(kinds jg-s9b)] $(ready jg-s9b)"
first=$(meta jg-s9b ready_at); tick; tick
[ "$(events jg-s9b)" = 1 ] || fail "a tick with nothing new must add no event, got $(events jg-s9b)"
bd provenance log jg-s9b --json | jq -e '.[0].ref == "lane-b@done-1794000200"' >/dev/null || fail "the commit ref is the task id at done-<epoch>"
printf 'working [at=1794000300]: lander refused it\n' >> "$T/home/state/lane-b.status"
tick; [ "$(kinds jg-s9b)" = "commit:jg-done resume:jg-done" ] && [ "$(ready jg-s9b)" = not-ready ] || fail "working after done must record resume, got [$(kinds jg-s9b)] $(ready jg-s9b)"
tick; [ "$(events jg-s9b)" = 2 ] || fail "resume is recorded once"
printf 'done [at=1794000400]: ready again\n' >> "$T/home/state/lane-b.status"
tick; [ "$(ready jg-s9b)" = ready ] && [ "$(meta jg-s9b ready_at)" \> "$first" ] || fail "a later done must write a newer ready_at and read ready"
pass "tick: done, working, done reads ready, not ready, ready with a resume between; a quiet tick writes nothing"

# A lane with no ticket is left alone.
printf 'mode=local\n' > "$T/home/state/lane-c.meta"; printf 'done [at=1794000500]: x\n' > "$T/home/state/lane-c.status"
tick; [ ! -e "$T/home/state/.ready-trace/lane-c" ] || fail "a lane with no ticket must not be recorded"

# The merge's post-merge step records the receipt it read, with the verdict.
axi add jg-s9d "[feature] merged fixture" --priority 2 --body why >/dev/null || fail "file jg-s9d"
printf 'ticket=jg-s9d\n' > "$T/home/state/lane-d.meta"
head=0123456789abcdef0123456789abcdef01234567
printf '{"task":"lane-d","head":"%s","verdict":"PASS"}\n' "$head" > "$T/home/state/lane-d.run-receipt.json"
( . "$ROOT/bin/jg-merge-gate-lib.sh" && jg_merge_post_hook "$T/home/config" "$T/home" lane-d "$T/home/state/lane-d.meta" "$head" - ) || fail "the post-merge step"
bd provenance log jg-s9d --json | jq -e '.[0] | .kind == "used" and .ref == "lane-d@0123456789ab" and (.payload | tostring | contains("PASS"))' >/dev/null \
  || fail "the receipt event is used, ref <task>@<head 12>, with the verdict: $(bd provenance log jg-s9d --json)"
pass "merge: the receipt it read is on the ticket's trail"
