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
