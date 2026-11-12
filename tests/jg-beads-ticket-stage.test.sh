#!/usr/bin/env bash
# Slice J2 on a real Beads store, through the real caller (jg-backlog.sh): the stage rule of section 6.3 gives the stage, sub-state
# and health of a fixture row for every row of its table, and the one adapter verb writes the seven new moments (an event first, then
# an RFC3339 string in UTC on the row) and the three wait keys. The older moments (ready_at, landed_at, ...) belong to jg-q1b3n's
# writers, which are not on this trunk yet, so each fixture lays them with bd directly. The same rows are read by jg-q1b3n's rule
# (section 6.5), held here as a second table, and the two must agree for every row that table already names. JG_BEADS_TEST_BD and
# JG_BEADS_TEST_DOLT name the builds; without them the run skips plainly.
# It also proves the drift check (slice J4, bin/jg-beads-drift.py) through jg-backlog.sh ticket-drift.
# It proves bin/jg-beads-stage.py (the rule), bin/jg-beads-drift.py and bin/jg-beads-moment.py (the writer), the files the changed-test selector maps to it.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

T=$(jg_test_tmproot jg-beads-ticket-stage)
WRAPPER=$ROOT/bin/jg-beads.sh CLI=$ROOT/bin/jg-backlog.sh
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
mkdir -p "$T/store" "$T/home/config" "$T/home/data" "$T/home/state"
export TZ=UTC TMPDIR=$T BEADS_DIR=$T/store/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
printf '%s\n' "$BEADS_DIR" > "$T/home/config/beads-dir"
jail=()
command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --tmpfs /tmp --bind "$T" "$T" --ro-bind "$ROOT" "$ROOT" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)

bd() { "${jail[@]}" "$WRAPPER" "$@"; }
axi() { JG_HOME="$T/home" "${jail[@]}" "$CLI" "$@"; }
row() { bd show "$1" --json 2>/dev/null | jq -c 'if type == "array" then .[0] else . end'; }
count() { bd list --all --limit 0 --json 2>/dev/null | jq length; }
meta() {  # <id> <key=value>...: lay a moment the older writers own (jg-q1b3n S8, S9, S12), as a fixture.
  local id=$1 args=()
  shift
  for kv in "$@"; do args+=(--set-metadata "$kv"); done
  bd update "$id" "${args[@]}" >/dev/null || fail "lay $* on $id"
}
new() { axi add "$1" "[feature] fixture $1" --priority 2 --body why >/dev/null || fail "file $1"; }

# jg-q1b3n section 6.5: the stage of a row by its five working words and the landing words (first match wins).
old_word() {  # <row json>
  jq -r '(.metadata // {}) as $m
    | def after($a; $b): ($a // "") != "" and $a > ($b // "");
      if ($m.released_at // "") != "" then "released"
      elif ($m.reverted_at // "") != "" and (($m.landed_at // "") == "" or $m.reverted_at >= $m.landed_at) then "reverted"
      elif ($m.live_at // "") != "" and (($m.pinned_back_at // "") == "" or after($m.live_at; $m.pinned_back_at)) then "live"
      elif ($m.landed_at // "") != "" then "landed"
      elif .status == "closed" then "done"
      elif .status == "on_hold" or .status == "deferred" then "held"
      elif ($m.ready_at // "") != "" and (($m.resumed_at // "") == "" or after($m.ready_at; $m.resumed_at)) then (if (.external_ref // "") | test("/pull") then "in review" else "ready" end)
      elif .status == "in_progress" then "working"
      else "queued" end' <<<"$1"
}
# Section 6.3, last column: the words of jg-q1b3n that a new reading may stand for.
old_allowed() {  # <new word> -> the old words it replaces
  case $1 in
    building.red) echo reverted ;;
    closed) echo 'done released landed' ;;   # the plan names done and released; jg-q1b3n reads landed first for a closed row that landed
    released) echo released landed ;;
    delivering.joining) echo landed live ;;
    delivering.live) echo live ;;
    delivering.batched) echo landed ;;
    delivering.resolving | delivering.gated | delivering.rebased | delivering.queued | proving.*) echo ready in_review ;;
    building) echo working held ready ;;
    ready | intake) echo queued held ;;
  esac
}

