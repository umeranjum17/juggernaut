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

# Episodes (slice H17): an alert held open at the owner's rung is one page when it opens, none while it stays open,
# one when it closes; the sends of every kind share one budget of 4 in an hour.
mkdir -p "$S/alerts"
ep() { printf 'alert=supervision-down\nsubject=%s\nrung=4\nsince=%s\nnote=%s\nstate=%s\n' "$1" "$2" "$3" "$4" > "$S/alerts/supervision-down--$1.rec"; }
NOW0=$(date +%s); base=$(sent)
ep sign-off "$NOW0" "no home can start sign-off work" open
JG_AWAY_REACH_NOW=$((NOW0 + 6000)) "$S/away-reach.check.sh"
assert_equals $((base + 1)) "$(sent)" "an episode that opens sends one page"
assert_contains "$(tail -n 6 "$SENT")" "no home can start sign-off work" "the page names what is blocked"
JG_AWAY_REACH_NOW=$((NOW0 + 6000 + 3 * 3600)) "$S/away-reach.check.sh"
JG_AWAY_REACH_NOW=$((NOW0 + 6000 + 3 * 3600 + 300)) "$S/away-reach.check.sh"
assert_equals $((base + 2)) "$(sent)" "3 hours later the open episode adds no page (only the changed-fleet update may go)"
ep sign-off "$NOW0" "no home can start sign-off work" resolved
JG_AWAY_REACH_NOW=$((NOW0 + 6000 + 3 * 3600 + 3000)) "$S/away-reach.check.sh"
assert_contains "$(cat "$SENT")" "Cleared after" "the close sends a second page"
b2=$(sent)
JG_AWAY_REACH_NOW=$((NOW0 + 6000 + 3 * 3600 + 3100)) "$S/away-reach.check.sh"
assert_equals "$b2" "$(sent)" "a closed episode is paged once"
# The budget: four sends in the hour are spent, so a new episode waits and is sent when the hour has room.
T5=$((NOW0 + 20000)); printf '%s\n' "$T5" "$T5" "$T5" "$T5" > "$S/away-reach.budget"
ep disk "$T5" "the host disk is full" open
b3=$(sent)
JG_AWAY_REACH_NOW=$((T5 + 10)) "$REACH" episodes
assert_equals "$b3" "$(sent)" "over the budget a page waits"
JG_AWAY_REACH_NOW=$((T5 + 3700)) "$REACH" episodes
assert_equals $((b3 + 1)) "$(sent)" "the waiting page goes when the hour has room"

# The fleet error budget (slice H36): landings under half of ready work in the window is one burn, paged once, not once per
# tick; it clears when landings catch up, and a later burn pages again.
: > "$S/away-reach.budget"; mkdir -p "$T/home/data"
NB=$((NOW0 + 40000)); LAND=$T/home/data/trunk-landings.tsv
for i in 1 2 3 4; do printf 'done [at=%s]: ready in branch feature/x%s (local-trunk)\n' "$((NB - 100 * i))" "$i" >> "$S/t2.status"; done
printf 'lane-a\tjuggernaut\tabc\t%s\tfull\n' "$((NB - 50))" > "$LAND"
printf "%s\n" "$NB" > "$S/away-reach.d/last-slot"; b4=$(sent)
JG_AWAY_REACH_NOW=$NB "$S/away-reach.check.sh"
assert_equals $((b4 + 1)) "$(sent)" "a burn (1 landing against 4 ready) sends one page"
assert_contains "$(tail -n 6 "$SENT")" "1 landed, 4 ready" "the burn page names the landings and the ready work"
JG_AWAY_REACH_NOW=$((NB + 300)) "$S/away-reach.check.sh"
JG_AWAY_REACH_NOW=$((NB + 600)) "$S/away-reach.check.sh"
assert_equals $((b4 + 1)) "$(sent)" "a burn that goes on is not paged again"
for i in 1 2 3; do printf 'lane-%s\tjuggernaut\tdef\t%s\tfull\n' "$i" "$((NB + 650))" >> "$LAND"; done
JG_AWAY_REACH_NOW=$((NB + 900)) "$S/away-reach.check.sh"
assert_contains "$(tail -n 6 "$SENT")" "Cleared after" "the burn closes when landings catch up"
b5=$(sent)
NC=$((NB + 7200)); : > "$LAND"; printf "%s\n" "$NC" > "$S/away-reach.d/last-slot"
for i in 1 2 3; do printf 'done [at=%s]: ready in branch feature/y%s (local-trunk)\n' "$((NC - 60 * i))" "$i" >> "$S/t2.status"; done
JG_AWAY_REACH_NOW=$NC "$S/away-reach.check.sh"
assert_equals $((b5 + 1)) "$(sent)" "a second burn pages once more"

"$ROOT/bin/jg-afk-contract.sh" archive >/dev/null 2>&1
assert_absent "$S/away-reach.check.sh" "returning disarms the reach"
assert_absent "$S/away-reach.check-trust" "returning removes the trust record"

# A quiet record (the captain is present) never arms it, and a stray check disarms itself.
JG_AFK_MODE=quiet "$ROOT/bin/jg-afk-contract.sh" enter >/dev/null 2>&1
assert_absent "$S/away-reach.check.sh" "quiet mode does not arm the reach"
rm -f "$S/.afk-contract"
"$REACH" arm >/dev/null
assert_absent "$S/away-reach.check.sh" "arming with no away record leaves nothing armed"
if [ -n "${AWAY_REACH_SHOW:-}" ]; then
  printf 'PASS: every check held. The messages the captain would get on Telegram, in order:\n'
  sed 's/^---$/-----/' "$SENT"
fi
