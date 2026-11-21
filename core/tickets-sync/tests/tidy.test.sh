#!/usr/bin/env bash
# The fleet backlog tidy on the home's tickets tables: `sync.py --tidy` plans the captain's clean-up rules over every open row and
# changes nothing; `--tidy --apply` closes with a named reason (its PR merged, its change landed on the trunk, an earlier row
# with the same title), defers a row idle for 14 days that nothing gives an owner or value (held with the reason, never
# closed), and never touches a captain ask. A duplicate closes with a `duplicates` link and the idle rows come from the tables' last-touched times;
# an old owner question (a gate row) is never named. A second run finds nothing left to do.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-tidy.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fork=${JG_TEST_FORK:-$(cd "$root/.." && pwd -P)}
export HOME=$work/user XDG_DATA_HOME=$work/xdg JG_HOME=$work/main
export SIGN_OFF_TICKETS_ADAPTER=$work/main/bin/jg-ticket-adapter.py   # as the installed check names it (wiring.sh)
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
mkdir -p "$HOME" "$JG_HOME"/{data/jg-trunk-landing,config,state/tickets-sync}
ln -sn "$fork/bin" "$JG_HOME/bin"
ln -sn "$fork/core" "$JG_HOME/core"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
# A fixture home on the tickets tables (fleet.db).
core_tables_home() {  # <checkout> <home>
  mkdir -p "$2/config" "$2/data" && : > "$2/config/backlog-intake-loose"
  case ":$PATH:" in *":$1/bin:"*) ;; *) PATH=$1/bin:$PATH; export PATH ;; esac
  JG_HOME=$2 python3 -I "$1/core/item-store/adapters/tickets.py" import --home main /dev/null >/dev/null
}
core_tables_home "$fork" "$JG_HOME"
merged=https://github.com/example/alpha/pull/7
(cd "$JG_HOME"
 jg-backlog.sh add jg-dup-a 'Umer same title row' --repo alpha --priority 1 >/dev/null
 jg-backlog.sh add jg-dup-b 'Umer same title row' --repo alpha --priority 2 >/dev/null
 jg-backlog.sh add jg-merged 'Umer work whose PR merged' --repo alpha --priority 1 --body "pr: $merged" >/dev/null
 jg-backlog.sh add jg-landed 'Umer work landed on the trunk' --repo alpha --priority 1 >/dev/null
 jg-backlog.sh add jg-idle 'Umer idea nobody picked up' --repo alpha --priority 2 >/dev/null
 jg-backlog.sh add jg-wanted 'Umer urgent idea' --repo alpha --priority 0 >/dev/null
 jg-backlog.sh add jg-ask '[captain-ask] Umer asks for a thing' --repo alpha --priority 0 --body 'type: captain-ask: "Umer wants this thing done soon"' >/dev/null)
printf '{"%s":{"merged":true,"state":"closed","draft":false,"at":1}}\n' "$merged" > "$JG_HOME/state/tickets-sync/prs.json"
# A lane the lander finished: its status says done, its landing record says landed, and the trunk holds its commit.
printf 'mode=local-trunk\n' > "$JG_HOME/state/jg-landed.meta"
printf 'done [at=1700000000]: ready in branch fix/jg-landed\n' > "$JG_HOME/state/jg-landed.status"
printf 'landed\n' > "$JG_HOME/data/jg-trunk-landing/jg-landed.0000000000000000000000000000000000000001.state"
printf 'jg-landed\talpha\t38f1eed7e0000000000000000000000000000000\t1700000000\tfull\n' > "$JG_HOME/data/trunk-landings.tsv"

# Every row (and an owner question, a gate row) is made 20 days idle in the tables themselves.
bdx() { python3 -I "$fork/core/item-store/adapters/bd_compat.py" "$@"; }
gate=$(bdx gate create --blocks jg-dup-a --type human --title 'Umer asks which way' --json | jq -r '.id // .gate.id // .[0].id')
[ -n "$gate" ] && [ "$gate" != null ] || { echo 'FAIL: no gate row was made'; exit 1; }
late=$(date -u +%F)
python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("UPDATE ticket SET updated_at = ?", (sys.argv[2],)); c.commit()' \
  "$JG_HOME/state/item-store/fleet.db" "$(date -u -d '20 days ago' +%FT%TZ)"
