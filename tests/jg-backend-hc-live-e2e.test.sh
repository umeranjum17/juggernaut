#!/usr/bin/env bash
# Default-on live journey for the hc (Herdr Core) backend's core primitives and
# its isolated lab helper, against a real Herdr Core.
#
# Every hc call runs through bin/jg-hc-lab.sh in one named, never-default lab
# session whose sockets and state sit under a disposable root, so the fleet's
# own Herdr Core is never reached. The journey submits no prompt and spends no
# model tokens, so the shared live gate runs it wherever hc is installed.
# The alive verdict uses a real Claude Code with no login in the lab HOME; it
# is reported as skipped when claude is not installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/bin/jg-hc-lab.sh"

# Under `done-done run`, every result line also goes to the run's own log.
EVIDENCE_LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/hc-backend-e2e.log}
say() {  # <stream 1|2> <line>
  if [ "$1" = 2 ]; then printf '%s\n' "$2" >&2; else printf '%s\n' "$2"; fi
  [ -z "$EVIDENCE_LOG" ] || printf '%s\n' "$2" >> "$EVIDENCE_LOG"
}
fail() { say 2 "not ok - $1"; exit 1; }
pass() { say 1 "ok - $1"; }

jg_live_gate default-on JG_HC_BACKEND_LIVE_E2E hc jq python3

REAL_HC=$(command -v hc)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/jg-hc-e2e.XXXXXX") || fail 'cannot create a scratch directory'
export JG_HC_LAB_STATE_DIR="$TMP_ROOT/lab-state"
SESSION=$("$LAB" name hc-backend-e2e)
FLEET_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$UID}/herdr-core/default.sock"
fleet_state() { if [ -e "$FLEET_SOCKET" ]; then stat -c '%i' "$FLEET_SOCKET" 2>/dev/null || stat -f '%i' "$FLEET_SOCKET"; else echo absent; fi; }
FLEET_BEFORE=$(fleet_state)
TORN_DOWN=0
cleanup() {
  [ "$TORN_DOWN" = 1 ] || "$LAB" teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

refused() {  # <expected text> <lab arguments...>
  local want=$1 out
  shift
  if out=$("$LAB" "$@" 2>&1); then
    fail "lab helper accepted: $*"
  fi
  case "$out" in *"$want"*) ;; *) fail "lab helper refused '$*' without naming '$want': $out" ;; esac
}

# --- the lab helper's own guards -----------------------------------------------

case "$SESSION" in jg-hclab-hc-backend-e2e-*) ;; *) fail "unexpected lab name: $SESSION" ;; esac
refused "refusing session name 'default'" provision default
refused "must start with 'jg-hclab-'" provision jg-lab-herdr-style
refused "not provisioned" run "$SESSION" ls
chmod 755 "$JG_HC_LAB_STATE_DIR"
refused "mode 700" provision "$SESSION"
chmod 700 "$JG_HC_LAB_STATE_DIR"
pass 'lab helper refuses default, foreign and unprovisioned sessions and a public state directory'

# Provision with SIGINT ignored, as a background job runs: the core and its
# programs must still get default signals, which the C-c step below proves.
( trap '' INT; exec "$LAB" provision "$SESSION" ) || fail 'could not provision the hc lab'
LAB_ROOT=$(cat "$JG_HC_LAB_STATE_DIR/$SESSION.root")
[ -S "$LAB_ROOT/run/herdr-core/$SESSION.sock" ] || fail 'the lab core does not listen inside its own root'
[ "$(stat -c '%a' "$LAB_ROOT" 2>/dev/null || stat -f '%Lp' "$LAB_ROOT")" = 700 ] || fail 'the lab root is not private'
for sub in server update machine connect; do
  refused "refusing '$sub' through run" run "$SESSION" "$sub" status
done
refused 'leading option' run "$SESSION" --json ls
"$LAB" provision "$SESSION" || fail 'provisioning twice must converge'
# shellcheck disable=SC2016 # Expanded by the lab terminal's own shell.
ANTHROPIC_API_KEY=should-not-leak "$LAB" run "$SESSION" run --bg --json -- sh -c 'printf "%s\n" "$HOME" "$XDG_RUNTIME_DIR" "${ANTHROPIC_API_KEY-unset}" > "$HOME/env.txt"; sleep 30' >/dev/null \
  || fail 'could not start an environment probe'
