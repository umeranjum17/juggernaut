#!/usr/bin/env bash
# Behavior test for the read verbs of `juggernaut-axi` (slices 1 and 2): status, lanes, wakes,
# tasks (list, show, ready), holds, and pr.
# Drives the real CLI over a fixture home and checks the backlog conventions (count line,
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
# The backlog is a Beads store: three tasks In flight and four queued, one blocked on a worker, one held for
# the captain and one parked behind a move.
jg_test_beads_home "$H"
bk() { jg_test_backlog "$H" "$@" >/dev/null || fail "backlog $*"; }
fix() {  # <id> <title> <priority> <repo> <kind> [add args]
  local id=$1 title=$2 prio=$3 repo=$4 kind=$5
  shift 5
  bk add "$id" "[feature] $title" --priority "$prio" --kind "$kind" --repo "$repo" --body "Fixture task $id" "$@"
}
hold_row() {  # <id> <reason> <kind>
  BEADS_DIR=$(cat "$H/config/beads-dir") JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT \
    "$ROOT/bin/jg-beads-write.py" hold "$1" --reason "$2" --kind "$3" >/dev/null || fail "hold $1"
}
fix w-1 'Worker one' 1 alpha ship; bk start w-1
fix w-2 'Worker two' 1 alpha ship; bk start w-2
fix w-3 'Scout three' 1 beta scout; bk start w-3
fix q-ready 'Ready alpha work' 1 alpha ship
fix q-blocked 'Waits on worker one' 2 alpha ship --blocked-by w-1
fix q-captain 'Needs the captain' 1 beta ship; hold_row q-captain 'pick the name' captain
fix q-future 'Parked behind the move' 3 beta ship; hold_row q-future 'after the move' future
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
# tasks: list, show, ready
before=$(jg_test_backlog "$H" list --json | sha256sum)
tl=$("$AXI" tasks)
assert_contains "$tl" "view: tasks" "tasks names its view"
assert_contains "$tl" "count: 7 of 7 total" "tasks counts its rows"
assert_contains "$tl" "tasks[7]{id,state,kind,repo,title}:" "tasks rows are tabular"
assert_contains "$tl" "help[" "tasks ends with next-step help"
assert_equals 3 "$("$AXI" tasks --state in_flight --json | jq '.tasks | length')" "--state filters"
assert_equals "q-captain q-future" "$("$AXI" tasks --state held --json | jq -r '[.tasks[].id] | join(" ")')" "--state held lists every held task"
assert_equals q-blocked "$("$AXI" tasks --blocked --json | jq -r '.tasks[].id')" "--blocked lists only blocked work"
assert_equals "q-captain q-future" "$("$AXI" tasks --repo beta --kind ship --json | jq -r '[.tasks[].id] | join(" ")')" "--repo and --kind combine"
assert_contains "$("$AXI" tasks --limit 2)" "tasks beyond limit,5" "the omitted tasks are counted"
assert_contains "$("$AXI" tasks --fields blocked_by,hold_kind)" "title,blocked_by,hold_kind}" "--fields adds columns"
assert_equals w-1 "$("$AXI" tasks --fields blocked_by --json | jq -r '.tasks[] | select(.id == "q-blocked") | .blocked_by')" "blocked_by names the open blocker"
none=$("$AXI" tasks --state "done")
assert_contains "$none" "tasks: 0 tasks match these filters" "an empty list says so in words"
assert_contains "$none" "count: 0 of 0 total" "an empty tasks list still counts"
"$AXI" tasks --state bogus >/dev/null 2>&1 && fail "an unknown state must be refused"
sh1=$("$AXI" tasks show q-captain)
assert_contains "$sh1" "view: task" "show names its view"
assert_contains "$sh1" "hold_kind: captain" "show states the hold kind"
assert_contains "$sh1" "hold_reason: pick the name" "show states the hold reason"
assert_contains "$sh1" "held: yes" "show states the task is held"
assert_contains "$("$AXI" tasks show q-blocked)" "blocked_by: w-1" "show names the blocker"
assert_equals 1 "$("$AXI" tasks show q-ready --json | jq '[.task] | length')" "show --json carries the task"
"$AXI" tasks show no-such-task >/dev/null 2>"$TMP_ROOT/err"; rc=$?
assert_equals 2 "$rc" "an unknown task exits 2"
assert_contains "$(cat "$TMP_ROOT/err")" "unknown task: no-such-task" "the refusal names the task"
rd=$("$AXI" tasks ready)
assert_contains "$rd" "view: ready" "ready names its view"
assert_equals q-ready "$("$AXI" tasks ready --json | jq -r '[.ready[].id] | join(" ")')" "ready is queued, unblocked, and unheld work only"
assert_contains "$("$AXI" tasks ready --repo beta)" "ready: 0 tasks are ready" "an empty ready list says so in words"
assert_contains "$("$AXI" holds --help)" "usage: juggernaut-axi holds" "holds has its own help"

