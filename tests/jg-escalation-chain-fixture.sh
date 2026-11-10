#!/usr/bin/env bash
# The stuck-worker escalation chain (core/wait-timers/README.md): a stuck
# operator goes to its owning lead, a stuck lead goes to Main, and only what
# Main cannot settle becomes a board card; every rung fires again while the
# wait stays open. Real watcher and drain cycles over a copy of this checkout's
# bin/ and features; only the terminal, the board, and the steer and interrupt
# endpoints are recorders. One test per scenario row.
set -eu

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-escalation-chain)
FORK="$TMP_ROOT/fork"
mkdir -p "$FORK"
# toolchain.versions pins the bd and dolt that the copied backlog scripts run.
cp -a "$ROOT/bin" "$ROOT/core" "$ROOT/toolchain.versions" "$FORK/"
# The steer and interrupt endpoints record their calls in the calling home. A home
# holding a real-steer file also delivers each steer through the real jg-send (kept
# as jg-send-real.sh), so its inbox records and decision closes are the real ones.
cp "$FORK/bin/jg-send.sh" "$FORK/bin/jg-send-real.sh"
for f in jg-send.sh jg-control.sh; do
  # shellcheck disable=SC2016 # the recorder expands its own arguments when run
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "$JG_HOME/sent"\n' "${f%.sh}" > "$FORK/bin/$f"
done
# shellcheck disable=SC2016 # the recorder expands its own arguments when run
printf '[ ! -e "$JG_HOME/real-steer" ] || exec "$(dirname "$0")/jg-send-real.sh" "$@"\n' >> "$FORK/bin/jg-send.sh"

# A home with a recorded terminal (fake:<n> panes listed in $JG_FAKE_PANES,
# each showing $h/panes/<n>, an agent in the foreground) and a recording board.
home() {  # <name> -> home path
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/config" "$h/home" "$h/tmp" "$h/fakebin" "$h/panes"
  : > "$h/config/backlog-intake-loose"
  jg_test_track_watcher_state "$h/state"
  cat > "$h/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
t=; prev=
for a in "$@"; do [ "$prev" = -t ] && t=$a; prev=$a; done
# A killed window stays gone, as it does in a real terminal, so a scan that lands after a cleanup does not see it.
pane_of() { local p=${1#=}; p=${p#fake:}; printf '%s\n' "${p#=}"; }
killed() { grep -Fxq -- "$(pane_of "$1")" "$JG_HOME/killed" 2>/dev/null; }
listed() { killed "$1" && return 1; case " ${JG_FAKE_PANES:-} " in *" $(pane_of "$1") "*) return 0 ;; esac; return 1; }
case "${1:-}" in
  list-windows) for p in ${JG_FAKE_PANES:-}; do killed "$p" || printf '%s\n' "$p"; done ;;
  kill-window|kill-pane) pane_of "$t" >> "$JG_HOME/killed"; exit 0 ;;
  capture-pane) listed "$t" || exit 1; cat "$JG_HOME/panes/${t#fake:}" 2>/dev/null || printf 'all quiet\n> \n' ;;
  display-message)
    listed "$t" || exit 1
    case "$*" in *pane_tty*) printf '/dev/pts/fake\n' ;; *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
  *) exit 1 ;;
esac
SH
  cat > "$h/fakebin/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -t "*) printf '  100   100   100 claude\n'; exit 0 ;; esac
for p in /bin/ps /usr/bin/ps; do [ ! -x "$p" ] || exec "$p" "$@"; done
exit 1
SH
  cat > "$h/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
log="$JG_HOME/cards"
case "${1:-}" in
  raise)
    key=; prev=
    for a in "$@"; do [ "$prev" = --key ] && key=$a; prev=$a; done
    printf 'raise %s\n' "$*" >> "$log"
    grep -Fxq "$key" "$log.open" 2>/dev/null || printf '%s\n' "$key" >> "$log.open" ;;
  list) printf '{"decisions":[%s]}\n' "$(sed 's/.*/{"key":"&"}/' "$log.open" 2>/dev/null | paste -sd, -)" ;;
  dismiss)
    printf 'dismiss %s\n' "$2" >> "$log"
    { grep -Fxv "$2" "$log.open" 2>/dev/null || true; } > "$log.tmp"; mv "$log.tmp" "$log.open" ;;
