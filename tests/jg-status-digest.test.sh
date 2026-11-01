#!/usr/bin/env bash
# tests/jg-status-digest.test.sh - the batch-class captain digest
# (bin/jg-status-digest.sh).
#
# The rules under test: a recorded milestone pushes the five lines at once, a
# tick inside the configured window pushes nothing, a changed state after the
# window pushes once, an unchanged digest is never pushed twice, and the digest
# goes to the captain channel when it is live and to the fleet board report card
# while it is not.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

DIGEST=$ROOT/bin/jg-status-digest.sh
TMP=$(jg_test_tmproot jg-status-digest)

# A home with the records the digest reads, a fleet board, and a poster that
# records the card it was asked to post instead of reaching a real board.
make_home() {  # <name> -> prints the home
  local name=$1 home
  home=$TMP/$name
  mkdir -p "$home"/{data/metrics,config,bin,board} "$TMP/bin"
  printf '{"schema":1,"decisions":[]}\n' > "$home/board/board.json"
  printf '%s\n' "$home/board/board.json" > "$home/config/fleet-board"
  {
    printf 'home\ttask\tkind\tproject\tmodels\tstarted\tended\toutcome\tpr\n'
    printf 'main\tlanded-a\tship\tx\tpi:m\t1799999000\t1800000100\tmerged\thttps://example.test/1\n'
    printf 'main\tlanded-b\tship\tx\tpi:m\t1799999000\t1800000200\tmerged\thttps://example.test/2\n'
    printf 'main\tolder\tship\tx\tpi:m\t1700000000\t1700000900\tmerged\thttps://example.test/3\n'
    printf 'main\tclosed\tship\tx\tpi:m\t1799999000\t1800000300\tclosed\t%s\n' -
  } > "$home/data/metrics/task-outcomes.tsv"
  printf '%s\n' "$home"
}

mkdir -p "$TMP/bin"
# The poster writes one line per call, so a test can count deliveries and read
# the card's key back out of it.
cat > "$TMP/bin/poster" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$POST_LOG"
SH
chmod +x "$TMP/bin/poster"
POST=$TMP/bin/poster

run() { # <home> <args...> -> stdout in OUT, exit code in RC
  export POST_LOG=$1/posted.log
  OUT=$(JG_STATUS_DIGEST_POST=$POST bash "$DIGEST" "$@" 2>&1)
  RC=$?
}

deliveries() { # <home>
  [ -f "$1/posted.log" ] && grep -c '^post ' "$1/posted.log" || echo 0
}

test_a_milestone_pushes_the_four_lines_once() {
  local home before
  home=$(make_home milestone)
  run "$home" record "the migration card landed" --left "3 items" --blockers "one review" \
    --since 1799999000 --now 1800001000
  expect_code 0 "$RC" "record should succeed"
  assert_contains "$OUT" "Done: the migration card landed; 2 tasks merged since 2027-01-15" \
    "Done counts the merged tasks since the effort began"
  assert_contains "$OUT" "Left: 3 items" "the recorded Left line is carried"
  assert_contains "$OUT" "Release blockers: one review" "the recorded blocker line is carried"
  assert_contains "$OUT" "Live now: no release is recorded yet" "no release record means the live line says so"
  assert_equals 1 "$(deliveries "$home")" "a milestone delivers exactly one card"
  assert_grep "--key status-digest-" "$POST_LOG" "the card carries a digest key"
  assert_present "$home/board/reports/status-digest-202701150816/index.html" "the card page is written"
  before=$(deliveries "$home")
  # A second record with the same words and the same records is the same digest.
  run "$home" record "the migration card landed" --left "3 items" --blockers "one review" \
    --since 1799999000 --now 1800001200
  expect_code 0 "$RC" "an unchanged second milestone should still succeed"
  assert_contains "$OUT" "unchanged" "an unchanged digest is named as unchanged"
  assert_equals "$before" "$(deliveries "$home")" "an unchanged digest is never pushed twice"
  pass "a milestone pushes the five lines once and an unchanged one is not pushed again"
}

test_the_cadence_window_is_honoured() {
  local home before
  home=$(make_home cadence)
  printf 'every-hours=4\n' > "$home/config/status-digest"
  run "$home" record "the first slice landed" --left "4 items" --since 1799999000 --now 1800000000
  expect_code 0 "$RC" "the milestone should push"
  before=$(deliveries "$home")
  run "$home" tick --now 1800003600
  expect_code 0 "$RC" "a tick inside the window should succeed"
  assert_contains "$OUT" "not due" "a tick inside the window does not push"
  assert_equals "$before" "$(deliveries "$home")" "a tick inside the configured window delivers nothing"
  # Inside the window even a changed state waits for the cadence.
  printf 'main\tlanded-c\tship\tx\tpi:m\t1799999000\t1800001000\tmerged\thttps://example.test/4\n' \
    >> "$home/data/metrics/task-outcomes.tsv"
  run "$home" tick --now 1800010000
  expect_code 0 "$RC" "a changed state inside the window should still succeed"
  assert_equals "$before" "$(deliveries "$home")" "a changed state inside the window still waits"
  # Past the window the same change goes out once.
  run "$home" tick --now 1800014401
  expect_code 0 "$RC" "a tick past the window should succeed"
  assert_contains "$OUT" "3 tasks merged" "the changed count is in the pushed digest"
  assert_equals "$((before + 1))" "$(deliveries "$home")" "one cadence push past the window"
  run "$home" tick --now 1800030000
  assert_contains "$OUT" "unchanged" "a second tick with the same state changes nothing"
  assert_equals "$((before + 1))" "$(deliveries "$home")" "an unchanged digest is not pushed a second time"
  pass "the cadence config is honoured and a changed state past the window pushes once"
}

