#!/usr/bin/env bash
# The role-scoped instruction surface: the shipped map covers every AGENTS.md section
# and skill once, a builder and a scout read fewer bytes than the whole surface, and
# check refuses a map that drops a section, names one twice, or names an unknown role.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK=$(jg_test_tmproot jg-worker-rules)
tool="$ROOT/bin/jg-worker-rules.sh"

"$tool" check | grep -q '^ok: roles' || fail "the shipped map must cover the surface"
pass "the shipped map's union is the whole surface"

whole=$(( $(wc -c < "$ROOT/AGENTS.md") ))
for role in builder scout reviewer; do
  got=$("$tool" render "$role" | wc -c)
  [ "$got" -gt 0 ] && [ "$got" -lt "$whole" ] || fail "$role block is $got bytes, whole AGENTS.md is $whole"
done
"$tool" render builder | grep -q 'juggernaut-coding-guidelines' || fail "builder must read the coding guidelines"
! "$tool" render builder | grep -q 'Never merge a PR without' || fail "builder must not read the supervisor rules"
"$tool" render overwatch | grep -q 'Never merge a PR without' || fail "overwatch must read the supervisor rules"
pass "workers read their parts and not the supervisor contract"

echo "recorded brief" > "$WORK/brief.md"
"$tool" measure builder "$WORK/brief.md" | grep -q '^block after' || fail "measure must print the after count"
pass "measure prints before and after"

mapfile=$WORK/map.tsv
bad() { JG_WORKER_RULES_MAP=$mapfile "$tool" check >"$WORK/out" 2>&1 && fail "$1: check passed"; grep -q "$2" "$WORK/out" || fail "$1: wanted '$2', got $(cat "$WORK/out")"; }
grep -v '^agents:14' "$ROOT/defaults/worker-rules.tsv" > "$mapfile"
bad "dropped section" 'no role reads: agents:14. Relay'
{ cat "$ROOT/defaults/worker-rules.tsv"; printf 'skill:prior-art\tscout\n'; } > "$mapfile"
bad "skill named twice" 'named twice: skill:prior-art'
sed 's/^agents-preamble\tall/agents-preamble\tcaptain/' "$ROOT/defaults/worker-rules.tsv" > "$mapfile"
bad "unknown role" "unknown role 'captain'"
pass "check refuses a lost, doubled, or misnamed part"
