#!/usr/bin/env bash
# Integration test for core/test-select/sample.sh, run as the lane's proof runs it.
# T1 the pick is fixed per lane; T2 it differs across lanes; T3 affected scripts are always in; T4 the default is 10 percent;
# T5 percent 0 gives only the affected and 100 gives all; T6 a day's lanes together cover the suite; T7 a bad percent is refused.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
S="$ROOT/core/test-select/sample.sh"
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
mkdir "$d/tests"; for i in $(seq 1 200); do : > "$d/tests/t$i.test.sh"; done
printf '%s\n' "$d/tests/t7.test.sh" > "$d/aff"
fail=0
ok() { local name=$1; shift; if "$@"; then echo "ok - $name"; else echo "not ok - $name"; fail=1; fi; }
run() { bash "$S" "$@" --tests "$d/tests"; }
# shellcheck disable=SC2329 # called through ok
eq() { [ "$1" = "$2" ]; }
# shellcheck disable=SC2329
ne() { [ "$1" != "$2" ]; }
# shellcheck disable=SC2329
between() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
# shellcheck disable=SC2329
has_line() { printf '%s\n' "$1" | grep -qx "$2"; }

a1=$(run lane-a --affected "$d/aff"); a2=$(run lane-a --affected "$d/aff"); b=$(run lane-b --affected "$d/aff")
n=$(run lane-a | wc -l)
only=$(run lane-a --percent 0 --affected "$d/aff")
all=$(run lane-a --percent 100 | wc -l)
cov=$(for l in $(seq 1 60); do run "lane-$l"; done | sort -u | wc -l)
run lane-a --percent abc >/dev/null 2>&1; bad=$?
ok "T1 same lane, same pick" eq "$a1" "$a2"
ok "T2 different lanes, different picks" ne "$a1" "$b"
ok "T3 affected script is in" has_line "$a1" "$d/tests/t7.test.sh"
ok "T4 default is about 10 percent ($n of 200)" between "$n" 5 40
ok "T5a percent 0 gives only affected" eq "$only" "$d/tests/t7.test.sh"
ok "T5b percent 100 gives all" eq "$all" 200
ok "T6 60 lanes cover the suite ($cov of 200)" between "$cov" 195 200
ok "T7 bad percent refused" eq "$bad" 2
exit $fail
