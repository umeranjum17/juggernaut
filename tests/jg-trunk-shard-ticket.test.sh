#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh (the shard-budget ticket) and bin/jg-shard-hints-refresh.sh (tests/jg-trunk-fixture.sh).
# Through the fixture it runs bin/jg-trunk.sh and stands in for bin/jg-backlog.sh; the refresh tool runs for real on a copy of
# bin/ and tests/ with its real coverage guard.
#
# A gate log with a `JG_TEST_COVERAGE advise` line files one ticket, shard-budget-<project>, and the next landing's advice files
#    no second one; the first log with `JG_TEST_COVERAGE ok` closes it, and later advice reopens that same ticket.
# The refresh tool on three recorded timing files (one run with a failed sample) and one script with no sample: each hint table
#    holds the slowest passing time of each measured script, the script with no sample gets a provisional hint from the gate's own
#    time, and the guard prints no advise line. With --split and the largest shard still over, it adds one shard to the
#    runner and to the workflow matrix.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

COV='total=1 parallel=1 parallel_max_ms=1 parallel_imbalance_ms=0 parallel_unhinted=0 serial=1 serial_shards=1 serial_unhinted=0 serial_max_ms=1 serial_budget_ms=2 herdr=0'

test_an_advise_line_files_one_ticket_and_an_ok_line_closes_it() {
  local calls ledger
  world shardticket
  calls="$W/backlog-calls"; ledger="$HOME_D/data/trunk/shard-budget-proj.tsv"
  printf 'gate-full=cat %s/verdict; ! grep -q BAD work.txt\n' "$W" >> "$HOME_D/config/trunk-policy"
  printf 'JG_TEST_COVERAGE advise %s\n' "$COV" > "$W/verdict"
  lane s1 one; trunk land s1 >/dev/null 2>&1 || fail "an advise line must never refuse a landing"
  [ "$(grep -c '^add shard-budget-proj ' "$calls")" = 1 ] || fail "one ticket for the advise line: $(cat "$calls" 2>/dev/null)"
  lane s2 two; trunk land s2 >/dev/null 2>&1 || fail "the second landing must land"
  [ "$(grep -c '^add ' "$calls")" = 1 ] || fail "the next landing's advice must not file a second ticket: $(cat "$calls")"
  printf 'JG_TEST_COVERAGE ok %s\n' "$COV" > "$W/verdict"
  lane s3 three; trunk land s3 >/dev/null 2>&1 || fail "the third landing must land"
  grep -q '^done shard-budget-proj' "$calls" || fail "a gate log with no advice closes the ticket: $(cat "$calls")"
  lane s4 four; trunk land s4 >/dev/null 2>&1 || fail "the fourth landing must land"
  [ "$(grep -c '^done ' "$calls")" = 1 ] || fail "a closed ticket is not closed again: $(cat "$calls")"
  printf 'JG_TEST_COVERAGE advise %s\n' "$COV" > "$W/verdict"
  lane s5 five; trunk land s5 >/dev/null 2>&1 || fail "the fifth landing must land"
  grep -q '^reopen shard-budget-proj' "$calls" || fail "later advice reopens the same ticket: $(cat "$calls")"
  [ "$(awk -F'\t' '{ printf "%s ", $3 }' "$ledger")" = 'open closed open ' ] || fail "the ledger holds each move once: $(cat "$ledger")"
  pass 'an advise line files one ticket, the next advice files none, and a clean log closes it'
}

# A copy of the runner and the suite, so the tool edits and judges its own tree.
tool_root() {  # <name>: prints the copy's path
  local r="$TMP_ROOT/$1"
  mkdir -p "$r"; cp -r "$ROOT/bin" "$ROOT/tests" "$r"/; cp -r "$ROOT/.github" "$r"/
  printf '%s\n' "$r"
}
timing() {  # <file> <script> <exit> <ms>...
  local f=$1 body='' sep=''
  shift
  while [ "$#" -ge 3 ]; do body="$body$sep{\"path\":\"$1\",\"exit\":$2,\"duration_ms\":$3}"; sep=,; shift 3; done
  printf '{"scripts":[%s]}\n' "$body" > "$f"
}

# Two copies of the tree whose hint table lacks one serial script, so the guard advises on it; the copy $a judges a huge budget
# and the copy $b a budget nothing can meet. The guard's log on $a stands in for a gate log: its advice lists every script with no hint.
gone=tests/jg-voice.test.sh
prepare_refresh_trees() {
  local d
  A=$(tool_root refresh-a); B=$(tool_root refresh-b)
  for d in "$A" "$B"; do
    sed -i "\#^$gone [0-9]*\$#d" "$d/bin/jg-test-run.sh"
    sed -i 's/^PORTABLE_SERIAL_MAX_UNHINTED_PERCENT=.*/PORTABLE_SERIAL_MAX_UNHINTED_PERCENT=0/' "$d/bin/jg-test-run.sh"
  done
  sed -i 's/^PORTABLE_SERIAL_MAX_WEIGHT_MS=.*/PORTABLE_SERIAL_MAX_WEIGHT_MS=2000000000/' "$A/bin/jg-test-run.sh"
  sed -i 's/^PORTABLE_SERIAL_MAX_WEIGHT_MS=.*/PORTABLE_SERIAL_MAX_WEIGHT_MS=1/' "$B/bin/jg-test-run.sh"
}