esac
SH
  # The forge read: prints the recorded answer (state, draft, merge state, head) or fails.
  cat > "$h/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$JG_HOME/gh.log"
[ -s "$JG_HOME/gh-answer" ] || exit 1
cat "$JG_HOME/gh-answer"
SH
  chmod +x "$h/fakebin/"*
  printf '%s\n' "$h"
}

# One watcher cycle; Main drains and acknowledges its wakes unless absent.
# While Main is absent the next cycle is the successor the arm path starts
# over its unread wakes, which keeps supervising instead of re-announcing them.
#
# A cycle keeps the four-second budget it always had, minus its one hard edge: it
# never stops inside a scan. A scan that overruns the budget (a loaded runner) is
# allowed to finish, so the wake it was about to report is not lost with it. The
# watcher publishes scan-complete after each complete scan, so the wait ends at
# a scan boundary instead of in the middle of one.
cycle() {  # <home> [absent]
  local h=$1 rc=0 seq gen pid successor=0 mark
  [ "${2:-}" != absent ] || successor=1
  mark="$h/tmp/cycle-mark"
  touch "$mark"
  env -u JG_TASK_ID JG_WATCH_HANDLING_SUCCESSOR="$successor" HOME="$h/home" XDG_DATA_HOME="$h/home/.local/share" TMPDIR="$h/tmp" PATH="$h/fakebin:$PATH" \
    JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_CONFIG_OVERRIDE="$h/config" \
    JG_POLL=1 JG_SIGNAL_GRACE=1 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS="${LIVENESS:-99999999}" JG_BUSY_TURN_MAX_SECS=999999 JG_STALE_ESCALATE_SECS=999999 \
    JG_SQUAD_LEAD_WAKE_STALL_SECS=999999 JG_WAIT_ALERT_SECS="${ALERT_SECS:-2}" JG_WAIT_ESCALATE_SECS="${ESCALATE_SECS:-4}" JG_WAIT_CARD_SECS="${CARD_SECS:-6}" \
    JG_READY_STALL_POLL_SECS=0 JG_GREEN_PR_POLL_SECS=0 \
    JG_PROMPT_REALERT_SECS=900 JG_FAKE_PANES="${PANES:-}" "$FORK/bin/jg-watch.sh" > "$h/out" 2> "$h/err" &
  pid=$!
  wait_for_scan "$pid" "$h/state" "$mark" "${CYCLE_POLLS:-40}" "${CYCLE_POLLS_MAX:-600}" || rc=$?
  case "$rc" in 0|124) ;; *) fail "watcher failed ($rc): $(cat "$h/err")" ;; esac
  cat "$h/out" >> "$h/events"
  [ "${2:-}" != absent ] || return 0
  JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" "$FORK/bin/jg-wake-drain.sh" > "$h/drain" 2> "$h/ack"
  # The wake queue is the delivery; the line the watcher prints is its doorbell.
  # A cycle that is stopped between queueing a wake and printing it (the stop
  # lands inside a scan on a loaded runner) still delivered it: Main's drain holds
  # the row. Count every drained wake as delivered to Main, once.
  awk -F '\t' 'NF >= 5 && $1 ~ /^[0-9]+$/ && $3 ~ /^(signal|stale|check|heartbeat)$/ { print $5 }' "$h/drain" \
    | while IFS= read -r line; do grep -Fxq -- "$line" "$h/events" || printf '%s\n' "$line" >> "$h/events"; done
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$h/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$h/ack")
  [ -z "$seq" ] || JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" "$FORK/bin/jg-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}

