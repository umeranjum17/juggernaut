#!/usr/bin/env bash
# Behavior test for bin/jg-load-journey.sh, driven through the real command: lab homes run at the same time, each
# fault is injected and recovered by its real owner script, and the run fails when a recovery is late, repeats an
# alarm or spends model tokens. The two shipped faults run in two homes; three fixture faults cover the failures.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JL="$ROOT/bin/jg-load-journey.sh"
T=$(cd "$(jg_test_tmproot jg-load-journey)" && pwd)

# The shipped faults, in two homes with four lanes.
OUT=$T/real
bash "$JL" run --homes 2 --lanes 4 --out "$OUT" >"$T/real.out" 2>&1 || { cat "$T/real.out" >&2; fail "the shipped faults did not all recover"; }
assert_equals 4 "$(wc -l < "$OUT/faults.jsonl")" "one result per fault and home"
assert_equals 0 "$(jq -s '[.[]|select(.recovered==false or .repeat==true or .tokens>0)]|length' "$OUT/faults.jsonl")" "every fault recovered once, with no model turn"
assert_equals "dropped-steer locked-store" "$(jq -rs '[.[].fault]|unique|join(" ")' "$OUT/faults.jsonl")" "both shipped faults ran"
jq -es 'all(.[]; (.recovery_ms|type)=="number")' "$OUT/faults.jsonl" >/dev/null || fail "each result carries its recovery time"
pass "two homes at once recover both shipped faults, timed, with no repeat and no tokens"

# Fixture faults: one never recovers, one rings again on every recovery, one spends tokens.
FX=$T/faults; mkdir -p "$FX"
cat > "$FX/never.sh" <<'EOT'
fault_inject() { :; }
fault_recover() { :; }
fault_recovered() { return 1; }
EOT
cat > "$FX/rings.sh" <<'EOT'
fault_inject() { :; }
fault_recover() { mkdir -p "$1/state/alerts"; date +%s%N >> "$1/state/.wake-queue"; }
fault_recovered() { return 0; }
EOT
cat > "$FX/spends.sh" <<'EOT'
fault_inject() { :; }
fault_recover() { :; }
fault_recovered() { return 0; }
fault_tokens() { echo 1200; }
EOT
for f in never rings spends; do
  JG_LOAD_JOURNEY_FAULTS=$FX bash "$JL" run --homes 1 --lanes 1 --faults "$f" --deadline 1 --out "$T/$f" >"$T/$f.out" 2>&1 && fail "the $f fault passed the run"
done
assert_equals false "$(jq -r .recovered "$T/never/faults.jsonl")" "a late recovery is reported unrecovered"
assert_equals true "$(jq -r .repeat "$T/rings/faults.jsonl")" "a second alarm on a known state is reported"
assert_equals 1200 "$(jq -r .tokens "$T/spends/faults.jsonl")" "token cost is recorded and fails the run"
pass "a late recovery, a repeated alarm and a token spend each fail the run and name the fault"

bash "$JL" run --homes 1 --lanes 1 --faults nosuch >"$T/bad.out" 2>&1; assert_equals 2 "$?" "an unknown fault is refused"
bash "$JL" run --homes 3 --lanes 2 >"$T/bad.out" 2>&1; assert_equals 2 "$?" "fewer lanes than homes is refused"
pass "bad arguments are refused before any lab home is made"
