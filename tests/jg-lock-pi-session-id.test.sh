#!/usr/bin/env bash
# A Pi primary records the Herdr session of its own pane in state/.lock-session,
# the way a Claude session records its conversation id, so bin/jg-sentinel.sh
# primary_target can find the one pane to wake. Run through the real
# bin/jg-lock.sh in a temp home, with a fake `pi` process and a fake herdr.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-lock-pi-session-id)
mkdir -p "$TMP_ROOT"

FB="$TMP_ROOT/fakebin"
mkdir -p "$FB"
ln -s "$(command -v bash)" "$FB/pi"
ln -s "$(command -v bash)" "$FB/codex"
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
