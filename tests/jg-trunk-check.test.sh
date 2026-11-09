#!/usr/bin/env bash
# Integration test for core/trunk-landing and the landing gates of bin/jg-trunk.sh: the registered check that lands a proved
# lane by itself, going live on the fleet's homes, the gate that charges a lane only for what it broke, and the rebase.
# Real git repositories, a local bare origin, the real gate chain and a stub for the captain-hold reader.
#
# T7 The registered check core/trunk-landing lands a task whose last status line is its done, with no human step, and
#    never goes live; it ignores a task that is not done, reports a refusal once (a conflict names its paths), retries a
#    refusal that only needs time, cleans a landed task up unforced, and runs on the watcher's fast tick.
# T11 The landing gate charges a lane only for what it broke: a script red on the trunk tip in the same way does not block
#    (it is reported once per tip tree, and the green pin stays), while a script that fails only on the lane, passes on the
#    tip, or fails differently on the lane blocks it, with the tip's rerun done in the environment the gate ended with.
#    A failure gets one rerun on the lane before it is judged: one that passes on the rerun is flaky and not charged.
# T12 A landing is one fast check: the lander rebases the lane's one commit onto the tip by itself (the lane follows it).
# tests/jg-trunk.test.sh, tests/jg-trunk-check.test.sh and tests/jg-trunk-queue.test.sh split one local trunk flow into three
# suites that each stay inside the fast set's weight limit; tests/jg-trunk-fixture.sh holds the fixture they share.
# The done-done journey journeys/trunk-landing.sh runs all three and seals their output.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-trunk-check)
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# A fleet: the code home (a clone of the project's origin, as Main's checkout is) and two registered Squad Lead homes
# (worktrees of it), all on the last release, a go-live waiver, and the home's own bin so the landing check runs.
fleet_world() {  # <name> [rig]: sets W HOME_D PROJ CODE_ROOT BASE; rig makes the post-landing suite the rig's t/*.test.sh
  local id
  world "$1"
  [ "${2-}" != rig ] || { rig; printf 'gate-full=! grep -q BAD work.txt\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"; }
  rm "$HOME_D/config/live-hook.proj"
  CODE_ROOT="$W/homecode"; git clone -q "$(git -C "$PROJ" remote get-url origin)" "$CODE_ROOT"
  BASE=$(git -C "$CODE_ROOT" rev-parse HEAD)
  for id in lead-a lead-b; do
    git -C "$CODE_ROOT" worktree add -q --detach "$W/$id" "$BASE"; printf '%s\n' "$id" > "$W/$id/.jg-squad-lead-home"
    printf -- '- %s - fixture (home: %s; scope: x; projects: proj; added 2026-11-09)\n' "$id" "$W/$id" >> "$HOME_D/data/squad_leads.md"
  done
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  trunk waiver "$PROJ" --rule owner-rule-test >/dev/null || fail "the Overwatch path must write the waiver"
}
# Sweeps of the landing check, as a home runs them (its own bin, the code home a clone of the origin), until <pattern> shows
# in what they print or the job that follows a landing has ended; prints what they printed.
fleet_sweeps() {  # <pattern>
  local acc=''
  for _ in $(seq 1 200); do
    acc="$acc$(JG_ROOT_OVERRIDE="$CODE_ROOT" JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")"$'\n'
    printf '%s' "$acc" | grep -q -- "$1" && break; sleep 0.2
  done
  printf '%s' "$acc"
}
homes_at() {  # <sha>: Main's code home and both Squad Lead homes are at it
  local h
  for h in "$CODE_ROOT" "$W/lead-a" "$W/lead-b"; do [ "$(git -C "$h" rev-parse HEAD)" = "$1" ] || return 1; done
}

# age_landings <newest-minutes> <oldest-minutes>: the landings on record happened that long ago (the first the oldest, the last the newest).
age_landings() {
  local now t; now=$(date +%s); t=$(wc -l < "$HOME_D/data/trunk-landings.tsv")
  awk -F'\t' -v OFS='\t' -v n="$now" -v new="$(( $1 * 60 ))" -v old="$(( $2 * 60 ))" -v t="$t" '{ $4 = n - (NR < t ? old : new); print }' "$HOME_D/data/trunk-landings.tsv" > "$HOME_D/data/trunk-landings.tsv.new" \
    && mv "$HOME_D/data/trunk-landings.tsv.new" "$HOME_D/data/trunk-landings.tsv"
}
# age_live: every go-live on record happened two hours ago, so a landing after it is a new batch.
age_live() {
  awk -F'\t' -v OFS='\t' -v n="$(date +%s)" '{ $3 = n - 7200; print }' "$HOME_D/data/trunk-live.tsv" > "$HOME_D/data/trunk-live.tsv.new" && mv "$HOME_D/data/trunk-live.tsv.new" "$HOME_D/data/trunk-live.tsv"
}
await_green() {  # the post-landing suite has moved the green pin to the trunk tip
  local _; for _ in $(seq 1 200); do [ "$(cat "$HOME_D/state/trunk-green-proj" 2>/dev/null)" = "$(tip)" ] && return 0; sleep 0.2; done; return 1
}