test_a_missing_cadence_config_still_defaults() {
  local home before
  home=$(make_home defaultcadence)
  run "$home" record "the first slice landed" --since 1799999000 --now 1800000000
  before=$(deliveries "$home")
  run "$home" tick --now 1800003600
  assert_contains "$OUT" "not due" "without config/status-digest the four-hour default applies"
  assert_equals "$before" "$(deliveries "$home")" "the default window pushes nothing"
  pass "an absent cadence config falls back to four hours"
}

test_a_live_captain_channel_takes_the_digest_instead_of_a_card() {
  local home before
  home=$(make_home channel)
  cat > "$home/bin/jg-bus.sh" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = config ] && { printf '%s\n' "${STUB_CHANNEL_MODE:-live}"; exit 0; }
printf '%s\n' "$*" >> "$BUS_LOG"
SH
  chmod +x "$home/bin/jg-bus.sh"
  BUS_LOG=$TMP/bus.log
  export BUS_LOG
  run "$home" record "the channel shipped" --left "2 items" --since 1799999000 --now 1800000000
  expect_code 0 "$RC" "a record should succeed on a live channel"
  before=$(deliveries "$home")
  assert_equals 0 "$before" "a live captain channel means no board card"
  assert_grep "publish digest status-digest-" "$BUS_LOG" "the digest is published to the captain channel"
  assert_grep "Left: 2 items" "$BUS_LOG" "the channel event carries the five lines"
  # A shadow channel is not live, so the card carries the digest again.
  rm -f "$BUS_LOG"
  export STUB_CHANNEL_MODE=shadow
  run "$home" record "the channel is only in shadow" --left "2 items" \
    --since 1799999000 --now 1800000100
  expect_code 0 "$RC" "a record should succeed while the channel is shadow"
  assert_equals 1 "$(deliveries "$home")" "a shadow channel falls back to the board card"
  assert_absent "$BUS_LOG" "a shadow channel records and publishes nothing here"
  pass "the captain channel carries the digest when live and the card carries it otherwise"
}

test_a_home_with_no_board_is_told_so() {
  local home
  home=$(make_home noboard)
  rm -f "$home/config/fleet-board"
  run "$home" record "nothing can deliver this" --now 1800000000
  expect_code 2 "$RC" "a home with no board should refuse rather than claim delivery"
  assert_contains "$OUT" "config/fleet-board" "the refusal names what is missing"
  assert_equals 0 "$(deliveries "$home")" "a refused delivery posts nothing"
  run "$home" show
  expect_code 0 "$RC" "the recorded milestone is still readable"
  assert_contains "$OUT" "Done: nothing can deliver this" "show prints the digest it recorded"
  pass "a home with no board is refused before anything is claimed as delivered"
}

test_tick_on_a_home_with_no_effort_is_silent() {
  local home
  home=$(make_home noeffort)
  run "$home" tick --now 1800000000
  expect_code 0 "$RC" "a tick with nothing recorded is not a failure"
  assert_equals '' "$OUT" "a tick with nothing recorded says nothing"
  run "$home" show
  expect_code 2 "$RC" "show with nothing recorded is a misuse, not an empty digest"
  assert_contains "$OUT" "record first" "the misuse says what to do"
  pass "tick is silent and show refuses while no batch effort is recorded"
}

test_the_release_state_is_carried_every_time() {
  local home before page
  home=$(make_home releaseline)
  mkdir -p "$home/bin"
  cat > "$home/bin/jg-release-readiness.sh" <<'SH'
#!/usr/bin/env bash
printf 'Release: ready to ship, 3 changes green, waiting 5 h for your approval\n'
SH
  chmod +x "$home/bin/jg-release-readiness.sh"
  run "$home" record "the first slice landed" --left "3 items" --since 1799999000 --now 1800000000
  expect_code 0 "$RC" "a home with a release owner pushes the digest"
  assert_contains "$OUT" "Release: ready to ship, 3 changes green, waiting 5 h for your approval" \
    "the digest carries the release state the release owner reports"
  page=$(cat "$home"/board/reports/*/index.html)
  assert_contains "$page" "Release: ready to ship, 3 changes green" "the card page carries it too"
  # A home without the release owner still answers the question every time.
  rm -f "$home/bin/jg-release-readiness.sh"
  before=$(deliveries "$home")
  run "$home" record "the second slice landed" --since 1799999000 --now 1800000200
  expect_code 0 "$RC" "a digest without a release owner still pushes"
  assert_contains "$OUT" "Release: no release is in progress" \
    "a home with no release still says so, and never leaves the line out"
  assert_equals "$((before + 1))" "$(deliveries "$home")" "the changed line is a changed digest"
  pass "the digest carries the release state every time, from the release owner"
}

test_a_milestone_pushes_the_four_lines_once
test_the_cadence_window_is_honoured
test_a_missing_cadence_config_still_defaults
test_a_live_captain_channel_takes_the_digest_instead_of_a_card
test_a_home_with_no_board_is_told_so
test_tick_on_a_home_with_no_effort_is_silent
test_the_release_state_is_carried_every_time
