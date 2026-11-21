#!/usr/bin/env bash
# Opt-in live guard for agy (Antigravity CLI) as a juggernaut PRIMARY.
#
# The agy primary integration rests on facts only the real agy can answer: that
# the tracked .agents/hooks.json SessionStart hook runs session start as agy's
# own child, so the session lock names the agy process, and that its
# injectSteps system message carries the digest into model context; that the
# Stop hook's `continue` decision keeps an unsupervised turn going once; and
# that a run_command background task wakes the session with a <SYSTEM_MESSAGE>
# when the watcher arm exits on a real wake. A stub can only confirm the
# assumption already written into the stub, so this drives the installed binary.
#
# tests/jg-turnend-guard.test.sh (the agy registration cases) and
# tests/jg-session-start.test.sh (the agy lock and block cases) are the
# portable regressions; this is the harness-and-credential-gated counterpart.
# Run it after every agy upgrade and before trusting refreshed evidence in
# docs/verification/agy.md:
#
#   JG_AGY_PRIMARY_LIVE_E2E=1 tests/jg-agy-primary-live-e2e.test.sh
#
# It submits real prompts (JG_AGY_PRIMARY_MODEL, default gemini-3.8-flash-high).
# With JG_AGY_PRIMARY_EVIDENCE=<dir> it keeps the pane captures and the
# conversation transcript there.
#
# Isolation: the session start this drives is a real one. The owner rule
# (bin/jg-unit-claim.sh) already refuses a home the machine's units do not serve
# while their owner is live, but a host whose units are absent or name a deleted
# home has no owner to refuse for, and a home the lab-home rule
# (bin/jg-lab-home-lib.sh) does not recognise would then claim them and install
# the stack there. So the throwaway home is a marked lab home (bin/jg-lab-home.sh create) inside a
# jg-test-run.* directory, which the rule recognises with no TMPDIR at all - the
# session runs from an empty environment - and the run refuses to start unless
# that environment's guard refuses the account's unit directory. The stack and
# wiring skips are set as well, the private tmux server lives in the lab home's
# own socket directory, and the run fails if any user unit names the lab after
# it. agy keeps the account's normal HOME with its own sign-in, never a copy.
# Answering agy's folder-trust dialog appends the lab path to agy's
# trustedWorkspaces list, and agy keeps the conversation under
# ~/.gemini/antigravity-cli/brain/; both are keyed to the throwaway run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

jg_live_gate opt-in JG_AGY_PRIMARY_LIVE_E2E agy tmux jq

REAL_TMUX=$(command -v tmux)
AGY_BIN=$(command -v agy || true)
[ -n "$AGY_BIN" ] || fail "agy not found on PATH; this guard refuses to pass without checking the real harness."
AGY_VERSION=$("$AGY_BIN" --version </dev/null 2>/dev/null | head -1)
[ -n "$AGY_VERSION" ] || fail "agy did not report a version; refusing to claim a verified result"
printf 'harness: agy %s\n' "$AGY_VERSION"
MODEL=${JG_AGY_PRIMARY_MODEL:-gemini-3.8-flash-high}
EVIDENCE=${JG_AGY_PRIMARY_EVIDENCE:-}

harness_fail() {  # <message>
  save_evidence
  fail "$1 [harness: agy $AGY_VERSION]"
}

SOCKET="jg-agy-primary-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/jg-test-run.agy-primary.XXXXXX")
HOME_DIR="$LAB/home"
LAB_HOME_HELPER="$ROOT/bin/jg-lab-home.sh"
LAB_TMUX_DIR=''
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
MARKER="JG_AGY_LIVE_MARKER_$$"
START_EPOCH=$(date +%s)

tmux_lab() {
  [ -n "$LAB_TMUX_DIR" ] || return 1
  TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L "$SOCKET" "$@"
}

