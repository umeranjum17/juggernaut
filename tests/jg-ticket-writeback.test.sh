#!/usr/bin/env bash
# A backlog transition writes its ticket in the same step, so the fleet board
# follows the work instead of waiting for the tickets-sync poll: the operator's
# own bin/jg-backlog.sh path, the lifecycle transition library, and the captain
# hold/release/close path. Real the backlog and real sign-off-axi on a disposable
# board; the poll never runs, so nothing but the transition can move a ticket.
# shellcheck source=tests/lib.sh
#
# This is also the test that owns journeys/tickets-writeback.sh (the done-done journey drives the same script),
# so the changed-test map selects it for a change to that journey.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sign-off-axi >/dev/null 2>&1 || { echo 'skip - sign-off-axi is not installed'; exit 0; }

work=$(jg_test_tmproot jg-ticket-writeback) || exit 1
home="$work/home"
mkdir -p "$home"/{data,config,state} "$work/user"
# shellcheck source=core/lib/beads-test-env.sh
. "$ROOT/core/lib/beads-test-env.sh"
core_beads_home "$ROOT" "$home"
board="$work/board.json"
printf '{"schema":2,"items":[]}\n' > "$board"
printf '%s\n' "$board" > "$home/config/fleet-board"
export JG_HOME="$home" HOME="$work/user" XDG_DATA_HOME="$work/xdg" SIGN_OFF_HOME="$work/signoff"
export JG_TICKETS_TICKET="$ROOT/core/tickets-sync/ticket.py"

ticket_id() { printf 'jg-%s\n' "$(printf 'main/%s' "$1" | sha256sum | cut -c1-32)"; }
ticket_field() {  # <id> <jq path>
  sign-off-axi ticket "$board" --id "$1" --json | jq -r ".ticket.$2"
}
publish() {  # <task>: the poll's own ticket creation, so the writer has a row to correct
  local id
  id=$(ticket_id "$1")
  # A new ticket needs its own description (sign-off-axi refuses one without), as the poll gives it.
  sign-off-axi ticket "$board" --id "$id" --title "Ticket for $1" --progress 0 --state queued \
    --description "$(printf 'Ticket for %s.\n# Ask\n- Show the work on the board.\n# Why\n- The board follows the work.\n# Done when\n- The ticket reads done.' "$1")" >/dev/null
}

(cd "$home" && jg-backlog.sh add jg-shipone 'Ship the first thing' --repo demo --priority 1 --body 'release: c-2' >/dev/null
 jg-backlog.sh add jg-shiptwo 'Ship the second thing' --repo demo --priority 1 >/dev/null
 jg-backlog.sh add jg-heldone '[captain-ask] Pick the colour' --repo demo --priority 0 >/dev/null) || fail 'fixture backlog was not written'
publish jg-shipone
publish jg-shiptwo
publish jg-heldone

