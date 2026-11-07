#!/usr/bin/env bash
# tests/jg-decisions-reconcile.test.sh - the hourly board reconcile clears what
# the durable records already answer, and nothing else (bin/jg-decisions-reconcile.sh).
#
# The replay cases are the recorded kinds from the live board: a card the captain
# answered on an earlier card sweep, a card whose key a status log resolved, a
# merge card whose PR merged, a card whose task is closed, and the false-block
# cases that must survive - a card whose lane is still in flight, and a card
# whose block was declared but never caused the card to be answered.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-decisions-reconcile)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
RECONCILE="$ROOT/bin/jg-decisions-reconcile.sh"
AT=2026-10-30T12:00:00Z

# A fixture home plus a board the fake sign-off-axi reads and edits, so a real
# dismiss removes the card and a second pass sees the truth.
setup() {  # <name> -> echoes the case dir
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/data" "$d/fakebin" "$d/so/.sign-off"
  jg_test_beads_home "$d/home"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  : > "$d/so/.sign-off/decisions.answers.jsonl"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1
shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
case "$cmd" in
  answers) jq -s 'reduce .[] as $a ({}; .[$a.key] = ($a | del(.key)))' \
    "${board%.json}.answers.jsonl" 2>/dev/null || printf '{}\n' ;;
  list) jq -c '{decisions: [.items[] | {key, filer, dismissed}]}' "$board" ;;
  dismiss) key=$1
    printf 'dismiss %s\n' "$*" >> "$SIGNOFF_LOG"
    jq --arg k "$key" '.items |= map(select(.key != $k))' "$board" > "$board.tmp" \
      && mv "$board.tmp" "$board" ;;
esac
SH
  chmod +x "$d/fakebin/sign-off-axi"
  printf '%s\n' "$d"
}

run() {  # <case-dir> [args...]
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" \
    SIGN_OFF_HOME="$d/so" SIGNOFF_LOG="$d/signoff.log" "$RECONCILE" "$@" 2>&1
}

# Write the board from `<key>[:<filer>]` arguments, one item each.
board() {  # <case-dir> <key[:filer]>...
  local d=$1
  shift
  local items='[]' spec key filer
  for spec in "$@"; do
    key=${spec%%:*}
    filer=''
    [ "$spec" = "$key" ] || filer=${spec#*:}
    items=$(printf '%s' "$items" | jq -c --arg k "$key" --arg f "$filer" '. + [{key: $k, filer: $f}]')
  done
  printf '{"schema":2,"items":%s}\n' "$items" > "$d/so/.sign-off/decisions.json"
}

answer() {  # <case-dir> <key>
  printf '{"key":"%s","answer":"yes","label":"yes","close":"done","at":"%s"}\n' "$2" "$AT" \
    >> "$1/so/.sign-off/decisions.answers.jsonl"
}

bd_() { BEADS_DIR=$(cat "$1/config/beads-dir") "$ROOT/bin/jg-beads.sh" "${@:2}"; }

lane() {  # <case-dir> <task-id> <state>; a Beads row in that state
  local d=$1 id=$2 state=$3
  jg_test_add "$d/home" "$id" "[feature] $id work"
  case "$state" in
    in_flight) jg_test_backlog "$d/home" start "$id" >/dev/null ;;
    done) jg_test_backlog "$d/home" start "$id" >/dev/null && jg_test_backlog "$d/home" done "$id" >/dev/null ;;
  esac
}

merge_card() {  # <case-dir> <task-id> <pull-url>; meta pr= and a sealed merge marker
  local d=$1 id=$2 url=$3 provider host path number
  printf 'pr=%s\n' "$url" > "$d/home/state/$id.meta"
  case "$url" in
    https://github.com/*) provider=github host=github.com ;;
    *) return 1 ;;
  esac
  path=${url#https://github.com/}
  path=${path%%/pull/*}
  number=${url##*/}
  { printf 'jg-pr-poll-merge-notified-v1\n%s\n%s\n%s\n%s\n' "$provider" "$host" "$path" "$number" \
      > "$d/home/state/$id.pr-poll-merge-notified"
    chmod 600 "$d/home/state/$id.pr-poll-merge-notified"; }
}

cleared() {  # <case-dir> -> the log's cleared card keys, one per line
  cut -f1 "$1/home/state/decisions-reconcile.log" 2>/dev/null
}

held_lane() {  # <case-dir> <task-id> <hold-kind> <hold-reason>; a held Beads row
  local d=$1 id=$2
  jg_test_add "$d/home" "$id" "[feature] $id work"
  bd_ "$d/home" update "$id" --status on_hold --set-metadata "hold_reason=$4" --set-metadata "hold_kind=$3" >/dev/null \
    || fail "could not hold $id"
}

