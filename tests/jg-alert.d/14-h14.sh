# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 14. H14: each new row raises its ring; a stranded release has the 4 h limit; the ladder ends: three repeats at the top, then one stuck card.
for r in wrong-repo:2:lead lock-held:0:tick orphan-process:0:tick escalation-stuck:4:owner fleet-blocked:0:tick quota-unused:0:tick quota-blind:0:tick; do
  n=${r%%:*}; rest=${r#*:}; held=(); case $n in lock-held) held=(--held 300) ;; quota-*) held=(--held 1800) ;; esac
  al raise "$n" "s-$n" "${held[@]}"; expect_code 0 "$RC" "raise $n"
  assert_equals "$(printf 'ring\t%s--s-%s\t%s\t%s' "$n" "$n" "${rest%%:*}" "${rest#*:}")" "$OUT" "the ring of $n"
done
al raise lock-held lh2 --held 299; expect_code 1 "$RC" "lock-held fires at 5 min"
al raise lock-held lh3 --fact holder-beating; assert_equals "" "$OUT" "a beating holder keeps lock-held quiet"
al raise quota-blind qb2 --fact account-no-lane --held 1800; assert_equals "" "$OUT" "an account with no lane keeps quota-blind quiet"
al raise quota-unused qu2 --fact host-at-stop --held 1800; assert_equals "" "$OUT" "a host at its stop keeps quota-unused quiet"
al raise escalation-stuck es2 --fact presence=away; assert_contains "$OUT" "	4	owner" "presence away does not hold the page"
al raise stranded st0 --held 172799; expect_code 1 "$RC" "no kind is the 48 h default"
al raise stranded st1 --kind stranded-release --held 14399; expect_code 1 "$RC" "a waited-for release is stranded at 4 h"
al raise stranded st1 --kind stranded-release --held 14400; assert_contains "$OUT" "ring	stranded--st1	2	lead" "held 4 h rings"
al raise stranded st2 --kind stranded --held 14400; expect_code 1 "$RC" "another stranded kind still waits 48 h"
al raise line-red lr9 --project p9; k=line-red--lr9; now=$(rec $k rung_at)
al climb $k --now $((now + 300)); assert_contains "$OUT" "	3	main" "a climb to Main"
al climb $k --now $((now + 600)); assert_contains "$OUT" "	4	owner" "a climb to the owner"
for i in 1 2 3; do al climb $k --now $((now + 600 + 600 * i)); assert_contains "$OUT" "ring	$k	4	owner" "repeat $i rings the top rung again"; done
al climb $k --now $((now + 2999)); expect_code 1 "$RC" "a repeat before its timer"
al climb $k --now $((now + 3000)); expect_code 0 "$RC" "the fourth climb at the top"
assert_equals "$(printf 'stuck\t%s\t4\towner\nring\tescalation-stuck--%s\t4\towner' "$k" "$k")" "$OUT" "it prints stuck once, then the one card's ring"
assert_equals stuck "$(bash "$AL" word $k)" "the alert is stuck"
al climb $k --now $((now + 99999)); expect_code 1 "$RC" "a stuck alert is quiet"
bash "$AL" climb $k --now $((now + 99999)) 2>/dev/null | bash "$AL" deliver; expect_code 0 $? "deliver accepts the stuck line"
al climb escalation-stuck--$k --now $((now + 99999)); expect_code 1 "$RC" "the page does not repeat"
al raise line-red lr9 --project p9; assert_equals "" "$OUT" "a stuck key rings nothing"
al resolve $k; assert_equals resolved "$(bash "$AL" word escalation-stuck--$k)" "resolving the alert resolves its card"
bash "$AL" raise line-red lr9 --project p9 >/dev/null; assert_equals open "$(bash "$AL" word $k)" "a new episode is open again"
pass "the new rows ring, stranded has its 4 h kind, and a ladder that ends in one stuck card"
