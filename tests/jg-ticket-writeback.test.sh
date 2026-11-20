#!/usr/bin/env bash
# A Beads-backed home keeps its tickets in the Beads store: the board reads that row directly, so a backlog
# transition has no board mirror to write, publish or verify. This test drives the operator's own
# bin/jg-backlog.sh path, the lifecycle transition library, the captain hold path and the merge path on a
# real Beads backlog and shows that the Beads status moves while the board file, its ticket feed and
# sign-off-axi are never touched, even where a poll script and a board pointer are present.
# shellcheck source=tests/lib.sh
#
# This is also the test that owns journeys/tickets-writeback.sh (the done-done journey drives the same script),
# so the changed-test map selects it for a change to that journey.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work=$(jg_test_tmproot jg-ticket-writeback) || exit 1
home="$work/home"
mkdir -p "$home"/{data,config,state} "$work/user"
# shellcheck source=core/lib/beads-test-env.sh
. "$ROOT/core/lib/beads-test-env.sh"
core_beads_home "$ROOT" "$home"
board="$work/board.json"
printf '{"schema":2,"items":[]}\n' > "$board"
printf '%s\n' "$board" > "$home/config/fleet-board"
# The poll script is reachable, so only the Beads-backed guard stands between a transition and the board.
export JG_HOME="$home" HOME="$work/user" XDG_DATA_HOME="$work/xdg" JG_TICKETS_SYNC="$ROOT/core/tickets-sync/sync.py"
export JG_TICKETS_TICKET="$ROOT/core/tickets-sync/ticket.py"

# A sign-off-axi that records every call: no transition may reach the board tool at all, so the proof does not
# depend on which sign-off-axi the host has installed.
fakebin=$(jg_fakebin "$work/fakebin") || fail 'fake bin was not built'
calls="$work/sign-off-calls"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 1\n' "$calls" > "$fakebin/sign-off-axi"
chmod +x "$fakebin/sign-off-axi"
PATH="$fakebin:$PATH"; export PATH

feed="$board.tickets.jsonl"
board_sum() { sha256sum "$board" "$feed" 2>/dev/null; }
no_board_write() {  # <before sum> <what>
  assert_equals "$1" "$(board_sum)" "$2 must write nothing to the board"
  [ ! -e "$calls" ] || fail "$2 called sign-off-axi: $(cat "$calls")"
}
bd_status() { BEADS_DIR=$(cat "$home/config/beads-dir") bash "$ROOT/bin/jg-beads.sh" show "$1" --json 2>/dev/null | jq -r 'if type == "array" then .[0] else . end | .status'; }

(cd "$home" && jg-backlog.sh add jg-shipone 'Ship the first thing' --repo demo --priority 1 --body 'release: c-2' >/dev/null
 jg-backlog.sh add jg-shiptwo 'Ship the second thing' --repo demo --priority 1 >/dev/null
 jg-backlog.sh add jg-heldone '[captain-ask] Pick the colour' --repo demo --priority 0 >/dev/null) || fail 'fixture backlog was not written'
before=$(board_sum)
no_board_write "$before" 'adding rows'

