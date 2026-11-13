# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 5. Replay: the words of the eight older tables, of status logs in three shapes and of a shadow log all have a target.
for v in working paused blocked needs-decision "done" resolved ready progress note failed; do
  printf '%s [at=1]: x\n2026-11-07T14:50:22Z %s: y\n%s: z\n' "$v" "$v" "$v"; done > "$H/state/lane-a.status"
tab 1794202567 task unknown "done" shadow > "$H/data/machine-shadow.log"; tab 1794202568 task landed "done" shadow >> "$H/data/machine-shadow.log"
tab 1794202569 task-inbox held-reported ring-counted shadow >> "$H/data/machine-shadow.log"
bash "$ROOT/core/machines/ticket-corpus.sh" --state "$H/state" --shadow "$H/data/machine-shadow.log" > "$T/corpus.tsv"
assert_equals 8 "$(awk -F'\t' '{print $1}' "$T/corpus.tsv" | sort -u | wc -l | tr -d ' ')" "the corpus holds the eight older tables"
assert_equals 44 "$(grep -c '^status-verb	' "$T/corpus.tsv")" "30 status lines in three shapes, as verbs, and the 14 states of the verb table"
jm replay ticket-words "$T/corpus.tsv"; expect_code 0 "$RC" "every word has a target"
assert_contains "$OUT" " 0 unmapped" "replay golden"
tab status-verb mystery >> "$T/corpus.tsv"
jm replay ticket-words "$T/corpus.tsv"; expect_code 1 "$RC" "a word without a target"; assert_contains "$OUT" "unmapped status-verb mystery" "replay names the word"
jm word ticket-words task rework; assert_equals "$(tab building worker red)" "$OUT" "rework is building, worker, red"
pass "every older word has a target"
