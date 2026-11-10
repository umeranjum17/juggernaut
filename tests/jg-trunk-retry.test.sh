#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh and the registered landing check core/trunk-landing: a refused landing is classed wait, retry
# or final, and a refusal the machine caused is tried again by itself (tests/jg-trunk-fixture.sh).
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh, reads bin/jg-dod-lib.sh and stands in for bin/jg-captain-hold.sh,
# bin/jg-backlog.sh, bin/jg-send.sh, bin/jg-teardown.sh, bin/jg-fleet-ledger.sh and bin/jg-home-health.sh.
#
# T17 `jg-trunk.sh classify` says wait, retry or final for a refusal's output: the refusals of 9 Nov 12:17-12:27 (a shard result
#    missing, a slow decisions read, a failed checkout, a full temp directory) are retry; a conflict, a lint red and a lane's own red stay
#    final; a refusal that only needs time is wait.
# T18 The landing check tries a retry refusal again after a 2 minute backoff and lands it when it passes; a refusal the machine causes
#    on every try is tried 3 times, then final with one report, so no lane is forgotten and none is retried for ever.
# T19 A wait refusal is never left stale: while every check sweep finds another landing running, the start that landing's end chains
#    (`next`) restarts a land-next lane refused in away mode once away mode ends, and it lands with no hand step (10 Nov: three lanes sat
#    hours on a wait cleared long before, while newer lanes landed past them); a lane whose wait still holds is judged again, stays
#    waiting, and is not restarted in a loop. A red trunk is never a wait (fric-no-red-trunk-stop), so away mode stands in for it.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# The refusals of 9 Nov (12:17-12:27) and the ones that must stay final, as the lander printed them: the verdict is the same on every path.
test_a_refusal_is_classed_wait_retry_or_final_from_its_output() {
  local d f
  world classify; d="$W/logs"; mkdir -p "$d"
  printf '%s\n' "jg-test-run: aggregate input not found: /d/shard-6.json" "REFUSED: gate 'full' failed (exit 1) at 182136d9ab37; full log: /d/gate-full.log" > "$d/codex"
  printf '%s\n' "jg-captain-hold: backlog show sm-s8 exceeded its 10s backlog read bound" "REFUSED: could not read the decisions linked to task sm-s8" > "$d/decisions"
  printf '%s\n' "jg-test-run: aggregate input not found: /d/shard-5.json" "REFUSED: gate 'full' failed (exit 1) at 46d7198badd8; this lane introduced or changed the failure of: tests/a.test.sh" > "$d/batch-red"
  printf '%s\n' "fatal: sha1 file '/tmp/tmp.x/tree/.git/index.lock' write error: Disk quota exceeded" "error: cannot check out 7af674eac94b for the gate" > "$d/checkout"
  printf '%s\n' "cat: write error: Disk quota exceeded" "REFUSED: gate 'full' failed (exit 1) at 1111111; full log: /d/gate-full.log" > "$d/quota"
  printf '%s\n' "REFUSED: fm/x conflicts with trunk (abc) in: work.txt; a lane rebases and fixes it" > "$d/conflict"
  printf '%s\n' "In a.sh line 3: SC2034: i appears unused." "REFUSED: gate 'lint' failed (exit 1) at b59e014; full log: /d/gate-lint.log" > "$d/lint"
  printf '%s\n' "not ok - the lane broke it" "REFUSED: gate 'full' failed (exit 1) at 2222222; full log: /d/gate-full.log" > "$d/test-red"
  printf '%s\n' "REFUSED: away mode: trunk landings stay held" > "$d/away"
  printf '%s\n' "cat: write error: Disk quota exceeded" "REFUSED: fm/x conflicts with trunk (abc) in: work.txt" > "$d/conflict-with-quota"
  for f in codex decisions batch-red checkout quota; do [ "$(trunk classify "$d/$f")" = retry ] || fail "$f must be classed retry"; done
  for f in conflict lint test-red conflict-with-quota; do [ "$(trunk classify "$d/$f")" = final ] || fail "$f must stay final"; done
  [ "$(trunk classify "$d/away")" = wait ] || fail "away mode only needs time"
  printf '%s\n' "REFUSED: gate 'full' failed (exit 1) at 3333333; this lane introduced or changed the failure of: tests/a.test.sh" > "$d/explained-red"
  printf '%s\n' "tests/lib.sh: line 965: printf: write error: Disk quota exceeded" > "$d/gate-full.log"
  [ "$(trunk classify "$d/explained-red")" = final ] || fail "a red with no machine failure in sight is the lane's"
  [ "$(trunk classify "$d/explained-red" "$d/gate-full.log")" = retry ] || fail "a quota error in the gate log is the machine's, not the lane's"
  pass 'a refusal is classed wait, retry or final from its output: the three infrastructure reds retry; a conflict, a lint red and a lane red stay final'
}

