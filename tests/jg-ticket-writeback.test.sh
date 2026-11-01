#!/usr/bin/env bash
# A backlog transition writes its ticket in the same step, so the fleet board
# follows the work instead of waiting for the tickets-sync poll: the operator's
# own bin/jg-tasks-axi.sh path, the lifecycle transition library, and the captain
# hold/release/close path. Real tasks-axi and real sign-off-axi on a disposable
# board; the poll never runs, so nothing but the transition can move a ticket.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo 'skip - tasks-axi is not installed'; exit 0; }
command -v sign-off-axi >/dev/null 2>&1 || { echo 'skip - sign-off-axi is not installed'; exit 0; }

work=$(jg_test_tmproot jg-ticket-writeback) || exit 1
home="$work/home"
mkdir -p "$home"/{data,config,state} "$work/user"
board="$work/board.json"
printf '{"schema":2,"items":[]}\n' > "$board"
printf '%s\n' "$board" > "$home/config/fleet-board"
printf '[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=10\n' > "$home/.tasks.toml"
export JG_HOME="$home" HOME="$work/user" XDG_DATA_HOME="$work/xdg" SIGN_OFF_HOME="$work/signoff"
export JG_TICKETS_TICKET="$ROOT/core/tickets-sync/ticket.py"

ticket_id() { printf 'jg-%s\n' "$(printf 'main/%s' "$1" | sha256sum | cut -c1-32)"; }
ticket_field() {  # <id> <jq path>
  sign-off-axi ticket "$board" --id "$1" --json | jq -r ".ticket.$2"
}
publish() {  # <task>: the poll's own ticket creation, so the writer has a row to correct
  local id
  id=$(ticket_id "$1")
  sign-off-axi ticket "$board" --id "$id" --title "Ticket for $1" --progress 0 --state queued --stage queued >/dev/null
}

(cd "$home" && tasks-axi add shipone 'Ship the first thing' --repo demo --priority 1 --body 'release: c-2' >/dev/null
 tasks-axi add shiptwo 'Ship the second thing' --repo demo --priority 1 >/dev/null
 tasks-axi add heldone '[captain-ask] Pick the colour' --repo demo --priority 0 >/dev/null) || fail 'fixture backlog was not written'
publish shipone
publish shiptwo
publish heldone

