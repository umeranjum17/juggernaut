#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh driven by the registered landing check core/trunk-landing: landing without a
# human step and the automatic live step over Main's code home and two Squad Lead homes (tests/jg-trunk-fixture.sh).
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh, reads bin/jg-dod-lib.sh and stands in for bin/jg-captain-hold.sh,
# bin/jg-backlog.sh, bin/jg-send.sh, bin/jg-teardown.sh, bin/jg-fleet-ledger.sh and bin/jg-home-health.sh.
#
# T7 The registered check core/trunk-landing lands a task whose last status line is its done, with no human step, and
#    never goes live; it ignores a task that is not done, reports a refusal once (a conflict names its paths), retries a
#    refusal that only needs time, cleans a landed task up unforced, and runs on the watcher's fast tick.
# The batched live step moves every home once the trunk has been quiet (the window is a knob) or at the hourly cap while
#    landings continue; a landed commit is green at once and nothing runs the whole suite after it; a red head, a red a
#    hand-run verify finds and a missing waiver move none; the bundled hook
#    fast-forwards a home that runs the project and records a dirty home as not moved.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# A fleet: the code home (a clone of the project's origin, as Main's checkout is) and two registered Squad Lead homes
# (worktrees of it), all on the last release, a go-live waiver, and the home's own bin so the landing check runs.
fleet_world() {  # <name> [rig]: sets W HOME_D PROJ CODE_ROOT BASE; rig makes the whole suite (verify, run by hand) the rig's t/*.test.sh
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
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  trunk waiver "$PROJ" --rule owner-rule-test >/dev/null || fail "the Overwatch path must write the waiver"
}

# Sweeps of the landing check, as a home runs them (its own bin, the code home a clone of the origin), until <pattern> shows
# in what they print or the job that follows a landing has ended; prints what they printed.
fleet_sweeps() {  # <pattern>
  local acc='' home
  for _ in $(seq 1 200); do
    acc="$acc$(JG_ROOT_OVERRIDE="$CODE_ROOT" JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")"$'\n'
    printf '%s' "$acc" | grep -q -- "$1" && break; sleep 0.2
  done
  # Each check starts a detached live job; one still running would race the case's own autolive call (a late one went
  # live first under load), so the sweeps return only once every live job they started has finished.
  home=$(cd "$HOME_D" && pwd -P)  # the check names the home by its resolved path
  for _ in $(seq 1 300); do pgrep -f "trunk-landing.sh live $home " >/dev/null || break; sleep 0.2; done
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
  awk -F'\t' -v OFS='\t' -v n="$(date +%s)" '{ $3 = n - 7200; print }' "$HOME_D/data/trunk-in-use.tsv" > "$HOME_D/data/trunk-in-use.tsv.new" && mv "$HOME_D/data/trunk-in-use.tsv.new" "$HOME_D/data/trunk-in-use.tsv"
}

await_green() {  # the tick's verify of the landing has moved the green pin to the trunk tip
  for _ in $(seq 1 200); do [ "$(cat "$HOME_D/state/trunk-green-proj" 2>/dev/null)" = "$(tip)" ] && return 0; sleep 0.2; done; return 1
}

