#!/usr/bin/env bash
# A lane's events reach its Beads ticket as they happen, through the real callers, on a real Beads store (ticket-state-writeback):
#   spawn    the library's dispatch step owns the row: assignee (the lane's agent name), model and effort, stage building;
#   done     the delivery tick's ready step (bin/jg-ready-trace.sh) puts ready_at on the row: stage proving;
#   take-up  the landing check takes the lane up (core/trunk-landing/ticket-trail.sh, trail_proved): stage delivering;
#   refusal  verdict_record (core/trunk-landing/verdict.sh) keeps the lane delivering and leaves the reason on the ticket's trail and
#            the wait on whoever owes the next move; a newer status line of the lane takes the wait off (bin/jg-wait-trace.sh);
#   park     a `paused ... reason=parked` line becomes the wait lead/parked at the next tick (bin/jg-wait-trace.sh);
#   landing  a landed commit puts the ticket on the line (bin/jg-beads-trace.py land; the lander's own caller, landed_effects, is
#            proved by tests/jg-trace-writers.test.sh and the trunk tests).
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-lane-events-ticket)
COMPAT=$ROOT/core/item-store/adapters/bd_compat.py CLI=$ROOT/bin/jg-backlog.sh
unset BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
mkdir -p "$T/home/config" "$T/home/data" "$T/home/state"
export TZ=UTC TMPDIR=$T JG_HOME=$T/home
: > "$T/home/config/backlog-intake-loose"
H=$T/home; ln -sn "$ROOT/bin" "$H/bin"

bd() { python3 -I "$COMPAT" "$@"; }
axi() { "$CLI" "$@"; }
field() { bd show "$1" --json 2>/dev/null | jq -r "(if type == \"array\" then .[0] else . end) | $2"; }
stage() { axi ticket-stage jg-w1 | cut -f1; }
kinds() { bd provenance log jg-w1 --json | jq -r 'sort_by(.occurred_at) | map(.kind + ":" + .source) | join(" ")'; }
status() { printf '%s\n' "$1" >> "$H/state/lane-w1.status"; }

axi add jg-w1 "[feature] fixture lane" --priority 2 --body why >/dev/null || fail "file jg-w1"
bd update jg-w1 --set-metadata task=lane-w1 >/dev/null || fail "name the task"
printf 'ticket=jg-w1\nmode=local-trunk\n' > "$H/state/lane-w1.meta"

# spawn: the library's own dispatch step, as bin/jg-spawn.sh calls it.
printf 'ticket=jg-w1\nspawn_gen=s1.1.1\nharness=claude\nmodel=m-5\neffort=high\nagent_name=fix-fixture-jg-w1\n' > "$H/state/lane-w1.meta"
# shellcheck disable=SC2016  # the script text is the child's, so $1 and $2 are its own
out=$(env -u JG_DATA_OVERRIDE -u JG_STATE_OVERRIDE -u JG_CONFIG_OVERRIDE JG_HOME="$H" bash -c '
  . "$1/jg-timeout-lib.sh"; . "$1/jg-backlog-lib.sh"; . "$1/jg-backlog-transition-lib.sh"
  jg_backlog_atomic_transition dispatch "$2/state/lane-w1.meta" "$2/data" jg-w1 "$2/state"' _ "$ROOT/bin" "$H" 2>&1) || fail "spawn dispatch: $out"
[ "$(field jg-w1 .assignee)" = fix-fixture-jg-w1 ] && [ "$(field jg-w1 .status)" = in_progress ] && [ "$(field jg-w1 .metadata.model)" = m-5 ] \
  || fail "spawn must set assignee, in_progress and the model, got [$(field jg-w1 .assignee)] [$(field jg-w1 .status)] [$(field jg-w1 .metadata.model)]"
[ "$(stage)" = building ] || fail "after spawn the ticket reads building, got [$(stage)]"
pass "spawn: assignee, model and building are on the row"

# done: the tick's ready step.
status 'working [at=1794000100]: started'
status 'done [at=1794000200]: ready in branch x'
bash "$ROOT/bin/jg-ready-trace.sh" "$H" || fail "the ready step failed"
case $(stage) in proving*) ;; *) fail "after done the ticket reads proving, got [$(stage)]" ;; esac
pass "done: the ticket reads proving"