attempt=0
while [ ! -s "$LAB_ROOT/home/env.txt" ] && [ "$attempt" -lt 50 ]; do sleep 0.1; attempt=$((attempt + 1)); done
printf '%s\n' "$LAB_ROOT/home" "$LAB_ROOT/run" unset > "$TMP_ROOT/env.expected"
cmp -s "$LAB_ROOT/home/env.txt" "$TMP_ROOT/env.expected" \
  || fail "lab terminals do not run with the disposable HOME and runtime dir: $(cat "$LAB_ROOT/home/env.txt" 2>/dev/null)"
pass 'lab core listens only inside its private root, refuses core and machine commands, and isolates HOME'

# --- the backend, with every hc call routed through the lab ---------------------

FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/hc" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${HC_SESSION:-}|\$*" >> "$TMP_ROOT/hc-calls.log"
[ "\${1:-}" != --version ] || exec "$REAL_HC" --version
[ "\${HC_SESSION:-}" = "$SESSION" ] || { echo "shim: refusing session '\${HC_SESSION:-}'" >&2; exit 9; }
JG_HC_LAB_BIN="$REAL_HC" exec "$LAB" run "$SESSION" "\$@"
SH
chmod +x "$FAKEBIN/hc"
cat > "$FAKEBIN/hc-old" <<'SH'
#!/usr/bin/env bash
echo 'hc 0.1.17'
SH
chmod +x "$FAKEBIN/hc-old"

# shellcheck disable=SC2016 # The child bash expands its own arguments.
backend() {  # <function> <arguments...>
  env PATH="$FAKEBIN:$PATH" XDG_RUNTIME_DIR="$LAB_ROOT/run" JG_HOME="$TMP_ROOT/home" \
    bash -c '. "$1/bin/jg-backend.sh" && jg_backend_source hc || exit 97; shift; "$@"' _ "$ROOT" "$@"
}
# shellcheck disable=SC2016 # The child bash expands its own arguments.
dispatch() {  # <jg_backend_* dispatcher> <arguments...>
  env PATH="$FAKEBIN:$PATH" XDG_RUNTIME_DIR="$LAB_ROOT/run" JG_HOME="$TMP_ROOT/home" \
    bash -c '. "$1/bin/jg-backend.sh" || exit 97; shift; "$@"' _ "$ROOT" "$@"
}
wait_state() {  # <target> <state> -> polls jg_backend_agent_state
  local i=0 got
  while [ "$i" -lt 60 ]; do
    got=$(dispatch jg_backend_agent_state hc "$1")
    [ "$got" = "$2" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  printf '# foreground: %s\n' "$("$LAB" run "$SESSION" get --json "${1#*:}" 2>&1 | jq -c '.foreground' 2>&1)" >&2
  printf '# screen tail:\n%s\n' "$(dispatch jg_backend_capture hc "$1" 8 2>&1)" >&2
  fail "agent state of $1 stayed '$got', expected '$2'"
}

dispatch jg_backend_validate hc || fail 'hc must be a known backend'
out=$(dispatch jg_backend_validate_spawn hc 2>&1) && fail 'hc must not be spawn-capable before its verify plan lands'
case "$out" in *"does not support task spawning"*) ;; *) fail "spawn refusal did not name the reason: $out" ;; esac
[ "$(dispatch jg_backend_required_tools hc)" = 'hc jq treehouse python3' ] || fail 'hc tool set changed'
backend jg_backend_hc_tool_check || fail 'tool check refused the real hc'
out=$(JG_BACKEND_HC_BIN=hc-old backend jg_backend_hc_tool_check 2>&1) && fail 'tool check accepted hc 0.1.17'
case "$out" in *'older than the tested 0.1.18'*) ;; *) fail "old-version refusal unclear: $out" ;; esac
pass 'hc is known but not spawn-capable, and the tool check enforces the tested version floor'

