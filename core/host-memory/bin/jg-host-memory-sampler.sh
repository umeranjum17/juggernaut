#!/usr/bin/env bash
# One memory sampler per home, started/restarted/stopped by jg-watch.sh.
# The home-scoped .host-memory-sampler.pid stores PID and process identity.
# Samples every JG_HOST_MEMORY_SECS (default 10) independently of supervision;
# each ALERT episode attempts one owned-task interrupt and queues a durable wake.
# Sourced by the watcher for lifecycle functions; executable as run HOME STATE CONFIG.

# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

MEMORY_SAMPLER_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jg-host-memory-sampler.sh"

jg_memory_sampler_matches() {
  local pid identity current suffix
  IFS=$'\t' read -r pid identity 2>/dev/null < "$STATE/.host-memory-sampler.pid" || return 1
  case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
  [ -n "$identity" ] || return 1
  current=$(jg_pid_identity "$pid") || return 1
  [ "$current" = "$identity" ] || return 1
  case "$current" in
    *cmdline-hex=*)
      suffix=$(printf '%s\0' "$MEMORY_SAMPLER_PATH" run "$JG_HOME" "$STATE" "$CONFIG" | od -An -v -tx1 | tr -d '[:space:]')
      case "$current" in *"$suffix") ;; *) return 1 ;; esac ;;
    *) case "$current" in *"$MEMORY_SAMPLER_PATH run $JG_HOME $STATE $CONFIG") ;; *) return 1 ;; esac ;;
  esac
  MEMORY_SAMPLER_PID=$pid
}