# The watcher the lab primary armed is this run's own process; stop it by the
# pid its home-scoped lock records, and only when that lock names this home.
stop_lab_watcher() {
  local pid
  [ "$(cat "$HOME_DIR/state/.watch.lock/jg-home" 2>/dev/null)" = "$HOME_DIR" ] || return 0
  pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null)
  case "$pid" in '' | *[!0-9]*) return 0 ;; esac
  kill "$pid" 2>/dev/null || true
  # It records its own exit in state/ as it goes; let it finish before cleanup removes the home.
  local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
}

cleanup_all() {
  tmux_lab send-keys -t primary -l '/quit' >/dev/null 2>&1 || true
  tmux_lab send-keys -t primary Enter >/dev/null 2>&1 || true
  sleep 2
  stop_lab_watcher
  tmux_lab kill-server >/dev/null 2>&1 || true
  [ -z "$LAB_TMUX_DIR" ] || "$LAB_HOME_HELPER" teardown "$HOME_DIR" || true
  [ -n "${LAB:-}" ] || return 0
  rm -rf -- "$LAB" 2>/dev/null || { sleep 2; rm -rf -- "$LAB"; }
}
trap cleanup_all EXIT

pane_text() {
  tmux_lab capture-pane -p -J -t primary -S -400 2>/dev/null
}

transcript() {
  local file
  file=$(grep -l "$MARKER" "$HOME"/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript_full.jsonl 2>/dev/null | head -1)
  [ -n "$file" ] && cat "$file"
}

save_evidence() {
  [ -n "$EVIDENCE" ] || return 0
  mkdir -p "$EVIDENCE"
  pane_text > "$EVIDENCE/agy-primary-pane.txt" 2>/dev/null || true
  transcript > "$EVIDENCE/agy-primary-transcript.jsonl" 2>/dev/null || true
}

