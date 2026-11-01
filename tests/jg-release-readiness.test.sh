#!/usr/bin/env bash
# tests/jg-release-readiness.test.sh - the release branch pushes its own
# readiness (bin/jg-release-readiness.sh).
#
# The rules under test: a release branch whose features are complete, carried and
# green raises exactly one card carrying what ships, the numbers and the risks; an
# unchanged release is never raised twice; an open feature, a missing carry, a red
# or running check and an unreadable check each hold the release with their own
# reason shown; a release that waits past wait-hours raises one alert and one
# only; and a changed release replaces its card.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

RR=$ROOT/bin/jg-release-readiness.sh
jg_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(jg_test_tmproot jg-release-readiness-tests)

# A world is a bare origin, a seed clone that plays the forge, and a home whose
# copy is the checkout this pass reads. The release branch starts at the default
# branch and carries two features. The repository is built once and copied per
# case, because every case needs a fresh one and git clones are what make a
# fixture slow.
TEMPLATE=$TMP_ROOT/template
build_template() {
  local w=$TEMPLATE
  mkdir -p "$w"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/README.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main
  git -C "$w/seed" checkout -qb release/c-2
  printf 'feature one\n' > "$w/seed/one.txt"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm 'Add the first feature (#11)'
  printf 'feature two\n' >> "$w/seed/one.txt"
  git -C "$w/seed" commit -qam 'Add the second feature (#12)'
  git -C "$w/seed" push -q origin release/c-2
  git clone -q "$w/origin.git" "$w/copy" 2>/dev/null
  git -C "$w/copy" remote set-head origin main >/dev/null 2>&1 || true
}

new_world() {  # <name> [wait-hours] -> prints the world directory
  local w=$TMP_ROOT/$1 hours=${2:-24}
  [ -d "$TEMPLATE" ] || build_template
  cp -a "$TEMPLATE" "$w"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config" "$w/bin"
  # The copies name their own origin, and the forge is a local bare repo here:
  # the card's link and the provider calls only need the GitHub-shaped URL.
  git -C "$w/seed" remote set-url origin "file://$w/origin.git"
  git -C "$w/copy" remote add forge "file://$w/origin.git"
  git -C "$w/copy" remote set-url origin https://github.com/acme/thing.git
  printf 'project-dir=%s\nwait-hours=%s\nboard=%s\n' "$w/copy" "$hours" "$w/board.json" \
    > "$w/home/config/release-readiness"
  printf '{"schema":1,"decisions":[]}\n' > "$w/board.json"

  # The provider facts: how many pull requests still target the release, what the
  # checks on its head say, and the release pull request itself (none yet).
  printf '0\n' > "$w/gh-open"
  printf 'completed success @Smoke,completed success @Build\n' > "$w/gh-checks"
  : > "$w/gh-pr"
  cat > "$w/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *state=all*) cat "$GH_PR" ;;
  */pulls\?*) cat "$GH_OPEN" ;;
  */check-runs*) cat "$GH_CHECKS" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$w/bin/gh"

  # The poster and the alerter keep the real scripts' shapes, recorded instead of
  # spending a board or a wake queue.
  cat > "$w/bin/poster" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$POST_LOG"
SH
  cat > "$w/bin/alert" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ALERT_LOG"
SH
  # The board reader keeps the real tool's shape for the one call the script
  # makes: `list <board> --json` prints the board's decisions. The test owns the
  # board file, so it no longer depends on sign-off-axi being installed (the
  # Behavior job has none, and the script then reads "not waiting").
  cat > "$w/bin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) cat "$2" ;;
  dismiss) ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$w/bin/poster" "$w/bin/alert" "$w/bin/sign-off-axi"
  printf '%s\n' "$w"
}

# run <world> <verb> <now> -> OUT, RC
run() {  # <world> <verb> <now>
  local w=$1
  POST_LOG=$w/posted.log ALERT_LOG=$w/alerted.log
  GH_OPEN=$w/gh-open GH_CHECKS=$w/gh-checks GH_PR=$w/gh-pr
  export POST_LOG ALERT_LOG GH_OPEN GH_CHECKS GH_PR PATH="$w/bin:$PATH"
  OUT=$(JG_RELEASE_CARD_POST=$w/bin/poster JG_RELEASE_ALERT_NOTE=$w/bin/alert \
    bash "$RR" "$w/home" "$2" --now "$3" 2>&1)
  RC=$?
}

