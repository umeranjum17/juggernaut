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

test_a_refusal_is_classed_wait_retry_or_final_from_its_output
test_a_refusal_the_machine_caused_is_retried_after_a_backoff_and_never_forgotten
printf 'jg-trunk-retry: ok\n'
