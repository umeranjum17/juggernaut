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
  { cat "$d/bin/bd"; printf '# dolt\n'; } > "$d/bin/dolt"
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
    ROWS_READY="$d/ready.json" ROWS_ALL="$d/all.json" JG_AUTO_DISPATCH_HOLD="$d/hold" \
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
cat > "$D2/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SPAWN_LOG"
SH
chmod +x "$D2/spawn"
for t in a1 a2 b c e; do approve "$D2" "$t" >/dev/null || fail "approve-dispatch $t was refused"; done
for t in a1 a2 b e d; do
  mkdir -p "$D2/data/$t"
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  printf 'Delivery contract: mode=local-trunk\n1. First action: create your branch: `git checkout -b feature/%s --`\n' "$t" > "$D2/data/$t/brief.md"
done
mkdir -p "$D2/data/c"
on_beat() { home_env "$D2" env SPAWN_LOG="$D2/spawn.log" JG_AUTO_DISPATCH_SPAWN="$D2/spawn" JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" "$@" bash "$CHECK" check "$D2" 2>&1; }
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
assert_contains "$rows" "a1	started	claude sonnet medium" "a1's row says started"
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || { cp "$D2/data/auto-dispatch/rows.tsv" "$DONE_DONE_EVIDENCE_ROOT/auto-dispatch-on-rows.tsv"; cp "$D2/spawn.log" "$DONE_DONE_EVIDENCE_ROOT/auto-dispatch-spawn-calls.log"; }
pass "switch on: two approved tickets are spawned with their route; the rest are never spawned and the lead hears once"

# A second beat spawns nothing again and says nothing again.
out=$(on_beat) || fail "second beat failed: $out"
assert_equals "$out" "" "a second beat tells the lead nothing new"
assert_equals "$(wc -l < "$D2/spawn.log")" 2 "a second beat spawns nothing: the starts are in flight"
pass "an unchanged beat neither spawns again nor names the same tickets again"

# A start that leaves no lane record is a failed start: named once, not retried until the lead approves again.
out=$(on_beat JG_AUTO_DISPATCH_IN_FLIGHT=0) || fail "failed-start beat failed: $out"
assert_contains "$out" "a1 (no lane record after 0 seconds" "a start with no lane record is named to the lead"
assert_contains "$(rows_of "$D2")" "a1	spawn failed	no lane record" "a1's row says the start failed"
out=$(on_beat JG_AUTO_DISPATCH_IN_FLIGHT=0) || fail "beat after a failed start failed: $out"
assert_equals "$out" "" "a failed start is named once"
assert_equals "$(wc -l < "$D2/spawn.log")" 2 "a failed start is not tried again by itself"
sleep 1
approve "$D2" a1 >/dev/null || fail "approving a1 again was refused"
on_beat >/dev/null
wait_for_spawns 3 || fail "a1 was not spawned again after a new approval"
pass "a failed start waits for the lead's new approval"

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
