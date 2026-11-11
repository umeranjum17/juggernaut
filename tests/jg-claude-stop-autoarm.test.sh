#!/usr/bin/env bash
# An arm that does not confirm a live watcher leaves one row that says why:
# the watcher's own failure line, the lock holder and the age of the last beat
# (bin/jg-claude-stop-autoarm.sh; fleet-goal triage slice S21).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A lander exports these; the hook must read this fixture home, not the real one.
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE

TMP_ROOT=$(jg_test_tmproot jg-claude-stop-autoarm)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
cp -R "$ROOT/bin" "$HOME_DIR/bin"
cp -R "$ROOT/defaults" "$HOME_DIR/defaults"
: > "$HOME_DIR/config/supervision-host-off"
ln -s /bin/bash "$HOME_DIR/fake-claude"
printf 'kind=ship\n' > "$HOME_DIR/state/task1.meta"
printf 'working [at=%s]: building\n' "$(date +%s)" > "$HOME_DIR/state/task1.status"

# The watcher arm is a stand-in that fails with its own reason.
cat > "$HOME_DIR/bin/jg-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: FAILED - another watcher holds the lock\n'
exit 1
SH
chmod +x "$HOME_DIR/bin/jg-watch-arm.sh"

# A lock holder and a beat from long ago.
sleep 60 &
HOLDER=$!
mkdir -p "$HOME_DIR/state/.watch.lock"
printf '%s\n' "$HOLDER" > "$HOME_DIR/state/.watch.lock/pid"
: > "$HOME_DIR/state/.last-watcher-beat"
touch -d '-1000 seconds' "$HOME_DIR/state/.last-watcher-beat"

fire_stop_hook() {  # runs the real Stop hook from a harness-named shell that holds the session lock
  # shellcheck disable=SC2016 # the fake harness expands its own variables.
  printf '{"session_id":"sess-cause","stop_hook_active":false}\n' \
    | JG_HOME="$HOME_DIR" JG_CLAUDE_AUTOARM_ATTEMPTS=1 TRACE="$TMP_ROOT/hook.trace" "$HOME_DIR/fake-claude" -c '
        printf "%s\n" "$$" > "$JG_HOME/state/.lock"
        bash -x "$JG_HOME/bin/jg-claude-stop-autoarm.sh" 2>"$TRACE"' 2>&1
}
fire_stop_hook > "$TMP_ROOT/hook.out"

LOG="$HOME_DIR/state/.watch-triage.log"
rows=$(grep -c 'did not confirm a live watcher' "$LOG" 2>/dev/null || true)
if [ "$rows" != 1 ]; then
  kill "$HOLDER" 2>/dev/null || true
  # The hook exits silently for many reasons: print what its own trace and its surroundings say.
  fail "expected one failed-arm row, found ${rows:-0}: log=$(cat "$LOG" 2>/dev/null) hook=$(cat "$TMP_ROOT/hook.out") tmpdir=${TMPDIR:-unset} stdin=$(readlink /proc/$$/fd/0) lock=$(cat "$HOME_DIR/state/.lock" 2>&1) state=$(cd "$HOME_DIR/state" && echo .[!.]* *) trace=$(tail -n 60 "$TMP_ROOT/hook.trace" | cut -c1-200)"
fi
row=$(grep 'did not confirm a live watcher' "$LOG")
assert_contains "$row" "watcher: FAILED - another watcher holds the lock" "the row lost the watcher's own failure line"
assert_contains "$row" "lock holder pid=$HOLDER" "the row does not name the lock holder"
assert_contains "$row" "beat age 10" "the row does not give the beat age"
printf "row: %s\n" "$row"
kill "$HOLDER" 2>/dev/null || true
pass "jg-claude-stop-autoarm: a failed arm leaves one row with the watcher's failure line, the lock holder and the beat age"
