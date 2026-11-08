#!/usr/bin/env bash
# Wake urgency routing (docs/watcher-continuity.md "Wake urgency classes"): the rule file
# assigns now, batch, or silent; a batched row cannot end the watcher cycle; and an urgent
# row from the same event still latches it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-wake-route)

route() {
  JG_HOME="$1" JG_STATE_OVERRIDE="$2" bash -c '
    . "$1/bin/jg-wake-lib.sh"; jg_wake_route_class "$2" "$3" "$4"' _ "$ROOT" "$3" "$4" "$5"
}

test_classes() {
  local home="$TMP_ROOT/classes" state="$TMP_ROOT/classes/state"
  mkdir -p "$state"
  assert_equals "$(route "$home" "$state" signal crew.turn-ended 'signal: x')" batch \
    "a turn-end must be batched, not woken on"
  assert_equals "$(route "$home" "$state" check startup-network 'check: MISSING')" now \
    "a startup failure must wake at once"
  assert_equals "$(route "$home" "$state" check "$state/board-gate.check.sh" \
    "check: $state/board-gate.check.sh: board ask routed to Overwatch, not a must: ask-mac-screen-grant - Allow screen recording? (record owd-1)")" batch \
    "a board ask without a must category must land in a digest, not wake a model"
  assert_equals "$(route "$home" "$state" check "$state/board-gate.check.sh" \
    "check: $state/board-gate.check.sh: merge landed with no board Evidence card: m1 https://example.test/o/r/pull/7")" now \
    "a merge with no board proof must still wake at once"
  assert_equals "$(route "$home" "$state" check "$state/tickets-stale.check.sh" \
    'tickets-stale: jg-1 says queued')" batch \
    "a staled tickets row is bookkeeping, not a decision"
  assert_equals "$(route "$home" "$state" check "$state/tickets-sync.check.sh" \
    'tickets-sync: 1 homes read; 2 tickets changed')" batch \
    "a tickets poll summary must not wake a model"
  assert_equals "$(route "$home" "$state" check "$state/route-chain.check.sh" \
    'route-chain: head=route:commandcode/x down=route:ollama-cloud/y(ollama_credit_empty)')" now \
    "a changed route state must wake at once"
  assert_equals "$(route "$home" "$state" check "$state/route-chain.check.sh" \
    'route-chain probe: quota-axi timed out')" batch \
    "any other route-chain output rides the digest"
  printf 'working [at=1]: editing\n' > "$state/lane.status"
  printf 'needs-decision [at=2]: pick one\n' > "$state/pick.status"
  assert_equals "$(route "$home" "$state" signal pick.status "signal: x")" now \
    "a captain decision must wake at once"
  printf 'silent signal *.status working*\nnow * * *\n' > "$home.routing"
  assert_equals "$(JG_WAKE_ROUTING="$home.routing" route "$home" "$state" signal lane.status x)" \
    silent "a home rule must be able to record an event only"
  assert_equals "$(route "$home" "$state" signal lane.status "signal: x")" batch \
    "a progress line rides the digest unless a home rule settles it"
  pass "the rule file assigns now, batch, and silent"
}

test_silent_is_recorded_not_queued() (
  dir=$(make_case route-silent)
  mkdir -p "$dir/config"
  printf 'silent signal *.status working*\nnow * * *\n' > "$dir/config/wake-routing"
  printf 'working [at=1]: editing\n' > "$dir/state/lane.status"
  JG_HOME="$dir" append_wake "$dir/state" signal lane.status "signal: x"
  [ ! -s "$dir/state/.wake-queue" ] || fail "a silent event reached the queue"
  assert_grep "lane.status" "$dir/state/.wake-settled" "a silent event must stay readable"
  pass "a home's silent rule records an event and never queues it"
)

