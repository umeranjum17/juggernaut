#!/usr/bin/env bash
# tests/jg-sentinel-restart-resume.test.sh - real-Herdr journey for the restart
# resume in bin/jg-sentinel.sh reconcile, token-free.
#
# Five lanes sit on panes of a named lab Herdr session. The lab server is
# restarted, which kills every pane process as a host session loss does, and a
# stand-in agent (a process named claude that reports its own Herdr state) comes
# back in each pane the way Herdr resumes a session. Then reconcile runs and the
# steering inboxes must show exactly one resume nudge for the lane whose turn
# was lost, none for the mid-turn lane, none for the lanes properly waiting, and
# none for the lane that already acted after the restart. Repeat passes and a
# second restart must not nudge again while the lane's state is unchanged.
# Every Herdr call goes through bin/jg-herdr-lab.sh; the default session is
# never touched. Set JG_SENTINEL_RESUME_EVIDENCE=<dir> to keep the outputs.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u

# The Juggernaut checkout named by JG_UPSTREAM_ROOT supplies tests/lib.sh (fail, pass, ROOT) and the
# upstream bin/ scripts; the sentinel under test is this feature's copy.
[ -n "${JG_UPSTREAM_ROOT:-}" ] || { echo "skip: set JG_UPSTREAM_ROOT to a Juggernaut checkout"; exit 0; }
SENTINEL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/jg-sentinel.sh"
# shellcheck source=/dev/null
. "$JG_UPSTREAM_ROOT/tests/lib.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }

jg_live_gate default-on JG_SENTINEL_RESUME_E2E herdr jq git

HELPER=$ROOT/bin/jg-herdr-lab.sh
EVID=${JG_SENTINEL_RESUME_EVIDENCE:-}
REAL_PATH=$PATH
LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/jg-resume.XXXXXX")
S=$("$HELPER" name jg-restart-resume)
HOME_DIR=$LAB/home
LANES='lost midturn paused decision acted'
READY=0

cleanup() {
  local status=$?
  [ -z "$EVID" ] || cp "$HOME_DIR/state/.sentinel.log" "$EVID/sentinel.log" 2>/dev/null || true
  [ "$READY" -eq 0 ] || "$HELPER" teardown "$S" >/dev/null || status=1
  rm -rf "$LAB"
  exit "$status"
}
trap cleanup EXIT

# Adapter calls append `--session <lab>`; this shim strips that, refuses any
# other session, and hands the call to the guarded helper with the real PATH.
mkdir -p "$LAB/bin"
cat > "$LAB/bin/herdr" <<SH
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n - 2))]}" = --session ] && [ "\${args[\$((n - 1))]}" = '$S' ]; then
  unset "args[\$((n - 1))]" "args[\$((n - 2))]"
fi
for a in "\${args[@]}"; do case "\$a" in --session|--session=*) exit 9 ;; esac; done
PATH='$REAL_PATH' exec '$HELPER' run '$S' "\${args[@]}"
SH
chmod +x "$LAB/bin/herdr"
lab() { PATH="$REAL_PATH" "$HELPER" run "$S" "$@"; }

JG_HOME=$("$ROOT/bin/jg-lab-home.sh" create "$HOME_DIR") || fail "could not create the lab home"
# The lab home is state-only; the sentinel runs the host tool's scripts from JG_HOME/bin.
ln -s "$ROOT/bin" "$JG_HOME/bin"
STATE=$JG_HOME/state
READY=1
PATH="$REAL_PATH" "$HELPER" provision "$S" >/dev/null || fail "could not provision the lab session"

before=$(( $(date +%s) - 600 ))
n=0
for id in $LANES; do
  n=$((n + 1))
  git init -q "$LAB/wt-$id" || fail "worktree for $id"
  lab workspace create --cwd "$LAB/wt-$id" --label "jg-$id" >/dev/null || fail "workspace for $id"
  cat > "$STATE/$id.meta" <<EOF
window=$S:w$n:p1
endpoint_task_id=$id
worktree=$LAB/wt-$id
project=$LAB/wt-$id
harness=claude
kind=scout
spawn_gen=s$before.1.1
backend=herdr
herdr_session=$S
herdr_workspace_id=w$n
herdr_tab_id=w$n:t1
herdr_pane_id=w$n:p1
EOF
  printf 'g%s.1.1\n' "$before" > "$STATE/$id.busy-gen"
  printf 'v1 gen=g%s.1.1 seq=2 state=busy source=claude-hook event=user-prompt-submit ts=%s\n' \
    "$before" "$((before + 60))" > "$STATE/$id.busy-state"
  printf 'working [at=%s]: implementing the brief\n' "$((before + 30))" > "$STATE/$id.status"