jg_memory_sampler_ensure() {
  local i=0
  jg_memory_sampler_matches && return 0
  env JG_HOST_MEMORY_FORK_BIN="${SAMPLER_DIR:-${SCRIPT_DIR:-${MEMORY_SAMPLER_PATH%/*}}}" \
    JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" JG_CONFIG_OVERRIDE="$CONFIG" \
    "$MEMORY_SAMPLER_PATH" run "$JG_HOME" "$STATE" "$CONFIG" \
    </dev/null >> "$STATE/.host-memory-sampler.log" 2>&1 &
  while [ "$i" -lt 30 ]; do
    jg_memory_sampler_matches && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

jg_memory_sampler_stop() {
  jg_memory_sampler_matches || return 0
  kill -TERM "$MEMORY_SAMPLER_PID" 2>/dev/null || true
  wait "$MEMORY_SAMPLER_PID" 2>/dev/null || true
}

jg_memory_sampler_interrupt() {
  local task=$1 action result
  if result=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SAMPLER_DIR/jg-control.sh" "$task" interrupt 2>&1); then
    action="automatically interrupted task $task: $result"
  else
    action="automatic interrupt failed for task $task: $result"
  fi
  printf '%s\t%s\t%s\n' "$(date +%s)" "$task" "$action" >> "$STATE/host-memory-interrupts.tsv"
}

jg_memory_sampler_tick() {
  local out d meta home root child_state task reason action epoch stop=0 latch="$STATE/.host-memory-alerted"
  local -a dirs=(--state-dir "$JG_HOME" "$STATE")
  jg_local_juggernaut_state_dirs "$STATE" 2>/dev/null || JG_LOCAL_JUGGERNAUT_STATES=("$STATE")
  if root=$(jg_juggernaut_root_home "$JG_HOME") && [ ! "$root" -ef "$JG_HOME" ]; then
    dirs+=(--state-dir "$root" "$root/state")
  fi
  for d in "${JG_LOCAL_JUGGERNAUT_STATES[@]}"; do
    for meta in "$d"/*.meta; do
      [ "$(jg_meta_get "$meta" kind)" = squad_lead ] || continue
      home=$(jg_meta_get "$meta" home)
      [ -n "$home" ] && [ ! "$home" -ef "$JG_HOME" ] || continue
      for child_state in "${JG_LOCAL_JUGGERNAUT_STATES[@]}"; do
        [ "$child_state" -ef "$home/state" ] || continue
        dirs+=(--state-dir "$home" "$child_state")
      done
    done
  done
  out=$("$SAMPLER_DIR/jg-jev-mem-guard.sh" --config "$CONFIG/host-memory" --record "$STATE/host-memory.tsv" --owned-top-task "$STATE" "${dirs[@]}" 2>&1) || {
    printf 'host memory guard failed: %s\n' "$out" >&2
    return 0
  }
  case "${out%%$'\t'*}" in
    ALERT) ;;
    WAIT|OK) rm -f "$latch"; return 0 ;;
    *) return 0 ;;
  esac
  [ ! -e "$latch" ] || return 0
  task=${out##*$'\t'}
  out=${out%$'\t'*}
  reason="check: host memory ALERT: ${out#*$'\t'}"
  action="automatic interrupt skipped: top consumer is not a task this home owns"
  case "$task" in
    ''|*[!A-Za-z0-9._-]*) ;;
    *) action="automatic interrupt attempted: task $task" ;;
  esac
  epoch=$(date +%s)
  jg_lock_acquire_wait "$JG_WAKE_QUEUE_LOCK" || return 0
  trap 'stop=1' HUP INT TERM
  if jg_wake_append_locked check host-memory "$reason; $action" \
    && printf '%s\t%s\t%s\n' "$epoch" "$task" "$reason; $action" >> "$STATE/host-memory-interrupts.tsv" \
    && printf '%s\n' "$reason; $action" > "$latch.$$" \
    && mv "$latch.$$" "$latch"; then
    case "$task" in
      ''|*[!A-Za-z0-9._-]*) ;;
      *) (trap - EXIT HUP INT TERM; jg_memory_sampler_interrupt "$task") </dev/null & ;;
    esac
  fi
  rm -f "$latch.$$"
  jg_lock_release "$JG_WAKE_QUEUE_LOCK"
  trap 'exit 0' HUP INT TERM
  [ "$stop" -eq 0 ] || exit 0
}

jg_memory_sampler_cleanup() {
  local pid identity
  IFS=$'\t' read -r pid identity 2>/dev/null < "$STATE/.host-memory-sampler.pid" || pid=
  [ "$pid" != "$$" ] || rm -f "$STATE/.host-memory-sampler.pid"
  jg_lock_release "$STATE/.host-memory-sampler.lock"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  [ "$#" -eq 4 ] && [ "$1" = run ] || exit 2
  JG_HOME=$2 STATE=$3 CONFIG=$4
  [ -d "$STATE" ] || exit 1
  # Libraries, control and (until the admission slice moves) guard stay in the fork.
  SAMPLER_DIR=${JG_HOST_MEMORY_FORK_BIN:-${MEMORY_SAMPLER_PATH%/*}}
  # shellcheck source=bin/jg-wake-lib.sh
  . "$SAMPLER_DIR/jg-wake-lib.sh"
  # shellcheck source=bin/jg-backend.sh
  . "$SAMPLER_DIR/jg-backend.sh"
  jg_lock_try_acquire "$STATE/.host-memory-sampler.lock" || exit 0
  trap jg_memory_sampler_cleanup EXIT
  trap 'exit 0' HUP INT TERM
  identity=$(jg_pid_identity "$$") || exit 1
  registered=0
  secs=${JG_HOST_MEMORY_SECS:-}
  case "$secs" in ''|*[!0-9]*|0) secs=10 ;; esac
  while [ -d "$JG_HOME" ] && [ -d "$STATE" ] && [ -d "$SAMPLER_DIR" ]; do
    watcher=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
    if ! jg_pid_alive "$watcher" || ! jg_watcher_lock_matches_pid "$STATE" "$SAMPLER_DIR/jg-watch.sh" "$watcher" "$JG_HOME"; then
      break
    fi
    start=$(date +%s)
    jg_memory_sampler_tick
    if [ "$registered" -eq 0 ]; then
      printf '%s\t%s\n' "$$" "$identity" > "$STATE/.host-memory-sampler.pid.$$" || exit 1
      mv "$STATE/.host-memory-sampler.pid.$$" "$STATE/.host-memory-sampler.pid" || exit 1
      registered=1
    fi
    remaining=$((secs - ($(date +%s) - start)))
    if [ "$remaining" -gt 0 ]; then sleep "$remaining" & wait "$!" || true; fi
  done
fi