wait_for() {  # <seconds> <what> <command...>
  local limit=$1 what=$2 i=0
  shift 2
  while [ "$i" -lt "$((limit * 2))" ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  printf 'pane at failure:\n%s\n' "$(pane_text | tail -40)" >&2
  harness_fail "$what did not happen within ${limit}s"
}

pane_has() { pane_text | grep -qF -- "$1"; }
watcher_live() {
  local pid
  pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null) || return 1
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# Transcript checks read agy's typed steps, never free text alone: the digest
# itself quotes the agy protocol, so a plain grep would match the protocol's own
# words for a wake or a drain that never happened.
transcript_holds() {  # <jq predicate over the step array>
  transcript | jq -se "$1" >/dev/null 2>&1
}
last_step() {
  transcript | jq -s 'map(.step_index) | max // -1' 2>/dev/null || printf '%s\n' -1
}
# A system message agy injected (not the SessionStart one) after step $1 holding $2.
system_after() {  # <step> <text>
  transcript_holds "any(.[]; .source == \"SYSTEM\" and .type == \"SYSTEM_MESSAGE\" and .step_index > $1 and ((.content // \"\") | contains(\"$2\")))"
}
first_system_after() {  # <step> <text>
  transcript | jq -s --argjson n "$1" --arg t "$2" '[.[] | select(.source == "SYSTEM" and .type == "SYSTEM_MESSAGE" and .step_index > $n and ((.content // "") | contains($t))) | .step_index] | min // empty' 2>/dev/null
}
# A model tool call after step $1 whose command holds $2.
command_after() {  # <step> <text>
  transcript_holds "any(.[]; .step_index > $1 and any((.tool_calls // [])[]; ((.args.CommandLine // \"\") | contains(\"$2\"))))"
}
# A tool result after step $1 holding $2.
result_after() {  # <step> <text>
  transcript_holds "any(.[]; .source == \"MODEL\" and .type == \"GENERIC\" and .step_index > $1 and ((.content // \"\") | contains(\"$2\")))"
}

submit() {  # <text>
  tmux_lab send-keys -t primary -l "$1"
  sleep 1
  tmux_lab send-keys -t primary Enter
}

# A plain (non-worktree) copy of the CURRENT working tree, so the guard tests
# the code under review rather than whatever is committed, staged into a marked
# lab home.
"$LAB_HOME_HELPER" create "$HOME_DIR" >/dev/null || harness_fail "could not mint the lab home"
(cd "$ROOT" && tar --exclude=.git --exclude=state --exclude=projects --exclude=node_modules --exclude=data --exclude=config -cf - .) \
  | (cd "$HOME_DIR" && tar -xf -) \
  || harness_fail "could not stage the working tree into the throwaway home"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" add -A >/dev/null 2>&1 || true
git -C "$HOME_DIR" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q -m "live-e2e fixture" >/dev/null 2>&1 || true
[ -f "$HOME_DIR/.agents/hooks.json" ] \
  || harness_fail "the working tree ships no .agents/hooks.json; there is nothing to verify"
# The machine's units belong to Main: without the claim script the lab can never
# claim them, and its watcher never wakes on a unit-claim check, whose wake would
# otherwise stand in for the status wake this run proves.
rm -f -- "$HOME_DIR/bin/jg-unit-claim.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
printf 'off\n' > "$HOME_DIR/config/overwatch-kpi"
printf '# Captain\n\nLive marker: %s\n' "$MARKER" > "$HOME_DIR/data/captain.md"
# One in-flight task, so supervision is genuinely needed from the first turn.
cat > "$HOME_DIR/state/probe.meta" <<EOF
id=probe
project=probe
harness=agy
backend=tmux
window=jg-probe
EOF
printf 'working [at=%s]: fixture lane\n' "$START_EPOCH" > "$HOME_DIR/state/probe.status"

# The session's environment, empty but for these: the account's HOME (agy's own
# sign-in), and the skips that keep a fixture home's session start off the stack
# and the host wiring.
LAB_ENV=(HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" PATH="$PATH"
  LANG="${LANG:-C.UTF-8}" TERM=xterm-256color SHELL=/bin/bash
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" JG_STACK_SKIP=1 JG_HOST_WIRING_SKIP=1)
# Refuse to start a session the lab-home guard would let write the account's
# units: checked in that same environment, so a lost TMPDIR cannot hide it.
# shellcheck disable=SC2016 # expanded by the checking shell
env -i "${LAB_ENV[@]}" bash -c '. "$1/bin/jg-lab-home-lib.sh"; jg_lab_home "$2" >/dev/null && ! jg_lab_home_guard "$2" agy-live "$3" 2>/dev/null' \
  _ "$ROOT" "$HOME_DIR" "$UNIT_DIR" \
  || harness_fail "the lab-home guard does not refuse $UNIT_DIR for $HOME_DIR; refusing to run a session start that could claim the machine's units"
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$HOME_DIR") || harness_fail "could not create the lab home's tmux directory"

# The tmux server and everything under it start from that environment.
env -i "${LAB_ENV[@]}" TMUX_TMPDIR="$LAB_TMUX_DIR" \
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s primary -x 220 -y 60 -c "$HOME_DIR" \
  "cd '$HOME_DIR' && JG_HOME='$HOME_DIR' exec '$AGY_BIN' --model '$MODEL' --dangerously-skip-permissions" \
  || harness_fail "could not start the private tmux server"

# A throwaway path is one agy has never seen, and agy loads a workspace's hooks
# only once it is trusted, so answer the preselected trust choice first.
wait_for 60 "the folder-trust dialog" pane_has "Do you trust the contents of this project?"
tmux_lab send-keys -t primary Enter
wait_for 60 "the idle composer" pane_has "for shortcuts"

# --- 1. run-tier session start and the lock ---------------------------------
submit "Answer only from the context you were given at session start. Do not run any command or tool in this turn. Reply with the exact live marker token you can see, and nothing else."
wait_for 240 "the fleet session lock" test -s "$HOME_DIR/state/.lock"
LOCK_PID=$(head -1 "$HOME_DIR/state/.lock")
PANE_PID=$(tmux_lab display-message -p -t primary '#{pane_pid}')
[ "$LOCK_PID" = "$PANE_PID" ] \
  || harness_fail "the session lock must be owned by the agy process (lock=$LOCK_PID pane=$PANE_PID)"
[ "$(ps -o comm= -p "$LOCK_PID")" = agy ] || harness_fail "the lock owner is not a process named agy"
pass "agy primary: the SessionStart hook takes the fleet lock as the agy process itself"

wait_for 240 "the completed session-start record" test -e "$HOME_DIR/state/.session-start-complete"
pass "agy primary: the run-tier session start completes"

wait_for 240 "the digest naming agy as the SessionStart system message" transcript_holds 'any(.[]; .source == "SYSTEM_SDK" and .type == "SYSTEM_MESSAGE" and ((.content // "") | contains("SUPERVISION OPERATING INSTRUCTIONS - primary harness: agy")))'
wait_for 240 "the live marker quoted back" pane_has "$MARKER"
pass "agy primary: the SessionStart system message carries the digest into model context"

# --- 2. the Stop guard and the first arm -------------------------------------
# The turn was told to run nothing, so the arm that follows the guard's system
# message was made because the Stop hook kept the unsupervised turn going.
wait_for 240 "the Stop guard's continue reason as an agy system message" system_after 0 "TURN WOULD END BLIND"
GUARD_STEP=$(first_system_after 0 "TURN WOULD END BLIND")
wait_for 240 "an arm after the forced continuation" command_after "$GUARD_STEP" "jg-watch-arm.sh"
wait_for 240 "a live watcher" watcher_live
pass "agy primary: the Stop hook holds an unsupervised turn end and the session then arms the watcher"

wait_for 120 "the arm as a background task" result_after "$GUARD_STEP" "running as a background task"
pass "agy primary: the arm runs as a tracked background task"

# --- 3. a real wake ----------------------------------------------------------
APPEND_STEP=$(last_step)
printf 'needs-decision [at=%s]: fixture needs a decision\n' "$(date +%s)" >> "$HOME_DIR/state/probe.status"
# The wake must be the arm's own exit on this status line: a background-task
# message after the append whose output names the status file.
wait_for 300 "a background-task wake naming the status line" system_after "$APPEND_STEP" "probe.status"
WAKE_STEP=$(first_system_after "$APPEND_STEP" "probe.status")
transcript_holds "any(.[]; .step_index == $WAKE_STEP and ((.content // \"\") | contains(\"finished with result\")))" \
  || harness_fail "the status-line wake at step $WAKE_STEP is not a finished background task"
wait_for 300 "the wake drain after the wake" command_after "$WAKE_STEP" "jg-wake-drain.sh"
wait_for 300 "a re-arm after the wake" command_after "$WAKE_STEP" "jg-watch-arm.sh"
wait_for 300 "a live watcher after the re-arm" watcher_live
pass "agy primary: a real status wake ends the arm, wakes the session, and it drains the signal and re-arms"

# --- 4. the tracked Claude hooks stay Claude's ------------------------------
[ ! -e "$HOME_DIR/state/.claude-autoarm-epoch" ] \
  || harness_fail "agy ran the tracked Claude Stop auto-arm; only .agents/hooks.json may run under agy"
pass "agy primary: the tracked .claude/settings.json hooks did not run under agy"

# --- 5. the machine's units stay the account's --------------------------------
if grep -rlsF -- "$LAB" "$UNIT_DIR" >/dev/null 2>&1; then
  harness_fail "a user unit under $UNIT_DIR names the lab $LAB; the lab session start wrote host wiring"
fi
pass "agy primary: no user unit names the lab home"

save_evidence
printf '# jg-agy-primary-live-e2e: all assertions passed (agy %s, %s, %ss)\n' "$AGY_VERSION" "$MODEL" "$(( $(date +%s) - START_EPOCH ))"
