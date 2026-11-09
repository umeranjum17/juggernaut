# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/jg-supervision-lib.sh
#
# Reports whether a juggernaut home needs supervision (jg_supervision_status
# below is the single owner of that condition set), and whether its watcher has
# a fresh liveness beacon (state/.last-watcher-beat, touched every poll cycle,
# within the grace window).
# bin/jg-turnend-guard.sh uses the PID-strict jg_watcher_healthy from
# bin/jg-wake-lib.sh for its block decision. bin/jg-guard.sh uses the model-aware
# jg_watcher_supervision_verdict (also in bin/jg-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

_JG_SUP_BIN=${BASH_SOURCE[0]%/*}

# jg_ready_work_rows <home>
# Prints one "<id> <repo>" line per ready backlog item of <home> (the backlog
# ready: queued, not blocked, not held), highest priority first (P0 before P4,
# an unprioritized item last, ties by id); <repo> is "-" for an item that names
# none. Returns the ready read's own status so a caller can tell an empty queue
# from an unreadable one.
jg_ready_work_rows() {
  local home=$1 out rc prios
  out=$(JG_HOME="$home" "$_JG_SUP_BIN/jg-backlog.sh" ready 2>/dev/null); rc=$?
  prios=$(JG_HOME="$home" "$_JG_SUP_BIN/jg-backlog.sh" list --state queued --fields priority 2>/dev/null) || prios=
  awk '
    NR == FNR {
      if ($0 ~ /^  /) {
        line = $0; sub(/^  /, "", line)
        id = line; sub(/,.*/, "", id)
        pr = line; sub(/.*,/, "", pr); gsub(/"/, "", pr)
        prio[id] = (pr ~ /^[0-9]+$/) ? pr : 9
      }
      next
    }
    /^ready\[[0-9]+\]/ { on = 1; next }
    on && /^  / {
      sub(/^  /, ""); split($0, f, ","); repo = f[4]; gsub(/"/, "", repo)
      print ((f[1] in prio) ? prio[f[1]] : 9), f[1], (repo == "" ? "-" : repo); next
    }
    { on = 0 }' <(printf '%s\n' "$prios") <(printf '%s\n' "$out") | sort -k1,1n -k2,2 | awk '{ print $2, $3 }'
  return "$rc"
}