# take-up and refusal: the landing check's own functions, with the variables trunk-landing.sh gives them.
export FMH=$H STATE=$H/state DATA_DIR=$H/data MEM=$H/data/jg-trunk-landing RETRY_CAP=3
mkdir -p "$MEM"
# shellcheck source=core/trunk-landing/ticket-trail.sh disable=SC1091
. "$ROOT/core/trunk-landing/ticket-trail.sh"
# shellcheck source=core/trunk-landing/verdict.sh disable=SC1091
. "$ROOT/core/trunk-landing/verdict.sh"
trail_proved lane-w1 || fail "trail_proved"
[ "$(stage)" = delivering.queued ] || fail "once the lander takes the lane up the ticket reads delivering, got [$(stage)]"
head=0123456789abcdef0123456789abcdef01234567
verdict_record lane-w1 "$head" "" tiptip "REFUSED: the commit must carry the trailer" "the commit must carry the trailer 'Ticket: jg-w1'" || fail "verdict_record"
[ "$(stage)" = delivering.queued ] || fail "a refusal keeps the ticket delivering, got [$(stage)]"
[ "$(field jg-w1 .metadata.wait)" = worker ] && [ "$(field jg-w1 .metadata.wait_reason)" = blocker ] || fail "a final refusal waits on the worker for a blocker"
bd provenance log jg-w1 --json | jq -e 'map(select(.source == "jg-trunk-refuse")) | length == 1 and (.[0].payload | tostring | contains("must carry the trailer"))' >/dev/null \
  || fail "the refusal's reason is on the trail"
verdict_record lane-w1 "$head" "" tiptip "REFUSED: the commit must carry the trailer" "the commit must carry the trailer 'Ticket: jg-w1'" || fail "verdict_record again"
[ "$(bd provenance log jg-w1 --json | jq '[.[] | select(.source == "jg-trunk-refuse")] | length')" = 1 ] || fail "the same refusal twice is one event"
bash "$ROOT/bin/jg-wait-trace.sh" "$H" || fail "the wait step failed"
[ "$(field jg-w1 .metadata.wait)" = worker ] || fail "the wait stays while the refused line is the last one"
pass "take-up and refusal: delivering with the reason, and the wait on the worker"

# the lane answers (a newer line): the refusal's wait goes. Then it parks: the declared wait reaches the row.
status 'working [at=1794000300]: fixing the trailer'
bash "$ROOT/bin/jg-wait-trace.sh" "$H" || fail "the wait step failed"
[ "$(field jg-w1 .metadata.wait)" = none ] || fail "a newer line takes the refusal's wait off, got [$(field jg-w1 .metadata.wait)]"
status 'paused [at=1794000400] [wait=lead] [reason=parked]: set aside'
bash "$ROOT/bin/jg-wait-trace.sh" "$H" || fail "the wait step failed"
[ "$(field jg-w1 .metadata.wait)" = lead ] && [ "$(field jg-w1 .metadata.wait_reason)" = parked ] || fail "a parked line must write the wait lead, parked"
status 'working [at=1794000500]: back'
bash "$ROOT/bin/jg-wait-trace.sh" "$H" || fail "the wait step failed"
[ "$(field jg-w1 .metadata.wait)" = none ] || fail "work after the park takes the wait off"
pass "park: the wait lead/parked is on the row and goes when the lane works again"

# landing.
axi trace record jg-w1 land git-sha "$head" --source jg-trunk-land --at 1794000600 >/dev/null || fail "land"
[ "$(stage)" = delivering.batched ] || fail "a landed commit puts the ticket on the line, got [$(stage)]"
python3 -I "$ROOT/core/item-store/adapters/tickets.py" check >"$T/check.log" 2>&1 || fail "the tables must stay the record: $(cat "$T/check.log")"
pass "landing: the ticket reads landed on the line ($(kinds))"