# A cycle stops at its first wake, so a home holding two open waits can report
# the other one first. Repeat bounded cycles until the wanted line is visible;
# the caller's assertion still reports the miss with its full evidence.
cycle_until() {  # <home> <extended-regex> [absent]
  local h=$1 want=$2 absent=${3:-} n=0
  while [ "$n" -lt "${CYCLE_TRIES:-8}" ]; do
    n=$((n + 1))
    cycle "$h" "$absent"
    grep -qE "$want" "$h/events" && return 0
  done
  return 0
}

# Wait for one owned watcher cycle. Return its exit status when the watcher
# reports a wake. Otherwise stop it after <budget> hundred-millisecond polls, or
# after <limit> polls when a scan that was already running crossed that budget:
# that scan finishes and the cycle ends on its completion marker, not inside it.
wait_for_scan() {  # <pid> <state> <mark> <budget> <limit>
  local pid=$1 state=$2 mark=$3 budget=${4:-40} limit=${5:-600} i=0
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || break
    # Ignore scans completed before the budget; another scan may be under way.
    [ "$i" -ne "$budget" ] || touch "$mark"
    if [ "$i" -ge "$budget" ] && [ "$state/.watch.lock/scan-complete" -nt "$mark" ]; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    # A loaded runner takes a moment to run the watcher's own exit trap, and a
    # KILL there leaves the next cycle on a lock nothing released.
    while [ "$i" -lt 50 ] && is_live_non_zombie "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
    if is_live_non_zombie "$pid"; then
      printf 'wait_for_scan: owned pid %s survived TERM; sending KILL\n' "$pid" >&2
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  wait "$pid"
}

# Make every terminal read in <home> cost <secs> of wall clock, the way a loaded
# CI runner's does, so a scan takes longer than any fixed cycle delay.
slow_panes() {  # <home> <secs>
  local t="$1/fakebin/tmux"
  mv "$t" "$t.real"
  # shellcheck disable=SC2016 # the wrapper expands its own arguments when run
  printf '#!/usr/bin/env bash\nsleep %s\n[ ! -e "$JG_HOME/state/.last-watcher-beat" ] || [ -e "$JG_HOME/state/.watch.lock/scan-complete" ] || touch "$JG_HOME/progress-before-completion"\nexec "$(dirname "$0")/tmux.real" "$@"\n' "$2" > "$t"
  chmod +x "$t"
}

lead_meta() {  # <home> <id> <pane> <lead-home> [harness]
  printf 'kind=squad_lead\nmode=squad_lead\nbackend=tmux\nwindow=fake:%s\nharness=%s\nhome=%s\n' "$3" "${5:-claude}" "$4" > "$1/state/$2.meta"
  : > "$1/state/$2.status"
  prime_status_seen "$1/state" "$1/state/$2.status"
}

# Move every recorded time of an episode back by <secs>, as if it had waited.
backdate() {  # <home> <task> <secs>
  local f="$1/state/.waiting-timers/$2" sig since owner parent key misses card last v out=()
  IFS=$'\t' read -r sig since owner parent key misses card last < "$f"
  for v in "$since" "$owner" "$parent" "${card:-0}" "${last:-0}"; do
    if [ "$v" -gt 1 ]; then out+=("$((v - $3))"); else out+=("$v"); fi
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sig" "${out[0]}" "${out[1]}" "${out[2]}" "$key" "${misses:-0}" "${out[3]}" "${out[4]}" > "$f"
}

# What the owning lead appends to Main's state/<lead>.status when its worker's
# wait is overdue (the parent channel), stamped <age> seconds ago.
overdue_report() {  # <main> <lead> <worker> <age>
  local since=$(($(date +%s) - $4))
  printf 'blocked [key=waiting-timer-0000aaaa-%s-g%s-q]: waiting-timer-overdue: %s (needs-decision key=q, observed %ss, since=%s); owning lead has not cleared the wait; Main must unblock or steer the lead; source=[needs-decision [key=q]: pick a database]\n' \
    "$3" "$since" "$3" "$4" "$since" >> "$1/state/$2.status"
  prime_status_seen "$1/state" "$1/state/$2.status"
}

