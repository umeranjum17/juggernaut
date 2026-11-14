#!/usr/bin/env bash
# The lander's retest after a conflict was resolved: the owned part of the landing run state `retesting` (core/machines/landing.states).
# Usage: . bin/jg-trunk-retest-lib.sh
#   jg_trunk_retest <project-dir> <resolved commit> <extends commit> <touched files file> <runner command> <limit seconds> <scratch dir>
#
# The runner runs in a detached copy of the lander's own (a worktree under <scratch dir>, removed again) at the resolved commit, with a
# time limit. It is told what to prove in the environment:
#   JG_RETEST_FILES    the touched files, one per line, in a file       JG_RETEST_COMMIT    the resolved commit (the copy's HEAD)
#   JG_RETEST_EXTENDS  the lane commit whose receipt the new one extends JG_RETEST_OUTCOME   the claim to prove
#   JG_RETEST_LIMIT    the limit in seconds
# With no runner command the home runs `done-done verify --affected-by <files> --extends <lane commit>`: only the journeys those files
# affect run, and the receipt it writes names the resolved commit and the receipt it extends. The result is the runner's exit code:
#   0   the journeys pass: prints nothing, return code 0
#   1   a journey fails on the commit: return code 1, the last output line (the failure) on stderr (the red is the commit's own)
#   any other code, or a runner past its limit: return code 2, the reason on stderr (a fault of the runner says nothing about the commit)
# The runner's `journeys: <n> of <total>` line, when it prints one, is passed on to stderr as `retest: ...`.

jg_trunk_retest() {  # <project-dir> <resolved commit> <extends commit> <touched file> <runner command> <limit seconds> <scratch dir>
  local proj=$1 fresh=$2 base=$3 files=$4 cmd=$5 limit=$6 scratch=$7 wt out rc=0
  mkdir -p "$scratch" || { echo "cannot make the retest scratch directory $scratch" >&2; return 2; }
  wt="$scratch/retest-copy"; out="$scratch/retest.log"; : > "$out"
  git -C "$proj" worktree add -q --detach "$wt" "$fresh" >/dev/null 2>&1 || { echo "cannot make the lander's copy at the resolved commit" >&2; return 2; }
  # shellcheck disable=SC2064 # the paths are fixed now
  trap "git -C '$proj' worktree remove --force '$wt' >/dev/null 2>&1 || :; git -C '$proj' worktree prune >/dev/null 2>&1 || :; trap - RETURN" RETURN
  # shellcheck disable=SC2016 # the command expands its own variables inside the copy
  [ -n "$cmd" ] || cmd='done-done verify --foreground --affected-by "$(paste -sd, "$JG_RETEST_FILES")" --extends "$JG_RETEST_EXTENDS" --outcome "$JG_RETEST_OUTCOME"'
  (cd "$wt" && JG_RETEST_FILES=$files JG_RETEST_COMMIT=$fresh JG_RETEST_EXTENDS=$base JG_RETEST_LIMIT=$limit \
    JG_RETEST_OUTCOME="the conflict resolution of the lane keeps every journey its touched files affect working" \
    timeout --kill-after=10 "$limit" bash -c "$cmd" >"$out" 2>&1 </dev/null) || rc=$?
  grep -E '^journeys: ' "$out" | tail -n 1 | sed 's/^/retest: /' >&2 || :
  case $rc in
    0) return 0 ;;
    1) { grep . "$out" | tail -n 1 | cut -c1-200 || :; } >&2; return 1 ;;
    124|137) echo "the retest runner did not finish inside its limit of $limit seconds" >&2; return 2 ;;
    *) echo "the retest runner stopped with exit $rc: $(grep . "$out" | tail -n 1 | cut -c1-200 || :)" >&2; return 2 ;;
  esac
}
