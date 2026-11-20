#!/usr/bin/env bash
# tests/jg-auto-dispatch-scout.test.sh - the dispatch check (core/auto-dispatch/dispatch.sh) starts a ticket whose brief is a Recon
# brief as a Recon lane (`--scout`, no `--mode`, no `--yolo`), a ship brief as a ship lane as before, and a brief with neither
# contract is still a failed start. The Recon brief is written by the real bin/jg-brief.sh, so a change to its marker line fails here.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Under done-done the run's own capture folder keeps this output and the rows and spawn calls it checked.
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/auto-dispatch-scout.log")

TMP_ROOT=$(jg_test_tmproot jg-auto-dispatch-scout)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
CHECK="$ROOT/core/auto-dispatch/dispatch.sh"

# A home with one registered project and three ready tickets: r (Recon brief), s (ship brief), n (a brief with neither line).
D=$TMP_ROOT/home
mkdir -p "$D/state" "$D/config" "$D/data"
printf -- '- proj [local-trunk] - the one project (added 2026-11-01)\n' > "$D/data/projects.md"
python3 - "$D" <<'PY'
import json, sys
d = sys.argv[1]
with open(d + "/export.jsonl", "w") as out:
    for i in ["r", "s", "n"]:
        out.write(json.dumps({"id": i, "title": "[feature] row " + i, "status": "open", "priority": 1, "issue_type": "task",
                              "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {}}) + "\n")
PY
JG_HOME="$D" python3 "$ROOT/core/item-store/adapters/tickets.py" import --home main "$D/export.jsonl" >/dev/null || fail "the rows did not import"
printf '#!/usr/bin/env bash\nexit 1\n' > "$D/hold"; chmod +x "$D/hold"   # no open decision for anyone
printf '3\n' > "$D/config/lane-target"; printf 'on\n' > "$D/config/auto-dispatch"
touch "$D/state/.last-watcher-beat"

# The spawn stand-in logs its arguments and publishes the lane record, as the real spawn does at its end.
cat > "$D/spawn" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$SPAWN_LOG"
printf 'kind=ship\n' > "$here/state/$1.meta"
SH
chmod +x "$D/spawn"

home_env() { env JG_HOME="$D" JG_AUTO_DISPATCH_HOLD="$D/hold" JG_AUTO_DISPATCH_BACKLOG="$ROOT/bin/jg-backlog.sh" "$@"; }
for t in r s n; do
  home_env "$ROOT/bin/jg-backlog.sh" approve-dispatch "$t" --harness claude --model sonnet --effort medium >/dev/null || fail "approve-dispatch $t was refused"
  mkdir -p "$D/data/$t"
done
# The Recon brief is the real scaffold; the ship brief carries the contract line the check reads; n carries neither.
home_env "$ROOT/bin/jg-brief.sh" r proj --scout --depth quick >/dev/null 2>&1 || fail "jg-brief.sh did not write the Recon brief"
assert_present "$D/data/r/brief.md" "the Recon brief was not written"
# shellcheck disable=SC2016  # the backquotes are the brief's own text
printf 'Delivery contract: mode=local-trunk\n1. First action: create your branch: `git checkout -b feature/s --`\n' > "$D/data/s/brief.md"
printf 'a brief with no contract\n' > "$D/data/n/brief.md"

home_env env SPAWN_LOG="$D/spawn.log" JG_AUTO_DISPATCH_SPAWN="$D/spawn" JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" \
  bash "$CHECK" check "$D" > "$D/out" 2>&1 || fail "the check failed: $(cat "$D/out")"
for _ in $(seq 1 100); do [ "$(wc -l < "$D/spawn.log" 2>/dev/null || echo 0)" -ge 2 ] && break; sleep 0.1; done
for _ in $(seq 1 100); do [ -f "$D/data/auto-dispatch/r.start.1" ] && grep -q '^result=' "$D/data/auto-dispatch/r.start.1" && break; sleep 0.1; done
spawned=$(cat "$D/spawn.log")
rows=$(cat "$D/data/auto-dispatch/rows.tsv")

[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || { cp "$D/data/auto-dispatch/rows.tsv" "$DONE_DONE_EVIDENCE_ROOT/auto-dispatch-scout-rows.tsv"; cp "$D/spawn.log" "$DONE_DONE_EVIDENCE_ROOT/auto-dispatch-scout-spawn-calls.log"; }

# T1 a Recon brief starts a Recon lane.
r_call=$(grep -- '--ticket r ' <<< "$spawned")
assert_contains "$r_call" "r $D/projects/proj --ticket r --scout --harness claude --model sonnet --effort medium" "T1: the Recon ticket is spawned with --scout and its route"
assert_not_contains "$r_call" " --mode " "T1: a Recon spawn carries no --mode"
assert_not_contains "$r_call" " --yolo " "T1: a Recon spawn carries no --yolo"
assert_not_contains "$r_call" "--branch-prefix" "T1: a Recon spawn carries no branch prefix"
assert_contains "$rows" "r	starting	claude sonnet medium" "T1: the Recon ticket's row says starting"
pass "T1: a Recon brief starts a Recon lane, with no mode, no yolo and no branch prefix"

# T2 a ship brief starts as today.
assert_contains "$spawned" "s $D/projects/proj --ticket s --mode local-trunk --yolo off --branch-prefix feature/ --harness claude --model sonnet --effort medium" "T2: the ship ticket keeps --mode and --yolo"
assert_not_contains "$(grep -- '--ticket s ' <<< "$spawned")" "--scout" "T2: a ship spawn is no Recon"
pass "T2: a ship brief starts as a ship lane, as before"

# T3 a brief with neither line is a failed start, named to the lead.
assert_not_contains "$spawned" "--ticket n " "T3: a brief with neither line is never spawned"
assert_contains "$rows" "n	skipped	the brief has no delivery contract line" "T3: the row names the missing delivery contract line, as today"
assert_contains "$(cat "$D/out")" "n (the brief has no delivery contract line)" "T3: the lead is told once"
pass "T3: a brief with neither line is a failed start, as before"