test_batch_is_gated_and_urgent_latches() (
  dir=$(make_case route-gate)
  out=$(JG_STATE_OVERRIDE="$dir/state" bash -c '. "$1/bin/jg-wake-lib.sh"
    jg_wake_append signal crew.turn-ended "signal: crew.turn-ended"
    printf "batch=%s\n" "${JG_WAKE_LAST:-}"
    printf "done [at=2]: done: finished\n" > "$STATE/pick.status"
    jg_wake_append signal pick.status "signal: $STATE/pick.status"
    printf "urgent=%s\n" "${JG_WAKE_CYCLE_URGENT:-}"' _ "$ROOT" 2>&1)
  assert_contains "$out" "batch=batch:crew.turn-ended" "a batched row hands its class on"
  assert_contains "$out" "urgent=1" "an urgent row must latch the cycle"
  assert_contains "$(JG_STATE_OVERRIDE="$dir/state" bash -c '. "$1/bin/jg-push-transition-lib.sh"
    JG_WAKE_LAST=batch:crew.turn-ended
    wake "signal: crew.turn-ended" && echo gated' _ "$ROOT" 2>&1)" gated \
    "a batched row must not end the watcher cycle"
  pass "batch rows are gated and an urgent row latches the cycle"
)

test_no_model_wakes() (
  dir=$(make_case route-nomodel)
  state="$dir/state"
  mkdir -p "$dir/config" "$dir/homes/alpha" "$dir/homes/beta"
  printf 'alpha\n' > "$dir/homes/alpha/.jg-squad-lead-home"
  printf 'beta\n' > "$dir/homes/beta/.jg-squad-lead-home"
  printf 'kind=squad_lead\nhome=%s\n' "$dir/homes/alpha" > "$state/alpha.meta"
  printf 'kind=squad_lead\nhome=%s\n' "$dir/homes/beta" > "$state/beta.meta"
  printf 'alpha\n' > "$dir/config/parked-homes"
  cp "$ROOT/defaults/wake-routing" "$dir/config/wake-routing"
  printf 'paused [at=1]: ack\n' | tee "$state/alpha.status" > "$state/beta.status"
  assert_equals "$(route "$dir" "$state" signal alpha.status x)" silent "a paused home's pause acknowledgement is settled"
  assert_equals "$(route "$dir" "$state" signal beta.status x)" batch "a live home's pause rides the digest"
  assert_equals "$(route "$dir" "$state" check alpha-wait-owner 'check: waiting-state alpha (x)')" silent "a timer on a paused home is settled"
  assert_equals "$(route "$dir" "$state" check beta-wait-owner 'check: waiting-state beta (x)')" now "a timer on a live home still wakes"
  relaunch='check: squad_lead beta auto-relaunched after dead (pane)'
  assert_equals "$(route "$dir" "$state" check squad-lead-relaunch-beta-9 "$relaunch")" now "a relaunch nobody asked for still wakes"
  printf '%s\tbeta\n' "$(date +%s)" > "$state/.squad-lead-restart-pass"
  assert_equals "$(route "$dir" "$state" check squad-lead-relaunch-beta-9 "$relaunch")" silent "a relaunch the restart pass caused is settled"
  printf '%s\tbeta\n' "$(( $(date +%s) - 9999 ))" > "$state/.squad-lead-restart-pass"
  assert_equals "$(route "$dir" "$state" check squad-lead-relaunch-beta-9 "$relaunch")" now "an old restart pass explains nothing"
  assert_equals "$(route "$dir" "$state" check rearm-resurface 'check: rearm-resurface')" silent "a re-arm with nothing queued is settled"
  printf 'blocked [at=2]: stuck\n' > "$state/beta.status"
  append_wake "$state" signal beta.status 'signal: x'
  assert_equals "$(route "$dir" "$state" check rearm-resurface 'check: rearm-resurface')" now "a re-arm with an urgent row queued still wakes"
  assert_equals "$(route "$dir" "$state" stale w:1 "stale: w:1 (unread juggernaut instruction: /x/a.inbox/002.msg stays unhandled - busy; no doorbell was typed, and it lands as soon as that clears, so no interrupt is needed unless the worker is wedged)")" silent "a busy-deferred doorbell report is settled"
  assert_equals "$(route "$dir" "$state" stale w:1 "stale: w:1 (unread juggernaut instruction: /x/a.inbox/002.msg still unhandled after 3 doorbell delivery attempts with an idle pane; inspect the worker)")" now "a doorbell stuck with an idle pane still wakes"
  assert_equals "$(route "$dir" "$state" signal crew.turn-ended 'signal: crew.turn-ended')" batch "a stop-hook turn end is batched, never a turn of its own"
  printf 'set silence-cap-per-hour 2\nsilent signal *.status paused*\nnow * * *\n' > "$dir/cap.routing"
  for i in 1 2 3; do printf 'paused [at=1]: x\n' > "$state/a$i.status"; JG_WAKE_ROUTING="$dir/cap.routing" JG_HOME="$dir" append_wake "$state" signal "a$i.status" 'signal: x'; done
  assert_equals "$(wc -l < "$state/.wake-silenced" | tr -d ' ')" 2 "the per-hour cap counts settled wakes"
  pass "pause acks, relaunch notices, re-arms and timers on paused homes settle; a cap bounds them"
)

# Recorded wakes of the real homes (tests/fixtures/wake-routing/recorded.tsv: the class the
# shared rules give, then kind, key, payload) replayed through the rule file.
test_recorded_wakes() (
  dir=$(make_case route-recorded)
  while IFS=$'\t' read -r want kind key payload; do
    got=$(route "$dir" "$dir/state" "$kind" "$key" "$payload")
    assert_equals "$got" "$want" "recorded wake $kind $key: $payload"
    case "$payload" in
      *"fleet-pulse 2h"*) ;;  # a trend report that names others' alarms; it rides the digest by rule
      *"needs-decision"*|*"STALLED"*|*"failed"*|*"security"*|*"merge landed with no board"*)
        assert_equals "$got" now "a decision, stall, failure or security wake must stay now: $payload" ;;
    esac
  done < "$ROOT/tests/fixtures/wake-routing/recorded.tsv"
  pass "recorded wakes keep the classes the shared rules give, and decisions stay now"
)

