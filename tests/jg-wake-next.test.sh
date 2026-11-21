#!/usr/bin/env bash
# tests/jg-wake-next.test.sh - behavior tests for bin/jg-wake-next.sh, the
# one-call fetch of the next wake together with its acknowledgement token.
# Every case drives the REAL jg-wake-next.sh and the REAL jg-wake-drain.sh over a
# real durable queue, and proves the single call is a true replacement for
# drain-then-parse: it returns the wake the drain would return, and the token it
# prints retires that same row when run.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

NEXT="$ROOT/bin/jg-wake-next.sh"
DRAIN="$ROOT/bin/jg-wake-drain.sh"

TMP_ROOT=$(jg_test_tmproot jg-wake-next-tests)

# The presented row's identity with the arrival timestamp dropped, so two
# The presented row's wake identity, with the arrival timestamp and the state-local
# sequence dropped, so two separate queue fixtures carrying the same appended wake
# compare equal while a wrong kind, key, or payload does not. The sequence is
# state-local (`bin/jg-wake-lib.sh` stamps one per queue), so it is not part of the
# identity two fixtures can share.
row_identity() {  # <file>
  awk -F '\t' '$3 == "signal" && $4 == "task1" { print $3 "\t" $4 "\t" $5 }' "$1"
}

# The --ack-through sequence a drain-style acknowledgement names, from either
# the drain's own WAKE_ACK_REQUIRED line or the new command's WAKE_NEXT_ACK line.
ack_sequence() {  # <file>
  sed -n 's/.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$1" | tail -1
}

# The runnable acknowledgement command the new call printed.
next_ack_command() {  # <file>
  sed -n 's/^WAKE_NEXT_ACK: \(bin\/jg-wake-drain\.sh .*\)$/\1/p' "$1" | tail -1
}

# Run one acknowledgement command exactly as printed, from the repo root so its
# relative bin/ path resolves.
run_ack() {  # <state> <command>
  local state=$1 command=$2
  ( cd "$ROOT" && JG_STATE_OVERRIDE="$state" bash -c "$command" )
}

queued_rows() {  # <state>
  awk 'END { print NR + 0 }' "$1/.wake-queue" 2>/dev/null || printf '0\n'
}

test_single_call_returns_the_wake_the_drain_returns_and_retires_the_same_row() {
  local old_dir old_state old_out old_err old_seq old_identity
  local new_dir new_state new_out new_err new_ack new_seq new_identity

  # The old way: drain, read the acknowledgement off stderr, run it by hand.
  old_dir=$(make_case next-old-way)
  old_state="$old_dir/state"
  old_out="$old_dir/drain.out"
  old_err="$old_dir/drain.err"
  append_wake "$old_state" signal task1 'watcher fired'
  JG_STATE_OVERRIDE="$old_state" "$DRAIN" > "$old_out" 2> "$old_err" \
    || fail "the reference drain failed"
  old_seq=$(ack_sequence "$old_err")
  [ -n "$old_seq" ] || fail "the reference drain printed no acknowledgement to compare against"
  old_identity=$(row_identity "$old_out")
  [ -n "$old_identity" ] || fail "the reference drain presented no wake row"
  run_ack "$old_state" "$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run \(bin\/jg-wake-drain\.sh .*\)$/\1/p' "$old_err" | tail -1)" \
    || fail "the reference drain's own acknowledgement failed"
  [ "$(queued_rows "$old_state")" = 0 ] \
    || fail "the reference drain's acknowledgement did not retire the row"

  # The new way: one call, no parse, no hand-built command.
  new_dir=$(make_case next-single-call)
  new_state="$new_dir/state"
  new_out="$new_dir/next.out"
  new_err="$new_dir/next.err"
  append_wake "$new_state" signal task1 'watcher fired'
  JG_STATE_OVERRIDE="$new_state" "$NEXT" > "$new_out" 2> "$new_err" \
    || fail "the single call failed"

  new_identity=$(row_identity "$new_out")
  [ "$new_identity" = "$old_identity" ] \
    || fail "the single call returned a different wake than the drain would (expected '$old_identity', got '$new_identity')"
  new_ack=$(next_ack_command "$new_out")
  [ -n "$new_ack" ] || fail "the single call printed no acknowledgement command"
  new_seq=$(ack_sequence "$new_out")
  # The queue sequence is state-local (`bin/jg-wake-lib.sh` stamps one per queue), so two
  # separate fixtures cannot share a number. What must hold is that the single call names
  # a sequence at all, and that the token built from it retires the row it presented below.
  [ -n "$new_seq" ] || fail "the single call named no sequence to acknowledge"
  ! grep -F 'WAKE_ACK_REQUIRED' "$new_out" "$new_err" >/dev/null \
    || fail "the single call still leaked the old acknowledgement line for the caller to parse"

  run_ack "$new_state" "$new_ack" || fail "the acknowledgement the single call printed failed"
  [ "$(queued_rows "$new_state")" = 0 ] \
    || fail "the acknowledgement the single call printed did not retire the row"

  pass "one call returns the wake the drain returns and its token retires that same row"
}

