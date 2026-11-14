#!/usr/bin/env bash
# Integration test for the live, pin-back and release writers of bin/jg-trunk.sh (jg-q1b3n S12), on a real Beads store through the real
# jg-backlog.sh and the real `live` and `rollover` commands. The live step finds its tickets from the `Ticket` trailer of the commits
# above the last commit that went live, so it still finds them after the lane's cleanup (the stand-in teardown removes the task record at
# once); a ticket of another home is listed in one line and written nowhere; a second live step skips a ticket that already has live_at;
# a pin-back writes pinned_back_at to the tickets above the commit the home went back to; a merged release writes released_at for the
# commits of every release row of its pull request, also when the release was pushed before the live step.
# JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the builds; without them the run skips plainly.
# It proves bin/jg-trunk.sh (the writers) and bin/jg-beads-trace.py (the sources and --once), the files the changed-test selector maps to it.
# shellcheck source=core/lib/beads-test-env.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib/beads-test-env.sh"
# shellcheck source=tests/jg-trunk-fixture.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

bd() { BEADS_DIR=$(cat "$HOME_D/config/beads-dir") "$ROOT/bin/jg-beads.sh" "$@"; }
meta() { bd show "$1" --json | jq -r 'if type == "array" then .[0] else . end | .metadata.'"$2"' // empty'; }
events() { bd provenance log "$1" --json | jq -r '[.[] | select(.source == "'"$2"'")] | length'; }
file_ticket() { JG_HOME=$HOME_D "$ROOT/bin/jg-backlog.sh" add "$1" "[feature] fixture $1" --priority 2 --body why >/dev/null || fail "file $1"
  bd update "$1" --set-metadata "task=${1#jg-}" >/dev/null || fail "join $1 to its task name"; }
land_ticket() {  # <lane> <ticket>: a lane whose commit ends with the Ticket trailer lands
  lane "$1" "echo ok" "t/$1.test.sh" "Ticket: $2"; out=$(trunk land "$1" 2>&1) || fail "$1 must land: $out"
}

test_live_pin_back_and_release_write_the_tickets_of_their_commits() {
  local out k2 k4 k1_live
  world livetix; rig; core_beads_home "$ROOT" "$HOME_D"
  cp "$ROOT/bin/jg-backlog.sh" "$W/root/bin/jg-backlog.sh"; ln -sfn "$ROOT/toolchain.versions" "$W/root/toolchain.versions"
  file_ticket jg-k1; file_ticket jg-k2; file_ticket jg-k4
  land_ticket k1 jg-k1; land_ticket k2 jg-k2; k2=$(tip); land_ticket k3 jg-elsewhere
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "verify must move the green pin"
  trunk word in-use "$PROJ" go >/dev/null 2>&1
  out=$(trunk live "$PROJ" 2>&1) || fail "live: $out"
  for t in jg-k1 jg-k2; do
    [ -n "$(meta $t live_at)" ] || fail "$t must hold live_at"
    [ "$(events $t jg-trunk-live)" = 1 ] || fail "$t must hold one live event"
  done
  [ "$(meta jg-k2 live_at)" = "$(bd provenance log jg-k2 --json | jq -r '[.[] | select(.source == "jg-trunk-live")][0].occurred_at')" ] || fail "the event and the row must carry the same time"
  [ "$(bd provenance log jg-k2 --json | jq -r '[.[] | select(.source == "jg-trunk-live")][0].ref')" = "$k2" ] || fail "the live event must hold the ticket's commit"
  assert_contains "$out" "not in this home: jg-elsewhere" "a ticket of another home must be listed in one line"
  [ "$(printf '%s\n' "$out" | grep -c 'not in this home')" = 1 ] || fail "one line only"
  pass "live writes live_at and a live event to each ticket of the commits that went live, found by trailer after the lane's cleanup"
  # The next live step starts above the last live commit and never rewrites a ticket that is live.
  k1_live=$(meta jg-k1 live_at); sleep 1
  land_ticket k4 jg-k4; k4=$(tip)
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "verify must move the green pin to k4"; trunk word in-use "$PROJ" go >/dev/null 2>&1
  out=$(trunk live "$PROJ" 2>&1) || fail "second live: $out"
  [ "$(events jg-k1 jg-trunk-live)" = 1 ] && [ "$(meta jg-k1 live_at)" = "$k1_live" ] || fail "a ticket that is live must not be written again"
  [ "$(events jg-k4 jg-trunk-live)" = 1 ] || fail "the new ticket must hold one live event"
  pass "the second live step writes only the tickets above the last live commit"
  # A pin-back to the commit before k4 writes pinned_back_at to k4 only.
  sleep 1; trunk ci "$PROJ" "$k4" red >/dev/null 2>&1 || fail "a red CI must pin the home back"
  [ -n "$(meta jg-k4 pinned_back_at)" ] && [ "$(events jg-k4 jg-trunk-pin-back)" = 1 ] || fail "k4 must hold pinned_back_at and a pin-back event"
  [ -z "$(meta jg-k2 pinned_back_at)" ] || fail "a ticket below the new live commit must not be pinned back"
  pass "a pin-back writes pinned_back_at to the tickets above the commit the home went back to"
  # A merged release: two rows of one pull request, one pushed before the live step, write released_at for every commit of both.
  git -C "$PROJ" push -q origin "$(tip):refs/heads/merged"; git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/merged
  printf 'proj\ttrunk\t%s\t2\t1\thttps://github.com/o/r/pull/9\nproj\ttrunk\t%s\t2\t2\thttps://github.com/o/r/pull/9\n' "$k2" "$(tip)" > "$HOME_D/data/trunk-releases.tsv"
  echo merged > "$W/pr-state"
  out=$(trunk rollover "$PROJ" 2>&1) || fail "rollover: $out"
  for t in jg-k1 jg-k2 jg-k4; do
    [ -n "$(meta $t released_at)" ] && [ "$(events $t jg-trunk-release)" = 1 ] || fail "$t must hold released_at and a release event"
  done
  [ "$(bd provenance log jg-k1 --json | jq -r '[.[] | select(.source == "jg-trunk-release")][0].ref')" = "https://github.com/o/r/pull/9" ] || fail "the release event must hold the pull request URL"
  assert_contains "$out" "not in this home: jg-elsewhere" "the release lists the ticket of another home"
  pass "a merged release writes released_at to the tickets of every release row of its pull request"
}

test_live_pin_back_and_release_write_the_tickets_of_their_commits
printf 'jg-trunk-live-tickets: ok\n'
