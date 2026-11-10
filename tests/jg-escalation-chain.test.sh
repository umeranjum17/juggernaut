#!/usr/bin/env bash
set -eu
# shellcheck source=tests/jg-escalation-chain-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/jg-escalation-chain-fixture.sh"

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
  wire_lead_check "$l"
  printf 'lead1\n' > "$l/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$m" > "$l/.jg-squad-lead-parent"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$l/state/w1.meta"
  printf 'needs-decision [key=q]: pick a database\n' > "$l/state/w1.status"
  prime_status_seen "$l/state" "$l/state/w1.status"
  printf 'session-one\n' > "$l/state/.lock-session"
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


test_a_stale_wake_names_its_task_and_reason
test_a_finished_landed_worker_is_cleaned_up_without_a_wake
test_a_finished_unlanded_worker_is_kept_and_wakes_with_its_reason
test_lead_idle_is_steered_without_interrupt
test_busy_lead_is_steered_without_interrupt
test_lead_stuck_on_a_prompt_reaches_the_board
test_dead_lead_still_reaches_the_board_and_relaunch_represents
test_lead_supervision_not_running_is_a_main_wait
test_worker_dead_prompt_and_question_differ
test_two_hops_stuck_at_once
test_main_absent_board_card_still_fires
test_watcher_handoff_gap_is_not_a_dead_watcher