# The recorded case: two holds created with bin/jg-captain-hold.sh carried the
# captain's own stop order, and a card built from that text reached his phone.
# The hold path raises no card for them now, and this hourly pass clears the two
# cards the old path left behind. The record number is a placeholder, because the
# repo's owner-details guard forbids committing his own number to a public
# repository and this test needs the shape, not the number.
test_the_recorded_stop_order_holds_leave_no_card() {
  local d out behaviour test_ci reason
  d=$(setup recorded-stop-order)
  reason="captain stop order Main42 holds this lane; branch preserved unmerged"
  behaviour=jg-captain-hold-juggernaut-behaviour-evals-1
  test_ci=jg-captain-hold-juggernaut-test-ci-rules-1
  held_lane "$d" "$behaviour" captain "$reason"
  held_lane "$d" "$test_ci" captain "$reason"
  board "$d" \
    "jg-0badc0de-$behaviour-20261030T120000Z" \
    "jg-0badc0de-$test_ci-20261030T120000Z"
  out=$(run "$d" check --force)
  assert_equals "jg-0badc0de-$behaviour-20261030T120000Z	own-instruction	$behaviour
jg-0badc0de-$test_ci-20261030T120000Z	own-instruction	$test_ci" \
    "$(cat "$d/home/state/decisions-reconcile.log")" \
    "the recorded stop-order cards were not cleared with their reason and key"
  assert_contains "$out" "reconcile: open 2 -> 0, cleared 2, kept 0" "the recorded cases did not both clear"
  assert_grep "dismiss jg-0badc0de-$behaviour-20261030T120000Z" "$d/signoff.log" \
    "the recorded card was logged but never dismissed from the board"
  [ "$(jq -r '.items | length' "$d/so/.sign-off/decisions.json")" = 0 ] \
    || fail "a recorded stop-order card survived the pass"
  pass "the two recorded stop-order holds leave no card, and the pass clears them"
}

test_a_parked_hold_card_is_cleared_by_the_reconcile() {
  local d
  d=$(setup parked-hold)
  held_lane "$d" jg-parked-lane parked "waiting on a lane we parked"
  board "$d" jg-0badc0de-jg-parked-lane-20261030T120000Z
  run "$d" check --force > /dev/null
  assert_equals "jg-0badc0de-jg-parked-lane-20261030T120000Z	own-instruction	jg-parked-lane" \
    "$(cat "$d/home/state/decisions-reconcile.log")" \
    "a card built from a parked hold was not cleared"
  pass "a card built from a parked hold is cleared, whatever its reason says"
}

# The counter-case: a question that really is the captain's alone keeps its card.
test_a_real_captain_ask_keeps_its_card() {
  local d out key=jg-0badc0de-jg-captain-hold-ship-friday-20261030T120000Z
  d=$(setup real-ask)
  held_lane "$d" jg-captain-hold-ship-friday captain "Ship the new sign-in screen this week"
  board "$d" "$key"
  out=$(run "$d" check --force)
  assert_contains "$out" "kept $key: no record settles it" "a real captain ask was not kept"
  [ ! -s "$d/signoff.log" ] || fail "a real captain ask was dismissed from the board"
  [ ! -s "$d/home/state/decisions-reconcile.log" ] || fail "a real captain ask was logged as cleared"
  pass "the counter-case: a real captain-only ask keeps its card"
}

test_an_answered_card_is_cleared_and_logged_with_its_evidence() {
  local d out
  d=$(setup answered)
  lane "$d" jg-ask-a queued
  board "$d" jg-ask-a
  answer "$d" jg-ask-a
  out=$(run "$d" check --force)
  assert_equals jg-ask-a "$(cleared "$d")" "the answered card was not logged"
  assert_equals "jg-ask-a	answered	$d/so/.sign-off/decisions.answers.jsonl" \
    "$(cat "$d/home/state/decisions-reconcile.log")" "the log line is not key, reason, evidence"
  assert_contains "$out" "cleared jg-ask-a reason=answered" "the pass did not report the clear"
  assert_contains "$out" "reconcile: open 1 -> 0, cleared 1, kept 0" "the before/after counts are wrong"
  assert_grep "dismiss jg-ask-a $d/so/.sign-off/decisions.json --reason done-elsewhere" \
    "$d/signoff.log" "the card was not dismissed with the archived reason"
  pass "an answered card is cleared, dismissed and logged with its evidence"
}

