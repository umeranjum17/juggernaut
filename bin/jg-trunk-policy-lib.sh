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
#   protected-landing     refuse      refuse: a commit touching protected-paths keeps the
#                                     pull request path; gate: it may land after the full gate
#   protected-paths       (gate machinery, below) space-separated globs
#   gate-mode             full        full: the lander runs gate-full before landing
#                                     smoke: it runs gate-smoke and the full suite runs in
#                                     `verify`; the home never moves past the last full pass
#   gate-full             the CI invariants that need no network (no tracked personal paths, no
#                         committed binaries, regression coverage), lint, then the whole suite
#   gate-smoke            (none)      smoke is refused until a command is chosen
#   owner-rules           keep        keep: every owner rule gate in config/merge-gate still
#                                     runs; any other value is refused as not decided
#   release-after-hours   48          age of the oldest unreleased commit that makes a release due
_JG_TRUNK_PROTECTED='bin/jg-merge-* bin/jg-pr-merge.sh bin/jg-trunk* bin/jg-dod-lib.sh bin/jg-captain-hold.sh bin/jg-test-run.sh bin/jg-lint.sh bin/jg-ci-* bin/jg-update.sh bin/jg-ff-lib.sh bin/jg-stack.sh core/merge-on-green/* core/merge-card/* core/owner-guard/* core/owner-rules/* core/receipts/* core/teardown/* core/delete-guard/* core/kill-guard/* policy/gate/* .github/workflows/*'

_JG_TRUNK_GATE_FULL='test -z "$(git ls-files -- data state config projects .no-mistakes)" && bin/jg-committed-binary-check.sh && bin/jg-test-run.sh --check-coverage && bin/jg-lint.sh && bin/jg-test-run.sh --all'

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
      gate-mode) val=full ;;
      gate-full) val=$_JG_TRUNK_GATE_FULL ;;
      gate-smoke) val= ;;
      owner-rules) val=keep ;;
      release-after-hours) val=48 ;;
      *) return 1 ;;
    esac
  fi
  printf '%s\n' "$val"
}
