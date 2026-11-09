#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the mid-turn arm
# (bin/jg-claude-stop-autoarm.sh --mid-turn, registered as an async PostToolUse
# hook in .claude/settings.json).
# Proves, against the real installed Claude Code and the real tracked hook
# registration: a Squad Lead home with work under way and no watcher gets a
# live, identity-matched watcher with a fresh beacon while its first turn is
# still running - before any Stop - with no model-issued arm command, and that
# cycle outlives the hook that started it while the turn runs on. The headless
# session's own exit later ends the arm, so nothing after the turn is checked.
# The lab is a disposable clone that is its own Squad Lead home; Claude keeps
# its existing managed authentication and runs on Haiku. No live fleet home,
# worktree, or session is touched, and the lab's watcher is stopped by its own
# home-scoped stop before the lab is removed.
# shellcheck disable=SC2016 # the model and the lab scripts, not this shell, expand the quoted text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

jg_live_gate opt-in JG_CLAUDE_LIVE_E2E claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/.claude-midturn-live-e2e.$$"
LEAD="$LAB/lead"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)
# How long the probe, run as the turn's second tool call, waits for the cycle,
# and how long it then watches that cycle stay up while the turn runs on.
WINDOW=${JG_MIDTURN_LIVE_WINDOW:-60}
HOLD=${JG_MIDTURN_LIVE_HOLD:-20}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

stop_lab_watcher() {
  [ -x "$LEAD/bin/jg-watch-arm.sh" ] || return 0
  JG_HOME="$LEAD" JG_STATE_OVERRIDE="$LEAD/state" "$LEAD/bin/jg-watch-arm.sh" --stop >/dev/null 2>&1 || true
}

cleanup() {
  if [ -n "${JG_MIDTURN_LIVE_EVIDENCE:-}" ]; then
    mkdir -p "$JG_MIDTURN_LIVE_EVIDENCE"
    for f in "$TRANSCRIPT" "$LEAD/state/midturn-probe.result" "$LEAD/state/tool-calls.log" \
      "$LEAD/state/.watch-cycle-exits.log" "$LEAD/state/.watch-triage.log"; do
      [ -e "$f" ] && cp "$f" "$JG_MIDTURN_LIVE_EVIDENCE/$(basename "$f" | sed 's/^\.//')"
    done
  fi
  stop_lab_watcher
  rm -rf "$LAB"
  jg_test_cleanup
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this checkout carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the auto-arm live E2E).
git clone -q "$ROOT" "$LEAD"
cp -R "$ROOT/bin/." "$LEAD/bin/"
cp "$ROOT/.claude/settings.json" "$LEAD/.claude/settings.json"
jg_test_track_watcher_state "$LEAD/state"

mkdir -p "$LEAD/state" "$LEAD/config" "$LEAD/data"
printf 'sm-live-midturn\n' > "$LEAD/.jg-squad-lead-home"
# The prompt is scripted, not a captain's, so the Overwatch KPI does not count it.
printf 'off\n' > "$LEAD/config/overwatch-kpi"
printf 'kind=ship\n' > "$LEAD/state/lane1.meta"
printf 'working [at=%s]: building\n' "$(date +%s)" > "$LEAD/state/lane1.status"

# The only local hook records model-issued Bash calls without touching the
# session lock or any lifecycle behavior.
cat > "$LEAD/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ]
  }
}
JSON
cat > "$LEAD/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$JG_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
# The probe runs as the turn's second tool call. It waits up to the window for
# the cycle the first call's PostToolUse firing started, then holds for the
# hold time to show that cycle outlives the hook that started it while the
# turn runs on: the same watcher stays healthy and no cycle ends. It records
# what it saw, then ends the lane so the turn's Stop has nothing to supervise.
cat > "$LEAD/bin/midturn-probe.sh" <<'SH'
#!/usr/bin/env bash
. "$JG_HOME/bin/jg-wake-lib.sh"
healthy() { jg_watcher_healthy "$JG_HOME/state" "$JG_HOME/bin/jg-watch.sh" 300 "$JG_HOME"; }
start=$(date +%s)
result=none pid= held=0
while :; do
  if healthy; then
    pid=$JG_WATCHER_HEALTHY_PID
    result="healthy pid=$pid"
    break
  fi
  [ $(( $(date +%s) - start )) -ge "$JG_MIDTURN_LIVE_WINDOW" ] && break
  sleep 1