test_heartbeat_and_status_classes() (
  dir=$(make_case route-heartbeat)
  state="$dir/state"
  hb="$state/fleet-heartbeat.check.sh"
  pre="check: $hb: fleet heartbeat:"
  assert_equals "$(route "$dir" "$state" check "$hb" "$pre firstmate-addons GAP for 0s - 1 open wait(s) climbing their ladder, 20 paused wait(s)")" silent "a gap that is only open waits settles"
  assert_equals "$(route "$dir" "$state" check "$hb" "$pre firstmate-addons GAP for 9s - 2 ready, 3 of 4 lanes working, 19 paused wait(s)")" batch "a gap with ready work rides the digest"
  assert_equals "$(route "$dir" "$state" check "$hb" "$pre firstmate-addons MOVING again")" batch "a recovery asks for nothing"
  assert_equals "$(route "$dir" "$state" check "$hb" "$pre a STALLED for 9s - work waits but no supervision beat for 999s $pre b GAP for 0s - 1 open wait(s) climbing their ladder")" now "a stall in the same report keeps waking"
  assert_equals "$(route "$dir" "$state" check "$hb" "$pre lane x is done but still open - land it and close it")" now "a finished lane nobody closed keeps waking"
  for word in working resolved paused; do
    printf '%s [at=1]: x\n' "$word" > "$state/$word.status"
    assert_equals "$(route "$dir" "$state" signal "$word.status" "signal: $word.status")" batch "a $word status line asks for nothing"
  done
  for word in needs-decision blocked failed "done"; do
    printf '%s [at=1]: x\n' "$word" > "$state/$word.status"
    assert_equals "$(route "$dir" "$state" signal "$word.status" "signal: $word.status")" now "a $word status line keeps waking"
  done
  printf 'done [key=child-pr-t] [at=1]: child t PR ready: https://x/pull/1 mode=direct-PR\n' > "$state/lead.status"
  assert_equals "$(route "$dir" "$state" signal lead.status x)" batch "the PR-ready report rides the digest, like every routine lead line"
  printf 'done [key=child-outcome-t-done-ab12cd34] [at=1]: child t done: PR https://x/pull/1 at head abc\n' > "$state/lead.status"
  assert_equals "$(route "$dir" "$state" signal lead.status x)" batch "the ledger copy of a reported PR is routine too"
  printf 'done [key=child-outcome-r-done-ab12cd34] [at=1]: child r done: findings in data/r/report.md\n' > "$state/lead.status"
  assert_equals "$(route "$dir" "$state" signal lead.status x)" batch "a lead's ledger copy of a child's outcome rides the digest"
  printf 'failed [key=child-outcome-r-failed-ab12cd34] [at=1]: child r failed: the build broke\n' > "$state/lead.status"
  assert_equals "$(route "$dir" "$state" signal lead.status x)" now "a failed child keeps waking"
  printf 'done [key=merged-t] [at=1]: merged t https://x/pull/1\n' > "$state/lead.status"
  assert_equals "$(route "$dir" "$state" signal lead.status x)" batch "a task merge notice asks for nothing"
  printf 'done [key=release-c3] [at=1]: RELEASE c-3 IS ON MAIN\n' > "$state/lead.status"
  assert_equals "$(route "$dir" "$state" signal lead.status x)" now "a release keeps waking"
  assert_equals "$(route "$dir" "$state" check waiting-timer-a-g1-default-owner-again "check: waiting-state a (paused, observed 9s, level=owner; still open, owning lead must recheck and unblock) id=x")" batch "a paused wait at the owning lead rides the digest"
  assert_equals "$(route "$dir" "$state" check waiting-timer-a-g1-default-owner "check: waiting-state a (blocked key=default, observed 9s, level=owner; owning lead must recheck and unblock) id=x")" now "a blocked wait keeps waking"
  assert_equals "$(route "$dir" "$state" stale w:1 "stale: w:1 (paused 9s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)")" batch "a declared pause being rechecked rides the digest"
  assert_equals "$(route "$dir" "$state" stale w:1 "stale: w:1 (paused 9s, awaiting external - the declared clearing time has passed, rechecked on a long cadence not a wedge; confirm the wait cleared)")" now "a pause past its clearing time keeps waking"
  pass "heartbeat, status-line, lead-channel and wait classes settle repeats and keep decisions waking"
)

