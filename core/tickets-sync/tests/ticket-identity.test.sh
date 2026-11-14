#!/usr/bin/env bash
# Every ticket the board holds for a row gets that row's state, from one writer. After the Beads cut the stale check
# reported 942 fleet tickets as "ticket says no state": the cut kept each migrated row's board ticket id as its store
# id, and the sync hashed that id again into a ticket the board never had, so the real ticket was never written. Lead
# homes ran the poll on the shared board too, under the name main, so their rows got main/<item> twins, their step
# writes missed, their stale check called every other home's ticket unaccounted, and sign-off's warnings about
# answers to archived cards stood in for the real refusal ("orphaned answers"). This files rows as the cut left them in
# main and new rows in a lead, with a lead store holding an open copy of a main row, then runs the installed checks:
# real jg-backlog.sh on Beads stores, real sign-off-axi, isolated homes.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-identity.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fork=${JG_TEST_FORK:-$(cd "$root/.." && pwd -P)}
[ -f "$fork/bin/jg-backlog.sh" ] || { echo "FAIL: $fork is not a Juggernaut checkout (no bin/jg-backlog.sh); set JG_TEST_FORK"; exit 1; }
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
main=$work/main lead=$work/lead board=$work/board.json
mkdir -p "$HOME"
printf '{"schema":2,"items":[]}\n' > "$board"
# shellcheck source=core/lib/beads-test-env.sh disable=SC1091
. "$root/lib/beads-test-env.sh"
for home in "$main" "$lead"; do
  mkdir -p "$home"/{data,config,state}
  ln -sn "$fork/bin" "$home/bin"; ln -sn "$fork/core" "$home/core"
  printf '%s\n' "$board" > "$home/config/fleet-board"
  core_beads_home "$fork" "$home"