done
waited=$(( $(date +%s) - start ))
if [ -n "$pid" ]; then
  while [ "$held" -lt "$JG_MIDTURN_LIVE_HOLD" ]; do
    sleep 1
    held=$((held + 1))
    if ! healthy || [ "$JG_WATCHER_HEALTHY_PID" != "$pid" ] \
      || grep -q 'origin=started' "$JG_HOME/state/.watch-cycle-exits.log" 2>/dev/null; then
      result="lost pid=$pid"
      break
    fi
  done
fi
printf '%s waited=%ss held=%ss epoch=%s\n' "$result" "$waited" "$held" \
  "$([ -e "$JG_HOME/state/.claude-autoarm-epoch" ] && echo present || echo absent)" \
  > "$JG_HOME/state/midturn-probe.result"
rm -f "$JG_HOME/state/lane1.meta" "$JG_HOME/state/lane1.status"
echo PROBED
SH
chmod +x "$LEAD/bin/tool-logger.sh" "$LEAD/bin/midturn-probe.sh"

PROMPT='Run exactly `true` with Bash. Then run exactly `bin/midturn-probe.sh` with Bash and wait for it to finish. Then reply with exactly DONE and stop. Never run bin/jg-watch-arm.sh or any other command, and never use any other tool.'

(
  cd "$LEAD" || exit 1
  JG_HOME="$LEAD" JG_MIDTURN_LIVE_WINDOW="$WINDOW" JG_MIDTURN_LIVE_HOLD="$HOLD" JG_SIGNAL_GRACE=0 JG_HEARTBEAT=999999 JG_POLL=1 \
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p "$PROMPT" --model claude-haiku-5-5 --dangerously-skip-permissions \
    --settings '{"feedbackDrafts":"off"}' --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude $CLAUDE_VERSION mid-turn session failed: $(tail -20 "$TRANSCRIPT")"

[ -s "$LEAD/state/midturn-probe.result" ] \
  || fail "Claude $CLAUDE_VERSION: the probe never ran: $(cat "$LEAD/state/tool-calls.log" 2>/dev/null)"
RESULT=$(cat "$LEAD/state/midturn-probe.result")
case "$RESULT" in
  'healthy pid='*" held=${HOLD}s epoch=absent") ;;
  'healthy pid='*) fail "Claude $CLAUDE_VERSION: the mid-turn cycle came from a Stop generation: $RESULT" ;;
  'lost pid='*) fail "Claude $CLAUDE_VERSION: the mid-turn cycle did not outlive its hook while the turn ran on: $RESULT; cycle exits: $(cat "$LEAD/state/.watch-cycle-exits.log" 2>/dev/null)" ;;
  *) fail "Claude $CLAUDE_VERSION: a lead with work under way had no live cycle mid-turn within ${WINDOW}s: $RESULT; triage: $(tail -n 3 "$LEAD/state/.watch-triage.log" 2>/dev/null)" ;;
esac
[ -s "$LEAD/state/tool-calls.log" ] || fail "Claude $CLAUDE_VERSION emitted no logged Bash tool calls"
! grep -q 'jg-watch-arm.sh' "$LEAD/state/tool-calls.log" \
  || fail "the model issued an arm command: $(cat "$LEAD/state/tool-calls.log")"

printf 'ok - Claude %s live E2E: a Squad Lead with work under way got a live cycle mid-turn (%s) with no Stop and no model-issued arm command\n' \
  "$CLAUDE_VERSION" "$RESULT"
