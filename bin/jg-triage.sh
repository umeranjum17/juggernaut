#!/usr/bin/env bash
# jg-triage.sh - check this home's health in one command, and repair what is safe to repair.
#
# Usage (JG_HOME is required, as for jg-send.sh):
#   JG_HOME=<home> bin/jg-triage.sh [--fix] [--only <check>[,<check>]] [--porcelain]
#                                   [--context <file>] [--agent] [--offline]
#
# Default is CHECK ONLY: nothing changes. It is a plain script with no model call, so it
# still runs when the agent runtime is the part that is broken. It reads each fact from the
# script that already owns it and adds no probe of its own:
#   session-lock    state/.lock holder (bin/jg-inbox.sh ready)
#   wake-consumer   whether the live session consumes wakes (bin/jg-inbox.sh ready)
#   stack           bus, wake engine, router, dapr, gateway (bin/jg-stack.sh status)
#   backlog-lock    a 0-byte data/backlog.md.lock left by a dead writer
#   squad-lead      each registered Squad Lead's endpoint (bin/jg-squad-lead-liveness-lib.sh, read-only probe)
#   sentinel        jg-sentinel not running (bin/jg-bootstrap.sh detect lines)
#   tools           missing tools and version floors (bin/jg-bootstrap.sh detect lines)
#   checkout        primary checkout off its default branch (bin/jg-bootstrap.sh detect lines)
#   config          invalid config and a code-root backlog fork (bin/jg-bootstrap.sh detect lines)
#   login           gh sign-in (gh auth status; skipped with --offline)
#   tmp             /tmp space and inode pressure (bin/jg-tmp-sweep.sh check)
#   stray-servers   leftover throwaway nats-servers (bin/jg-stray-nats-reap.sh dry run; report only)
#
# --fix repairs only these findings, each through the script that guards it:
#   stack          bin/jg-stack.sh up
#   backlog-lock   core/backlog-lock-reclaim/backlog-lock-reclaim.check.sh (reclaims only a 0-byte file nothing holds open)
#   squad-lead     the guarded relaunch of bin/jg-squad-lead-liveness-lib.sh, only when the endpoint is
#                  proved dead or missing; a parked or dormant home, an ambiguous or unreadable endpoint,
#                  and a lead whose auto-relaunch is paused are never relaunched
#   tmp            bin/jg-tmp-sweep.sh sweep --apply (stale fleet scratch only, by age)
# --fix changes nothing while another live session holds the home lock. A repair that does not
# make its check pass is reported as failed and the finding stays.
# It never forces, stashes, discards, signs in, installs, updates, kills a process, or touches
# projects/, a worktree, or unlanded work. Logins, installs, a tangled checkout and installed-copy
# drift stay HUMAN findings with the exact step printed.
#
#   --only <list>   run only the named checks (comma separated).
#   --porcelain     stable line protocol for scripts (below) instead of the people view.
#   --context <f>   write a redacted facts file for any agent to read (mode 0600); no secret is read.
#   --agent         after the checks, start an interactive agent on the findings the script cannot
#                   repair: the home's verified harness (bin/jg-harness.sh crew) with the --context
#                   facts and a playbook that asks before each fix and never reads a secret.
#                   Supported for claude and codex; nothing starts when no finding is left.
#   --offline       skip checks that call the network (login).
#
# Exit: 0 healthy, or every finding fixed; 1 a fixable or human finding remains; 2 no JG_HOME or
# a bad flag, or a check could not read its source (an unreadable state is never reported as dead).
#
# --porcelain lines, one fact per line, stable for script consumers:
#   mode=check|fix
#   check <name>[:<target>]=ok|fixable|human|skip|info|unknown: <detail>
#   fix <name>[:<target>]=applied|failed: <what happened>      (--fix only)
#   action: <name>[:<target>]: <the exact step to take>
#   summary fixable=<n> human=<n> unknown=<n>
# Every check line is the state after the repair attempt, so a gap is never shown as fixed.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ALL_CHECKS="session-lock wake-consumer stack backlog-lock squad-lead sentinel tools checkout config login tmp stray-servers"

