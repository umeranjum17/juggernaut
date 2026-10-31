#!/usr/bin/env bash
# bin/jg-board-ledger.sh: a card leaving the board without a dismissal record wakes
# once, a dismissed one stays quiet, a merge with no new card wakes once, and an old
# backup's lost cards are kept searchable off the board.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root=$(jg_test_tmproot board-ledger) || fail "no fixture root"
home=$root/home board=$root/board.json
mkdir -p "$home/state" "$home/data" "$home/config"
export JG_HOME=$home JG_STATE_OVERRIDE=$home/state JG_DATA_OVERRIDE=$home/data \
  JG_CONFIG_OVERRIDE=$home/config
S=$ROOT/bin/jg-board-ledger.sh

# One evidence card. The board is a sign-off file: dismissal never edits the
# item, it appends a line to the sidecar beside the board.
card() {  # <key> <filed>
  printf '{"kind":"evidence","key":"%s","title":"%s","link":"https://example.test/%s","filed":"%s"}' \
    "$1" "$1" "$1" "$2"
}

reset() {  # fresh board, sidecar, ledger and fleet ledger
  rm -f -- "$home/state/board-evidence-ledger.jsonl" "$home/state/.board-evidence-alerted.json" \
    "$home/state/fleet-ledger.jsonl" "$root/board.dismissed.jsonl" "$home/data/board-evidence-archive.jsonl"
}

# --- case 1: one card leaves with a dismissal, one without --------------------
reset
printf '{"schema":2,"items":[%s,%s]}\n' \
  "$(card kept-old 2026-10-30T08:30:55Z)" "$(card left-silent 2026-10-30T09:00:00Z)" > "$board"
printf '%s\n' '{"key":"left-silent","dismissed":true,"at":"2026-10-30T10:00:00Z","reason":"replaced"}' \
  > "$root/board.dismissed.jsonl"

first=$(bash "$S" scan "$board")
assert_equals "" "$first" "a board nobody left yet raises no wake"
assert_present "$home/state/board-evidence-ledger.jsonl" "scan must record the evidence ledger"
assert_grep '"key":"kept-old"' "$home/state/board-evidence-ledger.jsonl" "the ledger keeps a card's key"
assert_grep '"key":"left-silent"' "$home/state/board-evidence-ledger.jsonl" "the ledger keeps every card's key"

printf '{"schema":2,"items":[]}\n' > "$board"
second=$(bash "$S" scan "$board")
assert_contains "$second" "proof card kept-old left the board with no dismissal" \
  "a card removed with no dismissal record wakes"
assert_not_contains "$second" "left-silent" "a card with a dismissal record stays quiet"
assert_equals "1" "$(printf '%s\n' "$second" | grep -c 'left the board')" "one wake, not one per scan"

third=$(bash "$S" scan "$board")
assert_equals "" "$third" "the same removal is not raised a second time"

# --- case 2: a merge lands and no proof card follows it -----------------------
reset
printf '{"schema":2,"items":[%s]}\n' "$(card old-evidence 2026-10-30T08:30:55Z)" > "$board"
now=$(date +%s)
printf '{"v":1,"ts":%s,"event":"task.merged","task":"t1","via":"pr","pr":"https://example.test/pull/1"}\n' \
  "$now" > "$home/state/fleet-ledger.jsonl"
merged=$(bash "$S" scan "$board")
assert_contains "$merged" "no proof card filed since the merge at" "a merge with no new card wakes"
assert_contains "$merged" "checked at" "the wake names both timestamps"
assert_equals "" "$(bash "$S" scan "$board")" "the same quiet merge window is not raised twice"

# A card filed after the merge closes the window.
reset
printf '{"v":1,"ts":%s,"event":"task.merged","task":"t2","via":"pr","pr":"https://example.test/pull/2"}\n' \
  "$now" > "$home/state/fleet-ledger.jsonl"
printf '{"schema":2,"items":[%s]}\n' "$(card fresh-after-merge "$(date -u -d "@$((now + 5))" +%Y-%m-%dT%H:%M:%SZ)")" \
  > "$board"
assert_equals "" "$(bash "$S" scan "$board")" "a proof card filed after the merge keeps the alarm quiet"

# --- case 3: an old backup's lost cards stay searchable ----------------------
reset
printf '{"schema":2,"items":[%s]}\n' "$(card still-live 2026-10-30T08:30:55Z)" > "$board"
printf '%s\n' '{"key":"said-goodbye","dismissed":true,"at":"2026-10-30T10:00:00Z","reason":"replaced"}' \
  > "$root/board.dismissed.jsonl"
printf '{"schema":2,"items":[%s,%s,%s]}\n' "$(card still-live 2026-10-30T08:30:55Z)" \
  "$(card said-goodbye 2026-10-30T09:00:00Z)" "$(card lost-forever 2026-10-30T09:30:00Z)" \
  > "$root/board.bak.json"
bash "$S" archive "$root/board.bak.json" --board "$board" >/dev/null
archive=$home/data/board-evidence-archive.jsonl
assert_present "$archive" "archive must write the evidence archive"
assert_grep '"key":"lost-forever"' "$archive" "a card in neither the board nor the dismissal log is archived"
assert_no_grep '"key":"still-live"' "$archive" "a card still on the board is not archived"
assert_no_grep '"key":"said-goodbye"' "$archive" "a dismissed card is not archived"
bash "$S" archive "$root/board.bak.json" --board "$board" >/dev/null
assert_equals "1" "$(grep -c . "$archive")" "archiving the same backup twice adds no second copy"

pass "board ledger: proof cards cannot leave the board silently"
