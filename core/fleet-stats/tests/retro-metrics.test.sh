#!/usr/bin/env bash
# Integration: run the real retro-metrics CLI over a fixture home and check the one first-pass
# definition, the window split, and that a retro's stored index line is read back, not recomputed.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/bin/jg-retro-metrics.sh"
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/home/data/metrics"
M="$d/home/data/metrics"
# Window with --now 2026-11-04 12:00Z and --days 2: 11-03..11-04 beside 11-01..11-02.
# In-window non-bot PRs: 1 (first pass), 2 (rework), 3 (escaped, so not first pass), plus bot PR 4.
# Prior non-bot PRs: 5 (first pass), 6 (reverted, so not first pass).
{
  printf 'home\trepo\tpr\tcreated\tmerged\thours_to_merge\tbuild_hours\tcommits\tcommits_after_open\trework_ci\trework_pipeline\trework_other\treverted\tescaped\tfirst_pass\tbot\ttitle\n'
  printf 'a\tr/a\t1\t2026-11-03T01:00:00Z\t2026-11-03T02:00:00Z\t1.00\t2.00\t1\t0\t0\t0\t0\t0\t0\t1\t0\tone\n'
  printf 'a\tr/a\t2\t2026-11-03T01:00:00Z\t2026-11-03T05:00:00Z\t4.00\t5.00\t3\t2\t1\t0\t1\t0\t0\t0\t0\ttwo\n'
  printf 'a\tr/a\t3\t2026-11-04T01:00:00Z\t2026-11-04T04:00:00Z\t3.00\t3.00\t1\t0\t0\t0\t0\t0\t1\t0\t0\tthree\n'
  printf 'b\tr/b\t4\t2026-11-04T01:00:00Z\t2026-11-04T09:00:00Z\t8.00\t8.00\t1\t0\t0\t0\t0\t0\t1\t0\t1\tbot\n'
  printf 'a\tr/a\t5\t2026-11-01T01:00:00Z\t2026-11-01T02:00:00Z\t1.00\t1.00\t1\t0\t0\t0\t0\t0\t0\t1\t0\tfive\n'
  printf 'a\tr/a\t6\t2026-11-02T01:00:00Z\t2026-11-02T03:00:00Z\t2.00\t2.00\t1\t0\t0\t0\t0\t1\t0\t0\t0\tsix\n'
} >"$M/prs.tsv"
{
  printf 'day\thome\tsteers\tuntagged\ts_correct\tdecisions\tblocks\n'
  printf '2026-11-03\ta\t4\t0\t1\t1\t1\n'
  printf '2026-11-01\ta\t9\t0\t9\t0\t0\n'
} >"$M/daily.tsv"

fail() { echo "retro-metrics test: $1" >&2; exit 1; }
field() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[k]
print(v)' "$1"; }

out=$("$CLI" compute --home "$d/home" --days 2 --now 1793793600 --retro r1)
[ "$(printf '%s' "$out" | field metrics.ALL.window.merged)" = 4 ] || fail "window merged"
[ "$(printf '%s' "$out" | field metrics.ALL.window.first_pass_n)" = 1 ] || fail "first_pass_n"
[ "$(printf '%s' "$out" | field metrics.ALL.window.first_pass_of)" = 3 ] || fail "first_pass_of excludes bots"
[ "$(printf '%s' "$out" | field metrics.ALL.window.first_pass)" = 33 ] || fail "first_pass rounds down"
[ "$(printf '%s' "$out" | field metrics.ALL.prior.first_pass)" = 50 ] || fail "prior first_pass"
[ "$(printf '%s' "$out" | field metrics.ALL.window.escaped)" = 2 ] || fail "escaped counts bot PR"
[ "$(printf '%s' "$out" | field metrics.ALL.prior.reverted)" = 1 ] || fail "prior reverted"
[ "$(printf '%s' "$out" | field metrics.ALL.window.p90_hours)" = 3.0 ] || fail "p90 hours"
[ "$(printf '%s' "$out" | field metrics.ALL.window.interventions_per_merge)" = 1.5 ] || fail "interventions per merge"
[ "$(printf '%s' "$out" | field metrics.a.window.merged)" = 3 ] || fail "per-home split"
[ "$(printf '%s' "$out" | field window.from)" = 2026-11-03 ] || fail "window start"

# The stored line is what a later retro reads, even after the source records change.
: >"$M/prs.tsv"
[ "$("$CLI" show --home "$d/home" --retro r1 | field metrics.ALL.window.first_pass_n)" = 1 ] || fail "show reads stored index"
"$CLI" compute --home "$d/home" --days 2 --now 1793793600 --retro r1 >/dev/null
[ "$(wc -l <"$M/retro-index.jsonl")" = 1 ] || fail "same retro id replaces its line"
"$CLI" compute --home "$d/home" --days 2 --now 1793793600 >/dev/null
[ "$(wc -l <"$M/retro-index.jsonl")" = 1 ] || fail "compute without --retro writes nothing"

# Refusals.
"$CLI" show --home "$d/home" --retro nope 2>/dev/null && fail "show of unknown retro must refuse"
"$CLI" compute --days 2 2>/dev/null && fail "compute without --home must refuse"
"$CLI" definitions | grep -q '^first_pass: ' || fail "definitions lists first_pass"
echo "retro-metrics test: ok"
