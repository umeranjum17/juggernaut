#!/usr/bin/env bash
# E2E: the owner rules checked when a lane's brief is written (jg_owner_rules_check), driven through the real lib on a
# fixture backlog with one item per decision branch. brief-rules-cases.jsonl holds, per item, the exit status, the
# message and the brief body the check gave when its rules were shell code; they now live in
# policy/gate/brief_rules.rego and this test holds them to those recorded decisions.
# Usage: tests/brief-rules-cases.test.sh           check every item against its recorded decision
#        RECORD=1 tests/brief-rules-cases.test.sh   re-record the decisions (only after a deliberate rule change)
# Needs opa and go (the guard host evaluates the policy); with either absent the test skips.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
CASES=$here/brief-rules-cases.jsonl
# shellcheck source=lib/policy-test-env.sh
[ -n "${RECORD:-}" ] || . "$ROOT/core/lib/policy-test-env.sh"
d=$(mktemp -d "${TMPDIR:-/tmp}/brief-rules.XXXXXX") || exit 1
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home JG_CORE_DIR=$ROOT/core
mkdir -p "$HOME" "$d/data"
cat > "$d/data/backlog.md" <<'BL'
# Backlog

## In flight
- [ ] ask-plain - [captain-ask] Fix a thing (repo: sample) (kind: ship)
- [ ] main-order - Fix a thing for @O@1234 (repo: sample) (kind: ship)
  parent: ask-plain
- [ ] main-order-body - Fix a thing (repo: sample) (kind: ship)
  Serves @O@77 today.
  parent: ask-plain
- [ ] main-glued - Fix a thing (repo: sample) (kind: ship)
  Serves x@O@77 today.
  parent: ask-plain
- [ ] no-ask - Fix a thing (repo: sample) (kind: ship)
  parent: ask-plain
- [ ] no-ask-main-word - Fix a thing (repo: sample) (kind: ship)
  @O@line cleanup.
  parent: ask-plain
- [ ] no-parent - Fix a thing for @O@5 (repo: sample) (kind: ship)
- [ ] parent-missing - Fix a thing for @O@5 (repo: sample) (kind: ship)
  parent: nope
- [ ] parent-upkeep - Fix a thing for @O@5 (repo: sample) (kind: ship)
  parent: upkeep
- [ ] parent-padded - Fix a thing for @O@5 (repo: sample) (kind: ship)
    parent:   ask-plain  
- [ ] parent-done - Fix a thing for @O@5 (repo: sample) (kind: ship)
  parent: finished
- [x] finished - [captain-ask] Done earlier (repo: sample) (kind: ship)
- [ ] parent-prefix - Fix a thing for @O@5 (repo: sample) (kind: ship)
  parent: ask
- [ ] design-req - [captain-ask] Rebuild the dashboard (repo: sample) (kind: ship)
  design: required
- [ ] design-none - [captain-ask] Fix a spacing bug (repo: sample) (kind: ship)
  design: none
- [ ] design-absent - [captain-ask] Bump a dependency (repo: sample) (kind: ship)
- [ ] design-typo - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  desing: required
- [ ] design-typo2 - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  desgin: none
- [ ] design-plural - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  designs: required
- [ ] design-discovery - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  design discovery: required
- [ ] design-vague - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  design: maybe
- [ ] design-caps - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  Design: required
- [ ] design-trailing - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  design: required   
- [ ] design-twice - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  design: required
  design: none
- [ ] design-twice-same - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  design: none
  design: none
- [ ] nudge-title - [captain-ask] Redesign the landing page (repo: sample) (kind: ship)
- [ ] nudge-body - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  Needs a new screen for settings.
- [ ] nudge-mockup - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  A Mock-Up is wanted.
- [ ] nudge-word - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  Prototyping is fine, a prototype is not the plan.
- [ ] nudge-not-word - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  Prototypes and mockups are discussed elsewhere.
- [ ] flagged-words - [captain-ask] Redesign the landing page (repo: sample) (kind: ship)
  design: none
- [ ] req-with-nudge - [captain-ask] Redesign the landing page (repo: sample) (kind: ship)
  design: required
- [ ] no-ask-bad-design - Fix a thing (repo: sample) (kind: ship)
  desing: maybe

## Later
- [ ] later-item - [captain-ask] After the heading (repo: sample) (kind: ship)
BL
# The order name is spelled out here so no fixture line reads as a real owner reference.
sed -i 's/@O@/Main/g' "$d/data/backlog.md"
run_case() { # <id> <kind> <include>
  local out
  out=$(
    BRIEF_INCLUDE_BODY=$3
    # shellcheck disable=SC1091
    . "$ROOT/core/owner-rules/bin/jg-owner-rules-lib.sh"
    rc=0
    trap 'rc=$?; printf "err=%s\nbody=%s\nrc=%s\n" "$(cat "$d/err")" "$BRIEF_INCLUDE_BODY" "$rc"' EXIT
    jg_owner_rules_check "$d/data" "$1" direct-PR "$2" 2>"$d/err"
  )
  jq -cn --arg id "$1" --arg kind "$2" --arg include "$3" --arg out "$out" '{id: $id, kind: $kind, include: $include, out: $out}'
}
got=$d/got.jsonl
ids=$(sed -n 's/^- \[.\] \([^ ]*\) - .*/\1/p' "$d/data/backlog.md")
for id in $ids absent-item; do for kind in ship scout; do run_case "$id" "$kind" ''; done; done > "$got"
run_case design-req ship 'Earlier include' >> "$got"
run_case design-none ship 'Earlier include' >> "$got"
run_case no-ask squad_lead '' >> "$got"
if [ -n "${RECORD:-}" ]; then cp "$got" "$CASES"; printf 'recorded %s cases\n' "$(wc -l < "$got")"; exit 0; fi
n=$(wc -l < "$CASES") fails=0
[ "$n" -gt 0 ] && [ "$(wc -l < "$got")" -eq "$n" ] || { echo "FAIL: case count differs from the recording"; exit 1; }
while IFS= read -r line; do printf 'FAIL: %s\n' "$line"; fails=$((fails + 1)); done < <(diff "$CASES" "$got" | grep '^[<>]')
[ "$fails" -eq 0 ] && printf 'PASS: %s brief-rule cases match their recorded decisions\n' "$n" && exit 0
printf 'FAIL: %s differing lines against %s recorded cases\n' "$fails" "$n"
exit 1
