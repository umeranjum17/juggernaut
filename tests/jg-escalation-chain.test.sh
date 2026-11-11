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
# watcher publishes scan completion after each complete scan, so the wait ends at
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

# A lead home bound to <main> on the local parent channel, with a backlog.
lead_home() {  # <name> <main> -> lead home path
  local l
  l=$(home "$1")
  mkdir -p "$l/data"
  # A real lead has this required check registered; without it the repair wake
  # ends the first watcher cycle before the backlog timer can run.
  printf '#!/usr/bin/env bash\nexec %q check %q\n' "$FORK/core/trunk-latency/latency.sh" "$l" > "$l/state/trunk-latency.check.sh"
  chmod 700 "$l/state/trunk-latency.check.sh"
  JG_HOME="$l" "$FORK/bin/jg-check-register.sh" trunk-latency >/dev/null
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

# A finished ship task on a local-only branch: its work is on the branch, and
# <landed> says whether the project's main already holds it. The treehouse
# return is a recorder; the landed-work test is the real teardown's own.
finished_task() {  # <home> <id> <landed: yes|no>; its pane is jg-<id>, the name teardown requires
  local h=$1 id=$2 pane=jg-$2 p="$1/proj-$2" wt="$1/wt-$2"
  jg_git_identity fmtest fmtest@example.invalid
  mkdir -p "$h/data"
  # A teardown closes the task's backlog item, as a spawned task is In flight in the store.
  jg_test_beads_home "$h"
  jg_test_add "$h" "$id" "[feature] escalation-chain finished-task fixture"
  jg_test_backlog "$h" start "$id" >/dev/null
  git init -q -b main "$p"
  git -C "$p" commit -q --allow-empty -m baseline
  git -C "$p" worktree add -q -b "fm/$id" "$wt" main
  git -C "$wt" commit -q --allow-empty -m "the work"
  [ "$3" != yes ] || git -C "$p" merge -q --ff-only "fm/$id"
  printf '#!/usr/bin/env bash\nprintf "return %%s\\n" "$*" >> "%s/treehouse.log"\n' "$h" > "$h/fakebin/treehouse"
  chmod +x "$h/fakebin/treehouse"
  printf 'kind=ship\nmode=local-only\nbackend=tmux\nharness=claude\nwindow=fake:%s\nworktree=%s\nproject=%s\nendpoint_task_id=%s\nspawn_gen=%s-gen\n' \
    "$pane" "$wt" "$p" "$id" "$id" > "$h/state/$id.meta"
  printf 'done [at=1]: ready branch fm/%s\n' "$id" > "$h/state/$id.status"
  prime_status_seen "$h/state" "$h/state/$id.status"
}

# Every wake Main drained in <home>, as the reason text it was given.
test_a_stale_wake_names_its_task_and_reason() {
  local m
  m=$(home stale-names)
  # A worker stopped on a trust dialog, and a worker that exited after its last line.
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=claude\n' > "$m/state/stuck1.meta"
  printf 'working [at=1]: building\n' > "$m/state/stuck1.status"
  prime_status_seen "$m/state" "$m/state/stuck1.status"
  printf '%s\n' "$TRUST" > "$m/panes/1"
  PANES=1 cycle "$m"
  grep -qE '^stale: fake:1 \(permission prompt: .*\) \[task=stuck1 reason=permission\]$' "$m/events" \
    || fail "the prompt wake did not name its task and reason: $(cat "$m/events")"
  # The queued row Main drained carries the same words as the doorbell line.
  grep -qF '[task=stuck1 reason=permission]' "$m/drain" || fail "the queued wake lacks the task and reason: $(cat "$m/drain")"
  # An endpoint no record names still says so instead of guessing a task.
  [ "$(stale_wake_decorate_for "$m" 'stale: default:w9:p9')" = 'stale: default:w9:p9 [task=unknown reason=stopped]' ] \
    || fail "an unrecorded endpoint was mapped to a task"
  pass "a stale wake names the task and the reason, on the doorbell line and in the queued row"
}

stale_wake_decorate_for() {  # <home> <text>
  bash -c '. "$1/bin/jg-classify-lib.sh" && stale_wake_decorate "$2" "$3"' _ "$FORK" "$2" "$1/state"
}

# The watcher cleans a finished worker up detached; its marker says running until the teardown ends. A scan that
# overlaps the teardown's last step sees the pane of a task whose record is already gone, so a case that loops
# over cycles waits the teardown out between them.
settle_cleanup() {  # <home>
  local i=0 f
  while [ "$i" -lt 600 ]; do
    f=$(find "$1/state" -maxdepth 1 -name '.stale-cleanup-*' ! -name '*.log' ! -name '*.next' 2>/dev/null | head -n 1)
    { [ -n "$f" ] && grep -q '^running' "$f" 2>/dev/null; } || return 0
    sleep 0.2
    i=$((i + 1))
  done
}

test_a_finished_landed_worker_is_cleaned_up_without_a_wake() {
  local m n=0
  m=$(home cleanup-landed)
  finished_task "$m" ship-l yes
  while [ "$n" -lt 20 ] && [ -e "$m/state/ship-l.meta" ]; do
    n=$((n + 1))
    PANES=jg-ship-l cycle "$m"
    settle_cleanup "$m"
    sleep 0.3
  done
  [ ! -e "$m/state/ship-l.meta" ] || fail "a finished, landed worker was not cleaned up: $(cat "$m/err" "$m/events" "$m"/state/.stale-cleanup-* 2>&1)"
  grep -q 'return --force' "$m/treehouse.log" || fail "the cleanup did not return the worker's copy: $(cat "$m/treehouse.log" 2>&1)"
  ! grep -q '^stale:' "$m/events" || fail "Main was woken about a worker that was already landed: $(cat "$m/events")"
  ! grep -q $'\tstale\t' "$m/drain" || fail "a stale wake was queued for a landed worker: $(cat "$m/drain")"
  pass "a finished worker whose work has landed is cleaned up with no wake for Main"
}

test_a_finished_unlanded_worker_is_kept_and_wakes_with_its_reason() {
  local m n=0
  m=$(home cleanup-unlanded)
  finished_task "$m" ship-u no
  while [ "$n" -lt 20 ] && ! grep -q '^stale:' "$m/events" 2>/dev/null; do
    n=$((n + 1))
    PANES=jg-ship-u cycle "$m"
    settle_cleanup "$m"
    sleep 0.3
  done
  [ -e "$m/state/ship-u.meta" ] || fail "unlanded work was torn down"
  [ -d "$m/wt-ship-u" ] || fail "the unlanded worktree was removed"
  git -C "$m/proj-ship-u" rev-parse -q --verify refs/heads/fm/ship-u >/dev/null || fail "the unlanded branch was lost"
  [ ! -e "$m/treehouse.log" ] || fail "the unlanded copy was handed back: $(cat "$m/treehouse.log")"
  grep -qE '^stale: fake:jg-ship-u \(finished but not cleaned up: REFUSED.*\) \[task=ship-u reason=finished\]$' "$m/events" \
    || fail "the refused cleanup did not wake with the task and reason: $(cat "$m/events" "$m/state/.stale-cleanup-"* 2>&1)"
  # A refusal is reported once; the next scans neither repeat it nor retry the teardown.
  PANES=1 cycle "$m"
  [ "$(grep -c '^stale:' "$m/events")" -eq 1 ] || fail "the refusal woke Main again: $(cat "$m/events")"
  pass "a finished worker with unlanded work is not torn down and still wakes Main with the task and the refusal"
}

TRUST=$'Quick safety check: Is this a project you created or one you trust?\n  1. Yes, I trust this folder\n  2. No, exit\nEnter to confirm'

test_watcher_handoff_gap_is_not_a_dead_watcher() {
  local m lh
  m=$(home handoff)
  lh="$m/lead-home"
  mkdir -p "$lh/state"
  printf 'kind=ship\n' > "$lh/state/child.meta"
  lead_meta "$m" lead1 1 "$lh"
  # The lead's last cycle just ended on a wake: no beacon, no lock, a fresh hand-off stamp.
  touch "$lh/state/.last-watcher-handoff"
  LIVENESS=1 PANES=1 cycle "$m"
  ! grep -q 'supervision not running' "$m/events" || fail "a watcher between two cycles was reported not running: $(cat "$m/events")"
  [ ! -e "$m/state/.wait-sources/lead1.supervision" ] || fail "the hand-off gap became a wait"
  # A watcher that stopped restamping is dead once the grace has passed.
  touch -d '-5 minutes' "$lh/state/.last-watcher-handoff"
  LIVENESS=1 PANES=1 cycle "$m"
  grep -q 'check: squad_lead lead1 supervision not running' "$m/events" || fail "a truly dead watcher was not reported: $(cat "$m/events") $(cat "$m/err")"
  pass "a lead between two watcher cycles raises no alarm; one whose watcher stopped does"
}

test_lead_idle_is_steered_without_interrupt() {
  local m
  m=$(home lead-idle)
  lead_meta "$m" lead1 1 "$m/lead-home"
  "$FORK/bin/jg-busy-event.sh" arm "$m/state" lead1 --state idle --source claude-hook --event stop >/dev/null
  overdue_report "$m" lead1 w1 0
  PANES=1 cycle "$m"
  grep -q '^jg-send lead1 --fire-and-forget [0-9a-f]\{16\} Your worker w1 has been stuck .*on: needs-decision \[key=q\]: pick a database' "$m/sent" \
    || fail "an idle lead was not told which worker is stuck and on what: $(cat "$m/sent" 2>&1)"
  ! grep -q '^jg-control' "$m/sent" || fail "an idle lead was interrupted"
  [ ! -s "$m/cards" ] || fail "a card was posted before the worker had waited long enough"
  # The nudge fires again every interval while the report stays open.
  f=$(ls "$m/state/.waiting-relay/"*)
  IFS=$'\t' read -r first nudged card < "$f"
  printf '%s\t%s\t%s\n' "$first" "$((nudged - 1000))" "$card" > "$f"
  PANES=1 cycle "$m"
  [ "$(grep -c '^jg-send lead1 ' "$m/sent")" -eq 2 ] || fail "the nudge did not fire again after the interval"
  pass "an idle lead with a stuck worker is steered at once, naming the worker and its wait, and again every interval"
}

test_busy_lead_is_steered_without_interrupt() {
  local m
  m=$(home lead-busy)
  lead_meta "$m" lead1 1 "$m/lead-home"
  "$FORK/bin/jg-busy-event.sh" arm "$m/state" lead1 >/dev/null
  overdue_report "$m" lead1 w1 0
  PANES=1 cycle "$m"
  ! grep -q '^jg-control' "$m/sent" || fail "a busy lead was interrupted: $(cat "$m/sent" 2>&1)"
  sed -n 1p "$m/sent" | grep -q '^jg-send lead1 --fire-and-forget .*Your worker w1' || fail "the busy lead was not told about its worker"
  pass "a lead busy mid-turn is told its worker is blocked, and is not interrupted"
}

test_lead_stuck_on_a_prompt_reaches_the_board() {
  local m
  m=$(home lead-prompt)
  lead_meta "$m" lead1 1 "$m/lead-home"
  printf '%s\n' "$TRUST" > "$m/panes/1"
  PANES=1 cycle "$m"
  grep -q '^stale: fake:1 (permission prompt: claude launch trust dialog; path -; not answered: a trust dialog is never auto-approved)' "$m/events" \
    || fail "Main was not woken at first sight of the lead's prompt: $(cat "$m/events")"
  [ -f "$m/state/.wait-sources/lead1.prompt" ] || fail "the prompt was not handed to the chain"
  backdate "$m" lead1 10
  PANES=1 cycle "$m"
  grep -q 'check: waiting-state lead1 (prompt, .*level=main' "$m/events" || fail "the lead's prompt did not reach Main's rung: $(cat "$m/events")"
  PANES=1 cycle "$m"
  # A stuck worker is Main's to unblock, never a card for the captain
  # (bin/jg-ask-gate-lib.sh rule 2): the chain records the ask for Main instead.
  ! grep -q -- '--key waiting-timer-[0-9a-f]*-lead1-g[0-9]*-prompt-card' "$m/cards" 2>/dev/null \
    || fail "a stuck lead's prompt reached the captain's board: $(cat "$m/cards" 2>&1)"
  grep -q '^- Ask: Unblock stuck lead?' "$m/data/overwatch-decisions.md" 2>/dev/null \
    || fail "the lead's prompt was neither a card nor recorded for Main: $(cat "$m/data/overwatch-decisions.md" 2>&1)"
  [ "$(grep -c "stale: fake:1 (permission prompt" "$m/events")" -eq 1 ] || fail "the gate re-alerted instead of the chain"
  printf 'all quiet\n> \n' > "$m/panes/1"
  PANES=1 cycle "$m"
  PANES=1 cycle "$m"
  [ ! -s "$m/cards" ] || ! grep -q '^raise ' "$m/cards" \
    || fail "a card was raised for a stuck lead: $(cat "$m/cards" 2>&1)"
  grep -q '^- Ask: Unblock stuck lead?' "$m/data/overwatch-decisions.md" 2>/dev/null \
    || fail "the recorded prompt wait disappeared when the prompt was answered"
  [ ! -e "$m/state/.waiting-timers/lead1" ] || fail "the episode outlived the prompt"
  pass "a lead stuck on a prompt wakes Main at once, reaches Main's rung, is recorded for Main's decision, and clears when it is answered"
}

test_dead_lead_still_reaches_the_board_and_relaunch_represents() {
  local m l f
  m=$(home dead-main)
  lead_meta "$m" lead1 1 "$m/lead-home"
  overdue_report "$m" lead1 w1 100
  PANES='' cycle "$m"
  grep -q '^jg-send lead1 .*Your worker w1' "$m/sent" || fail "a dead lead got no durable steer"
  ! grep -q '^jg-control' "$m/sent" || fail "a dead lead was interrupted"
  ! grep -q -- '--key waiting-timer-0000aaaa-w1-.*-q-card' "$m/cards" 2>/dev/null \
    || fail "a worker's question went to the captain's board: $(cat "$m/cards" 2>&1)"
  grep -q '^- Ask: ' "$m/data/overwatch-decisions.md" 2>/dev/null \
    || fail "an unsettled wait was not recorded for Main to decide"
  # The relaunched lead re-presents its open waits on its first cycle.
  l=$(home dead-lead)
  printf 'lead1\n' > "$l/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$m" > "$l/.jg-squad-lead-parent"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$l/state/w1.meta"
  printf 'needs-decision [key=q]: pick a database\n' > "$l/state/w1.status"
  prime_status_seen "$l/state" "$l/state/w1.status"
  printf 'session-one\n' > "$l/state/.lock-session"
  # A lead home has its required check installed before supervision starts.
  cp -a "$FORK/bin" "$l/bin"
  mkdir -p "$l/core"
  cp -a "$FORK/core/trunk-latency" "$l/core/"
  HOME="$l/home" JG_HOME="$l" bash "$l/core/trunk-latency/wiring.sh" "$l" >/dev/null
  PANES=1 cycle "$l"
  backdate "$l" w1 10
  PANES=1 cycle "$l"
  backdate "$l" w1 10
  PANES=1 cycle "$l"
  f="$m/state/lead1.status"
  [ "$(grep -c 'waiting-timer-overdue: w1 ' "$f")" -eq 2 ] || fail "the lead did not report its overdue worker: $(cat "$f")"
  : > "$l/events"
  printf 'session-two\n' > "$l/state/.lock-session"
  PANES=1 cycle "$l"
  [ "$(grep -c 'waiting-timer-overdue: w1 ' "$f")" -eq 3 ] || fail "the relaunched lead did not re-report its stuck worker to Main: $(cat "$f")"
  grep -q 'check: waiting-state w1 (needs-decision key=q, .*level=owner; still open, owning lead must recheck' "$l/events" \
    || fail "the relaunched lead was not re-presented its stuck worker in one cycle: $(cat "$l/events")"
  pass "a dead lead's stuck worker still reaches the board, and after relaunch the lead re-presents it within one cycle"
}

test_lead_supervision_not_running_is_a_main_wait() {
  local m lh
  m=$(home sup-main)
  lh="$m/lead-home"
  mkdir -p "$lh/state"
  printf 'kind=ship\n' > "$lh/state/child.meta"
  lead_meta "$m" lead1 1 "$lh"
  LIVENESS=1 PANES=1 cycle "$m"
  grep -q 'check: squad_lead lead1 supervision not running' "$m/events" || fail "a lead with work and no watcher was not a Main event: $(cat "$m/events") $(cat "$m/err")"
  grep -q '^jg-send lead1 --fire-and-forget .*Re-arm your supervision' "$m/sent" || fail "the lead was not told to re-arm"
  backdate "$m" lead1 10
  LIVENESS=1 PANES=1 cycle "$m"
  grep -q 'check: waiting-state lead1 (supervision, .*level=main' "$m/events" || fail "the dead hop did not escalate on the chain: $(cat "$m/events")"
  touch "$lh/state/.last-watcher-beat"
  LIVENESS=1 PANES=1 cycle "$m"
  LIVENESS=1 PANES=1 cycle "$m"
  [ ! -e "$m/state/.wait-sources/lead1.supervision" ] || fail "the wait stayed after the lead's watcher came back"
  [ ! -e "$m/state/.waiting-timers/lead1" ] || fail "the episode stayed after the lead's watcher came back"
  pass "a lead whose own supervision is down is a Main wait that escalates until its watcher is back"
}

test_worker_dead_prompt_and_question_differ() {
  local m
  m=$(home worker-kinds)
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=claude\n' > "$m/state/wp.meta"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:2\nharness=claude\n' > "$m/state/wq.meta"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:3\nharness=claude\n' > "$m/state/wd.meta"
  printf '%s\n' "$TRUST" > "$m/panes/1"
  printf 'needs-decision [key=q]: pick a database\n' > "$m/state/wq.status"
  : > "$m/state/wp.status"; : > "$m/state/wd.status"
  for f in wp wq wd; do prime_status_seen "$m/state" "$m/state/$f.status"; done
  # A prompt recorded before the worker died is no longer seen by the gate.
  mkdir -p "$m/state/.wait-sources"
  printf 'prompt: claude launch trust dialog; path -\n' > "$m/state/.wait-sources/wd.prompt"
  touch -d '-10 minutes' "$m/state/.wait-sources/wd.prompt"
  PANES='1 2' cycle "$m"
  grep -q '^stale: fake:1 (permission prompt' "$m/events" || fail "a worker on a prompt did not wake Main at first sight"
  # The prompt on pane 1 is still an open wait at Main's rung, and a cycle stops
  # at its first wake, so the question's own rung is reached on a later scan.
  backdate "$m" wq 10
  PANES='1 2' cycle_until "$m" 'waiting-state wq \(needs-decision key=q, .*level=owner'
  grep -q 'check: waiting-state wq (needs-decision key=q, .*level=owner' "$m/events" || fail "an open question did not reach its owner: $(cat "$m/events")"
  PANES='1 2' cycle "$m"
  ! grep -q 'waiting-state wd ' "$m/events" || fail "a dead worker's lapsed prompt rode the chain"
  [ ! -e "$m/state/.waiting-timers/wd" ] || fail "a dead worker kept a wait episode"
  pass "a prompt wakes Main at first sight, an open question rides the owner rung, and a dead worker's old prompt lapses"
}

test_two_hops_stuck_at_once() {
  local m
  m=$(home two-hops)
  lead_meta "$m" lead1 1 "$m/lead-home"
  printf '%s\n' "$TRUST" > "$m/panes/1"
  overdue_report "$m" lead1 w1 100
  PANES=1 cycle "$m"
  backdate "$m" lead1 10
  PANES=1 cycle "$m"
  PANES=1 cycle "$m"
  # Neither hop is the captain's card: a stuck worker and a stuck lead are
  # Main's to unblock, so both are recorded for Main's decision.
  ! grep -q -- '--key waiting-timer-[0-9a-f]*-lead1-.*-prompt-card' "$m/cards" 2>/dev/null \
    || fail "the stuck lead reached the captain's board: $(cat "$m/cards" 2>&1)"
  ! grep -q -- '--key waiting-timer-0000aaaa-w1-.*-q-card' "$m/cards" 2>/dev/null \
    || fail "its stuck worker's question reached the captain's board: $(cat "$m/cards" 2>&1)"
  grep -q '^- Ask: ' "$m/data/overwatch-decisions.md" 2>/dev/null \
    || fail "its stuck worker's wait was not recorded for Main to decide"
  pass "a lead stuck on a prompt and its stuck worker both reach Main's decision, and neither reaches the captain's board"
}

test_main_absent_board_card_still_fires() {
  local m
  m=$(home main-absent)
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=claude\n' > "$m/state/w1.meta"
  printf 'blocked [key=dep]: waiting on the vendor\n' > "$m/state/w1.status"
  prime_status_seen "$m/state" "$m/state/w1.status"
  PANES=1 cycle "$m" absent
  backdate "$m" w1 10
  PANES=1 cycle "$m" absent
  PANES=1 cycle "$m" absent
  PANES=1 cycle "$m" absent
  grep -q 'level=main' "$m/events" || fail "Main's rung never fired: $(cat "$m/events")"
  ! grep -q -- '--key waiting-timer-[0-9a-f]*-w1-.*-dep-card' "$m/cards" 2>/dev/null \
    || fail "a wait Main had not settled went to the captain's board: $(cat "$m/cards" 2>&1)"
  grep -q '^- Ask: ' "$m/data/overwatch-decisions.md" 2>/dev/null \
    || fail "the unsettled wait was not recorded for Main while it was absent"
  [ -s "$m/state/.wake-queue" ] || fail "the fixture did not keep Main's wakes unread"
  pass "with Main absent and its wakes unread, the unsettled wait is recorded for Main"
}

test_stalled_backlog_wakes_the_lead_and_main_and_refires() {
  local m l f relay first nudged card
  m=$(home backlog-main)
  l=$(lead_home backlog-lead "$m")
  lead_meta "$m" lead1 1 "$l"
  printf '2\n' > "$l/config/lane-target"
  backlog "$l" add jg-alpha "first item" --priority 1
  f="$m/state/lead1.status"
  cycle "$l"
  cycle "$l"
  [ -f "$l/state/.waiting-timers/.ready-backlog" ] || fail "ready work on a free lane armed no episode: $(cat "$l/err")"
  ! grep -q 'waiting-timer-backlog-overdue' "$f" || fail "Main was told before the lead had 10 minutes"
  backdate_backlog "$l" 500
  cycle "$l"
  ! grep -q 'waiting-timer-backlog-overdue' "$f" || fail "Main was told before 10 minutes passed"
  backdate_backlog "$l" 200
  cycle "$l"
  grep -q '^blocked \[key=waiting-timer-[0-9a-f]*-lead1-g[0-9]*-ready-backlog\] \[at=[0-9]*\]: waiting-timer-backlog-overdue: lead1 (ready work jg-alpha, free lanes 0/2 open, nothing started for [0-9]*s' "$f" \
    || fail "a stalled backlog did not reach Main: $(cat "$f") $(cat "$l/err")"
  grep -q '^check: ready backlog stalled: jg-alpha waits with free lanes (0/2 open)' "$l/events" || fail "the lead was not woken again: $(cat "$l/events")"
  cycle "$l"
  [ "$(grep -c 'waiting-timer-backlog-overdue' "$f")" -eq 1 ] || fail "the stall re-fired inside the interval"
  backdate_backlog "$l" 901
  cycle "$l"
  [ "$(grep -c 'waiting-timer-backlog-overdue' "$f")" -eq 2 ] || fail "the stall did not re-fire after the interval: $(cat "$f")"
  [ "$(grep -c '^check: ready backlog stalled' "$l/events")" -eq 2 ] || fail "the lead was not woken on the re-fire"
  # The report itself is Main's event; the next cycle's relay steers the lead.
  PANES=1 CARD_SECS=3600 cycle "$m"
  grep -q 'lead1' "$m/events" || fail "the report raised no Main event: $(cat "$m/events")"
  PANES=1 CARD_SECS=3600 cycle "$m"
  grep -q '^jg-send lead1 --fire-and-forget [0-9a-f]\{16\} You have ready backlog work that can start now, and nothing has started (ready work jg-alpha' "$m/sent" \
    || fail "Main did not steer the lead about its stalled backlog: $(cat "$m/sent" 2>&1) $(cat "$m/err")"
  [ ! -s "$m/cards" ] || fail "a stalled backlog posted a board card before its time: $(cat "$m/cards")"
  # Still open when the card time passes: Main posts the board card.
  relay=$(ls "$m/state/.waiting-relay/"*)
  IFS=$'\t' read -r first nudged card < "$relay"
  printf '%s\t%s\t%s\n' "$((first - 4000))" "$nudged" "$card" > "$relay"
  PANES=1 CARD_SECS=3600 cycle "$m"
  ! grep -q -- '--key waiting-timer-[0-9a-f]*-lead1-g[0-9]*-ready-backlog-card' "$m/cards" 2>/dev/null \
    || fail "a lead's own park-or-retry call went to the captain's board: $(cat "$m/cards" 2>&1)"
  grep -q '^- Ask: Start the stalled' "$m/data/overwatch-decisions.md" 2>/dev/null \
    || fail "a stalled backlog was not recorded for Main to decide"
  backlog "$l" hold jg-alpha --reason "waits on the vendor"
  cycle "$l"
  grep -q '^resolved \[key=waiting-timer-.*-ready-backlog\] \[at=[0-9]*\]: waiting-timer-cleared: lead1 ready backlog: no ready work' "$f" \
    || fail "a held item left Main's report open: $(cat "$f")"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "the episode outlived the condition"
  PANES=1 CARD_SECS=3600 cycle "$m"
  PANES=1 CARD_SECS=3600 cycle "$m"
  [ -z "$(ls "$m/state/.waiting-relay/" 2>/dev/null)" ] || fail "Main kept relaying a cleared stall"
  grep -q '^- Ask: Start the stalled' "$m/data/overwatch-decisions.md" 2>/dev/null \
    || fail "the recorded backlog wait disappeared when the item was held"
  pass "a ready item on a free lane with nothing started for 10 minutes wakes the lead and Main, re-fires every interval, reaches the board, and clears when held"
}

test_stalled_backlog_skips_open_card_and_full_lanes() {
  local m l
  m=$(home card-main)
  l=$(lead_home card-lead "$m")
  printf '1\n' > "$l/config/lane-target"
  backlog "$l" add jg-alpha "first item"
  # The list endpoint returns only open cards, as sign-off-axi does.
  cat > "$l/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != list ] || printf '%s\n' '{"decisions":[{"key":"plan","ticket":"jg-alpha"}]}'
SH
  chmod +x "$l/fakebin/sign-off-axi"
  cycle "$l"
  cycle "$l"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "a ticket with an open card armed a stall"
  cat > "$l/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"decisions":[]}'
SH
  chmod +x "$l/fakebin/sign-off-axi"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$l/state/w1.meta"
  : > "$l/state/w1.status"
  prime_status_seen "$l/state" "$l/state/w1.status"
  PANES=1 cycle "$l"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "a full home armed a stall"
  rm -f "$l/state/w1.meta" "$l/state/w1.status"
  mkdir -p "$l/home/.local/share/jg-fleet-flow"
  cat > "$l/home/.local/share/jg-fleet-flow/jg-flow-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'lead\t1\t0\t1\t0\t0\t0\t1\t0\t0\t0\n'
SH
  chmod +x "$l/home/.local/share/jg-fleet-flow/jg-flow-check.sh"
  cycle "$l"
  cycle "$l"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "the eleven-field lane summary was not counted"
  rm -f "$l/home/.local/share/jg-fleet-flow/jg-flow-check.sh"
  cycle "$l"
  [ -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "a free lane and unheld ticket armed no stall"
  pass "only a free lane and an unheld ticket arm the ready backlog timer"
}

test_stalled_backlog_quiet_when_work_starts_in_time() {
  local m l
  m=$(home start-main)
  l=$(lead_home start-lead "$m")
  printf '2\n' > "$l/config/lane-target"
  backlog "$l" add jg-alpha "first item"
  backlog "$l" add jg-beta "second item"
  cycle "$l"
  backdate_backlog "$l" 1000
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$l/state/w1.meta"
  : > "$l/state/w1.status"
  prime_status_seen "$l/state" "$l/state/w1.status"
  PANES=1 cycle "$l"
  [ ! -e "$m/state/lead1.status" ] || ! grep -q 'waiting-timer-backlog-overdue' "$m/state/lead1.status" \
    || fail "a lead that started work was escalated"
  IFS=$'\t' read -r since lanes _ _ _ < "$l/state/.waiting-timers/.ready-backlog"
  [ "$lanes" = w1 ] && [ $(($(date +%s) - since)) -lt 60 ] || fail "a start did not re-arm the clock: $since $lanes"
  pass "a lead that starts work in time is never escalated, and the start re-arms the clock"
}

test_ship_ready_line_goes_through_the_pr_check() {
  local m
  m=$(home ready-pr)
  printf 'kind=ship\nmode=direct-PR\nbackend=tmux\nwindow=fake:1\nworktree=%s/gone\n' "$m" > "$m/state/w1.meta"
  printf 'done [at=1]: PR https://gitlab.example/g/p/-/merge_requests/3\n' > "$m/state/w1.status"
  PANES=1 cycle "$m"
  grep -q 'the ready PR of w1 was not recorded: error: ' \
    "$m/state/.watch-triage.log" || fail "the watcher did not run the ready line through jg-pr-check: $(cat "$m/state/.watch-triage.log" 2>&1)"
  grep -q '^signal:.*w1.status' "$m/events" || fail "a refused ready line must still wake Main: $(cat "$m/events")"
  pass "a ship's ready line runs through jg-pr-check's named-head gate and still wakes Main"
}

# A stand-in for jg-crew-state.sh that reports every lane as working on its pane.
working_crew_state() {  # <home> -> path
  printf '#!/usr/bin/env bash\nprintf "state: working source: pane\\n"\n' > "$1/fakebin/crew-state-working"
  chmod +x "$1/fakebin/crew-state-working"
  printf '%s\n' "$1/fakebin/crew-state-working"
}

test_stalled_backlog_quiet_without_a_free_lane_or_a_ready_item() {
  local m l crew
  m=$(home full-main)
  l=$(lead_home full-lead "$m")
  crew=$(working_crew_state "$l")
  printf '1\n' > "$l/config/lane-target"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$l/state/w1.meta"
  : > "$l/state/w1.status"
  prime_status_seen "$l/state" "$l/state/w1.status"
  backlog "$l" add jg-alpha "first item"
  JG_CREW_STATE_BIN="$crew" PANES=1 cycle "$l"
  JG_CREW_STATE_BIN="$crew" PANES=1 cycle "$l"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "a home at its floor with a worker working armed a stall"
  grep -q "$(printf '\tlanes-full\t1/1')" "$l/state/.waiting-timers/.ready-backlog-why" \
    || fail "the quiet backlog left no reason: $(cat "$l/state/.waiting-timers/.ready-backlog-why" 2>&1)"
  rm -f "$l/state/w1.meta" "$l/state/w1.status"
  backlog "$l" hold jg-alpha --reason "waits on the vendor"
  cycle "$l"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "a held item armed a stall"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog-why" ] || fail "a home with no ready work kept a quiet reason"
  pass "a worker provably working at the floor, or only a held item, never arms the stalled-backlog chain, and the quiet reason is recorded"
}


test_a_paused_home_silences_its_stalled_backlog_and_rings_when_it_lifts() {
  local m l f before
  m=$(home pause-main)
  l=$(lead_home pause-lead "$m")
  lead_meta "$m" lead1 1 "$l"
  printf '2\n' > "$l/config/lane-target"
  mkdir -p "$l/data"
  backlog "$l" add jg-alpha "first item" --priority 1
  f="$m/state/lead1.status"
  cycle "$l"
  [ -f "$l/state/.waiting-timers/.ready-backlog" ] || fail "ready work on a free lane armed no episode: $(cat "$l/err")"
  backdate_backlog "$l" 1000
  cycle "$l"
  grep -q '^blocked \[key=waiting-timer-[0-9a-f]*-lead1-g[0-9]*-ready-backlog\].*: waiting-timer-backlog-overdue:' "$f" \
    || fail "the unpaused home never reached Main: $(cat "$f") $(cat "$l/err")"
  # Main pauses this home: the stalled backlog goes quiet and its open report closes.
  printf '# Paused for the vendor migration\n\nStop new work.\n- Resume rule: Main sends an explicit resume order.\n' \
    > "$l/data/paused-for-juggernaut.md"
  cycle "$l"
  grep -q '^resolved \[key=waiting-timer-.*-ready-backlog\].*waiting-timer-cleared: lead1 ready backlog: the home is paused' "$f" \
    || fail "the pause left Main's report open: $(cat "$f")"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "a paused home kept its backlog episode"
  before=$(grep -c 'waiting-timer-backlog-overdue' "$f")
  touch -d '-15 days' "$l/state/.last-ready-work-check"
  cycle "$l"
  cycle "$l"
  [ "$(grep -c 'waiting-timer-backlog-overdue' "$f")" = "$before" ] \
    || fail "a paused home escalated its backlog: $(cat "$f")"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "a paused home armed a backlog episode again"
  # The resume order puts the backlog back on its ladder.
  rm -f "$l/data/paused-for-juggernaut.md"
  cycle "$l"
  [ -f "$l/state/.waiting-timers/.ready-backlog" ] || fail "the removed pause record did not re-arm the backlog: $(cat "$l/err")"
  backdate_backlog "$l" 1000
  cycle "$l"
  [ "$(grep -c 'waiting-timer-backlog-overdue' "$f")" -gt "$before" ] \
    || fail "the resumed home never rang again: $(cat "$f")"
  pass "a paused home arms and escalates no stalled backlog, closes the report it left open, and rings again when the record goes"
}

test_green_unmerged_pr_climbs_lead_main_and_the_board() {
  local m l f
  m=$(home green-main)
  l=$(lead_home green-lead "$m")
  lead_meta "$m" lead1 1 "$l"
  pr_task "$l" signoff on
  f="$m/state/lead1.status"
  PANES=1 cycle "$l"
  [ -f "$l/state/.green-pr/signoff" ] || fail "a green ready PR under yolo was not recorded: $(cat "$l/err")"
  [ ! -e "$l/state/.wait-sources/signoff.greenpr" ] || fail "the PR raised a wait before it had waited 15 minutes"
  backdate_green "$l" signoff 1000
  PANES=1 cycle "$l"
  grep -q '^greenpr: https://github.com/octo/widgets/pull/7 is green at aaaaaaaa and unmerged under yolo' "$l/state/.wait-sources/signoff.greenpr"     || fail "a PR green for 15 minutes was not handed to the chain: $(cat "$l/err")"
  PANES=1 cycle "$l"; backdate "$l" signoff 3
  PANES=1 cycle "$l"
  grep -q 'check: waiting-state signoff (greenpr, .*level=owner.*source=\[greenpr: https://github.com/octo/widgets/pull/7 ' "$l/events" \
    || fail "the lead was not woken naming the PR: $(cat "$l/events")"
  backdate "$l" signoff 5
  PANES=1 cycle "$l"
  grep -q 'waiting-timer-overdue: signoff (greenpr, observed [0-9]*s.*source=\[greenpr: https://github.com/octo/widgets/pull/7 ' "$f" \
    || fail "Main was not told which PR waits: $(cat "$f" 2>&1) $(cat "$l/err")"
  PANES=1 CARD_SECS=3600 cycle "$m"
  PANES=1 CARD_SECS=3600 cycle "$m"
  grep -q '^jg-send lead1 --fire-and-forget [0-9a-f]\{16\} Your worker signoff has been stuck .*on: greenpr: https://github.com/octo/widgets/pull/7 .*Merge it now with bin/jg-pr-merge.sh, or record a hold' "$m/sent" \
    || fail "Main did not steer the lead to merge: $(cat "$m/sent" 2>&1)"
  [ ! -s "$m/cards" ] || fail "a card was posted before its time"
  # The card follows the wait's own start, so age the report the lead filed.
  sed -i "s/^\(blocked.*since=\)[0-9]*/\1$(($(date +%s) - 4000))/" "$f"
  PANES=1 CARD_SECS=60 cycle "$m"; PANES=1 CARD_SECS=60 cycle "$m"
  ! grep -q -- '--key waiting-timer-[0-9a-f]*-signoff-g[0-9]*-greenpr-card' "$m/cards" 2>/dev/null \
    || fail "a green unmerged PR went to the captain's board: $(cat "$m/cards" 2>&1)"
  grep -q '^- Ask: Merge the green' "$m/data/overwatch-decisions.md" 2>/dev/null \
    || fail "the green unmerged PR was not recorded for Main to decide"
  # The merge ends it: the forge answers merged, the source goes, the report closes, the card is dismissed.
  forge "$l" MERGED false UNKNOWN aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  PANES=1 cycle "$l"; PANES=1 cycle "$l"
  [ ! -e "$l/state/.wait-sources/signoff.greenpr" ] && [ ! -e "$l/state/.waiting-timers/signoff" ] || fail "the wait outlived the merge"
  grep -q '^resolved \[key=waiting-timer-.*-signoff-.*-greenpr\].*waiting-timer-cleared: signoff' "$f" || fail "the merge left Main's report open: $(cat "$f")"
  PANES=1 CARD_SECS=3600 cycle "$m"; PANES=1 CARD_SECS=3600 cycle "$m"
  grep -q '^dismiss waiting-timer-.*-signoff-.*-greenpr-card' "$m/cards" || fail "the card stayed after the merge"
  pass "a green ready PR left unmerged under yolo wakes its lead, tells Main with the PR, steers the lead, reaches the board, and clears on merge"
}

test_green_unmerged_pr_in_the_main_home_wakes_main_then_the_board() {
  local m
  m=$(home green-solo)
  pr_task "$m" signoff on
  PANES=1 cycle "$m"
  backdate_green "$m" signoff 1000
  PANES=1 cycle "$m"; PANES=1 cycle "$m"; backdate "$m" signoff 3
  PANES=1 cycle "$m"
  grep -q 'check: waiting-state signoff (greenpr, .*level=owner; Main must recheck and unblock) id=.*source=\[greenpr: https://github.com/octo/widgets/pull/7 ' "$m/events" \
    || fail "Main was not woken naming the PR: $(cat "$m/events")"
  backdate "$m" signoff 5
  PANES=1 cycle "$m"
  grep -q 'check: waiting-state signoff (greenpr, .*level=main' "$m/events" || fail "Main's own rung never fired: $(cat "$m/events")"
  backdate "$m" signoff 10
  PANES=1 CARD_SECS=6 cycle "$m"; PANES=1 CARD_SECS=6 cycle "$m"
  ! grep -q -- '--key waiting-timer-[0-9a-f]*-signoff-g[0-9]*-greenpr-card' "$m/cards" 2>/dev/null \
    || fail "a green PR in the main home went to the captain's board: $(cat "$m/cards" 2>&1)"
  grep -q '^- Ask: Merge the green' "$m/data/overwatch-decisions.md" 2>/dev/null \
    || fail "a green PR in the main home was not recorded for Main to decide"
  pass "a green ready PR under yolo in the main home wakes Main, fires Main's rung, and reaches the board"
}

test_green_pr_stays_quiet_unless_it_is_green_unmerged_and_unheld_under_yolo() {
  local m n
  # yolo off: the captain merges, so nothing escalates.
  m=$(home green-off)
  pr_task "$m" signoff off
  PANES=1 cycle "$m"
  [ ! -e "$m/state/.green-pr/signoff" ] || fail "a PR without yolo was tracked"
  # A pending, red, draft or unreadable PR is not green.
  for n in "OPEN false BLOCKED" "OPEN false UNSTABLE" "OPEN true CLEAN" "CLOSED false CLEAN"; do
    m=$(home "green-$(printf '%s' "$n" | tr -c 'A-Za-z' -)")
    pr_task "$m" signoff on
    # shellcheck disable=SC2086
    forge "$m" $n aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    PANES=1 cycle "$m"
    [ ! -e "$m/state/.green-pr/signoff" ] || fail "'$n' was treated as green"
  done
  m=$(home green-unread)
  pr_task "$m" signoff on
  rm -f "$m/gh-answer"
  PANES=1 cycle "$m"
  [ ! -e "$m/state/.green-pr/signoff" ] && [ ! -e "$m/state/.wait-sources/signoff.greenpr" ] || fail "an unreadable forge answer was treated as green"
  # A recorded hold with a reason ends it; a new head re-arms the clock.
  m=$(home green-held)
  pr_task "$m" signoff on
  PANES=1 cycle "$m"
  backdate_green "$m" signoff 1000
  PANES=1 cycle "$m"
  [ -f "$m/state/.wait-sources/signoff.greenpr" ] || fail "fixture: the wait never started"
  printf 'paused [at=2]: waiting for the vendor to confirm the release window\n' >> "$m/state/signoff.status"
  prime_status_seen "$m/state" "$m/state/signoff.status"
  PANES=1 cycle "$m"
  [ ! -e "$m/state/.wait-sources/signoff.greenpr" ] || fail "a recorded pause with a reason did not clear the wait"
  printf 'done [at=3]: PR https://github.com/octo/widgets/pull/7\n' >> "$m/state/signoff.status"
  prime_status_seen "$m/state" "$m/state/signoff.status"
  PANES=1 cycle "$m"
  [ -f "$m/state/.green-pr/signoff" ] && [ ! -e "$m/state/.wait-sources/signoff.greenpr" ] || fail "the clock did not restart from zero after the pause ended"
  backdate_green "$m" signoff 1000
  PANES=1 cycle "$m"
  [ -f "$m/state/.wait-sources/signoff.greenpr" ] || fail "the wait did not return after the pause ended and 15 minutes passed"
  forge "$m" OPEN false CLEAN bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  PANES=1 cycle "$m"
  [ ! -e "$m/state/.wait-sources/signoff.greenpr" ] || fail "a new head did not re-arm the clock"
  pass "a PR is quiet without yolo, when not green or unreadable, and under a recorded pause, which restarts the clock when it ends; a new head re-arms the clock"
}

test_stalled_backlog_quiet_when_project_is_at_capacity() {
  local m l
  m=$(home cap-main)
  l=$(lead_home cap-lead "$m")
  git init -q "$l/projects/proj"
  printf 'proj 1\n' > "$m/config/project-capacity"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nproject=%s\n' "$l/projects/proj" > "$l/state/w1.meta"
  : > "$l/state/w1.status"
  prime_status_seen "$l/state" "$l/state/w1.status"
  backlog "$l" add jg-alpha "capped item" --repo proj
  PANES=1 cycle "$l"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "an item whose project is at capacity armed a stall"
  grep -q "$(printf '\tproject-capacity\t')" "$l/state/.waiting-timers/.ready-backlog-why" \
    || fail "the capacity hold left no reason: $(cat "$l/state/.waiting-timers/.ready-backlog-why" 2>&1)"
  backlog "$l" add jg-beta "uncapped item"
  PANES=1 cycle "$l"
  [ -e "$l/state/.waiting-timers/.ready-backlog" ] || fail "an uncapped item on a free lane armed no stall: $(cat "$l/err")"
  [ ! -e "$l/state/.waiting-timers/.ready-backlog-why" ] || fail "an armed stall kept a quiet reason"
  pass "an item whose project is at capacity cannot start, so it never arms the chain"
}

# A line a test printed is never a live condition. The detector read
# "disk quota exceeded; with TMPDIR on disk they pass." out of a finished lane's
# scrollback and woke the fleet three times. A quota wait now comes from the
# lane's own status line, or from a limit banner at the bottom of the screen.
test_a_printed_assertion_never_raises_a_quota_wait() {
  local m pane
  pane=$'● Running the classifier suites with TMPDIR on disk.\nnot ok 3 - the temp dir refuses a write\n  disk quota exceeded; with TMPDIR on disk they pass.\n● Done. 13 checks green, the PR is open.\n> '
  # The incident: a finished lane whose transcript holds the printed assertion.
  m=$(home printed-assertion)
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=pi\n' > "$m/state/w1.meta"
  printf '%s\n' "$pane" > "$m/panes/1"
  printf 'done [at=1]: PR https://example.invalid/o/r/pull/1\n' > "$m/state/w1.status"
  prime_status_seen "$m/state" "$m/state/w1.status"
  PANES=1 cycle "$m"
  [ ! -e "$m/state/.wait-sources/w1.quota" ] \
    || fail "a finished lane's printed test assertion became a live quota wait: $(cat "$m/state/.wait-sources/w1.quota")"
  ! grep -q 'waiting-state w1 (quota' "$m/events" 2>/dev/null \
    || fail "a printed test assertion woke the fleet as a quota wait: $(cat "$m/events")"
  # The same sentence in a working lane's transcript is history too: the footer
  # below it is the live screen, and it shows no limit.
  m=$(home printed-assertion-working)
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=pi\n' > "$m/state/w1.meta"
  printf '%s\n' "$pane" > "$m/panes/1"
  printf 'working [at=1]: reading the failures\n' > "$m/state/w1.status"
  prime_status_seen "$m/state" "$m/state/w1.status"
  PANES=1 cycle "$m"
  [ ! -e "$m/state/.wait-sources/w1.quota" ] \
    || fail "transcript text still raised a quota wait: $(cat "$m/state/.wait-sources/w1.quota")"
  # A provider banner at the bottom of the screen is a real wait: kept working.
  printf '● Working.\n■ You'"'"'ve hit your usage limit. Try again at 9:41 PM.\n> \n' > "$m/panes/1"
  PANES=1 cycle "$m"
  [ -e "$m/state/.wait-sources/w1.quota" ] \
    || fail "a usage-limit banner at the bottom of the pane raised no quota wait: $(ls -a "$m/state/.wait-sources" 2>&1)"
  grep -q "You've hit your usage limit" "$m/state/.wait-sources/w1.quota" \
    || fail "the quota wait did not name the banner it read: $(cat "$m/state/.wait-sources/w1.quota")"
  pass "a printed test assertion in a pane is never a live quota wait, and a usage-limit banner at the bottom of the screen still raises one"
}

# The other direction: a lane that declares the quota wait in its own status
# line is a wait, with no banner left on screen. The declaration is the source.
test_a_declared_quota_pause_is_a_wait() {
  local m n
  m=$(home declared-quota)
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=pi\n' > "$m/state/w1.meta"
  printf '● Stopped; no more turns until the reset.\n> \n' > "$m/panes/1"
  printf 'paused [at=1]: provider quota exhausted, resets 09:41Z\n' > "$m/state/w1.status"
  prime_status_seen "$m/state" "$m/state/w1.status"
  PANES=1 cycle "$m"
  [ ! -e "$m/state/.wait-sources/w1.quota" ] \
    || fail "pane text raised a quota wait with no banner on screen: $(cat "$m/state/.wait-sources/w1.quota")"
  # The declaration is the source: the lane still raises a wait, and it is never
  # counted as a gap.
  for n in 1 2 3 4 5 6 7 8; do
    [ -e "$m/state/.wait-sources/w1.silent" ] && break
    touch -d '-20 minutes' "$m/state/.silent-seen-fake_1" "$m/state/w1.status"
    prime_status_seen "$m/state" "$m/state/w1.status"
    PANES=1 cycle "$m"
  done
  [ -e "$m/state/.wait-sources/w1.silent" ] \
    || fail "a lane that declared a quota wait raised no wait at all: $(ls -a "$m/state/.wait-sources" 2>&1; cat "$m/err")"
  [ ! -e "$m/state/.wait-sources/w1.quota" ] \
    || fail "a declared quota wait was re-read out of pane text: $(cat "$m/state/.wait-sources/w1.quota")"
  pass "a lane that declares a quota wait in its status line is a wait from that declaration, with no banner on screen"
}

# Pane renderings per harness: the claude one is captured from a real Claude
# Code worker (tests/captures/claude-askuserquestion); the rest are the dialog hints each
# harness documents, pinned here so the harness-neutral matcher is exercised
# per adapter. The live guard in the verification record refreshes them.
verdict() {  # <pane-text> -> "kind" or "none"
  local out
  out=$(printf '%s\n' "$1" | bash -c '. "$1/jg-stuck-gate-lib.sh"; jg_stuck_verdict' _ "$FORK/bin")
  [ -n "$out" ] || out=none
  printf '%s' "${out%%$'\t'*}"
}

test_stuck_verdict_table() {
  local harness want text got fixture
  fixture=$(cat "$ROOT/tests/captures/claude-askuserquestion/picker.txt")
  while IFS='|' read -r harness want text; do
    got=$(verdict "$(printf '%b' "$text")")
    [ "$got" = "$want" ] || fail "$harness: wanted $want, got $got for: $text"
  done <<'TABLE'
pi|question|How should I resolve the review finding?\n  1. Fix now\n  2. Defer\n↑↓ navigate · Enter select · Esc cancel
pi-signed|question|How should I resolve the review finding?\n  1. Fix now\n  2. Defer\n↑↓ navigate · Enter select · Esc cancel
omp|question|Pick a database\n❯ 1. sqlite\n  2. postgres\nenter to select · esc to cancel
opencode|question|Which approach?\n  Fast\n  Safe\n⇆ select  enter confirm  esc dismiss
codex|question|Question 1/1\n  1. Yes\n  2. No\nPress enter to confirm or esc to go back
gemini|question|Choose an option\n  1. Continue\nEnter to submit · Esc to cancel
kimi|question|Select one\n  a) first\nPress Enter to select, Esc to skip
cursor|question|Which file?\n  1. a.ts\nenter to select · esc to cancel
claude-account|account|● Working\nClaude Code can't use your Claude subscription\n> 
claude-quota|quota|⎿ You've hit your limit · resets 3pm\n> 
codex-quota|quota|■ You've hit your usage limit. Upgrade or try again at 9:41 PM.\n> 
pi-quota|quota|Error: 429 Too Many Requests - rate limit exceeded\n> 
opencode-quota|quota|Error: insufficient_quota - You exceeded your current quota\n> 
opencode-errors|errors|┃  User not found.\n┃\n▣  Build · Some Model\n┃  User not found.\n┃\n▣  Build · Some Model\n┃  User not found.\n┃\n> 
pi-errors|errors|Error: Provider returned error\nretrying\nError: Provider returned error\nretrying\nError: Provider returned error\n> 
errors-once|none|┃  User not found.\n┃\nI will look at the key next.\n> 
errors-prose|none|I will check the config.\nI will check the config.\nI will check the config.\n> 
claude-idle|none|● Done. All checks pass.\n\n> 
printed-assertion|none|● Running the classifier suites with TMPDIR on disk.\nnot ok 3 - the temp dir refuses a write\n  disk quota exceeded; with TMPDIR on disk they pass.\n● Done. 13 checks green, the PR is open.\n> 
worker-prose|none|I will press Enter to select the file, then continue.\n> 
code-output|none|ok - 12 tests passed\nEnter the value of x\n> 
TABLE
  [ "$(verdict "$fixture")" = question ] || fail "the real Claude AskUserQuestion capture was not detected"
  # Panes captured from the live runtimes (tests/captures/stuck-live/README.md).
  local cap
  for cap in pi-question codex-question opencode-quota; do
    got=$(verdict "$(cat "$ROOT/tests/captures/stuck-live/$cap.txt")")
    [ "$got" = "${cap#*-}" ] || fail "the live $cap capture read as $got"
  done
  # A question scrolled off the bottom 12 lines is gone, so it is not stuck.
  got=$(verdict "$(printf '%s\n' "$fixture"; seq 1 30)")
  [ "$got" = none ] || fail "a dialog scrolled out of view still read as stuck"
  pass "the stuck-cause matcher reads a question, a quota wall, a repeated provider error, or nothing for each harness rendering"
}

# A loaded runner reads its panes slower than any fixed cycle delay allows, so a
# cycle must be bounded by its own scan. The wake is found on the last pane read,
# which is where a fixed four-second budget used to kill the cycle before it
# could report anything.
test_a_slow_scan_reports_the_wake_it_found() {
  local m n
  m=$(home slow-scan)
  for n in 1 2 3; do
    printf 'kind=ship\nbackend=tmux\nwindow=fake:%s\nharness=claude\n' "$n" > "$m/state/w$n.meta"
    : > "$m/state/w$n.status"
    prime_status_seen "$m/state" "$m/state/w$n.status"
  done
  printf '%s\n' "$TRUST" > "$m/panes/3"
  slow_panes "$m" 2.5
  # A healthy predecessor lets the next scan publish liveness mid-scan.
  touch "$m/state/.last-watcher-beat"
  PANES='1 2 3' cycle "$m"
  [ -e "$m/progress-before-completion" ] || fail "the slow scan never published progress before completion"
  grep -q '^stale: fake:3 (permission prompt' "$m/events" \
    || fail "a wake found on the last pane of a slow scan was lost: $(cat "$m/events")"
  pass "slow scan after a healthy watcher handoff delivered the wake from last pane 3: $(grep -m1 '^stale: fake:3 (permission prompt' "$m/events")"
}

test_question_and_quota_ride_the_chain_whatever_the_terminal_says() {
  local m kind want pane n
  for kind in question quota errors; do
    m=$(home "chain-$kind")
    printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=pi\n' > "$m/state/w1.meta"
    printf 'working [at=1]: on it\n' > "$m/state/w1.status"
    prime_status_seen "$m/state" "$m/state/w1.status"
    if [ "$kind" = question ]; then pane=$(cat "$ROOT/tests/captures/claude-askuserquestion/picker.txt")
    elif [ "$kind" = errors ]; then pane=$'┃  User not found.\n▣  Build\n┃  User not found.\n▣  Build\n┃  User not found.\n▣  Build'
    else pane=$'working...\nYou\'ve hit your usage limit. Try again at 9:41 PM.'; fi
    printf '%s\n' "$pane" > "$m/panes/1"
    PANES=1 cycle "$m"
    [ -f "$m/state/.wait-sources/w1.$kind" ] || fail "$kind was not recorded as a wait source"
    PANES=1 cycle "$m"; backdate "$m" w1 3
    PANES=1 cycle "$m"
    grep -q "check: waiting-state w1 ($kind, .*level=owner" "$m/events" || fail "$kind did not reach the owner rung: $(cat "$m/events")"
    backdate "$m" w1 5
    PANES=1 cycle "$m"
    grep -q "check: waiting-state w1 ($kind, .*level=main" "$m/events" || fail "$kind did not reach Main: $(cat "$m/events")"
    backdate "$m" w1 5
    PANES=1 cycle "$m"; PANES=1 cycle "$m"
    ! grep -q -- "--key waiting-timer-[0-9a-f]*-w1-.*-$kind-card" "$m/cards" 2>/dev/null \
      || fail "$kind went to the captain's board: $(cat "$m/cards" 2>&1)"
    grep -q "^- Ask: Unblock stuck" "$m/data/overwatch-decisions.md" 2>/dev/null \
      || fail "$kind was not recorded for Main to decide"
    printf 'working...\n> \n' > "$m/panes/1"
    # The cause is gone; the episode clears on a later scan, and a cycle that was
    # stopped at its budget edge can spend one of them, so wait for the condition.
    for n in 1 2 3 4; do
      if [ -e "$m/state/.wait-sources/w1.$kind" ] || [ -e "$m/state/.waiting-timers/w1" ]; then PANES=1 cycle "$m"; fi
    done
    [ ! -e "$m/state/.wait-sources/w1.$kind" ] && [ ! -e "$m/state/.waiting-timers/w1" ] || fail "$kind episode outlived the cause"
  done
  pass "a question dialog, a provider quota wall and a repeating provider error climb owner and Main, are recorded for Main to decide, and clear with the cause"
}

# The watcher records each pane's last change in state/.silent-seen-<window> on its
# first complete read of it. A cycle that ends on a wake, or is stopped at its
# limit, can end before that read; backdating a file the watcher has not written
# yet only creates an empty one, which the next read rewrites with a fresh time and
# so restarts the silence clock. Cycle until every pane is recorded and one more
# cycle rewrites none of them, so the backdating below ages a real record.
settle_silent_seen() {  # <home>
  local m=$1 n k missing rewritten mark="$1/tmp/silent-mark"
  for n in 1 2 3 4 5 6 7 8; do
    touch "$mark"
    PANES='1 2 3 4 5 6' cycle "$m"
    missing=0
    for k in 1 2 3 4 5 6; do [ -s "$m/state/.silent-seen-fake_$k" ] || missing=1; done
    rewritten=$(find "$m/state" -maxdepth 1 -name '.silent-seen-fake_*' -newer "$mark" | wc -l)
    [ "$missing" = 0 ] && [ "$rewritten" -eq 0 ] && return 0
  done
  fail "the watcher never settled its pane records: $(ls -la "$m"/state/.silent-* 2>&1; cat "$m/err")"
}

# Keep every CPU of the runner busy, the way a full CI shard does. Each burner
# stops itself after <secs> or once this test shell is gone, and burners_stop
# ends the ones this test started.
burners_start() {  # <secs>
  local n=0 cpus
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
  BURNERS=''
  while [ "$n" -lt "$cpus" ]; do
    # shellcheck disable=SC2016 # the burner expands its own argument when run
    timeout "$1" sh -c 'while kill -0 "$1" 2>/dev/null; do :; done' _ "$$" &
    BURNERS="$BURNERS $!"
    n=$((n + 1))
  done
}

burners_stop() {
  local pid
  for pid in $BURNERS; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in $BURNERS; do wait "$pid" 2>/dev/null || true; done
  BURNERS=''
}

# Run cycles over all six panes until <command> holds or <secs> of wall clock
# have passed, whatever one cycle costs on this runner; the caller's assertion
# reports a miss.
cycle_for() {  # <home> <secs> <command...>
  local h=$1 end=$((SECONDS + $2))
  shift 2
  while ! "$@"; do
    [ "$SECONDS" -lt "$end" ] || return 0
    PANES='1 2 3 4 5 6' cycle "$h"
  done
}

test_silent_worker_climbs_whatever_it_declared() {
  local m w n=0 hold quiet
  # Six windows per poll: a loaded runner needs far longer than the default cycle budget.
  local CYCLE_POLLS=300
  m=$(home silent)
  # id:status line:pane, one worker each; ld is an idle lead.
  hold=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%MZ)
  for w in "sb:blocked [at=1]: waiting on the vendor" "sp:paused [at=1]: waiting on CI" "sf:paused [at=1]: waiting on CI until $hold" \
    "sd:done [at=1]: finished" "ld:working [at=1]: on it" "sw:working [at=1]: on it"; do
    n=$((n + 1))
    printf 'kind=ship\nbackend=tmux\nwindow=fake:%s\nharness=claude\n' "$n" > "$m/state/${w%%:*}.meta"
    printf '%s\n' "${w#*:}" > "$m/state/${w%%:*}.status"
    prime_status_seen "$m/state" "$m/state/${w%%:*}.status"
  done
  printf 'kind=squad_lead\nmode=squad_lead\nbackend=tmux\nwindow=fake:5\nharness=claude\nhome=%s\n' "$m/lead-home" > "$m/state/ld.meta"
  settle_silent_seen "$m"
  # Everything has been silent for 20 minutes except the worker with fresh progress.
  for n in 1 2 3 4 5; do touch -d '-20 minutes' "$m/state/.silent-seen-fake_$n"; done
  for w in sb sp sf sd ld; do touch -d '-20 minutes' "$m/state/$w.status"; prime_status_seen "$m/state" "$m/state/$w.status"; done
  # A cycle that ends on a wake skips the rest of its poll, so repeat until both are recorded.
  cycle_for "$m" 120 test -e "$m/state/.wait-sources/sb.silent" -a -e "$m/state/.wait-sources/sp.silent"
  for w in sb sp; do
    grep -q '^silent: no status line or pane change' "$m/state/.wait-sources/$w.silent" 2>/dev/null || fail "$w silent 20 minutes raised no silent source: $(ls -a "$m/state/.wait-sources" 2>&1; ls -la --time-style=+%T "$m"/state/.silent-* ; cat "$m/err")"
  done
  for w in sf sd ld sw; do
    [ ! -e "$m/state/.wait-sources/$w.silent" ] || fail "$w was flagged silent"
  done
  # The climb runs on a runner whose every CPU is busy. A loaded runner reaches
  # each pane later than three polls and thirty seconds after its last read, so
  # every silent record is older than that when the next poll reads it. The
  # silence has not ended: the wait keeps its clock and its rung, and never falls
  # back to the line the worker declared before it went quiet, which would start
  # it over as a fresh two-second wait.
  burners_start 300
  for w in sb sp; do touch -d '-60 seconds' "$m/state/.wait-sources/$w.silent"; done
  quiet=$(wc -l < "$m/events")
  backdate "$m" sp 3
  cycle_for "$m" 120 grep -q 'waiting-state sp (silent, .*level=owner' "$m/events"
  grep -q 'check: waiting-state sp (silent, .*level=owner' "$m/events" || fail "a silent paused worker never reached the owner rung: $(cat "$m/events")"
  # One wake ends a cycle, so give the other silent worker's rung its own cycles.
  backdate "$m" sp 5
  cycle_for "$m" 120 grep -q 'waiting-state sp (silent, .*level=main' "$m/events"
  grep -q 'check: waiting-state sp (silent, .*level=main' "$m/events" || fail "a silent paused worker never reached Main: $(cat "$m/events"; cat "$m/state/.waiting-timers/sp")"
  ! tail -n +"$((quiet + 1))" "$m/events" | grep -qE 'waiting-state s[bp] \((blocked|paused)' \
    || fail "a late scan handed a silent worker back to the wait it declared: $(cat "$m/events")"
  burners_stop
  printf 'working [at=2]: back\n' >> "$m/state/sp.status"
  cycle_for "$m" 120 test ! -e "$m/state/.wait-sources/sp.silent"
  [ ! -e "$m/state/.wait-sources/sp.silent" ] || fail "a status line did not end the silence"
  pass "a silent blocked or paused worker climbs the chain; a dated pause, a finished worker, an idle lead and a worker with fresh progress do not"
}

test_ready_work_wakes_the_primary_home_too() {
  local m
  m=$(home ready-main)
  mkdir -p "$m/data"
  backlog "$m" add jg-alpha "first item" --priority 1
  cycle "$m"
  grep -q '^check: ready work waiting with no worker working: jg-alpha' "$m/events" \
    || fail "a primary home with ready work and no worker got no wake: $(cat "$m/events")"
  [ ! -e "$m/state/.waiting-timers/.ready-backlog" ] || fail "a primary home with no parent armed a lead escalation"
  # The same set must not ring again inside the resurface window, but a place
  # freed since it surfaced makes it startable now, so the stamp re-raises it.
  touch -d '-15 days' "$m/state/.last-ready-work-check"
  cycle "$m"
  [ "$(grep -c '^check: ready work waiting' "$m/events")" = 1 ] \
    || fail "the same ready set rang again inside the resurface window: $(cat "$m/events")"
  touch -d '-15 days' "$m/state/.last-ready-work-check"
  printf '%s\n' "$(($(date +%s) + 10))" > "$m/state/.capacity-freed"
  cycle "$m"
  [ "$(grep -c '^check: ready work waiting' "$m/events")" = 2 ] \
    || fail "a freed place did not re-raise the same ready set: $(cat "$m/events")"
  pass "ready work with no worker working wakes the primary home, not only a lead, and a freed place re-raises it"
}

test_a_merge_freeze_never_idles_free_lanes() {
  local m crew n
  m=$(home freeze-main)
  mkdir -p "$m/data"
  crew=$(working_crew_state "$m")
  printf '6\n' > "$m/config/lane-target"
  # The lead holds merges to keep a release head still: a freeze record, three
  # lanes working, and three lanes parked on held PRs that only wait.
  printf 'merges held for the release head\n' > "$m/state/.merge-freeze"
  for n in 1 2 3; do
    printf 'kind=ship\nbackend=tmux\nwindow=fake:%s\n' "$n" > "$m/state/w$n.meta"
    printf 'working [at=1]: on it\n' > "$m/state/w$n.status"
  done
  for n in 4 5 6; do
    printf 'kind=ship\nbackend=tmux\nwindow=fake:%s\n' "$n" > "$m/state/w$n.meta"
    printf 'paused [at=1]: PR held for the merge freeze\n' > "$m/state/w$n.status"
  done
  backlog "$m" add jg-alpha "first item" --priority 1
  backlog "$m" add jg-beta "second item"
  JG_CREW_STATE_BIN="$crew" PANES='1 2 3 4 5 6' cycle "$m"
  grep -q '^check: ready work waiting with free lane slots (3/6 open): jg-alpha jg-beta - ' "$m/events" \
    || fail "a merge freeze with 3 live lanes of 6 and 2 ready items raised no wake naming the count and ids: $(cat "$m/events")"
  [ "$(grep -c '^check: ready work waiting' "$m/events")" = 1 ] || fail "the shortfall rang more than once: $(cat "$m/events")"
  pass "live lanes below the floor with ready work wake the home whatever a merge freeze holds, and parked lanes do not count as live"
}

test_a_fleet_pause_silences_ready_work_but_not_a_blocker() {
  local m before
  m=$(home ready-pause)
  mkdir -p "$m/data"
  backlog "$m" add jg-alpha "first item" --priority 1
  cycle "$m"
  grep -q '^check: ready work waiting with no worker working: jg-alpha' "$m/events" \
    || fail "an unpaused primary home got no ready-work wake: $(cat "$m/events")"
  # A lane list parked under the home's own old pause record name is not a pause
  # declaration (bin/jg-pause-lib.sh), so ready-work intake still rings and the
  # live work keeps its alarm.
  printf '# Paused lanes for the Juggernaut-only push\n\nNo new work; nothing merged.\n- jg-beta: parked\n' \
    > "$m/data/paused-for-juggernaut.md"
  before=$(grep -c '^check: ready work waiting' "$m/events")
  backlog "$m" add jg-beta "second item" --priority 2
  touch -d '-15 days' "$m/state/.last-ready-work-check"
  cycle "$m"
  [ "$(grep -c '^check: ready work waiting' "$m/events")" -gt "$before" ] \
    || fail "a lane list under a pause record's name silenced ready-work intake: $(cat "$m/events")"
  rm -f "$m/data/paused-for-juggernaut.md"
  # Main declares the fleet pause in this home: ready-work intake goes silent.
  printf '# Fleet pause for the Juggernaut migration - 31 Oct 2026\n\nStop new work.\n- Resume rule: Main sends an explicit resume order.\n' \
    > "$m/data/fleet-pause-2026-10-31.md"
  before=$(grep -c '^check: ready work waiting' "$m/events")
  touch -d '-15 days' "$m/state/.last-ready-work-check"
  cycle "$m"
  [ "$(grep -c '^check: ready work waiting' "$m/events")" = "$before" ] \
    || fail "a paused primary home raised the ready-work wake: $(cat "$m/events")"
  # A worker's blocker is not ready-work intake, so the pause does not swallow it.
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nworktree=%s/gone\n' "$m" > "$m/state/w1.meta"
  printf 'blocked [at=1]: the vendor key is missing\n' > "$m/state/w1.status"
  PANES=1 cycle "$m"
  grep -q '^signal:.*w1.status' "$m/events" || fail "a paused home swallowed a worker's blocker: $(cat "$m/events")"
  # The resume order clears the record and the same ready set rings at once.
  rm -f "$m/data/fleet-pause-2026-10-31.md" "$m/state/w1.meta" "$m/state/w1.status"
  before=$(grep -c '^check: ready work waiting' "$m/events")
  touch -d '-15 days' "$m/state/.last-ready-work-check"
  cycle "$m"
  [ "$(grep -c '^check: ready work waiting' "$m/events")" -gt "$before" ] \
    || fail "the resume order did not re-raise the ready set: $(cat "$m/events")"
  pass "a fleet pause silences ready-work intake in the primary home, leaves a real blocker wake alone, and the resume order rings the set again"
}

test_memory_refused_launch_reraises_when_admission_clears() {
  local m
  m=$(home admit-retry)
  # The verdict comes from the newest sampler row, which this home's own sampler
  # writes; one refusal record rings once, and a cleared record stops ringing.
  printf '%s\tqueued-1\thost memory under pressure\n' "$(date +%s)" > "$m/state/admission-refused"
  PANES=1 cycle "$m"
  grep -q '^check: host memory admits launches again, so retry the launch of queued-1' "$m/events" \
    || fail "an admitting sample did not raise the retry wake: $(cat "$m/events" 2>&1)"
  touch -d '-15 days' "$m/state/.last-ready-work-check"
  cycle "$m"
  [ "$(grep -c 'host memory admits launches again' "$m/events")" = 1 ] \
    || fail "one refusal record rang twice: $(cat "$m/events")"
  rm -f "$m/state/admission-refused"
  touch -d '-15 days' "$m/state/.last-ready-work-check"
  cycle "$m"
  [ "$(grep -c 'host memory admits launches again' "$m/events")" = 1 ] \
    || fail "a cleared refusal record rang again: $(cat "$m/events")"
  pass "a memory-refused launch rings once while its record stands, and stops when it clears"
}

# Known next steps (core/wait-timers/README.md): the ladder takes them itself, so
# no rung wakes the owner or Main while a step is left. Each case runs the real
# jg-send (real-steer), so the inbox records and the decision close are real.

# A worker that has gone quiet mid-task: it says it is working and its pane and
# status have not changed for 20 minutes, so the watcher raises its silent source.
silence_worker() {  # <home> <task> <pane>
  local m=$1 n mark="$1/tmp/silent-mark"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:%s\nharness=claude\n' "$3" > "$m/state/$2.meta"
  printf 'working [at=1]: running the suite\n' > "$m/state/$2.status"
  prime_status_seen "$m/state" "$m/state/$2.status"
  for n in 1 2 3 4 5 6 7 8; do
    touch "$mark"
    cycle "$m"
    [ -s "$m/state/.silent-seen-fake_$3" ] && [ ! "$m/state/.silent-seen-fake_$3" -nt "$mark" ] && break
  done
  touch -d '-20 minutes' "$m/state/.silent-seen-fake_$3" "$m/state/$2.status"
  prime_status_seen "$m/state" "$m/state/$2.status"
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/$2"
  grep -q '^silent: no status line or pane change' "$m/state/.wait-sources/$2.silent" 2>/dev/null \
    || fail "$2 silent 20 minutes armed no silent wait: $(ls -a "$m/state/.wait-sources" 2>&1; cat "$m/err")"
}

# The row the metrics ledger holds for <task>, or nothing.
ledger_row() {  # <home> <task>
  awk -F '\t' -v t="$2" '$2 == t' "$1/data/metrics/escalations.tsv" 2>/dev/null
}

test_a_silent_worker_is_rung_and_clears_with_no_model_turn() {
  # Wide gaps between rungs, so arming takes no step and one test cycle takes one.
  local m row CYCLE_POLLS=100 PANES=1 ALERT_SECS=30 ESCALATE_SECS=90 CARD_SECS=600
  m=$(home silent-ring)
  : > "$m/real-steer"
  silence_worker "$m" sr 1
  backdate "$m" sr 31
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/.acted/sr"
  grep -qx 'silent	[0-9]*	ring	[0-9]*' "$m/state/.waiting-timers/.acted/sr" \
    || fail "the silent worker was not rung by the ladder: $(cat "$m/state/.waiting-timers/.acted/sr" 2>&1; cat "$m/err")"
  grep -l 'no status line and shown no new output' "$m/state/sr.inbox/"*.msg >/dev/null 2>&1 \
    || fail "the ring did not reach the worker's inbox: $(ls -la "$m/state/sr.inbox" 2>&1; cat "$m/sent" 2>&1)"
  # The worker reads the steer and reports where it is.
  printf 'working [at=%s]: back; the suite had hung on a lock\n' "$(date +%s)" >> "$m/state/sr.status"
  cycle_for "$m" 120 test ! -e "$m/state/.waiting-timers/sr"
  [ ! -e "$m/state/.waiting-timers/sr" ] || fail "the answered ring left the wait open: $(cat "$m/state/.waiting-timers/sr")"
  ! grep -q 'waiting-state sr' "$m/events" || fail "a rung wait still woke a model: $(cat "$m/events")"
  ! grep -q '^jg-control ' "$m/sent" 2>/dev/null || fail "an answered ring was relaunched: $(cat "$m/sent")"
  row=$(ledger_row "$m" sr)
  printf '%s\n' "$row" | grep -qE '^[0-9]+	sr	waiting-timer-[^	]+	[0-9]+	[0-9]+\.[0-9]	owner	ring	changed state$' \
    || fail "the ledger has no row with the cleared minutes: $(cat "$m/data/metrics/escalations.tsv" 2>&1)"
  printf 'silent ring: cleared in %s min, no model turn\n' "$(printf '%s' "$row" | cut -f5)"
  pass "a silent worker is rung by the ladder, clears when it reports, and the ledger holds the minutes, with no owner or Main wake"
}

test_an_unanswered_ring_is_relaunched_then_reaches_main() {
  local m row CYCLE_POLLS=100 PANES=1 ALERT_SECS=30 ESCALATE_SECS=90 CARD_SECS=600
  m=$(home silent-relaunch)
  : > "$m/real-steer"
  silence_worker "$m" sq 1
  backdate "$m" sq 31
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/.acted/sq"
  # No answer: the next rung is stuck-operator recovery's relaunch, not a wake.
  backdate "$m" sq 61
  cycle_for "$m" 120 grep -q '^jg-control sq relaunch --note ' "$m/sent"
  grep -q '^jg-control sq relaunch --note The watcher relaunched you' "$m/sent" \
    || fail "an unanswered ring was not relaunched: $(cat "$m/sent" 2>&1; cat "$m/state/.waiting-timers/.acted/sq" 2>&1)"
  grep -q 'relaunch exit=0' "$m/state/.waiting-timers/.acted/sq.relaunch.log" || fail "the relaunch outcome was not logged"
  ! grep -q 'waiting-state sq' "$m/events" || fail "a wait with a step left woke a model: $(cat "$m/events")"
  # Both steps spent and still silent: the table's next owner, the lead (Main
  # in this home), gets the owner wake; only then does the Main rung follow.
  backdate "$m" sq 61
  cycle_for "$m" 120 grep -q 'waiting-state sq (silent, .*level=owner' "$m/events"
  grep -q 'check: waiting-state sq (silent, .*level=owner' "$m/events" \
    || fail "the lead was not handed the wait after the steps were spent: $(cat "$m/events"; cat "$m/state/.waiting-timers/.acted/sq")"
  ! grep -q 'waiting-state sq (silent, .*level=main' "$m/events" || fail "Main was woken before the lead: $(cat "$m/events")"
  backdate "$m" sq 61
  cycle_for "$m" 120 grep -q 'waiting-state sq (silent, .*level=main' "$m/events"
  grep -q 'check: waiting-state sq (silent, .*level=main; the ladder already took: ring, relaunch, lead; Main must unblock it now)' "$m/events" \
    || fail "Main was not told after the lead: $(cat "$m/events")"
  printf 'working [at=%s]: resumed after the relaunch\n' "$(date +%s)" >> "$m/state/sq.status"
  cycle_for "$m" 120 test ! -e "$m/state/.waiting-timers/sq"
  row=$(ledger_row "$m" sq)
  printf '%s\n' "$row" | grep -qE '	main	ring, relaunch, lead	changed state$' \
    || fail "the ledger row does not name the rung and the steps: $(cat "$m/data/metrics/escalations.tsv" 2>&1)"
  pass "an unanswered ring is relaunched by the ladder, then the lead owns it, Main hears only after that, and the ledger names the steps"
}

test_a_ready_recon_draft_is_forwarded_to_its_critic() {
  local m w row draft=/drafts/rc/report.md CYCLE_POLLS=100 PANES='1 2 3 4'
  m=$(home critic-forward)
  : > "$m/real-steer"
  # rc's critic was started before this draft; rd's after it, so rd's critic already has its draft.
  printf 'kind=scout\nbackend=tmux\nwindow=fake:1\nharness=claude\n' > "$m/state/rc.meta"
  printf 'kind=scout\nbackend=tmux\nwindow=fake:2\nharness=claude\nspawn_gen=s1000.1.1\n' > "$m/state/rc-critic.meta"
  printf 'kind=scout\nbackend=tmux\nwindow=fake:3\nharness=claude\n' > "$m/state/rd.meta"
  printf 'kind=scout\nbackend=tmux\nwindow=fake:4\nharness=claude\nspawn_gen=s%s.1.1\n' "$(($(date +%s) + 60))" > "$m/state/rd-critic.meta"
  printf 'needs-decision [at=%s]: draft 2 ready for critic round 2 - %s\n' "$(date +%s)" "$draft" > "$m/state/rc.status"
  printf 'needs-decision [at=%s]: draft ready for the separate critic - /drafts/rd/report.md\n' "$(date +%s)" > "$m/state/rd.status"
  for w in rc rd; do prime_status_seen "$m/state" "$m/state/$w.status"; done
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/rc" -a -e "$m/state/.waiting-timers/rd"
  backdate "$m" rc 3
  backdate "$m" rd 3
  cycle_for "$m" 120 test ! -e "$m/state/.waiting-timers/rc" -a ! -e "$m/state/.waiting-timers/rd"
  grep -l "Recon rc declared its draft ready for your next round: draft 2 ready for critic round 2 - $draft" "$m/state/rc-critic.inbox/"*.msg >/dev/null 2>&1 \
    || fail "the draft did not reach its critic: $(cat "$m/state/rc-critic.inbox/"*.msg 2>&1; cat "$m/err")"
  grep -q '^resolved \[key=default\].*forwarded to the critic rc-critic' "$m/state/rc.status" \
    || fail "the forward did not close the draft decision: $(cat "$m/state/rc.status")"
  [ ! -d "$m/state/rd-critic.inbox" ] || ! ls "$m/state/rd-critic.inbox/"*.msg >/dev/null 2>&1 \
    || fail "a critic that already had the draft was sent it again: $(cat "$m/state/rd-critic.inbox/"*.msg)"
  grep -q '^resolved \[key=default\].*rd-critic already has this draft' "$m/state/rd.status" \
    || fail "a draft its critic already had was left open: $(cat "$m/state/rd.status")"
  ! grep -qE 'waiting-state r[cd] ' "$m/events" || fail "a forwarded draft woke a model: $(cat "$m/events")"
  row=$(ledger_row "$m" rc)
  printf '%s\n' "$row" | grep -qE '	owner	forward	changed state$' \
    || fail "the ledger has no row for the forwarded draft: $(cat "$m/data/metrics/escalations.tsv" 2>&1)"
  printf 'critic forward: cleared in %s min, no model turn\n' "$(printf '%s' "$row" | cut -f5)"
  pass "a ready Recon draft is forwarded to its critic and its decision closed by the ladder, a critic that has it is not sent it twice, and the ledger holds the minutes"
}

test_a_lane_blocked_for_the_herdr_lab_section_is_relaunched_once_with_it() {
  local m n CYCLE_POLLS=100 PANES='1 2'
  m=$(home herdr-lab)
  : > "$m/real-steer"
  # wl's brief has no lab section; wk's brief has it already, so its blocked line is not this state.
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=claude\n' > "$m/state/wl.meta"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:2\nharness=claude\n' > "$m/state/wk.meta"
  mkdir -p "$m/data/wl" "$m/data/wk"
  printf '# Task\n\n# Herdr lifecycle declaration - NOT ENABLED\nGate text.\n\n# Setup\n' > "$m/data/wl/brief.md"
  printf '# Herdr isolation - HARD SAFETY CONTRACT\n\n# Setup\n' > "$m/data/wk/brief.md"
  for n in wl wk; do
    printf 'blocked [at=%s] [key=lab]: needs --herdr-lab in my brief to drive the panes\n' "$(date +%s)" > "$m/state/$n.status"
    prime_status_seen "$m/state" "$m/state/$n.status"
  done
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/wl" -a -e "$m/state/.waiting-timers/wk"
  backdate "$m" wl 3
  cycle_for "$m" 120 grep -q '^jg-control wl relaunch --note ' "$m/sent"
  grep -q '^jg-control wl relaunch --note The watcher relaunched you because you were blocked on a brief with no Herdr lab section.* --herdr-lab$' "$m/sent" \
    || fail "the blocked lane was not relaunched with the lab section: $(cat "$m/sent" 2>&1; cat "$m/err"; cat "$m/state/wl.status"; ls -la "$m/state/.waiting-timers/.acted/"; cat "$m/state/.waiting-timers/.acted/wl.relaunch.log")"
  [ "$(grep -c '^jg-control wl relaunch' "$m/sent")" = 1 ] || fail "the lane was relaunched more than once: $(cat "$m/sent")"
  grep -q '^resolved \[key=lab\]' "$m/state/wl.status" || fail "the blocked decision was left open: $(cat "$m/state/wl.status")"
  grep -qx 'herdr-lab	[0-9]*	rebrief	[0-9]*' "$m/state/.waiting-timers/.acted/wl" \
    || fail "the step was not recorded: $(cat "$m/state/.waiting-timers/.acted/wl" 2>&1)"
  ! grep -q '^jg-control wk ' "$m/sent" 2>/dev/null || fail "a lane whose brief has the section was relaunched: $(cat "$m/sent")"
  pass "a lane blocked for the Herdr lab section is answered and relaunched once with it; a lane that has it is left alone"
}

# Account outage (core/wait-timers/README.md "Known next steps"): the pinned Claude
# account dies, and the watcher moves the lanes to the owner's next recorded
# account, or only raises its one card when he recorded none.

# A home pinned to account a, whose Claude CLI answers PONG on any account but a.
# w1 and w2 are working on a, wd is finished on a, wo works on b (another account).
account_outage_home() {  # <name> -> home path
  local m
  m=$(home "$1")
  mkdir -p "$m/acct/a" "$m/acct/b" "$m/acct/c"
  printf '%s\n' "$m/acct/a" > "$m/config/claude-account"
  cat > "$m/fakebin/claude" <<'SH'
#!/usr/bin/env bash
case "${CLAUDE_CONFIG_DIR:-}" in
  */a|*/c) echo "Claude Code can't use your Claude subscription: payment past due"; exit 1 ;;
esac
echo PONG
SH
  chmod +x "$m/fakebin/claude"
  local n=0 w
  for w in w1:working w2:working wd:done wo:working; do
    n=$((n + 1))
    printf 'kind=ship\nbackend=tmux\nwindow=fake:%s\nharness=claude\naccount=%s\n' "$n" "$m/acct/$([ "${w%%:*}" = wo ] && echo b || echo a)" > "$m/state/${w%%:*}.meta"
    printf '%s [at=1]: on it\n' "${w#*:}" > "$m/state/${w%%:*}.status"
    prime_status_seen "$m/state" "$m/state/${w%%:*}.status"
  done
  printf 'Claude Code can'"'"'t use your Claude subscription\n> \n' > "$m/panes/1"
  cp "$m/panes/1" "$m/panes/2"
  cp "$m/panes/1" "$m/panes/3"
  printf '%s\n' "$m"
}

