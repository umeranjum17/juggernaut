#!/usr/bin/env bash
# Integration test for the nothing-lands alert of core/trunk-landing/trunk-landing.sh (tests/jg-trunk-fixture.sh).
# Through the fixture it runs the real landing check and the real bin/jg-alert.sh.
#
# A project whose oldest ready lane has waited 30 minutes while nothing landed in it for 30 minutes raises ONE `fleet-blocked` alert to the
# lead (rung 2). A younger lane raises none, a second tick adds none, a landing resolves it, and a tick prints nothing to stdout.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

fresh() { printf 'done [at=%s]: ready in branch fm/%s (local-trunk)\n' "$(( $(date +%s) - $2 * 60 ))" "$1" >> "$HOME_D/state/$1.status"; }
tick() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" 2>"$W/tick.err"; }
aword() { JG_HOME="$HOME_D" JG_STATE_OVERRIDE="$HOME_D/state" bash "$HOME_D/bin/jg-alert.sh" word "$1" 2>&1; }
alerts() { find "$HOME_D/state/alerts" -name '*.rec' 2>/dev/null | wc -l | tr -d ' '; }

test_a_ready_lane_that_nothing_lands_behind_raises_one_alert_until_something_lands() {
  local out key=fleet-blocked--proj-nothing-lands rec
  world nolands
  # The lander starts nothing: the lane stays ready, as when the queue waits for its threshold.
  printf 'flush-at-ready=99\nflush-after-minutes=999999\n' >> "$HOME_D/config/trunk-policy"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  rec="$HOME_D/state/alerts/$key.rec"
  lane n1 one f1.txt
  # (a) a lane ready 10 minutes gives no alert.
  fresh n1 10; out=$(tick); [ "$(alerts)" = 0 ] || fail "(a) a lane ready 10 minutes raises no alert: $(ls "$HOME_D/state/alerts")"
  # (b) a lane ready 31 minutes with the last landing 31 minutes old gives exactly one alert, rung 2, for the lead.
  printf 'old\tproj\t%s\t%s\tfull\n' "$(git -C "$PROJ" rev-parse trunk)" "$(( $(date +%s) - 31 * 60 ))" > "$HOME_D/data/trunk-landings.tsv"
  fresh n1 31; out=$(tick)
  [ "$(alerts)" = 1 ] && [ -f "$rec" ] || fail "(b) one nothing-lands alert: $(ls "$HOME_D/state/alerts" 2>/dev/null)"
  assert_contains "$(cat "$rec")" "rung=2" "(b) the alert starts at rung 2"
  assert_contains "$(cat "$rec")" "ready lane(s) wait" "(b) the alert says what waits"
  [ "$(aword "$key")" = open ] || fail "(b) the alert is open: $(aword "$key")"
  grep -q "alert-$key" "$HOME_D/state/wake-queue"* 2>/dev/null || grep -rqs "alert-$key" "$HOME_D/state" || fail "(b) the alert reached the lead as a wake"
  # (c) a second tick adds no alert.
  out=$(tick); [ "$(alerts)" = 1 ] || fail "(c) a second tick adds no alert"
  # (e) a tick prints nothing to stdout, and no warning to stderr.
  [ -z "$out" ] || fail "(e) a tick prints nothing to stdout: $out"
  [ ! -s "$W/tick.err" ] || fail "(e) a tick prints no warning: $(cat "$W/tick.err")"
  # (d) a landing row written now resolves it at the next tick.
  printf 'n1\tproj\t%s\t%s\tfull\n' "$(git -C "$PROJ" rev-parse trunk)" "$(date +%s)" >> "$HOME_D/data/trunk-landings.tsv"
  tick >/dev/null
  [ "$(aword "$key")" = resolved ] || fail "(d) a landing resolves the alert"
  pass 'a project where nothing lands raises one alert and a landing resolves it'
}

test_an_emptied_queue_resolves_the_alert() {
  local key=fleet-blocked--proj-nothing-lands
  world nolands2
  printf 'flush-at-ready=99\nflush-after-minutes=999999\n' >> "$HOME_D/config/trunk-policy"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  lane n2 two f2.txt; fresh n2 40; tick >/dev/null
  [ "$(aword "$key")" = open ] || fail "a 40 minute wait with no landing raises the alert"
  rm -f "$HOME_D/state/n2.meta"; tick >/dev/null
  [ "$(aword "$key")" = resolved ] || fail "a project with no ready lane left resolves the alert"
  pass 'an emptied queue resolves the alert'
}

test_a_ready_lane_that_nothing_lands_behind_raises_one_alert_until_something_lands
test_an_emptied_queue_resolves_the_alert
printf 'jg-trunk-nothing-lands: ok\n'