done
printf 'paused [at=%s]: waiting on the validation run; resumes at its next gate\n' "$((before + 90))" >> "$STATE/paused.status"
printf 'needs-decision [at=%s] [key=pick]: two options for the schema\n' "$((before + 90))" >> "$STATE/decision.status"

# The restart: every pane process dies, then each agent comes back idle in its
# pane, except the mid-turn one, which reports working.
restart() {
  PATH="$REAL_PATH" "$HELPER" stop "$S" >/dev/null || fail "could not stop the lab server"
  sleep 1
  PATH="$REAL_PATH" "$HELPER" provision "$S" >/dev/null || fail "could not restart the lab server"
  local i=0 lane state
  for lane in $LANES; do
    i=$((i + 1))
    lab pane run "w$i:p1" "cd '$LAB/wt-$lane' && exec -a claude sleep 900" >/dev/null || fail "agent back in $lane"
    state=idle
    [ "$lane" != midturn ] || state=working
    sleep 0.5
    lab pane report-agent "w$i:p1" --source jg-resume-test --agent claude --state "$state" >/dev/null \
      || fail "report $state for $lane"
  done
}
reconcile() {
  PATH="$LAB/bin:$REAL_PATH" JG_HOME="$JG_HOME" JG_SENTINEL_HERDR_SESSION="$S" \
    "$SENTINEL" reconcile
}
nudges() { find "$STATE/$1.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
expect_nudges() {  # <pass-label>
  local lane want got
  for lane in $LANES; do
    want=0
    [ "$lane" != lost ] || want=1
    got=$(nudges "$lane")
    [ "$got" = "$want" ] || fail "$1: lane $lane holds $got nudges, expected $want"
  done
}

restart
# The acted lane posted a busy event after the restart, as a relaunched or
# already-resumed lane does.
sed -i.bak "s/ ts=[0-9]*$/ ts=$(date +%s)/" "$STATE/acted.busy-state" && rm -f "$STATE/acted.busy-state.bak"
OUT=$(reconcile) || fail "reconcile failed: $OUT"
[ -z "$EVID" ] || printf '%s\n' "$OUT" > "$EVID/pass1.txt"
expect_nudges "first pass"
grep -q 'turn was lost' "$STATE"/lost.inbox/*.msg || fail "the nudge does not say the turn was lost"
grep -q 'not new work' "$STATE"/lost.inbox/*.msg || fail "the nudge does not keep the brief unchanged"
printf '%s\n' "$OUT" | grep -q '^midturn: mid-turn; left alone' || fail "mid-turn lane not recognized: $OUT"
printf '%s\n' "$OUT" | grep -q '^paused: properly waiting' || fail "paused lane not recognized: $OUT"
printf '%s\n' "$OUT" | grep -q '^decision: properly waiting' || fail "open decision not recognized: $OUT"
printf '%s\n' "$OUT" | grep -q '^acted: acted since the restart' || fail "acted lane not recognized: $OUT"
pass "one restart: one resume nudge for the lost turn, none for mid-turn, waiting, or acted lanes"

OUT=$(reconcile) || fail "second reconcile failed: $OUT"
[ -z "$EVID" ] || printf '%s\n' "$OUT" > "$EVID/pass2.txt"
expect_nudges "repeat pass"
printf '%s\n' "$OUT" | grep -q '^herdr episode .* already reconciled; nothing to do$' || fail "repeat pass did not skip the reconciled episode: $OUT"
pass "a repeat pass after the same restart nudges nothing new"

restart
sed -i.bak "s/ ts=[0-9]*$/ ts=$(date +%s)/" "$STATE/acted.busy-state" && rm -f "$STATE/acted.busy-state.bak"
OUT=$(reconcile) || fail "third reconcile failed: $OUT"
[ -z "$EVID" ] || { printf '%s\n' "$OUT" > "$EVID/pass3.txt"; cp -r "$STATE"/*.inbox "$EVID/" 2>/dev/null; }
expect_nudges "second restart"
pass "a second restart nudges nothing new while the lane's state is unchanged"