# 1. The operator's own command: start, hold and reopen write nothing to the board (no stage, no state, no
# board-only key) while the Beads status moves; `done --pr` closes the ticket with the delivered PR.
feed="$work/board.tickets.jsonl"
board_sum() { sha256sum "$board" "$feed" 2>/dev/null; }
bd_status() { BEADS_DIR=$(cat "$home/config/beads-dir") bash "$ROOT/bin/jg-beads.sh" show "$1" --json 2>/dev/null | jq -r 'if type == "array" then .[0] else . end | .status'; }
before=$(board_sum)
out=$(bash "$ROOT/bin/jg-backlog.sh" start jg-shipone 2>&1) || fail "start failed: $out"
assert_equals "$before" "$(board_sum)" 'start must write nothing to the board'
out=$(bash "$ROOT/bin/jg-backlog.sh" hold jg-shipone --reason 'waiting on the colour pick' 2>&1) || fail "hold failed: $out"
assert_equals "$before" "$(board_sum)" 'hold must write nothing to the board'
assert_equals on_hold "$(bd_status jg-shipone)" 'bd must show the held status'
out=$(bash "$ROOT/bin/jg-backlog.sh" unhold jg-shipone 2>&1) || fail "unhold failed: $out"
assert_equals "$before" "$(board_sum)" 'unhold must write nothing to the board'
assert_equals queued "$(ticket_field "$(ticket_id jg-shipone)" state)" 'the board state must stay what the poll published'
assert_equals null "$(ticket_field "$(ticket_id jg-shipone)" stage)" 'no stage may be written for the ticket'
assert_not_contains "$(cat "$feed" 2>/dev/null)" '"stage"' 'no stage may reach the board feed'
assert_not_contains "$(cat "$feed" 2>/dev/null)" 'last_event_at' 'no last event time may reach the board feed'
out=$(bash "$ROOT/bin/jg-backlog.sh" start jg-shipone 2>&1) || fail "second start failed: $out"
assert_equals in_progress "$(bd_status jg-shipone)" 'bd must show the started status'
out=$(bash "$ROOT/bin/jg-backlog.sh" "done" jg-shipone --pr https://github.com/example/demo/pull/31 2>&1) || fail "done failed: $out"
assert_equals "done" "$(ticket_field "$(ticket_id jg-shipone)" state)" 'done must close the ticket'
assert_equals 100 "$(ticket_field "$(ticket_id jg-shipone)" progress)" 'done must record 100%'
assert_equals 'https://github.com/example/demo/pull/31' "$(sign-off-axi ticket "$board" --id "$(ticket_id jg-shipone)" --json | jq -r '.ticket.prs[0]')" 'done must link the delivered PR'
before=$(board_sum)
out=$(bash "$ROOT/bin/jg-backlog.sh" reopen jg-shipone 2>&1) || fail "reopen failed: $out"
assert_equals "$before" "$(board_sum)" 'reopen must write nothing to the board'
assert_equals open "$(bd_status jg-shipone)" 'bd must show the reopened status'
pass 'start, hold and reopen write no stage or state; done closes the ticket with its PR'

# 2. The lifecycle transition library, which spawn, teardown and bootstrap use, writes nothing for start, hold and unhold.
before=$(board_sum)
out=$(bash -c '
  set -u
  . "$1/bin/jg-backlog-lib.sh"
  . "$1/bin/jg-backlog-transition-lib.sh"
  jg_backlog_start "$JG_HOME/data" jg-shiptwo || exit 1
  jg_backlog_ticket_note "$JG_HOME/data" start jg-shiptwo || exit 1
  jg_backlog_ticket_note "$JG_HOME/data" hold jg-shiptwo --reason "the captain is choosing between two designs" || exit 1
  jg_backlog_ticket_note "$JG_HOME/data" unhold jg-shiptwo || exit 1
' _ "$ROOT" 2>&1) || fail "the transition library failed: $out"
assert_equals "$before" "$(board_sum)" 'start, hold and unhold must write nothing to the board'
assert_equals null "$(ticket_field "$(ticket_id jg-shiptwo)" hold)" 'no hold may be written for the ticket'
pass 'the lifecycle transition library writes no stage, state or hold'

# 3. A captain hold writes no board state either; the Beads status carries it.
printf 'held\n' > "$home/config/parked-homes"
bash "$ROOT/bin/jg-captain-hold.sh" hold jg-heldone --reason 'pick a colour' >/dev/null 2>&1 || true
assert_equals queued "$(ticket_field "$(ticket_id jg-heldone)" state)" 'a captain hold must not write a board state'
rm -f "$home/config/parked-homes"
pass 'a captain hold leaves the board state to the poll'

# 4. A home with no board writes nothing and still succeeds, so a board problem
# can never fail a transition.
noBoard="$work/no-board"
mkdir -p "$noBoard"/{data,config,state}
core_beads_home "$ROOT" "$noBoard"
(cd "$noBoard" && JG_HOME="$noBoard" jg-backlog.sh add jg-lonely 'Ship without a board' --repo demo --priority 2 >/dev/null)
before=$(sha256sum "$feed")
out=$(JG_HOME="$noBoard" bash "$ROOT/bin/jg-backlog.sh" start jg-lonely 2>&1) || fail "a boardless home failed its transition: $out"
assert_equals "$before" "$(sha256sum "$feed")" 'a boardless home must leave every board alone'
sign-off-axi ticket "$board" --id "$(ticket_id jg-lonely)" --json > "$work/jg-lonely.json" 2>&1 || true
assert_contains "$(cat "$work/jg-lonely.json")" 'NOT_FOUND' 'a boardless home must not create a ticket'
pass 'a home with no board stays a silent no-op'

# 5. The merge path: the one call every self-merge and every detected merge makes
# records the delivered PR and closes the ticket, with no poll in the picture.
(cd "$home" && jg-backlog.sh add jg-merged 'Ship the merged thing' --repo demo --priority 1 >/dev/null
 jg-backlog.sh start jg-merged >/dev/null)
publish jg-merged
url='https://github.com/example/demo/pull/33'
out=$(bash -c '. "$1/bin/jg-merge-outcome-lib.sh"; jg_merge_outcome_report "$2" "$2/state" jg-merged "$3" poll' _ "$ROOT" "$home" "$url" 2>&1) || fail "the merge path failed: $out"
assert_equals "done" "$(ticket_field "$(ticket_id jg-merged)" state)" 'the merge path must close the ticket'
assert_equals "$url" "$(sign-off-axi ticket "$board" --id "$(ticket_id jg-merged)" --json | jq -r '.ticket.prs[0]')" \
  'the merge path must link the delivered PR'
pass 'the merge path closes the ticket with the delivered PR'

# 6. The backlog and the board are one list: an added row appears on the board and a
# done row follows with no sync run by hand, syncing twice leaves one card, and a
# board that cannot be reached never fails the backlog write but says it is behind.
export JG_TICKETS_SYNC="$ROOT/core/tickets-sync/sync.py"
mirror="$work/mirror"
mkdir -p "$mirror"/{data,config,state}
core_beads_home "$ROOT" "$mirror"
ln -sn "$ROOT/bin" "$mirror/bin"
mboard="$work/mirror-board.json"
printf '{"schema":2,"items":[]}\n' > "$mboard"
printf '%s\n' "$mboard" > "$mirror/config/fleet-board"
count_cards() { sign-off-axi ticket "$mboard" --json | jq '[.tickets[] | select(.title | contains("Mirror the backlog"))] | length'; }
mid=$(printf 'jg-%s' "$(printf 'main/jg-mirrorone' | sha256sum | cut -c1-32)")
out=$(JG_HOME="$mirror" bash "$ROOT/bin/jg-backlog.sh" add jg-mirrorone 'Mirror the backlog' --repo demo --priority 1 2>&1) || fail "add failed: $out"
assert_not_contains "$out" 'mirror is behind' 'a reachable board must not report the mirror behind'
assert_equals 1 "$(count_cards)" 'an added ticket must appear on the board with no sync run by hand'
assert_equals queued "$(sign-off-axi ticket "$mboard" --id "$mid" --json | jq -r .ticket.state)" 'an added ticket must show as queued'
out=$(JG_HOME="$mirror" bash "$ROOT/bin/jg-backlog.sh" "done" jg-mirrorone 2>&1) || fail "done failed: $out"
assert_equals "done" "$(sign-off-axi ticket "$mboard" --id "$mid" --json | jq -r .ticket.state)" 'a done ticket must show done on the board'
JG_HOME="$mirror" python3 "$JG_TICKETS_SYNC" >/dev/null 2>&1 || fail 'the first explicit sync failed'
JG_HOME="$mirror" python3 "$JG_TICKETS_SYNC" >/dev/null 2>&1 || fail 'the second explicit sync failed'
assert_equals 1 "$(count_cards)" 'syncing twice must leave one card'
assert_equals "done" "$(sign-off-axi ticket "$mboard" --id "$mid" --json | jq -r .ticket.state)" 'syncing must not bounce a done ticket'
pass 'an added and a done ticket reach the board with no sync run by hand, once'

# A lead does not run its own poll; its parent owns publication.
printf 'lead-a\n' > "$mirror/.jg-squad-lead-home"
out=$(JG_HOME="$mirror" bash "$ROOT/bin/jg-backlog.sh" add jg-lead 'Lead work' --repo demo --priority 1 2>&1) || fail "lead add failed: $out"
assert_contains "$out" 'parent poll publishes' 'a lead must name the parent poll'
assert_not_contains "$out" 'mirror is behind' 'a lead must not claim its expected wait is a fault'
rm "$mirror/.jg-squad-lead-home"
pass 'a lead names the parent poll as publisher'

# A board the writer cannot reach: the backlog write still succeeds and says so.
fakebin=$(jg_fakebin "$work/fakebin-down") || fail 'fake bin was not built'
printf '#!/bin/sh\necho "board unreachable" >&2\nexit 1\n' > "$fakebin/sign-off-axi"
chmod +x "$fakebin/sign-off-axi"
err=$(PATH="$fakebin:$PATH" JG_HOME="$mirror" bash "$ROOT/bin/jg-backlog.sh" add jg-mirrortwo 'Mirror the backlog while down' --repo demo --priority 1 2>&1 >/dev/null) \
  || fail "an unreachable board failed the backlog write: $err"
assert_contains "$err" 'board mirror is behind' 'an unreachable board must be reported, not hidden'
assert_contains "$(cd "$mirror" && JG_HOME="$mirror" jg-backlog.sh list 2>&1)" 'jg-mirrortwo' 'the backlog write must stand when the board is down'
pass 'an unreachable board keeps the backlog write and says the mirror is behind'
