#!/usr/bin/env bash
# The one seam for the trunk flow's open captain calls (bin/jg-trunk.sh).
# Usage: . bin/jg-trunk-policy-lib.sh; jg_trunk_policy <key> [<project>]
#
# Every decision the captain has not yet made is a key here with its current SAFE
# default, and nothing else in the trunk flow changes with the answer. A home
# overrides a key with a `key=value` line in config/trunk-policy; `key@project=value`
# overrides it for one project. An unknown key prints nothing and returns 1.
#
#   trunk-branch          trunk       name of the local trunk branch
#   trunk-owner           this-home   which home owns the trunk; only this-home is built
#   away-landing          held        held: no landing while state/.afk exists; allowed
#   protected-landing     refuse      refuse: a commit touching protected-paths stays unlanded;
#                                     gate: it may land after the configured gates
#   protected-paths       (gate machinery, below) space-separated globs
#   gate-lint             bin/jg-lint.sh --changed-base HEAD^   the lint every landing passes, over the changed files only
#   gate-full             the landing's tests: the CI invariants that need no network (no tracked personal
#                         paths, no committed binaries, regression coverage), then only the test scripts
#                         the changed files map to (HEAD^ is the trunk tip: the lander rebases the lane first)
#   gate-verify           the same invariants, then the whole suite: `verify` runs it on a landed commit after
#                         the landing, and a script that fails there and passes on the commit's parent
#                         reverts that one commit by itself
#   gate-rerun            bin/jg-test-run.sh --jobs 1   the command that reruns the scripts a failed full gate
#                                     named, on the trunk tip's tree, to tell the tip's own red from the lane's;
#                                     the script paths are appended to it
#   gate-red-ticket       core-self-checks-red   the ticket that receives one note for each new tip red
#                                     (empty: no note, the alert still goes out)
#   release-after-hours   48          age of the oldest unreleased commit that makes a release due
#   batch-max             5           the most queued lanes the merge queue stacks into one landing (2 or more queued lanes land as one stack)
#   live-quiet-minutes    20          under a go-live waiver: the trunk goes live once no landing has happened for this long
#   live-cap-minutes      60          under a go-live waiver: ...or once the oldest landing not yet live is this old, whichever is first
_JG_TRUNK_PROTECTED='bin/jg-merge-* bin/jg-pr-merge.sh bin/jg-trunk* bin/jg-dod-lib.sh bin/jg-captain-hold.sh bin/jg-test-run.sh bin/jg-lint.sh bin/jg-ci-* bin/jg-update.sh bin/jg-ff-lib.sh bin/jg-stack.sh core/merge-on-green/* core/merge-card/* core/owner-guard/* core/owner-rules/* core/receipts/* core/teardown/* core/delete-guard/* core/kill-guard/* policy/gate/* .github/workflows/*'

# shellcheck disable=SC2016 # the command substitution runs in the gate's shell, not here
_JG_TRUNK_GATE_VERIFY='test -z "$(git ls-files -- data state config projects .no-mistakes)" && bin/jg-committed-binary-check.sh && bin/jg-test-run.sh --check-coverage && bin/jg-test-run.sh --all'
# The landing's tests are the same invariants with the changed files' tests in place of the whole suite.
_JG_TRUNK_GATE_FULL="${_JG_TRUNK_GATE_VERIFY% --all} --changed --base HEAD^ --exclude-family real-herdr-gated --max-weight-ms 60000"

jg_trunk_policy() {  # <key> [<project>]
  local key=$1 proj=${2-} file val=
  file="${JG_CONFIG_OVERRIDE:-${JG_HOME:-.}/config}/trunk-policy"
  if [ -r "$file" ]; then
    [ -z "$proj" ] || val=$(sed -n "s/^$key@$proj=//p" "$file" | tail -1)
    [ -n "$val" ] || val=$(sed -n "s/^$key=//p" "$file" | tail -1)
  fi
  if [ -z "$val" ]; then
    case $key in
      trunk-branch) val=trunk ;;
      trunk-owner) val=this-home ;;
      away-landing) val=held ;;
      protected-landing) val=refuse ;;
      protected-paths) val=$_JG_TRUNK_PROTECTED ;;
      gate-lint) val='bin/jg-lint.sh --changed-base HEAD^' ;;
      gate-full) val=$_JG_TRUNK_GATE_FULL ;;
      gate-verify) val=$_JG_TRUNK_GATE_VERIFY ;;
      gate-rerun) val='bin/jg-test-run.sh --jobs 1' ;;
      gate-red-ticket) val=core-self-checks-red ;;
      release-after-hours) val=48 ;;
      batch-max) val=5 ;;
      live-quiet-minutes) val=20 ;;
      live-cap-minutes) val=60 ;;
      *) return 1 ;;
    esac
  fi
  printf '%s\n' "$val"
}

# The branch a project's trunk is on now: the version the last rollover recorded (trunk-v2, ...), else the
# trunk-branch policy value. Usage: jg_trunk_branch <project> [<state-dir>]
jg_trunk_branch() {
  local f="${2:-${JG_STATE_OVERRIDE:-${JG_HOME:-.}/state}}/trunk-branch-$1"
  if [ -s "$f" ]; then cat "$f"; else jg_trunk_policy trunk-branch "$1"; fi
}
