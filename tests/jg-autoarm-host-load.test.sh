#!/usr/bin/env bash
# Supervision under host load (ticket jg8-autoarm-host-load). Three promises, each driven through its real caller:
#   1. The Stop auto-arm claims a home whose arming claim has no beat past the claim bound, even while the
#      load-stretched guard grace (600 s at a load of twice the CPU count) still reads it as fresh.
#   2. The watcher beats after every ready-task lookup, so a slow captain-hold lookup over many tasks never ages the beacon.
#   3. A command the harness detached (reparented, no harness in its ancestry) still owns the session lock of its own
#      Claude session, and a dead or foreign Claude does not.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_AUTOARM_CLAIM_BOUND

TMP_ROOT=$(jg_test_tmproot jg-autoarm-host-load)
PIDS=
cleanup() {
  # shellcheck disable=SC2086 # a list of pids this test started
  [ -z "$PIDS" ] || pkill -P "${PIDS// /,}" 2>/dev/null || true
  # shellcheck disable=SC2086 # a list of pids this test started
  [ -z "$PIDS" ] || kill $PIDS 2>/dev/null || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

# --- 1. the auto-arm claims a stale-beat home ------------------------------------
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
cp -R "$ROOT/bin" "$HOME_DIR/bin"
cp -R "$ROOT/defaults" "$HOME_DIR/defaults"
: > "$HOME_DIR/config/supervision-host-off"
ln -s /bin/bash "$HOME_DIR/fake-claude"
printf 'kind=ship\n' > "$HOME_DIR/state/task1.meta"
printf 'working [at=%s]: building\n' "$(date +%s)" > "$HOME_DIR/state/task1.status"
# The arm stand-in records that the hook ran it.
cat > "$HOME_DIR/bin/jg-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
date +%s >> "$JG_HOME/arm-ran"
printf 'watcher: FAILED - stand-in arm\n'
exit 1
SH
chmod +x "$HOME_DIR/bin/jg-watch-arm.sh"

# shellcheck source=bin/jg-wake-lib.sh
. "$ROOT/bin/jg-wake-lib.sh"
sleep 300 >/dev/null 2>&1 &
OWNER=$!
PIDS="$OWNER"
IDENT=$(jg_pid_identity "$OWNER") || fail "fixture: no identity for the claim owner"

# An arming claim with a live owner, and a claim age and beat age in seconds.
seed_claim() {  # <age>
  printf 'epoch=7 owner_pid=%s outcome=arming updated_at=%s\n%s\n' "$OWNER" "$(( $(date +%s) - $1 ))" "$IDENT" \
    > "$HOME_DIR/state/.claude-autoarm-epoch"
  : > "$HOME_DIR/state/.last-watcher-beat"
  touch -d "-$1 seconds" "$HOME_DIR/state/.claude-autoarm-epoch" "$HOME_DIR/state/.last-watcher-beat"
  rm -f "$HOME_DIR/arm-ran"
}
fire_stop_hook() {
  # shellcheck disable=SC2016 # the fake harness expands its own variables.
  printf '{"session_id":"sess-load","stop_hook_active":false}\n' \
    | JG_HOME="$HOME_DIR" JG_GUARD_GRACE=600 JG_CLAUDE_AUTOARM_ATTEMPTS=1 "$HOME_DIR/fake-claude" -c '
        printf "%s\n" "$$" > "$JG_HOME/state/.lock"
        bash "$JG_HOME/bin/jg-claude-stop-autoarm.sh" 2>&1' >/dev/null 2>&1
}

seed_claim 10
fire_stop_hook
[ ! -e "$HOME_DIR/arm-ran" ] || fail "a fresh arming claim must be deferred to, but the hook armed"
seed_claim 200
fire_stop_hook
[ -e "$HOME_DIR/arm-ran" ] || fail "a claim with a 200 s old beat (grace 600 under load) was not claimed: the home stays dark"
pass "jg-claude-stop-autoarm: a fresh claim is deferred to; a claim with no beat past the claim bound is claimed even at a load-stretched grace"

# --- 2. the watcher beats between slow lookups -----------------------------------
FN="$TMP_ROOT/stall-fn.sh"
sed -n '/^ready_backlog_stall_state() {$/,/^}$/p' "$ROOT/bin/jg-watch.sh" > "$FN"
[ -s "$FN" ] || fail "fixture: the watcher's ready-stall function was not found"
BEATS="$TMP_ROOT/beats"
: > "$BEATS"
mkdir -p "$TMP_ROOT/w/bin" "$TMP_ROOT/w/state"
cat > "$TMP_ROOT/w/bin/jg-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
sleep 0.2
exit 1
SH
chmod +x "$TMP_ROOT/w/bin/jg-captain-hold.sh"
: > "$TMP_ROOT/w/bin/jg-question-lib.sh"
# shellcheck disable=SC2034,SC2329 # the sourced function reads these and calls the stand-ins
(
  JG_HOME="$TMP_ROOT/w" STATE="$TMP_ROOT/w/state" CONFIG="$TMP_ROOT/w/config" SCRIPT_DIR="$TMP_ROOT/w/bin"
  jg_compat_marker() { printf '%s\n' "$FN"; }
  jg_ready_work_rows() { for n in 1 2 3 4 5; do printf 't%s -\n' "$n"; done; }
  lane_target_value() { printf '4\n'; }
  open_lane_count() { printf '0\n'; }
  jg_question_signoff_available() { return 1; }
  jg_project_capacity_config_dir() { return 1; }
  watcher_beat() { printf '%s\n' "$1" >> "$BEATS"; }
  # shellcheck source=/dev/null
  . "$FN"
  ready_backlog_stall_state
)
beats=$(grep -c '^ready-stall$' "$BEATS" || true)
[ "$beats" = 5 ] || fail "expected one beat per ready task lookup (5), saw ${beats:-0}"
pass "jg-watch: the ready-stall pass beats after each of the 5 slow captain-hold lookups"

# --- 3. a detached command still owns its own session lock -----------------------
LOCKSTATE="$TMP_ROOT/lock/state"
mkdir -p "$LOCKSTATE"
ln -s /bin/bash "$TMP_ROOT/lock/claude"
owner_probe() {  # <claude pid env> <session id env>: prints owned or not-owned from a detached process
  local out="$TMP_ROOT/lock/probe.out"
  rm -f "$out"
  # shellcheck disable=SC2016 # expanded by the inner shell
  env CLAUDE_PID="$1" CLAUDE_CODE_SESSION_ID="$2" LIB="$ROOT/bin/jg-session-lock-lib.sh" ST="$LOCKSTATE" OUT="$out" \
    setsid -f bash -c '. "$LIB"; if jg_session_lock_owned_by_self "$ST"; then echo owned; else echo not-owned; fi > "$OUT"' </dev/null >/dev/null 2>&1
  for _ in $(seq 1 50); do [ -s "$out" ] && break; sleep 0.1; done
  cat "$out" 2>/dev/null
}
"$TMP_ROOT/lock/claude" -c 'sleep 300; sleep 0' </dev/null >/dev/null 2>&1 &
CLAUDE=$!
PIDS="$PIDS $CLAUDE"
printf '%s\n' "$CLAUDE" > "$LOCKSTATE/.lock"
printf 'sess-a\n' > "$LOCKSTATE/.lock-session"
[ "$(owner_probe "$CLAUDE" sess-a)" = owned ] || fail "a detached command of the lock-owning Claude session lost ownership"
[ "$(owner_probe "$CLAUDE" sess-b)" = not-owned ] || fail "a detached command under another session id must not own the lock"
[ "$(owner_probe 999999 sess-a)" = not-owned ] || fail "a detached command naming a dead Claude pid must not own the lock"
pass "jg-session-lock: a detached command owns its own Claude session's lock; another session id or a dead pid does not"
