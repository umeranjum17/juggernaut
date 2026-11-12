#!/usr/bin/env bash
set -eu
# shellcheck source=tests/jg-escalation-chain-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/jg-escalation-chain-fixture.sh"

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

# The slow-delivery alert (bin/jg-alert.sh) of a task: its state word, empty when there is none.
slow_word() {  # <home> <task>
  JG_STATE_OVERRIDE="$1/state" bash "$FORK/bin/jg-alert.sh" word "slow-delivery--$2" 2>/dev/null || true
}

test_green_unmerged_pr_raises_slow_delivery_once_and_resolves_on_merge() {
  local l
  l=$(home green-lead)
  pr_task "$l" signoff on
  PANES=1 cycle "$l"
  [ -f "$l/state/.green-pr/signoff" ] || fail "a green ready PR under yolo was not recorded: $(cat "$l/err")"
  [ -z "$(slow_word "$l" signoff)" ] || fail "the PR raised an alert before it had waited 15 minutes"
  backdate_green "$l" signoff 1000
  PANES=1 cycle "$l"
  [ "$(slow_word "$l" signoff)" = open ] || fail "a PR green for 15 minutes did not raise the slow-delivery alert: $(cat "$l/err")"
  [ "$(JG_STATE_OVERRIDE="$l/state" bash "$FORK/bin/jg-alert.sh" show slow-delivery--signoff | sed -n 's/^rung=//p')" = 1 ] || fail "the alert did not start at rung 1"
  PANES=1 cycle "$l"
  [ "$(JG_STATE_OVERRIDE="$l/state" bash "$FORK/bin/jg-alert.sh" list | grep -c signoff)" = 1 ] || fail "a second tick raised the alert again"
  [ ! -e "$l/state/.wait-sources/signoff.greenpr" ] || fail "the old green-PR wait source was written"
  forge "$l" MERGED false UNKNOWN aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  PANES=1 cycle "$l"
  [ "$(slow_word "$l" signoff)" = resolved ] || fail "the merge did not resolve the alert: $(slow_word "$l" signoff)"
  pass "a green ready PR left unmerged under yolo raises the slow-delivery alert once after 15 minutes and resolves it on merge"
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
  [ ! -e "$m/state/.green-pr/signoff" ] && [ -z "$(slow_word "$m" signoff)" ] || fail "an unreadable forge answer was treated as green"
  # A recorded hold with a reason ends it; a new head re-arms the clock.
  m=$(home green-held)
  pr_task "$m" signoff on
  PANES=1 cycle "$m"
  backdate_green "$m" signoff 1000
  PANES=1 cycle "$m"
  [ "$(slow_word "$m" signoff)" = open ] || fail "fixture: the wait never started"
  printf 'paused [at=2]: waiting for the vendor to confirm the release window\n' >> "$m/state/signoff.status"
  prime_status_seen "$m/state" "$m/state/signoff.status"
  PANES=1 cycle "$m"
  [ "$(slow_word "$m" signoff)" = resolved ] || fail "a recorded pause with a reason did not clear the wait"
  printf 'done [at=3]: PR https://github.com/octo/widgets/pull/7\n' >> "$m/state/signoff.status"
  prime_status_seen "$m/state" "$m/state/signoff.status"
  PANES=1 cycle "$m"
  [ -f "$m/state/.green-pr/signoff" ] && [ "$(slow_word "$m" signoff)" = resolved ] || fail "the clock did not restart from zero after the pause ended"
  backdate_green "$m" signoff 1000
  PANES=1 cycle "$m"
  [ "$(slow_word "$m" signoff)" = open ] || fail "the wait did not return after the pause ended and 15 minutes passed"
  forge "$m" OPEN false CLEAN bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  PANES=1 cycle "$m"
  [ "$(slow_word "$m" signoff)" = resolved ] || fail "a new head did not re-arm the clock"
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


test_stalled_backlog_wakes_the_lead_and_main_and_refires
test_stalled_backlog_quiet_when_work_starts_in_time
test_stalled_backlog_quiet_without_a_free_lane_or_a_ready_item
test_stalled_backlog_skips_open_card_and_full_lanes
test_stalled_backlog_quiet_when_project_is_at_capacity
test_a_paused_home_silences_its_stalled_backlog_and_rings_when_it_lifts
test_ship_ready_line_goes_through_the_pr_check
test_green_unmerged_pr_raises_slow_delivery_once_and_resolves_on_merge
test_green_pr_stays_quiet_unless_it_is_green_unmerged_and_unheld_under_yolo