test_a_resolved_status_key_is_cleared() {
  local d
  d=$(setup resolved)
  lane "$d" jg-lane-a in_flight
  board "$d" card-of-lane-a jg-lane-a
  printf 'working [at=1]: going\nresolved [at=2] [key=card-of-lane-a]: answered: yes\n' \
    > "$d/home/state/jg-lane-a.status"
  run "$d" check --force > /dev/null
  assert_equals "card-of-lane-a	resolved	$d/home/state/jg-lane-a.status" \
    "$(cat "$d/home/state/decisions-reconcile.log")" "the resolved evidence path is wrong"
  pass "a status log's resolved key clears its card and names that log"
}

test_a_merged_pr_is_cleared_from_the_task_record() {
  local d
  d=$(setup merged)
  lane "$d" jg-lane-m 'done'
  board "$d" merge-acme-widget-pull-7:firstmate-merge
  merge_card "$d" jg-lane-m https://github.com/acme/widget/pull/7
  run "$d" check --force > /dev/null
  assert_equals "merge-acme-widget-pull-7	merged	$d/home/state/jg-lane-m.pr-poll-merge-notified" \
    "$(cat "$d/home/state/decisions-reconcile.log")" "the merge card was not cleared from the merged PR record"
  pass "a merge card is cleared when its task's recorded PR carries a merge record"
}

test_a_closed_task_clears_its_card() {
  local d
  d=$(setup closed)
  lane "$d" jg-lane-d 'done'
  board "$d" jg-0badc0de-jg-lane-d-20261030T120000Z
  run "$d" check --force > /dev/null
  assert_equals "jg-0badc0de-jg-lane-d-20261030T120000Z	closed	$d/home/data" \
    "$(cat "$d/home/state/decisions-reconcile.log")" "a closed lane's card was not cleared from the backlog"
  pass "a hold card whose lane is closed in the backlog is cleared"
}

test_a_keep_is_printed_once_and_a_live_lane_is_never_cleared() {
  local d out
  d=$(setup keeps)
  lane "$d" jg-lane-live in_flight
  board "$d" card-of-live:jg-lane-live ask-unknown
  printf 'blocked [at=1]: the checks are red\n' > "$d/home/state/jg-lane-live.status"
  out=$(run "$d" check --force)
  assert_contains "$out" "kept card-of-live: no record settles it" "a live lane's card was not reported as kept"
  assert_contains "$out" "kept ask-unknown: no record settles it" "an evidence-free card was not reported as kept"
  assert_contains "$out" "reconcile: open 2 -> 2, cleared 0, kept 2" "the kept counts are wrong"
  [ ! -s "$d/signoff.log" ] || fail "a card with no settling record was dismissed"
  out=$(run "$d" check --force)
  assert_not_contains "$out" "kept card-of-live" "an unchanged kept line was printed again"
  pass "a live lane and an evidence-free card are kept, reported once, and never cleared"
}

test_an_unreadable_record_refuses_the_card() {
  local d out
  d=$(setup unreadable)
  lane "$d" jg-lane-u 'done'
  board "$d" merge-acme-widget-pull-9:firstmate-merge
  merge_card "$d" jg-lane-u https://github.com/acme/widget/pull/9
  chmod 644 "$d/home/state/jg-lane-u.pr-poll-merge-notified"
  out=$(run "$d" check --force)
  assert_contains "$out" "kept merge-acme-widget-pull-9: its merge record cannot be read" \
    "an unreadable merge record did not refuse the card"
  [ ! -s "$d/signoff.log" ] || fail "a card was cleared because its record could not be read"
  [ ! -s "$d/home/state/decisions-reconcile.log" ] || fail "an unreadable record still wrote a clear line"
  pass "a card whose record cannot be read is kept and reported, never cleared"
}