test_one_call_reports_nothing_to_acknowledge_when_the_queue_is_empty() {
  local dir state out err

  dir=$(make_case next-idle)
  state="$dir/state"
  out="$dir/next.out"
  err="$dir/next.err"
  : > "$state/.wake-queue"

  JG_STATE_OVERRIDE="$state" "$NEXT" > "$out" 2> "$err" \
    || fail "the single call failed on an idle queue"
  grep -Fx 'WAKE_NEXT_ACK: none' "$out" >/dev/null \
    || fail "an idle queue did not report nothing to acknowledge: $(cat "$out")"
  [ "$(queued_rows "$state")" = 0 ] || fail "an idle call invented a queued row"

  pass "an idle queue reports nothing to acknowledge instead of a bogus token"
}

test_one_call_relays_the_presentation_and_still_surfaces_open_decisions() {
  local dir state out err

  dir=$(make_case next-sections)
  state="$dir/state"
  out="$dir/next.out"
  err="$dir/next.err"
  append_wake "$state" signal task1 'watcher fired'
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task9.status"

  JG_STATE_OVERRIDE="$state" "$NEXT" > "$out" 2> "$err" \
    || fail "the single call failed over an open decision"
  grep -F 'OPEN DECISIONS' "$out" >/dev/null \
    || fail "the single call swallowed the drain's OPEN DECISIONS section"
  grep -F '[key=api-shape]' "$out" | grep -F 'pick REST or RPC' >/dev/null \
    || fail "the single call did not surface the open decision"
  [ "$(row_identity "$out")" != '' ] \
    || fail "the single call swallowed the presented wake row while relaying sections"

  pass "one call keeps every section the drain presents beside the wake and its token"
}

