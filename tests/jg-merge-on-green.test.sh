#!/usr/bin/env bash
# The deterministic merge watcher must never merge without authority it can
# name, must raise exactly one alert per task and head when the merge gate
# refuses, and must record the done-to-merged minutes with an alert when they
# pass five. This test drives the script through sibling stubs, so it proves the
# decisions without touching a forge or a real merge path.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/jg-merge-on-green.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT INT TERM

# build_home: a fixture home whose bin/ holds the script under test plus stubs
# for everything it calls. The stubs read the fixture's own knobs:
#   $WORK/wait      the jg-pr-state.sh --waiting-for answer
#   $WORK/head      the head sha the gh stub reports
#   $WORK/merge-rc  the jg-pr-merge.sh exit status
#   $WORK/merge-out the jg-pr-merge.sh output
#   $WORK/yolo      the jg-project-mode.sh answer
build_home() {
  HOME_DIR="$WORK/home"
  mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state" "$HOME_DIR/data"
  cp "$ROOT/bin/jg-merge-on-green.sh" "$HOME_DIR/bin/jg-merge-on-green.sh"
  cat > "$HOME_DIR/bin/jg-pr-state.sh" <<'SH'
#!/usr/bin/env bash
cat "$WORK_DIR/wait" 2>/dev/null || true
exit 0
SH
  cat > "$HOME_DIR/bin/jg-pr-merge.sh" <<'SH'
#!/usr/bin/env bash
printf 'merge %s %s\n' "$1" "$2" >> "$WORK_DIR/merges"
cat "$WORK_DIR/merge-out" 2>/dev/null || true
exit "$(cat "$WORK_DIR/merge-rc" 2>/dev/null || echo 0)"
SH
  cat > "$HOME_DIR/bin/jg-project-mode.sh" <<'SH'
#!/usr/bin/env bash
cat "$WORK_DIR/yolo" 2>/dev/null || printf 'direct-PR off\n'
SH
  cat > "$HOME_DIR/bin/jg-wake-lib.sh" <<'SH'
#!/usr/bin/env bash
jg_wake_append() { printf 'wake %s %s %s\n' "$1" "$2" "$3" >> "$WORK_DIR/wakes"; }
SH
  cat > "$WORK/fakebin-gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *mergedAt*) cat "$WORK_DIR/merged-at" 2>/dev/null || true ;;
  *headRefOid*) cat "$WORK_DIR/head" 2>/dev/null || true ;;
esac
exit 0
SH
  chmod +x "$HOME_DIR/bin/"*.sh
  FAKEBIN=$(jg_fakebin "$WORK")
  cp "$WORK/fakebin-gh" "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
  # The stub bodies read $WORK_DIR; export it rather than hard-coding a path so
  # each case can point at its own fixture directory.
  export WORK_DIR="$WORK"
}

# write_meta <task-id> <project> <url>: a ship task with a recorded pull request.
write_meta() {  # <task-id> <project> <url>
  {
    printf 'kind=ship\n'
    printf 'project=%s\n' "$2"
    printf 'pr=%s\n' "$3"
  } > "$HOME_DIR/state/$1.meta"
}

run_sweep() {
  (
    cd "$WORK" || exit 1
    PATH="$FAKEBIN:$PATH" JG_ROOT_OVERRIDE="$HOME_DIR" JG_HOME="$HOME_DIR" \
      JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" \
      bash "$HOME_DIR/bin/jg-merge-on-green.sh" sweep
  )
}

run_cmd() {
  (
    cd "$WORK" || exit 1
    PATH="$FAKEBIN:$PATH" JG_ROOT_OVERRIDE="$HOME_DIR" JG_HOME="$HOME_DIR" \
      JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" \
      bash "$HOME_DIR/bin/jg-merge-on-green.sh" "$@"
  )
}

reset_fixture() {
  rm -rf -- "$HOME_DIR" "$WORK/fakebin"
  : > "$WORK/merges"
  : > "$WORK/wakes"
  build_home
}

URL='https://github.com/owner/repo/pull/7'
GREEN='juggernaut/waiting-for: the merge call: the required checks are green, and the lead merges within one cycle by rule'
PENDING='juggernaut/waiting-for: a required check is not passing: CI required (pending)'

build_home

test_a_green_pull_request_without_authority_is_not_merged() {
  reset_fixture
  printf '%s\n' "$GREEN" > "$WORK/wait"
  printf 'head123\n' > "$WORK/head"
  printf 'direct-PR off\n' > "$WORK/yolo"
  write_meta ship-a proj "$URL"
  run_sweep >/dev/null
  [ ! -s "$WORK/merges" ] || fail 'a pull request without merge authority must not be merged'
  [ ! -s "$WORK/wakes" ] || fail 'a pull request without merge authority is a wait, not an alert'
  pass 'a green pull request without authority is not merged'
}