test_replay_over_the_recorded_cases_clears_every_stale_card_and_no_open_one() {
  local d out open_before open_after
  d=$(setup replay)
  lane "$d" jg-lane-answered queued
  lane "$d" jg-lane-resolved in_flight
  lane "$d" jg-lane-merged 'done'
  lane "$d" jg-lane-closed 'done'
  lane "$d" jg-lane-live in_flight
  lane "$d" jg-lane-blocked in_flight
  board "$d" \
    ask-answered-by-captain:jg-lane-answered \
    card-of-resolved-lane:jg-lane-resolved \
    merge-acme-widget-pull-11:firstmate-merge \
    jg-7c1a2b3c-jg-lane-closed-20261030T090000Z \
    card-of-live-lane:jg-lane-live \
    card-of-blocked-lane:jg-lane-blocked \
    ask-nothing-on-file
  answer "$d" ask-answered-by-captain
  printf 'working [at=1]: going\nresolved [at=2] [key=card-of-resolved-lane]: answered: yes\n' \
    > "$d/home/state/jg-lane-resolved.status"
  printf 'blocked [at=1]: waiting on a red check\n' > "$d/home/state/jg-lane-blocked.status"
  merge_card "$d" jg-lane-merged https://github.com/acme/widget/pull/11
  open_before=$(run "$d" check --dry-run | sed -n 's/^reconcile: open \([0-9]*\) ->.*/\1/p')
  out=$(run "$d" check --force)
  open_after=$(printf '%s\n' "$out" | sed -n 's/^reconcile: open [0-9]* -> \([0-9]*\),.*/\1/p')
  assert_equals 7 "$open_before" "the replay did not start from 7 open cards"
  assert_equals 3 "$open_after" "the replay did not leave 3 open cards"
  assert_equals "ask-answered-by-captain
card-of-resolved-lane
jg-7c1a2b3c-jg-lane-closed-20261030T090000Z
merge-acme-widget-pull-11" "$(cleared "$d" | sort)" "the replay cleared the wrong cards"
  assert_not_contains "$(cleared "$d" | sort)" "card-of-live-lane" "a live lane's card was cleared"
  assert_not_contains "$(cleared "$d" | sort)" "card-of-blocked-lane" "a blocked but open lane's card was cleared"
  assert_contains "$out" "reconcile: open 7 -> 3, cleared 4, kept 3" "the replay counts are wrong"
  pass "the replay clears all 4 stale cards, keeps all 3 open ones, and reports 7 -> 3"
}

test_a_dry_run_changes_nothing_and_the_hourly_interval_holds() {
  local d out
  d=$(setup interval)
  lane "$d" jg-ask-i queued
  board "$d" jg-ask-i
  answer "$d" jg-ask-i
  out=$(run "$d" check --dry-run)
  assert_contains "$out" "clear jg-ask-i reason=answered" "the dry run did not name the card it would clear"
  [ ! -s "$d/signoff.log" ] || fail "a dry run dismissed a card"
  [ ! -e "$d/home/state/decisions-reconcile.log" ] || fail "a dry run wrote the clear log"
  out=$(run "$d" check)
  assert_contains "$out" "cleared jg-ask-i" "the real pass did not clear the card"
  out=$(run "$d" check)
  [ -z "$out" ] || fail "a pass inside the hourly interval ran again: $out"
  pass "a dry run changes nothing and the next pass waits for the hour"
}

test_arm_registers_the_check_the_watcher_timer_sweeps() {
  local d
  d=$(setup arm)
  board "$d"
  assert_contains "$(run "$d" arm)" "armed: decisions-reconcile" "arm did not report the arming"
  assert_grep "exec $RECONCILE check" "$d/home/state/decisions-reconcile.check.sh" \
    "the shim does not run the hourly pass"
  [ -s "$d/home/state/decisions-reconcile.check-trust" ] || fail "the check was not bound to its bytes"
  run "$d" disarm > /dev/null
  [ ! -e "$d/home/state/decisions-reconcile.check.sh" ] || fail "disarm left the shim behind"
  pass "arm writes and registers the hourly check on the watcher's own timer path"
}

test_an_absent_board_is_reported_and_changes_nothing() {
  local d out
  d=$(setup absent)
  printf '#!/usr/bin/env bash\nexit 3\n' > "$d/fakebin/sign-off-axi"
  chmod +x "$d/fakebin/sign-off-axi"
  board "$d" ask-x
  out=$(run "$d" check --force)
  assert_contains "$out" "board cards cannot be read" "an unreadable board was not reported"
  [ ! -s "$d/signoff.log" ] || fail "a card was dismissed from an unreadable board"
  pass "an unreadable board is reported and nothing is touched"
}

test_an_answered_card_is_cleared_and_logged_with_its_evidence
test_the_recorded_stop_order_holds_leave_no_card
test_a_parked_hold_card_is_cleared_by_the_reconcile
test_a_real_captain_ask_keeps_its_card
test_a_resolved_status_key_is_cleared
test_a_merged_pr_is_cleared_from_the_task_record
test_a_closed_task_clears_its_card
test_a_keep_is_printed_once_and_a_live_lane_is_never_cleared
test_an_unreadable_record_refuses_the_card
test_replay_over_the_recorded_cases_clears_every_stale_card_and_no_open_one
test_a_dry_run_changes_nothing_and_the_hourly_interval_holds
test_arm_registers_the_check_the_watcher_timer_sweeps
test_an_absent_board_is_reported_and_changes_nothing
