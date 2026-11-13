#!/usr/bin/env bash
# jg-account-drift: a lane never wakes onto an account the home no longer selects, through the real caller (`account-drift.sh tick`) and the
# real pin/map resolver. The lifecycle command is a fake that does what a relaunch does to the record: the lane's account= becomes the account
# the home selects. Proves: an idle lane on a deselected account is relaunched inside one tick; a busy lane waits for its idle; removing the map
# moves a lane that was on the mapped account; a stop-failure lane on a held account is relaunched once; a refused relaunch raises one alert
# naming the lane and the account; a home with no pin and no map moves nothing.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
root=$(cd "$here/.." && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/jg-account-drift-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
D=$root/core/claude-accounts/bin/account-drift.sh
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }

mkdir -p "$w/home/config" "$w/home/state/beats" "$w/p1" "$w/p2" "$w/bin"
S=$w/home/state
cat > "$w/bin/control" <<'X'
#!/usr/bin/env bash
echo "$*" >> "$DRIFT_TEST_LOG/control.log"
[ ! -e "$DRIFT_TEST_LOG/refuse" ] || { echo "error: relaunch refused: no account is signed in" >&2; exit 1; }
cfg=$JG_HOME/config; model=$(sed -n 's/^model=//p' "$JG_HOME/state/$1.meta")
. "$DRIFT_TEST_ROOT/bin/jg-worker-account-lib.sh"
new=$(jg_worker_account_resolve claude "$cfg" "$model" | cut -f1)
sed -i "s|^account=.*|account=$new|" "$JG_HOME/state/$1.meta"
X
cat > "$w/bin/alert" <<'X'
#!/usr/bin/env bash
echo "$*" >> "$DRIFT_TEST_LOG/alert.log"
X
chmod +x "$w/bin/control" "$w/bin/alert"
export DRIFT_TEST_LOG=$w DRIFT_TEST_ROOT=$root JG_HOME=$w/home JG_DRIFT_CONTROL=$w/bin/control JG_DRIFT_ALERT=$w/bin/alert
lane() { # <task> <account> [model]: a live Claude lane, idle under an armed busy gen
  printf 'harness=claude\nkind=ship\nmodel=%s\naccount=%s\n' "${3:-default}" "$2" > "$S/$1.meta"
  echo g1 > "$S/$1.busy-gen"; busy "$1" idle
}
busy() { echo "v1 gen=g1 seq=1 state=$2 source=claude-hook event=x ts=1" > "$S/$1.busy-state"; }
acct() { sed -n 's/^account=//p' "$S/$1.meta"; }
tick() { bash "$D" tick > "$w/tick.out" 2>&1; }
calls() { grep -c "^$1 relaunch" "$w/control.log" 2>/dev/null || true; }
: > "$w/control.log"

# No pin, no map: nothing is selected, so nothing drifts.
lane t-free "$w/p2"; tick
is "a home with no pin and no map moves no lane" "$(calls t-free)" 0

# The pin selects p1; an idle lane on p2 is relaunched in one tick and records p1.
echo "$w/p1" > "$w/home/config/claude-account"
lane t-idle "$w/p2"; tick
is "an idle lane on a deselected account is relaunched in one tick" "$(calls t-idle)" 1
is "the relaunched lane records the pin's account" "$(acct t-idle)" "$w/p1"
tick
is "a lane on the selected account is not relaunched again" "$(calls t-idle)" 1

# A busy lane waits; the tick after its idle moves it.
lane t-busy "$w/p2"; busy t-busy busy; tick
is "a busy lane is not moved" "$(calls t-busy)" 0
busy t-busy idle; tick
is "the busy lane is moved at its next idle" "$(calls t-busy)" 1
is "and records the pin's account" "$(acct t-busy)" "$w/p1"

# The map put a model on p2; the map is removed; the lane on p2 goes back to the pin.
echo "claude-opus $w/p2" > "$w/home/config/claude-account-by-model"
lane t-map "$w/p2" claude-opus; tick
is "a lane on the account its model is mapped to stays" "$(calls t-map)" 0
rm "$w/home/config/claude-account-by-model"; tick
is "removing the map moves the lane" "$(calls t-map)" 1
is "to the pin's account" "$(acct t-map)" "$w/p1"

# A stop-failure on a held account: one relaunch, idle or not, once per beat.
mkdir -p "$S/claude-accounts-held"; printf '1\t%s\tbilling error\n' "$w/p1" > "$S/claude-accounts-held/pa1"
lane t-fail "$w/p1"; busy t-fail busy; printf '5 UserPromptSubmit\n6 StopFailure error=billing_error\n' > "$S/beats/t-fail"; tick
is "a stop-failure lane on a held account is relaunched" "$(calls t-fail)" 1
tick
is "and only once for that beat" "$(calls t-fail)" 1
rm -f "$S/claude-accounts-held/pa1"

# A refused relaunch raises one alert naming the lane and the account, and is not retried.
: > "$w/alert.log"; touch "$w/refuse"
echo "$w/p2" > "$w/home/config/claude-account"
lane t-ref "$w/p1"; tick; tick
is "a refused relaunch is tried once" "$(calls t-ref)" 1
is "and raises one alert for it" "$(grep -c 'lane t-ref ' "$w/alert.log")" 1
is "and the account" "$(grep 'lane t-ref ' "$w/alert.log" | grep -c "account $w/p1 ")" 1

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
