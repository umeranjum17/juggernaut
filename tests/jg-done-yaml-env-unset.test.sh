#!/usr/bin/env bash
# Journey: a journey whose command clears an env var runs, because done-done's preflight reads that command.
# done-done 0.6.34 reads the word after `env -u` as the command to run, finds no `JG_TASK_ID` program and
# refuses the journey ("command not found: JG_TASK_ID in <journey>: nothing ran"), so nothing ran.
# `env --unset=NAME` reads right. This test runs every shipped journey whose command starts an `env` through
# done-done's own run, in a scratch repo holding the shipped config and a stand-in `bash` that exits 0,
# and fails when done-done refuses any of them as a command not found.
# Usage: tests/jg-done-yaml-env-unset.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/done-yaml-env-unset.log}
CFG=${JG_DONE_YAML:-$ROOT/.done-done.yaml}
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }

# env_journeys <file>: the journey key of each journey whose command runs `env `.
env_journeys() {
  awk '
    /^journeys:/ {inj=1; next}
    /^[^ #]/ {inj=0}
    inj && /^  [^ #][^:]*:[ ]*$/ {k=$0; sub(/^  /,"",k); sub(/:[ ]*$/,"",k)}
    inj && /^    command: (.*[ (])?env / {print k}' "$1"
}

d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir "$d/repo" "$d/bin"
printf '#!/bin/sh\nexit 0\n' > "$d/bin/bash"
chmod +x "$d/bin/bash"
cp "$CFG" "$d/repo/.done-done.yaml"
git -C "$d/repo" init -q .
git -C "$d/repo" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m seed

names=$(env_journeys "$CFG")
[ -n "$names" ] || { say "FAIL: no journey with an env command found in $CFG"; exit 1; }
fails=0
for n in $names; do
  out=$(cd "$d/repo" && PATH="$d/bin:$PATH" done-done run "$n" 2>&1 || true)
  case $out in
    *"command not found"*) say "FAIL: $n: done-done refused the command: $(printf '%s' "$out" | grep -m1 'command not found')"; fails=$((fails + 1)) ;;
    *) say "ok: $n: done-done's preflight accepts its command" ;;
  esac
done
[ "$fails" -eq 0 ]
