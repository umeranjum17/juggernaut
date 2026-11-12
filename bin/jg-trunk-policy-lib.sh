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
#                         the changed files map to, in eight shards run side by side (HEAD^ is the trunk tip:
#                         the lander rebases the lane first)
#   gate-verify           the same invariants, then the whole suite: `verify` runs it on a landed commit on
#                         demand (never per landing: the whole suite runs on the release PR in GitHub CI), and
#                         a script that fails there and passes on the commit's parent reverts that one commit
#                         gate-lint, gate-full and gate-verify defaults are Juggernaut's own suite: they apply only to a repository
#                         that carries it (bin/jg-test-run.sh at the commit). Any other project runs only a gate its home set for it
#                         (gate-verify@<project>, else gate-full@<project> for verify), and with none there is no gate: nothing runs and
#                         nothing goes red (jg_trunk_gate).
#   gate-rerun            bin/jg-test-run.sh --jobs 1   the command that reruns the scripts a failed full gate
#                                     named, on the trunk tip's tree, to tell the tip's own red from the lane's;
#                                     the script paths are appended to it
#   gate-red-ticket       core-self-checks-red   the ticket that receives one note for each new tip red
#                                     (empty: no note, the alert still goes out)
#   release-after-hours   48          age of the oldest unreleased commit that makes a release due
#   batch-max             5           the most queued lanes the merge queue stacks into one landing (2 or more queued lanes land as one stack)
#   gate-slots            2           the most landing gates that run at once: a second lane is gated on top of the first one's commit and lands right behind it; 1 lands one lane at a time
#   flush-at-ready        3           the landing check holds ready lanes until this many are ready (or flush-after-minutes passes), then lands them all as one batch; 1 lands every lane as soon as it is ready
#   flush-after-minutes   20          ...or until the oldest ready lane has waited this long, whichever is first
#   live-quiet-minutes    20          under a go-live waiver: the trunk goes live once no landing has happened for this long
#   live-cap-minutes      60          under a go-live waiver: ...or once the oldest landing not yet live is this old, whichever is first
#   pr-page-minutes      60           how often the pull request pager (core/pr-pager) pages the lead of a pull request that is still open
#   release-after-commits 10          unreleased commits on the trunk that make a release due, beside release-after-hours (whichever is first)
#   conflict-resolver     (empty)     the command of the agent that resolves a rebase conflict in the lander's copy (bin/jg-trunk-resolve-lib.sh);
#                                     empty sends every conflict back to the worker, as before
#   conflict-limit-seconds 600        how long that agent has before the run ends returned
#   no-green-alarm-minutes 15         the trunk with no green commit this long (since the oldest commit above the green pin landed) raises one alarm to Overwatch
_JG_TRUNK_PROTECTED='bin/jg-merge-* bin/jg-pr-merge.sh bin/jg-trunk* bin/jg-dod-lib.sh bin/jg-captain-hold.sh bin/jg-test-run.sh bin/jg-lint.sh bin/jg-ci-* bin/jg-update.sh bin/jg-ff-lib.sh bin/jg-stack.sh core/merge-on-green/* core/merge-card/* core/owner-guard/* core/owner-rules/* core/receipts/* core/teardown/* core/delete-guard/* core/kill-guard/* policy/gate/* .github/workflows/*'

# shellcheck disable=SC2016 # the command substitution runs in the gate's shell, not here
_JG_TRUNK_GATE_VERIFY='test -z "$(git ls-files -- data state config projects .no-mistakes)" && bin/jg-committed-binary-check.sh && bin/jg-test-run.sh --check-coverage && bin/jg-test-run.sh --all'
# The landing's tests are the same invariants with the changed files' tests in place of the whole suite: the
# fast required set, its eight shards run side by side (bin/jg-test-run.sh --required-shards), one timing file
# per shard and their aggregate under the lander's JG_TRUNK_GATE_OUTPUT directory.
# shellcheck disable=SC2016 # the command substitution runs in the gate's shell, not here
_JG_TRUNK_GATE_FULL="${_JG_TRUNK_GATE_VERIFY% --all}"' --required-shards HEAD^ "${JG_TRUNK_GATE_OUTPUT:-$(mktemp -d)}"'