test_six_signals_cannot_acknowledge_a_buried_report_unseen() {
  local dir state out err repeat seq gen id i line foreign ids_before
  local -a ids ack
  dir=$(make_case six-signals); state="$dir/state"; out="$dir/first.out"; err="$dir/first.err"
  for i in 1 2 3 4 5 6; do
    printf 'working: Umer starts team %s\n' "$i" > "$state/team$i.status"
    case "$i" in
      1) line='report: Umer report is ready' ;;
      2) line='done: Umer finished' ;;
      3) line='failed: Umer build refused' ;;
      4) line='working: PR https://example.test/Umer/demo/pull/7' ;;
      5) line='landed: Umer change reached the trunk' ;;
      6) line=$'blocked: Umer needs access\nneeds-decision: choose the next step' ;;
    esac
    printf '%s\nworking: Umer continues team %s\n' "$line" "$i" >> "$state/team$i.status"
    append_wake "$state" signal "team$i.status" "signal: $state/team$i.status"
  done
  JG_STATE_OVERRIDE="$state" "$ROOT/bin/jg-wake.sh" next > "$out" 2> "$err" || fail 'six-signal caller failed'
  seq=$(ack_sequence "$err"); gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || fail 'six signals have no acknowledgement'
  ack=(--ack-through "$seq" --recovery-generation "$gen")
  for i in 1 2 3 4 5 6; do
    while IFS= read -r line; do grep -F "team$i.status: $line" "$out" >/dev/null || fail "omitted $line"; done < "$state/team$i.status"
  done
  grep -F 'OUTCOME: team1.status: report:' "$out" >/dev/null || fail 'buried report has no outcome marker'
  grep -F 'ACTION: team6.status: blocked:' "$out" >/dev/null || fail 'blocker has no action marker'
  grep -F 'ACTION: team6.status: needs-decision:' "$out" >/dev/null || fail 'decision has no action marker'
  if JG_STATE_OVERRIDE="$state" "$DRAIN" "${ack[@]}" > "$dir/refused.out" 2>&1; then fail 'unseen outcomes were acknowledged'; fi
  [ "$(queued_rows "$state")" = 6 ] || fail 'refusal consumed a signal'
  mapfile -t ids < <(sed -n 's/^OUTCOME_REQUIRED: //p' "$out" | sort -u)
  [ "${#ids[@]}" = 5 ] || fail 'not every outcome has an id'
  ids_before=$(printf '%s\n' "${ids[@]}")
  repeat="$dir/repeat.out"
  JG_STATE_OVERRIDE="$state" "$NEXT" > "$repeat" 2> "$dir/repeat.err" || fail 'replay failed'
  [ "$(sed -n 's/^OUTCOME_REQUIRED: //p' "$repeat" | sort -u)" = "$ids_before" ] || fail 'outcome ids changed on replay'
  grep -F 'report: Umer report is ready' "$repeat" >/dev/null || fail 'replay lost the report'
  JG_STATE_OVERRIDE="$state" bash -c '. "$1"; JG_DAEMON_DIR=$2; handle_durable_wakes "$3" "$4"' _ \
    "$ROOT/bin/jg-supervise-daemon.sh" "$ROOT/bin" "signal: $state/team1.status" "$state" || fail 'daemon handoff failed'
  for id in "${ids[@]}"; do grep -F "$id" "$state/.subsuper-escalations" >/dev/null || fail 'daemon lost an outcome'; done
  grep -F 'report: Umer report is ready' "$state/.subsuper-escalations" >/dev/null || fail 'daemon lost report text'
  [ "$(queued_rows "$state")" = 6 ] || fail 'daemon consumed outcomes before explicit handling'
  foreign=$(make_case foreign-outcome)
  if JG_STATE_OVERRIDE="$foreign/state" "$DRAIN" --outcome "${ids[0]}" --classified reviewed > "$dir/foreign.out" 2>&1; then fail 'foreign home accepted an id'; fi
  if JG_STATE_OVERRIDE="$state" JG_SUPERVISION_ACTOR=branch "$DRAIN" --outcome "${ids[0]}" --classified reviewed > "$dir/actor.out" 2>&1; then fail 'foreign actor accepted an id'; fi
  if JG_STATE_OVERRIDE="$state" "$DRAIN" --outcome "${ids[0]}" --classified ' ' > "$dir/blank.out" 2>&1; then fail 'blank disposition passed'; fi
  if JG_STATE_OVERRIDE="$state" "$DRAIN" --outcome "$(printf '%064d' 0)" --relayed "$out" > "$dir/unknown.out" 2>&1; then fail 'unknown id passed'; fi
  JG_STATE_OVERRIDE="$state" "$DRAIN" --outcome "${ids[0]}" --relayed "$out" || fail 'relay receipt failed'
  for i in 1 2 3; do JG_STATE_OVERRIDE="$state" "$DRAIN" --outcome "${ids[$i]}" --classified 'reviewed synthetic outcome' || fail 'classification failed'; done
  if JG_STATE_OVERRIDE="$state" "$DRAIN" "${ack[@]}" >> "$dir/refused.out" 2>&1; then fail 'one unhandled outcome was swallowed'; fi
  JG_STATE_OVERRIDE="$state" "$DRAIN" --outcome "${ids[4]}" --classified 'reviewed final synthetic outcome' || fail 'last disposition failed'
  JG_STATE_OVERRIDE="$state" "$DRAIN" --outcome "${ids[4]}" --classified 'reviewed again' || fail 'handling is not idempotent'
  printf 'report: Umer appends after presentation\n' >> "$state/team1.status"
  if JG_STATE_OVERRIDE="$state" "$DRAIN" "${ack[@]}" >> "$dir/refused.out" 2>&1; then fail 'unpresented growth was swallowed'; fi
  JG_STATE_OVERRIDE="$state" "$NEXT" > "$dir/growth.out" 2> "$dir/growth.err" || fail 'growth replay failed'
  if JG_STATE_OVERRIDE="$state" "$DRAIN" "${ack[@]}" >> "$dir/refused.out" 2>&1; then fail 'new outcome used an old disposition'; fi
  id=$(sed -n 's/^OUTCOME_REQUIRED: //p' "$dir/growth.out" | sort -u | while read -r id; do [[ "$ids_before" == *"$id"* ]] || printf '%s\n' "$id"; done)
  JG_STATE_OVERRIDE="$state" "$DRAIN" --outcome "$id" --classified 'reviewed appended report' || fail 'appended disposition failed'
  JG_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$((seq - 1))" --recovery-generation "$gen" || fail 'older cutoff failed'
  [ "$(queued_rows "$state")" = 1 ] || fail 'older cutoff consumed newer row'
  JG_STATE_OVERRIDE="$state" "$NEXT" > "$dir/partial.out" 2> "$dir/partial.err" || fail 'partial batch replay failed'
  JG_STATE_OVERRIDE="$state" "$DRAIN" "${ack[@]}" || fail 'handled outcomes could not be acknowledged'
  JG_STATE_OVERRIDE="$state" "$DRAIN" "${ack[@]}" || fail 'acknowledgement is not idempotent'
  [ "$(queued_rows "$state")" = 0 ] || fail 'handled batch remains queued'
  JG_STATE_OVERRIDE="$state" "$NEXT" > "$dir/idle.out" 2> "$dir/idle.err" || fail 'post-ack drain failed'
  if grep -q '^wake annotation:' "$dir/idle.out"; then fail 'acknowledged lines replayed'; fi
  printf 'report: Umer has a new report\n' >> "$state/team1.status"
  append_wake "$state" signal team1.status "signal: $state/team1.status"
  JG_STATE_OVERRIDE="$state" "$NEXT" > "$dir/new.out" 2> "$dir/new.err" || fail 'new report failed to present'
  grep -F 'OUTCOME: team1.status: report: Umer has a new report' "$dir/new.out" >/dev/null || fail 'new report missing'
  if grep -q 'Umer report is ready' "$dir/new.out"; then fail 'old report repeated after ack'; fi
  seq=$(ack_sequence "$dir/new.out"); gen=$(sed -n 's/^WAKE_NEXT_ACK:.*--recovery-generation \([^ ]*\)$/\1/p' "$dir/new.out")
  if JG_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >> "$dir/refused.out" 2>&1; then fail 'fresh report reused an old receipt'; fi
  mv "$state/team1.status" "$dir/rotated.status"; printf 'report: Umer rotated the status log\n' > "$state/team1.status"
  JG_STATE_OVERRIDE="$state" "$NEXT" > "$dir/rotation.out" 2> "$dir/rotation.err" || fail 'rotation replay failed'
  grep -F 'report: Umer rotated the status log' "$dir/rotation.out" >/dev/null || fail 'rotation lost new report'
  if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
    cat "$out" "$err" "$repeat" "$state/.subsuper-escalations" "$dir/refused.out" "$dir/new.out" > "$DONE_DONE_EVIDENCE_ROOT/six-signals.log"
    printf '{"target":{"version":"%s"},"start":"six real signal rows over synthetic Umer status logs","steps":["drain through jg-wake next","refuse unseen and partially handled acknowledgements","replay through jg-wake-next","route the full batch through the real daemon handler","refuse foreign and invalid dispositions","record relay and classifications","refuse unseen growth","acknowledge twice","present a fresh report"],"result":"all six files and the buried report were presented; every outcome required a disposition; the handled batch was consumed once"}\n' "$(git -C "$ROOT" rev-parse HEAD)" > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
  fi
  pass 'six real signals retain their buried report until every outcome is explicitly handled'
}

test_six_signals_cannot_acknowledge_a_buried_report_unseen
test_single_call_returns_the_wake_the_drain_returns_and_retires_the_same_row
test_one_call_reports_nothing_to_acknowledge_when_the_queue_is_empty
test_one_call_relays_the_presentation_and_still_surfaces_open_decisions
