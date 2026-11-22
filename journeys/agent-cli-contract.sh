#!/usr/bin/env bash
# Drive the public CLI and the inventory's real script parsers in isolated homes.
# With a trunk ref, require the named test for every changed e6 fragment or test.
set -euo pipefail

suites=(inventory forms contract e6land2 e6homes e6steer e6radio3)
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
  core/agent-cli/tests/forms.test.sh core/agent-cli/tests/inventory.test.sh journeys/agent-cli-contract.sh > "$DONE_DONE_EVIDENCE_ROOT/lint.log" 2>&1 \
  || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/lint.log" >&2; exit 1; }
for suite in "${suites[@]}"; do
  log="$DONE_DONE_EVIDENCE_ROOT/$suite.log"
  test_file="core/agent-cli/tests/$suite.test.sh"
  {
    printf 'Running %s\n' "$test_file"
    bash "$test_file" && printf 'PASS %s\n' "$test_file"
  } > "$log" 2>&1 || { tail -n 25 "$log" >&2; exit 1; }
done
# Check that harness instructions use registered commands, except named script internals.
python3 - > "$DONE_DONE_EVIDENCE_ROOT/harness-instruction-contract.log" 2>&1 <<'PYTEST'
import glob
import json
import pathlib
import re

paths = [pathlib.Path('.agents/skills/harness-adapters/SKILL.md')]
paths += [pathlib.Path('.agents/skills/harness-adapters/references/common') / (name + '.md')
          for name in ('control-and-recovery', 'dispatch', 'model-and-effort', 'primary-hooks')]
entries = [entry for name in glob.glob('core/agent-cli/contract/*.json')
           for entry in json.loads(pathlib.Path(name).read_text())['entries']]
scripts = {pathlib.Path(entry['script']).name for entry in entries}
commands = {tuple(entry['path']) for entry in entries}
found = 0
for path in paths:
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if 'script:' not in line:
            for script in scripts:
                if re.search(r'(?<![\w-])' + re.escape(script) + r'(?![\w.-])', line):
                    raise SystemExit(f'{path}:{number}: contract script lacks script: prefix: {script}')
        for command in re.findall(r'`(jg [^`]*)`', line):
            words = command.split()[1:]
            if not any(tuple(words[:len(candidate)]) == candidate for candidate in commands):
                raise SystemExit(f'{path}:{number}: unregistered command: {command}')
            found += 1
if not found:
    raise SystemExit('no harness instruction commands found')
print(f'PASS harness-instruction-contract: {found} registered command references; no unmarked contract scripts')
PYTEST
if [ "$#" -gt 0 ]; then
  bash bin/jg-test-run.sh --changed --base "$1" --json "$DONE_DONE_EVIDENCE_ROOT/changed-tests.json" \
    > "$DONE_DONE_EVIDENCE_ROOT/changed-tests.log" 2>&1 \
    || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/changed-tests.log" >&2; exit 1; }
fi
