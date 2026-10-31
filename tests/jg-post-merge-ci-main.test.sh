#!/usr/bin/env bash
# The heavy behaviour suite is nightly and post-merge, and its red result must
# reach a fix item without ever blocking a pull request.
# bin/jg-post-merge-ci.sh --main is that alarm: it reads the latest completed run
# of the heavy workflow on main, files exactly one item per red run id, and stays
# quiet on green or unfinished runs.
# This drives the real script with a stubbed forge read and a stubbed backlog, and
# runs it twice on the same red run to prove the item is filed once.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALARM="$ROOT/bin/jg-post-merge-ci.sh"
TMP_ROOT=$(jg_test_tmproot jg-post-merge-ci)

# world <name> <status> <conclusion>: a repo holding the alarm and stub siblings.
world() {  # <name> <status> <conclusion>
  local name=$1 status=$2 conclusion=$3 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/data" "$dir/home/state" "$dir/repo/bin" "$dir/fakebin"
  cp "$ALARM" "$dir/repo/bin/jg-post-merge-ci.sh"
  cat > "$dir/repo/bin/jg-tasks-axi.sh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$dir/backlog-adds"
EOF
  cat > "$dir/repo/bin/jg-wake-lib.sh" <<EOF
jg_wake_append() { printf '%s\\n' "\$*" >> "$dir/wakes"; }
EOF
  chmod +x "$dir/repo/bin/jg-tasks-axi.sh"
  cat > "$dir/fakebin/gh" <<EOF
#!/usr/bin/env bash
printf '[{"databaseId":4242,"status":"$status","conclusion":"$conclusion","headSha":"abcdef0123456789"}]\\n'
EOF
  chmod +x "$dir/fakebin/gh"
  printf '%s\n' "$dir"
}

# alarm <dir>: run the alarm's main-suite mode against that world.
alarm() {  # <dir>
  local dir=$1
  ( cd "$dir/repo" && \
    PATH="$dir/fakebin:$PATH" \
    JG_HOME="$dir/home" JG_STATE_OVERRIDE="$dir/home/state" JG_DATA_OVERRIDE="$dir/home/data" \
    JG_ROOT_OVERRIDE="$dir/repo" \
    bash "$dir/repo/bin/jg-post-merge-ci.sh" --main 'Behavior suite' 2>&1 )
}

test_a_red_run_files_one_item_naming_the_run() {
  local dir out
  dir=$(world red completed failure) || fail 'the fixture world must build'
  out=$(alarm "$dir") || fail "the alarm must exit 0 even on a red run: $out"
  assert_contains "$out" 'filed' 'the alarm must say it filed the item'
  [ -f "$dir/backlog-adds" ] || fail 'a red run must add a backlog item'
  assert_contains "$(cat "$dir/backlog-adds")" 'ci-red-main-4242' 'the item id must name the red run'
  assert_contains "$(cat "$dir/backlog-adds")" '[blocker] Behavior suite went red' \
    'the item title must name the workflow and say it went red'
  assert_contains "$(cat "$dir/backlog-adds")" 'actions/runs/4242' \
    'the item body must carry the failing run url'
  [ -f "$dir/wakes" ] || fail 'a red run must queue a wake'
  assert_contains "$(cat "$dir/wakes")" 'check: Behavior suite went red on main' \
    'the wake must say which suite went red'
  pass 'a red run files one item naming the run'
}

test_the_same_red_run_files_nothing_twice() {
  local dir out
  dir=$(world repeat completed failure) || fail 'the fixture world must build'
  alarm "$dir" >/dev/null || fail 'the first alarm run must succeed'
  local adds_first
  adds_first=$(wc -l < "$dir/backlog-adds")
  out=$(alarm "$dir") || fail 'the second alarm run must succeed'
  assert_contains "$out" 'already filed' 'the second run must say the item is already filed'
  [ "$(wc -l < "$dir/backlog-adds")" -eq "$adds_first" ] || fail 'the second run must not add a second item'
  pass 'the same red run files nothing twice'
}

test_a_green_run_files_nothing() {
  local dir out
  dir=$(world green completed success) || fail 'the fixture world must build'
  out=$(alarm "$dir") || fail 'the alarm must exit 0 on a green run'
  assert_contains "$out" 'ended success' 'the alarm must report the green verdict'
  [ ! -f "$dir/backlog-adds" ] || fail 'a green run must not add a backlog item'
  pass 'a green run files nothing'
}

test_an_unfinished_run_waits_for_a_verdict() {
  local dir out
  dir=$(world unfinished in_progress '') || fail 'the fixture world must build'
  out=$(alarm "$dir") || fail 'the alarm must exit 0 while the run is in flight'
  assert_contains "$out" 'not finished' 'the alarm must say the run has no verdict yet'
  [ ! -f "$dir/backlog-adds" ] || fail 'an unfinished run must not add a backlog item'
  pass 'an unfinished run waits for a verdict'
}

test_a_red_run_files_one_item_naming_the_run
test_the_same_red_run_files_nothing_twice
test_a_green_run_files_nothing
test_an_unfinished_run_waits_for_a_verdict
printf 'jg-post-merge-ci-main: ok\n'