# A lead fixture has the required check that a provisioned lead home carries.
wire_lead_check() {  # <home>
  local h=$1
  mkdir -p "$h/core"
  cp -a "$FORK/core/trunk-latency" "$h/core/"
  cp -a "$FORK/bin" "$h/bin"
  XDG_DATA_HOME="$h/home/.local/share" HOME="$h/home" JG_HOME="$h" \
    bash "$h/core/trunk-latency/wiring.sh" "$h" >/dev/null
}

# A lead home bound to <main> on the local parent channel, with a backlog.
lead_home() {  # <name> <main> -> lead home path
  local l
  l=$(home "$1")
  mkdir -p "$l/data"
  wire_lead_check "$l"
  printf 'lead1\n' > "$l/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$2" > "$l/.jg-squad-lead-parent"
  printf '%s\n' "$l"
}

# A home's backlog is a real Beads store, built on first use; its item ids carry the store's prefix.
backlog() {  # <home> <backlog args...>
  local h=$1
  shift
  [ -s "$h/config/beads-dir" ] || jg_test_beads_home "$h"
  JG_HOME="$h" "$FORK/bin/jg-backlog.sh" "$@" >/dev/null || fail "fixture: tasks $*"
}

# Move the stalled-backlog episode's start and last fire back by <secs>.
backdate_backlog() {  # <home> <secs>
  local f="$1/state/.waiting-timers/.ready-backlog" since lanes key reported last
  IFS=$'\t' read -r since lanes key reported last < "$f"
  [ "$reported" -eq 0 ] || reported=$((reported - $2))
  [ "$last" -eq 0 ] || last=$((last - $2))
  printf '%s\t%s\t%s\t%s\t%s\n' "$((since - $2))" "$lanes" "$key" "$reported" "$last" > "$f"
}

# A ship task whose PR is recorded ready: pr=, yolo and an armed merge poll.
pr_task() {  # <home> <id> <yolo> [head]
  local pr=https://github.com/octo/widgets/pull/7
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\npr=%s\nyolo=%s\n' "$pr" "$3" > "$1/state/$2.meta"
  printf 'done [at=1]: PR %s\n' "$pr" > "$1/state/$2.status"
  prime_status_seen "$1/state" "$1/state/$2.status"
  : > "$1/state/$2.check.sh"
  touch "$1/state/.last-check"
  forge "$1" OPEN false CLEAN "${4:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
}

forge() {  # <home> <state> <draft> <merge-state> <head>
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" > "$1/gh-answer"
}

# Move the green-PR clock back by <secs>, as if the PR had waited unmerged.
backdate_green() {  # <home> <task> <secs>
  local f="$1/state/.green-pr/$2" checked since head url
  IFS=$'\t' read -r checked since head url < "$f"
  printf '%s\t%s\t%s\t%s\n' "$checked" "$((since - $3))" "$head" "$url" > "$f"
}


# Used by the sourced test files.
# shellcheck disable=SC2034
TRUST=$'Quick safety check: Is this a project you created or one you trust?\n  1. Yes, I trust this folder\n  2. No, exit\nEnter to confirm'

# A stand-in for jg-crew-state.sh that reports every lane as working on its pane.
working_crew_state() {  # <home> -> path
  printf '#!/usr/bin/env bash\nprintf "state: working source: pane\\n"\n' > "$1/fakebin/crew-state-working"
  chmod +x "$1/fakebin/crew-state-working"
  printf '%s\n' "$1/fakebin/crew-state-working"
}


cycle_for() {  # <home> <secs> <command...>
  local h=$1 end=$((SECONDS + $2))
  shift 2
  while ! "$@"; do
    [ "$SECONDS" -lt "$end" ] || return 0
    PANES='1 2 3 4 5 6' cycle "$h"
  done
}
