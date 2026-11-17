# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 19. An action closes only on source-clear proof, and an acknowledgement keeps the alert's deadline (report section 5.2, ban B10):
# taking the alert, an unrelated done line and a vanished queue row never clear it; its deadline still comes due and overdue names it; and
# only a proof closes it, once.
key=stuck-wait--proof
al raise stuck-wait proof --fact wait=lead --deliver; expect_code 0 "$RC" "raise the action for the lead"
al ack $key; expect_code 0 "$RC" "the lead takes it"
ack_at=$(rec $key ack_at)
assert_equals "$((ack_at + 600))" "$(rec $key deadline_at)" "the ack keeps the acknowledged state's deadline"
cp "$Q" "$T/queue.before" 2>/dev/null || :
printf 'done [at=%s]: an unrelated lane finished\n' "$ack_at" >> "$H/state/other.status"
: > "$Q"
assert_equals "$((ack_at + 600))" "$(rec $key deadline_at)" "an unrelated done line and a rotated queue never move the deadline"
assert_equals acknowledged "$(bash "$AL" word $key)" "a read notice and a vanished queue row do not close it"
cat "$T/queue.before" > "$Q" 2>/dev/null || :
al resolve $key; expect_code 1 "$RC" "a close with no proof is refused"
assert_equals acknowledged "$(bash "$AL" word $key)" "the refused close leaves it live"
al overdue --now $((ack_at + 599)); assert_not_contains "$OUT" "$key	" "not overdue before the deadline"
al overdue --now $((ack_at + 600)); expect_code 1 "$RC" "overdue at the deadline"
assert_contains "$OUT" "$key	acknowledged" "overdue names the acknowledged action"
al climb $key --now $((ack_at + 600)); assert_contains "$OUT" "ring	$key" "its deadline comes due and rings its rung again"
assert_equals open "$(bash "$AL" word $key)" "the deadline reopens it"
al resolve $key --proof notice:read; expect_code 1 "$RC" "an evidence kind that is not domain evidence is refused"
al resolve $key --proof task:no-such-ticket; expect_code 1 "$RC" "a task this home does not hold is refused"
printf 'working [at=%s]: on it\n' "$ack_at" > "$H/state/tk-proof.status"
al resolve $key --proof status:tk-proof; expect_code 0 "$RC" "the action's own status record closes it"
assert_equals resolved "$(bash "$AL" word $key)" "resolved"
assert_equals status:tk-proof "$(rec $key proof)" "the record keeps the proof that closed it"
al resolve $key; expect_code 0 "$RC" "a second close changes nothing"
pass "an acknowledgement keeps the deadline, and only source-clear proof closes the action"
