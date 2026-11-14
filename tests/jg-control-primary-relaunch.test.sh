#!/usr/bin/env bash
# tests/jg-control-primary-relaunch.test.sh - `jg-control.sh primary relaunch
# --clear-composer`, through the real caller, in a real Herdr lab session.
#
# The lab primary is a stand-in harness named `claude`: it registers with Herdr
# as a claude agent with a session id, draws the recorded Claude composer frame
# (tests/fixtures/doorbell-composer), and on every start does what a primary's
# session start does - takes state/.lock, writes state/.lock-session and takes
# the waiting wake record (on a restart). Nothing here starts a real model or touches the live
# default Herdr session: every Herdr call goes through bin/jg-herdr-lab.sh.
#   1. a pane that is not the locked primary: refused, nothing signalled, one row;
#   2. a person's draft in the box: refused, the session lives, one row;
#   3. --force: refused;
#   4. a primary whose box holds our own stuck doorbell line: one relaunch - the
#      old process ends, the same command runs again in the same pane, the new
#      session holds the lock and has taken the waiting wake, one relaunched row;
#   5. a second call inside 10 minutes: refused, the new session untouched, one
#      more row, and the log tells the lead what happened.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_live_gate default-on JG_CONTROL_PRIMARY_LAB herdr jq

HELPER=$ROOT/bin/jg-herdr-lab.sh
FRAMES=$ROOT/tests/fixtures/doorbell-composer
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
REAL_HERDR=$(command -v herdr)
ORIGINAL_PATH=$PATH
TMP=$(jg_test_tmproot jgcpr)
LAB=$("$HELPER" name jg-primary-relaunch)
LAB_READY=0
export HELPER LAB REAL_HERDR ORIGINAL_PATH

cleanup() {
  local status=$?
  [ "$LAB_READY" -eq 0 ] || "$HELPER" teardown "$LAB" >/dev/null 2>&1 || status=1
  exit "$status"
}
trap cleanup EXIT

lab() { "$HELPER" run "$LAB" "$@"; }

# The adapter appends --session <lab>; this shim accepts only that session and
# hands the call to the guarded helper, so production code reaches only the lab.
mkdir -p "$TMP/fakebin" "$TMP/stub"
cat >"$TMP/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$LAB" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then exec env PATH="$ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$LAB"; fi
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$LAB" "$@"
SH
chmod +x "$TMP/fakebin/herdr"

# The stand-in primary: a copy of bash named `claude` running body.sh, so its comm is `claude`, so Herdr detects it and the lock
# owner check accepts it.
cp "$(command -v bash)" "$TMP/stub/claude"
cat >"$TMP/stub/body.sh" <<'SH'
home= box=empty
while [ $# -gt 0 ]; do
  case "$1" in --home) home=$2; shift ;; --box) box=$2; shift ;; --model) shift ;; esac
  shift
done
state=$home/state
sid=sid-$$
n=$(cat "$home/starts" 2>/dev/null || echo 0)
echo $((n + 1)) >"$home/starts"
[ "$n" = 0 ] || box=empty
herdr pane report-agent "$HERDR_PANE_ID" --source herdr:claude --agent claude --state idle --agent-session-id "$sid" >/dev/null 2>&1
printf '%s\n' "$$" >"$state/.lock"
printf '%s\n' "$sid" >"$state/.lock-session"
mkdir -p "$state/wake-taken"
# The first start is the home's normal session; only a restarted session finds
# the wake that waited behind the stuck box.
for rec in "$state"/operational-inbox/*.msg; do
  [ "$n" != 0 ] && [ -f "$rec" ] && mv "$rec" "$state/wake-taken/$$-${rec##*/}"
done
frame=$home/frame-$box.txt
printf '\033[2J\033[H'
cat "$frame"
while :; do sleep 1; done
SH

doorbell_line() {  # <state> -> a fresh record and the doorbell line that names it
  local state=$1 line
  # shellcheck source=bin/jg-operational-input.sh
  . "$ROOT/bin/jg-operational-input.sh"
  jg_operational_record_write "$state" watcher "a wake waits" line || return 1
  printf '%s' "$line"
}

# new_home <name> <box> -> $HOME_DIR with a primary running in its own pane
new_home() {
  local name=$1 box=$2 line n=0
  HOME_DIR=$TMP/$name
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
  line=$(doorbell_line "$HOME_DIR/state") || fail "could not write the wake record"
  sed -e "s|@DOORBELL@|$line|" -e "s|@DOORBELL_PART@|${line:0:40}|" "$FRAMES/stuck.txt" >"$HOME_DIR/frame-stuck.txt"
  cp "$FRAMES/emptied.txt" "$HOME_DIR/frame-empty.txt"
  cp "$FRAMES/draft.txt" "$HOME_DIR/frame-draft.txt"
  lab workspace create --cwd "$HOME_DIR" --label "$name" >"$HOME_DIR/ws.json" 2>&1 || fail "no lab workspace for $name"
  PANE=$(jq -r '.result.root_pane.pane_id' "$HOME_DIR/ws.json")
  sleep 1
  lab pane run "$PANE" "$TMP/stub/claude $TMP/stub/body.sh --model haiku --home $HOME_DIR --box $box" >/dev/null 2>&1
  while [ "$n" -lt 40 ]; do
    [ -s "$HOME_DIR/state/.lock-session" ] \
      && [ "$(lab api snapshot 2>/dev/null | jq -r --arg p "$PANE" '[.result.snapshot.agents[]? | select(.pane_id == $p)] | length')" = 1 ] && break
    sleep 0.5
    n=$((n + 1))
  done
  [ "$n" -lt 40 ] || fail "the stand-in primary of $name did not register"
  OLD_PID=$(head -n 1 "$HOME_DIR/state/.lock")
}

