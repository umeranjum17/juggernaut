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
found=0
for f in ./*.sh ./*/* ./*/*/*; do
  [ -f "$f" ] || continue
  head -n 1 "$f" | grep -Eq '^#!.*\b(bash|sh)\b' || continue
  found=$((found + 1))
  exclude=SC2015
  case "$f" in
    ./sentinel/*|./supervisor-guard/*|./wait-timers/bin/*|./signoff/bin/*|./host-memory/bin/*|./alerts/*|./receipts/bin/*|./fleet-stats/bin/*) exclude=SC2015,SC1091 ;;
    ./wait-timers/tests/jg-wait-timers.test.sh) exclude=SC2015,SC1091,SC2034 ;;
  esac
  echo "== shellcheck -x -e $exclude $f =="
  shellcheck -x -e "$exclude" "$f"
done
if [ "$found" -eq 0 ]; then
  echo "no core feature script found in any core/<feature>/ directory" >&2
  exit 1
fi
