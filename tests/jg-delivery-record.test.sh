#!/usr/bin/env bash
# shellcheck disable=SC2015 # pass/fail reporting lines: "check && pass || fail" is the intended shape here
# shellcheck disable=SC2016 # the bash -c bodies are single-quoted on purpose
# The delivery record of a steer (bin/jg-delivery.sh, bin/jg-task-inbox-lib.sh): five words, each with
# its own proof. A real steer written through the inbox library is "stored"; a ring that returned 0 is
# "rung"; moving the file to handled/ is only "read"; "handled" exists only after the worker's command
# gives evidence, and that claim reaches the bus as its own event on a throwaway accounts server; a
# worker that never answers shows up in `overdue`; a dead bus never blocks the worker.
#
# The server is a lab one on a free port with its own store, so this never touches the machine's bus.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIR=$(jg_test_tmproot jg-delivery-record)
SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
JG_NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
command -v jq >/dev/null 2>&1 || { echo "skip: jq is needed"; exit 0; }
trap jg_test_cleanup EXIT

# --- The steer ladder runs in the tick (jg-delivery-tick.sh), whatever the watcher's cycle does. ---
# A home of 30 windows, no local trunk, no watcher. Window 28 holds the inbox of a lane that never
# read its 8 steers (the oldest hours old); window 27's keystroke fails; window 29's endpoint is gone.
# One pass of the tick must give 28 its ring, record 27's failed ring with its code, and raise the
# ladder's escalation for 29. A watcher's call of the same ladder beside the tick rings once, not twice.
LH=$DIR/ladder-home
LS=$LH/state
FB=$DIR/ladder-fakebin
mkdir -p "$LS" "$LH/config" "$FB"
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift; target=; literal=0
    while [ $# -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; -l) literal=1; shift ;; *) break ;; esac
    done
    [ "$target" != "${FAKE_TMUX_FAIL_TARGET:-}" ] || exit 1
    if [ "$literal" = 1 ]; then
      [ -z "${FAKE_TMUX_SLOW:-}" ] || /bin/sleep "$FAKE_TMUX_SLOW"
      printf '%s\t%s\n' "$target" "${1:-}" >> "$FAKE_TMUX_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; *pane_current_command*) printf 'claude\n'; exit 0 ;; esac; done
    exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) cat "$FAKE_TMUX_WINDOWS"; exit 0 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/sleep"
chmod +x "$FB/tmux" "$FB/sleep"
FAKE_LOG=$DIR/ladder-typed.log; : > "$FAKE_LOG"
FAKE_WINDOWS=$DIR/ladder-windows; : > "$FAKE_WINDOWS"
for n in $(seq -w 1 30); do
  printf 'window=sess:jg-t%s\nkind=ship\nharness=claude\n' "$n" > "$LS/t$n.meta"
  [ "$n" = 29 ] || printf 'jg-t%s\n' "$n" >> "$FAKE_WINDOWS"
