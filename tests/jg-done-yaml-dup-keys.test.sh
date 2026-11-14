#!/usr/bin/env bash
# Journey: .done-done.yaml holds each journey key once, and a duplicate is refused with its key named.
# A duplicate journey key makes every sealed done-done run refuse, so no lane can seal.
# a) the shipped config has no duplicate journey key;
# b) a copy with one journey entry added a second time is refused, and the output names that key and both lines.
# Reads the shipped config, the file done-done itself reads.
# Usage: tests/jg-done-yaml-dup-keys.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/done-yaml-dup-keys.log}
fails=0
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }

# dups <file>: print "<key> lines <a> and <b>" for each journey key that appears again.
dups() {
  awk '
    /^journeys:/ {inj=1; next}
    /^[^ #]/ {inj=0}
    inj && /^  [^ #][^:]*:[ ]*$/ {
      k=$0; sub(/^  /,"",k); sub(/:[ ]*$/,"",k)
      if (k in first) print k " lines " first[k] " and " NR; else first[k]=NR
    }' "$1"
}

got=$(dups "$ROOT/.done-done.yaml")
if [ -z "$got" ]; then say "ok: shipped .done-done.yaml has no duplicate journey key"
else say "FAIL: duplicate journey keys in .done-done.yaml:"; say "$got"; fails=$((fails + 1)); fi

d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
# Plant the entry this test owns a second time, right under journeys:, so the copy always has the duplicate inside the section.
awk '{print} /^journeys:/ {print "  done-yaml-dup-keys:\n    tier: local\n    command: bash journeys/done-yaml-dup-keys.sh"}' \
  "$ROOT/.done-done.yaml" > "$d/dup.yaml"
got=$(dups "$d/dup.yaml")
case $got in
  "done-yaml-dup-keys lines "*) say "ok: a planted duplicate is refused with its key named: $got" ;;
  *) say "FAIL: planted duplicate not named (got: ${got:-nothing})"; fails=$((fails + 1)) ;;
esac
[ "$fails" -eq 0 ]