# 1. The operator's own command: every transition moves the Beads status and writes nothing to the board,
# `done --pr` included.
out=$(bash "$ROOT/bin/jg-backlog.sh" start jg-shipone 2>&1) || fail "start failed: $out"
assert_equals in_progress "$(bd_status jg-shipone)" 'bd must show the started status'
no_board_write "$before" 'start'
out=$(bash "$ROOT/bin/jg-backlog.sh" hold jg-shipone --reason 'waiting on the colour pick' 2>&1) || fail "hold failed: $out"
assert_equals on_hold "$(bd_status jg-shipone)" 'bd must show the held status'
no_board_write "$before" 'hold'
out=$(bash "$ROOT/bin/jg-backlog.sh" unhold jg-shipone 2>&1) || fail "unhold failed: $out"
no_board_write "$before" 'unhold'
out=$(bash "$ROOT/bin/jg-backlog.sh" start jg-shipone 2>&1) || fail "second start failed: $out"
assert_equals in_progress "$(bd_status jg-shipone)" 'bd must show the started status again'
out=$(bash "$ROOT/bin/jg-backlog.sh" "done" jg-shipone --pr https://github.com/example/demo/pull/31 2>&1) || fail "done failed: $out"
assert_equals closed "$(bd_status jg-shipone)" 'bd must show the done row closed'
assert_not_contains "$out" 'mirror is behind' 'a Beads-backed home has no mirror to be behind'
no_board_write "$before" 'done'
out=$(bash "$ROOT/bin/jg-backlog.sh" reopen jg-shipone 2>&1) || fail "reopen failed: $out"
assert_equals open "$(bd_status jg-shipone)" 'bd must show the reopened status'
no_board_write "$before" 'reopen'
pass 'start, hold, unhold, done and reopen move the Beads status and write nothing to the board'

# 2. The lifecycle transition library, which spawn, teardown and bootstrap use, writes nothing either.
out=$(bash -c '
  set -u
  . "$1/bin/jg-backlog-lib.sh"
  . "$1/bin/jg-backlog-transition-lib.sh"
  jg_backlog_start "$JG_HOME/data" jg-shiptwo || exit 1
  jg_backlog_ticket_note "$JG_HOME/data" start jg-shiptwo || exit 1
  jg_backlog_ticket_note "$JG_HOME/data" hold jg-shiptwo --reason "the captain is choosing between two designs" || exit 1
  jg_backlog_ticket_note "$JG_HOME/data" unhold jg-shiptwo || exit 1
  jg_backlog_ticket_publish "$JG_HOME/data" "done" jg-shiptwo || exit 1
' _ "$ROOT" 2>&1) || fail "the transition library failed: $out"
assert_equals in_progress "$(bd_status jg-shiptwo)" 'the library start must move the Beads status'
no_board_write "$before" 'the transition library'
pass 'the lifecycle transition library writes nothing to the board'

# 3. A captain hold writes no board state either; the Beads status carries it.
printf 'held\n' > "$home/config/parked-homes"
bash "$ROOT/bin/jg-captain-hold.sh" hold jg-heldone --reason 'pick a colour' >/dev/null 2>&1 || true
rm -f "$home/config/parked-homes"
no_board_write "$before" 'a captain hold'
pass 'a captain hold leaves the board to its own read of the store'

# 4. A home with no board writes nothing and still succeeds, so a board problem can never fail a transition.
noBoard="$work/no-board"
mkdir -p "$noBoard"/{data,config,state}
core_beads_home "$ROOT" "$noBoard"
(cd "$noBoard" && JG_HOME="$noBoard" jg-backlog.sh add jg-lonely 'Ship without a board' --repo demo --priority 2 >/dev/null)
out=$(JG_HOME="$noBoard" bash "$ROOT/bin/jg-backlog.sh" start jg-lonely 2>&1) || fail "a boardless home failed its transition: $out"
no_board_write "$before" 'a boardless home'
pass 'a home with no board stays a silent no-op'

# 5. The merge path: the one call every self-merge and every detected merge makes records the outcome and
# leaves the board alone.
(cd "$home" && jg-backlog.sh add jg-merged 'Ship the merged thing' --repo demo --priority 1 >/dev/null
 jg-backlog.sh start jg-merged >/dev/null)
url='https://github.com/example/demo/pull/33'
out=$(bash -c '. "$1/bin/jg-merge-outcome-lib.sh"; jg_merge_outcome_report "$2" "$2/state" jg-merged "$3" poll' _ "$ROOT" "$home" "$url" 2>&1) || fail "the merge path failed: $out"
no_board_write "$before" 'the merge path'
pass 'the merge path writes nothing to the board'

# 6. A lead and a board the tool cannot reach: the backlog write succeeds and says nothing about a mirror,
# because there is none to be behind.
printf 'lead-a\n' > "$home/.jg-squad-lead-home"
out=$(bash "$ROOT/bin/jg-backlog.sh" add jg-lead 'Lead work' --repo demo --priority 1 2>&1) || fail "lead add failed: $out"
rm "$home/.jg-squad-lead-home"
assert_not_contains "$out" 'parent poll publishes' 'a Beads-backed lead has no board publication to wait for'
out=$(bash "$ROOT/bin/jg-backlog.sh" add jg-mirrortwo 'Mirror the backlog while down' --repo demo --priority 1 2>&1) \
  || fail "an unreachable board failed the backlog write: $out"
assert_not_contains "$out" 'mirror is behind' 'a Beads-backed home has no mirror to be behind'
assert_contains "$(cd "$home" && jg-backlog.sh list 2>&1)" 'jg-mirrortwo' 'the backlog write must stand when the board is down'
no_board_write "$before" 'a lead and an unreachable board'
pass 'an unreachable board never touches a backlog write'