# 1. The operator's own command: `start` builds, `done --pr` closes with the delivered PR.
out=$(bash "$ROOT/bin/jg-tasks-axi.sh" start shipone 2>&1) || fail "start failed: $out"
assert_equals 'in progress' "$(ticket_field "$(ticket_id shipone)" state)" 'start must mark the ticket in progress'
assert_equals building "$(ticket_field "$(ticket_id shipone)" stage)" 'start must move the ticket to building'
out=$(bash "$ROOT/bin/jg-tasks-axi.sh" "done" shipone --pr https://github.com/example/demo/pull/31 2>&1) || fail "done failed: $out"
assert_equals "done" "$(ticket_field "$(ticket_id shipone)" state)" 'done must close the ticket'
assert_equals 100 "$(ticket_field "$(ticket_id shipone)" progress)" 'done must record 100%'
assert_equals 'https://github.com/example/demo/pull/31' "$(sign-off-axi ticket "$board" --id "$(ticket_id shipone)" --json | jq -r '.ticket.prs[0]')" 'done must link the delivered PR'
pass 'a backlog start and done write the ticket with no poll'

# 2. The lifecycle transition library, which spawn, teardown and bootstrap use.
# shellcheck source=/dev/null
out=$(bash -c '
  set -u
  . "$1/bin/jg-tasks-axi-lib.sh"
  . "$1/bin/jg-backlog-transition-lib.sh"
  jg_backlog_start "$JG_HOME/data" shiptwo || exit 1
  jg_backlog_ticket_note "$JG_HOME/data" hold shiptwo --reason "the captain is choosing between two designs" || exit 1
' _ "$ROOT" 2>&1) || fail "the transition library failed: $out"
assert_equals building "$(ticket_field "$(ticket_id shiptwo)" stage)" 'the lifecycle start must move the ticket to building'
assert_equals 'on hold' "$(ticket_field "$(ticket_id shiptwo)" state)" 'a hold must put the ticket on hold'
assert_equals true "$(ticket_field "$(ticket_id shiptwo)" hold)" 'a hold must mark the ticket held'
assert_equals 'the captain is choosing between two designs' "$(ticket_field "$(ticket_id shiptwo)" hold_reason)" 'a hold must carry its reason'
bash -c '
  set -u
  . "$1/bin/jg-tasks-axi-lib.sh"
  . "$1/bin/jg-backlog-transition-lib.sh"
  jg_backlog_ticket_note "$JG_HOME/data" unhold shiptwo
' _ "$ROOT" >/dev/null 2>&1 || fail 'the release path failed'
assert_equals queued "$(ticket_field "$(ticket_id shiptwo)" state)" 'a release must return the ticket to queued'
assert_equals false "$(ticket_field "$(ticket_id shiptwo)" hold)" 'a release must clear the hold'
pass 'the lifecycle transition library writes its ticket state, hold and release'

# 3. A captain-held row closed by an answer closes its ticket too.
printf 'held\n' > "$home/config/parked-homes"
bash "$ROOT/bin/jg-captain-hold.sh" hold heldone --reason 'pick a colour' >/dev/null 2>&1 || true
assert_equals 'on hold' "$(ticket_field "$(ticket_id heldone)" state)" 'a captain hold must put the ticket on hold'
rm -f "$home/config/parked-homes"
pass 'a captain hold writes the ticket it holds'

# 4. A home with no board writes nothing and still succeeds, so a board problem
# can never fail a transition.
noBoard="$work/no-board"
mkdir -p "$noBoard"/{data,config,state}
cp "$home/.tasks.toml" "$noBoard/.tasks.toml"
(cd "$noBoard" && tasks-axi add lonely 'Ship without a board' --repo demo --priority 2 >/dev/null)
feed="$work/board.tickets.jsonl"
before=$(sha256sum "$feed")
out=$(JG_HOME="$noBoard" bash "$ROOT/bin/jg-tasks-axi.sh" start lonely 2>&1) || fail "a boardless home failed its transition: $out"
assert_equals "$before" "$(sha256sum "$feed")" 'a boardless home must leave every board alone'
sign-off-axi ticket "$board" --id "$(ticket_id lonely)" --json > "$work/lonely.json" 2>&1 || true
assert_contains "$(cat "$work/lonely.json")" 'NOT_FOUND' 'a boardless home must not create a ticket'
pass 'a home with no board stays a silent no-op'

# 5. The merge path: the one call every self-merge and every detected merge makes
# records the delivered PR and closes the ticket, with no poll in the picture.
(cd "$home" && tasks-axi add merged 'Ship the merged thing' --repo demo --priority 1 >/dev/null
 tasks-axi start merged >/dev/null)
publish merged
url='https://github.com/example/demo/pull/33'
out=$(bash -c '. "$1/bin/jg-merge-outcome-lib.sh"; jg_merge_outcome_report "$2" "$2/state" merged "$3" poll' _ "$ROOT" "$home" "$url" 2>&1) || fail "the merge path failed: $out"
assert_equals "done" "$(ticket_field "$(ticket_id merged)" state)" 'the merge path must close the ticket'
assert_equals "done" "$(ticket_field "$(ticket_id merged)" stage)" 'the merge path must move the ticket to done'
assert_equals "$url" "$(sign-off-axi ticket "$board" --id "$(ticket_id merged)" --json | jq -r '.ticket.prs[0]')" \
  'the merge path must link the delivered PR'
pass 'the merge path closes the ticket with the delivered PR'
