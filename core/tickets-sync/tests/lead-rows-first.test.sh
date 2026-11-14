#!/usr/bin/env bash
# A ticket a lead home mints reaches the board in the parent's next poll, whatever else the poll still owes.
# The poll works inside a time budget and walks the fleet from a cursor. On the fleet it spent each budget correcting
# thousands of old finished rows (a project or a priority they never got), so a ticket minted in the muxr, sign-off
# or second-mate lead home waited behind them for days and the board never showed it. A row the board does not hold
# at all is published first, before the cursor walk resumes; the walk then goes on from where it stood.
# This files three finished rows in main whose board tickets still say queued, and a new row in a lead home, then runs
# the parent's poll with a budget of one row per pass: real jg-backlog.sh on Beads stores, the installed poll and
# real sign-off-axi, in isolated homes.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-lead-first.XXXXXX")
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
in_home() { (cd "$1" && shift && JG_HOME=$PWD "$@" >/dev/null); }
state() {
  local out
  out=$(sign-off-axi ticket "$board" --id "$1" --json 2>/dev/null) || { echo 'no ticket'; return; }
  jq -r '.ticket.state // "no ticket"' <<<"$out"
}

# Finished rows in main that the board still shows queued: each one costs the poll a write.
old=(main-old-1 main-old-2 main-old-3)
for item in "${old[@]}"; do
  in_home "$main" jg-backlog.sh add "$item" "Umer main work $item" --repo alpha
  in_home "$main" jg-backlog.sh 'done' "$item"
  sign-off-axi ticket "$board" --id "$(hash "main/$item")" --title "Umer main work $item" --progress 0 --state queued --stage queued \
    --description "Umer main work $item" >/dev/null
done
in_home "$lead" jg-backlog.sh add lead-new 'Umer lead work minted today' --repo alpha
for home in "$main" "$lead"; do JG_HOME=$home bash "$root/tickets-sync/wiring.sh" >/dev/null; done

fail=0
# One row per pass: a pass handles the row it resumed on and stops before the next.
export JG_TICKETS_SYNC_BUDGET_SECS=0
poll() { env -u JG_HOME "$main/state/tickets-sync.check.sh" >> "$work/poll.out"; }

poll
[ "$(state "$(hash lead-a/lead-new)")" = queued ] \
  || { echo "FAIL: the lead's new ticket is $(state "$(hash lead-a/lead-new)") on the board after the parent's first poll, which spent its budget on main's old rows: $(cat "$work/poll.out")"; fail=1; }

# The cursor now stands inside main's rows; a ticket the lead mints next still publishes in the very next poll.
in_home "$lead" jg-backlog.sh add lead-later 'Umer lead work minted later' --repo alpha
poll
[ "$(state "$(hash lead-a/lead-later)")" = queued ] \
  || { echo "FAIL: the lead's second ticket is $(state "$(hash lead-a/lead-later)") on the board with the cursor part-way through main's rows"; fail=1; }

# Going first costs the old rows nothing: the walk goes on and every one of them reaches its row's state.
for _ in $(seq 8); do poll; done
for item in "${old[@]}"; do
  [ "$(state "$(hash "main/$item")")" = "done" ] || { echo "FAIL: main's finished row $item is still $(state "$(hash "main/$item")") on the board"; fail=1; }
done
# The poll published each row as <lead>/<item> once and never as a main twin.
for twin in "$(hash main/lead-new)" "$(hash main/lead-later)"; do
  [ "$(state "$twin")" = 'no ticket' ] || { echo "FAIL: the poll published twin ticket $twin beside the lead's own"; fail=1; }
done
[ "$fail" = 0 ] || exit 1
echo "PASS: the lead's new tickets reached the board in the next poll while ${#old[@]} older rows still waited, and the walk finished them"
