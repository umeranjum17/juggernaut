#!/usr/bin/env bash
# Behavior tests for the wait machine table (core/machines/tables/wait.tsv) through bin/jg-machine.sh.
# A pause that carries reason=parked is shown as "parked, no date"; the old placeholder date 2026-12-31 is no longer a parking word.
# The status lines are generated here by seed_status; no fleet record is copied. The display never
# changes the classifier: the verdicts jg-classify.sh gives for each seeded line are pinned below
# and the status files are byte-identical after every read.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v "${JG_CLASSIFY_GO:-go}" >/dev/null 2>&1; then
  printf 'skip: no Go toolchain on PATH; install go to build the classifier\n'
  exit 0
fi
JM="$ROOT/bin/jg-machine.sh"
CL="$ROOT/bin/jg-classify.sh"
T=$(jg_test_tmproot jg-machine-wait); mkdir -p "$T/state" "$T/cache"
export JG_STATE_OVERRIDE="$T/state" XDG_CACHE_HOME="$T/cache"
unset JG_MACHINES_TABLES
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
state_of() { jm show wait "$1"; printf '%s\n' "$OUT" | awk -F'\t' '$1=="state"{print $2}'; }

seed_status() {  # <id> <last line>: one task whose latest status line is the given one
  printf 'working [at=1]: start\n%s\n' "$2" > "$T/state/$1.status"
}
seed_status work 'working [at=2]: building'
seed_status prose 'working [at=2]: waiting until 2026-12-31 for nothing'
seed_status open 'paused [at=2]: waiting on review'
seed_status dated 'paused [at=2]: waiting until 2026-11-02T10:00Z'
seed_status sentstamp 'paused [at=2] [wait=lead] [reason=parked]: set aside'
seed_status sentday 'paused [at=2] wait=lead reason=parked: set aside'
seed_status oldday 'paused [at=2]: parked until 2026-12-31T00:00Z'
seed_status badtime 'paused [at=2]: waiting until 2026-13-45T99:00Z'

# Classifier verdicts for each seeded line, read before the table is consulted (paused, paused-until).
verdicts() { for id in work prose open dated sentstamp sentday oldday badtime; do
    l=$(bash "$CL" last-line "$T/state/$id.status"); bash "$CL" is-paused "$l" && p=yes || p=no
    u=$(bash "$CL" paused-until "$l") || u=-; printf '%s %s %s\n' "$id" "$p" "$u"; done; }
before=$(verdicts)
assert_equals "$(printf 'work no -\nprose no -\nopen yes -\ndated yes 1793613600\nsentstamp yes -\nsentday yes -\noldday yes 1798675200\nbadtime yes -')" "$before" "classifier verdicts for the seeded lines"
sum_before=$(cat "$T"/state/*.status | cksum)

jm check wait; expect_code 0 "$RC" "the wait table passes lint"
assert_contains "$OUT" "ok wait:" "check says ok"
pass "the wait table passes the machine lint"

assert_equals not-paused "$(state_of work)" "a working line is not a pause"
assert_equals not-paused "$(state_of prose)" "prose that names the date is not a pause"
assert_equals paused-open "$(state_of open)" "a pause with no time named"
assert_equals paused-dated "$(state_of dated)" "a pause with a real time"
assert_equals paused-no-date "$(state_of sentstamp)" "reason=parked in brackets is parked, no date"
assert_equals paused-no-date "$(state_of sentday)" "reason=parked as bare words is parked, no date"
assert_equals paused-dated "$(state_of oldday)" "the old placeholder date is only a far date now"
assert_equals paused-open "$(state_of badtime)" "a malformed time falls back to no time named"
jm show wait sentday
assert_contains "$OUT" "set aside by the lead and no date is waited for" "the captain sentence says parked, no date"
assert_not_contains "$OUT" "December" "the captain never reads December"
jm next wait sentday; expect_code 0 "$RC" "next on a parked line"
assert_contains "$OUT" "$(printf 'move\tdate\tpaused-dated')" "a parked wait can gain a real date"
pass "display state per seeded line, sentinel date shown as paused-no-date"

assert_equals "$before" "$(verdicts)" "classifier verdicts unchanged after the reads"
assert_equals "$sum_before" "$(cat "$T"/state/*.status | cksum)" "the status files are untouched"
pass "classifier verdicts and records are unchanged"

# Every edge: seed a task in the from state, append the line the event names, expect the to state.
line_for() {  # <state or event> -> a status line that puts a task in that state
  case $1 in
    not-paused|resume) echo 'working [at=3]: back to work' ;;
    paused-open|pause) echo 'paused [at=3]: waiting on review' ;;
    paused-dated|pause-dated|date) echo 'paused [at=3]: waiting until 2026-11-02T10:00Z' ;;
    paused-no-date|park) echo 'paused [at=3] [wait=lead] [reason=parked]: set aside' ;;
  esac
}
n=0
while IFS=$'\t' read -r kind from event to _; do
  [ "$kind" = edge ] || continue
  seed_status walk "$(line_for "$from")"; assert_equals "$from" "$(state_of walk)" "edge $from $event starts in $from"
  line_for "$event" >> "$T/state/walk.status"; assert_equals "$to" "$(state_of walk)" "edge $from $event lands in $to"
  n=$((n + 1))
done < "$ROOT/core/machines/tables/wait.tsv"
assert_equals 10 "$n" "every edge of the table was walked"
pass "each edge lands in its listed state"
