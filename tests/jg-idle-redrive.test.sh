#!/usr/bin/env bash
# Run the real delivery tick against a private tmux server and task records.
set -euo pipefail
if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  exec > "$DONE_DONE_EVIDENCE_ROOT/idle-worker-redrive.log" 2>&1
fi
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tmux >/dev/null || { echo 'skip: tmux unavailable'; exit 0; }
W=$(jg_test_tmproot jg-idle-redrive)
REAL_TMUX=$(command -v tmux)
SOCKET=jg-idle-redrive-$$
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true; jg_test_cleanup; }
trap cleanup EXIT
H=$W/home S=$W/home/state
mkdir -p "$H/bin" "$H/config" "$H/data" "$S" "$W/bin" "$W/copy"
export HOME=$W PATH="$W/bin:$PATH" JG_ROOT_OVERRIDE=$H
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCKET" > "$W/bin/tmux"
chmod +x "$W/bin/tmux"
cp "$(command -v bash)" "$W/bin/claude"
tmux new-session -d -s lanes -n jg-worker -x 160 -y 30
tmux send-keys -t lanes:jg-worker "'$W/bin/claude' '$ROOT/tests/fixtures/composer/fake-composer.sh' '$W/submitted'" Enter
printf 'kind=ship\nwindow=lanes:jg-worker\nharness=claude\nworktree=%s\nproject=%s\nspawn_gen=worker-gen\n' "$W/copy" "$W/copy" > "$S/worker.meta"
event() { bash "$ROOT/bin/jg-busy-event.sh" apply "$S" worker "$1" --current-gen --source claude-hook --event "$2"; }
bash "$ROOT/bin/jg-busy-event.sh" arm "$S" worker >/dev/null
event idle Stop
tick() { bash "$ROOT/bin/jg-delivery-tick.sh" "$H" >> "$W/tick.log" 2>&1 || fail "delivery tick failed: $(tail -n 5 "$W/tick.log")"; }
for _ in {1..40}; do
  tmux capture-pane -pt lanes:jg-worker | grep -q 'for shortcuts' && break
  sleep 0.05
done
tmux capture-pane -pt lanes:jg-worker | grep -q 'for shortcuts' || fail 'fixture prompt never appeared'
for closing in 'done: ready' 'blocked: dependency' 'needs-decision: pick one' 'failed: launch error'; do
  printf '%s\n' "$closing" > "$S/worker.status"
  tick
  [ ! -d "$S/worker.inbox" ] || fail "a closing line got a steer: $closing"
done
printf '%s\n' 'paused [wait=outside] [reason=dependency] [key=waiting]: waiting' \
  'resolved [key=unrelated]: another decision closed' > "$S/worker.status"
tick
[ ! -d "$S/worker.inbox" ] || fail 'an unrelated resolution cleared a declared wait'
pass 'terminal statuses and a standing declared wait got no recovery'

printf 'working [at=1]: unfinished change\n' > "$S/worker.status"
printf 'uncommitted work\n' > "$W/copy/change"
event busy UserPromptSubmit
tick
[ ! -d "$S/worker.inbox" ] || fail 'a busy turn got a steer'
event idle Stop
tmux send-keys -t lanes:jg-worker -l 'foreign draft'
tick
[ ! -d "$S/worker.inbox" ] || fail 'a foreign draft got a steer'
tmux capture-pane -pt lanes:jg-worker | grep -q 'foreign draft' || fail 'foreign draft was altered'
tmux send-keys -t lanes:jg-worker C-u
pass 'a busy turn and a prompt with unsent text got no recovery'

idle_at=$(date +%s)
tick
[ -f "$S/worker.inbox/001.msg" ] || fail "idle worker with no closing line had no durable steer after one tick: $(tail -n 5 "$W/tick.log") $(cat "$S/worker.idle-redrive.steer" 2>/dev/null || true)"
[ "$(( $(date +%s) - idle_at ))" -lt 120 ] || fail 'the idle worker was not steered within two minutes'
grep -qi 'continue' "$S/worker.inbox/001.msg" || fail 'steer did not tell the worker to continue'
grep -q 'instruction' "$W/submitted" || fail 'the idle prompt did not receive its doorbell'
pass 'one delivery tick queued a durable steer for an idle worker without a closing line'

mv "$S/worker.inbox/001.msg" "$S/worker.inbox/handled/"
tick
[ ! -e "$S/worker.inbox/002.msg" ] || fail 'the next tick queued a second steer'
touch -t 200001010000 "$S/worker.idle-redrive.steer"
tick
tick
[ "$(grep -c '^blocked .*\[key=idle-redrive\]' "$S/worker.status")" = 1 ] || fail 'the exhausted idle worker did not get exactly one blocker'
pass 'an idle worker that still owed a closing line received one blocker'

if JG_HOME=$H JG_STATE_OVERRIDE=$S JG_CONTROL_EXPECT_EXITED_GEN=worker-gen \
  bash "$ROOT/bin/jg-control.sh" worker relaunch --note recovery > "$W/control.err" 2>&1; then
  fail 'automatic relaunch accepted a live agent'
fi
grep -q 'agent is not known to have exited' "$W/control.err" || fail "wrong relaunch refusal: $(cat "$W/control.err")"
tmux capture-pane -pt lanes:jg-worker | grep -q 'for shortcuts' || fail 'the live agent was altered'

# Stop the fixture's own fake agent, leaving its real tmux shell in place.
# The home control shim records the requested contract without starting an agent.
tmux send-keys -t lanes:jg-worker C-x
cat > "$H/bin/jg-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s %s\n' "$1" "$2" "$JG_CONTROL_EXPECT_EXITED_GEN" >> "$JG_STATE_OVERRIDE/control.log"
echo 'error: fixture relaunch refused' >&2
exit 1
SH
printf 'resolved [key=idle-redrive]: test resumed\nworking: unfinished change\n' >> "$S/worker.status"
for _ in {1..40}; do
  [ "$(tmux display-message -pt lanes:jg-worker '#{pane_current_command}')" != claude ] && break
  sleep 0.05
done
tick
for _ in {1..40}; do
  [ -s "$S/control.log" ] && break
  sleep 0.05
done
[ "$(cat "$S/control.log")" = 'worker relaunch worker-gen' ] || fail 'the exited worker did not get its guarded relaunch'
touch -t 200001010000 "$S/worker.idle-redrive.relaunch"
tick
tick
[ "$(wc -l < "$S/control.log")" = 1 ] || fail 'the exited agent was relaunched more than once'
grep -q '^blocked .*fixture relaunch refused' "$S/worker.status" || fail 'the blocker omitted the control refusal'
[ "$(cat "$W/copy/change")" = 'uncommitted work' ] && [ -f "$S/worker.meta" ] || fail 'recovery discarded the worker or its work'
pass 'an exited worker got one guarded relaunch and retained its local changes after a refusal'