die() { printf 'jg-triage: %s\n' "$*" >&2; exit 2; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

FIX=0 PORCELAIN=0 AGENT=0 OFFLINE=0 CONTEXT="" ONLY=""
while [ "$#" -gt 0 ]; do
  case $1 in
    --fix) FIX=1 ;;
    --porcelain) PORCELAIN=1 ;;
    --agent) AGENT=1 ;;
    --offline) OFFLINE=1 ;;
    --only) [ "$#" -ge 2 ] || die "--only needs a check name"; ONLY=$2; shift ;;
    --only=*) ONLY=${1#--only=} ;;
    --context) [ "$#" -ge 2 ] || die "--context needs a file"; CONTEXT=$2; shift ;;
    --context=*) CONTEXT=${1#--context=} ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[ -n "${JG_HOME:-}" ] || die "JG_HOME must be set to the home to check"
[ -d "$JG_HOME" ] || die "JG_HOME is not a directory: $JG_HOME"
export JG_HOME
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
export JG_ROOT=${JG_ROOT:-$ROOT}
export STATE
HOME_NAME=$(basename "$JG_HOME")

SELECTED=""
if [ -n "$ONLY" ]; then
  _list=${ONLY//,/ }
  for c in $_list; do
    case " $ALL_CHECKS " in *" $c "*) ;; *) die "unknown check '$c' (known: $ALL_CHECKS)" ;; esac
    case " $SELECTED " in *" $c "*) ;; *) SELECTED="$SELECTED $c" ;; esac
  done
  [ -n "$SELECTED" ] || die "--only named no check"
else
  SELECTED=" $ALL_CHECKS"
