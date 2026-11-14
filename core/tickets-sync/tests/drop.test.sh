#!/usr/bin/env bash
# The drop of every pre-Beads open ticket on a real Beads store (captain, 11 Nov): `sync.py --drop-pre-beads DATE` plans and
# changes nothing; `--apply` closes each open row filed before DATE with the note "dropped by captain 11 Nov" and each board
# ticket no row answers to; an owner ask, a captain hold and a row filed on or after DATE stay open; a second run finds nothing.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-drop.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fork=${JG_TEST_FORK:-$(cd "$root/.." && pwd -P)}
export HOME=$work/user XDG_DATA_HOME=$work/xdg JG_HOME=$work/main
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
mkdir -p "$HOME" "$JG_HOME"/{data,config,state/tickets-sync}
ln -sn "$fork/bin" "$JG_HOME/bin"
ln -sn "$fork/core" "$JG_HOME/core"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
# shellcheck source=core/lib/beads-test-env.sh disable=SC1091
. "$root/lib/beads-test-env.sh"
core_beads_home "$fork" "$JG_HOME"
(cd "$JG_HOME"
 jg-backlog.sh add jg-old-a 'Umer old idea one' --repo alpha --priority 2 >/dev/null
 jg-backlog.sh add jg-old-b 'Umer old idea two' --repo alpha --priority 0 >/dev/null
 jg-backlog.sh add jg-ask '[captain-ask] Umer asks for a thing' --repo alpha --priority 0 --body 'type: captain-ask: "Umer wants this thing done soon"' >/dev/null
 jg-backlog.sh add jg-held 'Umer call waiting on him' --repo alpha --priority 1 >/dev/null
 bash bin/jg-captain-hold.sh hold jg-held --reason 'Umer must pick' >/dev/null)
sign-off-axi ticket "$work/board.json" --id jg-00000000000000000000000000000000 --title 'Umer old board-only ticket' --description 'Left from the old board.' >/dev/null
sign-off-axi ticket "$work/board.json" --id jg-11111111111111111111111111111111 --title 'Umer asked ticket' --description 'His own ask.' --asked yes >/dev/null

drop() { python3 "$root/tickets-sync/sync.py" --drop-pre-beads "$@"; }
tomorrow=$(date -u -d '+1 day' +%F); today=$(date -u +%F)
open_ids() { (cd "$JG_HOME" && jg-backlog.sh list --limit 100 | grep -o 'jg-[a-z-]*' | sort -u | tr '\n' ' '); }
before=$(open_ids)

plan=$(drop "$tomorrow")
printf '%s\n' "$plan"
case $plan in
  *'6 open before, 3 after; would drop 2 rows and 1 board-only tickets; kept 3 owner decisions, 0 with a waiting card, 0 with a live worker, 0 undated; 0 filed on or after'*) ;;
  *) echo 'FAIL: the plan line does not count the tickets as the order reads them'; exit 1 ;;
esac
[ "$(open_ids)" = "$before" ] || { echo 'FAIL: the plan changed a row'; exit 1; }
echo 'PASS: the plan counts every open ticket and changes nothing'

today_plan=$(drop "$today")
case $today_plan in
  *'dropped 0 rows and 1 board-only'*|*'would drop 0 rows and 1 board-only tickets'*'4 filed on or after'*) ;;
  *) echo 'FAIL: rows filed on the cut date were counted as before it'; exit 1 ;;
esac
echo 'PASS: a row filed on the cut date is not dropped'

applied=$(drop "$tomorrow" --apply)
printf '%s\n' "$applied"
case $applied in
  *'6 open before, 3 after; dropped 2 rows and 1 board-only tickets; kept 3 owner decisions'*) ;;
  *) echo 'FAIL: the applied line does not match the plan'; exit 1 ;;
esac
shown() { (cd "$JG_HOME" && jg-backlog.sh show "$1"); }
for id in jg-old-a jg-old-b; do
  shown "$id" | grep -q 'state: done'
  shown "$id" | grep -q 'dropped by captain 11 Nov'
done
shown jg-ask | grep -q 'state: queued'
shown jg-held | grep -q 'held: yes'
shown jg-held | grep -q 'state: queued'
board=$(sign-off-axi ticket "$work/board.json" --json)
printf '%s' "$board" | jq -e '.tickets[] | select(.id=="jg-00000000000000000000000000000000") | .state=="done"' >/dev/null
printf '%s' "$board" | jq -e '.tickets[] | select(.id=="jg-11111111111111111111111111111111") | .state!="done"' >/dev/null
grep -q '^kept-owner: main/.*jg-ask\|^kept-owner: main/jg-ask' "$JG_HOME"/state/tickets-sync/drop-pre-beads-*.txt
echo 'PASS: --apply closes each old row with the note and the board-only ticket, and keeps the ask, the hold and the asked ticket'

again=$(drop "$tomorrow" --apply)
printf '%s\n' "$again"
case $again in
  *'3 open before, 3 after; dropped 0 rows and 0 board-only tickets'*) ;;
  *) echo 'FAIL: a second run found something more to drop'; exit 1 ;;
esac
echo 'PASS: a second run has nothing left to drop'
