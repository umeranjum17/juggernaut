#!/usr/bin/env bash
# The Lavish refusal guard, replayed from the real incident: a report reached
# the captain as a Lavish page on port 4387 after Lavish was retired and
# sign-off became the only report surface.
# The first case is that exact note. Every case drives a real command: the
# guard itself, the status-append form the generated worker instructions carry,
# and the report helper a lead actually reports through.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/jg-lavish-guard.sh"
REPORT="$ROOT/bin/jg-squad-lead-report.sh"
TMP_ROOT=$(jg_test_tmproot jg-lavish-guard)

# Tonight's real case: the note is a done report whose whole finding is a link
# to a Lavish page on the retired port.
TONIGHT='done [at=1793417000]: report at http://review.example:4387/session/876d22727c2c3776'

guard() {  # <text> -> ERR, RC: the guard's own line is ERR, so only its status is kept
  printf '%s\n' "$1" | bash "$GUARD" 2>"$TMP_ROOT/stderr"
  RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

test_tonights_report_link_is_refused() {
  guard "$TONIGHT"
  [ "$RC" -eq 1 ] || fail "a report linking a Lavish page must be refused, got exit $RC"
  assert_contains "$ERR" 'sign-off board (sign-off-axi)' \
    'the refusal tells the worker to post on sign-off instead'
  pass 'a report whose link is a Lavish page on port 4387 is refused, and the refusal names sign-off'
}

test_a_lavish_publish_command_is_refused() {
  local text
  for text in 'lavish-axi review.html' 'lavish-axi publish board' 'cd x && lavish-axi .lavish/board.htm'; do
    guard "$text"
    [ "$RC" -eq 1 ] || fail "a Lavish publish command must be refused: $text"
    assert_contains "$ERR" 'sign-off board (sign-off-axi)' "the publish refusal names sign-off: $text"
  done
  pass 'a Lavish publish command is refused and points at sign-off'
}

test_clean_report_text_passes() {
  local text
  for text in \
    'done [at=1793417000]: merged https://github.com/umeranjum17/juggernaut/pull/310' \
    'http://review.example:4388/board/umer' \
    'Lavish is retired; the sign-off board carries the report.' \
    ''; do
    guard "$text"
    [ "$RC" -eq 0 ] || fail "clean captain-facing text was refused: $text"
  done
  pass 'a sign-off link, a PR link, retirement prose, and empty text all pass'
}

test_the_status_append_form_writes_only_clean_lines() {
  local status="$TMP_ROOT/worker.status"
  rm -f "$status"
  printf '%s\n' "$TONIGHT" | bash "$GUARD" --append "$status" 2>"$TMP_ROOT/stderr" \
    && fail 'the status-append form accepted a Lavish link'
  assert_absent "$status" 'a refused status line never reached the status file'
  printf '%s\n' 'working [at=1793417000]: rebuilding the board on sign-off' \
    | bash "$GUARD" --append "$status" || fail 'the status-append form refused clean text'
  assert_grep 'rebuilding the board on sign-off' "$status" \
    'a clean status line is appended unchanged'
  pass 'the status-append form refuses tonight'"'"'s line and appends only clean lines'
}

test_the_lead_report_helper_refuses_before_append() {
  local dir="$TMP_ROOT/report"
  mkdir -p "$dir/state" "$dir/parent/state"
  printf 'umer\n' > "$dir/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" \
    > "$dir/.jg-squad-lead-parent"
  JG_HOME="$dir" bash "$REPORT" 'done' abcdef0123456789 "$TONIGHT" 2>"$dir/stderr" \
    && fail 'the report helper accepted a Lavish report link'
  assert_contains "$(cat "$dir/stderr")" 'sign-off board (sign-off-axi)' \
    'the report helper surfaces the sign-off instruction'
  assert_absent "$dir/parent/state/umer.status" 'a refused report wrote nothing to the parent channel'
  JG_HOME="$dir" bash "$REPORT" 'done' abcdef0123456789 \
    'board: http://review.example:4388/board/umer #tickets/jg-abc' \
    2>>"$dir/stderr" || fail 'the report helper refused a sign-off report link'
  assert_grep 'board: http://review.example:4388/board/umer' "$dir/parent/state/umer.status" \
    'the sign-off report link reaches the parent channel'
  pass 'the report helper refuses before append and accepts the sign-off link'
}

# A Recon says done only when its cleanup would pass: the real guard append, the real
# depth gate and the real completion gate, on a lane record of kind scout.
recon_home() {  # <name> -> prints the home; a standard Recon scaffolded by the real brief
  local home="$TMP_ROOT/$1" id=$2
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  jg_test_beads_home "$home"
  : > "$home/config/backlog-intake-loose"
  jg_fake_exit0 "$(jg_fakebin "$home")" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

recon_append() {  # <home> <id> <line> -> RC, ERR
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" bash "$GUARD" --append "$home/state/$id.status" <<< "$3" 2>"$TMP_ROOT/stderr"
  RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

test_a_recon_done_waits_for_both_gates() {
  command -v jq >/dev/null 2>&1 || { pass 'skipped: jq not found'; return; }
  local id=rc-lead home dir
  home=$(recon_home recon "$id"); dir=$home/data/$id
  jg_write_meta "$home/state/$id.meta" "window=juggernaut:jg-$id" "worktree=$home/projects/none" \
    "project=$home/projects/sample" "harness=claude" "kind=scout" "mode=scout"
  JG_HOME="$home" JG_DATA_OVERRIDE="$home/data" "$ROOT/bin/jg-brief.sh" "$id" sample --scout --depth standard >/dev/null 2>&1 \
    || fail 'could not scaffold the standard Recon'
  recon_append "$home" "$id" 'done [at=1]: report ready'
  [ "$RC" -eq 1 ] || fail "a standard Recon with no report said done, got exit $RC"
  assert_contains "$ERR" 'depth gate: report.md is missing' 'the refusal names the depth gate'
  assert_contains "$ERR" 'completion gate' 'the refusal names the completion gate'
  assert_absent "$home/state/$id.status" 'a refused Recon done wrote nothing'
  recon_append "$home" "$id" 'working [at=1]: reading sources'
  [ "$RC" -eq 0 ] || fail "a working line of a Recon was refused: $ERR"
  # A waiver by Main passes the depth gate but never the completion gate.
  mkdir -p "$home/state/recon-gate-waiver"
  printf 'waived-by: Main\nreason: owner dropped the depth\n' > "$home/state/recon-gate-waiver/$id"
  printf '# Report\n\nNo captain choice.\n' > "$dir/report.md"
  recon_append "$home" "$id" 'done [at=2]: report ready'
  [ "$RC" -eq 1 ] || fail 'a waived Recon passed without its completion gate'
  assert_not_contains "$ERR" 'depth gate' 'a waived depth gate is not named as a gap'
  assert_contains "$ERR" 'completion gate' 'the completion gate still stands behind a waiver'
  PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/jg-captain-hold.sh" complete "$id" --none >/dev/null 2>&1 \
    || fail 'could not attest the completion gate'
  recon_append "$home" "$id" 'done [at=3]: report ready'
  [ "$RC" -eq 0 ] || fail "a Recon past both gates was refused: $ERR"
  assert_grep 'done [at=3]' "$home/state/$id.status" 'the accepted done is appended'
  pass 'a Recon done is refused until the depth gate and the completion gate pass; a waiver covers only the first'
}

test_a_critic_task_done_needs_no_report() {
  command -v jq >/dev/null 2>&1 || { pass 'skipped: jq not found'; return; }
  local id=rc-critic home dir
  home=$(recon_home critic "$id"); dir=$home/data/$id
  jg_write_meta "$home/state/$id.meta" "window=juggernaut:jg-$id" "worktree=$home/projects/none" \
    "project=$home/projects/sample" "harness=claude" "kind=scout" "mode=scout"
  JG_HOME="$home" JG_DATA_OVERRIDE="$home/data" "$ROOT/bin/jg-brief.sh" "$id" sample --scout --depth deep >/dev/null 2>&1 \
    || fail 'could not scaffold the critic task'
  printf 'Critic: %s\nRound 1: new gaps 2\n- a gap\n' "$id" > "$dir/critic.md"
  PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/jg-captain-hold.sh" complete "$id" --none >/dev/null 2>&1 \
    || fail 'could not attest the completion gate'
  recon_append "$home" "$id" 'done [at=1]: critic.md written'
  [ "$RC" -eq 0 ] || fail "a critic task with its critic.md was refused: $ERR"
  pass 'a critic task says done on its critic.md, with no report'
}

test_tonights_report_link_is_refused
test_a_lavish_publish_command_is_refused
test_clean_report_text_passes
test_the_status_append_form_writes_only_clean_lines
test_the_lead_report_helper_refuses_before_append
# These two need a Beads store; a host without one skips the suite from here, so they run last.
test_a_recon_done_waits_for_both_gates
test_a_critic_task_done_needs_no_report
printf 'jg-lavish-guard: ok\n'
