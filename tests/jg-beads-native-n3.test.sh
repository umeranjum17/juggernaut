#!/usr/bin/env bash
# A dated hold on a real Beads store: a native deferred row that returns by itself and always has a reason.
# Needs JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT naming the pinned builds, and skips without them.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh disable=SC1091
. "$HERE/lib.sh"
WRAPPER=$ROOT/bin/jg-beads.sh
WRITE=$ROOT/bin/jg-beads-write.py
VIEW=$ROOT/bin/jg-beads-view.py
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi
T=$(jg_test_tmproot jg-beads-n3)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/one" "$T/two"
export JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT BEADS_DIR=$T/one/.beads
PAST=2020-01-02 FUTURE=2099-03-04

bd_() { "$WRAPPER" "$@" 2>/dev/null; }
write() { python3 "$WRITE" "$@" 2>&1; }
axi() { bd_ list --all --limit 0 --json | python3 "$VIEW" "$@"; }
field() { axi show "$1" | sed -n "s/^  $2: //p"; }
row() {  # <id> <python expression over r>
  bd_ show "$1" --json | python3 -c 'import json,sys
r=json.load(sys.stdin); r=r[0] if isinstance(r,list) else r
m=r.get("metadata") or {}
print('"$2"')'
}
same() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }  # <got> <want> <message>
in_ready() { bd_ ready --limit 0 --json | grep -q "\"id\": \"$1\""; }
seed() { local id; for id; do "$WRAPPER" create "$id" --id "$id" --force >/dev/null 2>&1 || fail "seed $id"; done; }
refused() { local want=$1 got=0; shift; "$@" >/dev/null 2>&1 || got=$?; expect_code "$want" "$got" "$*"; }  # <exit code> <command...>

"$WRAPPER" init --prefix n3 >/dev/null 2>&1 || fail "init"
tables=$("$WRAPPER" dolt sql -q "select constraint_name, check_clause from information_schema.check_constraints where constraint_name like '%hold_needs_reason'" 2>&1)
assert_not_contains "$tables" deferred "the store's own rule must not name deferred"

# A dated hold is a deferred row, a plain hold stays on_hold, and either converts to the other.
seed n3-dated
out=$(write hold n3-dated --reason "waits on Umer" --kind external --until "$FUTURE") || fail "dated hold: $out"
same "$(row n3-dated 'r["status"], r["defer_until"], m["hold_reason"]')" "deferred ${FUTURE}T00:00:00Z waits on Umer" "dated hold row"
same "$(field n3-dated held)" yes "a future date must read as held"
same "$(field n3-dated hold_until)" "$FUTURE" "the date must read back"
in_ready n3-dated && fail "a future date must stay out of bd ready"
assert_not_contains "$out" "--include-held" "the tip must name a flag we serve"
assert_contains "$out" "list --state held" "the tip must name the held list"
out=$(write hold n3-dated --reason "waits on Umer" --kind external --until "$FUTURE")
assert_contains "$out" "already held" "the same dated hold must converge"
write hold n3-dated --reason "no date now" >/dev/null || fail "undated over dated"
same "$(row n3-dated 'r["status"], r.get("defer_until")')" "on_hold None" "an undated hold must drop the date"
write hold n3-dated --reason "dated again" --until "$FUTURE" >/dev/null || fail "dated over undated"
same "$(row n3-dated 'r["status"]')" deferred "a date must move on_hold to deferred"
write unhold n3-dated >/dev/null || fail "unhold"
same "$(row n3-dated 'r["status"], r.get("defer_until"), m.get("hold_reason")')" "open None None" "unhold must clear a dated hold"

# Our reason rule: every door that defers a row refuses with no reason, and the store has no part in it.
seed n3-bare
for call in "update n3-bare --status deferred" "update n3-bare --status=deferred" "update n3-bare -s deferred" \
  "update n3-bare --defer 2099-01-01" "update n3-bare --defer=2099-01-01" "create bare --id n3-new --force --defer 2099-01-01" \
  "create bare --id n3-new --force --status deferred"; do
  # shellcheck disable=SC2086  # Each call is a word list.
  refused 2 "$WRAPPER" $call
done
refused 2 "$WRAPPER" update n3-bare --status deferred --set-metadata "hold_reason=   "
refused 2 "$WRAPPER" update n3-bare --status deferred --metadata '{"kind":"x"}'
[ "$(row n3-bare 'r["status"]')" = open ] || fail "a refused call must change nothing"
out=$("$WRAPPER" update n3-bare --status deferred 2>&1) ; assert_contains "$out" "needs a reason" "the refusal must name the rule"
"$WRAPPER" update n3-bare --status deferred --defer 2099-01-01T00:00:00Z --set-metadata hold_reason=named >/dev/null 2>&1 || fail "reason in the same call"
refused 2 "$WRAPPER" update n3-bare --unset-metadata hold_reason
refused 2 "$WRAPPER" update n3-bare --set-metadata hold_reason=
same "$(row n3-bare 'm["hold_reason"]')" named "a deferred row must keep its reason"
"$WRAPPER" update n3-bare --unset-metadata hold_reason --status open --defer "" >/dev/null 2>&1 || fail "leaving deferred may drop the reason"

