# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 2. A move out of a stage is legal from each of its sub-states; a stage that was left cannot be left again; closed is final.
for s in $(awk -F'\t' '$1=="state"{print $2}' "$TABLES/proving.tsv"); do
  jm edge-check ticket "proving.$s" building; expect_code 0 "$RC" "prove-fail from proving.$s"; assert_contains "$OUT" "prove-fail" "event named from proving.$s"
  jm edge-check ticket "proving.$s" delivering; expect_code 0 "$RC" "prove-pass from proving.$s"
done
for s in $(awk -F'\t' '$1=="state"{print $2}' "$TABLES/delivering.tsv"); do
  for to in building released; do jm edge-check ticket "delivering.$s" "$to"; expect_code 0 "$RC" "delivering.$s to $to"; done
  jm edge-check ticket "delivering.$s" proving; expect_code 0 "$RC" "new-head from delivering.$s"; assert_contains "$OUT" "proving.planned" "new-head lands on the first sub-state"
done
jm edge-check ticket intake proving; expect_code 1 "$RC" "intake cannot claim done"
jm edge-check ticket building delivering; expect_code 1 "$RC" "building cannot skip proving"
jm edge-check ticket closed intake; expect_code 1 "$RC" "closed is final"
jm edge-check delivering rebased queued; expect_code 1 "$RC" "a rebase cannot go back to the queue"
jm edge-check delivering resolving returned; expect_code 0 "$RC" "give-back from resolving"; jm edge-check delivering batched returned; expect_code 0 "$RC" "revert from the line"
for s in intake ready building proving.running delivering.gated released; do jm edge-check ticket "$s" closed; expect_code 0 "$RC" "drop from $s"; done
pass "every stage is left from each of its sub-states"