# A session with no core: nothing is proven and no core is started.
NONE=jg-hclab-not-running
: > "$TMP_ROOT/hc-calls.log"
[ "$(dispatch jg_backend_target_absent hc "$NONE:t1")" = uncertain ] || fail 'no core must read uncertain, never absent'
[ "$(dispatch jg_backend_agent_state hc "$NONE:t1")" = unreadable ] || fail 'no core must read unreadable'
dispatch jg_backend_target_exists hc "$NONE:t1" && fail 'no core must not read as existing'
dispatch jg_backend_kill hc "$NONE:t1" 2>/dev/null && fail 'kill with no core must refuse, not report closed'
[ ! -e "$LAB_ROOT/run/herdr-core/$NONE.sock" ] || fail 'a read started a core'
! grep -v -- '|--version$' "$TMP_ROOT/hc-calls.log" || fail 'reads called hc beyond --version with no core listening'
pass 'with no core listening, reads prove nothing, send hc no command, and start no core'

TARGET=$(backend jg_backend_hc_create_task "$SESSION" Task.One_1 "$TMP_ROOT" bash --noprofile --norc) \
  || fail 'create_task failed'
case "$TARGET" in "$SESSION":t[0-9]*) ;; *) fail "unexpected target: $TARGET" ;; esac
[ "$("$LAB" run "$SESSION" get --json "${TARGET#*:}" | jq -r '.labels["jg.task"]')" = Task.One_1 ] \
  || fail 'the task label was not recorded'
dispatch jg_backend_target_exists hc "$TARGET" || fail 'a live terminal must exist'
[ "$(dispatch jg_backend_target_absent hc "$TARGET")" = present ] || fail 'a live terminal must read present'
wait_state "$TARGET" dead
dispatch jg_backend_agent_exited hc "$TARGET" || fail 'a bare shell must read as exited'
pass "create_task starts a labelled terminal ($TARGET), and a bare shell reads dead"

verdict=$(dispatch jg_backend_send_text_submit hc "$TARGET" "printf 'hc-%s\\n' delivered" 3 0.3 0.5) \
  || fail 'send_text_submit failed'
case "$verdict" in send-failed|missing|dead|'') fail "send verdict: '$verdict'" ;; esac
sleep 0.5
dispatch jg_backend_capture hc "$TARGET" 40 | grep -qx 'hc-delivered' || fail 'the sent text did not run'
pass "send_text_submit delivers once and reports '$verdict'"

dispatch jg_backend_send_text_submit hc "$TARGET" 'seq 1 400' 1 0.3 0.5 >/dev/null || fail 'seq send failed'
sleep 1
dispatch jg_backend_capture hc "$TARGET" 500 | grep -qx 5 || fail 'capture with history lost early lines'
visible=$(dispatch jg_backend_visible_capture hc "$TARGET") || fail 'visible capture failed'
printf '%s\n' "$visible" | grep -qx 400 || fail 'visible capture lacks the last line'
printf '%s\n' "$visible" | grep -qx 5 && fail 'visible capture returned history'
[ "$(dispatch jg_backend_capture hc "$TARGET" 3 | wc -l)" -le 3 ] || fail 'capture ignored its line bound'
pass 'capture reads bounded history, visible capture reads the screen only'

dispatch jg_backend_send_text_submit hc "$TARGET" 'sleep 300' 1 0.3 0.5 >/dev/null || fail 'sleep send failed'
wait_state "$TARGET" ambiguous
dispatch jg_backend_send_key hc "$TARGET" C-c || fail 'C-c was not delivered'
wait_state "$TARGET" dead
for key in Escape Enter C-u; do
  dispatch jg_backend_send_key hc "$TARGET" "$key" || fail "$key was not delivered"
done
pass 'a non-agent program reads ambiguous, C-c stops it although the core was started with SIGINT ignored, and Escape, Enter and C-u are delivered'

if command -v claude >/dev/null 2>&1; then
  AGENT=$(backend jg_backend_hc_create_task "$SESSION" claude-probe "$TMP_ROOT" claude --model claude-haiku-5-5) \
    || fail 'could not start claude in the lab'
  wait_state "$AGENT" alive
  dispatch jg_backend_kill hc "$AGENT" || fail 'could not end the claude probe'
  pass "a real Claude Code ($(claude --version 2>/dev/null | head -n 1)) reads alive"
else
  say 1 'skip: alive verdict: claude absent'
fi

FINISHED=$(backend jg_backend_hc_create_task "$SESSION" finished "$TMP_ROOT" true) || fail 'could not start true'
wait_state "$FINISHED" dead
dispatch jg_backend_target_exists hc "$FINISHED" && fail 'a finished terminal must not read as existing'
[ "$(dispatch jg_backend_target_absent hc "$FINISHED")" = present ] || fail 'a finished terminal is still present'
[ "$(dispatch jg_backend_send_text_submit hc "$FINISHED" x 1 0.1 0.1)" = dead ] || fail 'send to a finished terminal must read dead'
dispatch jg_backend_kill hc "$FINISHED" || fail 'kill of a finished terminal failed'
[ "$(dispatch jg_backend_target_absent hc "$FINISHED")" = absent ] || fail 'a removed terminal must read absent'
pass 'a finished terminal reads dead and present, and kill removes it'

dispatch jg_backend_kill hc "$TARGET" || fail 'kill failed'
[ "$(dispatch jg_backend_target_absent hc "$TARGET")" = absent ] || fail 'a killed terminal must read absent'
[ "$(dispatch jg_backend_agent_state hc "$TARGET")" = missing ] || fail 'a killed terminal must read missing'
dispatch jg_backend_kill hc "$TARGET" || fail 'a second kill must succeed quietly'
[ "$(dispatch jg_backend_send_text_submit hc "$TARGET" x 1 0.1 0.1)" = missing ] || fail 'send to a removed terminal must read missing'
pass 'kill ends and removes the terminal; a gone terminal reads absent and missing'

# --- endpoint records ---------------------------------------------------------

meta() {  # <file> <lines...>
  local file=$1
  shift
  printf '%s\n' project=juggernaut "worktree=$TMP_ROOT/wt" backend=hc "$@" > "$file"
}
M="$TMP_ROOT/t1.meta"
meta "$M" endpoint_task_id=t1 "hc_session=$SESSION" hc_terminal=t4 "window=$SESSION:t4"
bash -c '. "$1/bin/jg-backend.sh" && jg_backend_validate_task_endpoint "$2" t1 && printf "%s\n" "$JG_BACKEND_VALIDATED_TARGET"' _ "$ROOT" "$M" \
  | grep -qx "$SESSION:t4" || fail 'a well-formed hc record was refused'
meta "$M" endpoint_task_id=t1 "hc_session=$SESSION" hc_terminal=t4 "window=$SESSION:t5"
dispatch jg_backend_validate_task_endpoint "$M" t1 2>/dev/null && fail 'a window that disagrees with hc_terminal was accepted'
meta "$M" "hc_session=$SESSION" hc_terminal=t4 "window=$SESSION:t4"
dispatch jg_backend_validate_task_endpoint "$M" t1 2>/dev/null && fail 'a record with no task binding was accepted'
meta "$M" endpoint_task_id=t1 "hc_session=$SESSION" hc_terminal=box/t4 "window=$SESSION:box/t4"
dispatch jg_backend_validate_task_endpoint "$M" t1 2>/dev/null && fail 'a remote address was accepted'
pass 'hc endpoint records are validated by task binding, session and terminal'

# --- teardown -----------------------------------------------------------------

"$LAB" teardown "$SESSION" || fail 'lab teardown failed'
TORN_DOWN=1
[ ! -e "$LAB_ROOT" ] || fail 'teardown left the lab root'
[ -z "$(ls -A "$JG_HC_LAB_STATE_DIR")" ] || fail "teardown left lab records: $(ls -A "$JG_HC_LAB_STATE_DIR")"
[ "$(fleet_state)" = "$FLEET_BEFORE" ] || fail 'the fleet Herdr Core socket changed during the journey'
pass "teardown removes the lab and leaves the fleet Herdr Core as it was ($FLEET_BEFORE)"

if [ -n "$EVIDENCE_LOG" ]; then
  jq -n --arg version "$("$REAL_HC" --version)" --arg commit "$(git -C "$ROOT" rev-parse HEAD)" \
    --rawfile log "$EVIDENCE_LOG" '{
      target: {version: $version, commit: $commit},
      start: "no hc lab; the default Herdr Core socket state recorded",
      steps: ($log | split("\n") | map(select(length > 0))),
      result: "every hc primitive and lab guard held against a real Herdr Core, and the lab was removed"
    }' > "$DONE_DONE_EVIDENCE_ROOT/steps.json" || fail 'could not write the step record'
fi
