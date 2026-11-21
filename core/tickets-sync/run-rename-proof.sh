#!/usr/bin/env bash
# Five open tickets carry plan codes in their titles. The rename pass (bin/jg-retitle.py) gives each a plain outcome title,
# the poll publishes them, and the Tickets page at 390px lists the five plain titles under their parent ticket with no plan code in any of them.
set -euo pipefail
: "${DONE_DONE_EVIDENCE_ROOT:?done-done must provide its run evidence folder}"
command -v sign-off-axi >/dev/null || { echo 'sign-off-axi is required' >&2; exit 1; }
command -v chrome-devtools-axi >/dev/null || { echo 'chrome-devtools-axi is required' >&2; exit 1; }
real_home=${HOME:-/home/you}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
fork=${JG_TEST_FORK:-${JG_MAIN_HOME:-$(cd "$repo/.." && pwd -P)}}
evidence=$DONE_DONE_EVIDENCE_ROOT
work=$(mktemp -d "${TMPDIR:-/tmp}/rename-board.XXXXXX")
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main TMPDIR=$work/tmp
mkdir -p "$HOME" "$JG_HOME"/{data,config,state} "$TMPDIR"
ln -sn "$fork/bin" "$JG_HOME/bin"
ln -sn "$fork/toolchain.versions" "$JG_HOME/toolchain.versions"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
JG_HOME=$JG_HOME python3 -I "$fork/core/item-store/adapters/tickets.py" import --home main /dev/null >/dev/null || { echo 'cannot create the tickets tables' >&2; exit 1; }
: > "$JG_HOME/config/backlog-intake-loose"  # the old rows predate the title rule
map=$work/map.tsv
while IFS='|' read -r id old new; do
  (cd "$JG_HOME"; "$fork/bin/jg-backlog.sh" add "$id" "$old" --priority 1 --body "Umer ticket body for $id" >/dev/null)
  printf '%s\t%s\n' "$id" "$new" >> "$map"
done <<'ROWS'
umer-a|[feature] J20d-3: nm bin rest and name gate|Name gate covers the rest of bin
umer-b|[feature] mf-m2: Lone ready lane lands|A lone ready lane lands by itself
umer-c|[feature] S18c|Each change lands by itself when ready
umer-d|[feature] TC4b: core file swap into AGENTS.md|Core instructions live in one file
umer-e|[feature] jg8-q1b3n-s14: A move keeps link and log|A move keeps its link and log
ROWS
rm -f "$JG_HOME/config/backlog-intake-loose"
(cd "$JG_HOME"; python3 "$fork/bin/jg-retitle.py" list | tee "$evidence/before.tsv")
(cd "$JG_HOME"; python3 "$fork/bin/jg-retitle.py" apply "$map" --write | tee "$evidence/rename.out")
bash "$repo/tickets-sync/wiring.sh"
"$JG_HOME/state/tickets-sync.check.sh" | tee "$evidence/sync.out"
sign-off-axi ticket "$work/board.json" --json > "$evidence/tickets.json"
while IFS=$'\t' read -r _ new; do jq -e --arg t "$new" '[.tickets[].title] | index($t)' "$evidence/tickets.json" >/dev/null || { echo "the board lacks the title: $new" >&2; exit 1; }; done < "$map"
sign-off-axi serve "$work/board.json" --port 0 --bind 127.0.0.1 >"$work/serve.log" 2>&1 &
cleanup() {
  SIGN_OFF_HOME=$work/signoff sign-off-axi stop "$work/board.json" >/dev/null 2>&1 || true
  [ -z "${CHROME_DEVTOOLS_AXI_SESSION:-}" ] || HOME=$real_home timeout 20 chrome-devtools-axi stop >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for _ in $(seq 1 50); do grep -Eoq 'http://127\.0\.0\.1:[0-9]+' "$work/serve.log" && break; sleep 0.1; done
url=$(grep -Eo 'http://127\.0\.0\.1:[0-9]+' "$work/serve.log" | head -n1)
[ -n "$url" ] || { echo "serve did not print a URL: $(cat "$work/serve.log")" >&2; exit 1; }
export HOME=$real_home CHROME_DEVTOOLS_AXI_SESSION=tickets-rename-$$
unset XDG_DATA_HOME TMPDIR || true
chrome-devtools-axi selectpage 1 >/dev/null 2>&1 || true
chrome-devtools-axi emulate --viewport 390x844x1 --color-scheme light >/dev/null
upkeep=$(python3 "$repo/tickets-sync/identity.py" :upkeep fleet)  # the rows have no ask, so the poll files them under the fleet upkeep ticket
chrome-devtools-axi open "$url#ticket/$upkeep" >/dev/null
chrome-devtools-axi wait 'Core instructions live in one file' >/dev/null
chrome-devtools-axi eval 'JSON.stringify({ text: document.body.innerText })' > "$evidence/tickets-390.txt"
chrome-devtools-axi screenshot "$evidence/tickets-390.png" >/dev/null
while IFS=$'\t' read -r _ new; do grep -qF "$new" "$evidence/tickets-390.txt" || { echo "the 390px page does not show: $new" >&2; exit 1; }; done < "$map"
if grep -Eq 'J20d|mf-m2|S18c|TC4b|q1b3n' "$evidence/tickets-390.txt"; then echo 'the 390px page still shows a plan code' >&2; exit 1; fi
printf 'PASS: five open tickets renamed to plain outcome titles; the 390px Tickets page shows all five and no plan code\n'