test_a_dead_account_moves_the_lanes_to_the_recorded_fallback_with_no_model_turn() {
  local m row CYCLE_POLLS=100 PANES='1 2 3 4' ALERT_SECS=30 ESCALATE_SECS=90 CARD_SECS=600
  m=$(account_outage_home account-down)
  printf '%s\n%s\n' "$m/acct/a" "$m/acct/b" > "$m/config/claude-account-fallbacks"
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/w1" -a -e "$m/state/.waiting-timers/w2"
  [ -f "$m/state/.wait-sources/w1.account" ] || fail "a subscription error in the pane raised no account wait: $(ls -a "$m/state/.wait-sources" 2>&1)"
  backdate "$m" w1 31
  backdate "$m" w2 31
  cycle_for "$m" 120 grep -q 'relaunch.*w2' "$m/state/.account-outage/relaunch.log"
  [ "$(cat "$m/config/claude-account")" = "$m/acct/b" ] \
    || fail "the pin did not move to the recorded fallback: $(cat "$m/config/claude-account"; cat "$m/err")"
  cycle_for "$m" 20 test "$(grep -c '^jg-control .* relaunch ' "$m/sent" 2>/dev/null || echo 0)" -ge 2
  [ "$(grep -cE '^jg-control w[12] relaunch --note ' "$m/sent")" = 2 ] \
    || fail "a lane on the dead account was not relaunched: $(cat "$m/sent" 2>&1; cat "$m/state/.account-outage/relaunch.log" 2>&1)"
  ! grep -qE '^jg-control (wd|wo) ' "$m/sent" || fail "a finished lane or a lane on another account was relaunched: $(cat "$m/sent")"
  [ "$(grep -c '^raise ' "$m/cards")" = 1 ] || fail "the outage did not raise exactly one card: $(cat "$m/cards" 2>&1)"
  grep -q 'Renew the Claude account?' "$m/cards" || fail "the card does not ask the owner to renew: $(cat "$m/cards")"
  ! grep -q 'waiting-state' "$m/events" 2>/dev/null || fail "the recovery woke a model: $(cat "$m/events")"
  # The relaunched lanes show a quiet pane: the waits clear and the ledger holds the minutes.
  printf 'working on it\n> \n' > "$m/panes/1"
  cp "$m/panes/1" "$m/panes/2"
  printf 'working [at=%s]: back on the new account\n' "$(date +%s)" | tee -a "$m/state/w1.status" >> "$m/state/w2.status"
  cycle_for "$m" 120 test ! -e "$m/state/.waiting-timers/w1" -a ! -e "$m/state/.waiting-timers/w2"
  row=$(ledger_row "$m" w1)
  printf '%s\n' "$row" | grep -qE '	[0-9]+\.[0-9]	(owner|card)	recover	' \
    || fail "the ledger has no row with the outage minutes: $(cat "$m/data/metrics/escalations.tsv" 2>&1)"
  printf 'account outage: cleared in %s min, no model turn\n' "$(printf '%s' "$row" | cut -f5)"
  pass "a dead account moves its lanes to the next recorded fallback, relaunches only them, raises one card and records the minutes, with no model turn"
}

