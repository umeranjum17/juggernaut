#!/usr/bin/env bash
# ShellCheck over every core feature script, run from core/. A feature script is a shell script under a
# core/<feature>/ directory, one level down (`merge-card/merge-card`) or two levels down in its `bin/` and
# `tests/` subdirectories, so a new feature in either shape needs no edit here and a non-script file is left alone.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../core"
shellcheck --version
# SC2015 is excluded because both shared hook chains use the deliberate `A && B || fallback` idiom where the
# fallback is the intent: ask-default's incomplete-record check and merge-card's usage guard and media cap.
# A verbatim dormant copy from the fork carries `# shellcheck source=bin/...` or `source=tests/...` directives
# naming sibling fork libraries that did not move into this repository. With -x ShellCheck cannot open them, so
# it reports SC1091 for each missing source and, when only the unfollowed library reads a variable, a follow-on
# SC2034. The copies are byte-identical to the fork and may not be edited, so exactly those two codes are
# exempt for those files. Every other check stays on at every severity.
# The same SC1091 also fires for every in-repo `# shellcheck source=bin/...` or `source=core/...` directive, because
# those paths are relative to the repository root and ShellCheck 0.11 resolves them from this core/ directory; the
# libraries are real and are checked as scripts of their own, so SC1091 is exempt for all files, not only the copies.
found=0
for f in ./*.sh ./*/* ./*/*/*; do
  [ -f "$f" ] || continue
  head -n 1 "$f" | grep -Eq '^#!.*\b(bash|sh)\b' || continue
  found=$((found + 1))
  exclude=SC2015,SC1091
  case "$f" in
    ./wait-timers/tests/jg-wait-timers.test.sh) exclude=SC2015,SC1091,SC2034 ;;
    # ShellCheck 0.11 adds these notes for two verbatim fork copies: functions stubbed for the code under test and
    # called only from the sourced library, and a loop variable named like an uppercase global.
    ./alerts/tests/model-outage-hook-e2e.sh) exclude=SC2015,SC1091,SC2030,SC2329 ;;
    ./wait-timers/bin/jg-stops-lib.sh) exclude=SC2015,SC1091,SC2153 ;;
  esac
  echo "== shellcheck -x -e $exclude $f =="
  shellcheck -x -e "$exclude" "$f"
done
if [ "$found" -eq 0 ]; then
  echo "no core feature script found in any core/<feature>/ directory" >&2
  exit 1
fi
