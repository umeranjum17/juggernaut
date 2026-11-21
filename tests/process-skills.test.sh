#!/usr/bin/env bash
# Checks the strike-recon and op-order skills, their trigger-index lines, the deep-recon pointer and the war-room modes.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
fail=0
ok() { echo "ok $1"; }
bad() { echo "not ok $1"; fail=1; }
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

index="$root/.agents/skills/agent-skill-trigger-index/SKILL.md"
deep="$root/.agents/skills/deep-recon/SKILL.md"

for s in strike-recon op-order; do
  f="$root/.agents/skills/$s/SKILL.md"
  check "$s: file exists" test -f "$f"
  [ -f "$f" ] || continue
  check "$s: name equals folder" grep -qx "name: $s" "$f"
  desc=$(sed -n '/^description:/{s/^description: *//;p;q}' "$f")
  check "$s: description starts with Load" test "${desc:0:4}" = "Load"
  check "$s: description at most 200 characters" test "${#desc}" -le 200
  check "$s: user-invocable false" grep -qx 'user-invocable: false' "$f"
  check "$s: listed once in trigger index" test "$(grep -c "^- \`$s\` - " "$index")" -eq 1
done
check "deep-recon names strike-recon once" test "$(grep -c "\`strike-recon\`" "$deep")" -eq 1
war="$root/.agents/skills/war-room/SKILL.md"
what=$(sed -n '/^## What it does/,/^## Intake/p' "$war")
for mode in fast full lite; do
  check "war-room: What it does names $mode" grep -q "/war-room $mode <problem>" <<< "$what"
done
check "war-room: What it does says fast runs when no word is given" grep -q '/war-room <problem>. with no word runs .fast.' <<< "$what"
exit "$fail"