[ "$(bdx show "$gate" --json | jq -r '.[0].updated_at[:10]')" = "$(date -u -d '20 days ago' +%F)" ] || { echo 'FAIL: the gate row is not 20 days idle, so the fixture proves nothing'; exit 1; }
tidy() { JG_TIDY_TODAY=$late python3 "$root/tickets-sync/sync.py" --tidy "$@"; }
open_ids() { (cd "$JG_HOME" && jg-backlog.sh list --limit 100 | grep -o 'jg-[a-z-]*' | sort -u | tr '\n' ' '); }
before=$(open_ids)

plan=$(tidy)
printf '%s\n' "$plan"
case $plan in
  *'7 open before, 4 after; would close 2 done, 1 duplicate, 0 superseded; would defer 1 idle; 1 captain asks listed, none touched; 2 left alone'*) ;;
  *) echo 'FAIL: the plan line does not count the rows as the rules read them'; exit 1 ;;
esac
[ "$(open_ids)" = "$before" ] || { echo 'FAIL: the plan changed a row'; exit 1; }
list=$(ls "$JG_HOME"/state/tickets-sync/tidy-*.txt)
grep -q "^done: main/jg-merged - its PR merged: $merged" "$list"
grep -q '^done: main/jg-landed - landed on the local trunk as 38f1eed7e' "$list"
grep -q '^duplicate: main/jg-dup-b - same title as jg-dup-a, which stays open' "$list"
grep -q '^deferred: main/jg-idle - idle 20 days with no owner, parent, link or lane' "$list"
grep -q '^captain-ask: main/jg-ask - keep' "$list"
grep -q "$gate" "$list" && { echo 'FAIL: a gate row was named in the tidy list'; exit 1; }
grep -qE ': main/(jg-wanted|jg-dup-a) ' "$list" && { echo 'FAIL: a row with a clear owner or value was listed'; exit 1; }
echo 'PASS: the plan names each row, its class and its evidence, and changes nothing'

applied=$(tidy --apply)
printf '%s\n' "$applied"
case $applied in
  *'7 open before, 4 after; closed 2 done, 1 duplicate, 0 superseded; deferred 1 idle; 1 captain asks listed, none touched; 2 left alone'*) ;;
  *) echo 'FAIL: the applied line does not match the plan'; exit 1 ;;
esac
shown() { (cd "$JG_HOME" && jg-backlog.sh show "$1"); }
shown jg-merged | grep -q 'state: done'
shown jg-merged | grep -q "closed by the fleet tidy $late: its PR merged: $merged"
shown jg-landed | grep -q 'closed by the fleet tidy .*: landed on the local trunk as 38f1eed7e'
shown jg-dup-b | grep -q 'state: done'
bdx show jg-dup-b --json | jq -e '.[0].dependencies[] | select(.id == "jg-dup-a" and .dependency_type == "duplicates")' >/dev/null
shown jg-dup-a | grep -q 'state: queued'
shown jg-idle | grep -q 'state: queued'
shown jg-idle | grep -q 'held: yes'
shown jg-idle | grep -q 'hold_kind: parked'
shown jg-idle | grep -q 'hold_reason: .*idle 20 days.*deferred by the fleet tidy'
shown jg-wanted | grep -q 'held: no'
shown jg-ask | grep -q 'state: queued'
shown jg-ask | grep -q 'held: no'
shown jg-ask | grep -q 'Umer wants this thing done soon'
[ "$(bdx show "$gate" --json | jq -r '.[0].status')" = open ] || { echo 'FAIL: the tidy touched the gate row'; exit 1; }
echo 'PASS: --apply closes with the reason written on the row, defers the idle row held, and leaves the owner ask and the wanted row as they were'

again=$(tidy --apply)
printf '%s\n' "$again"
case $again in
  *'4 open before, 4 after; closed 0 done, 0 duplicate, 0 superseded; deferred 0 idle; 1 captain asks listed, none touched; 3 left alone'*) ;;
  *) echo 'FAIL: a second run found something more to do'; exit 1 ;;
esac
echo 'PASS: a second run has nothing left to close or defer'