posts() { [ -f "$1/posted.log" ] && grep -c '^post' "$1/posted.log" || echo 0; }
alerts() { [ -f "$1/alerted.log" ] && grep -c '^note' "$1/alerted.log" || echo 0; }
cards() { [ -f "$1/home/data/release-readiness/cards.jsonl" ] && wc -l < "$1/home/data/release-readiness/cards.jsonl" | tr -d ' ' || echo 0; }
field() { jq -r "$2" "$1/home/data/release-readiness/state.jsonl" 2>/dev/null | tail -1; }

test_a_finished_release_raises_one_card_with_numbers_and_risks() {
  local w
  w=$(new_world finished)
  run "$w" tick 1800000000
  expect_code 0 "$RC" "a ready release should tick cleanly"
  assert_contains "$OUT" "card: release-c-2-" "the ready release raises one card"
  assert_equals 1 "$(posts "$w")" "exactly one card is posted"
  assert_grep '--must public-release' "$w/posted.log" "the card carries the board must"
  assert_grep 'Ship the next release now?' "$w/posted.log" "the card asks one plain question"
  assert_grep 'Ships: 2 changes' "$w/posted.log" "the card says what ships"
  assert_grep 'Risks: all of it goes live at once' "$w/posted.log" "the card carries the measured risk"
  assert_grep 'compare/main...release/c-2' "$w/posted.log" "the card links to the whole change list"
  assert_grep '--outcome yes=It ships now.' "$w/posted.log" "the card offers one Approve"
  assert_grep '--default no' "$w/posted.log" "nothing ships without the answer"
  assert_equals 1 "$(cards "$w")" "the raised card is recorded once"
  assert_equals ready "$(field "$w" .state)" "the recorded state is ready"
  assert_equals 2 "$(field "$w" .changes)" "the recorded change count is the measured one"
  assert_equals green "$(field "$w" .ci)" "the recorded check state is green"
  assert_equals 0 "$(field "$w" .behind)" "the release carries the live version"
  run "$w" show 1800000000
  assert_contains "$OUT" "Release: ready to ship, 2 changes green, waiting for your approval" \
    "the digest line says the release is ready"
  # The number is git's own, and the command that measured it is beside it.
  assert_grep 'Counted by: git diff --shortstat main release/c-2' "$w/posted.log" \
    "the card prints the command that produced the number"
  assert_grep 'Ships: 2 changes, +2/-0 lines across 1 file.' "$w/posted.log" \
    "the lines are measured over the whole tree by git"
  assert_contains "$OUT" '+2/-0 lines across 1 file by git diff --shortstat main release/c-2' \
    "the digest line carries the number and its command"
  # The live state: the pull request, the checks, the smoke job and the merge.
  assert_contains "$OUT" 'no release pull request yet, checks green, smoke passed, not merged so no home has it yet' \
    "the digest line carries the live release state"
  pass "a finished release raises one card with its changes, numbers, risks and one Approve"
}

test_a_second_run_inside_the_wait_resends_nothing() {
  local w
  w=$(new_world repeat 6)
  run "$w" tick 1800000000
  expect_code 0 "$RC" "the first tick should succeed"
  run "$w" tick 1800003600
  expect_code 0 "$RC" "the second tick inside the wait should succeed"
  assert_contains "$OUT" "unchanged" "the second tick reports nothing to do"
  assert_equals 1 "$(posts "$w")" "an unchanged release is never raised twice"
  assert_equals 0 "$(alerts "$w")" "nothing alerts inside the wait limit"
  # The limit is the configured one: six hours, not the 24-hour default.
  run "$w" tick 1800021601
  expect_code 0 "$RC" "the tick past the configured limit should succeed"
  assert_equals 1 "$(alerts "$w")" "the alert fires once past wait-hours"
  assert_grep 'release-readiness-1800000000' "$w/alerted.log" "the alert is tied to this wait"
  assert_grep 'waited 6 hours for approval' "$w/alerted.log" "the alert names how long it waited"
  run "$w" tick 1800030000
  assert_equals 1 "$(alerts "$w")" "the same wait is never alerted a second time"
  assert_equals 1 "$(posts "$w")" "an alert does not raise another card"
  pass "a second run inside the wait resends nothing and the alert fires once"
}

test_an_open_feature_holds_the_release() {
  local w
  w=$(new_world openfeature)
  printf '1\n' > "$w/gh-open"
  run "$w" tick 1800000000
  expect_code 0 "$RC" "a held release is not a failure"
  assert_equals 0 "$(posts "$w")" "an open feature holds the card"
  assert_equals open "$(field "$w" .state)" "the recorded state names the open feature"
  run "$w" show 1800000000
  assert_contains "$OUT" "Release: not ready, 1 change still open" "the digest line names the open feature"
  pass "an open feature holds the release instead of asking for approval"
}