# jg_ready_work_ids <home>
# The ids of jg_ready_work_rows, space-joined in the same order, with its status.
jg_ready_work_ids() {
  local rows rc
  rows=$(jg_ready_work_rows "$1"); rc=$?
  printf '%s\n' "$rows" | awk 'NF { print $1 }' | paste -sd ' ' -
  return "$rc"
}

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
jg_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# jg_squad_lead_ready_work <state-dir>
# Prints the ready backlog ids and returns 0 only for a squad_lead home with some.
# The main home and a squad_lead with an empty queue stay idle: nothing is invented.
jg_squad_lead_ready_work() {
  local home=${JG_HOME:-${1%/*}} marker ids
  if declare -F jg_compat_marker >/dev/null; then marker=$(jg_compat_marker "$home"); else marker=$home/.jg-squad-lead-home; fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  ids=$(jg_ready_work_ids "$home") && [ -n "$ids" ] || return 1
  printf '%s\n' "$ids"
}

# jg_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   JG_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   JG_SUP_SOURCES        count of registered process-to-event sources
#   JG_SUP_CHECKS         count of registered custom checks: a state/<id>.check.sh
#                         with the state/<id>.check-trust binding that
#                         bin/jg-check-register.sh writes. Task PR polls carry no
#                         such binding and are torn down with their task, and the
#                         relay shim keeps its own trust path, so neither counts
#                         here. Presence of the binding is the whole test: whether
#                         those bytes are still the registered ones is the check
#                         sweep's call at execution time, and a home whose check
#                         no longer validates needs the watcher precisely so the
#                         sweep can report the rejection instead of going quiet.
#   JG_SUP_GOAL_NEXT      count of open Goals whose next step waits for the lead, in any home: the
#                         data/jg-goal-loop/<goal>.next records that core/goal-loop writes when it
#                         wakes the lead and removes when the step is taken. The goal-loop check
#                         itself is not a JG_SUP_CHECKS need, so a home with no Goal needs nothing.
#   JG_SUP_READY_WORK     count of ready backlog items in a squad_lead home with
#                         nothing else needing supervision (else 0); jg_ready_work_ids
#                         owns readiness
#   JG_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         a registered custom check, or ready backlog work in a
#                         squad_lead home, whose idle lead only learns of it from
#                         the watcher's ready-work wake
#   JG_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window, or
#                         a live lock-matched watcher still in its first scan (no
#                         beacon yet, or only its predecessor's older than the
#                         holder's lock claim) younger than the stall bound; needs
#                         bin/jg-wake-lib.sh sourced, else only the beacon counts
#   JG_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   JG_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $JG_GUARD_GRACE, then 300, matching jg-guard.sh.
# Always returns 0; callers read the vars, or use jg_supervision_unhealthy below.
jg_supervision_status() {
  local state=$1 grace=${2:-${JG_GUARD_GRACE:-300}} meta source check id beat m age pid claimed ready
  JG_SUP_IN_FLIGHT=0
  JG_SUP_READY_WORK=0
  JG_SUP_GOAL_NEXT=0
  JG_SUP_NEEDED=false
  JG_SUP_WATCHER_FRESH=false
  JG_SUP_BEACON_DESC=never
  JG_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    JG_SUP_IN_FLIGHT=$((JG_SUP_IN_FLIGHT + 1))
  done
  JG_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    JG_SUP_SOURCES=$((JG_SUP_SOURCES + 1))
  done
  JG_SUP_CHECKS=0
  for check in "$state"/*.check.sh; do
    [ -e "$check" ] || continue
    id=${check##*/}
    id=${id%.check.sh}
    if [ "$id" = x-watch ] || [ "$id" = goal-loop ]; then
      continue
    fi
    [ -e "$state/$id.check-trust" ] || continue
    JG_SUP_CHECKS=$((JG_SUP_CHECKS + 1))
  done
  JG_SUP_GOAL_NEXT=$(find "${JG_HOME:-${state%/*}}/data/jg-goal-loop" -maxdepth 1 -name '*.next' 2>/dev/null | wc -l)
  if [ "$JG_SUP_IN_FLIGHT" -gt 0 ] \
    || [ "$JG_SUP_GOAL_NEXT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$JG_SUP_SOURCES" -gt 0 ] \
    || [ "$JG_SUP_CHECKS" -gt 0 ]; then
    JG_SUP_NEEDED=true
  else
    # shellcheck disable=SC2034 # Read by callers (jg-turnend-guard.sh) after sourcing.
    ready=$(jg_squad_lead_ready_work "$state") && [ -n "$ready" ] \
      && JG_SUP_READY_WORK=$(printf '%s\n' "$ready" | wc -w) && JG_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  m=
  if [ -e "$beat" ]; then
    m=$(jg_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      JG_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && JG_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (jg-guard.sh) after sourcing.
      JG_SUP_BEACON_DESC=unknown
    fi
  fi
  # A live holder that claimed the lock after the last beacon is still in its
  # first scan: the beacon on disk is its predecessor's (a cycle that ended on a
  # wake leaves it, and a long handling turn ages it), and this holder renews it
  # only when the scan finishes. Treat it as fresh until the stall bound, the
  # same bound that evicts a stuck holder. Its own stale beacon is never newer
  # than its claim, so a slow cycle still reads as stale.
  if [ "$JG_SUP_WATCHER_FRESH" = false ] && [ "$JG_SUP_BEACON_DESC" != unknown ] \
    && declare -F jg_watcher_lock_matches_pid >/dev/null; then
    pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    claimed=$(jg_sup_stat_mtime "$state/.watch.lock/pid")
    if [ -z "$m" ] || { [ -n "$claimed" ] && [ "$claimed" -gt "$m" ]; }; then
      if jg_pid_alive "$pid" \
        && jg_watcher_lock_matches_pid "$state" "$JG_WAKE_LIB_DIR/jg-watch.sh" "$pid" "${JG_HOME:-}"; then
        age=$(( $(date +%s) - ${claimed:-0} ))
        if [ "$age" -lt "$(jg_watcher_stall_bound)" ]; then
          # shellcheck disable=SC2034 # Read by callers (jg-guard.sh) after sourcing.
          JG_SUP_BEACON_DESC="starting (${age}s)"
          JG_SUP_WATCHER_FRESH=true
        fi
      fi
    fi
  fi

  # An always-on squad lead daemon (jg-wake-lib.sh) owns supervision between its
  # one-shot watcher cycles, so no watcher process holds the lock and nothing is
  # wrong: a live daemon with a fresh beacon is supervised.
  if [ "$JG_SUP_WATCHER_FRESH" = false ] && declare -F jg_lead_daemon_supervising >/dev/null \
    && jg_lead_daemon_supervising "$state"; then
    # shellcheck disable=SC2034 # Read by callers (jg-guard.sh) after sourcing.
    JG_SUP_BEACON_DESC="lead daemon (${JG_SUP_BEACON_DESC})"
    JG_SUP_WATCHER_FRESH=true
  fi

  # A cycle that ended on a wake leaves a fresh beacon, but its replacement
  # clears it at start and writes none until its scan finishes. The hand-off
  # stamp the ending cycle left (jg-watch.sh) keeps that gap healthy for
  # JG_WATCHER_HANDOFF_SECS (default 60); a watcher that really died stops
  # restamping, so it is reported once the stamp is older.
  if [ "$JG_SUP_WATCHER_FRESH" = false ] && [ ! -e "$beat" ] && [ -e "$state/.last-watcher-handoff" ]; then
    m=$(jg_sup_stat_mtime "$state/.last-watcher-handoff")
    age=$(( $(date +%s) - ${m:-0} ))
    if [ "$age" -lt "${JG_WATCHER_HANDOFF_SECS:-60}" ]; then
      # shellcheck disable=SC2034 # Read by callers (jg-guard.sh) after sourcing.
      JG_SUP_BEACON_DESC="hand-off (${age}s)"
      JG_SUP_WATCHER_FRESH=true
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (jg-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && JG_SUP_QUEUE_PENDING=true
  return 0
}

# jg_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
jg_supervision_needed() {
  jg_supervision_status "$@"
  [ "$JG_SUP_NEEDED" = true ]
}

# jg_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
jg_supervision_unhealthy() {
  jg_supervision_status "$@"
  [ "$JG_SUP_NEEDED" = true ] && [ "$JG_SUP_WATCHER_FRESH" = false ]
}
