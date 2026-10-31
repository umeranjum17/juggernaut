#!/usr/bin/env bash
# The fast evals are the thin pull request gate's own behaviour checks, so their
# runner must report honestly: every selected eval runs, a failing eval fails the
# run, and --smoke selects exactly the boot eval.
# The cases here drive the real bin/jg-fast-evals.sh; they do not re-implement an
# eval. A runner that printed "ok - " for everything would fail the failure case.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVALS="$ROOT/bin/jg-fast-evals.sh"
TMP_ROOT=$(jg_test_tmproot jg-fast-evals)

test_the_smoke_run_selects_only_the_boot_eval() {
  local out
  out=$(bash "$EVALS" --smoke 2>&1) || fail "the smoke run must pass on this repo"
  assert_contains "$out" 'ok - home-boots' 'the smoke run must run the boot eval'
  assert_not_contains "$out" 'brief-scaffold' 'the smoke run must not run the other evals'
  assert_contains "$out" 'fast-evals: 1/1 passed' 'the smoke summary must count one eval'
  pass 'the smoke run selects only the boot eval'
}

test_the_full_run_passes_every_eval() {
  local out
  out=$(bash "$EVALS" 2>&1) || fail "the full run must pass on this repo"
  assert_contains "$out" 'ok - home-boots' 'home-boots must pass'
  assert_contains "$out" 'ok - brief-scaffold' 'brief-scaffold must pass'
  assert_contains "$out" 'ok - ticket-round-trip' 'ticket-round-trip must pass'
  assert_contains "$out" 'ok - claim-needs-release' 'claim-needs-release must pass'
  assert_contains "$out" 'fast-evals: 4/4 passed' 'the summary must count four evals'
  pass 'the full run passes every eval'
}

test_a_failing_eval_fails_the_run() {
  local stub out rc=0
  stub="$TMP_ROOT/stub-bin"
  mkdir -p "$stub" "$TMP_ROOT/stub-repo/bin"
  # A fleet view that exits cleanly but prints nothing: the boot eval must notice
  # the missing heading rather than pass a silent command.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/jg-fleet-view.sh"
  chmod +x "$stub/jg-fleet-view.sh"
  cp "$EVALS" "$TMP_ROOT/stub-repo/bin/jg-fast-evals.sh"
  out=$(JG_ROOT_OVERRIDE="$TMP_ROOT/stub-repo" bash "$TMP_ROOT/stub-repo/bin/jg-fast-evals.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a failing eval must exit 1, got $rc: $out"
  assert_contains "$out" 'not ok - home-boots' 'the failing eval must be named'
  assert_contains "$out" 'failed: home-boots' 'the summary must name the failing eval'
  pass 'a failing eval fails the run'
}

test_misuse_is_refused() {
  local out rc=0
  out=$(bash "$EVALS" --nonsense 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown argument must exit 2, got $rc"
  assert_contains "$out" 'unknown argument' 'the refusal must name the argument'
  pass 'misuse is refused'
}

test_the_smoke_run_selects_only_the_boot_eval
test_the_full_run_passes_every_eval
test_a_failing_eval_fails_the_run
test_misuse_is_refused
printf 'jg-fast-evals: ok\n'