settle() {  # wait, without the sweep's short bound, until no landing is running and the last one has let go of its run lock
  local _
  for _ in $(seq 1 600); do
    if ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && ! compgen -G "$HOME_D/state/.trunk-run-*.lock" >/dev/null; then break; fi
    sleep 0.2
  done
}

# shellcheck disable=SC2016 # the gate body is written out verbatim and expands when the gate runs it
test_a_refusal_the_machine_caused_is_retried_after_a_backoff_and_never_forgotten() {
  local c out _
  world retry
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # r1: the gate fails once on a full temp directory, then passes.
  printf 'gate-full=echo run >> "%s/r1-runs"; if [ "$(wc -l < "%s/r1-runs")" = 1 ]; then echo "cat: write error: Disk quota exceeded"; exit 1; fi; exit 0\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
  lane r1 one; c=$(git -C "$PROJ" rev-parse fm/r1)
  out=$(sweep); settle
  [ -z "$out" ] || fail "a retry is not a report: $out"
  grep -q '^retry 1 ' "$HOME_D/data/jg-trunk-landing/r1.$c.state" || fail "the refusal must wait in the retry state: $(cat "$HOME_D/data/jg-trunk-landing/r1.$c.state")"
  [ "$(tip)" != "$c" ] || fail "the first try must not land"
  sweep >/dev/null; settle; [ "$(wc -l < "$W/r1-runs" | tr -d ' ')" = 1 ] || fail "the backoff must hold the second try back"
  touch -d '3 minutes ago' "$HOME_D/data/jg-trunk-landing/r1.$c.state"
  sweep >/dev/null; settle; sweep >/dev/null; settle
  [ "$(tip)" = "$c" ] || fail "the lane must land by itself once the backoff passed: $(cat "$HOME_D/data/jg-trunk-landing/r1.$c.state")"
  # r2: the gate fails on the machine every time: three tries, then final, reported once.
  printf 'gate-full=echo run >> "%s/r2-runs"; echo "cat: write error: Disk quota exceeded"; exit 1\n' "$W" >> "$HOME_D/config/trunk-policy"
  lane r2 two work2.txt; c=$(git -C "$PROJ" rev-parse fm/r2); out=
  for _ in 1 2 3; do
    out="$out$(sweep)"; settle; touch -d '3 minutes ago' "$HOME_D/data/jg-trunk-landing/r2.$c.state"
  done
  out="$out$(sweep)"; settle; sweep >/dev/null; settle
  [ "$(wc -l < "$W/r2-runs" | tr -d ' ')" = 3 ] || fail "a machine failure is tried 3 times in all: $(cat "$W/r2-runs")"
  assert_contains "$out" "r2 not landed: gave up after 3 tries" "the last try is final and reported"
  [ "$(printf '%s' "$out" | grep -c 'r2 not landed')" = 1 ] || fail "the report must come once: $out"
  grep -q '^final ' "$HOME_D/data/jg-trunk-landing/r2.$c.state" || fail "the lane must end final"
  pass 'a refusal the machine caused is retried after a backoff, ends final after 3 tries with one report, and a pass lands by itself'
}