test_the_bundled_hook_moves_a_home_that_runs_the_project() {
  local c out rc base
  world home
  rm "$HOME_D/config/live-hook.proj"
  git clone -q "$(git -C "$PROJ" remote get-url origin)" "$W/homecode"
  lane h1 hook; c=$(git -C "$PROJ" rev-parse fm/h1)
  out=$(CODE_ROOT="$W/homecode" trunk land h1 2>&1) || fail "h1 must land: $out"
  [ "$(git -C "$W/homecode" rev-parse HEAD)" != "$c" ] || fail "landing alone must not move the home checkout"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "the verify must pass: it moves the pin that live follows"
  trunk word in-use "$PROJ" "go" >/dev/null 2>&1
  out=$(CODE_ROOT="$W/homecode" trunk live "$PROJ" 2>&1) || fail "live must move a home that runs the project: $out"
  [ "$(git -C "$W/homecode" rev-parse HEAD)" = "$c" ] || fail "the home checkout must be fast-forwarded to the landed commit: $out"
  grep -Eq "^proj	$c	[0-9]+	live$" "$HOME_D/data/trunk-in-use.tsv" || fail "the live record must say live"
  base=$(cat "$HOME_D/state/trunk-released-proj")
  out=$(CODE_ROOT="$W/homecode" trunk ci "$PROJ" "$c" red 2>&1) || fail "a red CI must pin the bundled home back: $out"
  [ "$(git -C "$W/homecode" rev-parse HEAD)" = "$base" ] || fail "the home checkout must return to the last release when no earlier commit was live: $out"
  printf '%s\n' "$c" > "$HOME_D/state/trunk-green-proj"
  rm "$HOME_D/data/trunk-in-use.tsv"; printf 'dirty\n' >> "$W/homecode/README.md"
  lane h2 hook2; CODE_ROOT="$W/homecode" trunk land h2 >/dev/null 2>&1 || fail "h2 must land"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "the verify must pass: it moves the pin that live follows"
  trunk word in-use "$PROJ" "go" >/dev/null 2>&1
  rc=0; out=$(CODE_ROOT="$W/homecode" trunk live "$PROJ" 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a live whose home did not move must exit 3, got $rc: $out"
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/h2)" ] || fail "the commit must stay landed when only the live step failed"
  assert_contains "$(cat "$HOME_D/data/trunk-in-use.tsv")" hook-failed "a home that did not move must be recorded as such"
  pass 'the bundled hook fast-forwards the home and a dirty home is recorded as not moved'
}