test_a_release_that_does_not_carry_the_live_version_is_held() {
  local w tip
  w=$(new_world parity)
  git -C "$w/seed" checkout -q main
  printf 'later\n' >> "$w/seed/README.md"
  git -C "$w/seed" commit -qam 'A newer change on the live version'
  git -C "$w/seed" push -q origin main
  tip=$(git -C "$w/seed" rev-parse HEAD)
  git -C "$w/copy" fetch -q forge "main:refs/remotes/forge/main"
  git -C "$w/copy" update-ref refs/remotes/origin/main "$(git -C "$w/copy" rev-parse refs/remotes/forge/main)"
  assert_equals "$tip" "$(git -C "$w/copy" rev-parse refs/remotes/origin/main)" "the fixture moved the live version"
  run "$w" tick 1800000000
  assert_equals 0 "$(posts "$w")" "a release missing a live-version change raises no card"
  assert_equals behind "$(field "$w" .state)" "the recorded state names the missing carry"
  assert_equals 1 "$(field "$w" .behind)" "the missing change is counted"
  run "$w" show 1800000000
  assert_contains "$OUT" "1 change of the live version are not in it" "the digest line names what is missing"
  pass "a release that does not carry the live version is held, with the count shown"
}

test_a_red_or_running_or_unreadable_check_holds_the_release() {
  local w
  w=$(new_world checks)
  printf 'completed failure @Smoke,completed success @Build\n' > "$w/gh-checks"
  run "$w" tick 1800000000
  assert_equals 0 "$(posts "$w")" "a red check raises no card"
  run "$w" show 1800000000
  assert_contains "$OUT" "the checks on it are red" "the digest line says the check is red"
  assert_contains "$OUT" 'smoke failed' "a failed smoke job is named as failed"
  printf 'in_progress  @Smoke,completed success @Build\n' > "$w/gh-checks"
  run "$w" tick 1800000000
  assert_equals 0 "$(posts "$w")" "a running check raises no card"
  run "$w" show 1800000000
  assert_contains "$OUT" "the checks on it are still running" "the digest line says the check is running"
  assert_contains "$OUT" 'smoke still running' "a running smoke job is named as running"
  # A head with no smoke job at all is reported as such, never assumed passed.
  printf 'completed success @Build\n' > "$w/gh-checks"
  run "$w" show 1800000000
  assert_contains "$OUT" 'smoke not reported' "a head with no smoke job says so"
  printf '\n' > "$w/gh-checks"
  run "$w" tick 1800000000
  assert_equals 0 "$(posts "$w")" "no check at all raises no card"
  run "$w" show 1800000000
  assert_contains "$OUT" "cannot be checked right now" "an unreadable check is named, never assumed green"
  pass "a red, running or unreadable check holds the release instead of shipping it"
}

# The count comes from the refs the remote holds now, not stale local refs.
test_the_count_is_fetched_before_it_is_measured() {
  local w
  w=$(new_world fetched)
  # This world's origin is the bare repository, so the fetch can reach it.
  git -C "$w/copy" remote set-url origin "file://$w/origin.git"
  git -C "$w/seed" checkout -q release/c-2
  printf 'feature three\n' >> "$w/seed/one.txt"
  git -C "$w/seed" commit -qam 'Add a third feature (#13)'
  git -C "$w/seed" push -q origin release/c-2
  run "$w" tick 1800000000
  assert_equals '+3/-0' "$(field "$w" .lines)" \
    "the lines come from the fetched release branch, not a stale local ref"
  pass "the count is measured after both refs are fetched"
}