done
lwrite() { bash -c '. "$1/bin/jg-task-inbox-lib.sh"; jg_task_inbox_write "$2" "$3" "$4"' _ "$ROOT" "$LS" "$1" "$2" >/dev/null; }
for i in 1 2 3 4 5 6 7 8; do lwrite t28 "steer $i"; done
lwrite t27 "steer for a window whose keystroke fails"
lwrite t29 "steer for a window that is gone"
touch -d '5 hours ago' "$LS"/t28.inbox/*.msg "$LS"/t27.inbox/*.msg "$LS"/t29.inbox/*.msg
ltick() { env PATH="$FB:$PATH" FAKE_TMUX_LOG="$FAKE_LOG" FAKE_TMUX_WINDOWS="$FAKE_WINDOWS" "$@" "$ROOT/bin/jg-delivery-tick.sh" "$LH" >/dev/null 2>&1; }
ltick FAKE_TMUX_FAIL_TARGET=sess:jg-t27 || true
[ "$(grep -c '^sess:jg-t28' "$FAKE_LOG")" = 1 ] && pass "the tick gave window 28's unread inbox one ring in one pass" || fail "window 28 got $(grep -c '^sess:jg-t28' "$FAKE_LOG") rings from the tick: $(cat "$FAKE_LOG")"
jq -e 'select(.word == "ring-failed" and (.pointer | test("^[0-9]+$")))' "$LS/t27.inbox/.delivery.jsonl" >/dev/null 2>&1 \
  && pass "a failed ring is recorded as ring-failed with its code: $(jq -c 'select(.word == "ring-failed")' "$LS/t27.inbox/.delivery.jsonl" | head -1)" \
  || fail "no ring-failed word with a code for window 27: $(cat "$LS/t27.inbox/.delivery.jsonl" 2>/dev/null)"
if grep -rq 'unread juggernaut instruction.*jg-t29\|jg-t29.*unread juggernaut instruction\|sess:jg-t29.*unhandled' "$LS" 2>/dev/null; then
  pass "a dead endpoint got the ladder's escalation, not a ring"
else
  fail "no escalation was raised for window 29 (gone)"
fi
! grep -q '^sess:jg-t29' "$FAKE_LOG" && pass "nothing was typed at the dead endpoint" || fail "the tick typed at the dead endpoint"
ltick FAKE_TMUX_FAIL_TARGET=sess:jg-t27 || true
[ "$(grep -c '^sess:jg-t28' "$FAKE_LOG")" = 1 ] && pass "a second pass inside the grace rings nothing again" || fail "the second pass rang window 28 again"

# The watcher's own call of the same ladder runs beside the tick: window 26 gets one ring, not two.
lwrite t26 "steer rung by two callers"
touch -d '5 hours ago' "$LS"/t26.inbox/*.msg
: > "$FAKE_LOG"
( env PATH="$FB:$PATH" FAKE_TMUX_LOG="$FAKE_LOG" FAKE_TMUX_WINDOWS="$FAKE_WINDOWS" FAKE_TMUX_SLOW=1 \
    bash -c '. "$1/bin/jg-task-inbox-lib.sh"; jg_task_inbox_ladder "$2" t26 sess:jg-t26 tmux jg-t26' _ "$ROOT" "$LS" >/dev/null 2>&1 ) &
sleep 0.3
ltick FAKE_TMUX_SLOW=1 || true
wait
[ "$(grep -c '^sess:jg-t26' "$FAKE_LOG")" = 1 ] && pass "a watcher and the tick together ring window 26 once" || fail "window 26 got $(grep -c '^sess:jg-t26' "$FAKE_LOG") rings with both callers: $(cat "$FAKE_LOG")"
[ -n "$SERVER" ] && [ -n "$JG_NATS_BIN" ] || { echo "skip: nats-server and the nats client are needed"; exit 0; }
export JG_NATS_BIN
trap jg_test_cleanup EXIT

HOME_DIR="$DIR/home"
mkdir -p "$HOME_DIR/state/bus" "$HOME_DIR/config/bus" "$HOME_DIR/data"
port=$(( 47900 + RANDOM % 90 ))
sed "s/4222/$port/" "$ROOT/core/bus/nats.conf" > "$HOME_DIR/config/bus/nats.conf"
printf 'set nats-url nats://127.0.0.1:%s\n' "$port" > "$HOME_DIR/config/captain-channel"
export JG_WAKE_BUS_URL="nats://127.0.0.1:$port"
export JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data"
STATE=$HOME_DIR/state
BUS="$ROOT/bin/jg-bus.sh"
"$BUS" accounts "$HOME_DIR" > "$STATE/bus/accounts.conf" 2>"$DIR/accounts.err" || fail "the accounts file was not generated: $(cat "$DIR/accounts.err")"
printf 'include "../../config/bus/nats.conf"\ninclude "accounts.conf"\n' > "$STATE/bus/bus.conf"
( cd "$STATE/bus" && exec "$SERVER" -c bus.conf > "$DIR/nats.log" 2>&1 ) &
printf '%s\n' "$!" >> "$JG_TEST_BUS_REGISTRY"
for _ in $(seq 1 200); do grep -q 'Server is ready' "$DIR/nats.log" 2>/dev/null && break; sleep 0.05; done
grep -q 'Server is ready' "$DIR/nats.log" || { echo "skip: the throwaway server never became ready"; exit 0; }
for _ in $(seq 1 40); do "$BUS" bootstrap >/dev/null 2>&1; "$ROOT/bin/jg-wake-bus.sh" render >/dev/null 2>&1 && break; sleep 0.25; done

DEL="$ROOT/bin/jg-delivery.sh"
TASK=lab-task
# One real steer through the library; the ring is the one step that needs a terminal, so only the
# backend's attempt is replaced: the wrapper that records the word is the real one.
rec=$(bash -c '. "$1/bin/jg-task-inbox-lib.sh"; jg_task_inbox_write "$2" "$3" "do the thing"' _ "$ROOT" "$STATE" "$TASK") || fail "the steer was not written"
[ -f "$rec" ] || fail "no record file: $rec"
bash -c '. "$1/bin/jg-task-inbox-lib.sh"; _jg_task_inbox_ring_attempt() { return 1; }; jg_task_inbox_ring b t "$2"' _ "$ROOT" "$rec" && fail "a ring that failed returned 0"
show=$("$DEL" show "$TASK") || fail "show failed: $show"
case "$show" in *"stored="[0-9]*"rung=no read=no handled=no failed=no"*) pass "a stored steer with no ring is stored only: $show" ;; *) fail "wrong words after the write: $show" ;; esac
bash -c '. "$1/bin/jg-task-inbox-lib.sh"; _jg_task_inbox_ring_attempt() { return 0; }; jg_task_inbox_ring b t "$2"' _ "$ROOT" "$rec" || fail "a ring that landed did not return 0"
show=$("$DEL" show "$TASK")
case "$show" in *"rung="[0-9]*" read=no handled=no"*) pass "a landed ring is rung, and nothing else: $show" ;; *) fail "wrong words after the ring: $show" ;; esac
"$DEL" overdue "$TASK" --after 0 >"$DIR/overdue.out" && fail "an unanswered steer was not overdue"
grep -q '^001 ' "$DIR/overdue.out" && pass "the sender's timeout lists the steer nobody answered: $(cat "$DIR/overdue.out")" || fail "overdue did not name it: $(cat "$DIR/overdue.out")"
"$DEL" overdue "$TASK" --after 3600 >/dev/null && pass "a steer younger than the timeout is not overdue" || fail "a young steer was overdue"

# The move is a read, not a handled.
mv "$rec" "$STATE/$TASK.inbox/handled/"
show=$("$DEL" show "$TASK")
case "$show" in *"read=yes handled=no failed=no"*) pass "moving the file proves read, not handled: $show" ;; *) fail "the move was taken for more: $show" ;; esac
"$DEL" overdue "$TASK" --after 0 >/dev/null && fail "a read steer with no answer was not overdue"
pass "a read steer with no handled word is still overdue"

# Handled needs evidence of a known kind.
"$DEL" handled "$TASK" 1 >/dev/null 2>&1 && fail "handled was accepted with no evidence"
"$DEL" handled "$TASK" 1 --evidence "hearsay:it is done" >/dev/null 2>&1 && fail "handled was accepted with an unknown evidence kind"
"$DEL" handled "$TASK" 1 --evidence "commit:" >/dev/null 2>&1 && fail "handled was accepted with an empty pointer"
"$DEL" handled "$TASK" 9 --evidence "commit:abc123" >/dev/null 2>&1 && fail "handled was accepted for a steer that does not exist"
pass "handled is refused without a known evidence kind, a pointer, or a real steer"
"$DEL" handled "$TASK" 1 --evidence "commit:abc123" >"$DIR/handled.out" 2>&1 || fail "handled with evidence failed: $(cat "$DIR/handled.out")"
show=$("$DEL" show "$TASK" 1)
case "$show" in *"handled="[0-9]*" failed=no"*"evidence: commit:abc123"*) pass "handled carries its evidence pointer: $(printf '%s' "$show" | tr '\n' ' ')" ;; *) fail "handled is missing its pointer: $show" ;; esac
"$DEL" overdue "$TASK" --after 0 >/dev/null && pass "a handled steer is no longer overdue" || fail "a handled steer was overdue"

# The claim is its own event on the bus; the transport's ack is never called handled.
login=$("$BUS" login) || fail "no bus login"
user=${login%%$'\t'*}; pass_file=${login#*$'\t'}
got=''
for _ in $(seq 1 100); do
  got=$("$JG_NATS_BIN" -s "$JG_WAKE_BUS_URL" --user "$user" --password "$(cat "$pass_file")" stream get JG_INBOX --last-for "jg.$user.inbox.handled" 2>/dev/null) && break
  sleep 0.1
done
case "$got" in *'"evidence":"commit:abc123"'*'"task":"lab-task"'*|*'"task":"lab-task"'*'"evidence":"commit:abc123"'*) pass "the handled claim reached the bus as its own event" ;; *) fail "no handled event on the bus: $got" ;; esac

# The new event folds into no queue row and does not upset the renderer or the inbox settle.
WAKE="$ROOT/bin/jg-wake-bus.sh"
"$WAKE" render >/dev/null 2>&1 || fail "the renderer failed after a handled event"
"$WAKE" inbox-settle >/dev/null 2>&1 || fail "the inbox settle failed after a handled event"
"$WAKE" ids wake x >/dev/null 2>&1 || true
[ "$("$WAKE" count)" -le 1 ] && pass "a handled event adds no wake row: count=$("$WAKE" count)" || fail "a handled event became a queue row: $("$WAKE" count)"

# A refusal is a word too, with its reason.
bash -c '. "$1/bin/jg-task-inbox-lib.sh"; jg_task_inbox_write "$2" "$3" "second"' _ "$ROOT" "$STATE" "$TASK" >/dev/null
"$DEL" failed "$TASK" 2 --reason "cannot do it: no access" >/dev/null || fail "failed was refused"
"$DEL" show "$TASK" 2 | grep -q 'reason: cannot do it' && pass "a refusal is recorded with its reason" || fail "the reason is missing: $("$DEL" show "$TASK" 2)"

# A dead bus never blocks the worker: the record still holds the claim.
bash -c '. "$1/bin/jg-task-inbox-lib.sh"; jg_task_inbox_write "$2" "$3" "third"' _ "$ROOT" "$STATE" "$TASK" >/dev/null
start=$(date +%s)
JG_WAKE_BUS_URL=nats://127.0.0.1:1 JG_DELIVERY_BUS_TIMEOUT=3 "$DEL" handled "$TASK" 3 --evidence "status:done line" >/dev/null 2>"$DIR/dead.err" || fail "a dead bus blocked the claim: $(cat "$DIR/dead.err")"
[ $(( $(date +%s) - start )) -le 8 ] || fail "a dead bus held the worker too long"
"$DEL" show "$TASK" 3 | grep -q 'evidence: status:done line' && pass "with the bus down the claim is still in the record, and quickly" || fail "the claim was lost"