test_restart_and_beacon_classes() (
  dir=$(make_case route-beacon)
  state="$dir/state"
  mkdir -p "$state/.watch.lock"
  body="Supervision is needed but the watcher beacon is 9m old and no turn is running, so nothing is watching the fleet."
  assert_equals "$(route "$dir" "$state" check sentinel-beacon-old "$body")" now "an old beacon with no live watcher keeps waking"
  sleep 20 & pid=$!
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/jg-home"
  printf '%s\n' "$ROOT/bin/jg-watch.sh" > "$state/.watch.lock/watcher-path"
  JG_HOME="$dir" bash -c '. "$1/bin/jg-wake-lib.sh"; jg_pid_identity "$2"' _ "$ROOT" "$pid" > "$state/.watch.lock/pid-identity"
  assert_equals "$(route "$dir" "$state" check sentinel-beacon-old "$body")" silent "an old beacon under a live watcher settles"
  printf '99999999\n' > "$state/.watch.lock/pid"
  assert_equals "$(route "$dir" "$state" check sentinel-beacon-old "$body")" now "an old beacon whose watcher is gone keeps waking"
  lead="check: squad_lead beta supervision not running while it has work under way; it was told to re-arm, and the wait escalates until it does"
  assert_equals "$(route "$dir" "$state" check squad-lead-supervision-beta-1 "$lead")" now "a re-arm nobody caused keeps waking"
  printf '%s\tbeta\n' "$(date +%s)" > "$state/.squad-lead-restart-pass"
  assert_equals "$(route "$dir" "$state" check squad-lead-supervision-beta-1 "$lead")" silent "a re-arm after Main's restart pass settles"
  pass "an old beacon settles only under a live watcher, and a restart-pass re-arm settles"
)

