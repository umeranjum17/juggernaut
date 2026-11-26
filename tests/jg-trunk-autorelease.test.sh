#!/usr/bin/env bash
# Integration test for `bin/jg-trunk.sh autorelease` (report fable-jg-7v6uw, slice 24): under the release waiver
# (config/trunk-release-waiver) main follows every CI-green trunk commit with no person in between. The real callers run:
# bin/jg-trunk.sh autorelease, the landing check's own `autorelease` step (core/trunk-landing), the owner guard's pre-push
# rule (core/owner-guard) behind a real pre-push hook, and a real fast-forward push to a local bare origin. The forge is a
# stand-in whose `CI required` answer is the file ci-required.
#
# T1 CI required green on the pushed pin: main fast-forwards to exactly that commit (the trunk tip above it stays out), a green
#    row is recorded, the next trunk version is cut at the trunk tip with the very same commits (no replay), and the
#    next trunk is cut although the forge still reads the pull request as open.
# T2 Red: main stays, the red is recorded once, one fix ticket is filed, and a second run files nothing more.
# T3 A run that is pending, never reported or unreadable: nothing moves.
# T4 No release waiver: nothing moves, even on green. A main that is not an ancestor of the pin is refused.
# T5 The pre-push guard: a commit with no green result is refused for main behind a real hook, a rewind is refused, a green
#    fast-forward passes, a push to the trunk branch is out of the rule, and so is a project not registered local-trunk.
# T6 The landing check's step reports a release once, a red once and a wait never, with the home's own tool.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

RULE='owner-rule-5f0e638d'
U=https://github.com/o/r/pull
GUARD="$ROOT/core/owner-guard/owner-guard"

# A world with release 1 pushed from the trunk (a1 on it) and a2 landed above the pushed pin. The forge answers `CI required`
# from the file ci-required, and pull request state from pr-state-<n> (open).
world_released() {  # <name> [no-waiver]
  local out
  world "$1"
  cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-calls"
case "\$2" in
  view) printf 'state: %s\n' "\$(cat "$W/pr-state-\$3" 2>/dev/null || echo open)" ;;
  list) printf 'count: 0\n' ;;
  create) printf '$U/1\n' ;;
esac
SH
  cat > "$W/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-real-calls"
case "\$1 \$2 \$*" in
  'pr view '*isDraft*) printf '{"isDraft":false}\n' ;;
  'pr view '*headRefOid*) git -C "$PROJ" rev-parse trunk ;;
  'pr view '*baseRefName*) printf 'main\ttrunk\n' ;;
  'api repos/o/r/commits/'*check-runs*) cat "$W/ci-required" 2>/dev/null || exit 1 ;;
  'api '*) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$W/fakebin/gh-axi" "$W/fakebin/gh"
  ln -sn "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"
  case "${2-}" in
    no-waiver) ;;
    release-only) trunk waiver "$PROJ" --rule "$RULE" --release >/dev/null 2>&1 || fail "the release waiver must record" ;;
    *) trunk waiver "$PROJ" --rule "$RULE" --autorelease >/dev/null 2>&1 || fail "the automatic release choice must record" ;;
  esac
  lane a1 released >/dev/null; trunk land a1 >/dev/null 2>&1 || fail "a1 must land"; trunk verify "$PROJ" >/dev/null 2>&1 || fail "a1 must verify"
  trunk word release "$PROJ" "ship a1" >/dev/null 2>&1 || fail "the release word must record"
  out=$(trunk release "$PROJ" 2>&1) || fail "the release must be pushed: $out"
  PIN=$(tip)
  lane a2 later >/dev/null; trunk land a2 >/dev/null 2>&1 || fail "a2 must land above the pushed pin"; trunk verify "$PROJ" >/dev/null 2>&1 || fail "a2 must verify"
  TIP=$(tip); printf 'green\n' > "$W/ci-required"
}
origin_main() { git --git-dir="$W/origin.git" rev-parse refs/heads/main; }
ci_rows() { awk -F'\t' -v c="$PIN" -v r="$1" '$2 == c && $4 == r { n++ } END { print n + 0 }' < <(cat "$HOME_D/data/trunk-ci.tsv" 2>/dev/null); }
tickets() { grep -c '^add ci-red-release-proj-' "$W/backlog-calls" 2>/dev/null || true; }

