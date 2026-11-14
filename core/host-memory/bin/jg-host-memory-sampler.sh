#!/usr/bin/env bash
# One memory sampler per machine, shared by every home on it.
# A home's jg-watch.sh registers it with jg_memory_sampler_ensure (a record under the machine directory) and
# unregisters with jg_memory_sampler_stop; the first ensure starts the one loop and the last stop ends it.
# Every JG_HOST_MEMORY_SECS (default 10) the loop runs one tick per registered home, each in its own child
# (tick HOME STATE CONFIG) so a home keeps its own wake queue, latch and interrupt log; a home whose watcher
# is gone is dropped. Each ALERT episode attempts one owned-task interrupt and queues a durable wake,
# except in a Squad Lead home under a local root, which records the alert without a wake.
# The home's .host-memory-sampler.pid names the shared process and proves the home is registered.
# Sourced by the watcher for lifecycle functions; executable as run (the machine loop) or tick HOME STATE CONFIG.

# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

MEMORY_SAMPLER_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jg-host-memory-sampler.sh"

# The machine directory is shared by every home of this user: the runtime dir when there is one.
jg_memory_machine_dir() {
  printf '%s\n' "${JG_HOST_MEMORY_MACHINE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/jg-host-memory-$(id -u)}"
}

# True when the pid recorded in <pidfile> is a live shared sampler (same process identity, same command).
jg_memory_sampler_pidfile_live() {
  local pid identity current suffix
  IFS=$'\t' read -r pid identity 2>/dev/null < "$1" || return 1
  case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
  [ -n "$identity" ] || return 1
  current=$(jg_pid_identity "$pid") || return 1
  [ "$current" = "$identity" ] || return 1
  case "$current" in
    *cmdline-hex=*)
      suffix=$(printf '%s\0' "$MEMORY_SAMPLER_PATH" run | od -An -v -tx1 | tr -d '[:space:]')
      case "$current" in *"$suffix") ;; *) return 1 ;; esac ;;
    *) case "$current" in *"$MEMORY_SAMPLER_PATH run") ;; *) return 1 ;; esac ;;
  esac
  MEMORY_SAMPLER_PID=$pid
}

# This home is served: it has a registry record and its own pid file names the live shared sampler.
jg_memory_sampler_matches() {
  [ -e "$(jg_memory_machine_dir)/homes/${STATE//\//%}" ] || return 1
  jg_memory_sampler_pidfile_live "$STATE/.host-memory-sampler.pid"
}

# jg_memory_sampler_register <home> <state> <config> <bin dir>: record one home for the shared loop to serve.
jg_memory_sampler_register() {
  local record
  mkdir -p "$(jg_memory_machine_dir)/homes" || return 1
  record="$(jg_memory_machine_dir)/homes/${2//\//%}"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" > "$record.$$" && mv "$record.$$" "$record"
}

jg_memory_sampler_ensure() {
  local machine i=0
  jg_memory_sampler_matches && return 0
  machine=$(jg_memory_machine_dir)
  jg_memory_sampler_register "$JG_HOME" "$STATE" "$CONFIG" "${SAMPLER_DIR:-${SCRIPT_DIR:-${MEMORY_SAMPLER_PATH%/*}}}" || return 1
  jg_memory_sampler_pidfile_live "$machine/pid" || {
    env JG_HOST_MEMORY_FORK_BIN="${SAMPLER_DIR:-${SCRIPT_DIR:-${MEMORY_SAMPLER_PATH%/*}}}" \
      JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" JG_CONFIG_OVERRIDE="$CONFIG" JG_HOST_MEMORY_MACHINE_DIR="$machine" \
      "$MEMORY_SAMPLER_PATH" run </dev/null >> "$machine/log" 2>&1 &
    while [ "$i" -lt 30 ]; do
      jg_memory_sampler_pidfile_live "$machine/pid" && break
      sleep 0.05
      i=$((i + 1))
    done
    jg_memory_sampler_pidfile_live "$machine/pid" || return 1
  }
  printf '%s\t%s\n' "$MEMORY_SAMPLER_PID" "$(jg_pid_identity "$MEMORY_SAMPLER_PID")" > "$STATE/.host-memory-sampler.pid.$$" \
    && mv "$STATE/.host-memory-sampler.pid.$$" "$STATE/.host-memory-sampler.pid"
}

