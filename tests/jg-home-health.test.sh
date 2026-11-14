#!/usr/bin/env bash
# Integration test for bin/jg-home-health.sh: the per-home health check after a live move and the pin-back that undoes a
# bad move on the one home it broke (ap-t4-home-health-pinback, slice T4). Real git repositories and the real home guard.
#
# T1 A healthy home (fresh beacon, current overlay, guard present, session start in time, HEAD at the base) passes.
# T2 Each failure names its reason: stale-beacon, stale-overlay, missing-guard, slow-session-start, not-at-base.
# T2b A home read BEFORE a move (check --all) and checked after it (check --before): a fault it already had is carried and
#    is not a failure, a new fault fails, and the move's own faults (missing-guard, not-at-base) are never carried.
# T3 The pin-back restores the recorded pre-move HEAD, even when that HEAD is not on the trunk (the first rollback after
#    the convergence), through the guard, and writes rolled-back:<reason> in trunk-in-use.tsv.
# T4 The pin-back refuses a dirty tree, a HEAD that is not the recorded post-move HEAD, and a home with no record.
# T5 A home that fails on both commits is recorded rolled-back:start-failed-both with ONE blocked line on the parent
#    channel; running it again adds nothing (no loop).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-home-health)
HEALTH="$ROOT/bin/jg-home-health.sh"
GUARD="$ROOT/bin/jg-home-guard.sh"
STRIP="$ROOT/bin/jg-git-strip-ai-trailers.sh"