test_a_quiet_trunk_goes_live_on_every_home_by_itself() {
  local out c h
  fleet_world autolive; lane g1 good; c=$(git -C "$PROJ" rev-parse fm/g1)
  homes_at "$BASE" || fail "fixture: every home starts on the release"
  fleet_sweeps "landed g1" >/dev/null; await_green || fail "the post-landing suite must move the green pin"
  # A landing never waits on a go-live, and a fresh landing is not live yet: the trunk is not quiet.
  homes_at "$BASE" || fail "a fresh landing must not go live at once"
  out=$(trunk autolive "$PROJ" 2>&1 | tail -n 1); assert_contains "$out" "autolive: waiting: live in about" "a busy trunk waits for its quiet window"
  # 25 quiet minutes later (default window 20) the check's own tick moves every home, with no word and no model turn.
  age_landings 25 25
  out=$(fleet_sweeps "proj: live at")
  assert_contains "$out" "proj: live at ${c:0:12} on every home" "the outbox must say every home moved"
  homes_at "$c" || fail "a quiet trunk must move Main and every Squad Lead home: $(cat "$HOME_D/data/trunk-live.tsv" 2>/dev/null)"
  [ ! -e "$HOME_D/state/trunk-word-live-proj" ] && [ ! -e "$HOME_D/data/trunk-words.tsv" ] || fail "the waiver records and spends no word"
  for h in lead-a lead-b primary; do grep -q "^proj:$h	$c	[0-9]*	live" "$HOME_D/data/trunk-live.tsv" || fail "$h needs a live row: $(cat "$HOME_D/data/trunk-live.tsv")"; done
  [ "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" = "autolive: already live at ${c:0:12}" ] || fail "a commit that is live is not moved twice"
  # The knob moves the window: 3 quiet minutes is not enough under 5 and is under 2; a red CI then pins EVERY home back at once.
  age_live; lane g2 two; fleet_sweeps "landed g2" >/dev/null; await_green || fail "g2 must verify"
  age_landings 3 3; printf 'live-quiet-minutes=5\n' >> "$HOME_D/config/trunk-policy"
  assert_contains "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" "waiting" "3 quiet minutes is not enough under a 5 minute window"
  printf 'live-quiet-minutes=2\n' >> "$HOME_D/config/trunk-policy"
  assert_contains "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" "live at $(tip | cut -c1-12)" "the quiet window is a policy knob"
  homes_at "$(tip)" || fail "the second batch must move every home"
  trunk ci "$PROJ" "$(tip)" red >/dev/null 2>&1 || fail "a red CI must record and pin back"
  homes_at "$c" || fail "a red CI must pin every home back to the last green live commit at once"
  grep -q "^proj:lead-a	$c	[0-9]*	live,pinned-back-from:" "$HOME_D/data/trunk-live.tsv" || fail "the pin-back row names where the home came from"
  pass 'a quiet trunk goes live on Main and every Squad Lead home by itself, the window is a knob, and a red CI pins every home back'
}

