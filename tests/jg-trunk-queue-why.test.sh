#!/usr/bin/env bash
# Integration test for the landing row's wait reason (ticket h100-h40): the real lander (core/trunk-landing/trunk-landing.sh check) over a
# fixture home (tests/jg-trunk-fixture.sh), then the real latency check (core/trunk-latency/latency.sh) over what it wrote.
# W1 every gate slot is in use, so the lander declines a ready lane and records `slot full` at that decision; the lane lands once a slot is
#    free, and its latency row carries `slot full` in the queue_why column with a header that names the column; the row lint passes.
# W2 a landing with no recorded reason gets `not recorded`, and the row lint refuses it, naming the lane; an empty reason is refused too.
# W3 a latency file with the old 12-column header is migrated once: the header gains queue_why, queue_secs and landing_secs, the old rows stay.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

export JG_TRUNK_LATENCY_ALERT=$ROOT/bin/jg-alert.sh
sweep_once() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" 2>&1; }
latency() { JG_TRUNK_LATENCY_LOADAVG=/dev/null bash "$ROOT/core/trunk-latency/latency.sh" "$@"; }
col() {  # <task> <column>: one field of the task's latency row
  awk -F'\t' -v t="$1" -v f="$2" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next } $1 == t { print $c[f] }' "$HOME_D/data/trunk-latency.tsv"
}

test_a_lane_that_waited_for_a_slot_names_it_on_its_row() {
  local mem sleeper1 sleeper2 head out rc=0 now _
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
  # W1: the row names the wait, the header names the column, and the lint passes.
  out=$(latency check "$HOME_D") || fail "the latency check failed: $out"
  head -n 1 "$HOME_D/data/trunk-latency.tsv" | tr '\t' '\n' | grep -qx queue_why || fail "the header must name queue_why"
  [ "$(col w1 stage)" = queue ] || fail "the lane waited in the queue: stage $(col w1 stage)"
  [ "$(col w1 queue_why)" = 'slot full' ] || fail "the row names the wait: $(col w1 queue_why)"
  latency lint "$HOME_D" >/dev/null || fail "a row with a reason passes the lint"
  pass 'W1: the lander records slot full at its decision and the landing row names it'
  # W2: no reason, or an empty one, fails the lint and names the lane.
  rm -f -- "$HOME_D/data/trunk-latency.tsv" "$mem/w1.$head.queue-why"
  latency check "$HOME_D" >/dev/null || :
  [ "$(col w1 queue_why)" = 'not recorded' ] || fail "a landing with no record says not recorded: $(col w1 queue_why)"
  out=$(latency lint "$HOME_D" 2>&1) && rc=0 || rc=$?
  if [ "$rc" != 1 ] || ! grep -q 'w1 .* no recorded reason' <<< "$out"; then fail "the lint must refuse not recorded and name w1 (rc $rc): $out"; fi
  awk -F'\t' 'BEGIN { OFS = FS } NR == 1 { for (i = 1; i <= NF; i++) if ($i == "queue_why") w = i } NR > 1 { $w = "" } { print }' "$HOME_D/data/trunk-latency.tsv" > "$W/empty.tsv"
  cp "$W/empty.tsv" "$HOME_D/data/trunk-latency.tsv"
  latency lint "$HOME_D" >/dev/null 2>&1 && fail "an empty reason must fail the lint"
  pass 'W2: not recorded and an empty reason fail the row lint'
  # W3: the old header is migrated once and keeps its rows.
  printf 'task\thead\tcommit\tfirst_done\tready\tgate_start\tlaunch\tlanded\tminutes\tstage\tgate_secs\tload\nold\th\tc\t1\t2\t3\t4\t5\t6\tgate\t7\t0.1\n' > "$HOME_D/data/trunk-latency.tsv"
  printf 'x\tp\tc2\t9\tfull\n' >> "$HOME_D/data/trunk-landings.tsv"
  latency check "$HOME_D" >/dev/null || :
  [ "$(head -n 1 "$HOME_D/data/trunk-latency.tsv")" = "$(printf 'task\thead\tcommit\tfirst_done\tready\tgate_start\tlaunch\tlanded\tminutes\tstage\tgate_secs\tload\tqueue_why\tqueue_secs\tlanding_secs')" ] \
    || fail "the old header must gain the three columns once: $(head -n 1 "$HOME_D/data/trunk-latency.tsv")"
  [ "$(grep -c '^old' "$HOME_D/data/trunk-latency.tsv")" = 1 ] || fail "the old row stays"
  pass 'W3: the old header is migrated once'
}

test_a_lane_that_waited_for_a_slot_names_it_on_its_row
printf 'jg-trunk-queue-why: ok\n'
