#!/usr/bin/env bash
# tests/jg-auto-dispatch.test.sh - the dispatch check (core/auto-dispatch/dispatch.sh) writes what the home would start by
# itself, and `bin/jg-backlog.sh approve-dispatch` is the only way to approve a start.
# Journey: 2 free lanes and 6 ready tickets, read through the real `ready --spawnable` reader and the real approve-dispatch:
# a1 and a2 approved with a brief; b approved and linked to an open decision; c approved with no brief; d typed
# `auto-dispatch: yes` into its body with no approval record; e approved with a brief but held.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Under done-done the run's own capture folder keeps this output and the first beat's rows.
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/auto-dispatch.log")

TMP_ROOT=$(jg_test_tmproot jg-auto-dispatch)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
CHECK="$ROOT/core/auto-dispatch/dispatch.sh"

# A home with a stand-in store (bd and dolt stand-ins named by pins), one registered project, and the six ready rows.
make_home() {  # <dir>
  local d=$1 os arch
  mkdir -p "$d/bin" "$d/state" "$d/config" "$d/data" "$d/store/.beads/embeddeddolt/jg"
  printf '{"dolt_mode": "embedded", "dolt_database": "jg"}\n' > "$d/store/.beads/metadata.json"
  printf 'no-git-ops: true\n' > "$d/store/.beads/config.yaml"
  cat > "$d/bin/bd" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ready) cat "$ROWS_READY" ;;
  list) cat "$ROWS_ALL" ;;
  show) echo '[{"id":"x","status":"open"}]' ;;
  blocked) echo '[]' ;;