test_a_busy_trunk_goes_live_at_the_hourly_cap() {
  local out c
  fleet_world autolive-cap; lane b1 one; fleet_sweeps "landed b1" >/dev/null; await_green || fail "b1 must verify"
  lane b2 two; fleet_sweeps "landed b2" >/dev/null; await_green || fail "b2 must verify"
  c=$(tip)
  # Landings keep coming (the newest one a minute ago) but the oldest not-yet-live one is 59 minutes old: still waiting.
  age_landings 1 59
  assert_contains "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" "waiting" "59 minutes of landings is under the 60 minute cap"
  homes_at "$BASE" || fail "nothing may move before the cap"
  age_landings 1 61
  out=$(trunk autolive "$PROJ" 2>&1 | tail -n 1); assert_contains "$out" "live at ${c:0:12} on every home" "the cap makes the trunk go live while landings continue"
  homes_at "$c" || fail "the hourly cap must move every home: $(cat "$HOME_D/data/trunk-live.tsv" 2>/dev/null)"
  # Landings after that go live in the next batch, not at once: the cap counts from what is not live yet.
  lane b3 three; fleet_sweeps "landed b3" >/dev/null; await_green || fail "b3 must verify"
  assert_contains "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" "waiting" "a landing after a go-live starts a new batch"
  pass 'a trunk that keeps landing still goes live once the oldest landing not yet live is an hour old, and the next landing starts a new batch'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_red_or_unwaived_landing_never_goes_live() {
  local out c
  fleet_world autolive-red rig
  # A head the landing check refuses never lands and no home moves.
  lane r1 BAD
  out=$(fleet_sweeps "r1 not landed")
  assert_contains "$out" "r1 not landed" "a red head is refused by the landing gate"
  homes_at "$BASE" || fail "a refused head must not move any home: $out"
  # A head that passes the landing check and breaks the whole suite: landed, reverted, and no home ever moves to it.
  lane r2 'echo "not ok - r2 breaks the suite" >&2; exit 1' t/r2.test.sh; c=$(git -C "$PROJ" rev-parse fm/r2)
  out=$(fleet_sweeps "r2: the whole suite is red")
  assert_contains "$out" "r2: the whole suite is red at" "the red post-landing suite is reported and nothing goes live"
  git -C "$PROJ" log --format=%B trunk | grep -q '^reverts: ' || fail "a post-landing red is reverted by itself"
  age_landings 30 30; trunk autolive "$PROJ" >/dev/null 2>&1
  homes_at "$BASE" || fail "a red post-landing suite must not move any home, even after the quiet window: $(cat "$HOME_D/data/trunk-live.tsv" 2>/dev/null)"
  ! grep -q "	$c	" "$HOME_D/data/trunk-live.tsv" 2>/dev/null || fail "the red commit is never live: $(cat "$HOME_D/data/trunk-live.tsv")"
  # A standing red pin holds the live step on a green pin, and says so once.
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-green-proj"; printf '%s\n' "$c" > "$HOME_D/state/trunk-red-proj"
  out=$(trunk autolive "$PROJ" 2>&1 | tail -n 1); assert_contains "$out" "held: the trunk is red at ${c:0:12}" "a red pin holds the live step"
  trunk autolive "$PROJ" >/dev/null 2>&1
  [ "$(grep -c "held:the trunk is red" "$HOME_D/data/trunk-live.tsv")" = 1 ] || fail "a hold is recorded once per reason: $(cat "$HOME_D/data/trunk-live.tsv")"
  homes_at "$BASE" || fail "a red trunk must not move any home"
  # With no waiver the word rule stands, and a worker never runs the live step.
  rm -f "$HOME_D/state/trunk-red-proj" "$HOME_D/config/trunk-live-waiver"
  out=$(trunk autolive "$PROJ" 2>&1 | tail -n 1); assert_contains "$out" "needs the captain's word" "no waiver, no automatic live"
  homes_at "$BASE" || fail "no waiver must not move any home"
  out=$(JG_TASK_ID=x trunk autolive "$PROJ" 2>&1) && fail "a worker must never run the live step"
  pass 'a red head, a red post-landing suite, a red pin and a missing waiver never move a home'
}

test_the_registered_check_lands_a_proved_task_without_a_human() {
  local out c
  world auto
  # the check runs the home's own bin, so the fixture home needs the copied bin and a mode the check reads
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane a1 one; lane a2 two; rm "$HOME_D/state/a2.status"
  sweep >/dev/null; out=$(sweep)
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/a1)" ] || fail "the check must land the proved task by itself: $out"
  assert_contains "$out" "landed a1" "the landing must be reported"
  assert_contains "$out" "cleaned up" "a landed task must be cleaned up"
  [ "$(cat "$W/teardown-calls")" = a1 ] || fail "cleanup must run unforced: jg-teardown.sh <id> and nothing else"
  [ -z "$(sweep)" ] || fail "a reported landing must not repeat"
  [ ! -e "$W/live-moves" ] || fail "the check must never go live"
  git -C "$PROJ" merge-base --is-ancestor "$(git -C "$PROJ" rev-parse fm/a2)" trunk && fail "a task that is not done must not land"
  git -C "$W/lanes/a2" reset -q --hard "$(git -C "$PROJ" rev-parse trunk~1)"; commit_in "$W/lanes/a2" work.txt clash "ticket a2"; prove a2; ready a2
  sweep >/dev/null; out=$(sweep)
  assert_contains "$out" "a2 not landed" "a refusal must be reported"
  assert_contains "$out" "in: work.txt" "a conflict must name its paths"
  [ -z "$(sweep)" ] || fail "a final refusal must be reported once"
  lane a3 three; : > "$HOME_D/state/.afk"
  sweep >/dev/null; assert_contains "$(sweep)" "a3 waits to land" "a time-only refusal must be reported"
  [ -z "$(sweep)" ] || fail "a waiting refusal must not repeat"
  rm "$HOME_D/state/.afk"; sweep >/dev/null; sweep >/dev/null
  c=$(git -C "$PROJ" rev-parse fm/a3); [ "$(tip)" = "$c" ] || fail "a waiting task must land once the wait clears"
  pass 'the registered check lands a proved task by itself, reports refusals once, and never goes live'
}

