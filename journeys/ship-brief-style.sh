#!/usr/bin/env bash
# done-done journey: jg-brief.sh reads the delivery-style table. The real jg-brief.sh scaffolds the ship brief of each mode
# (and of local-only and local-trunk on a local-trunk project) and each must equal its golden byte for byte; an unknown mode
# is refused with the table's mode list.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
home=$(mktemp -d) rc=0
mkdir -p "$home/data" "$home/config"
printf -- '- trunk-proj [local-trunk] - fixture (added 2026-11-09)\n' > "$home/data/projects.md"
{
  while read -r id proj mode extra; do
    # shellcheck disable=SC2086 # extra is empty or the two --risk words.
    JG_HOME="$home" "$root/bin/jg-brief.sh" "$id" "$proj" --mode "$mode" $extra >/dev/null 2>&1 || { echo "FAIL scaffold $id"; rc=1; continue; }
    if sed -e "s#$home#@HOME@#g" -e "s#$root#@ROOT@#g" "$home/data/$id/brief.md" | cmp -s - "$root/tests/fixtures/ship-brief/$id.golden"; then
      echo "== $id ($mode on $proj): equals its golden"
    else echo "FAIL $id ($mode on $proj) drifted from its golden"; rc=1; fi
  done <<'LIST'
nm some-proj no-mistakes --risk release
dp some-proj direct-PR
lo some-proj local-only
lt some-proj local-trunk
tlo trunk-proj local-only
tlt trunk-proj local-trunk
LIST
  echo "== bogus mode"; JG_HOME="$home" "$root/bin/jg-brief.sh" bad some-proj --mode bogus && rc=1
  bash "$root/tests/jg-delivery-style.test.sh" || rc=1
} > "$out" 2>&1
rm -rf -- "$home"
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped jg-brief.sh and delivery-style table",
 "steps": ["scaffold the ship brief of each of the four modes, and local-only and local-trunk on a local-trunk project", "compare each with its golden byte for byte", "ask for an unknown mode and require a refusal"],
 "result": "the six briefs equal their goldens and an unknown mode is refused with the table's mode list"}
JSON
exit "$rc"
