#!/usr/bin/env bash
# One red core-suites run must list every failing suite, not only the first, so every test step
# after the install steps runs unless the run is cancelled.
# Refuses a step in .github/workflows/core-suites.yml that lacks `if: ${{ !cancelled() }}`.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="${CORE_SUITES_WORKFLOW:-$ROOT/.github/workflows/core-suites.yml}"
[ -f "$WORKFLOW" ] || fail "workflow not found: $WORKFLOW"

# Walk the job's steps: a step starts at a six-space dash. Steps before the last install step are setup
# and stop the run on failure; every later step must carry the condition.
RESULT=$(awk '
  function flush() {
    if (name != "" && started && !cond) { print "missing: " name; bad++ }
    if (name != "" && started) checked++
  }
  /^      - / {
    flush()
    name = $0; sub(/^      - (name: )?/, "", name)
    cond = 0
    if (name ~ /Install the backlog/) started_next = 1
    else if (started_next) started = 1
    next
  }
  /^        if: \$\{\{ !cancelled\(\) \}\}[[:space:]]*$/ { cond = 1 }
  END { flush(); printf "checked %d\nbad %d\n", checked, bad }
' "$WORKFLOW")

CHECKED=$(printf '%s\n' "$RESULT" | sed -n 's/^checked //p')
[ "${CHECKED:-0}" -gt 0 ] || fail "no test step found after the install steps: $RESULT"
case "$RESULT" in
  *"bad 0"*) ;;
  *) fail "core-suites steps that stop a red run at its first failure: $RESULT" ;;
esac
pass "core-suites: $CHECKED steps run unless cancelled"
