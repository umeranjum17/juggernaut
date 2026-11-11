#!/usr/bin/env bash
# The daily clean-up publishes a report card, never an ask: a keep/remove call on
# flagged tickets is not one of the captain's six must categories, so an ask
# carrying it is routed to Overwatch and re-alerted on. The card takes no answer,
# the finding count and the first findings are on it, the report file beside it
# still holds every finding, and the asks gate neither counts nor routes it.
# Real jg-backlog.sh on a Beads store, real sign-off-axi board, real install: nothing is mocked.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
fork=${JG_TEST_FORK:-$(cd "$root/../.." && pwd -P)}
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/cleanup-report-card.XXXXXX")
trap 'echo "retained fixture: $work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state}
ln -s "$fork/bin" "$JG_HOME/bin"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
# shellcheck source=core/lib/beads-test-env.sh disable=SC1091
. "$root/../lib/beads-test-env.sh"
core_beads_home "$fork" "$JG_HOME"
# Eight captain tickets with no ask card and no quoted words are two findings
# each, so the full finding list is well past the 1000 characters one card used to take.
(cd "$JG_HOME"; for n in one two three four five six seven eight; do
  jg-backlog.sh add "jg-ask-$n" "[captain-ask] P0 Umer capped ask $n" --repo alpha --priority 0 --body 'type: captain-ask' >/dev/null
done)
bash "$root/wiring.sh"
status=0
out=$("$JG_HOME/state/tickets-cleanup.check.sh") || status=$?
[ "$status" = 0 ] || { echo "FAIL: the clean-up check exited $status: $out"; exit 1; }
key="ticket-cleanup-$(date -u +%F)"
sign-off-axi list "$work/board.json" --json > "$work/cards.json"
jq -e --arg key "$key" '.decisions[] | select(.key == $key)' "$work/cards.json" >/dev/null \
  || { echo "FAIL: no $key card on the board: $(cat "$work/cards.json")"; exit 1; }
jq -e --arg key "$key" '.decisions[] | select(.key == $key) | .kind == "report"' "$work/cards.json" >/dev/null \
  || { echo 'FAIL: the clean-up posted something other than a report card'; exit 1; }
jq -e --arg key "$key" '.decisions[] | select(.key == $key) | ((.options // []) | length) == 0' "$work/cards.json" >/dev/null \
  || { echo 'FAIL: the report card takes an answer, so the asks gate still sees a must-less ask'; exit 1; }
jq -e --arg key "$key" '.decisions[] | select(.key == $key) | .sections[].items[].title | test("^no-quote: main/jg-ask-")' "$work/cards.json" >/dev/null \
  || { echo 'FAIL: the report card names none of the flagged tickets'; exit 1; }
report=$JG_HOME/state/tickets-sync/cleanup-$(date -u +%F).txt
head -n1 <<<"$out" | grep -q "full list $report$" || { echo "FAIL: the check line does not name the full list: $(head -n1 <<<"$out")"; exit 1; }
test -s "$report" || { echo "FAIL: no full finding list at $report"; exit 1; }
test "$(wc -c < "$report")" -gt 1000 || { echo 'FAIL: the fixture never carried more findings than one card holds, so the list was not exercised'; exit 1; }
grep -q '^no-quote: main/jg-ask-one - captain ticket carries no quoted words$' "$report"
grep -q '^no-ask-card: main/jg-ask-eight - ' "$report"
# The asks gate reads every waiting ask: a report is not one, so it neither counts
# nor routes it, and no line reaches Main.
test "$(BOARD=$work/board.json "$JG_HOME/bin/jg-board-gate.sh" waiting)" = 0 \
  || { echo 'FAIL: the clean-up report counted as an ask waiting on the captain'; exit 1; }
gate=$(BOARD=$work/board.json "$JG_HOME/bin/jg-board-gate.sh" check)
test -z "$gate" || { echo "FAIL: the board gate alerted on the clean-up report: $gate"; exit 1; }
# The migration day: the day's key can already be taken by the old keep/remove ask
# card. A key takes only the same message again, so the report goes on beside it
# instead of failing the whole pass every time the check runs.
printf '{"schema":2,"items":[]}\n' > "$work/board2.json"
sign-off-axi raise "$work/board2.json" --key "$key" --ask-ref "$key" --title 'Keep or remove the flagged tickets?' \
  --why 'The old keep/remove card.' --option 'keep=Keep them' --option 'remove=Remove them' \
  --outcome 'keep=They stay.' --outcome 'remove=Main removes them.' \
  --recommend keep --recommend-reason 'Nothing is lost.' --default keep >/dev/null
printf '%s\n' "$work/board2.json" > "$JG_HOME/config/fleet-board"
rm -f "$JG_HOME/state/tickets-sync/cleanup.day"
status=0; out=$("$JG_HOME/state/tickets-cleanup.check.sh") || status=$?
[ "$status" = 0 ] || { echo "FAIL: the clean-up check exited $status with the day's key taken: $out"; exit 1; }
grep -q "card $key-report" <<<"$out" || { echo "FAIL: the report did not go on beside the taken key: $out"; exit 1; }
sign-off-axi list "$work/board2.json" --json > "$work/cards.json"
jq -e --arg key "$key-report" '.decisions[] | select(.key == $key) | .kind == "report"' "$work/cards.json" >/dev/null \
  || { echo 'FAIL: no report card beside the taken day key'; exit 1; }
echo 'PASS: the daily clean-up posts one report card that takes no answer, keeps every finding in its report file, and never becomes a waiting or routed ask'