test_the_registered_check_lands_a_proved_task_without_a_human() {
  local out c
  world auto
  # the check runs the home's own bin, so the fixture home needs the copied bin and a mode the check reads
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
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

test_a_quiet_trunk_goes_live_on_every_home_by_itself() {
  local out c h
  fleet_world autolive; lane g1 good; c=$(git -C "$PROJ" rev-parse fm/g1)
  homes_at "$BASE" || fail "fixture: every home starts on the release"
  fleet_sweeps "landed g1" >/dev/null; await_green || fail "the landing must move the green pin"
  # A landing never waits on a go-live, and a fresh landing is not live yet: the trunk is not quiet.
  homes_at "$BASE" || fail "a fresh landing must not go live at once"
  out=$(trunk autolive "$PROJ" 2>&1 | tail -n 1); assert_contains "$out" "autolive: waiting: In use in about" "a busy trunk waits for its quiet window"
  # 25 quiet minutes later (default window 20) the check's own tick moves every home, with no word and no model turn.
  age_landings 25 25
  out=$(fleet_sweeps "proj: live at")
  assert_contains "$out" "proj: In use at ${c:0:12} on every home" "the outbox must say every home moved"
  homes_at "$c" || fail "a quiet trunk must move Main and every Squad Lead home: $(cat "$HOME_D/data/trunk-in-use.tsv" 2>/dev/null)"
  [ ! -e "$HOME_D/state/trunk-word-in-use-proj" ] && [ ! -e "$HOME_D/data/trunk-words.tsv" ] || fail "the waiver records and spends no word"
  for h in lead-a lead-b primary; do grep -q "^proj:$h	$c	[0-9]*	live" "$HOME_D/data/trunk-in-use.tsv" || fail "$h needs a live row: $(cat "$HOME_D/data/trunk-in-use.tsv")"; done
  [ "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" = "autolive: already In use at ${c:0:12}" ] || fail "a commit that is live is not moved twice"
  # The knob moves the window: 3 quiet minutes is not enough under 5 and is under 2; a red CI then pins EVERY home back at once.
  age_live; lane g2 two; fleet_sweeps "landed g2" >/dev/null; await_green || fail "g2's landing must move the green pin"
  age_landings 3 3; printf 'live-quiet-minutes=5\n' >> "$HOME_D/config/trunk-policy"
  assert_contains "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" "waiting" "3 quiet minutes is not enough under a 5 minute window"
  printf 'live-quiet-minutes=2\n' >> "$HOME_D/config/trunk-policy"
  assert_contains "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" "In use at $(tip | cut -c1-12)" "the quiet window is a policy knob"
  homes_at "$(tip)" || fail "the second batch must move every home"
  trunk ci "$PROJ" "$(tip)" red >/dev/null 2>&1 || fail "a red CI must record and pin back"
  homes_at "$c" || fail "a red CI must pin every home back to the last green live commit at once"
  grep -q "^proj:lead-a	$c	[0-9]*	live,pinned-back-from:" "$HOME_D/data/trunk-in-use.tsv" || fail "the pin-back row names where the home came from"
  pass 'a quiet trunk goes live on Main and every Squad Lead home by itself, the window is a knob, and a red CI pins every home back'
}

# A go-live pinned behind the tip (the green pin is under the trunk tip) moves every home exactly as one at the tip does, and its
# `live` row is written only once every home is at the pin: a home left behind (dirty here) makes it a failed move naming the home.
test_a_pinned_behind_go_live_moves_every_home_and_fails_naming_a_home_left_behind() {
  local out c1 c2 h
  fleet_world autolive-pinned; lane p1 one; fleet_sweeps "landed p1" >/dev/null; await_green || fail "p1's landing must move the green pin"
  c1=$(tip); lane p2 two; trunk land p2 >/dev/null 2>&1 || fail "p2 must land"; c2=$(tip)
  printf '%s\n' "$c1" > "$HOME_D/state/trunk-green-proj"  # as a red found after p2 landed leaves it: the pin one commit under the tip
  [ "$c2" != "$c1" ] && [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c1" ] || fail "fixture: the pin must be one commit behind the tip"
  age_landings 25 25; printf 'dirty\n' >> "$W/lead-a/work.txt"
  out=$(trunk autolive "$PROJ" 2>&1); [ "$(printf '%s\n' "$out" | tail -n 1)" = "autolive: NOT In use, the move failed: fleet: not every home is at ${c1:0:12}: lead-a" ] \
    || fail "a home left behind must fail the pinned-behind move and be named: $out"
  awk -F'\t' -v p=proj -v g="$c1" '$1 == p && $2 == g && $4 ~ /^live/ { f = 1 } END { exit f }' "$HOME_D/data/trunk-in-use.tsv" || fail "no live row while a home is behind: $(cat "$HOME_D/data/trunk-in-use.tsv")"
  grep -q "^proj	$c1	[0-9]*	hook-failed:fleet: not every home is at ${c1:0:12}: lead-a" "$HOME_D/data/trunk-in-use.tsv" || fail "the failed move leaves a hook-failed row naming the home"
  assert_contains "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" "waiting: the last move failed" "a failed move is not retried on every tick"
  rm -f "$W/lead-a/work.txt"; age_live
  out=$(trunk autolive "$PROJ" 2>&1 | tail -n 1); assert_contains "$out" "In use at ${c1:0:12} on every home" "the retry after the quiet window moves every home"
  homes_at "$c1" || fail "the pinned-behind move must reach Main and every Squad Lead home, not the tip: $(cat "$HOME_D/data/trunk-in-use.tsv")"
  for h in lead-a lead-b primary; do grep -q "^proj:$h	$c1	[0-9]*	live" "$HOME_D/data/trunk-in-use.tsv" || fail "$h needs a live row at the pin"; done
  grep -q "^proj	$c1	[0-9]*	live,pinned-behind-${c2:0:12},waiver=" "$HOME_D/data/trunk-in-use.tsv" || fail "the live row says pinned-behind the tip: $(grep "^proj	" "$HOME_D/data/trunk-in-use.tsv")"
  pass 'a pinned-behind go-live moves every home, writes its live row only when all are there, and names a home left behind'
}

test_a_busy_trunk_goes_live_at_the_hourly_cap() {
  local out c
  fleet_world autolive-cap; lane b1 one; fleet_sweeps "landed b1" >/dev/null; await_green || fail "b1's landing must move the green pin"
  lane b2 two; fleet_sweeps "landed b2" >/dev/null; await_green || fail "b2's landing must move the green pin"
  c=$(tip)
  # Landings keep coming (the newest one a minute ago) but the oldest not-yet-live one is 59 minutes old: still waiting.
  age_landings 1 59
  assert_contains "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" "waiting" "59 minutes of landings is under the 60 minute cap"
  homes_at "$BASE" || fail "nothing may move before the cap"
  age_landings 1 61
  out=$(trunk autolive "$PROJ" 2>&1 | tail -n 1); assert_contains "$out" "In use at ${c:0:12} on every home" "the cap makes the trunk go live while landings continue"
  homes_at "$c" || fail "the hourly cap must move every home: $(cat "$HOME_D/data/trunk-in-use.tsv" 2>/dev/null)"
  # Landings after that go live in the next batch, not at once: the cap counts from what is not live yet.
  lane b3 three; fleet_sweeps "landed b3" >/dev/null; await_green || fail "b3's landing must move the green pin"
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
  # A head that passes the landing check and breaks the whole suite lands green (nothing runs the whole suite after a landing);
  # once a hand-run verify finds the red, it is reverted, takes the green pin back, and no home ever moves to it.
  lane r2 'echo "not ok - r2 breaks the suite" >&2; exit 1' t/r2.test.sh; c=$(git -C "$PROJ" rev-parse fm/r2)
  out=$(fleet_sweeps "landed r2"); assert_contains "$out" "landed r2" "a head that passes the landing check lands"
  case $out in *"whole suite is red"*) fail "no whole suite may run after a landing: $out" ;; esac
  # The tick's own verify (started by the sweep) and a hand-run one find the same red; whichever runs first reverts it.
  trunk verify "$PROJ" "$c" >/dev/null 2>&1 || :
  for _ in $(seq 1 150); do git -C "$PROJ" log --format=%B trunk | grep -q "^reverts: $c" && break; sleep 0.2; done
  git -C "$PROJ" log --format=%B trunk | grep -q "^reverts: $c" || fail "a red verify finds is reverted by itself"
  age_landings 30 30; trunk autolive "$PROJ" >/dev/null 2>&1
  homes_at "$BASE" || fail "a red verify found must not move any home, even after the quiet window: $(cat "$HOME_D/data/trunk-in-use.tsv" 2>/dev/null)"
  ! grep -q "	$c	" "$HOME_D/data/trunk-in-use.tsv" 2>/dev/null || fail "the red commit is never live: $(cat "$HOME_D/data/trunk-in-use.tsv")"
  # With no waiver the word rule stands, and a worker never runs the live step.
  rm -f "$HOME_D/config/trunk-live-waiver"
  out=$(trunk autolive "$PROJ" 2>&1 | tail -n 1); assert_contains "$out" "needs the captain's word" "no waiver, no automatic live"
  homes_at "$BASE" || fail "no waiver must not move any home"
  out=$(JG_TASK_ID=x trunk autolive "$PROJ" 2>&1) && fail "a worker must never run the live step"
  pass 'a red head, a red a hand-run verify finds and a missing waiver never move a home'
}

test_the_landing_check_cuts_the_next_trunk_once_the_release_merged() {
  local out
  world rolcheck
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  lane k1 one; trunk land k1 >/dev/null 2>&1 || fail "k1 must land"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "the verify must pass: the release ships the pin it moves"
  trunk word release "$PROJ" "ship it" >/dev/null 2>&1; trunk release "$PROJ" >/dev/null 2>&1 || fail "release must open"
  out=$(sweep); [ -z "$out" ] || fail "an open release must change nothing: $out"
  printf 'merged\n' > "$W/pr-state"; git -C "$PROJ" push -q origin "$(tip):refs/heads/main"; rm -f "$HOME_D"/data/jg-trunk-landing/.rollover-*
  out=$(sweep); assert_contains "$out" "release merged: the project is now on release/v2" "the check must cut the next trunk"
  git -C "$PROJ" rev-parse --verify -q release/v2 >/dev/null || fail "release/v2 must exist"
  pass 'the landing check cuts the next trunk once the release merged'
}

test_the_watcher_runs_the_landing_check_on_its_fast_tick() {
  local c out rc=0 st
  world outer-watch
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
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

if [ "${JG_TRUNK_OUTER_ONLY:-0}" = 1 ]; then
  test_the_watcher_runs_the_landing_check_on_its_fast_tick
  exit
fi

# The journey that stalled on 9 Nov: a lane lands on a tip that carries only recorded reds and the check tears the lane down at once
# (its record is gone). The landing's own gate sets the recorded reds aside, the tick's verify moves the pin, and the quiet trunk goes
# live by itself.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_landing_on_a_tip_with_only_recorded_reds_moves_the_pin_and_goes_live_by_itself() {
  local out c
  fleet_world oldreds; rig; seed_red_tip; cp "$W/root/bin/jg-backlog.sh" "$HOME_D/bin/jg-backlog.sh"
  cp "$HOME_D/state/trunk-tip-proj" "$HOME_D/state/trunk-green-proj"  # the red tip is the trunk's accepted green: its reds are the parent's own
  printf 'gate-verify=echo run >> %s/suite-runs; export GATE_MARK=yes; bash %s/rig.sh --all\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
  lane good 'exit 0' t/d.test.sh
  out=$(fleet_sweeps "landed good"); assert_contains "$out" "cleaned up" "the check must tear the landed lane down"
  [ ! -e "$HOME_D/state/good.meta" ] || fail "fixture: the lane's record must be gone, as the real teardown leaves it"
  await_green || fail "the tick's verify must move the pin over the tip's recorded reds: $(cat "$HOME_D"/data/jg-trunk-landing/good.*.log "$HOME_D"/data/jg-trunk-landing/verify-proj.log 2>&1)"
  c=$(tip)
  [ -e "$W/suite-runs" ] || fail "the verify, not the landing, ran the suite"
  age_landings 25 25
  out=$(fleet_sweeps "proj: live at")
  assert_contains "$out" "proj: In use at ${c:0:12} on every home" "the quiet trunk must go live by itself over the recorded reds"
  homes_at "$c" || fail "every home must move to the landed commit: $(cat "$HOME_D/data/trunk-in-use.tsv" 2>/dev/null)"
  pass 'a landing on a tip with only recorded reds moves the pin after its lane is torn down and goes live with no hand step'
}

test_a_home_with_the_old_live_names_moves_them_once_and_keeps_no_second_path() {
  local out
  world oldnames
  printf 'proj\tabc\t1\tlive\n' > "$HOME_D/data/trunk-live.tsv"
  printf 'abc\t1\tgo\n' > "$HOME_D/state/trunk-word-live-proj"
  printf 'new\t1\tgo\n' > "$HOME_D/state/trunk-word-live-other"; printf 'kept\t1\tgo\n' > "$HOME_D/state/trunk-word-in-use-other"
  out=$(trunk autolive "$PROJ" 2>&1) || :
  [ ! -e "$HOME_D/data/trunk-live.tsv" ] && [ ! -e "$HOME_D/state/trunk-word-live-proj" ] && [ ! -e "$HOME_D/state/trunk-word-live-other" ] || fail "no old name may be left: $out"
  assert_contains "$(cat "$HOME_D/data/trunk-in-use.tsv")" "proj	abc	1	live" "the old record moves into the In use record"
  assert_equals "$(cut -f1 "$HOME_D/state/trunk-word-in-use-proj")" abc "the old word moves to its In use name"
  assert_equals "$(cut -f1 "$HOME_D/state/trunk-word-in-use-other")" kept "a word already under the new name wins"
  trunk autolive "$PROJ" >/dev/null 2>&1 || :
  [ "$(grep -c '^proj	abc	1	live' "$HOME_D/data/trunk-in-use.tsv")" = 1 ] || fail "a second run moves nothing again"
  pass 'the old live record and word files move once to their In use names, with no second path left'
}

test_a_landing_on_a_tip_with_only_recorded_reds_moves_the_pin_and_goes_live_by_itself
test_a_home_with_the_old_live_names_moves_them_once_and_keeps_no_second_path
test_the_bundled_hook_moves_a_home_that_runs_the_project
test_the_registered_check_lands_a_proved_task_without_a_human
test_a_quiet_trunk_goes_live_on_every_home_by_itself
test_a_pinned_behind_go_live_moves_every_home_and_fails_naming_a_home_left_behind
test_a_busy_trunk_goes_live_at_the_hourly_cap
test_a_red_or_unwaived_landing_never_goes_live
test_the_landing_check_cuts_the_next_trunk_once_the_release_merged
test_the_watcher_runs_the_landing_check_on_its_fast_tick
printf 'jg-trunk-live: ok\n'