# Unregister this home; the last home out ends the shared sampler.
jg_memory_sampler_stop() {
  local machine
  machine=$(jg_memory_machine_dir)
  rm -f "$machine/homes/${STATE//\//%}" "$STATE/.host-memory-sampler.pid"
  [ -z "$(ls -A "$machine/homes" 2>/dev/null)" ] || return 0
  jg_memory_sampler_pidfile_live "$machine/pid" || return 0
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
  local out root task reason action epoch stop=0 latch="$STATE/.host-memory-alerted" lead=0
  # The guard walks the squad_lead homes below these itself, and only when it names consumers,
  # so an ordinary tick reads no task record.
  local -a dirs=(--state-dir "$JG_HOME" "$STATE")
  if root=$(jg_juggernaut_root_home "$JG_HOME") && [ ! "$root" -ef "$JG_HOME" ]; then
    dirs+=(--state-dir "$root" "$root/state")
    lead=1
  fi
  out=$("$SAMPLER_DIR/jg-jev-mem-guard.sh" --config "$CONFIG/host-memory" --record "$STATE/host-memory.tsv" --owned-top-task "$STATE" "${dirs[@]}" 2>&1) || {
    printf 'host memory guard failed: %s\n' "$out" >&2
    return 0
  }
  case "${out%%$'\t'*}" in
    ALERT) ;;
    WAIT|OK) [ ! -e "$latch" ] || { rm -f "$latch"; jg_wake_host_clear host-memory; }; return 0 ;;
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
  trap 'stop=1' HUP INT TERM
  # The alert is one machine-wide event, raised through the alert function (alert host). A Squad Lead home under a
  # local root starts it at the tick rung, which settles it into the wake tally and its own interrupt log with no wake;
  # the root's sampler wakes Main alone. A home with no readable local parent record (Main, a remote-routed lead, a
  # damaged record) wakes as before.
  if jg_wake_host host-memory "$reason; $action" "$([ "$lead" -eq 1 ] && echo 0 || echo 3)" \
    && printf '%s\t%s\t%s\n' "$epoch" "$task" "$reason; $action" >> "$STATE/host-memory-interrupts.tsv" \
    && printf '%s\n' "$reason; $action" > "$latch.$$" \
    && mv "$latch.$$" "$latch"; then
    case "$task" in
      ''|*[!A-Za-z0-9._-]*) ;;
      *) (trap - EXIT HUP INT TERM; jg_memory_sampler_interrupt "$task") </dev/null & ;;
    esac
  fi
  rm -f "$latch.$$"
  trap 'exit 0' HUP INT TERM
  [ "$stop" -eq 0 ] || exit 0
}

jg_memory_sampler_cleanup() {
  local machine
  machine=$(jg_memory_machine_dir)
  jg_memory_sampler_pidfile_live "$machine/pid" && [ "$MEMORY_SAMPLER_PID" = "$$" ] && rm -f "$machine/pid"
  jg_lock_release "$machine/lock"
}

# One tick for one home, in the caller's own process: sources that home's libraries, which read STATE at source time.
jg_memory_sampler_tick_home() {
  JG_HOME=$1 STATE=$2 CONFIG=$3
  SAMPLER_DIR=${JG_HOST_MEMORY_FORK_BIN:-${MEMORY_SAMPLER_PATH%/*}}
  [ -d "$STATE" ] && [ -d "$SAMPLER_DIR" ] || return 3
  # shellcheck source=bin/jg-wake-lib.sh
  . "$SAMPLER_DIR/jg-wake-lib.sh"
  watcher=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  jg_pid_alive "$watcher" && jg_watcher_lock_matches_pid "$STATE" "$SAMPLER_DIR/jg-watch.sh" "$watcher" "$JG_HOME" || return 3
  trap 'exit 0' HUP INT TERM
  jg_memory_sampler_tick
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  case "${1:-}:$#" in
    tick:4) jg_memory_sampler_tick_home "$2" "$3" "$4"; exit $? ;;
    run:1) ;;
    run:4) ;; # run HOME STATE CONFIG: this home is registered first, then the one shared loop runs
    *) exit 2 ;;
  esac
  SAMPLER_DIR=${JG_HOST_MEMORY_FORK_BIN:-${MEMORY_SAMPLER_PATH%/*}}
  [ "$#" -ne 4 ] || { [ -d "$3" ] || exit 1; jg_memory_sampler_register "$2" "$3" "$4" "$SAMPLER_DIR" || exit 1; }
  STATE=${JG_STATE_OVERRIDE:-}
  # shellcheck source=bin/jg-wake-lib.sh
  . "$SAMPLER_DIR/jg-wake-lib.sh"
  machine=$(jg_memory_machine_dir)
  mkdir -p "$machine/homes" || exit 1
  jg_lock_try_acquire "$machine/lock" || exit 0
  trap jg_memory_sampler_cleanup EXIT
  trap 'exit 0' HUP INT TERM
  identity=$(jg_pid_identity "$$") || exit 1
  printf '%s\t%s\n' "$$" "$identity" > "$machine/pid.$$" || exit 1
  mv "$machine/pid.$$" "$machine/pid" || exit 1
  secs=${JG_HOST_MEMORY_SECS:-}
  case "$secs" in ''|*[!0-9]*|0) secs=10 ;; esac
  limit=
  command -v timeout >/dev/null 2>&1 && limit="timeout -k 5 ${JG_HOST_MEMORY_TICK_LIMIT:-60}"
  while [ -d "$SAMPLER_DIR" ]; do
    start=$(date +%s)
    served=0
    for record in "$machine/homes"/*; do
      [ -f "$record" ] || continue
      IFS=$'\t' read -r home state config bindir < "$record" || { rm -f "$record"; continue; }
      served=1
      # shellcheck disable=SC2086 # $limit is a command prefix or empty.
      env JG_HOME="$home" JG_STATE_OVERRIDE="$state" JG_CONFIG_OVERRIDE="$config" JG_HOST_MEMORY_FORK_BIN="$bindir" \
        $limit "$MEMORY_SAMPLER_PATH" tick "$home" "$state" "$config" </dev/null
      [ "$?" -ne 3 ] || rm -f "$record" "$state/.host-memory-sampler.pid"
    done
    [ "$served" -eq 1 ] || break
    remaining=$((secs - ($(date +%s) - start)))
    if [ "$remaining" -gt 0 ]; then sleep "$remaining" & wait "$!" || true; fi
  done
fi
