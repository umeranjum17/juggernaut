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
# shellcheck source=tests/title-rule-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/title-rule-lib.sh"

ALARM="$ROOT/bin/jg-post-merge-ci.sh"
TMP_ROOT=$(jg_test_tmproot jg-post-merge-ci)

# world <name> <status> <conclusion>: a repo holding the alarm and stub siblings.
world() {  # <name> <status> <conclusion>
  local name=$1 status=$2 conclusion=$3 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/data" "$dir/home/state" "$dir/repo/bin" "$dir/fakebin"
  cp "$ALARM" "$dir/repo/bin/jg-post-merge-ci.sh"
  cat > "$dir/repo/bin/jg-backlog.sh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$dir/backlog-adds"
EOF
  cat > "$dir/repo/bin/jg-wake-lib.sh" <<EOF
jg_wake_append() { printf '%s\\n' "\$*" >> "$dir/wakes"; }
EOF
  chmod +x "$dir/repo/bin/jg-backlog.sh"
  # The real alert function and its tables raise line-red; only the wake queue is recorded.
  cp "$ROOT/bin/jg-alert.sh" "$ROOT/bin/jg-machine.sh" "$dir/repo/bin/"
  ln -sn "$ROOT/core" "$dir/repo/core"
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
  assert_contains "$(cat "$dir/backlog-adds")" 'Post-merge CI went red -l blocker' \
    'the item title must say CI went red and carry the blocker label'
  title_rule_ok "$(sed -n '1s/^add [^ ]* \(.*\) -l blocker.*/\1/p' "$dir/backlog-adds")" \
    || fail "the item title must pass the title rule: $(head -n1 "$dir/backlog-adds")"
  assert_contains "$(cat "$dir/backlog-adds")" 'Behavior suite went red on main' \
    'the workflow name moves to the item body'
  assert_contains "$(cat "$dir/backlog-adds")" 'actions/runs/4242' \
    'the item body must carry the failing run url'
  [ -f "$dir/wakes" ] || fail 'a red run must queue a wake'
  assert_contains "$(cat "$dir/wakes")" 'check alert-line-red--post-merge-ci-ci-red-main-4242 alert line-red (P1) at rung 2 for lead' \
    'the red must raise the line-red alert for the lead'
  assert_contains "$(cat "$dir/wakes")" 'Behavior suite went red on main' \
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

# ---- the verify's one rule: a red run is judged against the last green run's own timing aggregate ----

# agg <file> <script:exit>...: a timing aggregate holding those scripts (exit 0 passes, 124 is a runner timeout).
agg() {
  local file=$1 s rows=; shift
  for s in "$@"; do rows="$rows$(jq -cn --arg p "tests/${s%%:*}.test.sh" --argjson e "${s##*:}" '{path: $p, exit: $e, gate_skip: false}'),"; done
  printf '{"kind":"aggregate","scripts":[%s]}\n' "${rows%,}" > "$file"
}

# rworld <name>: the alarm's world with a real git history (green head, then the red head that touched b.test.sh), a forge stand-in that
# serves run lists and artifacts from files, a backlog stand-in that records add, show and update, and a trunk stand-in that records ci calls.
rworld() {
  local dir=$TMP_ROOT/$1
  world "$1" completed failure >/dev/null
  git -C "$dir/repo" init -q . && git -C "$dir/repo" config user.email t@example.com && git -C "$dir/repo" config user.name t
  mkdir -p "$dir/repo/tests" && printf 'a\n' > "$dir/repo/tests/a.test.sh" && printf 'b\n' > "$dir/repo/tests/b.test.sh"
  git -C "$dir/repo" add tests && git -C "$dir/repo" commit -qm green && git -C "$dir/repo" rev-parse HEAD > "$dir/green-head"
  printf 'b2\n' > "$dir/repo/tests/b.test.sh" && git -C "$dir/repo" commit -qam 'touch b' && git -C "$dir/repo" rev-parse HEAD > "$dir/red-head"
  cat > "$dir/repo/bin/jg-backlog.sh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  show) printf 'task:\n  state: in_flight\n' ;;
  *) printf '%s\n' "\$*" >> "$dir/backlog-calls" ;;
esac
EOF
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/trunk-calls"\n' "$dir" > "$dir/repo/bin/jg-trunk.sh"
  chmod +x "$dir/repo/bin/jg-backlog.sh" "$dir/repo/bin/jg-trunk.sh"
  cat > "$dir/fakebin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"run download"*)
    id=\$3; out=; while [ "\$#" -gt 0 ]; do [ "\$1" = -D ] && out=\$2; shift; done
    [ -f "$dir/agg-\$id.json" ] && cp "$dir/agg-\$id.json" "\$out/jg-test-timing-aggregate.json"; exit 0 ;;
  *"--status success"*) cat "$dir/green-run.json" ;;
  *) cat "$dir/latest-run.json" ;;
