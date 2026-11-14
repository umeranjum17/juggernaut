#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: a lander refusal the worker can fix reaches that lane's worker by itself (split out of tests/jg-trunk.test.sh).
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

sends() { awk -F'\t' -v i="$1" '$1 == i { n++ } END { print n + 0 }' "$W/send-calls" 2>/dev/null || echo 0; }

# shellcheck disable=SC2016 # the gate bodies are written out verbatim and expand when the gate runs them
test_a_refusal_reaches_the_lanes_worker_and_never_sits_silent() {
  local out gone h f real_backlog=0
  world reach
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  # An incomplete proof: the worker is steered with the refusal text, and the done itself names what to run.
  lane r1 one; rm "$HOME_D/data/r1/merge-card.json"
  out=$(done_gate r1) && fail "a done with no merge-card evidence must be refused: $out"
  assert_contains "$out" "merge-card check r1" "the done names the command to run"
  printf '# the done is refused and names what to run: %s\n' "$out"
  sweep >/dev/null
  [ "$(sends r1)" = 1 ] || fail "the refused lane's worker must be steered once, got $(sends r1)"
  assert_contains "$(grep '^r1	' "$W/send-calls")" "proof inputs are incomplete" "the steer carries the refusal text"
  assert_contains "$(grep '^r1	' "$W/send-calls")" "merge-card check r1" "the steer names what to run"
  printf '# the lane worker is steered: %s\n' "$(grep '^r1	' "$W/send-calls" | head -n 1)"
  sweep >/dev/null; [ "$(sends r1)" = 1 ] || fail "the same refusal must not steer again before it is due"
  # Re-rung while the head is unchanged, unless the worker still has an unread steer (the inbox's own ladder rings that one).
  rf=$(ls "$HOME_D"/data/jg-trunk-landing/r1.*.refusal); sed -i "s/^\([0-9]*\) \([0-9]*\) [0-9]* /\1 \2 $(( $(date +%s) - 700 )) /" "$rf"
  mkdir -p "$HOME_D/state/r1.inbox"; : > "$HOME_D/state/r1.inbox/001.msg"
  sweep >/dev/null; [ "$(sends r1)" = 1 ] || fail "a worker with an unread steer is not steered again"
  rm "$HOME_D/state/r1.inbox/001.msg"
  sweep >/dev/null; [ "$(sends r1)" = 2 ] || fail "an unchanged head is steered again when the last steer is due: $(sends r1)"
  # Nobody acted for ten minutes: one alert names the lane and the refusal.
  out=$(sweep); [[ $out != *ALERT* ]] || fail "no alert before ten minutes: $out"
  sed -i "s/^[0-9]* /$(( $(date +%s) - 700 )) /" "$rf"
  out=$(sweep); assert_contains "$out" "ALERT: r1 has sat refused for over 10 minutes" "the alert names the lane"
  assert_contains "$out" "no approved merge-card evidence" "the alert names the refusal"
  printf '# after ten silent minutes: %s\n' "$out"
  out=$(sweep); [[ $out != *ALERT* ]] || fail "the alert is raised once: $out"
  # A final refusal (a red gate) tells the ticket and steers the worker once.
  if [ -n "${JG_BEADS_TEST_BD:-}" ] && [ -n "${JG_BEADS_TEST_DOLT:-}" ]; then
    jg_test_beads_home "$HOME_D"
    cp "$ROOT/bin/jg-backlog.sh" "$HOME_D/bin/jg-backlog.sh"
    cp "$ROOT/toolchain.versions" "$HOME_D/toolchain.versions"
    jg_test_backlog "$HOME_D" add jg-r2 '[feature] refusal fixture' --kind ship --repo proj --body 'Prove a final refusal reaches its owner.' >/dev/null || fail 'create jg-r2 ticket'
    jg_test_backlog "$HOME_D" add jg-r5 '[feature] retry fixture' --kind ship --repo proj --body 'Prove exhausted retries reach their owner.' >/dev/null || fail 'create jg-r5 ticket'
    real_backlog=1
  else
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/backlog-calls"\n' "$W" > "$HOME_D/bin/jg-backlog.sh"
    chmod +x "$HOME_D/bin/jg-backlog.sh"
    printf '# real ticket assertions skipped: no pinned Beads tools\n'
  fi
  cp "$HOME_D/bin/jg-send.sh" "$W/send-stub"
  cp "$ROOT/bin/jg-send.sh" "$HOME_D/bin/jg-send.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/tmux"; chmod +x "$W/fakebin/tmux"
  lane jg-r2 BAD
  printf 'kind=ship\nharness=codex\nwindow=sess:jg-jg-r2\n' >> "$HOME_D/state/jg-r2.meta"
  sweep >/dev/null; sweep >/dev/null
  assert_contains "$(cat "$HOME_D/state/jg-r2.inbox/001.msg" 2>/dev/null)" "gate 'full' failed" "a final refusal reaches its worker"
  if [ "$real_backlog" = 1 ]; then
    assert_contains "$(jg_test_backlog "$HOME_D" show jg-r2 --full)" "gate 'full' failed" "the final refusal reaches its ticket"
  else assert_contains "$(cat "$W/backlog-calls" 2>/dev/null)" "update jg-r2 --body-file" "the final refusal reaches its ticket"; fi
  [ "$(find "$HOME_D/state/jg-r2.inbox" -maxdepth 1 -name '*.msg' | wc -l)" = 1 ] || fail "a final refusal sends one steer"
  assert_not_contains "$(cat "$HOME_D"/data/jg-trunk-landing/jg-r2.*.log)" "unbound variable" "the real lander completes its refusal"
  assert_contains "$(JG_HOME="$HOME_D" "$HOME_D/bin/jg-machine.sh" show task jg-r2)" "rework" "the refused lane is in rework"
  cp "$W/send-stub" "$HOME_D/bin/jg-send.sh"
  # The lane changes its head: the old refusal is history and the new head is judged on its own.
  gone=$(git -C "$PROJ" rev-parse fm/r1); relane r1 two; ready r1
  sweep >/dev/null; sweep >/dev/null
  [ "$(sends r1)" = 2 ] || fail "a lane with a new head is not steered about its old head: $(grep '^r1	' "$W/send-calls" | cut -c1-80)"
  [ "$(git -C "$PROJ" rev-parse fm/r1)" != "$gone" ] || fail "the lane moved to a new head"
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/r1)" ] || fail "the new, proved head lands"
  # A refusal recorded for a head the lane no longer has steers nobody.
  lane r3 three; printf 'final REFUSED: an old refusal\n' > "$HOME_D/data/jg-trunk-landing/r3.0000000000000000000000000000000000000000.state"
  sweep >/dev/null; sweep >/dev/null
  [ "$(sends r3)" = 0 ] || fail "a stale-head refusal must steer nobody: $(grep "^r3	" "$W/send-calls" | cut -c1-300)"
  # A refusal that only needs time is not the worker's to fix.
  lane r4 four; : > "$HOME_D/state/.afk"; sweep >/dev/null; sweep >/dev/null; rm "$HOME_D/state/.afk"
  [ "$(sends r4)" = 0 ] || fail "a wait for time (away mode) must not steer the worker"
  # An infrastructure failure becomes final only after three attempts and then reaches the owner once.
  sweep >/dev/null; sweep >/dev/null
  printf 'gate-full=echo "cat: write error: Disk quota exceeded"; exit 1\n' >> "$HOME_D/config/trunk-policy"
  cp "$ROOT/bin/jg-send.sh" "$HOME_D/bin/jg-send.sh"
  lane jg-r5 five jg-r5.txt; printf 'kind=ship\nharness=codex\nwindow=sess:jg-jg-r5\n' >> "$HOME_D/state/jg-r5.meta"
  h=$(git -C "$PROJ" rev-parse fm/jg-r5); f=$HOME_D/data/jg-trunk-landing/jg-r5.$h.state
  for n in 1 2 3; do
    sweep >/dev/null
    for _ in $(seq 1 600); do
      if ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && ! compgen -G "$HOME_D/state/.trunk-run-*.lock" >/dev/null; then break; fi
      sleep 0.2
    done
    [ -f "$f" ] || fail "retry $n has no verdict"
    if [ "$n" -lt 3 ]; then [ ! -d "$HOME_D/state/jg-r5.inbox" ] || fail "retry $n must not steer"; fi
    touch -d '3 minutes ago' "$f"
  done
  sweep >/dev/null
  [ "$(find "$HOME_D/state/jg-r5.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l)" = 1 ] || fail "the final retry verdict must send one steer: $(cat "$f")"
  if [ "$real_backlog" = 1 ]; then
    assert_contains "$(jg_test_backlog "$HOME_D" show jg-r5 --full)" "gave up after 3 tries" "the final retry verdict reaches its ticket"
  else assert_contains "$(cat "$W/backlog-calls")" "update jg-r5 --body-file" "the final retry verdict reaches its ticket"; fi
  assert_contains "$(JG_HOME="$HOME_D" "$HOME_D/bin/jg-machine.sh" show task jg-r5)" "rework" "the exhausted lane is in rework"
  pass 'a refusal the worker fixes reaches it by steer, repeats until the head changes, alerts after ten silent minutes, and never steers a stale head or a wait'
}

test_a_refusal_reaches_the_lanes_worker_and_never_sits_silent
printf 'jg-trunk-refusal: ok\n'