test_yolo_authority_merges_the_green_pull_request() {
  reset_fixture
  printf '%s\n' "$GREEN" > "$WORK/wait"
  printf 'head123\n' > "$WORK/head"
  printf 'direct-PR on\n' > "$WORK/yolo"
  printf '0\n' > "$WORK/merge-rc"
  now=$(date +%s)
  printf 'done [at=%s]: PR %s\n' "$((now - 120))" "$URL" > "$HOME_DIR/state/ship-b.status"
  write_meta ship-b proj "$URL"
  run_sweep >/dev/null
  assert_contains "$(cat "$WORK/merges")" "merge ship-b $URL" \
    'a +yolo project must merge its green pull request'
  assert_contains "$(cat "$HOME_DIR/data/merge-latency.tsv")" 'ship-b' \
    'a landed merge must be recorded in the latency table'
  pass 'yolo authority merges the green pull request'
}

test_a_recorded_approval_merges_without_yolo() {
  reset_fixture
  printf '%s\n' "$GREEN" > "$WORK/wait"
  printf 'head123\n' > "$WORK/head"
  printf 'direct-PR off\n' > "$WORK/yolo"
  printf '0\n' > "$WORK/merge-rc"
  write_meta ship-c proj "$URL"
  run_cmd approve ship-c >/dev/null
  assert_contains "$(cat "$HOME_DIR/state/ship-c.merge-go")" "url=$URL" \
    'the approval must name the pull request it approves'
  run_sweep >/dev/null
  assert_contains "$(cat "$WORK/merges" 2>/dev/null)" "merge ship-c $URL" \
    'a recorded approval must let the sweep merge'
  pass 'a recorded approval merges without yolo'
}

test_a_pending_check_is_a_wait_with_no_alert() {
  reset_fixture
  printf '%s\n' "$PENDING" > "$WORK/wait"
  printf 'head123\n' > "$WORK/head"
  printf 'direct-PR on\n' > "$WORK/yolo"
  write_meta ship-d proj "$URL"
  run_sweep >/dev/null
  [ ! -s "$WORK/merges" ] || fail 'a pending required check must not merge'
  [ ! -s "$WORK/wakes" ] || fail 'a pending required check must not raise an alert'
  pass 'a pending required check is a wait with no alert'
}

test_a_refused_gate_raises_exactly_one_alert_per_head() {
  reset_fixture
  printf '%s\n' "$GREEN" > "$WORK/wait"
  printf 'head123\n' > "$WORK/head"
  printf 'direct-PR on\n' > "$WORK/yolo"
  printf '1\n' > "$WORK/merge-rc"
  printf 'error: refusing to merge: the required check CI required is pending\n' > "$WORK/merge-out"
  write_meta ship-e proj "$URL"
  run_sweep >/dev/null
  run_sweep >/dev/null
  count=$(grep -c '^wake ' "$WORK/wakes" || true)
  [ "$count" = 1 ] || fail "a refusal must raise exactly one alert per head, got $count"
  assert_contains "$(cat "$WORK/wakes")" 'CI required is pending' \
    'the alert must name the gate refusal reason'
  # A new head is a new verdict and earns its own single alert.
  printf 'head456\n' > "$WORK/head"
  run_sweep >/dev/null
  count=$(grep -c '^wake ' "$WORK/wakes" || true)
  [ "$count" = 2 ] || fail "a new head must raise one new alert, got $count"
  pass 'a refused gate raises exactly one alert per head'
}

test_a_slow_merge_records_and_alerts_over_five_minutes() {
  reset_fixture
  now=$(date +%s)
  # A done line eleven minutes before the merge, and a forge merge time now.
  { printf 'working [at=%s]: started\n' "$((now - 900))"; printf 'done [at=%s]: PR %s\n' "$((now - 660))" "$URL"; } \
    > "$HOME_DIR/state/ship-f.status"
  printf 'merged\n' > "$WORK/wait"
  run_cmd latency >/dev/null
  # Record through the merge path: the sweep is the only writer, so drive it.
  printf '%s\n' "$GREEN" > "$WORK/wait"
  printf 'head123\n' > "$WORK/head"
  printf 'direct-PR on\n' > "$WORK/yolo"
  printf '0\n' > "$WORK/merge-rc"
  date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ > "$WORK/merged-at"
  write_meta ship-f proj "$URL"
  run_sweep >/dev/null
  row=$(grep '^ship-f' "$HOME_DIR/data/merge-latency.tsv" 2>/dev/null || true)
  [ -n "$row" ] || fail 'a landed merge must be recorded'
  minutes=$(printf '%s\n' "$row" | cut -f5)
  [ "$minutes" -ge 10 ] || fail "the recorded minutes must be the real gap, got $minutes"
  assert_contains "$(cat "$WORK/wakes")" 'over the 5-minute target' \
    'a merge over five minutes must raise one alert'
  pass 'a slow merge records and alerts over five minutes'
}

test_a_green_pull_request_without_authority_is_not_merged
test_yolo_authority_merges_the_green_pull_request
test_a_recorded_approval_merges_without_yolo
test_a_pending_check_is_a_wait_with_no_alert
test_a_refused_gate_raises_exactly_one_alert_per_head
test_a_slow_merge_records_and_alerts_over_five_minutes
printf 'jg-merge-on-green: ok\n'
