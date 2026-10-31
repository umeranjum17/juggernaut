#!/usr/bin/env bash
# The wake key of a waiting lane is stable identity plus a rung of a fixed ladder, never the age in the text.
# Proves: one lane waiting 80.0 h then 80.2 h rings once, and rings again only at the next named rung (128 h);
# two lanes that trade places in the text ring one wake for the pair. CHECK=<script> runs another copy of the check.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
CHECK=${CHECK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/jg-flow-check.sh}
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
main=$d/main home=$d/pool/8/juggernaut t0=1700000000 h=3600
mkdir -p "$main/bin" "$main/config" "$home/state" "$home/data"
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: want [$2] got [$3]"; fail=1; fi; }
lane() {  # <task> <seconds waiting at t0>
  printf 'kind=ship\n' > "$home/state/$1.meta"
  printf 'needs-decision [key=ask] [at=%s]: which name\n' "$((t0 - $2))" > "$home/state/$1.status"
}
poll() {  # <seconds after t0>: 1 when the check raises a wake (any line), else 0, then its derived keys on stderr
  JG_FLOW_NOW=$((t0 + $1)) JG_FLOW_KEYS=1 JG_MAIN_HOME=$main python3 "$CHECK" "$home" 2>"$d/keys" | grep -q '^flow: .* past its clock' && echo 1 || echo 0
  cat "$d/keys" >&2
}
reset() { rm -f "$home/state/.flow.last" "$home/state"/*.meta "$home/state"/*.status; }

reset; lane solo $((80 * h))
expect 'solo lane at 80.0 h rings once' 1 "$(poll 0)"
expect 'solo lane at 80.2 h rings nothing' 0 "$(poll 720)"
expect 'solo lane at 100 h (same rung) rings nothing' 0 "$(poll $((20 * h)))"
expect 'solo lane at the next rung (128 h) rings again' 1 "$(poll $((48 * h)))"
expect 'solo lane just past that rung rings nothing' 0 "$(poll $((48 * h + 720)))"

# Two lanes in one wake; each poll the lane that is younger by a hair swaps, so the text order and ages alternate.
reset; lane aa $((80 * h)); lane bb $((80 * h))
expect 'pair rings once' 1 "$(poll 0)"
for i in 1 2 3; do
  [ $((i % 2)) = 0 ] && { lane aa $((80 * h)); lane bb $((80 * h + 720)); } || { lane aa $((80 * h + 720)); lane bb $((80 * h)); }
  expect "pair poll $i rings nothing" 0 "$(poll $((i * 720)))"
done
[ "$fail" -eq 0 ] && echo "PASS: jg-flow wake key" || { echo "FAIL: jg-flow wake key"; exit 1; }
