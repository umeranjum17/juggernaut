#!/usr/bin/env bash
# Integration test for the landing's wait reason (ticket h100-h40): the real lander (core/trunk-landing/trunk-landing.sh check) over a
# fixture home (tests/jg-trunk-fixture.sh), then the timing of the landing that core/trunk-latency/latency.sh measures from what it wrote.
# W1 every gate slot is in use, so the lander declines a ready lane and records `slot full` at that decision; the lane lands once a slot is
#    free, and its timing names `slot full` as the queue_why of the queue stage; no latency file is written.
# W2 a landing with no recorded reason gets `not recorded`, never a bare queue.
# W3 flush-at-ready@proj=3 holds one ready lane: the lander records `flush hold` at that decision, and the landing that follows keeps it.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

export JG_TRUNK_LATENCY_ALERT=$ROOT/bin/jg-alert.sh
sweep_once() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" 2>&1; }
latency() { JG_TRUNK_LATENCY_LOADAVG=/dev/null bash "$ROOT/core/trunk-latency/latency.sh" "$@"; }

test_a_lane_that_waited_for_a_slot_names_it_on_its_row() {
  local mem sleeper1 sleeper2 head now _
  world qwhy; mem=$HOME_D/data/jg-trunk-landing
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  printf 'flush-at-ready=1\n' >> "$HOME_D/config/trunk-policy"
  mkdir -p "$mem"
  # Two landings are running (two live pids): every gate slot is in use.
  sleep 120 & sleeper1=$!; sleep 120 & sleeper2=$!
  local h1=1111111111111111111111111111111111111111 h2=2222222222222222222222222222222222222222
  printf 'running %s %s\n' "$(date +%s)" "$sleeper1" > "$mem/other-a.$h1.state"
  printf 'running %s %s\n' "$(date +%s)" "$sleeper2" > "$mem/other-b.$h2.state"
  lane w1 one f1.txt
  now=$(date +%s); : > "$HOME_D/state/w1.status"; printf 'done [at=%s]: ready in branch fm/w1 (local-trunk)\n' "$((now - 600))" >> "$HOME_D/state/w1.status"
  head=$(git -C "$W/lanes/w1" rev-parse HEAD)
  sweep_once >/dev/null
  [ "$(cat "$mem/w1.$head.queue-why" 2>/dev/null)" = 'slot full' ] || fail "the lander must record why it declined the lane: $(cat "$mem/w1.$head.queue-why" 2>&1)"
  # The slots free up; the lane lands, and the reason stays the one recorded at the decision.
  kill "$sleeper1" "$sleeper2" 2>/dev/null || :; wait "$sleeper1" "$sleeper2" 2>/dev/null || :
  rm -f -- "$mem/other-a.$h1.state" "$mem/other-b.$h2.state"
  sweep_once >/dev/null
  for _ in $(seq 1 150); do git -C "$PROJ" log --format=%s trunk | grep -q '^ticket w1' && break; sleep 0.2; done
  git -C "$PROJ" log --format=%s trunk | grep -q '^ticket w1' || fail "the lane lands once a slot is free"
  for _ in $(seq 1 100); do [ -z "$(jg_test_detached_alive)" ] && break; sleep 0.2; done
  [ "$(cat "$mem/w1.$head.queue-why")" = 'slot full' ] || fail "the reason survives the landing: $(cat "$mem/w1.$head.queue-why")"
  # W1: the landing's timing names the wait, and no latency file is written.
  local commit payload
  commit=$(awk -F'\t' '$1 == "w1" { print $3 }' "$HOME_D/data/trunk-landings.tsv")
  payload=$(latency measure "$HOME_D" w1 "$commit") || fail "the timing of the landing: $payload"
  [ "$(jq -r .stage <<< "$payload")" = queue ] || fail "the lane waited in the queue: $payload"
  [ "$(jq -r .queue_why <<< "$payload")" = 'slot full' ] || fail "the timing names the wait: $payload"
  [ ! -e "$HOME_D/data/trunk-latency.tsv" ] || fail "no latency file is written"
  pass 'W1: the lander records slot full at its decision and the landing timing names it'
  # W2: no recorded reason says `not recorded`, never a bare queue.
  rm -f -- "$mem/w1.$head.queue-why"
  payload=$(latency measure "$HOME_D" w1 "$commit") || fail "the timing of the landing: $payload"
  [ "$(jq -r .queue_why <<< "$payload")" = 'not recorded' ] || fail "a landing with no record says not recorded: $payload"
  pass 'W2: a queue stage with no recorded reason says not recorded'
}

test_a_lane_held_by_the_flush_rule_names_it_on_its_row() {
  local mem head now _ payload commit
  world qflush; mem=$HOME_D/data/jg-trunk-landing
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  sed -i.bak '/^flush-at-ready=/d' "$HOME_D/config/trunk-policy"
  printf 'flush-at-ready@proj=3\n' >> "$HOME_D/config/trunk-policy"
  mkdir -p "$mem"
  lane f1 one f1.txt
  now=$(date +%s); : > "$HOME_D/state/f1.status"; printf 'done [at=%s]: ready in branch fm/f1 (local-trunk)\n' "$((now - 600))" >> "$HOME_D/state/f1.status"
  head=$(git -C "$W/lanes/f1" rev-parse HEAD)
  sweep_once >/dev/null
  [ "$(cat "$mem/f1.$head.queue-why" 2>/dev/null)" = 'flush hold' ] || fail "the lander must record the flush hold: $(cat "$mem/f1.$head.queue-why" 2>&1)"
  ! git -C "$PROJ" log --format=%s trunk | grep -q '^ticket f1' || fail "the held lane does not land while the flush rule holds it"
  # The hold ends: the lane lands, and the reason stays the one recorded at the decision.
  sed -i.bak '/^flush-at-ready@/d' "$HOME_D/config/trunk-policy"
  sweep_once >/dev/null
  for _ in $(seq 1 150); do git -C "$PROJ" log --format=%s trunk | grep -q '^ticket f1' && break; sleep 0.2; done
  git -C "$PROJ" log --format=%s trunk | grep -q '^ticket f1' || fail "the lane lands once the flush rule lets it go"
  for _ in $(seq 1 100); do [ -z "$(jg_test_detached_alive)" ] && break; sleep 0.2; done
  commit=$(awk -F'\t' '$1 == "f1" { print $3 }' "$HOME_D/data/trunk-landings.tsv")
  payload=$(latency measure "$HOME_D" f1 "$commit") || fail "the timing of the landing: $payload"
  [ "$(jq -r .queue_why <<< "$payload")" = 'flush hold' ] || fail "the timing names the flush hold: $payload"
  pass 'W3: the lander records flush hold for a lane the flush rule holds and the landing timing names it'
}

test_a_lane_that_waited_for_a_slot_names_it_on_its_row
test_a_lane_held_by_the_flush_rule_names_it_on_its_row
printf 'jg-trunk-queue-why: ok\n'
