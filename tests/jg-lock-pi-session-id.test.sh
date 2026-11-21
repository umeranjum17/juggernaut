#!/usr/bin/env bash
# A Pi primary records the Herdr session of its own pane in state/.lock-session,
# the way a Claude session records its conversation id, so bin/jg-sentinel.sh
# primary_target can find the one pane to wake. An agy primary records its
# ANTIGRAVITY_CONVERSATION_ID the same way, so the prompt hook's chat notes can
# prove they came from the locked session (tests/jg-primary-chat-approval.test.sh).
# Run through the real bin/jg-lock.sh in a temp home, with a fake `pi` or `agy`
# process and a fake herdr.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-lock-pi-session-id)
mkdir -p "$TMP_ROOT"

FB="$TMP_ROOT/fakebin"
mkdir -p "$FB"
ln -s "$(command -v bash)" "$FB/pi"
ln -s "$(command -v bash)" "$FB/codex"
ln -s "$(command -v bash)" "$FB/agy"
cat > "$FB/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"api snapshot"*)
    cat <<'JSON'
{"result":{"snapshot":{"agents":[
 {"pane_id":"p1","agent":"pi","agent_session":{"kind":"path","value":"/s/one.jsonl"}},
 {"pane_id":"p2","agent":"pi","agent_session":{"kind":"path","value":"/s/two.jsonl"}}]}}}
JSON
    ;;
esac
SH
chmod +x "$FB/herdr"

# <runtime> <pane> -> acquires the lock from that fake runtime, home in $HOME_DIR.
acquire() {
  HOME_DIR="$TMP_ROOT/home-$1-$2"
  mkdir -p "$HOME_DIR/state"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    JG_HOME="$HOME_DIR" HERDR_PANE_ID="$2" HERDR_BIN_PATH="$FB/herdr" HERDR_SESSION=default \
    "$FB/$1" -c "$ROOT/bin/jg-lock.sh; exit \$?" >"$HOME_DIR/out" 2>&1
}

acquire pi p2 || fail "a Pi session could not take the lock: $(cat "$HOME_DIR/out")"
[ "$(head -n 1 "$HOME_DIR/state/.lock-session" 2>/dev/null)" = /s/two.jsonl ] \
  || fail "a Pi primary must record its pane's Herdr session in .lock-session, got: $(cat "$HOME_DIR/state/.lock-session" 2>&1)"
pass "a Pi primary records its own pane's session id beside the lock"

acquire pi p9 || fail "a Pi session in an unlisted pane could not take the lock"
[ ! -e "$HOME_DIR/state/.lock-session" ] || fail "a pane Herdr does not list must not produce a session id"
acquire codex p2 || fail "a codex session could not take the lock"
[ ! -e "$HOME_DIR/state/.lock-session" ] || fail "a codex run in a Pi pane must not claim the pane's session id"
pass "an unlisted pane and a non-Pi runtime record no session id"

# <runtime> <home> <conversation id> [<shell tail run after the lock>] -> takes the lock from that
# fake runtime with the conversation id agy would hand its shells, home in the given directory.
acquire_agy() {
  mkdir -p "$2/state"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u HERDR_PANE_ID ANTIGRAVITY_CONVERSATION_ID="$3" \
    JG_HOME="$2" "$FB/$1" -c "$ROOT/bin/jg-lock.sh; rc=\$?; ${4:-:}; exit \$rc" >"$2/out" 2>&1
}

AGY_HOME="$TMP_ROOT/home-agy"
acquire_agy agy "$AGY_HOME" conv-one-1 || fail "an agy session could not take the lock: $(cat "$AGY_HOME/out")"
[ "$(head -n 1 "$AGY_HOME/state/.lock-session" 2>/dev/null)" = conv-one-1 ] \
  || fail "an agy primary must record its conversation id in .lock-session, got: $(cat "$AGY_HOME/state/.lock-session" 2>&1)"
pass "an agy primary records its own conversation id beside the lock"

for case_id in "" "conv/../escape" "conv with space"; do
  home="$TMP_ROOT/home-agy-bad-$(printf '%s' "$case_id" | tr -c 'A-Za-z0-9' _)"
  acquire_agy agy "$home" "$case_id" || fail "an agy session with id '$case_id' could not take the lock"
  [ ! -e "$home/state/.lock-session" ] || fail "an agy id of '$case_id' must not be recorded as a session"
done
home="$TMP_ROOT/home-codex-agy-id"
acquire_agy codex "$home" conv-one-1 || fail "a codex session could not take the lock"
[ ! -e "$home/state/.lock-session" ] || fail "a codex run that inherited an agy conversation id must not claim it"
pass "no id, a malformed id and a non-agy runtime record no agy session id"

# (The trailing `:` keeps bash from exec-ing sleep over the fake agy process.)
# A live agy primary keeps its lock and its session id against a second session
# with another conversation id and against a codex that inherited its id.
LIVE_HOME="$TMP_ROOT/home-agy-live"
mkdir -p "$LIVE_HOME/state"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u HERDR_PANE_ID ANTIGRAVITY_CONVERSATION_ID=conv-live-1 JG_HOME="$LIVE_HOME" \
  "$FB/agy" -c "$ROOT/bin/jg-lock.sh; sleep 30; :" >"$LIVE_HOME/out" 2>&1 &
LIVE_PID=$!
for _ in $(seq 1 50); do [ -s "$LIVE_HOME/state/.lock-session" ] && break; sleep 0.1; done
[ "$(head -n 1 "$LIVE_HOME/state/.lock-session" 2>/dev/null)" = conv-live-1 ] || { kill "$LIVE_PID" 2>/dev/null; fail "the live agy primary never recorded its id: $(cat "$LIVE_HOME/out")"; }
acquire_agy agy "$LIVE_HOME" conv-other-2 && { kill "$LIVE_PID" 2>/dev/null; fail "an agy session with another conversation id took a live agy primary's lock"; }
grep -q 'another live juggernaut session holds the lock' "$LIVE_HOME/out" || { kill "$LIVE_PID" 2>/dev/null; fail "the refusal does not name the live owner: $(cat "$LIVE_HOME/out")"; }
acquire_agy codex "$LIVE_HOME" conv-live-1 && { kill "$LIVE_PID" 2>/dev/null; fail "a codex that inherited the live agy id took its lock"; }
[ "$(head -n 1 "$LIVE_HOME/state/.lock-session" 2>/dev/null)" = conv-live-1 ] || { kill "$LIVE_PID" 2>/dev/null; fail "a refused session rewrote the live primary's session id"; }
kill "$LIVE_PID" 2>/dev/null
pass "a foreign agy conversation and an inheriting codex are refused and leave the live primary's session id alone"
