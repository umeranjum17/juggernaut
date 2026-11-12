#!/usr/bin/env bash
# claude-accounts-hold: the account hold, through its real caller. A lane's last beat is a billing error (what a fake runner's failure leaves in
# state/beats/<task>); one `scan` tick puts the account on hold, the observer says on-hold, the picker and a pinned launch skip it, a second
# account takes the lane (relaunch --account <id>) with no pin file changed; with one account nothing moves and the alert says every start stops.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
core=$(cd "$here/../.." && pwd) || exit 1
root=$(cd "$core/.." && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/claude-accounts-hold-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
H=$here/../bin/claude-accounts-hold.sh
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }

mkdir -p "$w/home/config" "$w/home/state/beats" "$w/a1" "$w/a2" "$w/bin"
NOW=$(date +%s)
reading() { # every account the registry names, fresh and healthy
  jq -n --argjson now "$NOW" '{schema:1, generated_at:$now, accounts:[$ARGS.positional[] | {id:., name:., folder:"/x", read_at:$now,
    five_hour:{left:80,resets_at:"2030-01-01T00:00:00+00:00"}, seven_day:{left:80,resets_at:"2030-01-01T00:00:00+00:00"}, problem:null}]}' --args "$@" > "$w/home/state/claude-accounts.json"
}
registry() { # ids of the pool
  jq -n --arg w "$w" '{version:1, accounts:[$ARGS.positional[] | {id:., provider:"claude", name:., folder:"\($w)/\(.)"}]}' --args "$@" > "$w/registry.json"
}
cat > "$w/bin/control" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$HOLD_TEST_LOG/control.log"
S
cat > "$w/bin/alert" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$HOLD_TEST_LOG/alert.log"
S
cat > "$w/bin/claude" <<'S'
#!/usr/bin/env bash
exit 0
S
chmod +x "$w/bin/control" "$w/bin/alert" "$w/bin/claude"
export HOLD_TEST_LOG=$w JG_HOME=$w/home JG_CLAUDE_ACCOUNTS_REGISTRY=$w/registry.json JG_CLAUDE_ACCOUNTS_FRESH=100000 \
  JG_HOLD_CONTROL=$w/bin/control JG_HOLD_ALERT=$w/bin/alert
S=$w/home/state
lane() { # <task> <account id> <beat error>: a live lane on the account whose last turn ended on the error
  printf 'window=w:%s\nkind=ship\naccount=%s\n' "$1" "$2" > "$S/$1.meta"
  printf '%s UserPromptSubmit\n%s StopFailure error=%s\n' "$NOW" "$NOW" "$3" > "$S/beats/$1"
}
word() { bash "$root/core/machines/observers/account.sh" "claude.$1"; }
picked() { bash "$here/../bin/claude-accounts-pick" pick claude --json --state "$S" 2>&1 | jq -r '.id // .reason' 2>/dev/null; }
echo "$w/a1" > "$w/home/config/claude-account"; pin_sum=$(cksum < "$w/home/config/claude-account")
# shellcheck disable=SC2016
pinned() { env -i PATH="$PATH" HOME="$w" JG_HOME="$w/home" bash -c '. "$1/bin/jg-worker-account-lib.sh"; jg_worker_account_select claude "$2" "" "$3"' _ "$root" "$w/home/config" "$w/bin/claude" 2>&1; }

# Two accounts: a1 is on a billing error, a2 is free.
registry a1 a2; reading a1 a2
lane t-bill a1 billing_error; lane t-other a2 rate_limit
is "a1 is available before the tick" "$(word a1)" available
is "an account with no held lane error is not held: other error types hold nothing" "$(bash "$H" status a2)" free
bash "$H" scan > "$w/scan.out" 2>&1
is "one tick puts the billing-error account on hold" "$(bash "$H" status a1)" held
is "the observer says on-hold" "$(word a1)" on-hold
is "the lane's new account is in use, not held" "$(word a2)" in-use
is "the alert names the capacity event and the hold" "$(grep -c 'capacity claude-accounts-hold .*a1 is on hold' "$w/alert.log")" 1
is "the lane moved to the second account" "$(cat "$w/control.log")" "t-bill relaunch --account a2"
is "no pick goes to the held account" "$(picked)" a2
is "a pinned launch on the held folder refuses" "$(pinned | grep -c 'is on hold (lane t-bill ended on billing_error)')" 1
is "the pin file is unchanged" "$(cksum < "$w/home/config/claude-account")" "$pin_sum"
bash "$H" release a1 >/dev/null
is "release lifts the hold" "$(word a1)" available
pinned >/dev/null; is "a pinned launch on a1 passes again" "$?" 0
bash "$H" hold a2 --reason test >/dev/null 2>&1; rm -f "$S/account-assignments.json"
is "with a2 held and a1 released the pick is a1" "$(picked)" a1
bash "$H" release a2 >/dev/null

# One account: every start stops, one alert, nothing to move to.
: > "$w/control.log"; : > "$w/alert.log"; rm -f "$S"/*-accounts-held/*
registry a1; reading a1; lane t-solo a1 billing_error
bash "$H" scan >/dev/null 2>&1
is "the lone account is on hold" "$(word a1)" on-hold
is "no lane is moved" "$(wc -c < "$w/control.log" | tr -d ' ')" 0
is "one alert says no worker starts" "$(grep -c 'no other account: no worker starts' "$w/alert.log")" 1
is "the pick refuses and names the hold" "$(picked | grep -c 'on hold')" 1
bash "$H" scan >/dev/null 2>&1
is "a second tick does not alert again" "$(wc -l < "$w/alert.log" | tr -d ' ')" 1
if [ "$fails" -eq 0 ]; then echo "all ok"; else echo "$fails failed"; exit 1; fi
