#!/usr/bin/env bash
# Integration test for core/trunk-release/ci-watch.sh (slice H50, report section 8.1): a red release pull request is fixed fast.
# The watch runs as the registered check does (`ci-watch.sh check <home>`) over a real trunk, with the real bin/jg-trunk.sh and
# a stand-in only for the forge's check reader (bin/jg-pr-state.sh).
#
# T1 The release pull request's checks are pending, or it is merged: nothing is filed or recorded and nothing is printed.
# T2 A required check failed: one line, one ticket naming the failing check, a red row for the release head in data/trunk-ci.tsv,
#    and the green pin back at the last green commit.
# T3 The next tick on the same red head prints, files and records nothing more.
# T4 The board row (data/trunk-release-age.tsv) counts the landings that are not released and the age of the oldest.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

U=https://github.com/o/r/pull/77
watch() { JG_CI_WATCH_NOW=5000 PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-release/ci-watch.sh" check "$HOME_D" 2>&1; }
landed() {  # <id>...: each lane lands, then a verify moves the green pin to it
  local id out; for id; do lane "$id" "$id"; out=$(trunk land "$id" 2>&1) || fail "$id must land: $out"; out=$(trunk verify "$PROJ" 2>&1) || fail "$id must verify: $out"; done
}

test_a_red_release_is_recorded_and_filed_once() {
  local out second calls pin
  world cw
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # shellcheck disable=SC2016 # the stand-in script expands its own variables
  printf '#!/usr/bin/env bash\ncat "%s/pr-checks" 2>/dev/null || true\n' "$W" > "$HOME_D/bin/jg-pr-state.sh"; chmod +x "$HOME_D/bin/jg-pr-state.sh"
  landed c1 c2
  second=$(tip)
  printf 'proj\ttrunk\t%s\t2\t1000\t%s\n' "$second" "$U" > "$HOME_D/data/trunk-releases.tsv"

  : > "$W/backlog-calls"  # the landings above filed their own tickets; only the watch's count here
  printf 'REQUIRED CHECK: unit-tests (pending)\n' > "$W/pr-checks"
  out=$(watch) || fail "T1: the watch must exit 0: $out"
  [ -z "$out" ] && ! grep -q "	red" "$HOME_D/data/trunk-ci.tsv" 2>/dev/null && [ ! -s "$W/backlog-calls" ] || fail "T1: a pending check must record and file nothing: $out"
  printf 'STATE: merged at 2026-11-13T00:00:00Z\n' > "$W/pr-checks"
  out=$(watch) || fail "T1: $out"
  [ -z "$out" ] && [ ! -s "$W/backlog-calls" ] || fail "T1: a merged release must be silent: $out"
  pass 'T1 a pending check and a merged release pull request leave no trace'

  printf 'REQUIRED CHECK: unit-tests (FAILURE)\n' > "$W/pr-checks"
  out=$(watch) || fail "T2: $out"
  assert_contains "$out" "unit-tests" "T2: the line must name the failing check"
  calls=$(cat "$W/backlog-calls")
  assert_contains "$calls" "ci-red-release-proj-${second:0:12}" "T2: one ticket for the release head"
  assert_contains "$calls" "unit-tests" "T2: the ticket must name the failing check"
  grep -Eq "^proj	$second	[0-9]+	red" "$HOME_D/data/trunk-ci.tsv" || fail "T2: the red must be recorded as the trunk's CI result for the head"
  pin=$(cat "$HOME_D/state/trunk-green-proj")
  { [ "$pin" != "$second" ] && git -C "$PROJ" merge-base --is-ancestor "$pin" "$second"; } || fail "T2: the green pin must go back below the red head: pin $pin out $out"
  assert_contains "$out" "${pin:0:12}" "T2: the pin must go back to the commit the trunk names"
  pass 'T2 a red release files one ticket, records the red and moves the green pin back'

  out=$(watch) || fail "T3: $out"
  [ -z "$out" ] && [ "$(grep -c . "$W/backlog-calls")" = 1 ] && [ "$(grep -c "	red" "$HOME_D/data/trunk-ci.tsv")" = 1 ] || fail "T3: a second tick must do nothing: $out"
  pass 'T3 the same red head is handled once'

  [ "$(cat "$HOME_D/data/trunk-release-age.tsv")" = "$(printf 'proj\t2\t%s\t%s' "$(awk -F'\t' 'NR == 1 { print $4 }' "$HOME_D/data/trunk-landings.tsv")" \
    "$((5000 - $(awk -F'\t' 'NR == 1 { print $4 }' "$HOME_D/data/trunk-landings.tsv")))")" ] || fail "T4: the board row is wrong: $(cat "$HOME_D/data/trunk-release-age.tsv")"
  pass 'T4 the board row holds the unreleased landings and the age of the oldest'
}

test_a_red_release_is_recorded_and_filed_once
printf 'jg-trunk-release-ci-watch: ok\n'