test_the_watcher_runs_the_landing_check_on_its_fast_tick() {
  local c out rc=0 st
  world outer-watch
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  printf 'off\n' > "$HOME_D/config/wake-bus"
  lane ready one; c=$(git -C "$PROJ" rev-parse fm/ready)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/tmux"; chmod +x "$W/fakebin/tmux"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$W/fakebin/systemctl"; chmod +x "$W/fakebin/systemctl"
  printf '#!/usr/bin/env bash\nsleep 0.2\nexec %s "$@"\n' "$(command -v setsid)" > "$W/fakebin/setsid"; chmod +x "$W/fakebin/setsid"
  JG_HOME="$HOME_D" JG_STATE_OVERRIDE="$HOME_D/state" bash -c \
    '. "$1"; jg_wake_append check urgent "check: waiting-state urgent blocker"' _ "$ROOT/bin/jg-wake-lib.sh" \
    || fail "could not queue the urgent wake"
  JG_HOME="$HOME_D" "$ROOT/bin/jg-bus.sh" watcher oldest >/dev/null || fail "could not observe the queued wake"
  sleep 2
  out=$(env -u JG_TASK_ID PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" \
    JG_STATE_OVERRIDE="$HOME_D/state" JG_CONFIG_OVERRIDE="$HOME_D/config" JG_POLL=1 JG_SIGNAL_GRACE=0 \
    JG_WATCH_HANDLING_SUCCESSOR=1 JG_SQUAD_LEAD_WAKE_STALL_SECS=1 JG_FAST_CHECK_INTERVAL=0 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 \
    timeout 60 "$HOME_D/bin/jg-watch.sh" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "outer watcher failed ($rc): $out"
  assert_contains "$out" 'check: waiting-state urgent blocker' 'the urgent wake must still be delivered'
  st="$HOME_D/data/jg-trunk-landing/ready.$c.state"
  [ -e "$st" ] || fail "urgent queue exit skipped the eligible ready/PASS landing check: $out"
  printf 'outer-check: ready/PASS dispatch exists before urgent wake exit; fixture=%s\n' "$W"
  for _ in $(seq 1 600); do grep -Eq '^landed( |$)' "$st" && break; sleep 0.1; done
  grep -Eq '^landed( |$)' "$st" || fail "detached landing did not finish: $(cat "$st" "$HOME_D/data/jg-trunk-landing/ready.$c.log")"
  [ "$(tip)" = "$c" ] || fail "outer watcher dispatched but did not land the exact ready head"
  [ ! -e "$W/live-moves" ] || fail "outer watcher must never release or go live"
  pass 'real outer watcher dispatches and lands ready/PASS before an urgent queued wake exits; never goes live'
}

test_the_landing_check_cuts_the_next_trunk_once_the_release_merged() {
  local out
  world rolcheck
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane k1 one; trunk land k1 >/dev/null 2>&1 || fail "k1 must land"
  trunk verify "$PROJ" >/dev/null 2>&1; trunk word release "$PROJ" "ship it" >/dev/null 2>&1; trunk release "$PROJ" >/dev/null 2>&1 || fail "release must open"
  out=$(sweep); [ -z "$out" ] || fail "an open release must change nothing: $out"
  printf 'merged\n' > "$W/pr-state"; git -C "$PROJ" push -q origin "$(tip):refs/heads/main"; rm -f "$HOME_D"/data/jg-trunk-landing/.rollover-*
  out=$(sweep); assert_contains "$out" "release merged: the project is now on trunk-v2" "the check must cut the next trunk"
  git -C "$PROJ" rev-parse --verify -q trunk-v2 >/dev/null || fail "trunk-v2 must exist"
  pass 'the landing check cuts the next trunk once the release merged'
}

test_the_bundled_hook_moves_a_home_that_runs_the_project() {
  local c out rc base
  world home
  rm "$HOME_D/config/live-hook.proj"
  git clone -q "$(git -C "$PROJ" remote get-url origin)" "$W/homecode"
  lane h1 hook; c=$(git -C "$PROJ" rev-parse fm/h1)
  out=$(CODE_ROOT="$W/homecode" trunk land h1 2>&1) || fail "h1 must land: $out"
  [ "$(git -C "$W/homecode" rev-parse HEAD)" != "$c" ] || fail "landing alone must not move the home checkout"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "h1 must verify"
  trunk word live "$PROJ" "go" >/dev/null 2>&1
  out=$(CODE_ROOT="$W/homecode" trunk live "$PROJ" 2>&1) || fail "live must move a home that runs the project: $out"
  [ "$(git -C "$W/homecode" rev-parse HEAD)" = "$c" ] || fail "the home checkout must be fast-forwarded to the landed commit: $out"
  grep -Eq "^proj	$c	[0-9]+	live$" "$HOME_D/data/trunk-live.tsv" || fail "the live record must say live"
  base=$(cat "$HOME_D/state/trunk-released-proj")
  out=$(CODE_ROOT="$W/homecode" trunk ci "$PROJ" "$c" red 2>&1) || fail "a red CI must pin the bundled home back: $out"
  [ "$(git -C "$W/homecode" rev-parse HEAD)" = "$base" ] || fail "the home checkout must return to the last release when no earlier commit was live: $out"
  rm -f "$HOME_D/state/trunk-red-proj"; printf '%s\n' "$c" > "$HOME_D/state/trunk-green-proj"
  rm "$HOME_D/data/trunk-live.tsv"; printf 'dirty\n' >> "$W/homecode/README.md"
  lane h2 hook2; CODE_ROOT="$W/homecode" trunk land h2 >/dev/null 2>&1 || fail "h2 must land"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "h2 must verify"
  trunk word live "$PROJ" "go" >/dev/null 2>&1
  rc=0; out=$(CODE_ROOT="$W/homecode" trunk live "$PROJ" 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a live whose home did not move must exit 3, got $rc: $out"
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/h2)" ] || fail "the commit must stay landed when only the live step failed"
  assert_contains "$(cat "$HOME_D/data/trunk-live.tsv")" hook-failed "a home that did not move must be recorded as such"
  pass 'the bundled hook fast-forwards the home and a dirty home is recorded as not moved'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_full_gate_charges_a_lane_only_for_what_it_broke() {
  local out tipc green
  world base; rig; seed_red_tip; tipc=$(tip)
  # A lane that adds a failing script of its own: blocked by name, and the tip's red is reported.
  lane intro 'echo "not ok - lane case" >&2; exit 1' t/b.test.sh
  refused 'a failure only the lane has' intro 't/b.test.sh'
  assert_contains "$(trunk land intro 2>&1 || true)" "introduced or changed" "the refusal must say the lane caused it"
  # A lane that makes the tip's red worse (an added failing case in the same script): blocked.
  lane worse '[ "${GATE_MARK:-}" = yes ] && { echo "not ok - tip case" >&2; echo "not ok - new case" >&2; exit 1; }; exit 0' t/a.test.sh
  refused 'a different red in the same script' worse 't/a.test.sh'
  # A lane that breaks a script that passes on the tip: blocked.
  lane breaks 'echo "not ok - broke c" >&2; exit 1' t/c.test.sh
  refused 'a script that passes on the tip' breaks 't/c.test.sh'
  # Reported once for the tip tree: one wake and one note, however many lanes met it; and the tip was rerun once.
  [ "$(grep -c . "$W/backlog-calls")" = 1 ] || fail "the tip's red must be noted once: $(cat "$W/backlog-calls")"
  [ "$(grep -c 'trunk-tip-red-proj-' "$HOME_D/state/.wake-queue")" = 1 ] || fail "the tip's red must raise one alert: $(cat "$HOME_D/state/.wake-queue" 2>&1)"
  assert_contains "$(cat "$W/backlog-calls")" "update ticket-red --append-notes" "the note goes to the red ticket"
  assert_contains "$(cat "$W/backlog-calls")" "t/a.test.sh" "the note names the red script"
  [ "$(grep -c '^t/a.test.sh' "$HOME_D/data/trunk/"tip-results-proj-*.tsv)" = 1 ] || fail "the tip's result for a script is computed once"
  assert_contains "$(cat "$HOME_D/data/trunk/tip-red-reported-proj.tsv")" "t/a.test.sh" "the report is recorded by script and tip tree"
  [ "$(tip)" = "$tipc" ] || fail "no refused lane moves the trunk"
  # A lane that touches only what is unrelated lands; the tip's red is set aside, not charged, and the green pin stays.
  lane good 'exit 0' t/d.test.sh
  green=$(cat "$HOME_D/state/trunk-green-proj")
  out=$(trunk land good 2>&1) || fail "a lane that adds no red must land on a red tip: $out"
  assert_contains "$out" "not charged to this lane" "the landing must say it set the tip's red aside"
  assert_contains "$out" "gate=full-tip-red" "the landing must record that the gate was set against the tip"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$green" ] || fail "a landing that set red aside must not move the green pin"
  [ "$(grep -c . "$W/backlog-calls")" = 1 ] && [ "$(grep -c 'trunk-tip-red-proj-' "$HOME_D/state/.wake-queue")" = 1 ] || fail "the same tip tree is not reported twice"
  pass 'the full gate blocks only what the lane broke: new, worse and broken-passing scripts block; the tip'"'"'s own red lands, reported once'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_flaky_failure_gets_one_rerun_before_it_is_judged() {
  local out green
  world flaky; rig; seed_red_tip; green=$(cat "$HOME_D/state/trunk-green-proj")
  # Fails the first time the gate runs it and passes the second: judged flaky, so the lane lands beside the tip's own red.
  lane once "[ -e $W/seen ] || { : > $W/seen; echo 'not ok - flaky case' >&2; exit 1; }; exit 0" t/f.test.sh
  out=$(trunk land once 2>&1) || fail "a failure that passes on its one rerun must not block: $out"
  assert_contains "$out" "judged flaky" "the landing must say it set a flaky failure aside"
  assert_contains "$out" "gate=full-tip-red" "the tip's own red is still set aside and recorded"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$green" ] || fail "a rerun landing must not move the green pin"
  # The same script failing on both runs is the lane's own failure.
  lane twice 'echo "not ok - solid case" >&2; exit 1' t/g.test.sh
  refused 'a failure that repeats on the rerun' twice 't/g.test.sh'
  pass 'a failure gets one rerun before it is judged: a flaky one is set aside, a repeated one blocks'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_tip_red_that_prints_its_elapsed_seconds_is_the_same_red_on_every_run() {
  local out
  world elapsed; rig
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  # A Go test prints its run time on the last line, so the tip's red reads differently on every run.
  commit_in "$W/seed" t/h.test.sh '[ "${GATE_MARK:-}" = yes ] || exit 0; n=$(cat '"$W"'/runs 2>/dev/null || echo 0); echo $((n + 1)) > '"$W"'/runs; printf "FAIL\\tpkg/x\\t2%s.%s3s\\n" "$n" "$n" >&2; exit 1' "seed h"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  lane good 'exit 0' t/d.test.sh
  out=$(trunk land good 2>&1) || fail "a lane must land beside a tip red that differs from its own run only by elapsed seconds: $out"
  assert_contains "$out" "not charged to this lane" "the tip's red is set aside"
  pass "a tip red that prints its elapsed seconds is the same red on every run, so no lane is charged for it"
}

test_configured_hooks_and_the_launch_overlay_preserve_trunk_protection() {
  local c before out rc=0 hook_kind owner_hash
  for hook_kind in configured owner-guard; do
  rc=0
  world "hook-context-$hook_kind"
  lane hook good; c=$(git -C "$PROJ" rev-parse fm/hook); before=$(tip)
  mkdir -p "$W/repository-hooks"
  if [ "$hook_kind" = owner-guard ]; then
    sed -e 's/__NAME__/reference-transaction/g' -e "s|__CAT__|$(command -v cat)|g" \
      -e "s|__MKTEMP__|$(command -v mktemp)|g" -e "s|__RM__|$(command -v rm)|g" \
      "$ROOT/core/owner-guard/global-hook.sh" > "$W/repository-hooks/reference-transaction"
    chmod 555 "$W/repository-hooks/reference-transaction"
    owner_hash=$(git hash-object "$W/repository-hooks/reference-transaction")
  fi
  git -C "$PROJ" config core.hooksPath "$W/repository-hooks"
  "$ROOT/bin/jg-git-strip-ai-trailers.sh" install "$W/launch-hooks" "$PROJ"
  "$ROOT/bin/jg-git-strip-ai-trailers.sh" env-file "$W/launch-hooks" "$W/launch-env"
  # A real child shell inherits exactly the env-file entry the spawn path emits.
  (
    # shellcheck source=/dev/null # The real launch helper emitted this environment file.
    . "$W/launch-env"
    trunk due "$PROJ" >/dev/null 2>&1 || true
    [ "$(git -C "$PROJ" rev-parse --path-format=absolute --git-path hooks/reference-transaction)" = "$W/launch-hooks/reference-transaction" ] || fail "the launched environment lost its configured hook directory"
    out=$(git -C "$PROJ" update-ref refs/heads/trunk "$c" "$before" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "the task overlay bypassed the repository trunk guard"
    assert_contains "$out" 'moves only through' 'the actual configured hook must refuse the unauthorized movement'
    [ "$(tip)" = "$before" ] || fail "a refused transaction moved the trunk"
    trunk land hook >/dev/null 2>&1 || fail "the same configured hook must allow the guarded landing"
  ) || fail "configured hook journey failed"
  [ "$(tip)" = "$c" ] || fail "the authorized landing did not move the trunk"
  if [ "$hook_kind" = owner-guard ]; then
    [ "$(git hash-object "$W/repository-hooks/reference-transaction")" = "$owner_hash" ] || fail "the existing owner hook was changed"
  fi
  pass "the spawned Git environment preserves $hook_kind hooks and repository trunk protection"
  done
}

test_admission_is_shared_by_manual_and_automatic_requests() {
  local c out rc=0 first_log
  world admission
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane once BAD; c=$(git -C "$PROJ" rev-parse fm/once)
  printf 'gate-full=echo first >> "%s/calls"; while [ ! -e "%s/release" ]; do sleep 0.1; done; echo original; exit 1\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 100); do [ ! -s "$W/calls" ] || break; sleep 0.1; done
  [ -s "$W/calls" ] || fail "automatic request did not enter its gate"
  out=$(trunk land once 2>&1) || rc=$?
  : > "$W/release" # release our own attempt even when the assertion below fails
  [ "$rc" = 75 ] || fail "a concurrent manual request must report in progress (75): $out"
  assert_contains "$out" IN_PROGRESS "a concurrent request must name its typed outcome"
  sweep >/dev/null
  first_log=$(find "$HOME_D/data/jg-trunk-landing" -name gate-full.log -print | head -n 1)
  out=$(trunk land once 2>&1) && fail "an unchanged failed gate must stay refused"
  [ "$(wc -l < "$W/calls" | tr -d ' ')" = 1 ] || fail "unchanged failure reran its gate"
  printf 'gate-full=echo second >> "%s/calls"; echo changed; exit 1\n' "$W" >> "$HOME_D/config/trunk-policy"
  trunk land once >/dev/null 2>&1 && fail "a changed failing context must refuse"
  [ "$(wc -l < "$W/calls" | tr -d ' ')" = 2 ] || fail "changed context must get one attempt"
  [ "$(cat "$first_log")" = original ] || fail "a later attempt overwrote the original gate log"
  [ "$(find "$HOME_D/data/jg-trunk-landing" -name gate-full.log | wc -l | tr -d ' ')" = 2 ] || fail "every attempt must keep its gate log"
  [ "$(tip)" != "$c" ] || fail "failed proof must never move the trunk"
  pass 'automatic/manual requests share admission, unchanged failure stays cached, and changed attempts retain their logs'
}

test_a_home_with_other_shas_is_contained_only_when_the_trunk_took_its_changes() {
  local g="$TMP_ROOT/contained" t m h rc=0 out
  jg_git_init_commit "$g"; commit_in "$g" a.txt one "base"; t=$(git -C "$g" rev-parse HEAD)
  git -C "$g" checkout -q -b home; commit_in "$g" a.txt two "home change"; commit_in "$g" b.txt new "home file"; h=$(git -C "$g" rev-parse HEAD)
  git -C "$g" checkout -q -b trunk2 "$t"; commit_in "$g" a.txt two "the trunk takes it as one squash"; commit_in "$g" b.txt new "squash part 2"
  commit_in "$g" a.txt three "a later trunk commit supersedes it"; m=$(git -C "$g" rev-parse HEAD)
  "$ROOT/bin/jg-home-contained.sh" "$h" "$m" "$g" || fail "a home whose changes are on the trunk (one later superseded) must be contained"
  "$ROOT/bin/jg-home-contained.sh" "$t" "$m" "$g" || fail "an ancestor of the trunk is contained"
  git -C "$g" checkout -q home; commit_in "$g" c.txt stray "stray commit"; h=$(git -C "$g" rev-parse HEAD)
  out=$("$ROOT/bin/jg-home-contained.sh" "$h" "$m" "$g") || rc=$?
  [ "$rc" = 1 ] || fail "a home with a change the trunk never took must exit 1, got $rc"
  assert_contains "$out" 'uncontained: c.txt' "the uncontained path must be named"
  case $out in *a.txt*|*b.txt*) fail "contained paths must not be listed: $out" ;; esac
  rc=0; "$ROOT/bin/jg-home-contained.sh" "$h" nope "$g" 2>/dev/null || rc=$?
  [ "$rc" = 2 ] || fail "an unknown commit must exit 2, got $rc"
  pass 'jg-home-contained proves tree containment: same bytes, a superseding trunk commit, or the named uncontained paths'
}

# shellcheck disable=SC2016 # the policy lines are written out verbatim and expand when the gate runs them
test_a_project_that_is_not_juggernaut_never_runs_juggernauts_gates() {
  local out rc=0 sha lib="$ROOT/bin/jg-trunk-policy-lib.sh"
  world foreign
  rm -f "$HOME_D/config/trunk-policy"  # no override at all: the built-in defaults decide, and they are Juggernaut's own suite
  # The fixture tracks a file under data/, which Juggernaut's own invariant would reject silently (an empty log, a red pin).
  lane f1 one data/notes.txt
  out=$(trunk land f1 2>&1) || fail "a project with no gates set must land with none run: $out"
  assert_contains "$out" "no landing gate" "the landing must say it ran no gate"
  assert_contains "$(cat "$HOME_D/data/trunk-landings.tsv")" "no-gate" "the landing must record that no gate ran"
  sha=$(tip)
  out=$(trunk verify "$PROJ" "$sha" 2>&1) || fail "verify with no gate must not fail: $out"
  assert_contains "$out" "no verify gate for proj" "verify must say it had no gate"
  [ ! -e "$HOME_D/state/trunk-red-proj" ] || fail "no gate means nothing can go red"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$sha" ] || fail "verify with no gate must leave the trunk green so the home can go on"
  # A red pin the old default wrote is cleared by running verify again, and landings resume.
  printf '%s\n' "$sha" > "$HOME_D/state/trunk-red-proj"; rm -f "$HOME_D/state/trunk-green-proj"
  trunk verify "$PROJ" "$sha" >/dev/null 2>&1 || fail "verify must clear a red pin the removed default wrote"
  [ ! -e "$HOME_D/state/trunk-red-proj" ] || fail "verify must clear that red pin"
  # The project's own gate-full is its verify gate when it set no gate-verify; its own gate-verify wins over it; both fail for real.
  printf 'gate-full@proj=test ! -e BAD\n' > "$HOME_D/config/trunk-policy"
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$HOME_D/config' jg_trunk_gate gate-verify proj '$PROJ' trunk")
  [ "$out" = 'test ! -e BAD' ] || fail "a project with only gate-full@proj must verify with it, got '$out'"
  printf 'gate-full@proj=true\ngate-verify@proj=false\n' > "$HOME_D/config/trunk-policy"
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$HOME_D/config' jg_trunk_gate gate-verify proj '$PROJ' trunk")
  [ "$out" = false ] || fail "gate-verify@proj must win over gate-full@proj, got '$out'"
  rc=0; trunk verify "$PROJ" "$sha" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a project's own failing gate-verify must still fail verify"
  # A repository that carries Juggernaut's own suite keeps the built-in defaults.
  mkdir -p "$W/self/bin"; : > "$W/self/bin/jg-test-run.sh"; git init -q "$W/self"; git -C "$W/self" add -A
  git -C "$W/self" -c user.name=t -c user.email=t@example.invalid commit -q -m self
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$W/none' jg_trunk_gate gate-verify self '$W/self' HEAD")
  assert_contains "$out" "bin/jg-test-run.sh --all" "the Juggernaut repository must keep its built-in verify gate"
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$W/none' jg_trunk_gate gate-verify proj '$PROJ' trunk") && fail "another project must have no built-in gate, got '$out'"
  pass 'a project that is not Juggernaut runs only the gates its home set for it, and none clears its red pin'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_gates_are_policy_keys_with_fast_defaults() {
  local key
  pol() { JG_CONFIG_OVERRIDE="$TMP_ROOT/no-config" bash -c ". '$ROOT/bin/jg-trunk-policy-lib.sh'; jg_trunk_policy $1"; }
  assert_contains "$(pol gate-lint)" "--changed-base HEAD^" "the landing lint must cover the changed files only"
  assert_contains "$(pol gate-full)" "--required-shards HEAD^" "the landing tests must be the changed files' tests, run as the parallel shards"
  case $(pol gate-full) in *"--all"*) fail "the landing must not run the whole suite" ;; esac
  assert_contains "$(pol gate-verify)" "bin/jg-test-run.sh --all" "verify must run the whole suite"
  for key in gate-mode gate-smoke owner-rules; do pol "$key" >/dev/null 2>&1 && fail "the retired policy key $key must be gone"; done
  pass 'the landing gates are policy keys: the lint and tests cover the changed files, the whole suite is verify'"'"'s'
}

test_a_landing_rebases_the_lane_by_itself() {
  local out rows c1 c2 c3
  world rebase
  # The merge gate of this home refuses every merge for a missing signature: a landing no longer asks it.
  printf '#!/usr/bin/env bash\necho "merge refused: no valid local proof signature" >&2\nexit 1\n' > "$HOME_D/config/merge-gate"; chmod +x "$HOME_D/config/merge-gate"
  lane r1 one a.txt; lane r2 two b.txt; lane r3 three c.txt
  c1=$(git -C "$PROJ" rev-parse fm/r1)
  out=$(trunk land r1 2>&1) || fail "a lane with its whole proof must land: $out"
  [ "$(tip)" = "$c1" ] || fail "r1 must be on the trunk as it is"
  # r2 is based on the old tip: the lander rebases it (its proof is for the head it reported), the lane follows, its worktree stays clean.
  c2=$(git -C "$PROJ" rev-parse fm/r2)
  out=$(trunk land r2 2>&1) || fail "a lane on a moved tip must land by being rebased: $out"
  [ "$(tip)" != "$c2" ] && [ "$(git -C "$PROJ" rev-parse "$(tip)^")" = "$c1" ] || fail "the rebased commit must sit directly on the previous tip"
  [ "$(git -C "$PROJ" rev-parse fm/r2)" = "$(tip)" ] || fail "the lane must follow its rebased commit"
  [ -z "$(git -C "$W/lanes/r2" status --porcelain)" ] && [ "$(git -C "$W/lanes/r2" rev-parse HEAD)" = "$(tip)" ] || fail "the lane's worktree must follow the rebase and stay clean"
  [ "$(git -C "$PROJ" log -1 --format=%s "$(tip)")" = "ticket r2" ] || fail "the rebased commit must keep the lane's message"
  # A lane whose worktree has unsaved work lands, and the work is left alone.
  printf 'unsaved\n' > "$W/lanes/r3/scratch.txt"
  out=$(trunk land r3 2>&1) || fail "a lane with unsaved work in its copy must land: $out"
  c3=$(git -C "$PROJ" rev-parse fm/r3)
  [ "$(tip)" != "$c3" ] && [ -f "$W/lanes/r3/scratch.txt" ] || fail "unsaved work in the lane must be left exactly as it was"
  rows=$(cat "$HOME_D/data/trunk-landing-proofs.tsv")
  assert_contains "$rows" "$(printf 'r1\tproj\t%s' "$c1")" "the landing must be recorded with its facts"
  assert_contains "$rows" "receipt=PASS@" "the sealed receipt is recorded with the landing"
  assert_contains "$rows" "signature=absent" "a missing signature is recorded as absent and never blocks"
  assert_contains "$rows" "merge-card=present" "the merge-card is recorded"
  # A change that really conflicts is still refused, with its paths, and is never rebased dirty.
  lane x1 left; lane x2 right
  trunk land x1 >/dev/null 2>&1 || fail "x1 must land"
  refused 'a conflicting lane' x2 'conflicts with trunk'
  assert_contains "$(trunk land x2 2>&1)" 'in: work.txt' 'a conflict names its paths'
  pass 'the lander rebases a lane by itself; only the owner signature stays outside the landing'
}

if [ "${JG_TRUNK_OUTER_ONLY:-0}" = 1 ]; then
  test_the_watcher_runs_the_landing_check_on_its_fast_tick
  exit
fi

test_configured_hooks_and_the_launch_overlay_preserve_trunk_protection
test_a_home_with_other_shas_is_contained_only_when_the_trunk_took_its_changes
test_admission_is_shared_by_manual_and_automatic_requests
test_the_bundled_hook_moves_a_home_that_runs_the_project
test_the_registered_check_lands_a_proved_task_without_a_human
test_a_quiet_trunk_goes_live_on_every_home_by_itself
test_a_busy_trunk_goes_live_at_the_hourly_cap
test_a_red_or_unwaived_landing_never_goes_live
test_the_landing_check_cuts_the_next_trunk_once_the_release_merged
test_the_watcher_runs_the_landing_check_on_its_fast_tick
test_the_full_gate_charges_a_lane_only_for_what_it_broke
test_a_flaky_failure_gets_one_rerun_before_it_is_judged
test_a_tip_red_that_prints_its_elapsed_seconds_is_the_same_red_on_every_run
test_the_gates_are_policy_keys_with_fast_defaults
test_a_project_that_is_not_juggernaut_never_runs_juggernauts_gates
test_a_landing_rebases_the_lane_by_itself
printf 'jg-trunk-check: ok\n'
