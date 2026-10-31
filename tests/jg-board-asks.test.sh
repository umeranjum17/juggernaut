#!/usr/bin/env bash
# tests/jg-board-asks.test.sh - the board ask rebuild's three corrections
# (bin/jg-board-asks.sh, bin/jg-board-record-lib.sh): a surviving card keeps the
# detail field its must category lives in, a key its owner dismissed is never
# rebuilt, and a key another home already has live is left to that home.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-board-asks)
REBUILD="$ROOT/bin/jg-board-asks.sh"

# <name> -> the case dir, with a board and a freshly built feed in it; the feed
# carries the same three cards each case corrects differently.
setup() {  # <name>
  local d=$TMP_ROOT/$1
  mkdir -p "$d/board"
  cat > "$d/board/board.json" <<'JSON'
{"schema":2,"answers_only":true,"items":[
 {"key":"ask-screen","title":"Allow screen recording?","filer":"captain-board-feed","detail":"must: security"},
 {"key":"ask-click","title":"Click Allow on the Mac?","filer":"captain-board-feed"},
 {"key":"ask-desklink","title":"Sign in to the app store?","filer":"desklink"}
]}
JSON
  cat > "$d/feed.json" <<'JSON'
{"schema":2,"answers_only":true,"items":[
 {"key":"ask-screen","contract":1,"kind":"ask","schema":1,"title":"Allow screen recording?","detail":"TakeOne Mac recording needs it"},
 {"key":"ask-click","contract":1,"kind":"ask","schema":1,"title":"Click Allow on the Mac?"},
 {"key":"ask-desklink","contract":1,"kind":"ask","schema":1,"title":"Sign in to the app store?"},
 {"key":"ask-fresh","contract":1,"kind":"ask","schema":1,"title":"Renew the domain?"}
]}
JSON
  printf '%s\n' "$d"
}

rebuild() {  # <case dir> [flags...] -> both streams
  local d=$1
  shift
  bash "$REBUILD" rebuild --board "$d/board/board.json" --from "$d/feed.json" "$@" 2>&1
}

items() {  # <case dir> <json> -> the keys a corrected feed keeps
  printf '%s' "$2" | sed -n '/^{/,$p' | jq -r '[.items[].key] | join(" ")'
}

test_a_surviving_card_keeps_its_must_category() {
  local d out detail
  d=$(setup keeps-category)
  out=$(rebuild "$d")
  detail=$(printf '%s' "$out" | sed -n '/^{/,$p' | jq -r '.items[] | select(.key == "ask-screen") | .detail')
  assert_contains "$detail" "must: security" "the rebuild dropped the card's must category"
  assert_contains "$detail" "TakeOne Mac recording needs it" "the rebuild dropped the card's own detail text"
  pass "a card that survives the rebuild keeps the must category it was filed with"
}

test_a_dismissed_card_is_never_rebuilt() {
  local d out
  d=$(setup dismissed)
  printf '%s\n' '{"key":"ask-click","dismissed":true,"at":"2026-10-31T20:24:33Z"}' \
    > "$d/board/board.dismissed.jsonl"
  out=$(rebuild "$d")
  assert_not_contains "$(items "$d" "$out")" "ask-click" "a key its owner dismissed was rebuilt"
  assert_contains "$out" "dropped ask-click: dismissed by its owning home" "the rebuild did not say what it dropped"
  assert_contains "$(items "$d" "$out")" "ask-fresh" "an unrelated new ask was dropped with it"
  pass "a dismissal is a record, not an absence: the dismissed key is not rebuilt"
}

test_a_reopened_card_is_rebuilt_again() {
  local d out
  d=$(setup reopened)
  printf '%s\n' \
    '{"key":"ask-click","dismissed":true,"at":"2026-10-31T20:24:33Z"}' \
    '{"key":"ask-click","dismissed":false,"at":"2026-10-31T21:24:33Z"}' \
    > "$d/board/board.dismissed.jsonl"
  out=$(rebuild "$d")
  assert_contains "$(items "$d" "$out")" "ask-click" "an undone dismissal still held the card off the board"
  pass "the record's last line decides: an undone dismissal rebuilds the card again"
}

test_a_card_another_home_holds_is_left_to_that_home() {
  local d out
  d=$(setup held-elsewhere)
  out=$(rebuild "$d")
  assert_not_contains "$(items "$d" "$out")" "ask-desklink" "a card another home already has live was rebuilt twice"
  assert_contains "$out" "dropped ask-desklink: already live on the board under another filer" \
    "the rebuild did not say what it left to the other home"
  pass "a key another home already has live stays with that home"
}

test_the_corrected_feed_writes_out() {
  local d out
  d=$(setup writes-out)
  rebuild "$d" --out "$d/posted.json" >/dev/null || fail "the rebuild refused --out"
  [ -s "$d/posted.json" ] || fail "the rebuild wrote no feed to --out"
  out=$(jq -r '[.items[].key] | join(" ")' "$d/posted.json")
  assert_equals "ask-screen ask-click ask-fresh" "$out" "the feed written to --out is not the corrected feed"
  pass "a corrected feed can be written to a file for the poster"
}

test_a_surviving_card_keeps_its_must_category
test_a_dismissed_card_is_never_rebuilt
test_a_reopened_card_is_rebuilt_again
test_a_card_another_home_holds_is_left_to_that_home
test_the_corrected_feed_writes_out
