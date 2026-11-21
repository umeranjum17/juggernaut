#!/usr/bin/env bash
# The ticket adapter (bin/jg-ticket-adapter.py), driven the way the board drives it: one JSON request on stdin per call, on a
# throwaway home's tickets tables. It proves the ticket is the row as the tables hold it (id, status, assignee, parent as
# bin/jg-beads-read.py shows them), a list leaves closed rows out, an update is a patch that keeps a label written beside it, a write by
# hand moves the rev and so gives a conflict, a repeated op_id writes once, history names the actor and the changed fields, and a failed
# read is an error. It also runs the interface's own conformance script (tests/ticket-adapter-conformance/) unmodified and through its
# documented order-insensitive exception, with tests/fixtures/ticket-adapter/faults.sh as the tables' faults driver.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/ticket-adapter.log")
ADAPTER="$ROOT/bin/jg-ticket-adapter.py" FIX="$ROOT/tests/fixtures/ticket-adapter" T=$(jg_test_tmproot jg-ticket-adapter)
# The single-store half reads one throwaway home flat, as `bd show` would, never the fleet of the home it runs in.
mkdir -p "$T/real/config" "$T/real/state" "$T/real/data"
export JG_HOME=$T/real JG_TICKET_ADAPTER_FLAT=1

# call <op> <json body>: the adapter's answer on stdout; its exit status is kept in $rc.
call() { out=$(printf '%s' "$2" | "$ADAPTER" "$1"); rc=$?; }
# pick <python expression over d>: a value of the last answer.
pick() { printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
expect() { [ "$(pick "$1")" = "$2" ] || fail "$3: wanted $2 from $1, got $(pick "$1") in $out"; }
bd_() { python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" "$@" 2>/dev/null; }

parent=$(bd_ q "the parent")
call create "{\"interface\":1,\"op_id\":\"c1\",\"ticket\":{\"title\":\"Write it\",\"body\":\"Two lines.\",\"kind\":\"feature\",\"assignee\":\"Umer\",\"labels\":[\"alpha\",\"beta\"],\"parent\":\"$parent\",\"extra\":{\"legacy-ref\":\"L-17\"}}}"
[ "$rc" = 0 ] || fail "create: $out"
id=$(pick 'd["ticket"]["id"]')
expect 'd["ticket"]["status"]' open "create: the row's own status word, no invented stage"
expect 'd["ticket"]["parent"]' "$parent" "create: the parent is the row's"
expect 'd["ticket"]["assignee"]' Umer "create: the assignee is the row's"
expect 'sorted(d["ticket"].keys()) == sorted(["id","rev","title","body","kind","status","assignee","labels","parent","links","created_at","updated_at","extra"])' True "create: only the record's fields"
row_show=$("$ROOT/bin/jg-beads-read.py" show "$id")
[ "$(printf '%s' "$row_show" | python3 -c 'import json,sys; r=json.load(sys.stdin)[0]; print(r["status"], r["assignee"], r["parent"], r["issue_type"], r["description"])')" = "open Umer $parent feature Two lines." ] || fail "the tables do not hold what the adapter answered: $row_show"

# a closed row is left out of list; an open one is in it
gone=$(bd_ q "closed soon"); "$ROOT/bin/jg-backlog.sh" 'done' "$gone" >/dev/null 2>&1 || fail "close a row"
call list '{"interface":1}'
expect "'$id' in [t['id'] for t in d['tickets']] and '$gone' not in [t['id'] for t in d['tickets']] and d['complete']" True "list: open rows in, closed rows out"

# a patch changes what it names; a label only bd put there survives it; a write by hand moves the rev and gives a conflict
call get "{\"interface\":1,\"id\":\"$id\"}"; rev=$(pick 'd["ticket"]["rev"]')
bd_ update "$id" --add-label by-hand >/dev/null
call update "{\"interface\":1,\"id\":\"$id\",\"rev\":\"$rev\",\"op_id\":\"u0\",\"set\":{\"title\":\"Stale\"}}"
[ "$rc" = 1 ] && [ "$(pick 'd["error"]["code"]')" = conflict ] || fail "a label written by hand must make the rev stale: $out"
expect 'sorted(d["error"]["detail"]["current"]["labels"])' "['alpha', 'beta', 'by-hand']" "conflict carries the current ticket"
rev=$(pick 'd["error"]["detail"]["current"]["rev"]')
call update "{\"interface\":1,\"id\":\"$id\",\"rev\":\"$rev\",\"op_id\":\"u1\",\"set\":{\"status\":\"in_progress\",\"assignee\":null,\"labels\":[\"alpha\",\"by-hand\"]}}"
[ "$rc" = 0 ] || fail "update: $out"
expect '(d["ticket"]["status"], d["ticket"]["assignee"], d["ticket"]["labels"], d["ticket"]["title"], d["ticket"]["extra"])' "('in_progress', None, ['alpha', 'by-hand'], 'Write it', {'legacy-ref': 'L-17'})" "update: only the named fields moved"
first=$out
# the same op_id again writes nothing and answers the first result; the same op_id for another edit is refused
call update "{\"interface\":1,\"id\":\"$id\",\"rev\":\"$rev\",\"op_id\":\"u1\",\"set\":{\"status\":\"in_progress\",\"assignee\":null,\"labels\":[\"alpha\",\"by-hand\"]}}"
[ "$out" = "$first" ] || fail "a repeated op_id must answer the first result: $out"
call update "{\"interface\":1,\"id\":\"$id\",\"rev\":\"$rev\",\"op_id\":\"u1\",\"set\":{\"title\":\"Other\"}}"
expect 'd["error"]["detail"]["fields"][0]["field"]' op_id "a reused op_id is invalid"
call create '{"interface":1,"op_id":"c1","ticket":{"title":"Write it","body":"Two lines.","kind":"feature","assignee":"Umer","labels":["alpha","beta"],"parent":"'"$parent"'","extra":{"legacy-ref":"L-17"}}}'
expect 'd["ticket"]["id"]' "$id" "a repeated create answers its first ticket"
call list '{"interface":1}'
expect "len([t for t in d['tickets'] if t['title'] == 'Write it'])" 1 "a repeated create made no second ticket"

# a bad word is refused with the field named, before bd runs
call update "{\"interface\":1,\"id\":\"$id\",\"rev\":\"$(pick 'd["tickets"][0]["rev"]')\",\"op_id\":\"u2\",\"set\":{\"status\":\"stage-9\"}}"
expect 'd["error"]["detail"]["fields"][0]["field"]' status "an unknown status is invalid"

# history: bd's event log with the actor and the changed fields, and the comment, oldest first
call comment "{\"interface\":1,\"id\":\"$id\",\"text\":\"Needs a shot.\",\"op_id\":\"m1\"}"
[ "$rc" = 0 ] || fail "comment: $out"
cid=$(pick 'd["event"]["id"]')
call history "{\"interface\":1,\"id\":\"$id\"}"
expect "[e['type'] for e in d['events']][0]" created "history starts at the creation"
expect "any(e['id'] == '$cid' and e['text'] == 'Needs a shot.' for e in d['events'])" True "history holds the comment"
expect "any(c['field'] == 'status' and c['from'] == 'open' and c['to'] == 'in_progress' for e in d['events'] for c in e['changes'])" True "history names the field change"
expect "all(e['actor'] for e in d['events'])" True "every event has an actor"

# a store that cannot be read is an error, never an empty list
"$FIX/faults.sh" unreadable; call list '{"interface":1}'; "$FIX/faults.sh" none
[ "$rc" = 1 ] && [ "$(pick 'd["error"]["code"]')" = unavailable ] || fail "an unreadable store must be unavailable: $out"

# the interface's own script: unmodified it passes 16 of 18 (check 2 reads the key order of extra, which the tables sort; check 18 needs a
# list read in part, which the tables, read in one query, never give, so faults.sh refuses partial); with the documented exception 17 of 18
CONF=$ROOT/tests/ticket-adapter-conformance
if command -v node >/dev/null 2>&1; then
  mkdir -p "$T/conf/config" "$T/conf/state" "$T/conf/data"
  conf() { JG_HOME=$T/conf node "$@" "$ADAPTER" --throwaway --faults "$FIX/faults.sh"; }
  conf "$CONF/run-order-insensitive.mjs" >"$T/conformance-exception.log" 2>&1
  if ! grep -q '^# 17 passed, 1 failed' "$T/conformance-exception.log" || ! grep -q '^not ok 18 - incomplete' "$T/conformance-exception.log"; then
    fail "the exception run must fail only check 18: $(cat "$T/conformance-exception.log")"
  fi
  conf "$CONF/test/ticket-adapter-conformance.mjs" >"$T/conformance-shipped.log" 2>&1
  if ! grep -q '^# 16 passed, 2 failed' "$T/conformance-shipped.log" || ! grep -q '^not ok 2 - create' "$T/conformance-shipped.log" \
      || ! grep -q '^not ok 18 - incomplete' "$T/conformance-shipped.log"; then
    fail "the shipped script must fail only checks 2 and 18: $(cat "$T/conformance-shipped.log")"
  fi
  [ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || cp "$T/conformance-shipped.log" "$T/conformance-exception.log" "$DONE_DONE_EVIDENCE_ROOT/"
else
  printf 'skip: conformance script: node is not installed\n'
fi
pass "ticket adapter: the row's own words, patch edits, op_id replay, history, failed reads"

# The same executable as the board, over a main home and a local lead home whose rows share the main home's fleet.db.
unset JG_TICKET_ADAPTER_FLAT
mkdir -p "$T/fleet/main/config" "$T/fleet/main/data" "$T/fleet/main/state" "$T/fleet/lead/config" "$T/fleet/lead/state" "$T/fleet/lead/data"
printf 'lead\n' > "$T/fleet/lead/.jg-squad-lead-home"
printf 'parent_home=%s\n' "$T/fleet/main" > "$T/fleet/lead/.jg-squad-lead-parent"
printf '%s\n' "- lead - fixture (home: $T/fleet/lead; scope: test)" > "$T/fleet/main/data/squad_leads.md"
a() { JG_HOME=$T/fleet/main bd_ "$@"; }
b() { JG_HOME=$T/fleet/lead bd_ "$@"; }
waiting=$(a q 'Waiting')
next=$(a q 'Ready')
working=$(b q 'Building')
closed=$(b q 'Finished')
gate=$(a create --title 'Pick' --type gate --silent)
a dep add "$waiting" "$gate" --type blocks >/dev/null || fail 'link gate'
a update "$waiting" --add-label project:alpha >/dev/null || fail 'label waiting'
a update "$next" --add-label project:alpha >/dev/null || fail 'label next'
b update "$working" --add-label project:beta >/dev/null || fail 'label working'
b update "$closed" --add-label project:beta >/dev/null || fail 'label closed'
JG_HOME=$T/fleet/lead "$ROOT/bin/jg-backlog.sh" 'done' "$closed" >/dev/null 2>&1 || fail 'close'
printf 'window=fixture\n' > "$T/fleet/lead/state/$working.meta"
printf 'working [at=1]: building\n' > "$T/fleet/lead/state/$working.status"
export JG_HOME=$T/fleet/main
call describe '{"interface":1}'
expect '[f for f in d["fields"] if f["name"] == "status"][0]["values"] == [{"value": x, "label": x} for x in ["Waiting for you", "Next up", "Being built", "Done"]]' True 'fleet describe columns'
expect 'any(f["name"] == "project" and f["readonly"] for f in d["fields"])' True 'fleet describe project'
call list '{"interface":1}'
[ "$rc" = 0 ] || fail "fleet list: $out"
expect 'len(d["tickets"]) + ("next_cursor" in d)' 4 'a client that names no limit gets the whole fleet in one page'
listed_rev=$(pick "[t['rev'] for t in d['tickets'] if t['id'] == 'lead--$working'][0]")
expect "{t['title']: (t['status'], t['project']) for t in d['tickets']} == {'Building': ('Being built', 'beta'), 'Finished': ('Done', 'beta'), 'Ready': ('Next up', 'alpha'), 'Waiting': ('Waiting for you', 'alpha')}" True 'fleet columns and projects'
expect "all(t['id'].startswith(('main--','lead--')) for t in d['tickets'])" True 'fleet ids name their store'
call get "{\"interface\":1,\"id\":\"lead--$working\"}"
expect 'd["ticket"]["project"]' beta 'fleet get routes to lead'
rev=$(pick 'd["ticket"]["rev"]')
[ "$rev" = "$listed_rev" ] || fail "a ticket listed with rev $listed_rev must be got with the same rev, got $rev"
call update "{\"interface\":1,\"id\":\"lead--$working\",\"rev\":\"$rev\",\"op_id\":\"fleet-edit\",\"set\":{\"title\":\"Building changed\"}}"
expect 'd["ticket"]["title"]' 'Building changed' 'fleet write routes to lead'
[ "$(JG_HOME=$T/fleet/lead "$ROOT/bin/jg-beads-read.py" show "$working" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["title"])')" = 'Building changed' ] || fail 'write reached the wrong home'
call update "{\"interface\":1,\"id\":\"lead--$working\",\"rev\":\"$rev\",\"op_id\":\"fleet-status\",\"set\":{\"status\":\"Done\"}}"
expect 'd["error"]["code"]' invalid 'derived status is read only'
call list '{"interface":1,"limit":1}'
cursor=$(pick 'd["next_cursor"]')
call list "{\"interface\":1,\"limit\":1,\"cursor\":\"$cursor\"}"
expect 'len(d["tickets"])' 1 'fleet cursor returns the next page'
printf '%s\n' "- gone - fixture (home: $T/fleet/gone; scope: test)" >> "$T/fleet/main/data/squad_leads.md"
call list '{"interface":1}'
[ "$rc" = 1 ] || fail 'a home whose tables cannot be read must not return an incomplete fleet'
expect 'd["error"]["code"]' unavailable 'the failed home is visible'
unset JG_HOME
pass 'fleet adapter: two homes, four factual columns, projects, one rev for list and get, routing, pagination and failure'