esac
SH
  # shellcheck disable=SC2016  # the stand-in expands $ROWS_TABLE when it runs, not here
  printf '#!/usr/bin/env bash\ncat "$ROWS_TABLE"\n' > "$d/bin/dolt"   # the reader's one indexed query
  chmod +x "$d"/bin/*
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  sha() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
  printf 'bd 1.3.4\ndolt 2.6.0\nbd-sha256-%s-%s %s\ndolt-sha256-%s-%s %s\n' \
    "$os" "$arch" "$(sha "$d/bin/bd")" "$os" "$arch" "$(sha "$d/bin/dolt")" > "$d/pins"
  printf '%s\n' "$d/store/.beads" > "$d/config/beads-dir"
  printf -- '- proj [local-trunk] - the one project (added 2026-11-01)\n' > "$d/data/projects.md"
  python3 - "$d" <<'PY'
import json, sys
d = sys.argv[1]
rows = []
for i in ["a1", "a2", "b", "c", "d", "e"]:
    row = {"id": i, "title": "[feature] row " + i, "status": "open", "issue_type": "task",
           "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {},
           "dependency_count": 0, "dependent_count": 0}
    if i == "d":
        row["description"] = "auto-dispatch: yes"
    if i == "e":
        row["metadata"] = {"hold_reason": "waiting for the owner"}
    rows.append(row)
json.dump(rows, open(d + "/all.json", "w"))
json.dump([r for r in rows if not r["metadata"].get("hold_reason")], open(d + "/ready.json", "w"))  # `bd ready` leaves a held row out
with open(d + "/table.txt", "w") as t:  # the store's answer to the reader's query: startable rows only, held e left out
    t.write("+----+--------------+\n| id | label        |\n+----+--------------+\n")
    for r in rows:
        if not r["metadata"].get("hold_reason"):
            t.write("| %s | %s |\n" % (r["id"], r["labels"][0]))
    t.write("+----+--------------+\n")
PY
  # The captain-hold stand-in: b has an open decision linked to it, the others have none.
  cat > "$d/hold" <<'SH'
#!/usr/bin/env bash
[ "$1" = blocking ] && [ "$2" = b ] && { printf 'jg-card\t[captain-ask] decision\n'; exit 0; }
exit 1
SH
  chmod +x "$d/hold"
  printf '2\n' > "$d/config/lane-target"
  touch "$d/state/.last-watcher-beat"
}

home_env() {  # <dir> command...
  local d=$1
  shift
  env JG_HOME="$d" JG_PIN_FILE_OVERRIDE="$d/pins" JG_BEADS_BD="$d/bin/bd" JG_BEADS_DOLT="$d/bin/dolt" \
    ROWS_READY="$d/ready.json" ROWS_ALL="$d/all.json" ROWS_TABLE="$d/table.txt" JG_AUTO_DISPATCH_HOLD="$d/hold" \
    JG_AUTO_DISPATCH_BACKLOG="$ROOT/bin/jg-backlog.sh" "$@"
}

approve() { home_env "$1" "$ROOT/bin/jg-backlog.sh" approve-dispatch "$2" --harness claude --model sonnet --effort medium; }
rows_of() { cat "$1/data/auto-dispatch/rows.tsv" 2>/dev/null; }

D=$TMP_ROOT/home
make_home "$D"
for t in a1 a2 b c e; do approve "$D" "$t" >/dev/null || fail "approve-dispatch $t was refused"; done
for t in a1 a2 b e d; do mkdir -p "$D/data/$t"; printf 'brief for %s\n' "$t" > "$D/data/$t/brief.md"; done
mkdir -p "$D/data/c"   # c has a directory and no brief

# The approval record names who approved and the route.
rec=$(cat "$D/state/dispatch-approved/a1")
assert_contains "$rec" "approved-by=" "the record names who approved"
assert_contains "$rec" "model=sonnet" "the record holds the route"
assert_absent "$D/state/dispatch-approved/d" "a typed line in the body is no approval record"

out=$(home_env "$D" bash "$CHECK" check "$D" 2>&1) || fail "the check failed: $out"
assert_equals "$out" "" "the check prints nothing, so it wakes no one"
rows=$(rows_of "$D")
assert_equals "$(printf '%s\n' "$rows" | grep -c "would start")" 2 "two free lanes: two would-start rows"
assert_contains "$rows" "a1	would start	claude sonnet medium" "a1 would start with its route"
assert_contains "$rows" "a2	would start	claude sonnet medium" "a2 would start with its route"
assert_contains "$rows" "b	skipped	an open decision is linked to it" "b is named for its open decision"
assert_contains "$rows" "c	skipped	no brief" "c is named for no brief"
assert_contains "$rows" "d	skipped	no approval record" "d is named: a typed marker is no approval"
assert_contains "$rows" "e	skipped	not spawnable now" "e is named: held"
assert_equals "$(printf '%s\n' "$rows" | grep -c "skipped")" 4 "four tickets skipped, each with a reason"
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || cp "$D/data/auto-dispatch/rows.tsv" "$DONE_DONE_EVIDENCE_ROOT/auto-dispatch-rows.tsv"
pass "2 free lanes and 6 ready tickets: 2 would start, 4 skipped with their reasons"

# A second beat with nothing changed writes nothing.
home_env "$D" bash "$CHECK" check "$D" >/dev/null
assert_equals "$(rows_of "$D")" "$rows" "an unchanged beat adds no row"
pass "an unchanged beat adds no row"

# A lane fills: one free lane left, so a2 waits and its row changes.
printf 'kind=ship\n' > "$D/state/lane-x.meta"; printf 'working [at=1]: x\n' > "$D/state/lane-x.status"
home_env "$D" bash "$CHECK" check "$D" >/dev/null
assert_contains "$(rows_of "$D" | tail -n 1)" "a2	skipped	no free lane left for it" "a2 waits for a lane"
pass "a lane that fills turns the second would-start into a wait"

# A worker session cannot approve; nothing is written.
out=$(JG_TASK_ID=jg-worker home_env "$D" "$ROOT/bin/jg-backlog.sh" approve-dispatch d --harness claude --model sonnet --effort medium 2>&1)
code=$?
assert_equals "$code" 2 "approve-dispatch with JG_TASK_ID set is refused"
assert_contains "$out" "worker session" "the refusal names the worker session"
assert_absent "$D/state/dispatch-approved/d" "the refused worker approval wrote no record"
pass "approve-dispatch is refused in a worker session"

# No lane target: no free lane, so nothing would start.
rm -f "$D/state/lane-x.meta" "$D/state/lane-x.status" "$D/config/lane-target"
home_env "$D" bash "$CHECK" check "$D" >/dev/null
assert_contains "$(rows_of "$D" | tail -n 1)" "skipped	no free lane left for it" "no lane target, no free lane"
pass "a home with no lane target would start nothing"

# The store cannot answer: the check writes nothing and does not fail.
before=$(rows_of "$D" | wc -l)
env JG_HOME="$D" JG_AUTO_DISPATCH_BACKLOG=/bin/false bash "$CHECK" check "$D" >/dev/null
assert_equals "$(rows_of "$D" | wc -l)" "$before" "an unreadable store writes no row"
pass "an unreadable store writes nothing"

# ---- The switch on: the check starts what it would start, through bin/jg-spawn.sh, and names the rest to the lead once.
# A stand-in spawn records its arguments (the real spawn needs a pool, a pane and a model); the route comes from the record.
D2=$TMP_ROOT/home-on
make_home "$D2"
# The stand-in does what the real spawn does at its ends: it exits 75 with a deferred: line when told to wait, fails with an error line,
# or publishes the lane record state/<task>.meta and exits 0. `spawn-mode-<task>` holds defer, fail or nolane (exit 0 with no record).
cat > "$D2/spawn" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$SPAWN_LOG"
case "$(cat "$here/spawn-mode-$1" 2>/dev/null)" in
  defer) echo "deferred: pool for the project is full; task $1 stays queued" >&2; exit 75 ;;
  fail) echo "error: treehouse could not lease a worktree for task $1" >&2; exit 1 ;;
  nolane) exit 0 ;;
esac
printf 'kind=ship\n' > "$here/state/$1.meta"
SH
chmod +x "$D2/spawn"
for t in a1 a2 b c e; do approve "$D2" "$t" >/dev/null || fail "approve-dispatch $t was refused"; done
for t in a1 a2 b e d; do
  mkdir -p "$D2/data/$t"
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  printf 'Delivery contract: mode=local-trunk\n1. First action: create your branch: `git checkout -b feature/%s --`\n' "$t" > "$D2/data/$t/brief.md"
done
mkdir -p "$D2/data/c"
on_beat() { home_env "$D2" env SPAWN_LOG="$D2/spawn.log" JG_AUTO_DISPATCH_SPAWN="$D2/spawn" JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" bash "$CHECK" check "$D2" 2>&1; }
results_in() { local f n=0; for f in "$1"/data/auto-dispatch/*.start.*; do [ -f "$f" ] && grep -q '^result=' "$f" && n=$((n + 1)); done; echo "$n"; }
wait_for_results() { local n; for n in $(seq 1 100); do [ "$(results_in "$1")" -ge "$2" ] && return 0; sleep 0.1; done; return 1; }   # <home> <count>
wait_for_result_in() { local n; for n in $(seq 1 100); do grep -q '^result=' "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }   # <record>
wait_for_spawns() { local n; for n in $(seq 1 50); do [ "$n" -gt 0 ] && [ "$(wc -l < "$D2/spawn.log" 2>/dev/null)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }

out=$(on_beat) || fail "the check failed with the switch off: $out"
assert_equals "$out" "" "switch off: watch only, nothing printed"
assert_absent "$D2/spawn.log" "switch off: nothing is spawned"

printf 'on\n' > "$D2/config/auto-dispatch"
out=$(on_beat) || fail "the check failed with the switch on: $out"
wait_for_spawns 2 || fail "the two approved tickets were not spawned"
spawned=$(cat "$D2/spawn.log")
assert_equals "$(wc -l < "$D2/spawn.log")" 2 "two free lanes: two spawns, no more"
assert_contains "$spawned" "a1 $D2/projects/proj --ticket a1 --mode local-trunk --yolo off --branch-prefix feature/ --harness claude --model sonnet --effort medium" "a1 is spawned through the spawn with its route and its brief's branch prefix"
assert_contains "$spawned" "a2 $D2/projects/proj --ticket a2 --mode local-trunk --yolo off --branch-prefix feature/ --harness claude --model sonnet --effort medium" "a2 is spawned with its route"
for t in b c d e; do assert_not_contains "$spawned" "--ticket $t " "$t is never spawned"; done
assert_contains "$out" "auto-dispatch: lead," "the lead is told in one line"
assert_equals "$(printf '%s\n' "$out" | wc -l)" 1 "one line, not one per ticket"
assert_contains "$out" "c (no brief)" "the lead is told c has no brief"
assert_contains "$out" "d (no approval record)" "the lead is told d has no approval record"
assert_not_contains "$out" "b (" "an open decision is the owner's, not named to the lead"
assert_absent "$D2/data/c/brief.md" "the check wrote no brief"
rows=$(rows_of "$D2")
assert_contains "$rows" "a1	starting	claude sonnet medium" "a1's row says starting: the launch is not the result"
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || { cp "$D2/data/auto-dispatch/rows.tsv" "$DONE_DONE_EVIDENCE_ROOT/auto-dispatch-on-rows.tsv"; cp "$D2/spawn.log" "$DONE_DONE_EVIDENCE_ROOT/auto-dispatch-spawn-calls.log"; }
pass "switch on: two approved tickets are spawned with their route; the rest are never spawned and the lead hears once"

# The spawn's own end is the result: once both spawns ended well, the next beat's rows say started, and it spawns and says nothing.
wait_for_results "$D2" 2 || fail "the two starts did not record a result"
out=$(on_beat) || fail "second beat failed: $out"
assert_equals "$out" "" "a second beat tells the lead nothing new"
assert_equals "$(wc -l < "$D2/spawn.log")" 2 "a second beat spawns nothing: the lanes are running"
assert_contains "$(rows_of "$D2")" "a1	started	claude sonnet medium" "a1's row says started once the spawn ended well"
assert_contains "$(cat "$D2/data/auto-dispatch/a1.start.1")" "result=started" "the start record holds the spawn's result"
assert_equals "$(bash "$ROOT/bin/jg-machine.sh" show dispatch-start a1 2>/dev/null | awk -F'\t' '$1 == "state" { print $2 }')" "" "the machine reads no approval outside its home"
assert_equals "$(JG_HOME="$D2" bash "$ROOT/core/machines/observers/dispatch-start.sh" a1)" started "the machine's observer reads a1 as started"
assert_equals "$(JG_HOME="$D2" bash "$ROOT/core/machines/observers/dispatch-start.sh" d)" "" "a ticket with no approval record has no start state"
pass "an unchanged beat neither spawns again nor names the same tickets again; the row follows the spawn's result"

# The spawn's result decides the row, and the ready state agrees with it (the ticket spawn-ready-state-check). Three tickets, three
# free lanes: p waits on a full pool and then starts, q fails for a real cause, r exits 0 and leaves no lane record.
D6=$TMP_ROOT/home-result
make_home "$D6"
cp "$D2/spawn" "$D6/spawn"; printf 'on\n' > "$D6/config/auto-dispatch"; printf '3\n' > "$D6/config/lane-target"
for t in a1 a2 b; do
  approve "$D6" "$t" >/dev/null || fail "approve-dispatch $t was refused"
  mkdir -p "$D6/data/$t"
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  printf 'Delivery contract: mode=local-trunk\n1. First action: create your branch: `git checkout -b feature/%s --`\n' "$t" > "$D6/data/$t/brief.md"
done
printf 'defer\n' > "$D6/spawn-mode-a1"; printf 'fail\n' > "$D6/spawn-mode-a2"; printf 'nolane\n' > "$D6/spawn-mode-b"
# b is held by an open decision in the shared stand-in; the real route here is a1, a2 and a third ticket made from c.
mkdir -p "$D6/data/c"; printf 'a brief\n' > "$D6/data/c/brief.md"
rb() { home_env "$D6" env SPAWN_LOG="$D6/spawn.log" JG_AUTO_DISPATCH_SPAWN="$D6/spawn" JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" bash "$CHECK" check "$D6" 2>&1; }
printf '#!/usr/bin/env bash\nexit 1\n' > "$D6/hold"   # no open decision for anyone in this home
out=$(rb) || fail "the first beat failed: $out"
for t in a1 a2 b; do wait_for_result_in "$D6/data/auto-dispatch/$t.start.1" || fail "the start of $t did not record a result"; done
out=$(rb)
assert_contains "$out" "a2 (error: treehouse could not lease a worktree for task a2)" "a refused start names the spawn's real cause to the lead"
assert_contains "$(rows_of "$D6")" "a2	spawn failed	error: treehouse could not lease a worktree for task a2" "the row says failed at once, with the cause"
assert_not_contains "$out" "a1" "a deferral is a wait: the lead is not told about a1"
assert_contains "$(rows_of "$D6")" "a1	deferred	deferred: pool for the project is full; task a1 stays queued" "the row says deferred, with the spawn's own words"
assert_equals "$(JG_HOME="$D6" bash "$ROOT/core/machines/observers/dispatch-start.sh" a1)" deferred "the machine's observer reads a1 as deferred"
assert_equals "$(JG_HOME="$D6" bash "$ROOT/core/machines/observers/dispatch-start.sh" a2)" refused "the machine's observer reads a2 as refused"
assert_equals "$(bash "$ROOT/bin/jg-machine.sh" check dispatch-start | cut -d: -f1)" "ok dispatch-start" "the dispatch-start table lints clean"
pass "a deferral and a refusal are told apart at once, with the spawn's own words"

# The deferral clears with no new approval: while the pool stays full each beat tries a1 again as the next attempt, and the first beat after
# it frees starts it. A refusal is never tried again by itself.
wait_for_result_in "$D6/data/auto-dispatch/a1.start.2" || fail "the second attempt of a1 did not record a result"
assert_contains "$(cat "$D6/data/auto-dispatch/a1.start.2")" "result=deferred" "a1 stays deferred while the pool is full"
rm -f "$D6/spawn-mode-a1"
rb >/dev/null
wait_for_result_in "$D6/data/auto-dispatch/a1.start.3" || fail "the third attempt of a1 did not record a result"
assert_contains "$(cat "$D6/data/auto-dispatch/a1.start.3")" "result=started" "attempt 3 of a1 ended well, with no new approval"
assert_equals "$(grep -c -- '^a1 ' "$D6/spawn.log")" 3 "a1 was spawned once for each attempt"
rb >/dev/null
assert_contains "$(rows_of "$D6")" "a1	started" "a1's row says started"
assert_equals "$(grep -c -- '^a2 ' "$D6/spawn.log")" 1 "a refused start is not tried again by itself"
pass "a deferred start resumes under the same approval; a refused start does not"

# A restart creates no duplicate: further beats, and two runs at once, spawn nothing more for a lane that runs.
for _ in 1 2 3; do rb >/dev/null; done
rb >/dev/null & rb >/dev/null & wait
assert_equals "$(grep -c -- '^a1 ' "$D6/spawn.log")" 3 "a restart and two runs at once start a1 no more"
attempts=("$D6"/data/auto-dispatch/a1.start.[0-9]*)
assert_equals "${#attempts[@]}" 3 "a1 has exactly its three attempts on record"
pass "a restart, and two check runs at once, create no duplicate start"

# A new approval starts a refused ticket again.
sleep 1
rm -f "$D6/spawn-mode-a2"
approve "$D6" a2 >/dev/null || fail "approving a2 again was refused"
rb >/dev/null
wait_for_result_in "$D6/data/auto-dispatch/a2.start.2" || fail "a2 was not started again after a new approval"
assert_contains "$(cat "$D6/data/auto-dispatch/a2.start.2")" "result=started" "a2's second attempt ended well"
pass "a refused start waits for the lead's new approval and then starts"

# The ready state is asked again right before a start: a lane record that is already there (another path started the ticket after
# the list was read) means no spawn. A dead wrapper is settled by the lane record: there is one, it started; none, it failed.
D7=$TMP_ROOT/home-preflight
make_home "$D7"
cp "$D2/spawn" "$D7/spawn"; printf 'on\n' > "$D7/config/auto-dispatch"; printf '6\n' > "$D7/config/lane-target"
printf '#!/usr/bin/env bash\nexit 1\n' > "$D7/hold"
for t in a1 a2 b; do
  approve "$D7" "$t" >/dev/null || fail "approve-dispatch $t was refused"
  mkdir -p "$D7/data/$t"
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  printf 'Delivery contract: mode=local-trunk\n1. First action: create your branch: `git checkout -b feature/%s --`\n' "$t" > "$D7/data/$t/brief.md"
done
printf 'kind=ship\n' > "$D7/state/a1.meta"                      # a1 already runs: the stand-in list still names it
printf 'cleanup_recovery=treehouse\n' > "$D7/state/b.meta"       # b's wrapper died and its record only keeps a failed launch's copy: that is no lane
now=$(date +%s)
mkdir -p "$D7/data/auto-dispatch"
printf 'attempt=1\ntask=a2\napproved-at=%s\nlaunched-at=%s\nroute=claude sonnet medium\n' \
  "$(awk -F= '$1 == "approved-at" { print $2 }' "$D7/state/dispatch-approved/a2")" "$((now - 5000))" > "$D7/data/auto-dispatch/a2.start.1"
printf 'attempt=1\ntask=b\napproved-at=%s\nlaunched-at=%s\nroute=claude sonnet medium\n' \
  "$(awk -F= '$1 == "approved-at" { print $2 }' "$D7/state/dispatch-approved/b")" "$((now - 5000))" > "$D7/data/auto-dispatch/b.start.1"
printf 'kind=ship\n' > "$D7/state/a2.meta"                      # a2's wrapper died after the spawn published the lane
out=$(home_env "$D7" env SPAWN_LOG="$D7/spawn.log" JG_AUTO_DISPATCH_SPAWN="$D7/spawn" JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" bash "$CHECK" check "$D7" 2>&1)
sleep 1
assert_not_contains "$(cat "$D7/spawn.log" 2>/dev/null)" "--ticket a1 " "a lane that already runs is not spawned again"
assert_not_contains "$(cat "$D7/spawn.log" 2>/dev/null)" "--ticket a2 " "a start whose wrapper died after the lane was published is not spawned again"
assert_contains "$(rows_of "$D7")" "a1	started	its lane is already running" "a1's row says its lane already runs"
assert_contains "$(rows_of "$D7")" "a2	started" "a2's row says started: its lane record is there"
assert_contains "$(rows_of "$D7")" "b	spawn failed	the start left no result in 600 seconds" "a dead wrapper whose record is no lane is a failed start"
assert_contains "$out" "b (the start left no result in 600 seconds" "that failed start is named to the lead"
rm -f "$D7/state/a2.meta"
out=$(home_env "$D7" env SPAWN_LOG="$D7/spawn.log" JG_AUTO_DISPATCH_SPAWN="$D7/spawn" JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" bash "$CHECK" check "$D7" 2>&1)
assert_contains "$out" "a2 (the start left no result in 600 seconds" "with the lane record gone, a2's dead wrapper is a failed start"
pass "the lane record settles a start with no result, and a running lane is never spawned again"

# Delivery contract missing: the ticket is named to the lead and not spawned.
D3=$TMP_ROOT/home-nocontract
make_home "$D3"
cp "$D2/spawn" "$D3/spawn"; printf 'on\n' > "$D3/config/auto-dispatch"
approve "$D3" a1 >/dev/null; mkdir -p "$D3/data/a1"; printf 'a brief with no contract\n' > "$D3/data/a1/brief.md"
out=$(home_env "$D3" env SPAWN_LOG="$D3/spawn.log" JG_AUTO_DISPATCH_SPAWN="$D3/spawn" JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" bash "$CHECK" check "$D3" 2>&1)
assert_contains "$out" "a1 (the brief has no delivery contract line)" "a brief with no delivery contract is named to the lead"
assert_absent "$D3/spawn.log" "a brief with no delivery contract is never spawned"
pass "a brief with no delivery contract is not spawned"

# ready-idle: a ticket the check may start, with a free lane, but no start running 10 minutes after its refusal raises the alert
# once, through the real bin/jg-alert.sh and its table's own timer. The same beat 5 minutes in raises nothing.
ra() { home_env "$D3" env JG_STATE_OVERRIDE="$D3/state" JG_AUTO_DISPATCH_ALERT="$ROOT/bin/jg-alert.sh" JG_AUTO_DISPATCH_SPAWN="$D3/spawn" \
  JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" bash "$CHECK" check "$D3" 2>&1; }
out=$(ra)
assert_not_contains "$out" "ready-idle" "a fresh refusal raises no ready-idle alert yet"
old=$(( $(date +%s) - 700 ))
sed -i "s/^[0-9]*\(\ta1\tskipped\)/$old\1/" "$D3/data/auto-dispatch/rows.tsv"
out=$(ra)
assert_contains "$out" "alert ready-idle (P3) at rung 2 for lead: a1" "10 minutes after the refusal the lead gets the ready-idle alert"
assert_equals "$(ra | grep -c 'ready-idle')" 0 "the alert is printed once, not every beat"
pass "an unstarted ticket with a free lane raises ready-idle after 10 minutes, once"

# Free copy: with the switch on, a ticket that passed every other reason starts only while its project has a copy the lane limit
# and the red-fix reserve allow. No copy is a wait (a row, no spawn, nothing for the lead); the next beat with a copy starts it.
D4=$TMP_ROOT/home-copy
make_home "$D4"
cp "$D2/spawn" "$D4/spawn"; printf 'on\n' > "$D4/config/auto-dispatch"
printf '#!/usr/bin/env bash\n[ ! -e "%s/no-copy" ] || { echo "deferred: no copy" >&2; exit 75; }\n' "$D4" > "$D4/reserve"; chmod +x "$D4/reserve"
approve "$D4" a1 >/dev/null; mkdir -p "$D4/data/a1"
# shellcheck disable=SC2016  # the backquotes are the brief's own text
printf 'Delivery contract: mode=local-trunk\n1. First action: create your branch: `git checkout -b feature/a1 --`\n' > "$D4/data/a1/brief.md"
cb() { home_env "$D4" env SPAWN_LOG="$D4/spawn.log" JG_AUTO_DISPATCH_SPAWN="$D4/spawn" JG_AUTO_DISPATCH_RESERVE="$D4/reserve" \
  JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" bash "$CHECK" check "$D4" 2>&1; }
: > "$D4/no-copy"
out=$(cb)
assert_not_contains "$out" "a1" "no free copy: the lead is not told about a1"
assert_absent "$D4/spawn.log" "no free copy: nothing is spawned"
assert_contains "$(rows_of "$D4")" "a1	skipped	no free copy" "no free copy: the row says it waits for a copy"
rm -f "$D4/no-copy"
cb >/dev/null
for n in $(seq 1 50); do [ -s "$D4/spawn.log" ] && break; sleep 0.1; done
assert_contains "$(cat "$D4/spawn.log" 2>/dev/null)" "a1 $D4/projects/proj --ticket a1" "a copy frees: the next beat starts a1 with no lead turn"
assert_contains "$(rows_of "$D4")" "a1	starting" "a1's row says starting"
pass "a ticket starts only when a copy is free under the lane limit and the reserve; no copy is a quiet wait"

# Priority order: the store lists a2 before a1 (a2 is the higher priority), one lane is free. The check starts a2 only, not the
# alphabetically first a1, and a beat after a restart (a new check run with the same rows file) starts nothing more.
D5=$TMP_ROOT/home-order
make_home "$D5"
cp "$D2/spawn" "$D5/spawn"; printf 'on\n' > "$D5/config/auto-dispatch"; printf '1\n' > "$D5/config/lane-target"
python3 - "$D5" <<'PY'
import json, sys
d = sys.argv[1]
for name in ("all.json", "ready.json"):
    rows = json.load(open(d + "/" + name))
    rows.sort(key=lambda r: r["id"] != "a2")   # a2 first, the rest keep their order
    json.dump(rows, open(d + "/" + name, "w"))
t = open(d + "/table.txt").read().splitlines()
a2 = [l for l in t if l.startswith("| a2 ")]
t = [l for l in t if not l.startswith("| a2 ")]
i = next(n for n, l in enumerate(t) if l.startswith("| a1 "))
open(d + "/table.txt", "w").write("\n".join(t[:i] + a2 + t[i:]) + "\n")
PY
for t in a1 a2; do
  approve "$D5" "$t" >/dev/null || fail "approve-dispatch $t was refused"
  mkdir -p "$D5/data/$t"
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  printf 'Delivery contract: mode=local-trunk\n1. First action: create your branch: `git checkout -b feature/%s --`\n' "$t" > "$D5/data/$t/brief.md"
done
ob() { home_env "$D5" env SPAWN_LOG="$D5/spawn.log" JG_AUTO_DISPATCH_SPAWN="$D5/spawn" JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" bash "$CHECK" check "$D5" 2>&1; }
ob >/dev/null
for n in $(seq 1 50); do [ -s "$D5/spawn.log" ] && break; sleep 0.1; done
assert_contains "$(cat "$D5/spawn.log" 2>/dev/null)" "a2 $D5/projects/proj --ticket a2" "the higher-priority a2 starts first"
assert_not_contains "$(cat "$D5/spawn.log")" "--ticket a1 " "a1 does not start: one lane is free"
assert_contains "$(rows_of "$D5")" "a1	skipped	no free lane left for it" "a1 waits for a lane"
ob >/dev/null; ob >/dev/null
assert_equals "$(wc -l < "$D5/spawn.log")" 1 "a restart (a later beat) starts nothing twice"
pass "a priority-ordered queue with one free lane starts exactly the highest ticket; a restart adds no duplicate"