test_repeat_and_override() (
  dir=$(make_case route-repeat)
  state="$dir/state"; mkdir -p "$dir/config"
  printf 'done [at=1]: PR https://x/pull/1 ready\n' > "$state/t.status"
  first=$(JG_STATE_OVERRIDE="$state" JG_HOME="$dir" bash -c '. "$1/bin/jg-wake-lib.sh"; jg_wake_append signal t.status "signal: t.status"; printf "%s" "$JG_WAKE_LAST"' _ "$ROOT")
  second=$(JG_STATE_OVERRIDE="$state" JG_HOME="$dir" bash -c '. "$1/bin/jg-wake-lib.sh"; jg_wake_append signal t.status "signal: t.status"; printf "%s" "$JG_WAKE_LAST"' _ "$ROOT")
  printf 'done [at=2]: PR https://x/pull/1 ready at a new head\n' > "$state/t.status"
  third=$(JG_STATE_OVERRIDE="$state" JG_HOME="$dir" bash -c '. "$1/bin/jg-wake-lib.sh"; jg_wake_append signal t.status "signal: t.status"; printf "%s" "$JG_WAKE_LAST"' _ "$ROOT")
  assert_equals "$first" now:t.status "the first outcome line wakes"
  assert_equals "$second" batch:t.status "the same outcome line again is a repeat"
  assert_equals "$third" now:t.status "a new outcome line wakes again"
  # A home's small file wins for what it names; everything else is the shared file's.
  printf 'now check *fleet-heartbeat.check.sh *climbing their ladder*\n' > "$dir/config/wake-routing"
  ladder="check: x/fleet-heartbeat.check.sh: fleet heartbeat: a GAP for 0s - 1 open wait(s) climbing their ladder"
  assert_equals "$(route "$dir" "$state" check x/fleet-heartbeat.check.sh "$ladder")" now "a home rule wins over the shared file"
  assert_equals "$(route "$dir" "$state" check x/fleet-heartbeat.check.sh "check: x: fleet heartbeat: a MOVING again")" batch "what the home does not name falls through to the shared file"
  printf 'set re-alert-minutes 0\n' > "$dir/config/wake-routing"
  assert_equals "$(JG_HOME="$dir" bash -c '. "$1/bin/jg-wake-lib.sh"; _jg_wake_rule_set re-alert-minutes 30' _ "$ROOT")" 0 "a home value wins over the shared set"
  pass "a repeated outcome line batches, and a home file layers over the shared file"
)