run_primary() {  # <home> <args...>
  local home=$1
  shift
  env PATH="$TMP/fakebin:$ORIGINAL_PATH" JG_HOME="$home" JG_CONTROL_PRIMARY_HERDR_SESSION="$LAB" \
    HERDR_LAB_SESSION="$LAB" LAB="$LAB" HELPER="$HELPER" REAL_HERDR="$REAL_HERDR" ORIGINAL_PATH="$ORIGINAL_PATH" \
    JG_CONTROL_LAUNCH_WAIT=40 JG_CONTROL_EXIT_WAIT=15 "$ROOT/bin/jg-control.sh" primary "$@"
}

rows() { wc -l <"$1/data/primary-relaunches.tsv" 2>/dev/null | tr -d ' '; }
alive() { kill -0 "$1" 2>/dev/null; }
assert_alive() { alive "$1" || fail "$2"; pass "$2"; }
assert_dead() { ! alive "$1" || fail "$2"; pass "$2"; }

"$HELPER" provision "$LAB" >/dev/null 2>&1 || fail "the lab session did not provision"
LAB_READY=1

# 1. A pane that is not the locked primary.
new_home notlocked empty
printf 'sid-someone-else\n' >"$HOME_DIR/state/.lock-session"
out=$(run_primary "$HOME_DIR" relaunch --clear-composer 2>&1); rc=$?
expect_code 1 "$rc" "a pane that is not the locked primary is refused"
assert_contains "$out" "not the locked primary" "the refusal names the missing proof"
assert_alive "$OLD_PID" "a refused relaunch leaves the session running"
assert_equals 1 "$(rows "$HOME_DIR")" "the refusal is one row for the lead"
assert_contains "$(cat "$HOME_DIR/data/primary-relaunches.tsv")" "refused" "the row says refused"

# 2. A person's draft in the input box is never cleared.
new_home typing draft
out=$(run_primary "$HOME_DIR" relaunch --clear-composer 2>&1); rc=$?
expect_code 1 "$rc" "a person typing blocks the relaunch"
assert_contains "$out" "not our doorbell line" "the refusal says why"
assert_alive "$OLD_PID" "a draft in the box keeps the session running"

# 3. There is no --force.
out=$(run_primary "$HOME_DIR" relaunch --clear-composer --force 2>&1); rc=$?
expect_code 1 "$rc" "--force is refused"
assert_contains "$out" "no --force" "the refusal names the missing flag"
out=$(run_primary "$HOME_DIR" relaunch 2>&1); rc=$?
expect_code 1 "$rc" "a relaunch without --clear-composer is refused"

# 4. A box that cannot be cleared: one relaunch, and the new session takes the wake.
new_home stuck stuck
out=$(run_primary "$HOME_DIR" relaunch --clear-composer 2>&1); rc=$?
expect_code 0 "$rc" "a primary with a stuck doorbell line is relaunched: $out"
assert_contains "$out" "relaunched primary harness=claude model=haiku" "the output names the harness and the model"
assert_contains "$out" "lock=taken" "the new session took the lock"
assert_dead "$OLD_PID" "the old primary process ended"
NEW_PID=$(head -n 1 "$HOME_DIR/state/.lock")
assert_not_equals "$OLD_PID" "$NEW_PID" "a new primary process holds the lock"
assert_alive "$NEW_PID" "the new primary process runs"
assert_equals "$PANE" "$(lab api snapshot | jq -r --arg s "$(head -n 1 "$HOME_DIR/state/.lock-session")" '.result.snapshot.agents[] | select(.agent_session.value == $s) | .pane_id')" "the new session runs in the same pane"
# The stand-in takes the lock before the wake, as a primary does, so the relaunch
# can return between the two: wait for the wake rather than reading it once.
n=0
while [ "$n" -lt 40 ] && ! compgen -G "$HOME_DIR/state/wake-taken/*.msg" >/dev/null; do
  sleep 0.25
  n=$((n + 1))
done
compgen -G "$HOME_DIR/state/wake-taken/*.msg" >/dev/null || fail "the waiting wake was not taken"
pass "the new session took the waiting wake"
assert_equals 2 "$(cat "$HOME_DIR/starts")" "the primary started twice"
assert_equals 1 "$(rows "$HOME_DIR")" "one relaunch is one row"
assert_contains "$(cat "$HOME_DIR/data/primary-relaunches.tsv")" "relaunched" "the row says relaunched"

# 5. A second call inside 10 minutes.
out=$(run_primary "$HOME_DIR" relaunch --clear-composer 2>&1); rc=$?
expect_code 1 "$rc" "a second relaunch inside 10 minutes is refused"
assert_contains "$out" "at most one in 600s" "the refusal names the limit"
assert_alive "$NEW_PID" "the refused second call leaves the new session running"
assert_equals 2 "$(rows "$HOME_DIR")" "the refusal adds one row for the lead"

echo "all primary relaunch checks passed"
