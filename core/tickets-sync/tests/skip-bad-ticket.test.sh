#!/usr/bin/env bash
# One record the board refuses never stops a pass: the sync names that ticket and its
# source item once, keeps going, and publishes the rest of the home in the same pass.
# Real tasks-axi, the real installer and the real sign-off-axi in an isolated home.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-sync-skip.XXXXXX")
trap 'echo "retained fixture: $work"' EXIT
fork=${JG_TEST_FORK:-$(cd "$root/.." && pwd -P)}
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state}
ln -s "$fork/bin" "$JG_HOME/bin"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
printf '[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=0\n' > "$JG_HOME/.tasks.toml"
(cd "$JG_HOME"
 tasks-axi add good 'Umer good item' --repo alpha --priority 2 >/dev/null
 tasks-axi add bad 'Umer bad item' --repo alpha --priority 2 >/dev/null
 tasks-axi add longhold 'Umer long hold item' --repo alpha --priority 2 >/dev/null
 tasks-axi hold longhold --reason "$(printf 'Umer waits on the store review %.0s' {1..10})" --kind captain >/dev/null)
# The bad item's own record names a PR link sign-off refuses, so its publish is the only one that fails.
printf 'pr=not-a-url\n' > "$JG_HOME/state/bad.meta"
bash "$root/tickets-sync/wiring.sh"
set +e
out=$(env -u JG_HOME "$JG_HOME/state/tickets-sync.check.sh" 2>&1)
status=$?
set -e
printf '%s\n' "$out"
[ "$status" = 0 ] || { echo "FAIL: the pass exited $status instead of carrying on"; exit 1; }
ticket_id() { printf 'jg-%s\n' "$(printf '%s' "$1" | sha256sum | cut -c1-32)"; }
bad=$(ticket_id main/bad) good=$(ticket_id main/good)
# The skip names the ticket once, and names the home and item whose record the owner must fix.
[ "$(grep -cE "^tickets-sync: skipped $bad: main/bad: " <<<"$out")" = 1 ] \
  || { echo "FAIL: expected exactly one skip line naming $bad and main/bad, got: $out"; exit 1; }
grep -qE '^tickets-sync: [0-9]+ homes read; [0-9]+ tickets changed$' <<<"$out" \
  || { echo "FAIL: the pass printed no count line, got: $out"; exit 1; }
# The other item of the same pass reached the board, and the refused one did not.
sign-off-axi ticket "$work/board.json" --id "$good" --json | jq -e '.ticket.title == "Umer good item"'
# A source reason past sign-off's 160-character cap still holds the ticket, shortened the way a title is.
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/longhold)" --json | jq -e '.ticket.hold == true'
held_reason=$(jq -rs --arg id "$(ticket_id main/longhold)" 'map(select(.id == $id)) | last | .hold_reason // ""' "$work/board.tickets.jsonl")
[ -n "$held_reason" ] && [ "${#held_reason}" -le 160 ] \
  || { echo "FAIL: expected the long source reason to reach the board capped at 160, got: $held_reason"; exit 1; }
if sign-off-axi ticket "$work/board.json" --id "$bad" --json >/dev/null 2>&1; then
  echo 'FAIL: the refused ticket must not reach the board'; exit 1
fi
echo 'PASS: one refused ticket is skipped by name and the pass publishes the rest'
