#!/usr/bin/env bash
# The daily clean-up on a board with more findings than fit sign-off-axi's
# 1000-character --detail: the raise succeeds, the card exists, its detail is
# capped with one "... and N more" line that keeps the count, and the report
# file beside it still holds every finding.
# Real tasks-axi backlog, real sign-off-axi board, real install: nothing is mocked.
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
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/cleanup-detail-cap.XXXXXX")
trap 'echo "retained fixture: $work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state}
ln -s "$fork/bin" "$JG_HOME/bin"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
printf '[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=0\n' > "$JG_HOME/.tasks.toml"
# Eight captain tickets with no ask card and no quoted words are two findings
# each, so the joined detail is well past the 1000 characters sign-off-axi takes.
(cd "$JG_HOME"; for n in one two three four five six seven eight; do
  tasks-axi add "ask-$n" "[captain-ask] P2 Umer capped ask $n" --repo alpha --priority 2 --body 'type: captain-ask' >/dev/null
done)
bash "$root/wiring.sh"
status=0
out=$("$JG_HOME/state/tickets-cleanup.check.sh") || status=$?
[ "$status" = 0 ] || { echo "FAIL: the clean-up check exited $status: $out"; exit 1; }
grep -q 'VALIDATION_ERROR\|characters, over' <<<"$out" && { echo "FAIL: the clean-up raise was refused: $out"; exit 1; }
key="ticket-cleanup-$(date -u +%F)"
sign-off-axi list "$work/board.json" --json > "$work/cards.json"
jq -e --arg key "$key" '.decisions[] | select(.key == $key)' "$work/cards.json" >/dev/null || { echo "FAIL: no $key card on the board: $(cat "$work/cards.json")"; exit 1; }
jq -e --arg key "$key" '.decisions[] | select(.key == $key) | (.detail | length) <= 1000' "$work/cards.json" >/dev/null || { echo 'FAIL: the card detail is over 1000 characters'; exit 1; }
jq -e --arg key "$key" '.decisions[] | select(.key == $key) | (.detail | test("and [0-9]+ more$"))' "$work/cards.json" >/dev/null || { echo 'FAIL: the capped detail names no "... and N more" line'; exit 1; }
report=$JG_HOME/state/tickets-sync/cleanup-$(date -u +%F).txt
head -n1 <<<"$out" | grep -q "full list $report$" || { echo "FAIL: the check line does not name the full list: $(head -n1 <<<"$out")"; exit 1; }
test -s "$report" || { echo "FAIL: no full finding list at $report"; exit 1; }
test "$(wc -c < "$report")" -gt 1000 || { echo 'FAIL: the fixture never carried more findings than fit, so the cap was not exercised'; exit 1; }
grep -q '^no-quote: main/ask-one - captain ticket carries no quoted words$' "$report"
grep -q '^no-ask-card: main/ask-eight - ' "$report"
# Kept detail lines plus the count on the "... and N more" line are exactly what the report holds.
kept=$(( $(jq --arg key "$key" '.decisions[] | select(.key == $key) | [.detail | splits("\n")] | length' "$work/cards.json") - 1 ))
more=$(jq -r --arg key "$key" '.decisions[] | select(.key == $key) | .detail | capture("and (?<n>[0-9]+) more$").n' "$work/cards.json")
test "$(( kept + more ))" -eq "$(( $(wc -l < "$report") - 1 ))" || { echo "FAIL: $kept kept + $more more does not cover the $(wc -l < "$report") report lines"; exit 1; }
echo 'PASS: the daily clean-up caps its card detail under 1000 characters, keeps the finding count, and writes every finding to its report file'
