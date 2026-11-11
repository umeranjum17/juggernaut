#!/usr/bin/env bash
# Exercise a swallowed direct Codex send followed by a durable inbox doorbell.
# shellcheck disable=SC2016 # The dollar sign is literal Codex input.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v tmux >/dev/null || { echo 'skip: tmux unavailable'; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="jg-held-wake-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jg-held-wake.XXXXXX")
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf -- "$WORK"; }
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK/bin" "$WORK/home/state" "$WORK/home/config" "$WORK/home/data"
cat > "$WORK/bin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ] && [ -e '$WORK/swallow' ]; then
  for arg in "\$@"; do
    if [ "\$arg" = Enter ]; then printf 'Enter\n' >> '$WORK/enters'; rm -f '$WORK/swallow'; exit 0; fi
  done
fi
if [ "\${1:-}" = send-keys ]; then
  for arg in "\$@"; do [ "\$arg" != Enter ] || printf 'Enter\n' >> '$WORK/enters'; done
fi
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
SH
chmod +x "$WORK/bin/tmux"
cp "$(command -v bash)" "$WORK/bin/codex"
export PATH="$WORK/bin:$PATH" JG_HOME="$WORK/home" JG_ROOT_OVERRIDE="$WORK/home"
export JG_SEND_RETRIES=1 JG_SEND_SLEEP=0.1 JG_TASK_INBOX_GRACE_SECS=1 JG_TASK_INBOX_HELD_SECS=1
export JG_KV_URL=nats://127.0.0.1:1 JG_WAKE_BUS_URL=nats://127.0.0.1:1 JG_STATE_BUS_URL=nats://127.0.0.1:1
printf 'window=held:jg-lead\nkind=ship\nharness=codex\n' > "$JG_HOME/state/lead.meta"
tmux new-session -d -s held -n jg-lead -x 200 -y 40
: > "$WORK/submitted"
tmux send-keys -t held:jg-lead "exec '$WORK/bin/codex' '$ROOT/tests/fixtures/composer/fake-composer.sh' '$WORK/submitted'" Enter
sleep 0.5
: > "$WORK/swallow"
rc=0
bash "$ROOT/bin/jg-send.sh" lead '$wake held text' >"$WORK/direct.out" 2>"$WORK/direct.err" || rc=$?
[ "$rc" -eq 3 ] || fail "direct send should be unconfirmed, got $rc: $(cat "$WORK/direct.err")"
bash "$ROOT/bin/jg-send.sh" lead 'wake the lead' >"$WORK/bell.out" 2>"$WORK/bell.err" || fail 'inbox send failed'
sleep 2
bash "$ROOT/bin/jg-delivery-tick.sh" "$JG_HOME" >"$WORK/tick.out" 2>"$WORK/tick.err" || fail 'delivery tick failed'
[ "$(grep -cF '$wake held text' "$WORK/submitted" || true)" -eq 1 ] || fail "own held wake was not submitted exactly once: $(cat "$WORK/submitted"); $(cat "$WORK/direct.err" "$WORK/bell.err" "$WORK/tick.err"); $(tmux capture-pane -p -t held:jg-lead); $(ls -la "$JG_HOME/state/lead.inbox")"
bash "$ROOT/bin/jg-delivery-tick.sh" "$JG_HOME" >/dev/null 2>&1 || fail 'second delivery tick failed'
[ "$(grep -cF '$wake held text' "$WORK/submitted" || true)" -eq 1 ] || fail 'held wake was submitted twice'
tmux send-keys -t held:jg-lead -l 'a human draft'
sleep 0.3
rc=0
bash "$ROOT/bin/jg-send.sh" lead '$do not submit' >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'a direct send accepted a foreign draft'
bash "$ROOT/bin/jg-send.sh" lead 'another instruction' >/dev/null 2>&1 || fail 'second inbox send failed'
sleep 2
bash "$ROOT/bin/jg-delivery-tick.sh" "$JG_HOME" >/dev/null 2>&1 || fail 'foreign-text delivery tick failed'
! grep -qF 'a human draft' "$WORK/submitted" || fail 'foreign text was submitted'
tmux capture-pane -p -t held:jg-lead | grep -qF 'a human draft' || fail 'foreign text was altered'
tmux send-keys -t held:jg-lead C-u
: > "$WORK/swallow"
rc=0
bash "$ROOT/bin/jg-send.sh" lead '$second wake' >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "second direct send returned $rc"
: > "$WORK/swallow"
: > "$WORK/enters"
sleep 2
bash "$ROOT/bin/jg-delivery-tick.sh" "$JG_HOME" >/dev/null 2>&1 || fail 'retry delivery tick failed'
sleep 2
bash "$ROOT/bin/jg-delivery-tick.sh" "$JG_HOME" >/dev/null 2>&1 || fail 'repeat delivery tick failed'
[ "$(wc -l < "$WORK/enters")" -eq 1 ] || fail 'an unconfirmed recovery was attempted more than once'
tmux send-keys -t held:jg-lead C-u
line=$(bash -c '. "$1/bin/jg-task-inbox-lib.sh"; jg_task_inbox_doorbell_line "$2"' _ "$ROOT" "$JG_HOME/state/lead.inbox/001.msg")
tmux send-keys -t held:jg-lead -l "$line"
sleep 2
: > "$WORK/enters"
bash "$ROOT/bin/jg-delivery-tick.sh" "$JG_HOME" >/dev/null 2>&1 || fail 'unowned doorbell tick failed'
[ ! -s "$WORK/enters" ] || fail 'an unowned copy of the doorbell received Enter'
printf 'ok - direct held wake is submitted once through inbox recovery\n'
