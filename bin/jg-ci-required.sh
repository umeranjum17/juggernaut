#!/usr/bin/env bash
# jg-ci-required.sh - the single merge-gate verdict for ci.yml's `CI required`.
#
# JG_CI_NEEDS is GitHub's toJSON(needs) and JG_CI_BEHAVIOR the invariants job's
# scope verdict. A behavior change needs every lane passed; a documentation
# change needs the lanes deliberately skipped. Anything else refuses, so a path
# filter can never become a silent skip.
#
# The lanes are the thin pull request set only. The heavy behaviour suite is
# .github/workflows/behavior.yml, which is nightly and post-merge and never a
# pull request gate, so no verdict here names it.
#
#   JG_CI_NEEDS='{"invariants":{"result":"success"},...}' JG_CI_BEHAVIOR=true \
#     bin/jg-ci-required.sh
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
set -eu

JG_CI_REQUIRED_LANES='lint syntax smoke evals'

jg_ci_required_die() { printf 'error: %s\n' "$*" >&2; exit 1; }

jg_ci_required_result() {
  printf '%s' "${JG_CI_NEEDS:-}" | jq -er --arg job "$1" '.[$job].result // "missing"'
}

jg_ci_required_main() {
  local want lane result bad=''
  case ${1:-} in
    -h|--help) sed -n '2,8{s/^# \{0,1\}//;p;}' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jg-ci-required.sh"; return 0 ;;
    '') ;;
    *) jg_ci_required_die "unknown argument $1" ;;
  esac
  command -v jq >/dev/null 2>&1 || jg_ci_required_die "jq is required to read the needed-job results"
  printf '%s' "${JG_CI_NEEDS:-}" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || jg_ci_required_die "the needed-job results are not a JSON object"
  case ${JG_CI_BEHAVIOR:-} in
    true) want=success ;;
    false) want=skipped ;;
    *) jg_ci_required_die "the scope verdict is '${JG_CI_BEHAVIOR:-}', so CI cannot say which lanes this change needed" ;;
  esac
  # The scope verdict is always needed: without it no lane verdict counts.
  [ "$(jg_ci_required_result invariants)" = success ] || bad="$bad invariants=not-passed"
  # shellcheck disable=SC2086  # the lane list is a deliberate word split
  for lane in $JG_CI_REQUIRED_LANES; do
    result=$(jg_ci_required_result "$lane") || result=unreadable
    if [ "$want" = skipped ]; then
      case $result in failure|cancelled) bad="$bad $lane=$result" ;; esac
    elif [ "$result" != success ]; then
      bad="$bad $lane=$result"
    fi
  done
  [ -z "$bad" ] || jg_ci_required_die "this change is not verifiable:$bad"
  printf 'verified: every job this %s change needed ran and passed\n' \
    "$([ "$want" = success ] && printf behavior || printf documentation)"
}

jg_ci_required_main "$@"
