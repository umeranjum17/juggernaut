#!/usr/bin/env bash
# tests/jg-nudge-residue.test.sh - a nudge never leaves text in an input box.
#
# The captain saw a doorbell line stay in his message box, and his own next
# sentence joined it into one unsent message. This drives the real doorbell ring
# (bin/jg-task-inbox-lib.sh) against a real tmux pane (private socket) running
# tests/fixtures/composer/fake-composer.sh, a Claude-shaped input box that can swallow
# Enter, and then types the captain's sentence into the same box:
#   1. an empty box whose Enter is swallowed ends EMPTY, and his sentence is
#      alone in it afterward;
#   2. an empty box that submits receives the line exactly once and ends empty;
#   3. a box that already holds his text is never keyed, typed into, or submitted;
#   4. a backend with no clear-line key is not typed into at all.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="jg-nudge-residue-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jg-nudge-residue.XXXXXX")
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/bin" "$WORK/inbox"
cat > "$WORK/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/jg-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-task-inbox-lib.sh"
jg_backend_source tmux || fail "jg_backend_source tmux failed"

tmux new-session -d -s nudge -x 120 -y 24 -n w || fail "tmux new-session failed"
tmux set-window-option -t nudge:w automatic-rename off
# The ring checks that an agent is alive in the pane, and tells an agent from a
# shell by its process name, so the input box runs under a copy of bash named `claude`.
cp "$(command -v bash)" "$WORK/bin/claude"
TARGET=nudge:w
RECORD="$WORK/inbox/1.msg"
printf 'body\n' > "$RECORD"
LINE=$(jg_task_inbox_doorbell_line "$RECORD") || fail "no doorbell line for the record"

# Start the input box in <mode>; <log> collects every line the box submits.
start_box() {  # <mode> <log> [text-to-type-first]
  : > "$2"
  tmux respawn-pane -k -t "$TARGET" "exec '$WORK/bin/claude' '$ROOT/tests/fixtures/composer/fake-composer.sh' '$2' $1" || fail "could not start the input box"
  sleep 0.5
  [ -z "${3:-}" ] || { tmux send-keys -t "$TARGET" -l "$3"; sleep 0.3; }
}
box_text() { tmux capture-pane -p -t "$TARGET" | sed -n 's/^❯ \{0,1\}//p' | head -1; }

# --- 1. swallowed Enter: the box ends empty, his sentence is alone ---------------
start_box swallow "$WORK/log1"
[ "$(jg_backend_composer_state tmux "$TARGET")" = empty ] || fail "the input box did not start empty"
rc=0; jg_task_inbox_ring tmux "$TARGET" "$RECORD" || rc=$?
[ "$rc" = 2 ] || fail "a ring whose Enter was swallowed returned $rc, not 2 (not delivered)"
[ -z "$(box_text)" ] || fail "the nudge stayed in the box: '$(box_text)'"
tmux send-keys -t "$TARGET" -l "please rebase onto main"; sleep 0.3
[ "$(box_text)" = "please rebase onto main" ] || fail "his sentence joined leftover text: '$(box_text)'"
[ ! -s "$WORK/log1" ] || fail "something was submitted: $(cat "$WORK/log1")"
pass "an empty box whose Enter is swallowed ends empty; his next sentence is alone"

# --- 2. working Enter: delivered exactly once, box ends empty --------------------
start_box submit "$WORK/log2"
rc=0; jg_task_inbox_ring tmux "$TARGET" "$RECORD" || rc=$?
[ "$rc" = 0 ] || fail "a ring into a submitting box returned $rc"
[ "$(wc -l < "$WORK/log2")" = 1 ] || fail "the nudge was delivered $(wc -l < "$WORK/log2") times"
[ "$(head -1 "$WORK/log2")" = "$LINE" ] || fail "the box received '$(head -1 "$WORK/log2")'"
[ -z "$(box_text)" ] || fail "the box is not empty after delivery: '$(box_text)'"
pass "a submitting box receives the nudge exactly once and ends empty"

# --- 3. his text is already there: never touched ---------------------------------
start_box swallow "$WORK/log3" "half a sentence"
rc=0; jg_task_inbox_ring tmux "$TARGET" "$RECORD" || rc=$?
[ "$rc" = 1 ] || fail "a ring into a box holding his text returned $rc, not 1 (skipped)"
[ "$(box_text)" = "half a sentence" ] || fail "his text was changed: '$(box_text)'"
[ ! -s "$WORK/log3" ] || fail "his text was submitted: $(cat "$WORK/log3")"
verdict=$(jg_backend_send_nudge tmux "$TARGET" "$LINE" 2 0.2 0.2)
[ "$verdict" = holds-text ] || fail "the nudge helper answered '$verdict' for a box holding his text"
[ "$(box_text)" = "half a sentence" ] || fail "the helper changed his text: '$(box_text)'"
pass "a box that already holds his text is never touched"

# --- 4. no clear-line key: not typed at all --------------------------------------
verdict=$(jg_backend_send_nudge orca "nowhere" "$LINE" 2 0.2 0.2)
[ "$verdict" = not-withdrawable ] || fail "a backend with no clear key answered '$verdict'"
pass "a backend that cannot take the line back is not typed into"

# An existing non-Codex pane still submits its own pending doorbell as before.
start_box submit "$WORK/log5" "$LINE"
rc=0; jg_task_inbox_ring tmux "$TARGET" "$RECORD" || rc=$?
[ "$rc" = 0 ] || fail "the non-Codex pending doorbell returned $rc"
[ "$(wc -l < "$WORK/log5")" = 1 ] || fail "the non-Codex pending doorbell was not submitted once"
[ "$(head -1 "$WORK/log5")" = "$LINE" ] || fail "the non-Codex pending doorbell changed"
pass "a non-Codex pane still submits its own pending doorbell"