done
printf 'lead-a\n' > "$lead/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$main" > "$lead/.jg-squad-lead-parent"
printf -- '- lead-a - Umer lead (home: %s; charter: data/charter.md)\n' "$lead" > "$main/data/squad_leads.md"
hash() { printf 'jg-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-32)"; }
done_id=jg-0123456789abcdef0123456789abcd01 open_id=jg-0123456789abcdef0123456789abcd02 held_hex=0123456789abcdef0123456789abcd03
in_home() { (cd "$1" && shift && JG_HOME=$PWD "$@" >/dev/null); }
in_home "$main" jg-backlog.sh add "$done_id" 'Umer migrated work that finished' --repo alpha
in_home "$main" jg-backlog.sh 'done' "$done_id"
in_home "$main" jg-backlog.sh add "$open_id" 'Umer migrated work still queued' --repo alpha
in_home "$main" jg-backlog.sh add "fm-$held_hex" 'Umer migrated work on hold' --repo alpha
in_home "$main" jg-backlog.sh hold "fm-$held_hex" --reason 'Umer waits on the store review' --kind captain
in_home "$lead" jg-backlog.sh add lead-done 'Umer lead work that finished' --repo alpha
in_home "$lead" jg-backlog.sh 'done' lead-done
in_home "$lead" jg-backlog.sh add lead-queued 'Umer lead work still queued' --repo alpha
in_home "$lead" jg-backlog.sh add lead-held 'Umer lead work on hold' --repo alpha
in_home "$lead" jg-backlog.sh hold lead-held --reason 'Umer waits on a sign-in' --kind captain
# The lead's store also took an open copy of main's finished row, as one home's store did at the cut.
in_home "$lead" jg-backlog.sh add "$done_id" 'Umer migrated work that finished' --repo alpha
# The board as the old sync left it: the migrated tickets carry no state, the lead's tickets the wrong one.
ticket() { sign-off-axi ticket "$board" --id "$1" --title "$2" --progress 0 --description "$2" "${@:3}" >/dev/null; }
ticket "$done_id" 'Umer migrated work that finished'
ticket "$open_id" 'Umer migrated work still queued'
ticket "jg-$held_hex" 'Umer migrated work on hold'
ticket "$(hash lead-a/lead-done)" 'Umer lead work that finished' --state 'in progress' --stage building
ticket "$(hash lead-a/lead-queued)" 'Umer lead work still queued'
ticket "$(hash lead-a/lead-held)" 'Umer lead work on hold' --state queued --stage queued
# An answer to a card that has left the board: sign-off names it on stderr at every read.
printf '{"key":"gone-card","answer":"yes","label":"Yes","close":"done","at":"2026-10-01T00:00:00Z"}\n' > "$work/board.answers.jsonl"
for home in "$main" "$lead"; do JG_HOME=$home bash "$root/tickets-sync/wiring.sh" >/dev/null; done
fail=0
state() { sign-off-axi ticket "$board" --id "$1" --json 2>/dev/null | jq -r '.ticket.state // "no state"'; }
exists() { sign-off-axi ticket "$board" --id "$1" --json >/dev/null 2>&1; }
env -u JG_HOME "$main/state/tickets-stale.check.sh" > "$work/stale-before.out"
before=$(grep -c . "$work/stale-before.out" || true)
[ "$before" -ge 6 ] || { echo "FAIL: the seeded board should disagree on six tickets, the check printed: $(cat "$work/stale-before.out")"; fail=1; }

# The lead runs no poll, check or clean-up of its own on the shared board: it prints nothing and writes nothing.
snapshot() { cat "$work"/board.json "$work"/board.*.jsonl 2>/dev/null | sha256sum; }
was=$(snapshot)
for check in tickets-sync tickets-stale tickets-cleanup; do
  out=$(env -u JG_HOME "$lead/state/$check.check.sh" 2>&1)
  [ -z "$out" ] || { echo "FAIL: the lead's $check check spoke on the shared board: $out"; fail=1; }
done
[ "$(snapshot)" = "$was" ] || { echo "FAIL: the lead's checks wrote the shared board"; fail=1; }

# One run of main's poll gives every disagreeing ticket of every home the state of its row.
env -u JG_HOME "$main/state/tickets-sync.check.sh" > "$work/sync.out"
for want in "$done_id=done" "$open_id=queued" "jg-$held_hex=on hold" "$(hash lead-a/lead-done)=done" \
    "$(hash lead-a/lead-queued)=queued" "$(hash lead-a/lead-held)=on hold"; do
  got=$(state "${want%%=*}")
  [ "$got" = "${want#*=}" ] || { echo "FAIL: ticket ${want%%=*} says $got, its row says ${want#*=}"; fail=1; }
done
for twin in "$(hash "main/$done_id")" "$(hash "main/$open_id")" "$(hash "lead-a/$done_id")" "$(hash main/lead-queued)"; do
  ! exists "$twin" || { echo "FAIL: the poll published twin ticket $twin beside the row's own"; fail=1; }
done
env -u JG_HOME "$main/state/tickets-stale.check.sh" > "$work/stale-after.out"
[ ! -s "$work/stale-after.out" ] || { echo "FAIL: the stale check still reports a true board: $(cat "$work/stale-after.out")"; fail=1; }

# A lead's step writer names the same ticket the poll publishes, so starting work shows on the board at once.
in_home "$lead" jg-backlog.sh start lead-queued
[ "$(state "$(hash lead-a/lead-queued)")" = 'in progress' ] || { echo "FAIL: starting lead-queued did not reach its ticket"; fail=1; }
# A second poll keeps main's finished row done: the lead's open copy never takes its ticket.
env -u JG_HOME "$main/state/tickets-sync.check.sh" >> "$work/sync.out"
[ "$(state "$done_id")" = 'done' ] || { echo "FAIL: the lead's open copy reopened main's finished ticket"; fail=1; }

# Every lead once posted the day's clean-up card on the shared board too, so a second writer found the day's key and
# its fallback taken and failed each minute. The failure names sign-off's refusal, never the warning about an archived
# answer that every read of this board prints. Each pass flags one more held row and clears the day, standing in for
# that second home's different card.
for n in 1 2 3; do
  in_home "$main" jg-backlog.sh add "umer-ask-$n" "Umer ask $n waits" --repo alpha
  in_home "$main" jg-backlog.sh hold "umer-ask-$n" --reason "Umer decides ask $n" --kind captain
  rm -f "$main/state/tickets-sync/cleanup.day"
  out=$(env -u JG_HOME "$main/state/tickets-cleanup.check.sh" 2>&1) || true
done
if ! grep -q 'already holds a different message' <<<"$out" || grep -q 'left out the answer' <<<"$out"; then
  echo "FAIL: a refused clean-up card should be named with sign-off's refusal, got: $out"; fail=1
fi
[ "$fail" = 0 ] || exit 1
echo "PASS: the stale check went from $before lines to none; every ticket took its row's state from main's one poll, and the lead wrote nothing"
