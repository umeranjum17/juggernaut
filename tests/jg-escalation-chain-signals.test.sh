#!/usr/bin/env bash
set -eu
# shellcheck source=tests/jg-escalation-chain-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/jg-escalation-chain-fixture.sh"

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
claude-account|account|● Working\nClaude Code can't use your Claude subscription\n>\x20
claude-quota|quota|⎿ You've hit your limit · resets 3pm\n>\x20
codex-quota|quota|■ You've hit your usage limit. Upgrade or try again at 9:41 PM.\n>\x20
pi-quota|quota|Error: 429 Too Many Requests - rate limit exceeded\n>\x20
opencode-quota|quota|Error: insufficient_quota - You exceeded your current quota\n>\x20
opencode-errors|errors|┃  User not found.\n┃\n▣  Build · Some Model\n┃  User not found.\n┃\n▣  Build · Some Model\n┃  User not found.\n┃\n>\x20
pi-errors|errors|Error: Provider returned error\nretrying\nError: Provider returned error\nretrying\nError: Provider returned error\n>\x20
errors-once|none|┃  User not found.\n┃\nI will look at the key next.\n>\x20
errors-prose|none|I will check the config.\nI will check the config.\nI will check the config.\n>\x20
claude-idle|none|● Done. All checks pass.\n\n>\x20
printed-assertion|none|● Running the classifier suites with TMPDIR on disk.\nnot ok 3 - the temp dir refuses a write\n  disk quota exceeded; with TMPDIR on disk they pass.\n● Done. 13 checks green, the PR is open.\n>\x20
worker-prose|none|I will press Enter to select the file, then continue.\n>\x20
code-output|none|ok - 12 tests passed\nEnter the value of x\n>\x20
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

test_stuck_verdict_table
test_a_printed_assertion_never_raises_a_quota_wait
test_a_declared_quota_pause_is_a_wait
test_a_slow_scan_reports_the_wake_it_found
test_question_and_quota_ride_the_chain_whatever_the_terminal_says
test_silent_worker_climbs_whatever_it_declared
test_ready_work_wakes_the_primary_home_too
test_a_merge_freeze_never_idles_free_lanes
test_a_fleet_pause_silences_ready_work_but_not_a_blocker
test_memory_refused_launch_reraises_when_admission_clears