esac
EOF
  printf '[{"databaseId":50,"status":"completed","conclusion":"success","headSha":"%s"}]\n' "$(cat "$dir/green-head")" > "$dir/green-run.json"
  agg "$dir/agg-50.json" a:0 b:0 c:0 d:0
  printf '%s\n' "$dir"
}

# redrun <dir> <run id>: the latest run on main is that red run at the red head.
redrun() { printf '[{"databaseId":%s,"status":"completed","conclusion":"failure","headSha":"%s"}]\n' "$2" "$(cat "$1/red-head")" > "$1/latest-run.json"; }

ralarm() {  # <dir> [alarm args]
  local dir=$1; shift
  ( cd "$dir/repo" && PATH="$dir/fakebin:$PATH" JG_HOME="$dir/home" JG_STATE_OVERRIDE="$dir/home/state" JG_DATA_OVERRIDE="$dir/home/data" \
    JG_ROOT_OVERRIDE="$dir/repo" bash "$dir/repo/bin/jg-post-merge-ci.sh" --main "$@" 2>&1 )
}

test_a_new_failure_names_the_run_and_the_commit_that_introduced_it() {
  local dir out
  dir=$(rworld newfail); redrun "$dir" 61; agg "$dir/agg-61.json" a:0 b:1 c:0 d:0
  out=$(ralarm "$dir" --restore "$dir/proj"); assert_contains "$out" 'filed ci-red-main-61' 'a new failure files one item for the run'
  assert_contains "$(cat "$dir/backlog-calls")" 'tests/b.test.sh: counted: regression; introduced by' 'the item names the failing script and how the rule typed it'
  assert_contains "$(cat "$dir/backlog-calls")" "introduced by $(git -C "$dir/repo" rev-parse --short "$(cat "$dir/red-head")")" 'the item names the commit that touched the script'
  assert_contains "$(cat "$dir/backlog-calls")" 'actions/runs/61' 'the item names the run'
  [ ! -f "$dir/trunk-calls" ] || fail "one counted failure is inside the grace: no restore, got $(cat "$dir/trunk-calls")"
  assert_contains "$out" 'no restore' 'the alarm says nothing was restored'
  pass 'a new failure files one item naming the run and the commit that introduced it, and restores nothing inside the grace'
}

test_the_same_failure_on_a_later_run_updates_its_open_item() {
  local dir out adds
  dir=$(rworld samefail); redrun "$dir" 61; agg "$dir/agg-61.json" a:0 b:1 c:0 d:0; ralarm "$dir" --restore "$dir/proj" >/dev/null
  adds=$(grep -c '^add ' "$dir/backlog-calls"); redrun "$dir" 62; agg "$dir/agg-62.json" a:0 b:1 c:0 d:0
  out=$(ralarm "$dir" --restore "$dir/proj")
  assert_contains "$out" 'matched tests/b.test.sh to open item ci-red-main-61' 'the carried failure is matched to its open item'
  [ "$(grep -c '^add ' "$dir/backlog-calls")" -eq "$adds" ] || fail 'a failure that already existed must not file a second item'
  assert_contains "$(sed -n '/^update /,$p' "$dir/backlog-calls")" 'actions/runs/62' 'the open item is updated with the later run'
  [ ! -f "$dir/trunk-calls" ] || fail "a carried failure must never restore: $(cat "$dir/trunk-calls")"
  pass 'the same failure on a later run updates its open item, files nothing and restores nothing'
}