# holds
hl=$("$AXI" holds)
assert_contains "$hl" "view: holds" "holds names its view"
assert_contains "$hl" "holds[2]{id,kind,bucket,age_days,until,reason}:" "hold rows are tabular"
assert_equals "captain:1 future:1" "$("$AXI" holds --json | jq -r '[.kinds[] | "\(.kind):\(.count)"] | join(" ")')" "holds are counted by kind"
assert_equals q-captain "$("$AXI" holds --kind captain --json | jq -r '.holds[0].id')" "--kind filters"
assert_equals live "$("$AXI" holds --bucket live --json | jq -r '.holds[0].bucket')" "a fresh captain hold is live"
assert_contains "$("$AXI" holds --kind parked)" "holds: 0 holds match these filters" "an empty hold list says so in words"
assert_contains "$("$AXI" holds --limit 1)" "holds beyond limit,1" "the omitted holds are counted"
"$AXI" holds --kind bogus >/dev/null 2>&1 && fail "an unknown hold kind must be refused"
assert_equals "$before" "$(jg_test_backlog "$H" list --json | sha256sum)" "reading tasks and holds changes no record"

# pr: a stub gh stands in for GitHub; the real jg-pr-state.sh reads it
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf 'state=open\nmerged_at=\ndraft=%s\nhead=abc123\nauthor=umer\nmergeability=mergeable\nreview_decision=\n' "${STUB_DRAFT:-false}" ;;
  "pr checks") [ -z "${STUB_RED:-}" ] || echo "REQUIRED CHECK: lint (FAILURE)" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$TMP_ROOT/bin/gh"
PRURL=https://github.com/example/repo/pull/7
red=$(PATH="$TMP_ROOT/bin:$PATH" STUB_RED=1 "$AXI" pr "$PRURL")
assert_contains "$red" "view: pr" "pr names its view"
assert_contains "$red" "blockers[1]{kind,detail}:" "blockers are tabular"
assert_contains "$red" "REQUIRED CHECK,lint (FAILURE)" "a red required check is listed"
assert_contains "$red" "waiting_for: \"a required check is not passing: lint\"" "the one wait is named"
assert_contains "$red" "not a readiness verdict" "an empty list is never read as ready"
green=$(PATH="$TMP_ROOT/bin:$PATH" "$AXI" pr "$PRURL")
assert_contains "$green" "blockers: 0 blockers reported" "no blocker says so in words"
assert_contains "$green" "waiting_for: \"the merge call" "a clean pull request waits only on the merge call"
assert_contains "$(PATH="$TMP_ROOT/bin:$PATH" STUB_DRAFT=true "$AXI" pr "$PRURL" --json)" "marked ready for review" "--json carries the same wait"
"$AXI" pr not-a-url >/dev/null 2>&1 && fail "a non-URL must be refused"
PATH="$TMP_ROOT/bin:$PATH" "$AXI" pr "https://github.com/example/repo/issues/7" >/dev/null 2>&1 && fail "an issue URL must be refused"
assert_contains "$("$AXI" pr --help)" "usage: juggernaut-axi pr" "pr has its own help"
pass "juggernaut-axi read verbs"