test_an_empty_fallback_list_raises_one_card_and_changes_nothing() {
  local m listed CYCLE_POLLS=100 PANES='1 2 3 4' ALERT_SECS=30 ESCALATE_SECS=90 CARD_SECS=600
  for listed in empty none; do
    m=$(account_outage_home "account-down-$listed")
    [ "$listed" = none ] || : > "$m/config/claude-account-fallbacks"
    cycle_for "$m" 120 test -e "$m/state/.waiting-timers/w1" -a -e "$m/state/.waiting-timers/w2"
    backdate "$m" w1 31
    backdate "$m" w2 31
    cycle_for "$m" 120 test -s "$m/cards"
    cycle "$m"
    [ "$(cat "$m/config/claude-account")" = "$m/acct/a" ] || fail "($listed) the pin moved with no recorded fallback: $(cat "$m/config/claude-account")"
    ! grep -q '^jg-control ' "$m/sent" 2>/dev/null || fail "($listed) a pane was relaunched with no recorded fallback: $(cat "$m/sent")"
    [ "$(grep -c '^raise ' "$m/cards")" = 1 ] || fail "($listed) the outage did not raise exactly one card: $(cat "$m/cards" 2>&1)"
  done
  pass "with no recorded fallback the outage raises one card, moves no pin and relaunches nothing"
}