n=0
# check <id> <expected stage[.sub]> <expected health> [agree|differs]: the verb's answer, and jg-q1b3n's word for the same row.
check() {
  local id=$1 want=$2 health=$3 mode=${4:-agree} got r key w ok='' o
  got=$(axi ticket-stage "$id" 2>&1) || fail "ticket-stage $id: $got"
  [ "$got" = "$(printf '%s\t%s' "$want" "$health")" ] || fail "$id: want [$want $health], got [$got]"
  n=$((n + 1))
  r=$(row "$id")
  key=$want
  [ "$health" = red ] && [ "$want" = building ] && key=building.red
  w=$(old_word "$r")
  if [ "$mode" = agree ]; then
    for o in $(old_allowed "$key"); do [ "${o//_/ }" = "$w" ] && ok=1; done
    [ -n "$ok" ] || fail "$id: reads $want, but jg-q1b3n's rule reads [$w] and the table allows [$(old_allowed "$key")]"
  fi
  pass "$id reads $want ($health); jg-q1b3n reads [$w]${mode/agree/}"
}

bd init --prefix jg >"$T/init.log" 2>&1 || fail "init the store: $(cat "$T/init.log")"

t0=2026-11-12T09:00:00Z t1=2026-11-12T09:10:00Z t2=2026-11-12T09:20:00Z t3=2026-11-12T09:30:00Z t4=2026-11-12T09:40:00Z t5=2026-11-12T09:50:00Z t6=2026-11-12T10:00:00Z
pr=https://github.com/example/proj/pull/7

# The three first stages, and a hold while building.
new jg-a1; check jg-a1 intake ok
axi moment jg-a1 approved_at --at $t0 >/dev/null || fail "approved_at"; check jg-a1 ready ok
bd update jg-a1 -s in_progress -a w1 >/dev/null; check jg-a1 building ok
bd update jg-a1 -s on_hold --set-metadata hold_reason=wait >/dev/null; check jg-a1 building ok   # held while building keeps started_at and the assignee
new jg-a2; axi moment jg-a2 approved_at --at $t0 >/dev/null; bd update jg-a2 -s on_hold --set-metadata hold_reason=wait >/dev/null
check jg-a2 ready ok   # a reclaimed row has no started_at and no assignee; held after, it still reads ready

# Proving and the whole of delivering, one moment at a time.
new jg-b1; meta jg-b1 ready_at=$t1; check jg-b1 proving.planned ok
[ "$(axi ticket-stage jg-b1 --proof running)" = "$(printf 'proving.running\tok')" ] || fail "the sub-state is the stage of the proof run"
axi moment jg-b1 proved_at --at $t2 >/dev/null; check jg-b1 delivering.queued ok
axi moment jg-b1 landing_at --at $t3 >/dev/null; check jg-b1 delivering.rebased ok
axi moment jg-b1 gated_at --at $t4 >/dev/null; check jg-b1 delivering.gated ok
axi moment jg-b1 landing_at --at $t5 >/dev/null; check jg-b1 delivering.rebased ok   # a new landing run after the gate
meta jg-b1 conflict_at=$t6
check jg-b1 delivering.resolving ok   # a rebase that met a conflict
new jg-b2; meta jg-b2 ready_at=$t1; axi moment jg-b2 proved_at --at $t2 >/dev/null; axi moment jg-b2 landing_at --at $t3 >/dev/null
axi moment jg-b2 returned_at --at $t4 >/dev/null; check jg-b2 building ok
meta jg-b2 ready_at=$t5; check jg-b2 proving.planned ok   # returned to building, then done again
new jg-b3; meta jg-b3 ready_at=$t1; axi moment jg-b3 bypassed_at --at $t2 >/dev/null; check jg-b3 delivering.queued ok   # a bypass is the proof moment of its try
new jg-b4; meta jg-b4 ready_at=$t1; axi moment jg-b4 proved_at --at $t2 >/dev/null; bd update jg-b4 -s in_progress -a w1 >/dev/null
meta jg-b4 resumed_at=$t3; check jg-b4 building ok   # proved, then working again
meta jg-b4 ready_at=$t4; axi moment jg-b4 proved_at --at $t5 >/dev/null; meta jg-b4 ready_at=$t6; check jg-b4 proving.planned ok   # proved, then a done line with another head

