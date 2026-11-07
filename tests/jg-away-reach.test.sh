#!/usr/bin/env bash
# Away mode reaches the captain on Telegram by itself: entering arms it, a thirty-minute update goes
# out on the clock, an urgent ask goes out at once, an unchanged fleet is not news, and returning
# stops it. Fails if the thirty-minute clock or the urgent path is removed from bin/jg-away-reach.sh.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(jg_test_tmproot away-reach)
mkdir -p "$T/home/state" "$T/bin"
export JG_HOME=$T/home JG_STATE_OVERRIDE=$T/home/state SENT=$T/sent.log
cat > "$T/bus" <<'F'
#!/usr/bin/env bash
{ cat; printf '\n---\n'; } >> "$SENT"
F
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'echo "Needs you: 0"' 'echo "Not done: $ASKS_N"' > "$T/asks"
chmod +x "$T/bus" "$T/asks"
export JG_BUS_CMD=$T/bus JG_OWNER_ASKS_BIN=$T/asks ASKS_N=1
REACH=$ROOT/bin/jg-away-reach.sh
S=$JG_STATE_OVERRIDE
sent() { grep -c '^---$' "$SENT" 2>/dev/null || echo 0; }
printf 'working [at=1]: old\nblocked [at=2]: an old block before away mode\n' > "$S/t1.status"

"$ROOT/bin/jg-afk-contract.sh" enter --words "back later" >/dev/null 2>&1
assert_present "$S/away-reach.check.sh" "entering away mode arms the check with no further command"
assert_present "$S/away-reach.check-trust" "the check is bound by a trust record"
assert_contains "$(cat "$SENT")" "Away mode is on" "entry tells the captain the reach is on"
assert_equals 1 "$(sent)" "only the entry message so far"

export JG_AWAY_REACH_NOW=$(( $(date +%s) + 600 ))
"$S/away-reach.check.sh"
assert_equals 1 "$(sent)" "nothing goes out before the thirty minutes pass; an old block is not news"

JG_AWAY_REACH_NOW=$(( $(date +%s) + 1900 )) "$S/away-reach.check.sh"
assert_equals 2 "$(sent)" "an update goes out once thirty minutes have passed"
assert_contains "$(cat "$SENT")" "Away update" "the update is labelled"
assert_contains "$(cat "$SENT")" "Not done: 1" "the update carries the asks"

JG_AWAY_REACH_NOW=$(( $(date +%s) + 3800 )) "$S/away-reach.check.sh"
assert_equals 2 "$(sent)" "an unchanged fleet sends no second update"

ASKS_N=2 JG_AWAY_REACH_NOW=$(( $(date +%s) + 5700 )) "$S/away-reach.check.sh"
assert_equals 3 "$(sent)" "a changed fleet sends the next update on the clock"

printf 'needs-decision [at=9]: pick option A or B for the login page\n' >> "$S/t1.status"
JG_AWAY_REACH_NOW=$(( $(date +%s) + 5710 )) "$S/away-reach.check.sh"
assert_equals 4 "$(sent)" "an urgent ask goes out at once, before the next slot"
assert_contains "$(tail -n 8 "$SENT")" "Urgent: A worker needs your decision. pick option A or B" "the urgent text is plain"
JG_AWAY_REACH_NOW=$(( $(date +%s) + 5720 )) "$S/away-reach.check.sh"
assert_equals 4 "$(sent)" "the same line is sent once"

printf 'working [at=10]: token=abcdefgh12345678 sign in needed\n' >> "$S/t1.status"
JG_AWAY_REACH_NOW=$(( $(date +%s) + 5730 )) "$S/away-reach.check.sh"
assert_equals 5 "$(sent)" "a sign-in need is urgent"
assert_not_contains "$(cat "$SENT")" "abcdefgh12345678" "a secret is never sent"

"$ROOT/bin/jg-afk-contract.sh" archive >/dev/null 2>&1
assert_absent "$S/away-reach.check.sh" "returning disarms the reach"
assert_absent "$S/away-reach.check-trust" "returning removes the trust record"

# A quiet record (the captain is present) never arms it, and a stray check disarms itself.
JG_AFK_MODE=quiet "$ROOT/bin/jg-afk-contract.sh" enter >/dev/null 2>&1
assert_absent "$S/away-reach.check.sh" "quiet mode does not arm the reach"
rm -f "$S/.afk-contract"
"$REACH" arm >/dev/null
assert_absent "$S/away-reach.check.sh" "arming with no away record leaves nothing armed"