# Past date: a linked decision wakes in bd ready, its work stays stopped, and start works from both forms of a due row.
seed n3-decide n3-work n3-unwoken n3-woken n3-future n3-lane n3-pause
"$WRAPPER" dep add n3-work n3-decide >/dev/null 2>&1 || fail "edge"
write hold n3-decide --reason "captain call" --kind captain --until "$PAST" >/dev/null || fail "past hold"
same "$(row n3-decide 'r["status"]')" deferred "list and show must not wake a row"
same "$(field n3-decide held)" no "a past date must read as no longer held"
in_ready n3-decide || fail "a past date must show in bd ready"
same "$(row n3-decide 'r["status"], r.get("defer_until"), m["hold_reason"], m["hold_kind"]')" "open None captain call captain" "bd ready wakes the row and keeps the hold's fields"
same "$(field n3-decide held)" no "a woken row must read as no longer held"
same "$(field n3-decide hold_kind)" captain "a woken row must stay answerable"
in_ready n3-work && fail "work behind a due decision must stay stopped"
same "$(field n3-work blocked)" yes "the provider must read the work as stopped"
mkdir -p "$T/home/config" "$T/home/data" "$T/home/state"
printf 'beads\n' > "$T/home/config/backlog-backend"
printf '%s\n' "$BEADS_DIR" > "$T/home/config/beads-dir"
assert_contains "$(JG_HOME=$T/home JG_CONFIG_OVERRIDE=$T/home/config JG_DATA_OVERRIDE=$T/home/data JG_STATE_OVERRIDE=$T/home/state "$ROOT/bin/jg-captain-hold.sh" blocking n3-work 2>&1)" n3-decide "a due decision must keep stopping its work"
out=$(write hold n3-decide --reason "captain call" --kind captain) || fail "hold a woken row"
assert_not_contains "$out" "already held" "a woken row is not held"
same "$(row n3-decide 'r["status"]')" on_hold "a woken row can be held again"
write unhold n3-decide >/dev/null || fail "unhold decision"

write hold n3-unwoken --reason "due today" --until "$PAST" >/dev/null || fail "past hold two"
write start n3-unwoken >/dev/null || fail "start from deferred"
same "$(row n3-unwoken 'r["status"], r.get("defer_until")')" "in_progress None" "start must take a due deferred row"
write hold n3-woken --reason "due today" --until "$PAST" >/dev/null || fail "past hold three"
in_ready n3-woken || fail "woken row"
write start n3-woken >/dev/null || fail "start from woken"
same "$(row n3-woken 'r["status"]')" in_progress "start must take a woken row"
write hold n3-future --reason later --until "$FUTURE" >/dev/null || fail "future hold"
refused 13 python3 "$WRITE" start n3-future
same "$(row n3-future 'r["status"]')" deferred "start must refuse a future date"

# A lane held in flight on a date stays in flight across the wake, and start puts it back.
write start n3-lane >/dev/null || fail "start lane"
write hold n3-lane --reason "pause" --until "$PAST" >/dev/null || fail "hold lane"
same "$(field n3-lane state)" in_flight "a held lane must read in flight"
in_ready n3-lane || fail "lane wakes"
same "$(field n3-lane state)" in_flight "a woken lane must read in flight"
write start n3-lane >/dev/null || fail "restart lane"
same "$(row n3-lane 'r["status"]')" in_progress "start must restore a woken lane"
write start n3-pause >/dev/null || fail "start pause"
write hold n3-pause --reason "pause" --until "$PAST" >/dev/null || fail "hold pause"
in_ready n3-pause || fail "pause wakes"
write unhold n3-pause >/dev/null || fail "unhold pause"
same "$(row n3-pause 'r["status"]')" in_progress "unhold must restore a woken lane"
write "done" n3-future >/dev/null || fail "done from deferred"
same "$(row n3-future 'r["status"]')" closed "done must close a deferred row"

# Export and import carry deferred rows, dates, reasons and edges into a fresh store, and check names a row with no reason.
seed n3-carried n3-behind n3-due
"$WRAPPER" dep add n3-behind n3-carried >/dev/null 2>&1 || fail "edge two"
write hold n3-carried --reason "moves whole" --kind captain --until "$FUTURE" >/dev/null || fail "hold carried"
write hold n3-due --reason "moves due" --until "$PAST" >/dev/null || fail "hold due"
"$WRAPPER" check >/dev/null 2>&1 || fail "check on a store whose deferred rows have reasons"
"$WRAPPER" export -o move.jsonl >/dev/null 2>&1 || fail "export"
cp "$T/one/move.jsonl" "$T/two/move.jsonl"
export BEADS_DIR=$T/two/.beads
"$WRAPPER" init --prefix n3 >/dev/null 2>&1 || fail "init two"
"$WRAPPER" import move.jsonl >/dev/null 2>&1 || fail "import"
same "$(row n3-carried 'r["status"], r["defer_until"], m["hold_reason"], m["hold_kind"]')" "deferred ${FUTURE}T00:00:00Z moves whole captain" "import must carry a dated hold"
same "$(row n3-due 'r["status"], r["defer_until"][:10]')" "deferred $PAST" "import must carry a due row unwoken"
in_ready n3-due || fail "an imported due row must wake"
in_ready n3-carried && fail "an imported future date must stay out of bd ready"
in_ready n3-behind && fail "an imported edge must keep work stopped"
"$WRAPPER" check >/dev/null 2>&1 || fail "check after import"
python3 - "$T/two/bad.jsonl" <<'PY' || fail "bad row"
import json, sys
open(sys.argv[1], "w").write(json.dumps({"_type": "issue", "id": "n3-noreason", "title": "t", "status": "deferred", "priority": 2,
    "issue_type": "task", "created_at": "2026-11-07T00:00:00Z", "created_by": "j", "updated_at": "2026-11-07T00:00:00Z",
    "defer_until": "2099-01-01T00:00:00Z"}) + "\n")
PY
"$WRAPPER" import bad.jsonl >/dev/null 2>&1 || fail "import bad"
out=$("$WRAPPER" check 2>&1) && fail "check must refuse a deferred row with no reason"
assert_contains "$out" n3-noreason "check must name the row"

printf 'ok: jg-beads-native-n3\n'