test_green_fast_forwards_main_and_cuts_the_next_trunk() {
  local out
  world_released green
  out=$(trunk autorelease "$PROJ" 2>&1) || fail "T1: autorelease must succeed: $out"
  [ "$(origin_main)" = "$PIN" ] || fail "T1: main must be exactly the pushed pin ${PIN:0:12}, got $(origin_main): $out"
  [ "$(ci_rows green)" = 1 ] || fail "T1: one green row must be recorded for the pin"
  [ "$(cat "$HOME_D/state/trunk-released-proj")" = "$PIN" ] || fail "T1: the released mark must be the pin"
  [ "$(cat "$HOME_D/state/trunk-branch-proj")" = release/v2 ] || fail "T1: the project must be on the next trunk: $out"
  [ "$(git -C "$PROJ" rev-parse release/v2)" = "$TIP" ] || fail "T1: the next trunk must start at the old tip with no replay"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk >/dev/null && fail "T1: the old trunk is carried whole into the next one, so it retires"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$TIP" ] || fail "T1: the green pin must stay on the landed tip"
  assert_contains "$out" "autorelease: main is now ${PIN:0:12}" "T1: the outcome line"
  pass 'T1 a green pin fast-forwards main to exactly that commit and the next trunk is cut at the tip with no replay'
  out=$(trunk autorelease "$PROJ" 2>&1) || fail "T1: a second run must not fail: $out"
  [ "$(origin_main)" = "$PIN" ] || fail "T1: a second run must move nothing"
}