# The machine-wide hooks path would hide the repository's own reference-transaction hook, so every git call here ignores it.
clean_env=(GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
g() { env "${clean_env[@]}" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid git "$@"; }
health() { env "${clean_env[@]}" JG_HOME="$W/main" JG_DATA_OVERRIDE="$W/main/data" "$HEALTH" "$@"; }
commit() { printf '%s\n' "$3" > "$1/$2"; g -C "$1" add "$2"; g -C "$1" commit -q -m "$4"; }

# world <name> (SLOW_TRUNK=1: the trunk commit makes the supervision read slow): a lead home H at the trunk commit T (post-move) that left PRE (a commit the trunk does not hold, whose whole
# tree T holds), with the guard installed, a fresh beacon, one launch overlay and a fast supervision read.
world() {
  W="$TMP_ROOT/$1"; H="$W/lead"; mkdir -p "$W/main/data" "$W/main/state" "$H/bin" "$H/state"
  g init -q -b main "$H"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$H/bin/jg-supervision-instructions.sh"; chmod +x "$H/bin/jg-supervision-instructions.sh"
  commit "$H" base.txt base "base"; g -C "$H" add bin; g -C "$H" commit -q -m "supervision read"; BASE=$(g -C "$H" rev-parse HEAD)
  g -C "$H" checkout -q -b trunk
  commit "$H" a.txt one "trunk a"
  if [ "${SLOW_TRUNK:-}" = 1 ]; then printf '#!/usr/bin/env bash\nsleep 3\n' > "$H/bin/jg-supervision-instructions.sh"; g -C "$H" commit -q -am "slow read"; fi
  commit "$H" b.txt two "trunk b"; T=$(g -C "$H" rev-parse HEAD)
  g -C "$H" checkout -q -b old "$BASE"
  commit "$H" a.txt one "home-only a"; PRE=$(g -C "$H" rev-parse HEAD)
  g -C "$H" checkout -q main; g -C "$H" reset -q --hard "$PRE"
  env "${clean_env[@]}" "$GUARD" install "$H" --tip "$T" >/dev/null || fail "guard install"
  JG_TRUNK_LIVE=1 JG_TRUNK_TIP="$T" g -C "$H" reset -q --keep "$T" || fail "the live move to the trunk tip"
  touch "$H/state/.last-watcher-beat"
  mkdir -p "$H/wt"; "$STRIP" install "$H/state/probe.git-hooks" "$H/wt" >/dev/null || fail "overlay install"
  printf 'lead1\n' > "$H/.jg-squad-lead-home"
  mkdir -p "$W/main/state"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$W/main" > "$H/.jg-squad-lead-parent"
}
# Everything the world adds besides tracked files is untracked; status of tracked files is what the pin-back judges.

failing_reason() {  # <expect> <label> <args...>: the check must fail with <expect> as its reason
  local expect=$1 label=$2 out rc=0; shift 2
  out=$(health check "$H" "$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$label must fail, but it passed: $out"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "$expect" "$label must name its reason on the last line"
}

test_a_healthy_home_passes() {
  local out
  world healthy
  out=$(health check "$H" "$T" --session-max 20 2>&1) || fail "a healthy home must pass: $out"
  assert_contains "$out" "ok" "a healthy home says ok"
  pass 'a healthy home passes the health check'
}

test_each_failure_names_its_reason() {
  local hooks
  world beacon
  touch -d '3 hours ago' "$H/state/.last-watcher-beat"
  failing_reason "stale-beacon" "a stale beacon" "$T" --session-max 20
  rm -f "$H/state/.last-watcher-beat"
  failing_reason "stale-beacon" "a missing beacon" "$T" --session-max 20

  world overlay
  hooks="$H/state/probe.git-hooks"; chmod u+w "$hooks"; rm -f "$hooks/pre-commit"; chmod 500 "$hooks"
  failing_reason "stale-overlay" "an overlay missing a hook of the installer's set" "$T" --session-max 20

  world guard
  env "${clean_env[@]}" "$GUARD" uninstall "$H" >/dev/null
  failing_reason "missing-guard" "a home with no guard" "$T" --session-max 20

  world slow
  printf '#!/usr/bin/env bash\nsleep 3\n' > "$H/bin/jg-supervision-instructions.sh"
  failing_reason "slow-session-start" "a session start over its bound" "$T" --session-max 1

  world base
  failing_reason "not-at-base" "a home that is not at the base it was moved to" "$PRE" --session-max 20
  pass 'stale beacon, stale overlay, missing guard, slow session start and wrong base each fail with the named reason'
}

test_a_fault_the_home_had_before_the_move_is_carried_and_a_new_one_fails() {
  local out rc=0 before hooks
  world carried
  hooks="$H/state/probe.git-hooks"; chmod u+w "$hooks"; rm -f "$hooks/pre-commit"; chmod 500 "$hooks"
  touch -d '3 hours ago' "$H/state/.last-watcher-beat"
  before="$W/before.txt"
  out=$(health check "$H" --all --session-max 20 2>&1) || rc=$?
  printf '%s\n' "$out" > "$before"
  [ "$rc" -ne 0 ] && [ "$(grep -c . "$before")" = 2 ] || fail "--all must print every failed fact (the overlay and the beacon): $out"
  out=$(health check "$H" "$T" --before "$before" --session-max 20 2>&1) || fail "faults the home had before must not fail the move: $out"
  assert_contains "$out" "carried stale-overlay:" "the overlay fault is carried"
  assert_contains "$out" "carried stale-beacon:" "the beacon fault is carried"
  assert_equals "ok $H" "$(printf '%s\n' "$out" | tail -n 1)" "a home with only carried faults ends ok"
  printf 'stale-beacon: the watcher beacon was old\n' > "$before"
  rc=0; out=$(health check "$H" "$T" --before "$before" --session-max 20 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a fault absent from the earlier read must fail: $out"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "stale-overlay" "the new fault is the last line"
  env "${clean_env[@]}" "$GUARD" uninstall "$H" >/dev/null
  printf 'missing-guard: none\nnot-at-base: none\n' > "$before"
  rc=0; out=$(health check "$H" "$T" --before "$before" --session-max 20 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing guard is never carried: $out"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "missing-guard:" "the missing guard is named"
  rc=0; out=$(health check "$H" "$PRE" --before "$before" --session-max 20 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a wrong base is never carried: $out"
  assert_contains "$out" "not-at-base:" "the wrong base is named"
  pass 'a fault the home had before the move is carried, a new fault fails, and the move'"'"'s own faults are never carried'
}

test_the_pinback_restores_the_recorded_pre_move_head() {
  local out row
  world pinback
  g -C "$H" merge-base --is-ancestor "$PRE" "$T" && fail "fixture: the pre-move HEAD must not be on the trunk"
  out=$(health pinback "$H" --project juggernaut --key lead1 --reason stale-beacon 2>&1) || fail "the pin-back must pass: $out"
  assert_equals "$PRE" "$(g -C "$H" rev-parse HEAD)" "the home must be back at the pre-move HEAD, which is not on the trunk"
  assert_equals "$PRE" "$(g -C "$H" rev-parse main)" "main must follow"
  row=$(tail -n 1 "$W/main/data/trunk-in-use.tsv")
  assert_equals "juggernaut:lead1"$'\t'"$T"$'\t'"$(printf '%s' "$row" | cut -f3)"$'\t'"rolled-back:stale-beacon"$'\t'"$PRE" "$row" "the row names the home, the moved-to sha, the reason and the pre-move HEAD"
  pass 'the pin-back restores the recorded pre-move HEAD (not on the trunk) through the guard and writes rolled-back:<reason>'
}

test_the_pinback_refuses_what_it_may_not_do() {
  local out rc
  world dirty
  printf 'mine\n' >> "$H/a.txt"
  rc=0; out=$(health pinback "$H" --project juggernaut --key lead1 --reason r 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a pin-back over a dirty tree must refuse"
  assert_contains "$out" "uncommitted" "the dirty refusal says why"
  assert_equals "$T" "$(g -C "$H" rev-parse HEAD)" "a refused pin-back leaves the home where it was"
  g -C "$H" checkout -q -- a.txt

  world moved
  g -C "$H" reset -q --keep "$BASE" 2>/dev/null || env JG_TRUNK_PINBACK=1 "${clean_env[@]}" git -C "$H" reset -q --keep "$BASE"
  rc=0; out=$(health pinback "$H" --project juggernaut --key lead1 --reason r 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a pin-back from a HEAD that is not the recorded post-move HEAD must refuse"
  assert_contains "$out" "not the HEAD" "the wrong-head refusal says why"

  world norecord
  rm -f "$H/.git/jg-home-guard/pre-move"
  rc=0; out=$(health pinback "$H" --project juggernaut --key lead1 --reason r 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a pin-back with no record of the move must refuse"
  assert_contains "$out" "no record" "the no-record refusal says why"
  assert_equals "$T" "$(g -C "$H" rev-parse HEAD)" "a refused pin-back leaves the home where it was"
  pass 'the pin-back refuses a dirty tree, a HEAD that is not the recorded post-move HEAD, and a home with no record'
}

test_a_home_failing_on_both_commits_is_blocked_once() {
  local out rc n rows
  world both
  rm -f "$H/state/.last-watcher-beat"      # no beacon on either commit: the lead never comes up
  rc=0; out=$(health verify "$H" "$T" --project juggernaut --key lead1 --session-max 20 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a failing home must make verify fail"
  assert_equals "$PRE" "$(g -C "$H" rev-parse HEAD)" "the failing home is pinned back to its pre-move HEAD"
  assert_contains "$(tail -n 1 "$W/main/data/trunk-in-use.tsv")" "rolled-back:start-failed-both" "a home failing on both commits is recorded start-failed-both"
  n=$(grep -c '^blocked' "$W/main/state/lead1.status" 2>/dev/null || true)
  assert_equals "1" "$n" "ONE blocked line reaches the parent channel"
  rows=$(wc -l < "$W/main/data/trunk-in-use.tsv")
  rc=0; out=$(health verify "$H" "$T" --project juggernaut --key lead1 --session-max 20 2>&1) || rc=$?
  assert_equals "1" "$(grep -c '^blocked' "$W/main/state/lead1.status")" "a second run adds no second blocked line"
  assert_equals "$rows" "$(wc -l < "$W/main/data/trunk-in-use.tsv")" "a second run adds no second row (no loop)"

  # Failing only on the new commit: pinned back and the old commit is healthy, so the row says why and nothing is blocked.
  SLOW_TRUNK=1 world newonly
  rc=0; out=$(health verify "$H" "$T" --project juggernaut --key lead1 --session-max 1 2>&1) || rc=$?
  assert_equals "1" "$rc" "a failure on the new commit only exits 1"
  assert_equals "$PRE" "$(g -C "$H" rev-parse HEAD)" "the home is pinned back"
  assert_contains "$(tail -n 1 "$W/main/data/trunk-in-use.tsv")" "rolled-back:slow-session-start" "the row names the reason"
  [ ! -s "$W/main/state/lead1.status" ] || fail "no blocked line when the old commit is healthy"

  world once
  rc=0; out=$(health verify "$H" "$T" --project juggernaut --key lead1 --session-max 20 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a healthy home must verify clean: $out"
  assert_equals "$T" "$(g -C "$H" rev-parse HEAD)" "a healthy home stays on the new commit"
  pass 'a home failing on both commits is recorded start-failed-both with one blocked line and no loop; a healthy home stays moved'
}

test_a_healthy_home_passes
test_each_failure_names_its_reason
test_a_fault_the_home_had_before_the_move_is_carried_and_a_new_one_fails
test_the_pinback_restores_the_recorded_pre_move_head
test_the_pinback_refuses_what_it_may_not_do
test_a_home_failing_on_both_commits_is_blocked_once
