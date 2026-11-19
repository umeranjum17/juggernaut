#!/usr/bin/env bash
# bin/jg-tier-run.sh over the shipped .done-done.yaml: each tier it is asked for (ci, local) runs exactly the journeys the
# config marks with that tier, one `done-done run <journey> --tier <tier>` each, and a tier with no journey is refused.
# A recording stand-in takes the place of done-done, so no journey is run.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(jg_test_tmproot jg-done-done-tiers)
mkdir -p "$T/bin"
# shellcheck disable=SC2016 # the stub's own $2 and $4 are expanded when it runs
printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$2" "$4" >> "%s/runs"\n' "$T" > "$T/bin/done-done"
chmod +x "$T/bin/done-done"

for tier in ci local; do
  : > "$T/runs"
  want=$(awk -v want="$tier" '/^journeys:/ {inj=1; next} /^[^ #]/ {inj=0} inj && /^  [A-Za-z0-9_-]+:$/ {name=$1; sub(/:$/, "", name)} inj && /^    tier: / && $2 == want {print name}' "$ROOT/.done-done.yaml")
  [ -n "$want" ] || fail "the shipped config marks no journey with tier $tier"
  PATH="$T/bin:$PATH" bash "$ROOT/bin/jg-tier-run.sh" "$tier" > "$T/out" 2>&1 || fail "the tier $tier run was refused: $(tail -3 "$T/out")"
  assert_equals "$(awk -v t="$tier" '{ print $0 " " t }' <<< "$want")" "$(cat "$T/runs")" "tier $tier must run each journey the config marks with it, in order"
  pass "tier $tier runs exactly the journeys the shipped config marks with it"
done

printf 'journeys:\n  only-local:\n    tier: local\n' > "$T/small.yaml"
JG_TIER_CONFIG="$T/small.yaml" PATH="$T/bin:$PATH" bash "$ROOT/bin/jg-tier-run.sh" ci > "$T/out" 2>&1 && fail "a tier with no journey must be refused"
assert_contains "$(cat "$T/out")" "no journey with tier ci" "the refusal names the empty tier"
pass "a tier with no journey is refused"