# The release state follows the pull request: none, open, then merged.
test_the_release_state_follows_the_pull_request() {
  local w sha merge
  w=$(new_world state)
  sha=$(git -C "$w/seed" rev-parse release/c-2)
  printf '12\thttps://github.com/acme/thing/pull/12\topen\t%s\t\n' "$sha" > "$w/gh-pr"
  run "$w" show 1800000000
  assert_contains "$OUT" 'the release pull request is open at https://github.com/acme/thing/pull/12' \
    "an open release pull request is named with its address"
  assert_contains "$OUT" 'not merged so no home has it yet' "an unmerged release reaches no home"
  # The pull request merges: every readable home carrying the merge is counted.
  git -C "$w/seed" checkout -q main
  git -C "$w/seed" merge -q --no-ff release/c-2 -m 'Merge the release (#12)'
  git -C "$w/seed" push -q origin main
  merge=$(git -C "$w/seed" rev-parse HEAD)
  git -C "$w/copy" fetch -q forge main:refs/remotes/origin/main
  printf '12\thttps://github.com/acme/thing/pull/12\tmerged\t%s\t%s\n' "$sha" "$merge" > "$w/gh-pr"
  printf -- '- sq1 - Example domain. (home: %s; scope: everything; projects: none; added 2026-01-01)\n' \
    "$w/seed" > "$w/home/data/squad_leads.md"
  run "$w" show 1800000000
  assert_contains "$OUT" 'Release: shipped' "a merged release says it shipped"
  assert_contains "$OUT" 'the release pull request is merged at https://github.com/acme/thing/pull/12' \
    "the merge state is read from the pull request"
  assert_contains "$OUT" '1 of 1 homes updated, 1 not checked' \
    "the homes that carry the merge commit are counted, and an unreadable one is not assumed"
  run "$w" tick 1800000000
  assert_contains "$OUT" 'shipped: the release is merged' "a shipped release raises no card"
  assert_equals 0 "$(posts "$w")" "nothing asks for approval after the release landed"
  pass "the release state follows the pull request from open to merged, with the homes that carry it"
}

test_a_changed_release_replaces_its_card() {
  local w first
  w=$(new_world changed)
  run "$w" tick 1800000000
  first=$(jq -r .key "$w/home/data/release-readiness/cards.jsonl" | tail -1)
  git -C "$w/seed" checkout -q release/c-2
  printf 'feature three\n' >> "$w/seed/one.txt"
  git -C "$w/seed" commit -qam 'Add a third feature (#13)'
  git -C "$w/seed" push -q origin release/c-2
  git -C "$w/copy" fetch -q forge "release/c-2:refs/remotes/forge/release/c-2"
  git -C "$w/copy" update-ref refs/remotes/origin/release/c-2 \
    "$(git -C "$w/copy" rev-parse refs/remotes/forge/release/c-2)"
  run "$w" tick 1800000000
  expect_code 0 "$RC" "the changed release should tick cleanly"
  assert_equals 2 "$(posts "$w")" "a changed release raises its card once more"
  assert_equals 2 "$(cards "$w")" "both cards are recorded"
  assert_not_equals "$first" "$(jq -r .key "$w/home/data/release-readiness/cards.jsonl" | tail -1)" \
    "the changed card replaces the earlier one under a new key"
  assert_grep 'Ships: 3 changes' "$w/posted.log" "the changed card carries the new count"
  pass "a changed release replaces its card, and an unchanged one keeps it"
}

test_a_card_already_waiting_is_not_raised_again() {
  local w key
  w=$(new_world waiting)
  run "$w" tick 1800000000
  key=$(jq -r .key "$w/home/data/release-readiness/cards.jsonl" | tail -1)
  # The board still holds the card, so the release is waiting on an answer even
  # with the local card record gone.
  jq -n --arg k "$key" '{schema:1,decisions:[{key:$k,status:"waiting",title:"Ship the next release now?"}]}' \
    > "$w/board.json"
  rm -f "$w/home/data/release-readiness/cards.jsonl"
  run "$w" tick 1800000000
  expect_code 0 "$RC" "a waiting card is not a failure"
  assert_equals 1 "$(posts "$w")" "a card still waiting on the board is never raised again"
  pass "a card already waiting on the board is never raised twice"
}

test_a_home_with_no_release_branch_says_so() {
  local w
  w=$(new_world nobranch)
  git -C "$w/copy" update-ref -d refs/remotes/origin/release/c-2
  run "$w" tick 1800000000
  expect_code 0 "$RC" "a home with no release branch ticks cleanly"
  assert_contains "$OUT" "not ready: none" "the tick names that no release is in progress"
  assert_equals 0 "$(posts "$w")" "no release branch raises no card"
  run "$w" show 1800000000
  assert_contains "$OUT" "Release: no release is in progress" "the digest line says no release is in progress"
  assert_absent "$w/home/data/release-readiness/state.jsonl" "nothing is recorded for a home with no release"
  pass "a home with no release branch says so and records nothing"
}

test_a_finished_release_raises_one_card_with_numbers_and_risks
test_a_second_run_inside_the_wait_resends_nothing
test_an_open_feature_holds_the_release
test_a_release_that_does_not_carry_the_live_version_is_held
test_a_red_or_running_or_unreadable_check_holds_the_release
test_the_count_is_fetched_before_it_is_measured
test_the_release_state_follows_the_pull_request
test_a_changed_release_replaces_its_card
test_a_card_already_waiting_is_not_raised_again
test_a_home_with_no_release_branch_says_so
