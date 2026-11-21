#!/usr/bin/env bash
# Drive the public CLI and the inventory's real script parsers in isolated homes.
# With a trunk ref, require the named test for every changed e6 fragment or test.
set -euo pipefail

suites=(inventory forms contract e6land2 e6homes)
if [ "$#" -gt 0 ]; then
  base=$(git merge-base "$1" HEAD)
  changed=$(git diff --name-only --no-renames "$base" -- \
    ':(glob)core/agent-cli/contract/e6*.json' ':(glob)core/agent-cli/tests/e6*.test.sh')
  while IFS= read -r path; do
    case "$path" in
      '') continue ;;
      core/agent-cli/contract/*) suite=${path##*/}; suite=${suite%.json} ;;
      core/agent-cli/tests/*) suite=${path##*/}; suite=${suite%.test.sh} ;;
      *) printf 'Cannot map e6 path %s to its test\n' "$path" >&2; exit 1 ;;
    esac
    test_file="core/agent-cli/tests/$suite.test.sh"
    # contract.test.sh covers the shipped, partial e6steer fragment. A change to
    # that slice must supply its own test, just like any other changed e6 slice.
    if [ ! -f "$test_file" ] || [ ! -s "$test_file" ]; then
      printf 'Missing required e6 test %s for %s\n' "$test_file" "$path" >&2
      exit 1
    fi
    case " ${suites[*]} " in
      *" $suite "*) ;;
      *) suites+=("$suite") ;;
    esac
  done <<< "$changed"
fi

bash bin/jg-lint.sh bin/jg bin/jg-alert.sh bin/jg-board-gate.sh bin/jg-crew-state.sh bin/jg-migrate.sh \
  core/agent-cli/dispatch.sh core/agent-cli/tests/contract.test.sh \
  core/agent-cli/tests/forms.test.sh journeys/agent-cli-contract.sh > "$DONE_DONE_EVIDENCE_ROOT/lint.log" 2>&1 \
  || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/lint.log" >&2; exit 1; }
for suite in "${suites[@]}"; do
  log="$DONE_DONE_EVIDENCE_ROOT/$suite.log"
  test_file="core/agent-cli/tests/$suite.test.sh"
  {
    printf 'Running %s\n' "$test_file"
    bash "$test_file" && printf 'PASS %s\n' "$test_file"
  } > "$log" 2>&1 || { tail -n 25 "$log" >&2; exit 1; }
done
if [ "$#" -gt 0 ]; then
  bash bin/jg-test-run.sh --changed --base "$1" --json "$DONE_DONE_EVIDENCE_ROOT/changed-tests.json" \
    > "$DONE_DONE_EVIDENCE_ROOT/changed-tests.log" 2>&1 \
    || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/changed-tests.log" >&2; exit 1; }
fi
