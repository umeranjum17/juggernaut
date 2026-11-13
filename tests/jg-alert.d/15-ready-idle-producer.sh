# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 15. The ready-idle producer (bin/jg-ready-idle.sh): fire raises one live ready-idle alert for its subject, a second fire keeps one record, clear resolves it.
bash "$RI" fire "ready-work:t1+t2" >/dev/null 2>&1; expect_code 0 $? "fire raises ready-idle"
assert_equals open "$(bash "$AL" word ready-idle--ready-work:t1+t2)" "the subject has one open alert"
bash "$RI" fire "ready-work:t1+t2" >/dev/null 2>&1; expect_code 0 $? "a second fire is accepted"
assert_equals open "$(bash "$AL" word ready-idle--ready-work:t1+t2)" "the second fire leaves one open alert"
bash "$RI" clear "ready-work:" >/dev/null 2>&1; expect_code 0 $? "clear is accepted"
assert_equals resolved "$(bash "$AL" word ready-idle--ready-work:t1+t2)" "clear resolves the alert"
bash "$RI" bogus >/dev/null 2>&1; expect_code 2 $? "an unknown command is a usage error"
pass "bin/jg-ready-idle.sh fire raises one ready-idle alert per subject, a second fire keeps one, and clear resolves it"