# The value a home set for a key (key@project first, then key), empty when it set none.
_jg_trunk_policy_set() {  # <key> [<project>]
  local key=$1 proj=${2-} file val=
  file="${JG_CONFIG_OVERRIDE:-${JG_HOME:-.}/config}/trunk-policy"
  if [ -r "$file" ]; then
    [ -z "$proj" ] || val=$(sed -n "s/^$key@$proj=//p" "$file" | tail -1)
    [ -n "$val" ] || val=$(sed -n "s/^$key=//p" "$file" | tail -1)
  fi
  printf '%s' "$val"
}

# The gate command to run for one project at one commit, or nothing (status 1) when that project has no such gate.
# The built-in gate-lint, gate-full and gate-verify defaults are Juggernaut's own suite, so they apply only to a
# repository that carries it (the commit has bin/jg-test-run.sh). Any other project runs the gate its home set for it:
# its own key, and for gate-verify its own gate-full when it set no gate-verify. With none set there is no gate and
# nothing can go red for it.   Usage: jg_trunk_gate <gate-lint|gate-full|gate-verify> <project> <project-dir> <commit>
jg_trunk_gate() {
  local key=$1 proj=$2 dir=$3 commit=$4 val
  val=$(_jg_trunk_policy_set "$key" "$proj")
  [ -n "$val" ] || { [ "$key" != gate-verify ] || val=$(_jg_trunk_policy_set gate-full "$proj"); }
  if [ -z "$val" ] && git -C "$dir" cat-file -e "$commit:bin/jg-test-run.sh" 2>/dev/null; then val=$(jg_trunk_policy "$key" "$proj"); fi
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}

jg_trunk_policy() {  # <key> [<project>]
  local key=$1 proj=${2-} val
  val=$(_jg_trunk_policy_set "$key" "$proj")
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
      gate-slots) val=2 ;;
      flush-at-ready) val=3 ;;
      flush-after-minutes) val=20 ;;
      live-quiet-minutes) val=20 ;;
      live-cap-minutes) val=60 ;;
      pr-page-minutes) val=60 ;;
      release-after-commits) val=10 ;;
      no-green-alarm-minutes) val=15 ;;
      conflict-resolver) val='' ;;
      conflict-limit-seconds) val=600 ;;
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

# The trunk branch a project is on now, printed only when the project is registered local-trunk (data/projects.md)
# and its trunk exists (state/trunk-tip-<project>, written by `jg-trunk.sh init`); exit 1 with nothing otherwise.
# A lane starts on it (bin/jg-spawn.sh), and it is the one head the release pull request into the default branch has
# (bin/jg-version-branch-lib.sh jg_is_release_head). Usage: jg_project_trunk_branch <project-dir> [<state-dir>]
jg_project_trunk_branch() {
  # shellcheck source=bin/jg-delivery-style.sh
  command -v jg_delivery_style_is >/dev/null 2>&1 || . "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/jg-delivery-style.sh"
  local pn state mode
  [ -n "${1:-}" ] || return 1
  pn=$(basename "$1"); state=${2:-${JG_STATE_OVERRIDE:-${JG_HOME:-.}/state}}
  mode=$("$(cd "${BASH_SOURCE[0]%/*}" && pwd)/jg-project-mode.sh" --raw "$pn" 2>/dev/null | cut -d' ' -f1) || return 1
  jg_delivery_style_is "$mode" trunk && [ -e "$state/trunk-tip-$pn" ] || return 1
  jg_trunk_branch "$pn" "$state"
}

# The owner rule that waives one captain word for a project (config/trunk-live-waiver for going live, config/trunk-release-waiver
# for merging a green release pull request), printed from the project's last line, or nothing when it has none. Both files hold one
# line per project, `<project> <owner-rule-id> <epoch> until=stable`, written only by `jg-trunk.sh waiver`; deleting the line
# restores the word. Usage: jg_trunk_waiver_rule <waiver-file> <project>
jg_trunk_waiver_rule() {
  awk -v p="$2" '$1 == p { r = $2 } END { print r }' "$1" 2>/dev/null || true
}