test_a_run_red_under_the_rule_restores_and_a_timeout_never_does() {
  local dir out
  dir=$(rworld redrule); redrun "$dir" 71; agg "$dir/agg-71.json" a:1 b:1 c:1 d:0
  out=$(ralarm "$dir" --restore "$dir/proj"); assert_contains "$out" 'went back to the last green commit' 'three counted failures are red under the rule'
  assert_contains "$(cat "$dir/trunk-calls")" "ci $dir/proj $(cat "$dir/red-head") red" 'the restore goes through the trunk owner with the red head'
  dir=$(rworld timeouts); redrun "$dir" 72; agg "$dir/agg-72.json" a:124 b:124 c:124 d:0
  out=$(ralarm "$dir" --restore "$dir/proj"); assert_contains "$out" 'filed ci-red-main-72' 'timeouts are incomplete and still file the red run'
  assert_contains "$(cat "$dir/backlog-calls")" 'tests/a.test.sh: incomplete: runner-bound timeout' 'a timeout is typed incomplete, never a failure'
  [ ! -f "$dir/trunk-calls" ] || fail 'an incomplete result must never restore'
  dir=$(rworld nogreen); rm -f "$dir/agg-50.json"; redrun "$dir" 73; agg "$dir/agg-73.json" a:1 b:1 c:1 d:1
  out=$(ralarm "$dir" --restore "$dir/proj"); assert_contains "$out" 'filed ci-red-main-73' 'a missing green aggregate still files the red run'
  [ ! -f "$dir/trunk-calls" ] || fail 'with no green baseline the failures are incomplete and never restore'
  dir=$(rworld norestore); redrun "$dir" 74; agg "$dir/agg-74.json" a:1 b:1 c:1 d:0
  ralarm "$dir" >/dev/null; [ ! -f "$dir/trunk-calls" ] || fail 'without --restore nothing is ever restored'
  pass 'a run red under the rule restores through the trunk owner; timeouts, a missing baseline and no flag never do'
}

test_a_red_run_with_no_failing_script_is_still_filed() {
  local dir out
  dir=$(rworld nonscript); redrun "$dir" 81; agg "$dir/agg-81.json" a:0 b:0 c:0 d:0
  out=$(ralarm "$dir"); assert_contains "$out" 'filed ci-red-main-81' 'a red run whose scripts all passed (another job went red) is still filed, not dropped'
  pass 'a red run with no failing script is still filed'
}

# ---- the schedule: the registered check starts the alarm on its own interval, detached, and prints nothing ----
test_the_registered_check_runs_the_alarm_on_its_interval_and_restores_only_when_told() {
  local h=$TMP_ROOT/sched calls i
  mkdir -p "$h/bin" "$h/state" "$h/config" "$h/data"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/alarm-calls"\n' "$h" > "$h/bin/jg-post-merge-ci.sh"; chmod +x "$h/bin/jg-post-merge-ci.sh"
  [ -z "$(bash "$ROOT/core/post-merge-ci/check.sh" check "$h")" ] || fail 'the check must print nothing: the alarm raises its own alert'
  for i in $(seq 1 50); do [ -s "$h/alarm-calls" ] && break; sleep 0.1; done
  assert_equals "$(cat "$h/alarm-calls")" '--main' 'the first tick starts the alarm for the suite on main, with no restore'
  bash "$ROOT/core/post-merge-ci/check.sh" check "$h"; sleep 0.3
  assert_equals "$(wc -l < "$h/alarm-calls")" 1 'a second tick inside the interval starts nothing'
  touch -d '11 minutes ago' "$h/state/.post-merge-ci.last"; printf '%s\n' "$h/proj" > "$h/config/post-merge-ci-restore"
  bash "$ROOT/core/post-merge-ci/check.sh" check "$h"
  for i in $(seq 1 50); do [ "$(wc -l < "$h/alarm-calls")" -ge 2 ] && break; sleep 0.1; done
  calls=$(tail -n 1 "$h/alarm-calls"); assert_equals "$calls" "--main --restore $h/proj" 'the restore project from config reaches the alarm after the interval'
  pass 'the registered check runs the alarm on its interval, prints nothing and restores only when its config names a project'
}

test_a_red_run_files_one_item_naming_the_run
test_the_same_red_run_files_nothing_twice
test_a_green_run_files_nothing
test_an_unfinished_run_waits_for_a_verdict
test_a_new_failure_names_the_run_and_the_commit_that_introduced_it
test_the_same_failure_on_a_later_run_updates_its_open_item
test_a_run_red_under_the_rule_restores_and_a_timeout_never_does
test_a_red_run_with_no_failing_script_is_still_filed
test_the_registered_check_runs_the_alarm_on_its_interval_and_restores_only_when_told
printf 'jg-post-merge-ci-main: ok\n'
