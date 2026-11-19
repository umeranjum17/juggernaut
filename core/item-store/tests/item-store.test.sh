#!/usr/bin/env bash
# The store's proofs: each script runs with python3 -I and its last line must be the accepted line.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
fail=0
run() {   # <script> <expected last line>
  local got rc
  got=$(python3 -I "$HERE/$1"); rc=$?
  got=$(printf '%s\n' "$got" | tail -n 1)
  if [ "$rc" -ne 0 ] || [ "$got" != "$2" ]; then
    echo "FAIL $1: exit $rc, last line [$got], want [$2]"; fail=1
  else
    echo "ok $1: $got"
  fi
}
run ladder_fields.py '42 alert-table values read from the store: 42 PASS, 0 FAIL'
run prove.py '150 cases: 150 PASS, 0 FAIL; mutants killed 20 of 20'
run synthesis_cases.py '5 synthesis cases: 5 PASS, 0 FAIL'
run clause_mutants.py '39 clauses in multi-clause triggers: 39 caught by a case, 0 not'
run page_cap_mutants.py '3 of 3 page-read mutants caught'
run trigger_order.py 'orders with a different result: 0 of 10'
exit "$fail"