test_red_keeps_main_and_files_one_ticket() {
  local out
  world_released red
  repair_fixture
  printf 'red\n' > "$W/ci-required"
  out=$(trunk autorelease "$PROJ" 2>&1) || fail "T2: a red must not fail the step: $out"
  assert_contains "$out" "autorelease: RED" "T2: the red must be named"
  [ "$(origin_main)" != "$PIN" ] || fail "T2: main must stay"
  [ "$(ci_rows red)" = 1 ] || fail "T2: one red row"
  [ "$(tickets)" = 1 ] || fail "T2: one fix ticket, got $(tickets)"
  await_repair_lane "ci-red-release-proj-${PIN:0:12}"
  trunk autorelease "$PROJ" >/dev/null 2>&1 || fail "T2: a second run must not fail"
  printf '#!/usr/bin/env bash\necho "REQUIRED CHECK: CI required (FAILURE)"\n' > "$HOME_D/bin/jg-pr-state.sh"
  chmod +x "$HOME_D/bin/jg-pr-state.sh"
  out=$(PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-release/ci-watch.sh" check "$HOME_D" 2>&1) || fail "T2: the other release observer must exit cleanly"
  [ -z "$out" ] && [ "$(wc -l < "$W/spawn-calls")" = 1 ] || fail "T2: the other release observer must not start another repair: $out"
  [ "$(ci_rows red)" = 1 ] && [ "$(tickets)" = 1 ] || fail "T2: a second run must record and file nothing more"
  git -C "$PROJ" rev-parse --verify -q refs/heads/release/v2 >/dev/null && fail "T2: no next trunk on a red"
  pass 'T2 a red leaves main alone, records the red once and files one fix ticket'
}

test_unfinished_or_unreadable_runs_wait() {
  local s out
  world_released wait
  for s in pending absent garbage; do
    printf '%s\n' "$s" > "$W/ci-required"
    out=$(trunk autorelease "$PROJ" 2>&1) || fail "T3: a wait must not fail ($s): $out"
    assert_contains "$out" "autorelease: waiting" "T3: $s must wait"
    [ "$(origin_main)" != "$PIN" ] || fail "T3: $s must not move main"
  done
  rm -f "$W/ci-required"
  trunk autorelease "$PROJ" 2>&1 | grep -q "waiting" || fail "T3: an unreadable forge must wait"
  [ "$(ci_rows green)" = 0 ] || fail "T3: no green row on a wait"
  pass 'T3 a pending, unreported or unreadable run waits and moves nothing'
}

test_no_waiver_and_diverged_main_are_refused() {
  local out
  world_released nowaiver no-waiver
  out=$(trunk autorelease "$PROJ" 2>&1) || fail "T4: no waiver must not fail: $out"
  assert_contains "$out" "needs the captain's word" "T4: no waiver, no push"
  [ "$(origin_main)" != "$PIN" ] || fail "T4: main must not move without the waiver"
  world_released releaseonly release-only
  out=$(trunk autorelease "$PROJ" 2>&1) || fail "T4: a release waiver alone must not fail: $out"
  assert_contains "$out" "not chosen for the automatic release" "T4: a release waiver alone does not choose the automatic release"
  out=$(trunk publish "$PROJ" 2>&1) || fail "T4: publish without the choice must not fail: $out"
  assert_contains "$out" "not chosen for the automatic release" "T4: publish needs the choice too"
  [ "$(origin_main)" != "$PIN" ] || fail "T4: main must not move on a release waiver alone"
  world_released diverged
  git -C "$PROJ" worktree add -q -b other "$W/other" "$(origin_main)"
  commit_in "$W/other" other.txt x "main moves alone"; git -C "$W/other" push -q origin other:refs/heads/main
  out=$(trunk autorelease "$PROJ" 2>&1) && fail "T4: a main that is not an ancestor of the pin must be refused: $out"
  assert_contains "$out" "fast-forward" "T4: the refusal says why"
  [ "$(origin_main)" != "$PIN" ] || fail "T4: nothing is pushed over a diverged main"
  pass 'T4 no waiver, a release waiver without the automatic-release choice, and a diverged main all leave main alone'
}

test_pre_push_guard_admits_only_green_fast_forwards() {
  local out base bad
  world_released guard
  base=$(origin_main)
  printf '#!/bin/sh\nexec "%s" pre-push "$@"\n' "$GUARD" > "$PROJ/.git/hooks/pre-push"; chmod +x "$PROJ/.git/hooks/pre-push"
  export JG_HOME="$HOME_D"
  out=$(cd "$PROJ" && plain_git push origin "$PIN:refs/heads/main" 2>&1) && fail "T5: a commit with no green result must be refused: $out"
  assert_contains "$out" "no recorded CI-green result" "T5: the guard must say why"
  [ "$(origin_main)" = "$base" ] || fail "T5: main must not move"
  printf 'proj\t%s\t1\tgreen\n' "$PIN" >> "$HOME_D/data/trunk-ci.tsv"
  bad=$(git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit-tree "$PIN^{tree}" -m rewrite)
  printf 'proj\t%s\t1\tgreen\n' "$bad" >> "$HOME_D/data/trunk-ci.tsv"
  printf 'refs/heads/trunk %s refs/heads/main %s\n' "$bad" "$PIN" | (cd "$PROJ" && "$GUARD" pre-push) >/dev/null 2>&1 \
    && fail "T5: a green commit that does not fast-forward main must be refused"
  out=$(cd "$PROJ" && plain_git push origin "$PIN:refs/heads/main" 2>&1) || fail "T5: a green fast-forward must pass: $out"
  [ "$(origin_main)" = "$PIN" ] || fail "T5: main must move to the green pin"
  (cd "$PROJ" && plain_git push -q origin "$TIP:refs/heads/trunk-side" 2>&1) || fail "T5: a push to another branch is out of the rule"
  git -C "$PROJ" worktree add -q -b free "$W/free-wt" "$TIP" 2>/dev/null
  mkdir -p "$W/unreg" && git -C "$W/unreg" init -q && git -C "$W/unreg" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m x
  printf 'refs/heads/x %s refs/heads/main %s\n' "$(git -C "$W/unreg" rev-parse HEAD)" 0000000000000000000000000000000000000000 | (cd "$W/unreg" && "$GUARD" pre-push) >/dev/null 2>&1 \
    || fail "T5: a project that is not local-trunk is out of the rule"
  unset JG_HOME
  pass 'T5 the pre-push guard admits main only for a green fast-forward, in a local-trunk project'
}

test_the_landing_check_reports_once() {
  local out line
  world_released tick
  sweep() { PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" bash "$ROOT/core/trunk-landing/trunk-landing.sh" autorelease "$HOME_D" proj 2>&1; }
  printf 'pending\n' > "$W/ci-required"; sweep >/dev/null
  [ ! -s "$HOME_D/data/jg-trunk-landing/outbox" ] || fail "T6: a wait must be silent"
  printf 'green\n' > "$W/ci-required"; sweep >/dev/null
  line=$(grep -c 'proj: main is now' "$HOME_D/data/jg-trunk-landing/outbox" || true)
  [ "$line" = 1 ] || fail "T6: one release line, got $line: $(cat "$HOME_D/data/jg-trunk-landing/outbox" 2>/dev/null)"
  sweep >/dev/null
  [ "$(grep -c 'main is now' "$HOME_D/data/jg-trunk-landing/outbox")" = 1 ] || fail "T6: the same line is not repeated"
  pass 'T6 the landing check releases through the home tool, says so once and stays silent on a wait'
}

test_green_fast_forwards_main_and_cuts_the_next_trunk
test_red_keeps_main_and_files_one_ticket
test_unfinished_or_unreadable_runs_wait
test_no_waiver_and_diverged_main_are_refused
test_pre_push_guard_admits_only_green_fast_forwards
test_the_landing_check_reports_once
printf 'jg-trunk-autorelease: ok\n'