# After the landing: batched, live, joining, released and closed.
new jg-c1; meta jg-c1 ready_at=$t1 landed_at=$t3 commit=abc123; axi moment jg-c1 proved_at --at $t2 >/dev/null; check jg-c1 delivering.batched ok
meta jg-c1 ready_at=$t4; check jg-c1 delivering.batched ok   # a later done line at the landed commit changes nothing
meta jg-c1 live_at=$t5; check jg-c1 delivering.live ok
meta jg-c1 pinned_back_at=$t6; check jg-c1 delivering.batched red   # a home pinned back: the landing stands, and the line is red
new jg-c2; meta jg-c2 landed_at=$t1 commit=abc123 live_at=$t2; axi moment jg-c2 release_opened_at --at $t3 >/dev/null
check jg-c2 delivering.joining ok   # a release opened before the homes moved
new jg-c3; meta jg-c3 landed_at=$t1 "commit="; bd update jg-c3 --external-ref $pr >/dev/null; bd update jg-c3 -s in_progress -a w1 >/dev/null
check jg-c3 released ok; bd update jg-c3 -s closed >/dev/null; check jg-c3 closed ok   # a pull request's merge: released while open, closed after cleanup
new jg-c4; meta jg-c4 landed_at=$t1 released_at=$t1 commit=abc123; bd update jg-c4 -s in_progress -a w1 >/dev/null
check jg-c4 released ok; bd update jg-c4 -s closed >/dev/null; check jg-c4 closed ok   # a local landing of a project that publishes nothing
new jg-c5; meta jg-c5 landed_at=$t1 commit=abc123; bd update jg-c5 -s in_progress -a w1 >/dev/null; bd update jg-c5 -s closed >/dev/null
check jg-c5 delivering.batched ok   # closed at cleanup, but not on main yet
new jg-c6; bd update jg-c6 -s closed >/dev/null; check jg-c6 closed ok   # a row that never landed

# A revert.
new jg-d1; meta jg-d1 ready_at=$t1 landed_at=$t2 commit=abc123 reverted_at=$t3; bd update jg-d1 -s in_progress -a w1 >/dev/null
check jg-d1 building red
meta jg-d1 ready_at=$t4; check jg-d1 proving.planned ok differs   # reverted, then done again: a new try, which jg-q1b3n's rule does not read
new jg-d2; meta jg-d2 ready_at=$t1 landed_at=$t2 commit=abc123; bd update jg-d2 -s in_progress -a w1 >/dev/null; bd update jg-d2 -s closed >/dev/null
meta jg-d2 reverted_at=2099-01-01T00:00:00Z; check jg-d2 building red   # closed at cleanup, and then reverted
new jg-d3; meta jg-d3 ready_at=2020-01-01T00:00:01Z landed_at=2020-01-01T00:00:02Z reverted_at=2020-01-01T00:00:03Z; bd update jg-d3 -s in_progress -a w1 >/dev/null; bd update jg-d3 -s closed >/dev/null
check jg-d3 closed ok differs   # dropped after the revert: closed_at is later than the revert, and jg-q1b3n's rule reads reverted

# Every word the rule printed is a word of its enum.
for w in intake ready building proving delivering released closed; do grep -q "^$w	" "$ROOT/core/machines/ticket.states" || fail "$w is not a stage"; done
pass "$n rows read as the rule table says"

# The writer: an event first, then an RFC3339 string in UTC, and a moment only moves forward.
new jg-w1
before=$(count)
out=$(axi moment jg-w1 gated_at --at 2026-11-12T10:00:00+01:00) || fail "moment with an offset: $out"
[ "$(row jg-w1 | jq -r .metadata.gated_at)" = 2026-11-12T09:00:00Z ] || fail "the stored moment must be UTC, got [$(row jg-w1 | jq -r .metadata.gated_at)]"
ev=$(bd provenance log jg-w1 --json | jq -r '[.[] | select(.source == "jg-trunk-gate")] | map(.occurred_at) | join(",")')
[ "$ev" = 2026-11-12T09:00:00Z ] || fail "the event must carry the same time as the row, got [$ev]"
axi moment jg-w1 gated_at --at 2026-11-12T09:00:00Z >/dev/null || fail "a second write of the same moment"
[ "$(bd provenance log jg-w1 --json | jq length)" = 1 ] || fail "a second write of the same moment must add no second event"
axi moment jg-w1 gated_at --at 2026-11-12T09:30:00+01:00 >/dev/null && fail "a zone-time that is earlier in UTC must be refused, however late it reads"
axi moment jg-w1 gated_at --at 2026-11-12T09:59:59Z >/dev/null || fail "a later moment replaces the older"
a=$(row jg-w1 | jq -r .metadata.gated_at)
[ "$a" = 2026-11-12T09:59:59Z ] && [ "$a" \> 2026-11-12T09:00:00Z ] || fail "two moments must compare as text in time order, got [$a]"
rc=0; axi moment jg-w1 gated_at --at 2026-11-12T09:30:00Z >/dev/null || rc=$?
[ "$rc" != 0 ] && [ "$(row jg-w1 | jq -r .metadata.gated_at)" = 2026-11-12T09:59:59Z ] || fail "a moment moved back must be refused and leave the row"
axi moment jg-w1 returned_at --at $t1 --returned-to proving >/dev/null || fail "returned_at with returned_to"
[ "$(row jg-w1 | jq -r '.metadata.returned_to')" = proving ] || fail "returned_to must be written with returned_at"
axi moment jg-w1 landed_at >/dev/null 2>&1 && fail "only the six new moments are written by this verb"
pass "the writer records the event first, keeps UTC text, and never moves a moment back"