fi
selected() { case "$SELECTED " in *" $1 "*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------- records
# One record per finding: check, target (may be empty), status, detail, action (may be empty).
R_CHECK=() R_TARGET=() R_STATUS=() R_DETAIL=() R_ACTION=()
F_KEY=() F_RESULT=() F_TEXT=()

emit() {  # <check> <target> <ok|fixable|human|skip|info|unknown> <detail> [action]
  R_CHECK[${#R_CHECK[@]}]=$1
  R_TARGET[${#R_TARGET[@]}]=$2
  R_STATUS[${#R_STATUS[@]}]=$3
  R_DETAIL[${#R_DETAIL[@]}]=$4
  R_ACTION[${#R_ACTION[@]}]=${5:-}
}

drop_check() {  # <check>: forget its records so a re-check replaces them
  local i c=() t=() s=() d=() a=()
  for ((i = 0; i < ${#R_CHECK[@]}; i++)); do
    [ "${R_CHECK[$i]}" = "$1" ] && continue
    c[${#c[@]}]=${R_CHECK[$i]} t[${#t[@]}]=${R_TARGET[$i]} s[${#s[@]}]=${R_STATUS[$i]}
    d[${#d[@]}]=${R_DETAIL[$i]} a[${#a[@]}]=${R_ACTION[$i]}
  done
  R_CHECK=() R_TARGET=() R_STATUS=() R_DETAIL=() R_ACTION=()
  for ((i = 0; i < ${#c[@]}; i++)); do emit "${c[$i]}" "${t[$i]}" "${s[$i]}" "${d[$i]}" "${a[$i]}"; done
}

count_status() {  # <status>
  local i n=0
  for ((i = 0; i < ${#R_STATUS[@]}; i++)); do [ "${R_STATUS[$i]}" = "$1" ] && n=$((n + 1)); done
  printf '%s\n' "$n"
}

first_line() { printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'; }

run_timed() {  # <seconds> <cmd>...
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# ---------------------------------------------------------------- shared reads
READY_JSON="" READY_DONE=0
read_ready() {
  [ "$READY_DONE" = 0 ] || return 0
  READY_DONE=1
  [ -x "$SCRIPT_DIR/jg-inbox.sh" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  READY_JSON=$(run_timed 30 "$SCRIPT_DIR/jg-inbox.sh" ready 2>/dev/null) || READY_JSON=""
  printf '%s' "$READY_JSON" | jq -e . >/dev/null 2>&1 || READY_JSON=""
}
ready_get() { printf '%s' "$READY_JSON" | jq -r "$1 // empty" 2>/dev/null; }

BOOT_DONE=0 BOOT_OK=0 BOOT_OUT=""
read_bootstrap() {
  [ "$BOOT_DONE" = 0 ] || return 0
  BOOT_DONE=1
  [ -x "$SCRIPT_DIR/jg-bootstrap.sh" ] || return 0
  if BOOT_OUT=$(JG_BOOTSTRAP_DETECT_ONLY=1 JG_BOOTSTRAP_NETWORK=skip run_timed 180 "$SCRIPT_DIR/jg-bootstrap.sh" 2>/dev/null); then
    BOOT_OK=1
  fi
}

# The three facts a repair must not run without: another live session holds the home lock.
FIX_GATE_DONE=0 FIX_GATE_REASON=""
fix_gate() {  # prints nothing; sets FIX_GATE_REASON non-empty when a repair is refused
  [ "$FIX_GATE_DONE" = 0 ] || return 0
  FIX_GATE_DONE=1
  read_ready
  local state pid live
  state=$(ready_get .lock.state)
  pid=$(ready_get .lock.pid)
  live=$(ready_get .lock.live_harness)
  case "$state" in
    free|stale) return 0 ;;
    held) [ "$live" = true ] || return 0 ;;
    '') FIX_GATE_REASON="the home lock could not be read, so no repair is safe" ; return 0 ;;
    *) FIX_GATE_REASON="the home lock state is $state, so no repair is safe"; return 0 ;;
  esac
  if [ -r "$SCRIPT_DIR/jg-session-lock-lib.sh" ]; then
    # shellcheck source=bin/jg-session-lock-lib.sh
    . "$SCRIPT_DIR/jg-session-lock-lib.sh" 2>/dev/null || true
    if command -v jg_session_lock_owned_by_self >/dev/null 2>&1 && jg_session_lock_owned_by_self "$STATE"; then
      return 0
    fi
  fi
  FIX_GATE_REASON="another live session (pid ${pid:-unknown}) holds the home lock"
}

# ---------------------------------------------------------------- checks
check_session_lock() {
  read_ready
  if [ -z "$READY_JSON" ]; then
    emit session-lock "" unknown "the lock state could not be read (needs jq, python3 and bin/jg-inbox.sh ready); not treated as dead"
    return
  fi
  local state pid live
  state=$(ready_get .lock.state)
  pid=$(ready_get .lock.pid)
  live=$(ready_get .lock.live_harness)
  case "$state" in
    held) emit session-lock "" ok "held by live pid ${pid:-unknown}" ;;
    free) emit session-lock "" ok "no session holds the lock; the next session takes it" ;;
    stale) emit session-lock "" ok "recorded pid ${pid:-unknown} is gone; the next session reclaims the lock" ;;
    *) emit session-lock "" unknown "lock state is ${state:-unreadable} (live harness: ${live:-unknown}); not treated as dead" ;;
  esac
}

check_wake_consumer() {
  read_ready
  if [ -z "$READY_JSON" ]; then
    emit wake-consumer "" unknown "the wake consumer state could not be read (needs jq, python3 and bin/jg-inbox.sh ready)"
    return
  fi
  local lock state reason
  lock=$(ready_get .lock.state)
  state=$(ready_get .wake_consumer.state)
  reason=$(ready_get .wake_consumer.reason)
  case "$state" in
    healthy) emit wake-consumer "" ok "supervised" ;;
    down)
      if [ "$lock" = held ]; then
        emit wake-consumer "" human "the live session is not consuming wakes (${reason:-unknown})" \
          "the session must re-arm its supervision cycle (the digest names the command); triage cannot arm it"
      else
        emit wake-consumer "" ok "no live session, so nothing consumes wakes (${reason:-unknown})"
      fi
      ;;
    *) emit wake-consumer "" ok "not known (${reason:-unknown}); no live session to ask" ;;
  esac
}

STACK_OUT=""
check_stack() {
  if [ ! -x "$SCRIPT_DIR/jg-stack.sh" ]; then
    emit stack "" unknown "bin/jg-stack.sh is not here"
    return
  fi
  local rc=0 line parts
  STACK_OUT=$(run_timed 120 "$SCRIPT_DIR/jg-stack.sh" status 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then
    parts=$(printf '%s\n' "$STACK_OUT" | grep -c 'running pid')
    emit stack "" ok "$parts parts running"
    return
  fi
  line=$(printf '%s\n' "$STACK_OUT" | grep '^STACK_FAILED:' | head -n 1)
  if [ -n "$line" ]; then
    emit stack "" fixable "${line#STACK_FAILED: }"
  else
    emit stack "" unknown "jg-stack.sh status failed (exit $rc): $(first_line "$STACK_OUT")"
  fi
}
fix_stack() {  # <target> -> prints a one-line result, returns 0 when the script ran clean
  local out rc=0
  out=$(run_timed 600 "$SCRIPT_DIR/jg-stack.sh" up 2>&1) || rc=$?
  printf '%s\n' "$(printf '%s\n' "$out" | grep '^STACK_FAILED:' | head -n 1 | sed 's/^STACK_FAILED: //')"
  return "$rc"
}

lock_file() { printf '%s\n' "$DATA/backlog.md.lock"; }
file_mtime() { stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null; }
check_backlog_lock() {
  local lock mtime age safe=${JG_BACKLOG_LOCK_SAFE_AGE_S:-60}
  lock=$(lock_file)
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    emit backlog-lock "" ok "no lock file"
    return
  fi
  if [ -L "$lock" ] || [ ! -f "$lock" ]; then
    emit backlog-lock "" human "data/backlog.md.lock is not a plain file" "look at $lock; triage does not touch it"
    return
  fi
  if [ -s "$lock" ]; then
    emit backlog-lock "" ok "held by a writer (the lock has an owner token)"
    return
  fi
  mtime=$(file_mtime "$lock") || mtime=""
  case "$mtime" in ''|*[!0-9]*) emit backlog-lock "" unknown "the age of the lock file could not be read"; return ;; esac
  age=$(( $(date +%s) - mtime ))
  if [ "$age" -gt "$safe" ]; then
    emit backlog-lock "" fixable "0-byte backlog.md.lock, ${age}s old"
  else
    emit backlog-lock "" ok "0-byte lock only ${age}s old; a writer may still be starting"
  fi
}
fix_backlog_lock() {
  local reclaim="$ROOT/core/backlog-lock-reclaim/backlog-lock-reclaim.check.sh" out rc=0
  [ -x "$reclaim" ] || { printf 'core/backlog-lock-reclaim is not installed here\n'; return 1; }
  out=$(run_timed 60 "$reclaim" "$JG_HOME" 2>&1) || rc=$?
  printf '%s\n' "$(first_line "$out")"
  return "$rc"
}

# Squad Leads. The probe is the read-only `poll` mode of the liveness library, run in a subshell
# so its globals never leak. Output of the subshell: <status>|<state>|<text>.
squad_lead_ids() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=squad_lead$' "$meta" 2>/dev/null || continue
    basename "$meta" .meta
  done
}
squad_lead_probe() {  # <id> -> "<verdict>|<text>"; verdict: parked dormant silent alive relaunchable skipped bound
  local id=$1
  (
    lib="$SCRIPT_DIR/jg-squad-lead-liveness-lib.sh"
    [ -r "$lib" ] || { printf 'skipped|the liveness library is not here\n'; exit 0; }
    # shellcheck source=bin/jg-squad-lead-liveness-lib.sh
    . "$lib" >/dev/null 2>&1 || { printf 'skipped|the liveness library did not load\n'; exit 0; }
    meta="$STATE/$id.meta"
    if [ -r "$SCRIPT_DIR/jg-parked-homes-lib.sh" ]; then
      # shellcheck source=bin/jg-parked-homes-lib.sh
      . "$SCRIPT_DIR/jg-parked-homes-lib.sh" >/dev/null 2>&1 || true
      if command -v jg_parked_skip_meta >/dev/null 2>&1 && jg_parked_skip_meta "$meta" "$id" triage >/dev/null 2>&1; then
        printf 'parked|its home is parked (config/parked-homes); left alone\n'
        exit 0
      fi
    fi
    if [ -r "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh" ]; then
      # shellcheck source=bin/jg-squad-lead-registry-lib.sh
      . "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh" >/dev/null 2>&1 || true
      if command -v squad_lead_dormant >/dev/null 2>&1 && squad_lead_dormant "$STATE" "$id"; then
        printf 'dormant|dormant with no open work\n'
        exit 0
      fi
    fi
    jg_squad_lead_liveness_probe "$meta" "$id" poll >/dev/null 2>&1
    case "${JG_SM_LIVE_STATUS:-}" in
      silent) printf 'silent|no endpoint is recorded for it\n' ;;
      alive) printf 'alive|%s\n' "${JG_SM_LIVE_LINE:-endpoint alive}" ;;
      relaunchable)
        if [ -e "$STATE/.squad-lead-relaunch-bound-$id" ] || [ -L "$STATE/.squad-lead-relaunch-bound-$id" ]; then
          printf 'bound|endpoint %s (%s) and its auto-relaunch is paused after repeated attempts\n' \
            "${JG_SM_LIVE_STATE:-unknown}" "${JG_SM_LIVE_WHERE:-unknown}"
        else
          printf 'relaunchable|endpoint %s (%s)\n' "${JG_SM_LIVE_STATE:-unknown}" "${JG_SM_LIVE_WHERE:-unknown}"
        fi
        ;;
      *) printf 'skipped|%s\n' "${JG_SM_LIVE_REASON:-the endpoint could not be probed}" ;;
    esac
  ) 2>/dev/null
}
check_squad_lead() {
  local id any=0 res verdict text
  for id in $(squad_lead_ids); do
    any=1
    res=$(squad_lead_probe "$id") || res=""
    verdict=${res%%|*}
    text=${res#*|}
    case "$verdict" in
      alive) emit squad-lead "$id" ok "$text" ;;
      parked|dormant) emit squad-lead "$id" skip "$text" ;;
      relaunchable) emit squad-lead "$id" fixable "$text" ;;
      bound) emit squad-lead "$id" human "$text" "find out why it keeps exiting; the pause lifts when a probe finds it alive" ;;
      silent) emit squad-lead "$id" human "$text" "this is a provisioning gap; load squad-lead-provisioning recovery" ;;
      *) emit squad-lead "$id" unknown "${text:-the endpoint could not be probed}; not treated as dead" ;;
    esac
  done
  [ "$any" = 1 ] || emit squad-lead "" skip "no Squad Lead is registered in this home"
}
fix_squad_lead() {  # <id>
  local id=$1
  (
    # shellcheck source=bin/jg-squad-lead-liveness-lib.sh
    . "$SCRIPT_DIR/jg-squad-lead-liveness-lib.sh" >/dev/null 2>&1 || { printf 'the liveness library did not load\n'; exit 1; }
    meta="$STATE/$id.meta"
    jg_squad_lead_liveness_lock "$id" || { printf 'another liveness check is already in progress\n'; exit 1; }
    jg_squad_lead_liveness_probe "$meta" "$id" poll >/dev/null 2>&1
    if [ "${JG_SM_LIVE_STATUS:-}" != relaunchable ]; then
      jg_squad_lead_liveness_unlock "$id"
      printf 'not relaunchable now (%s)\n' "${JG_SM_LIVE_STATUS:-unknown}"
      exit 1
    fi
    if jg_squad_lead_liveness_relaunch "$meta" "$id" 600 >/dev/null 2>&1; then
      jg_squad_lead_liveness_unlock "$id"
      printf 'relaunched after %s (%s)\n' "${JG_SM_LIVE_CAUSE:-an unreachable endpoint}" "${JG_SM_LIVE_WHERE:-its recorded place}"
      exit 0
    fi
    jg_squad_lead_liveness_unlock "$id"
    printf 'relaunch refused: %s\n' "$(first_line "${JG_SM_LIVE_REASON:-${JG_SM_LIVE_OUT:-no reason given}}")"
    exit 1
  ) 2>/dev/null
}

# The jg-bootstrap detect lines, mapped to checks. One run serves all four checks.
bootstrap_lines() {  # <check>  -> the lines of BOOT_OUT that belong to it
  printf '%s\n' "$BOOT_OUT" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      MISSING:*|MISSING_MANUAL:*) k=tools ;;
      TANGLE:*) k=checkout ;;
      SENTINEL:*) k=sentinel ;;
      BOOTSTRAP_INFO:*) continue ;;
      BACKEND_INVALID:*|STARTUP_MEMORY_BUDGET:*|CREW_DISPATCH:*|BACKLOG_RECONCILE:*|HOME_SUMMARY:*) k=config ;;
      *) k=config ;;
    esac
    [ "$k" = "$1" ] && printf '%s\n' "$line"
  done
}
bootstrap_action() {  # <line> -> the step the line itself names, or empty
  local line=$1
  case "$line" in
    *'(install: '*) printf 'run: %s\n' "$(printf '%s' "${line#*'(install: '}" | sed 's/)$//')" ;;
    *'(instructions: '*) printf 'see: %s\n' "$(printf '%s' "${line#*'(instructions: '}" | sed 's/)$//')" ;;
    *'restore the primary with: '*) printf 'run: %s\n' "${line#*'restore the primary with: '}" ;;
    *'(fix, then run: '*) printf 'run: %s\n' "$(printf '%s' "${line#*'(fix, then run: '}" | sed 's/)$//')" ;;
  esac
}
check_from_bootstrap() {  # <check> <clean detail>
  read_bootstrap
  if [ "$BOOT_OK" != 1 ]; then
    emit "$1" "" unknown "the detect run of bin/jg-bootstrap.sh did not finish"
    return
  fi
  local lines line n=0
  lines=$(bootstrap_lines "$1")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    emit "$1" "$n" human "$(first_line "${line#*: }")" "$(bootstrap_action "$line")"
  done <<EOF
$lines
EOF
  [ "$n" -gt 0 ] || emit "$1" "" ok "$2"
}
check_sentinel() { check_from_bootstrap sentinel "jg-sentinel is running"; }
check_tools() { check_from_bootstrap tools "every tool is present at its floor"; }
check_checkout() { check_from_bootstrap checkout "the primary checkout is on its default branch"; }
check_config() { check_from_bootstrap config "config and the backlog code-root are sound"; }

check_login() {
  if [ "$OFFLINE" = 1 ]; then
    emit login "" skip "--offline"
    return
  fi
  if ! command -v gh >/dev/null 2>&1; then
    emit login "" skip "gh is not installed (the tools check names the install)"
    return
  fi
  if run_timed 20 gh auth status >/dev/null 2>&1; then
    emit login "" ok "gh is signed in"
  else
    emit login "" human "gh is not signed in" "run: gh auth login"
  fi
}

check_tmp() {
  if [ ! -x "$SCRIPT_DIR/jg-tmp-sweep.sh" ]; then
    emit tmp "" unknown "bin/jg-tmp-sweep.sh is not here"
    return
  fi
  local out rc=0
  out=$(run_timed 60 "$SCRIPT_DIR/jg-tmp-sweep.sh" check 2>&1) || rc=$?
  case "$rc" in
    0) emit tmp "" ok "$(first_line "$out")" ;;
    1) emit tmp "" fixable "$(first_line "$out")" ;;
    *) emit tmp "" unknown "the space of /tmp could not be read: $(first_line "$out")" ;;
  esac
}
fix_tmp() {
  local out rc=0
  out=$(run_timed 300 "$SCRIPT_DIR/jg-tmp-sweep.sh" sweep --apply 2>&1) || rc=$?
  printf '%s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  return "$rc"
}