# A ship's PR-ready done line wakes no model when core/merge-on-green owns the PR: the watcher's own
# merge or alert wakes the lead. Every other done line, and every other word, keeps waking.
test_merge_owned_done() (
  dir=$(make_case route-merge-owned)
  state="$dir/state"
  pr=https://example.test/o/r/pull/7
  head=0123456789abcdef0123456789abcdef01234567
  ready="done [at=1]: PR $pr checks green"
  task() {  # <task> <status line> <meta rows...>
    local t=$1 line=$2; shift 2
    printf '%s\n' "$line" > "$state/$t.status"
    : > "$state/$t.meta"
    [ "$#" -eq 0 ] || printf '%s\n' "$@" > "$state/$t.meta"
  }
  task yolo "$ready" kind=ship yolo=on "pr=$pr" "pr_head=$head"
  assert_equals "$(route "$dir" "$state" signal yolo.status x)" silent "an owned PR-ready done line is settled"
  JG_HOME="$dir" append_wake "$state" signal yolo.status "signal: yolo.status"
  [ ! -s "$state/.wake-queue" ] || fail "a settled done line reached the queue"
  assert_grep "yolo.status" "$state/.wake-settled" "a settled done line must stay in the durable wake log"
  task appr "$ready" yolo=off "pr=$pr" "pr_head=$head" merge=approved
  assert_equals "$(route "$dir" "$state" signal appr.status x)" silent "a lead-recorded merge approval is owned too"
  task nokind "$ready" yolo=on "pr=$pr" "pr_head=$head"
  assert_equals "$(route "$dir" "$state" signal nokind.status x)" silent "a record with no kind is a ship"
  task off "$ready" yolo=off "pr=$pr" "pr_head=$head"
  assert_equals "$(route "$dir" "$state" signal off.status x)" batch "a PR the watcher does not own rides the merge-ready batch"
  task manual "$ready" yolo=on "pr=$pr" "pr_head=$head" merge=manual
  assert_equals "$(route "$dir" "$state" signal manual.status x)" batch "merge=manual rides the merge-ready batch"
  task nopr "$ready" kind=ship yolo=on
  assert_equals "$(route "$dir" "$state" signal nopr.status x)" batch "a done line with no recorded PR rides the merge-ready batch"
  task nohead "$ready" kind=ship yolo=on "pr=$pr"
  assert_equals "$(route "$dir" "$state" signal nohead.status x)" batch "a PR with no recorded head is not the watcher's yet, so it rides the merge-ready batch"
  : > "$state/nometa.status"; printf '%s\n' "$ready" > "$state/nometa.status"
  assert_equals "$(route "$dir" "$state" signal nometa.status x)" now "a task with no record keeps waking"
  task other "done [at=1]: PR https://example.test/o/r/pull/8" kind=ship yolo=on "pr=$pr" "pr_head=$head"
  assert_equals "$(route "$dir" "$state" signal other.status x)" batch "a done line naming another PR rides the merge-ready batch"
  task noreport "done [at=1]: ready branch wf5, nothing pushed" kind=ship yolo=on "pr=$pr" "pr_head=$head"
  assert_equals "$(route "$dir" "$state" signal noreport.status x)" now "a done line that reports no PR keeps waking"
  task merged "done [at=1]: merged $pr" kind=ship yolo=on "pr=$pr" "pr_head=$head"
  assert_equals "$(route "$dir" "$state" signal merged.status x)" now "the merge outcome keeps waking"
  task scout "done [at=1]: PR $pr" kind=scout yolo=on "pr=$pr" "pr_head=$head"
  assert_equals "$(route "$dir" "$state" signal scout.status x)" now "a Recon result keeps waking"
  task recon "done [at=1]: findings in data/recon/report.md" kind=scout
  assert_equals "$(route "$dir" "$state" signal recon.status x)" now "a Recon report keeps waking"
  task spent "$ready" kind=ship yolo=on "pr=$pr" "pr_head=$head"
  mkdir -p "$dir/data/jg-merge-on-green"; printf '%s\n' "$head" > "$dir/data/jg-merge-on-green/spent.head"
  assert_equals "$(route "$dir" "$state" signal spent.status x)" batch "a head the watcher already attempted rides the merge-ready batch"
  printf 'done [at=3]: PR %s checks green\n' "$pr" > "$state/spent.status"
  printf 'cafe\n' > "$dir/data/jg-merge-on-green/spent.head"
  assert_equals "$(route "$dir" "$state" signal spent.status x)" silent "a new head is the watcher's again"
  assert_equals "$(route "$dir" "$state" check "$state/merge-on-green.check.sh" "check: $state/merge-on-green.check.sh: merge-on-green: NOT merging yolo $pr: checks lint refused: x; lead: act")" now \
    "the watcher's refusal alert wakes the lead, since the done line no longer does"
  for word in failed blocked needs-decision; do
    task "w$word" "$word [at=1]: PR $pr" kind=ship yolo=on "pr=$pr" "pr_head=$head"
    assert_equals "$(route "$dir" "$state" signal "w$word.status" x)" now "a $word line on an owned PR keeps waking"
  done
  pass "an owned PR-ready done line is settled; unowned, PR-less, failed and Recon lines keep waking"
)

