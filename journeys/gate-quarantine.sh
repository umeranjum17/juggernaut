#!/usr/bin/env bash
# done-done journey: a quarantined test script can never hold a landing. A lane changes tests/jg-trunk-verify.test.sh, which
# tests/gate-quarantine.tsv lists; the real bin/jg-test-run.sh --required-shards (the landing gate's tests) lists it as
# JG_TEST_QUARANTINED with its reason, does not run it (here it would fail if it ran), counts no test and exits 0.
# The control lane without the quarantine line runs the same script and the gate fails, so the pass is the quarantine's doing.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ev=${DONE_DONE_EVIDENCE_ROOT:?this journey writes its log into the done-done evidence folder}
w=$(mktemp -d "${TMPDIR:-/tmp}/jg-gate-quarantine.XXXXXX") || exit 1
# shellcheck disable=SC2064 # $w is fixed now
trap "rm -rf -- '$w'" EXIT
export JG_TEST_HOST_SLOTS="$w/slots"
git clone -q "$root" "$w/repo" && cd "$w/repo" || exit 1
git checkout -q --detach "$(git -C "$root" rev-parse HEAD)"
g() { git -c user.name=t -c user.email=t@example.invalid "$@"; }
run_gate() { env -u JG_TASK_ID bash bin/jg-test-run.sh --required-shards HEAD^ "$1" 2>&1; }
{
  echo "== quarantine list =="; grep -v '^#' tests/gate-quarantine.tsv
  printf '# lane touch\n' >> tests/jg-trunk-verify.test.sh; g commit -qam 'lane touches the quarantined script'
  echo "== plain selection for the lane still names the script =="; bash bin/jg-test-run.sh --list --changed --base HEAD^ 2>&1
  printf '#!/usr/bin/env bash\necho RAN-QUARANTINED-SCRIPT\nexit 1\n' > tests/jg-trunk-verify.test.sh; g commit -qam 'the script would fail if it ran'
  echo "== landing gate: bin/jg-test-run.sh --required-shards HEAD^ =="
  out=$(run_gate "$ev/shards"); rc=$?
  printf '%s\n' "$out" | grep -E 'RAN-QUARANTINED|JG_TEST_QUARANTINED|JG_TEST_AGGREGATE' | sort | uniq -c
  echo "gate exit=$rc"
  echo "== control: the same lane with the quarantine line removed =="
  : > tests/gate-quarantine.tsv; g commit -qam 'unquarantine'
  printf '# touch\n' >> tests/jg-trunk-verify.test.sh; g commit -qam 'touch again'
  out=$(run_gate "$ev/shards-control"); crc=$?
  printf '%s\n' "$out" | grep -E 'RAN-QUARANTINED|JG_TEST_AGGREGATE'
  echo "control gate exit=$crc"
  if [ "$rc" = 0 ] && [ "$crc" != 0 ]; then echo "RESULT: quarantined script skipped and the gate passed; unquarantined it ran and failed the gate"; else echo "RESULT: FAIL"; fi
} > "$ev/gate-quarantine.log" 2>&1
cat "$ev/gate-quarantine.log"
ok=0; grep -q '^RESULT: quarantined' "$ev/gate-quarantine.log" && ok=1
jq -n --arg v "$(git -C "$root" rev-parse --short HEAD)" --arg r "$([ "$ok" = 1 ] && echo 'the gate listed the quarantined script with its reason, ran no test and exited 0; without the quarantine line it ran the script and failed' || echo 'the quarantine did not hold')" \
  '{target: {version: $v}, start: "a lane changes tests/jg-trunk-verify.test.sh, which tests/gate-quarantine.tsv lists", steps: ["list the tests the lane selects", "run the landing gate (bin/jg-test-run.sh --required-shards HEAD^)", "run the same lane with the quarantine line removed"], result: $r}' > "$ev/steps.json"
[ "$ok" = 1 ]
