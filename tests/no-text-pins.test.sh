#!/usr/bin/env bash
# Refuses a test that greps the repository's own source or documents for a fixed phrase.
# Such a line fails when wording changes and passes when behaviour breaks; run the program and
# check its output instead. A line that reads source as data and asserts no phrase ends with
# `# pins-ok: <reason>`. Prints each offending file:line.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF=tests/no-text-pins.test.sh
P='\$\{?(ROOT|JG_ROOT|REPO)\}?/(bin|core|docs|\.agents|AGENTS\.md)'

hits=$(cd "$ROOT" && git ls-files '*.test.sh' | grep -vFx "$SELF" | while read -r f; do
  # a grep (not assert_grep) with the repository path as its own quoted word, or assert_grep with it as the file argument
  grep -nE "(^|[^_[:alnum:]])grep[^|;&]*[[:space:]]\"$P|assert_grep \"[^\"]*\" \"$P" "$f" | grep -v '# pins-ok: ' | sed "s|^|$f:|"
done)

if [ -n "$hits" ]; then
  echo "FAIL: tests grep repository source or documents for a phrase (run the program and check its output):"
  printf '%s\n' "$hits" | sed 's/^\([^:]*:[0-9]*\):.*/  \1/'
  exit 1
fi
echo "PASS: no test greps repository source or documents for a phrase"