# A wait: three keys in one write, no child row, no stage word, no hold_kind.
before=$(count)
axi wait jg-w1 owner decision >/dev/null || fail "wait"
[ "$(row jg-w1 | jq -r '[.metadata.wait, .metadata.wait_reason, (.metadata.wait_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$") | tostring)] | join(",")')" = owner,decision,true ] || fail "the wait keys: $(row jg-w1 | jq -c .metadata)"
[ "$(count)" = "$before" ] || fail "a wait must add no child row ($before rows, then $(count))"
[ "$(bd children jg-w1 --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)" = 0 ] || fail "a wait must leave the ticket with no child"
row jg-w1 | jq -e '.metadata | has("stage") or has("hold_kind")' >/dev/null && fail "no stage word and no hold_kind are written"
axi wait jg-w1 none >/dev/null || fail "ending a wait"
[ "$(row jg-w1 | jq -r '.metadata.wait + "|" + .metadata.wait_reason')" = "none|" ] || fail "a wait ends by writing none"
axi wait jg-w1 nobody decision >/dev/null && fail "a who outside the closed list must be refused"
axi wait jg-w1 owner whim >/dev/null && fail "a reason outside the closed list must be refused"
axi wait jg-w1 lead >/dev/null && fail "a wait with no reason must be refused"
pass "a wait writes three keys in one update and adds no child row"

# Drift (slice J4): the row and the records outside Beads differ. The trunk's landing record is a fixture file in the home's data folder;
# the forge is a stub gh on PATH. A row that agrees prints nothing; each difference prints one line and the row's health reads lost.
drift() { axi ticket-drift "$@" 2>&1; }
printf 'jg-e1\tproj\tabc1234567890def\t1\tfast\njg-e2\tproj\tfeed1234567890\t2\tfast\nrevert-jg-e3\tproj\tbeef12345678\t3\tfast\njg-e3\tproj\tbeef12345678\t1\tfast\n' > "$T/home/data/trunk-landings.tsv"
new jg-e1; new jg-e2; new jg-e3; new jg-e4
meta jg-e2 landed_at=$t1 commit=feed123
meta jg-e3 ready_at=$t1
out=$(drift jg-e1); n_lines=$(grep -c . <<<"$out")
[ "$n_lines" = 1 ] && [ "$out" = "$(printf 'drift\tjg-e1\tlost\tthe trunk landed commit abc123456789 and the row has no landed_at')" ] || fail "a landed commit with no landed_at must print one drift line, got [$out]"
[ -z "$(drift jg-e2)" ] || fail "a row that agrees with the landing record must print no drift line: $(drift jg-e2)"
[ -z "$(drift jg-e3)" ] || fail "a landing taken back (a revert row) is not drift: $(drift jg-e3)"
[ -z "$(drift jg-e4)" ] || fail "a row with no landing record must print no drift line: $(drift jg-e4)"
[ "$(row jg-e1 | jq -c '.metadata | has("landed_at")')" = false ] || fail "the observer must not write a moment"
pass "a landed commit with no landed_at prints one drift line, and a row that agrees prints none"
mkdir -p "$T/bin"
# shellcheck disable=SC2016  # the stub's text expands when the stub runs
printf '#!/bin/sh\nprintf "state=MERGED\\nmerged=%%s\\n" "${FAKE_MERGED:-true}"\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"
new jg-f1; bd update jg-f1 --external-ref $pr >/dev/null; bd update jg-f1 -s in_progress -a w1 >/dev/null
[ -z "$(drift jg-f1)" ] || fail "the forge is read only with --forge"
out=$(PATH="$T/bin:$PATH" drift jg-f1 --forge)
[ "$out" = "$(printf 'drift\tjg-f1\tlost\tpull request %s is merged and the row is in_progress' "$pr")" ] || fail "a merged pull request on an open row must print one drift line, got [$out]"
[ -z "$(FAKE_MERGED=false PATH="$T/bin:$PATH" drift jg-f1 --forge)" ] || fail "an open pull request is not drift"
meta jg-f1 released_at=$t2; [ -z "$(PATH="$T/bin:$PATH" drift jg-f1 --forge)" ] || fail "a released row agrees with a merged pull request"
pass "a merged pull request on an open row prints one drift line"

# The time of one write.
out=$(axi moment jg-w1 approved_at) || fail "timed write: $out"
secs=$(sed -n 's/.*(\([0-9.]*\) s)$/\1/p' <<<"$out")
printf '# one moment write (an event, then the row): %s\n' "$out"
if [ -z "$secs" ] || ! awk -v s="$secs" 'BEGIN { exit !(s < 1) }'; then fail "one write must take under 1 s, got [$out]"; fi
pass "jg-beads ticket stage"