test_a_working_account_is_not_treated_as_down() {
  local m CYCLE_POLLS=100 PANES='1 2 3 4' ALERT_SECS=30 ESCALATE_SECS=90 CARD_SECS=600
  m=$(account_outage_home account-up)
  printf '%s\n%s\n' "$m/acct/a" "$m/acct/b" > "$m/config/claude-account-fallbacks"
  printf '%s\n' "$m/acct/b" > "$m/config/claude-account"
  sed -i "s|acct/a|acct/b|" "$m/state/w1.meta" "$m/state/w2.meta"
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/w1"
  backdate "$m" w1 31
  cycle "$m"; cycle "$m"
  [ "$(cat "$m/config/claude-account")" = "$m/acct/b" ] || fail "an account that answers its probe was switched away: $(cat "$m/config/claude-account")"
  ! grep -q '^jg-control ' "$m/sent" 2>/dev/null || fail "a lane on a working account was relaunched: $(cat "$m/sent")"
  [ ! -s "$m/cards" ] || fail "a working account raised an outage card: $(cat "$m/cards")"
  pass "an account that answers its probe is not treated as down"
}

test_a_silent_worker_is_rung_and_clears_with_no_model_turn
test_an_unanswered_ring_is_relaunched_then_reaches_main
test_a_ready_recon_draft_is_forwarded_to_its_critic
test_a_dead_account_moves_the_lanes_to_the_recorded_fallback_with_no_model_turn
test_a_lane_blocked_for_the_herdr_lab_section_is_relaunched_once_with_it
test_an_empty_fallback_list_raises_one_card_and_changes_nothing
test_a_working_account_is_not_treated_as_down
test_a_stale_wake_names_its_task_and_reason
test_a_finished_landed_worker_is_cleaned_up_without_a_wake
test_a_finished_unlanded_worker_is_kept_and_wakes_with_its_reason
test_lead_idle_is_steered_without_interrupt
test_stuck_verdict_table
test_a_printed_assertion_never_raises_a_quota_wait
test_a_declared_quota_pause_is_a_wait
# A cycle is bounded by the scan, not by a fixed delay: the wake found on the
# last pane of a slow scan still reaches the queue.
test_a_slow_scan_reports_the_wake_it_found
test_question_and_quota_ride_the_chain_whatever_the_terminal_says
test_silent_worker_climbs_whatever_it_declared
test_busy_lead_is_steered_without_interrupt
test_lead_stuck_on_a_prompt_reaches_the_board
test_dead_lead_still_reaches_the_board_and_relaunch_represents
test_lead_supervision_not_running_is_a_main_wait
test_worker_dead_prompt_and_question_differ
test_two_hops_stuck_at_once
test_main_absent_board_card_still_fires
test_stalled_backlog_wakes_the_lead_and_main_and_refires
test_stalled_backlog_skips_open_card_and_full_lanes
test_stalled_backlog_quiet_when_work_starts_in_time
test_stalled_backlog_quiet_without_a_free_lane_or_a_ready_item
test_stalled_backlog_quiet_when_project_is_at_capacity
test_a_paused_home_silences_its_stalled_backlog_and_rings_when_it_lifts
test_ship_ready_line_goes_through_the_pr_check
test_watcher_handoff_gap_is_not_a_dead_watcher
test_ready_work_wakes_the_primary_home_too
test_a_merge_freeze_never_idles_free_lanes
test_a_fleet_pause_silences_ready_work_but_not_a_blocker
test_memory_refused_launch_reraises_when_admission_clears
test_green_unmerged_pr_climbs_lead_main_and_the_board
test_green_unmerged_pr_in_the_main_home_wakes_main_then_the_board
test_green_pr_stays_quiet_unless_it_is_green_unmerged_and_unheld_under_yolo
