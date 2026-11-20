#!/usr/bin/env bash
# The startable set is answered from the tickets tables: a store holding 60,000 rows gives it through the real
# caller (`jg-backlog.sh ready --spawnable`) under 1 second, 20 runs (median under 1 second, slowest under 2), and the answer is right at that size:
# only the startable ticket comes back; a held one, an assigned one, one linked to an open decision card, one a live
# lane holds and one of an unregistered project are left out.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/spawnable-scale.log")

T=$(jg_test_tmproot jg-spawnable-scale)
H=$T/home
mkdir -p "$H/config" "$H/data" "$H/state"
printf '%s\n' "$T/store" > "$H/config/beads-dir"   # kept until bin/jg-backlog-lib.sh stops asking for a store path
: > "$H/config/one-engine-read"   # kept until bin/jg-backlog-spawnable.sh reads the tables without it
printf -- '- demo [local-trunk] - the registered project (added 2026-11-01)\n' > "$H/data/projects.md"
spawnable() { (cd "$H" && JG_HOME="$H" "$ROOT/bin/jg-backlog.sh" ready --spawnable); }
seed() {  # <bulk row count>: the six small-board rows, the open decision card, and that many bulk rows, imported into the tables
  python3 - "$1" > "$T/rows.jsonl" <<'PY'
import json, sys
def row(i, **kw):
    r = {"id": i, "title": "ticket " + i, "status": "open", "priority": 1, "issue_type": "task", "created_at": "2026-11-01T00:00:00Z",
         "labels": ["project:demo"], "metadata": {}}
    r.update(kw); return json.dumps(r)
print(row("jg-go")); print(row("jg-held", metadata={"hold_reason": "waiting for the owner"})); print(row("jg-taken", assignee="someone"))
print(row("jg-linked", dependencies=[{"issue_id": "jg-linked", "depends_on_id": "jg-card", "type": "blocks"}]))
print(row("jg-card", issue_type="decision", labels=[])); print(row("jg-lane")); print(row("jg-other", labels=["project:elsewhere"]))
# Closed history, one open row in 20 already taken by a lane, and a dependency edge per 10 rows.
for i in range(1, int(sys.argv[1]) + 1):
    taken = i % 20 == 0
    deps = [{"issue_id": "bulk-%d" % i, "depends_on_id": "bulk-%d" % (i + 1), "type": "blocks"}] if i % 10 == 0 and i < int(sys.argv[1]) else []
    print(row("bulk-%d" % i, status="in_progress" if taken else "closed", assignee="lane" if taken else None,
              labels=["project:demo"] if taken else [], dependencies=deps, **({} if taken else {"closed_at": "2026-11-02T00:00:00Z"})))
PY
  JG_HOME="$H" python3 "$ROOT/core/item-store/adapters/tickets.py" import --home main "$T/rows.jsonl" >/dev/null || fail "could not import $1 bulk rows"
}

seed 0
printf 'kind=ship\n' > "$H/state/jg-lane.meta"
out=$(spawnable) || fail "the small board did not read: $out"
assert_contains "$out" "jg-go" "the startable ticket is listed"
for id in jg-held jg-taken jg-linked jg-lane jg-other; do assert_not_contains "$out" "$id" "$id is left out"; done

# Grow the store to 60,000 rows.
seed 60000
rows=$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT count(*) FROM ticket").fetchone()[0])' "$H/state/item-store/fleet.db")
[ "$rows" -ge 60000 ] || fail "the store holds $rows rows, not 60,000"

out=$(spawnable) || fail "the 60,000-row store did not read: $out"
assert_contains "$out" "count: 1" "at $rows rows exactly one ticket can start"
assert_contains "$out" "jg-go" "the startable ticket is still listed"

# 20 runs in a row: the median under 1 second and the slowest under 2. The bound is a median because the host is shared.
times=()
for run in $(seq 1 20); do
  s=$(date +%s%N); spawnable >/dev/null || fail "run $run failed"; ms=$(( ($(date +%s%N) - s) / 1000000 ))
  times+=("$ms")
  [ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || printf 'run %s: %s ms\n' "$run" "$ms" >> "$DONE_DONE_EVIDENCE_ROOT/startable-set.txt"
done
mapfile -t sorted < <(printf '%s\n' "${times[@]}" | sort -n)
median=$(( (sorted[9] + sorted[10]) / 2 )) slowest=${sorted[19]}
[ "$median" -lt 1000 ] || fail "the median of 20 runs was $median ms at $rows rows, not under 1000"
[ "$slowest" -lt 2000 ] || fail "the slowest of 20 runs was $slowest ms at $rows rows, not under 2000"
pass "at $rows rows the startable set ends in a median of $median ms and at most $slowest ms over 20 runs, and names only the startable ticket"
