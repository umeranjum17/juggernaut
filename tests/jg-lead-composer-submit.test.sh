#!/usr/bin/env bash
# A lead's composer that holds the same pending text for the set bound is
# submitted once and then the doorbell rings; a composer that keeps changing is
# left alone. Runs through the real caller, bin/jg-delivery-tick.sh.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v tmux >/dev/null || { echo 'skip: tmux unavailable'; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="jg-lead-submit-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jg-lead-submit.XXXXXX")
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf -- "$WORK"; }
trap cleanup EXIT
fail() { printf "not ok - %s\n" "$1" >&2; [ -z "${DEBUG:-}" ] || { cat "$WORK/tick.log"; ls -la "$JG_HOME/state" "$JG_HOME"/state/*.inbox; cat "$JG_HOME"/state/lead.inbox/.composer-seen; tmux capture-pane -p -t lead:jg-lead; }; exit 1; }
mkdir -p "$WORK/bin" "$WORK/home/state" "$WORK/home/config" "$WORK/home/data"
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCKET" > "$WORK/bin/tmux"
chmod +x "$WORK/bin/tmux"
cp "$(command -v bash)" "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH" JG_HOME="$WORK/home" JG_ROOT_OVERRIDE="$WORK/home"
export JG_SEND_RETRIES=1 JG_SEND_SLEEP=0.1 JG_TASK_INBOX_GRACE_SECS=1 JG_TASK_INBOX_COMPOSER_SUBMIT_SECS=3
export JG_KV_URL=nats://127.0.0.1:1 JG_WAKE_BUS_URL=nats://127.0.0.1:1 JG_STATE_BUS_URL=nats://127.0.0.1:1
tick() { bash "$ROOT/bin/jg-delivery-tick.sh" "$JG_HOME" >>"$WORK/tick.log" 2>&1 || fail "delivery tick failed"; }
start_lead() {  # <name> <kind>
  printf 'window=%s:jg-%s\nkind=%s\nharness=claude\n' "$1" "$1" "$2" > "$JG_HOME/state/$1.meta"
  : > "$WORK/$1.submitted"
  tmux new-session -d -s "$1" -n "jg-$1" -x 200 -y 40
  tmux send-keys -t "$1:jg-$1" "exec '$WORK/bin/claude' '$ROOT/tests/fixtures/composer/fake-composer.sh' '$WORK/$1.submitted'" Enter
  sleep 0.5
}

# A lead whose composer keeps the same text: submitted once after the bound, then rung.
start_lead lead squad_lead
tmux send-keys -t lead:jg-lead -l 'unsent lead draft'
sleep 0.3
bash "$ROOT/bin/jg-send.sh" lead 'steer for the lead' >/dev/null 2>&1 || fail 'inbox send failed'
sleep 1.5
tick; tick
! grep -qF 'unsent lead draft' "$WORK/lead.submitted" || fail 'draft was submitted before the bound'
sleep 3.5
tick
[ "$(grep -cF 'unsent lead draft' "$WORK/lead.submitted")" -eq 1 ] || fail "draft not submitted once: $(cat "$WORK/lead.submitted")"
grep -q 'inbox' "$WORK/lead.submitted" || fail "doorbell was not rung after the submit: $(cat "$WORK/lead.submitted")"
tick; sleep 1.5; tick
[ "$(grep -cF 'unsent lead draft' "$WORK/lead.submitted")" -eq 1 ] || fail 'draft was submitted twice'

# A lead whose composer keeps changing is left alone.
start_lead mover squad_lead
tmux send-keys -t mover:jg-mover -l 'x0'
sleep 0.3
bash "$ROOT/bin/jg-send.sh" mover 'steer for the mover' >/dev/null 2>&1 || fail 'mover inbox send failed'
for i in 1 2 3 4 5 6; do
  tmux send-keys -t mover:jg-mover -l "x$i"
  sleep 1.2
  tick
done
grep -q . "$JG_HOME/state/mover.inbox/001.msg" || fail 'mover steer vanished'
[ ! -s "$WORK/mover.submitted" ] || fail "changing composer was submitted: $(cat "$WORK/mover.submitted")"

# A ship worker's draft is never submitted by the watcher.
start_lead ship ship
tmux send-keys -t ship:jg-ship -l 'ship draft'
sleep 0.3
bash "$ROOT/bin/jg-send.sh" ship 'steer for the ship' >/dev/null 2>&1 || fail 'ship inbox send failed'
sleep 1.5; tick; sleep 3.5; tick
! grep -qF 'ship draft' "$WORK/ship.submitted" || fail 'a non-lead draft was submitted'
printf 'ok - unchanged lead composer is submitted once then rung; changing or non-lead composers are left alone\n'