check_stray_servers() {
  if [ ! -x "$SCRIPT_DIR/jg-stray-nats-reap.sh" ]; then
    emit stray-servers "" skip "bin/jg-stray-nats-reap.sh is not here"
    return
  fi
  local out n
  out=$(run_timed 30 "$SCRIPT_DIR/jg-stray-nats-reap.sh" 2>/dev/null) || out=""
  n=$(printf '%s\n' "$out" | grep -c '^would stop ')
  if [ "$n" -gt 0 ]; then
    emit stray-servers "" info "$n leftover throwaway nats-server(s)" "run: bin/jg-stray-nats-reap.sh --stop"
  else
    emit stray-servers "" ok "no leftover throwaway nats-server"
  fi
}

# ---------------------------------------------------------------- run
run_check() {  # <check>
  case $1 in
    session-lock) check_session_lock ;;
    wake-consumer) check_wake_consumer ;;
    stack) check_stack ;;
    backlog-lock) check_backlog_lock ;;
    squad-lead) check_squad_lead ;;
    sentinel) check_sentinel ;;
    tools) check_tools ;;
    checkout) check_checkout ;;
    config) check_config ;;
    login) check_login ;;
    tmp) check_tmp ;;
    stray-servers) check_stray_servers ;;
  esac
}
run_fix() {  # <check> <target>
  case $1 in
    stack) fix_stack "$2" ;;
    backlog-lock) fix_backlog_lock "$2" ;;
    squad-lead) fix_squad_lead "$2" ;;
    tmp) fix_tmp "$2" ;;
    *) return 1 ;;
  esac
}
FIXABLE_CHECKS="stack backlog-lock squad-lead tmp"
run_all() {
  local c
  for c in $ALL_CHECKS; do
    selected "$c" || continue
    run_check "$c"
  done
}
run_fixes() {
  local c i target key before_status out rc
  fix_gate
  if [ -n "$FIX_GATE_REASON" ]; then
    F_KEY[${#F_KEY[@]}]=gate F_RESULT[${#F_RESULT[@]}]=failed
    F_TEXT[${#F_TEXT[@]}]="nothing changed: $FIX_GATE_REASON"
    return
  fi
  for c in $FIXABLE_CHECKS; do
    selected "$c" || continue
    # The targets of this check that are fixable now.
    local targets=()
    for ((i = 0; i < ${#R_CHECK[@]}; i++)); do
      [ "${R_CHECK[$i]}" = "$c" ] && [ "${R_STATUS[$i]}" = fixable ] && targets[${#targets[@]}]=${R_TARGET[$i]}
    done
    [ "${#targets[@]}" -gt 0 ] || continue
    for target in "${targets[@]}"; do
      key=$c
      [ -z "$target" ] || key="$c:$target"
      rc=0
      out=$(run_fix "$c" "$target") || rc=$?
      before_status=$rc
      # Re-check this one check; its fresh records replace the old ones.
      drop_check "$c"
      BOOT_DONE=0
      run_check "$c"
      F_KEY[${#F_KEY[@]}]=$key
      if [ "$before_status" = 0 ] && ! check_still_fixable "$c" "$target"; then
        F_RESULT[${#F_RESULT[@]}]=applied
        F_TEXT[${#F_TEXT[@]}]=${out:-done}
      else
        F_RESULT[${#F_RESULT[@]}]=failed
        F_TEXT[${#F_TEXT[@]}]=${out:-the repair did not make the check pass}
        demote_to_human "$c" "$target" "${out:-the repair did not make the check pass}"
      fi
    done
  done
}
check_still_fixable() {  # <check> <target>
  local i
  for ((i = 0; i < ${#R_CHECK[@]}; i++)); do
    [ "${R_CHECK[$i]}" = "$1" ] && [ "${R_TARGET[$i]}" = "$2" ] && [ "${R_STATUS[$i]}" = fixable ] && return 0
  done
  return 1
}
demote_to_human() {  # <check> <target> <why>: a failed repair leaves a person's job, not another --fix
  local i
  for ((i = 0; i < ${#R_CHECK[@]}; i++)); do
    if [ "${R_CHECK[$i]}" = "$1" ] && [ "${R_TARGET[$i]}" = "$2" ] && [ "${R_STATUS[$i]}" = fixable ]; then
      R_STATUS[i]=human
      R_DETAIL[i]="${R_DETAIL[$i]}; --fix did not clear it: $3"
    fi
  done
}

label_of() {  # <check> <target>
  if [ -n "$2" ] && ! [[ "$2" =~ ^[0-9]+$ ]]; then printf '%s:%s\n' "$1" "$2"; else printf '%s\n' "$1"; fi
}

fix_hint() {  # <check> -> text for the people view
  case "$1" in
    stack) printf '[--fix: jg-stack.sh up]' ;;
    backlog-lock) printf '[--fix: backlog-lock-reclaim]' ;;
    squad-lead) printf '[--fix: guarded relaunch]' ;;
    tmp) printf '[--fix: jg-tmp-sweep.sh sweep --apply]' ;;
  esac
}

render_people() {
  local mode=check i label st tag extra
  [ "$FIX" = 1 ] && mode=fix
  if [ "$mode" = check ]; then
    printf 'jg-triage: home %s, mode check, nothing changed\n' "$HOME_NAME"
  else
    printf 'jg-triage: home %s, mode fix\n' "$HOME_NAME"
  fi
  for ((i = 0; i < ${#F_KEY[@]}; i++)); do
    printf '%-6s %-14s %s\n' "$(printf '%s' "${F_RESULT[$i]}" | tr '[:lower:]' '[:upper:]')" "${F_KEY[$i]}" "${F_TEXT[$i]}"
  done
  for ((i = 0; i < ${#R_CHECK[@]}; i++)); do
    label=$(label_of "${R_CHECK[$i]}" "${R_TARGET[$i]}")
    st=${R_STATUS[$i]}
    extra=""
    case "$st" in
      ok) tag=ok ;;
      skip) tag=skip ;;
      info) tag=INFO ;;
      fixable) tag=FIX; extra=$(fix_hint "${R_CHECK[$i]}") ;;
      human) tag=HUMAN ;;
      *) tag='??' ;;
    esac
    [ -z "${R_ACTION[$i]}" ] || extra="${extra:+$extra }${R_ACTION[$i]}"
    printf '%-6s %-14s %s%s\n' "$tag" "$label" "${R_DETAIL[$i]}" "${extra:+   $extra}"
  done
  printf '%s fixable, %s need you, %s unreadable.' "$(count_status fixable)" "$(count_status human)" "$(count_status unknown)"
  if [ "$FIX" = 0 ] && [ "$(count_status fixable)" -gt 0 ]; then printf ' Re-run with --fix.'; fi
  printf '\n'
}

render_porcelain() {
  local i label mode=check
  [ "$FIX" = 1 ] && mode=fix
  printf 'mode=%s\n' "$mode"
  for ((i = 0; i < ${#F_KEY[@]}; i++)); do
    printf 'fix %s=%s: %s\n' "${F_KEY[$i]}" "${F_RESULT[$i]}" "${F_TEXT[$i]}"
  done
  for ((i = 0; i < ${#R_CHECK[@]}; i++)); do
    label=$(label_of "${R_CHECK[$i]}" "${R_TARGET[$i]}")
    printf 'check %s=%s: %s\n' "$label" "${R_STATUS[$i]}" "${R_DETAIL[$i]}"
    [ -z "${R_ACTION[$i]}" ] || printf 'action: %s: %s\n' "$label" "${R_ACTION[$i]}"
  done
  printf 'summary fixable=%s human=%s unknown=%s\n' "$(count_status fixable)" "$(count_status human)" "$(count_status unknown)"
}

# ---------------------------------------------------------------- context and agent
# A line of the facts file never carries a home path or anything shaped like a credential.
redact() {
  local line
  while IFS= read -r line; do
    line=${line//"$HOME"/\~}
    printf '%s\n' "$line"
  done | sed -E \
    -e 's/(([Tt]oken|TOKEN|[Ss]ecret|SECRET|[Pp]assword|PASSWORD|[Aa]pi[_-]?[Kk]ey|API[_-]?KEY|[Kk]ey|KEY)[A-Za-z_]*[=:][[:space:]]*)[^[:space:]]+/\1<redacted>/g' \
    -e 's/[A-Za-z0-9_+\/=-]{40,}/<redacted>/g'
}

write_context() {  # <file>
  local f=$1 tmp i label
  if [ -L "$f" ] || [ -d "$f" ]; then die "--context target is a link or a directory: $f"; fi
  tmp=$(umask 077 && mktemp "${f}.XXXXXX") || die "cannot write --context file: $f"
  {
    printf '# jg-triage facts\n\n'
    printf 'Home: %s\n' "$HOME_NAME"
    printf 'Juggernaut checkout: %s\n' "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'Mode: %s\n' "$([ "$FIX" = 1 ] && echo fix || echo check)"
    printf 'Observed: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\nThis file holds check results only. No secret, token, or config value was read to make it.\n\n'
    printf '## Findings\n\n'
    for ((i = 0; i < ${#F_KEY[@]}; i++)); do
      printf -- '- fix %s: %s - %s\n' "${F_KEY[$i]}" "${F_RESULT[$i]}" "${F_TEXT[$i]}"
    done
    for ((i = 0; i < ${#R_CHECK[@]}; i++)); do
      label=$(label_of "${R_CHECK[$i]}" "${R_TARGET[$i]}")
      printf -- '- %s: %s - %s' "$label" "${R_STATUS[$i]}" "${R_DETAIL[$i]}"
      [ -z "${R_ACTION[$i]}" ] || printf ' (%s)' "${R_ACTION[$i]}"
      printf '\n'
    done
  } | redact > "$tmp"
  mv -f -- "$tmp" "$f" || die "cannot write --context file: $f"
}

has_open_findings() {
  [ "$(( $(count_status fixable) + $(count_status human) + $(count_status unknown) ))" -gt 0 ]
}

run_agent() {
  has_open_findings || { printf 'jg-triage: nothing is left to triage, so no agent was started\n' >&2; return 0; }
  local harness dir facts playbook prompt
  harness=$("$SCRIPT_DIR/jg-harness.sh" crew 2>/dev/null) || harness=""
  case "$harness" in
    claude|codex) ;;
    '') die "--agent could not resolve a harness (bin/jg-harness.sh crew printed nothing)" ;;
    *) die "--agent supports the claude and codex harnesses; this home resolves to '$harness'. Read the --context file and the playbook by hand." ;;
  esac
  command -v "$harness" >/dev/null 2>&1 || die "--agent: '$harness' is not on PATH"
  dir=$(mktemp -d) || die "cannot make a scratch folder for --agent"
  facts=${CONTEXT:-$dir/facts.md}
  [ -n "$CONTEXT" ] || write_context "$facts"
  playbook="$dir/playbook.md"
  cat > "$playbook" <<'PLAYBOOK'
# jg-triage playbook

You are helping the person at this terminal repair a Juggernaut home. A script already checked it.
The facts file lists what it found. Work only from those findings.

Rules, in force for the whole session:
- Ask before every fix. Say what you will run and what it changes, then wait for a yes.
- Never read a secret. Do not open `.env`, anything under `config/` that holds a token or key, `state/bus/` credentials, ssh or cloud credential files, or a process environment.
- Use the guarded Juggernaut scripts for repairs (`bin/jg-stack.sh up`, `bin/jg-control.sh`, `bin/jg-fleet-sync.sh`, `bin/jg-tmp-sweep.sh`). Never force, stash, discard, or delete unlanded work, and never touch `projects/`.
- Treat an unreadable or ambiguous state as unknown, never as dead.
- Sign-ins, installs, and account choices belong to the person. Print the command and let them run it.
- Never post, comment, or open anything on a remote service.

Steps:
1. Read the facts file. Rank the findings by what they block.
2. For each finding, read only the logs and records that explain it, then propose one fix.
3. After each approved fix, run `bin/jg-triage.sh --only <check>` and show the new result.
4. End with what is fixed, what is left, and who must act on it.
PLAYBOOK
  prompt="Read $facts and $playbook, then follow the playbook for the findings in the facts file."
  printf 'jg-triage: starting %s with %s and %s\n' "$harness" "$facts" "$playbook" >&2
  exec "$harness" "$prompt"
}

# ---------------------------------------------------------------- main
run_all
if [ "$FIX" = 1 ]; then
  run_fixes
fi

if [ "$PORCELAIN" = 1 ]; then render_porcelain; else render_people; fi
[ -z "$CONTEXT" ] || write_context "$CONTEXT"
[ "$AGENT" = 0 ] || run_agent

if [ "$(count_status unknown)" -gt 0 ]; then exit 2; fi
if [ "$(count_status fixable)" -gt 0 ] || [ "$(count_status human)" -gt 0 ]; then exit 1; fi
exit 0
