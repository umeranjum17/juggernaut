#!/usr/bin/env bash
# Behavior test for the read verbs of `juggernaut-axi` (slice 1): status, lanes, wakes.
# Drives the real CLI over a fixture home and checks the tasks-axi conventions (count line,
# tabular rows, plain-words empty state, cut text with --full, --fields, --limit, help[]),
# TOON/JSON parity, and that reading never changes a record.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

AXI="$ROOT/bin/juggernaut-axi"
TMP_ROOT=$(jg_test_tmproot juggernaut-axi)
H=$TMP_ROOT/home
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$TMP_ROOT/fixture-root"
printf '## In flight\n- [ ] w1 - Worker one (repo: alpha) (kind: ship)\n- [ ] w2 - Worker two (repo: alpha) (kind: ship)\n- [ ] w3 - Scout three (repo: beta) (kind: scout)\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
export JG_HOME=$H JG_ROOT_OVERRIDE=$TMP_ROOT/fixture-root
LONG=$(printf 'long-note-%.0s' $(seq 30))
for t in w1:ship:alpha w2:ship:alpha w3:scout:beta; do
  id=${t%%:*}; rest=${t#*:}; kind=${rest%%:*}; repo=${rest#*:}
  jg_write_meta "$H/state/$id.meta" harness=claude kind="$kind" mode=direct-PR branch="fm/$id" backend=herdr \
    window=default:w:p project="$H/projects/$repo"
done
echo "working [at=$(date +%s)]: doing a small thing" > "$H/state/w1.status"
echo "paused [at=$(date +%s)]: $LONG" > "$H/state/w2.status"
echo "done [at=$(date +%s)]: finished" > "$H/state/w3.status"
printf '1793585000\t11\tstale\tdefault:w:p1\tstale: default:w:p1\n1793585100\t12\tsignal\tw1.status\tsignal: w1.status\n1793585200\t13\tcheck\tmerge\t%s\n' "$LONG$LONG" > "$H/state/.wake-queue"
printf '1793585300\tsilent\tstale\tdefault:w:p2\tstale: default:w:p2\n' > "$H/state/.wake-settled"

# lanes
out=$("$AXI" lanes)
assert_contains "$out" "view: lanes" "lanes names its view"
assert_contains "$out" "count: 3" "lanes counts its rows"
assert_contains "$out" "lanes[3]{id,kind,state,reported,project,note}:" "lanes rows are tabular"
assert_contains "$out" "help[" "lanes ends with next-step help"
assert_equals 3 "$("$AXI" lanes --json | jq '.lanes | length')" "JSON carries every lane"
assert_equals paused "$("$AXI" lanes --json | jq -r '.lanes[] | select(.id == "w2") | .reported')" "reported state is the last status line"
assert_equals scout "$("$AXI" lanes --kind scout --json | jq -r '.lanes[0].kind')" "--kind filters"
assert_equals beta "$("$AXI" lanes --project beta --json | jq -r '.lanes[0].project')" "--project filters"
two=$("$AXI" lanes --limit 2)
assert_contains "$two" "count: 2 of 3 total" "a cut list says how many exist"
assert_contains "$two" "lanes beyond limit,1" "the omitted row is counted"
assert_contains "$("$AXI" lanes --fields branch,harness)" "note,branch,harness}" "--fields adds columns"
assert_contains "$("$AXI" lanes)" "truncated, ${#LONG} chars total - use --full" "long text names its full length"
assert_not_contains "$("$AXI" lanes --full)" "truncated" "--full lifts the cut"
none=$("$AXI" lanes --kind ship --state nothing)
assert_contains "$none" "lanes: 0 lanes match these filters" "an empty list says so in words"
assert_contains "$none" "count: 0 of 0 total" "an empty list still counts"
"$AXI" lanes --fields bogus >/dev/null 2>"$TMP_ROOT/err" && fail "an unknown field must be refused"
assert_contains "$(cat "$TMP_ROOT/err")" "unknown --fields name: bogus" "the refusal names the field"
"$AXI" lanes --limit 0 >/dev/null 2>&1 && fail "limit 0 must be refused"

# wakes
before=$(sha256sum "$H/state/.wake-queue" "$H/state/.wake-settled")
w=$("$AXI" wakes)
assert_contains "$w" "queued: 3" "wakes counts the queue"
assert_contains "$w" "settled_recorded: 1" "record-only wakes are counted"
assert_contains "$w" "wakes[3]{seq,at,kind,key,payload}:" "wake rows are tabular"
assert_contains "$w" "not the live bus" "the source is stated"
assert_equals "11 12 13" "$("$AXI" wakes --json | jq -r '[.wakes[].seq] | join(" ")')" "rows keep queue order, oldest first"
assert_equals 1 "$("$AXI" wakes --kind signal --json | jq '.wakes | length')" "--kind filters"
assert_contains "$("$AXI" wakes --limit 1)" "wakes beyond limit,2" "the omitted wakes are counted"
assert_contains "$w" "truncated, $((${#LONG} * 2)) chars total" "long payloads are cut with their length"
assert_not_contains "$("$AXI" wakes --full)" "truncated" "--full lifts the cut"
"$AXI" wakes --kind bogus >/dev/null 2>&1 && fail "an unknown kind must be refused"
assert_equals "$before" "$(sha256sum "$H/state/.wake-queue" "$H/state/.wake-settled")" "reading wakes changes no record"
rm -f "$H/state/.wake-queue"
assert_contains "$("$AXI" wakes)" "wakes: 0 wakes queued" "an absent queue reads as empty"

# status and help
st=$("$AXI" status)
assert_contains "$st" "wakes_queued: 0" "status counts queued wakes"
assert_contains "$st" "juggernaut-axi lanes" "status points at lanes"
assert_contains "$("$AXI" lanes --help)" "usage: juggernaut-axi lanes" "lanes has its own help"
assert_contains "$("$AXI" wakes --help)" "usage: juggernaut-axi wakes" "wakes has its own help"
assert_contains "$("$AXI" tickets --json)" "juggernaut-axi.v1" "existing views still answer"
pass "juggernaut-axi read verbs"