test_the_refresh_tool_rewrites_the_hints_and_splits_a_shard_still_over() {
  local i pa pb
  wait "$GUARD_PID" || fail "the copy's guard must pass"
  grep -aq '^JG_TEST_COVERAGE advise' "$TMP_ROOT/gate.log" || fail "the copy must advise before the refresh (a script without a hint)"
  # The gate's own time for each script the advice lists, on this host.
  grep -a '^tests/.*\.sh$' "$TMP_ROOT/gate.log" | sed 's/.*/JG_TEST_END 2026-01-01T00:00:00Z & exit=0 duration_ms=1200 gate_skip=false/' > "$TMP_ROOT/gate-times"
  cat "$TMP_ROOT/gate-times" >> "$TMP_ROOT/gate.log"
  # A serial and a parallel script with samples in three runs (the slowest sample of run 3 failed); $gone has none.
  for i in 1 2 3; do mkdir -p "$TMP_ROOT/runs/r$i"; done
  timing "$TMP_ROOT/runs/r1/jg-test-timing-portable-serial-1.json" tests/jg-clause.test.sh 0 7000 tests/jg-brief.test.sh 0 5000
  timing "$TMP_ROOT/runs/r2/jg-test-timing-portable-serial-1.json" tests/jg-clause.test.sh 0 9000 tests/jg-brief.test.sh 0 4000
  timing "$TMP_ROOT/runs/r3/jg-test-timing-portable-serial-1.json" tests/jg-clause.test.sh 0 8000 tests/jg-brief.test.sh 1 99999
  (cd "$A" && bash bin/jg-shard-hints-refresh.sh --root "$A" --timing-dir "$TMP_ROOT/runs/r1" --timing-dir "$TMP_ROOT/runs/r2" --timing-dir "$TMP_ROOT/runs/r3" --gate-log "$TMP_ROOT/gate.log" > "$TMP_ROOT/a.out" 2>&1) &
  pa=$!
  (cd "$B" && bash bin/jg-shard-hints-refresh.sh --root "$B" --timing-dir "$TMP_ROOT/runs/r1" --gate-log "$TMP_ROOT/gate.log" --split > "$TMP_ROOT/b.out" 2>&1) &
  pb=$!
  wait "$pa" || fail "the refresh must succeed: $(cat "$TMP_ROOT/a.out")"
  wait "$pb" || fail "the split refresh must succeed: $(cat "$TMP_ROOT/b.out")"
  grep -q '^tests/jg-clause.test.sh 9000$' "$A/bin/jg-test-run.sh" || fail "the serial table holds the slowest passing time: $(cat "$TMP_ROOT/a.out")"
  grep -q '^tests/jg-brief.test.sh 5000$' "$A/bin/jg-test-run.sh" || fail "the parallel table holds the slowest passing time, a failed sample excluded"
  [ "$(grep -c "^$gone 1500\$" "$A/bin/jg-test-run.sh")" = 1 ] || fail "the script with no sample gets one provisional hint, the gate's time rounded up: $(cat "$TMP_ROOT/a.out")"
  grep -q '^JG_TEST_COVERAGE ok ' "$TMP_ROOT/a.out" || fail "the guard prints no advise line after the refresh: $(tail -3 "$TMP_ROOT/a.out")"
  grep -q '^PORTABLE_SERIAL_SHARDS=12$' "$A/bin/jg-test-run.sh" || fail "no --split, no new shard"
  grep -q '^PORTABLE_SERIAL_SHARDS=13$' "$B/bin/jg-test-run.sh" || fail "--split with the largest shard still over adds one shard: $(cat "$TMP_ROOT/b.out")"
  grep -q 'shard: \[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13\]' "$B/.github/workflows/behavior.yml" || fail "the matrix gains shard 13"
  pass 'the refresh tool rewrites both tables from the slowest passing sample, hints the script with no sample, clears the advice and splits a shard still over'
}

prepare_refresh_trees
(cd "$A" && bash bin/jg-test-run.sh --check-coverage > "$TMP_ROOT/gate.log" 2>&1) & GUARD_PID=$!
test_an_advise_line_files_one_ticket_and_an_ok_line_closes_it
test_the_refresh_tool_rewrites_the_hints_and_splits_a_shard_still_over
printf 'jg-trunk-shard-ticket: ok\n'
