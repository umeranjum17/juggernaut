#!/usr/bin/env bash
# E2E: the completion-receipt acceptance (jg_dod_receipt_accept), driven through the real merge-path library on a
# corpus of task records and receipts, one per decision branch. receipt-accept-cases.jsonl holds, per case, the status
# and the exact output the acceptance gave when its rules were shell code; they now live in policy/gate/receipt.rego
# and this test holds them to those recorded decisions.
# Usage: tests/receipt-accept-cases.test.sh           check every case against its recorded decision
#        RECORD=1 tests/receipt-accept-cases.test.sh   re-record the decisions (only after a deliberate rule change)
# Needs opa and go (the guard host evaluates the policy); with either absent the test skips.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
CASES=$here/receipt-accept-cases.jsonl
# shellcheck source=lib/policy-test-env.sh
[ -n "${RECORD:-}" ] || . "$ROOT/core/lib/policy-test-env.sh"
d=$(mktemp -d "${TMPDIR:-/tmp}/receipt-cases.XXXXXX") || exit 1
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d JG_HOME=$d/jg JG_CORE_DIR=$ROOT/core
mkdir -p "$HOME" "$JG_HOME/state"
# shellcheck disable=SC1091  # $ROOT resolves at run time; the library is not beside this file
. "$ROOT/bin/jg-dod-lib.sh"
# The forge read behind "the lane's next PR" is the one fact the acceptance cannot gather offline: each case says what it answers.
NEXT=no
# shellcheck disable=SC2317,SC2329  # the acceptance calls this through the library
jg_receipts_next_pr_of_lane_ok() { [ "$NEXT" = yes ]; }
st=$JG_HOME/state head=$(printf 'c%.0s' {1..40}) pr=https://github.com/o/r/pull/1 pr2=https://github.com/o/r/pull/2
good() { # <field=value>... overrides: the receipt of task t that the acceptance accepts at $head
  jq -cn --arg head "$head" --arg pr "$pr" '{schema:1, task:"t", mode:"direct-PR", spawn_gen:"1", head:$head, pr:$pr, verdict:"PASS", at:1700000000, evidence:"ran the checks"}'
}
# name ~ meta lines (\n separated) | receipt (a jq filter over the good receipt, or raw:<text>, link, absent) | head | next
cases=(
  "optional, no receipt~~absent~$head~no"
  "required, no receipt~receipt_required=1~absent~$head~no"
  "required zero is malformed~receipt_required=0~absent~$head~no"
  "required twice is malformed~receipt_required=1\nreceipt_required=1~absent~$head~no"
  "required junk is malformed~receipt_required=yes~.~$head~no"
  "required twice with a receipt~receipt_required=1\nreceipt_required=1~.~$head~no"
  "unrequired receipt for the head accepts~~.~$head~no"
  "required receipt for the head accepts~receipt_required=1~.~$head~no"
  "bound pr, same pr accepts~receipt_required=1\npr=$pr~.~$head~no"
  "bound pr, other pr refuses~receipt_required=1\npr=$pr2~.~$head~no"
  "bound pr, other pr but lane's next pr accepts~receipt_required=1\npr=$pr2~.~$head~yes"
  "bound pr, receipt without a pr refuses~receipt_required=1\npr=$pr~del(.pr)~$head~no"
  "bound pr, receipt pr not a string refuses~receipt_required=1\npr=$pr~.pr=7~$head~no"
  "unbound pr, any receipt pr accepts~receipt_required=1~.pr=\"$pr2\"~$head~no"
  "unbound pr, receipt without a pr accepts~receipt_required=1~del(.pr)~$head~no"
  "FAIL verdict refuses~receipt_required=1~.verdict=\"FAIL\"~$head~no"
  "lowercase verdict refuses~receipt_required=1~.verdict=\"pass\"~$head~no"
  "other head refuses~receipt_required=1~.~dddddddddddddddddddddddddddddddddddddddd~no"
  "invalid candidate head refuses~receipt_required=1~.head=\"zz\"~zz~no"
  "uppercase candidate head refuses~receipt_required=1~.head=\"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\"~CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC~no"
  "empty candidate head refuses~receipt_required=1~.~\"\"~no"
  "other task refuses~receipt_required=1~.task=\"u\"~$head~no"
  "other mode refuses~receipt_required=1~.mode=\"local-only\"~$head~no"
  "other incarnation refuses~receipt_required=1~.spawn_gen=\"2\"~$head~no"
  "incarnation as a number refuses~receipt_required=1~.spawn_gen=1~$head~no"
  "schema 2 refuses~receipt_required=1~.schema=2~$head~no"
  "blank evidence refuses~receipt_required=1~.evidence=\" \\n\\t\"~$head~no"
  "missing evidence refuses~receipt_required=1~del(.evidence)~$head~no"
  "evidence not a string refuses~receipt_required=1~.evidence=[\"x\"]~$head~no"
  "evidence with leading space accepts~receipt_required=1~.evidence=\"  ok\"~$head~no"
  "time zero refuses~receipt_required=1~.at=0~$head~no"
  "time as a string refuses~receipt_required=1~.at=\"1700000000\"~$head~no"
  "time missing refuses~receipt_required=1~del(.at)~$head~no"
  "fractional time accepts~receipt_required=1~.at=1.5~$head~no"
  "two receipts in the file refuse~receipt_required=1~raw:two~$head~no"
  "not json refuses~receipt_required=1~raw:not json~$head~no"
  "empty file refuses~receipt_required=1~raw:~$head~no"
  "array receipt refuses~receipt_required=1~raw:[1]~$head~no"
  "null receipt refuses~receipt_required=1~raw:null~$head~no"
  "a symlinked receipt refuses~receipt_required=1~link~$head~no"
  "a symlinked receipt refuses when optional~~link~$head~no"
)
run_case() { # <name> <meta> <receipt> <head> <next>
  local name=$1 meta=$2 receipt=$3 cand=$4 next=$5 out rc
  rm -f "$st"/t.*
  printf 'mode=direct-PR\nspawn_gen=1\n' > "$st/t.meta"
  [ -z "$meta" ] || printf '%b\n' "$meta" >> "$st/t.meta"
  case $receipt in
    absent) ;;
    link) good > "$d/target.json"; ln -s "$d/target.json" "$st/t.run-receipt.json" ;;
    raw:two) { good; good; } > "$st/t.run-receipt.json" ;;
    raw:*) printf '%s' "${receipt#raw:}" > "$st/t.run-receipt.json" ;;
    *) good | jq -c "$receipt" > "$st/t.run-receipt.json" ;;
  esac
  [ "$cand" != '""' ] || cand=
  NEXT=$next
  out=$(jg_dod_receipt_accept "$st" t "$st/t.meta" "$cand" 2>&1); rc=$?
  out=${out//"$JG_HOME"/<HOME>}; out=${out//"$ROOT"/<ROOT>}
  jq -cn --arg name "$name" --argjson rc "$rc" --arg out "$out" '{name: $name, rc: $rc, out: $out}'
}
got=$d/got.jsonl
for c in "${cases[@]}"; do
  IFS='~' read -r name meta receipt cand next <<<"$c"
  run_case "$name" "$meta" "$receipt" "$cand" "$next"
done > "$got"
if [ -n "${RECORD:-}" ]; then cp "$got" "$CASES"; printf 'recorded %s cases\n' "$(wc -l < "$got")"; exit 0; fi
n=$(wc -l < "$CASES") fails=0
[ "$n" -gt 0 ] && [ "$(wc -l < "$got")" -eq "$n" ] || { echo "FAIL: case count differs from the recording"; exit 1; }
while IFS= read -r line; do printf 'FAIL: %s\n' "$line"; fails=$((fails + 1)); done < <(diff "$CASES" "$got" | grep '^[<>]')
[ "$fails" -eq 0 ] && printf 'PASS: %s receipt cases match their recorded decisions\n' "$n" && exit 0
printf 'FAIL: %s differing lines against %s recorded cases\n' "$fails" "$n"
exit 1
