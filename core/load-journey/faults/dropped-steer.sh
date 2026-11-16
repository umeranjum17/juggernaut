# shellcheck shell=bash
# Fault: a steer to a lane was read and never answered (the message was dropped on the way). Owner of the recovery:
# core/wait-timers (its tick raises one stuck-wait alert to the lead). Sourced by bin/jg-load-journey.sh.
fault_inject() {  # <home> <lane>
  local home=$1 lane=$2 now; now=$(date +%s)
  printf '%s\n' "$((now - 200000))" > "$home/state/.overdue-steers.since"   # the watermark the steer must follow
  printf 'kind=ship\n' > "$home/state/$lane.meta"
  mkdir -p "$home/state/$lane.inbox/handled"
  printf 'schema=jg-task-inbox.v1\n--\nhello\n' > "$home/state/$lane.inbox/handled/001.msg"
  printf '{"seq":1,"word":"stored","at":%d}\n{"seq":1,"word":"rung","at":%d}\n' "$((now - 1200))" "$((now - 1200))" \
    >> "$home/state/$lane.inbox/.delivery.jsonl"
}
fault_recover() {  # <home>: one tick of the wait timers, as the watcher runs it
  rm -f "$1/state/.overdue-steers.at"   # the pass runs once per 300 s
  # shellcheck disable=SC2153 # JGL_ROOT is exported by bin/jg-load-journey.sh
  ( export JG_HOME=$1 JG_STATE_OVERRIDE=$1/state JG_CONFIG_OVERRIDE=$1/config SCRIPT_DIR=$JGL_ROOT/bin
    # shellcheck source=bin/jg-wake-lib.sh
    . "$JGL_ROOT/bin/jg-wake-lib.sh"
    # shellcheck source=core/wait-timers/bin/jg-wait-timers-lib.sh
    . "$JGL_ROOT/core/wait-timers/bin/jg-wait-timers-lib.sh"
    jg_wait_timers_tick ) >/dev/null 2>&1
}
fault_recovered() {  # <home> <lane>: the dropped steer has its one alert
  [ -n "$(JG_HOME=$1 "$JGL_ROOT/bin/jg-alert.sh" word "stuck-wait--$2-msg-001" 2>/dev/null)" ]
}