attempts() { compgen -G "$HOME_D/data/jg-trunk-landing/$1.$2.request-*.log" | grep -c .; }  # <id> <head>: landing tries recorded
chained_start() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" next "$HOME_D" || fail "next must not fail"; }

test_a_wait_whose_reason_cleared_lands_while_the_check_finds_the_trunk_busy() {
  local m w1 w2 n1 busy other
  world wait-cleared; m=$HOME_D/data/jg-trunk-landing
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # w1, marked land-next, is refused in away mode and waits.
  : > "$HOME_D/state/.afk"
  lane w1 one; w1=$(git -C "$PROJ" rev-parse fm/w1); : > "$HOME_D/state/w1.land-next"
  sweep >/dev/null; settle
  grep -q '^wait REFUSED: away mode' "$m/w1.$w1.state" || fail "away mode must hold w1 in wait: $(cat "$m/w1.$w1.state")"
  # Away mode ends hours later, while another lane's landing runs whenever the check sweeps, and a new lane n1 reports done.
  rm -f "$HOME_D/state/.afk"; touch -d '3 hours ago' "$m/w1.$w1.state"
  sleep 300 & busy=$!; other=$(printf 'c%.0s' $(seq 40))
  printf 'running %s %s\n' "$(date +%s)" "$busy" > "$m/x1.$other.state"
  lane n1 two work2.txt; n1=$(git -C "$PROJ" rev-parse fm/n1)
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null || fail "the check must not fail"
  [ "$(attempts w1 "$w1")" = 1 ] || fail "no landing starts while another one runs"
  # That landing ends and starts the next one at once, as every landing does.
  kill "$busy"; wait "$busy" 2>/dev/null; printf 'landed cleaned up\n' > "$m/x1.$other.state"
  chained_start; settle
  grep -q '^landed' "$m/w1.$w1.state" || fail "w1 must land once away mode ends, with no hand step: $(cat "$m/w1.$w1.state")"
  grep -q '^landed' "$m/n1.$n1.state" || fail "n1 must land with it: $(cat "$m/n1.$n1.state")"
  git -C "$PROJ" log --format=%s trunk | grep -qx 'ticket w1' || fail "the trunk must hold w1"
  # w2 is refused in away mode that still holds: judged again after the backoff, it stays waiting, and a second start at once tries nothing.
  : > "$HOME_D/state/.afk"
  lane w2 three work3.txt; w2=$(git -C "$PROJ" rev-parse fm/w2)
  sweep >/dev/null; settle
  grep -q '^wait REFUSED: away mode' "$m/w2.$w2.state" || fail "away mode must hold w2 in wait: $(cat "$m/w2.$w2.state")"
  touch -d '3 hours ago' "$m/w2.$w2.state"
  chained_start; settle
  [ "$(attempts w2 "$w2")" = 2 ] || fail "the chained start must judge w2 again: $(attempts w2 "$w2") tries"
  grep -q '^wait REFUSED: away mode' "$m/w2.$w2.state" || fail "w2 must stay waiting while away mode holds: $(cat "$m/w2.$w2.state")"
  chained_start; settle
  [ "$(attempts w2 "$w2")" = 2 ] || fail "a lane just refused must not restart itself in a loop: $(attempts w2 "$w2") tries"
  ! git -C "$PROJ" log --format=%s trunk | grep -qx 'ticket w2' || fail "w2 must not land in away mode"
  rm -f "$HOME_D/state/.afk"
  pass 'a wait whose reason cleared lands on the start a finished landing chains, and a wait whose reason holds stays waiting with no loop'
}

test_a_refusal_is_classed_wait_retry_or_final_from_its_output
test_a_wait_whose_reason_cleared_lands_while_the_check_finds_the_trunk_busy
test_a_refusal_the_machine_caused_is_retried_after_a_backoff_and_never_forgotten
printf 'jg-trunk-retry: ok\n'