# A signal row keeps the status word of the line that woke it, so an audit of wake routing can read
# it after cleanup removed the status file and the queue row. Routing never reads the word.
test_status_word_is_kept() (
  dir=$(make_case route-word)
  state="$dir/state"
  mkdir -p "$dir/config"
  printf 'silent signal *.status working*\nnow * * *\n' > "$dir/config/wake-routing"
  printf 'blocked [at=2]: stuck on a decision\n' > "$state/urgent.status"
  printf 'working [at=1]: editing\n' > "$state/quiet.status"
  JG_HOME="$dir" append_wake "$state" signal urgent.status 'signal: x'
  JG_HOME="$dir" append_wake "$state" signal quiet.status 'signal: x'
  JG_HOME="$dir" append_wake "$state" check rearm-resurface 'check: rearm-resurface'
  assert_grep '"key":"urgent.status","payload":"signal: x","class":"now","word":"blocked"' "$state/.wake-bus.events.jsonl" \
    "a queued signal event must carry its status word"
  assert_grep '"class":"silent","word":"working"' "$state/.wake-bus.events.jsonl" "a settled signal event must carry its status word"
  assert_equals "$(awk -F '\t' '$4 == "quiet.status" { print NF ":" $6 }' "$state/.wake-settled")" "6:working" \
    "a settled row must list the word after its payload"
  assert_equals "$(awk -F '\t' '$4 == "urgent.status" { print NF }' "$state/.wake-queue")" 5 \
    "the queue row keeps its five fields, so every reader of it is unchanged"
  assert_grep 'signal: urgent.status signal: x [status=blocked]' "$state/chat.jsonl" "the fleet note must name the word"
  # Cleanup removes the status file and prunes the task's queue row; the word stays on record.
  rm -f "$state/urgent.status"
  JG_STATE_OVERRIDE="$state" bash -c '. "$1/bin/jg-wake-lib.sh"; jg_wake_queue_prune_task "$2" urgent' _ "$ROOT" "$state"
  [ -z "$(awk -F '\t' '$4 == "urgent.status"' "$state/.wake-queue")" ] || fail "the cleanup left the queue row"
  assert_grep '"class":"now","word":"blocked"' "$state/.wake-bus.events.jsonl" "the word must outlive the status file"
  assert_grep '[status=blocked]' "$state/chat.jsonl" "the word must outlive the queue row"
  # Old records without a word still read, and a key with no status line gets none.
  assert_equals "$(awk -F '\t' '$3 == "check" { print NF }' "$state/.wake-queue")" 5 "a row with no word stays five fields"
  printf '{"v":1,"id":"settled/old/1","home":"old","where":"settled","at":1,"rseq":1000,"kind":"signal","key":"old.status","payload":"signal: x","class":"silent"}\n' >> "$state/.wake-bus.events.jsonl"
  JG_HOME="$dir" JG_STATE_OVERRIDE="$state" "$ROOT/bin/jg-wake-bus.sh" render
  assert_equals "$(awk -F '\t' '$4 == "old.status" { print NF }' "$state/.wake-settled")" 5 "an old settled row must still read"
  assert_contains "$(JG_HOME="$dir" JG_STATE_OVERRIDE="$state" "$ROOT/bin/jg-wake.sh" settled 5)" old.status "an old row must list"
  pass "a signal wake keeps its status word through cleanup, and old rows without one still read"
)

result=0
test_classes || result=1
test_no_model_wakes || result=1
test_silent_is_recorded_not_queued || result=1
test_batch_is_gated_and_urgent_latches || result=1
test_recorded_wakes || result=1
test_heartbeat_and_status_classes || result=1
test_restart_and_beacon_classes || result=1
test_repeat_and_override || result=1
test_merge_owned_done || result=1
test_status_word_is_kept || result=1
exit "$result"
