#!/usr/bin/env bash
# Behavior test for core/fleet-stats/bottlenecks.sh (H41): run the real script over a fixture home holding landing rows, a
# nightly file, load rows and per-script timing records; check each report part, the once-a-day record, and that a script
# over its cost budget or failing over 40 percent of at least 30 runs gets one ticket (never a second while it is open).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-ledger.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-ledger.sh"

BN="$ROOT/core/fleet-stats/bottlenecks.sh"
T=$(jg_test_tmproot jg-bottlenecks); H=$T/home; D=$H/data
mkdir -p "$D/trunk" "$D/metrics"
ledger_home "$H"
DAYS=2026-11-12; NOON=$(date -u -d "$DAYS 12:00" +%s)

# Landings in the ticket ledger: two in the day (one waited behind a lane, one at no recorded reason), one the day before (left out).
HX=$(printf 'a%.0s' {1..40})
ledger_landing "$H" lane-a "$(printf '1%.0s' {1..40})" "$HX" "$NOON" - queue 200 30 100 40.0 'behind lane-x'
ledger_landing "$H" lane-b "$(printf '2%.0s' {1..40})" "$HX" "$((NOON + 60))" - gate 0 10 300 60.0 -
ledger_landing "$H" lane-old "$(printf '3%.0s' {1..40})" "$HX" "$((NOON - 86400))" - queue 999 999 999 5.0 'behind old'
printf -- '- seconds: 2852\n' > "$D/trunk/nightly-juggernaut-$DAYS.md"
printf '%s\th\t1of8\t900000\t600000\t70.00\t32\n' "$NOON" > "$D/trunk/load-juggernaut.tsv"

# Timing records: a high-fail script (35 runs, 15 red), a red-always script under 30 runs, a slow one (4 runs of 200 s),
# a skipped run, and a fine one. One record carries every run, as a shard's json does.
python3 - "$D/trunk/required-fast.t1" <<'PY'
import json, os, sys
d = sys.argv[1]; os.makedirs(d)
def run(path, red=False, ms=1000, skip=False):
    return {"path": path, "exit": 1 if red else 0, "duration_ms": ms, "gate_skip": skip}
s = [run("tests/flaky.test.sh", red=i < 15) for i in range(35)]
s += [run("tests/few.test.sh", red=True) for _ in range(10)]
s += [run("tests/slow.test.sh", ms=200000) for _ in range(4)]
s += [run("tests/skipped.test.sh", ms=900000, skip=True) for _ in range(5)]
s += [run("tests/fine.test.sh") for _ in range(40)]
json.dump({"started_at": "2026-11-12T10:00:00Z", "finished_at": "2026-11-12T11:00:00Z", "scripts": s}, open(d + "/1.json", "w"))
PY

# The filer is the real quarantine.sh, copied beside a stub backlog because it finds its backlog from its own location.
mkdir -p "$T/fk/core/trunk-landing" "$T/fk/bin"
cp "$ROOT/core/trunk-landing/quarantine.sh" "$T/fk/core/trunk-landing/"
cat > "$T/fk/bin/jg-backlog.sh" <<'B'
#!/usr/bin/env bash
case $1 in
  show) grep -qx "$2" "$BL/ids" 2>/dev/null && { echo '  closed: "-"'; exit 0; }; exit 1 ;;
  add) echo "$2" >> "$BL/ids"; printf '%s\n' "$*" >> "$BL/adds" ;;
esac
B
chmod +x "$T/fk/bin/jg-backlog.sh"; export BL=$T JG_BOTTLENECKS_QUARANTINE=$T/fk/core/trunk-landing/quarantine.sh

run() { OUT=$(JG_HOME=$H bash "$BN" --day "$DAYS" "$@" 2>&1); RC=$?; }

run
assert_equals 0 "$RC" "a plain report succeeds"
assert_contains "$OUT" "Landing steps (2 landings)" "only the landings of the day count"
assert_contains "$OUT" "queue      n=2 median=200s p90=200s total=200s" "queue seconds per landing (the zero is no wait)"
assert_contains "$OUT" "gate       n=2 median=300s p90=300s total=400s" "gate seconds per landing"
assert_contains "$OUT" "nightly 2026-11-12: 2852s" "the verify seconds come from the nightly file"
assert_contains "$OUT" "behind lane-x: 1 landings, 200s" "queue wait is split by its recorded reason"
assert_contains "$OUT" "at landings: n=2 mean=50.0 max=60.0" "load at the landings"
assert_contains "$OUT" "at gate shards: n=1 mean=70.0 max=70.0 on 32 cpus" "load at the gate shards"
assert_contains "$OUT" "tests/flaky.test.sh: runs=35 failed=15 (43%)" "each script's runs, failures and rate"
assert_not_contains "$OUT" "skipped.test.sh: runs" "a skipped run is not a run"
assert_contains "$OUT" "tests/flaky.test.sh: failed 15 of 35 runs (43%), over 40%" "a script failing over 40% of 30 runs is flagged with its numbers"
assert_contains "$OUT" "tests/slow.test.sh: mean 200s is over the 120s budget" "a script over its cost budget is flagged"
assert_not_contains "$OUT" "tests/few.test.sh: failed" "a script under 30 runs is not flagged for failing"
assert_not_contains "$OUT" "tests/fine.test.sh: mean" "a cheap green script is not flagged"
assert_absent "$D/metrics/bottlenecks-juggernaut-$DAYS.md" "a plain report records nothing"

# The report follows the ledger: one more landing in the day changes the counts and the queue wait it names.
ledger_landing "$H" lane-c "$(printf '4%.0s' {1..40})" "$HX" "$((NOON + 120))" - queue 500 5 700 20.0 'behind lane-y'
run
assert_contains "$OUT" "Landing steps (3 landings)" "a landing added to the ledger is counted"
assert_contains "$OUT" "behind lane-y: 1 landings, 500s" "its queue wait is named by its reason"
assert_contains "$OUT" "gate       n=3 median=300s p90=700s total=1100s" "its gate seconds join the report"

run --daily --file-tickets
assert_equals 0 "$RC" "a daily report that files tickets succeeds"
assert_equals "flaky-juggernaut-flaky
flaky-juggernaut-slow" "$(sort "$T/ids")" "one ticket per flagged script and none for the others"
assert_contains "$(cat "$T/adds")" "failed 15 of 35 runs (43%)" "the ticket body carries the script's numbers"
assert_contains "$(cat "$D/metrics/bottlenecks-juggernaut-$DAYS.md")" "Scripts for a fix ticket" "the daily report is kept"
# A journey that wants to show the product's output names a file for the report and the tickets the run produced.
[ -z "${BOTTLENECKS_SHOW:-}" ] || { cat "$D/metrics/bottlenecks-juggernaut-$DAYS.md"; printf '\nFix tickets filed:\n'; cat "$T/adds"; } > "$BOTTLENECKS_SHOW"
run --daily --file-tickets; assert_equals "already reported $DAYS" "$OUT" "a second report on the same day is skipped"

rm "$D/metrics/bottlenecks-juggernaut-$DAYS.md"
run --daily --file-tickets
assert_equals 2 "$(wc -l < "$T/ids" | tr -d ' ')" "no second ticket while one is open"

run --file-tickets; assert_equals 2 "$RC" "--file-tickets without --daily is refused"
pass "bottlenecks: report parts, once-a-day record and one ticket per flagged script"
