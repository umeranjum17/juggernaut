#!/usr/bin/env bash
# The startable set is answered from the store's indexes: a real store holding 60,000 rows gives it through the real
# caller (`jg-backlog.sh ready --spawnable`) under 1 second, 20 runs (median under 1 second, slowest under 2), and the answer is right at that size:
# only the startable ticket comes back; a held one, an assigned one, one linked to an open decision card, one a live
# lane holds and one of an unregistered project are left out. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/spawnable-scale.log")

T=$(jg_test_tmproot jg-spawnable-scale)
H=$T/home
jg_test_beads_home "$H"
printf -- '- demo [local-trunk] - the registered project (added 2026-11-01)\n' > "$H/data/projects.md"
mkdir -p "$H/state"
spawnable() { (cd "$H" && JG_HOME="$H" "$ROOT/bin/jg-backlog.sh" ready --spawnable); }

# Real rows through the real writer: one startable ticket and the five that must stay out.
for id in jg-go jg-held jg-taken jg-linked jg-lane jg-other; do
  repo=demo; [ "$id" = jg-other ] && repo=elsewhere
  jg_test_add "$H" "$id" "[feature] ticket $id" --repo "$repo"
done
jg_test_backlog "$H" hold jg-held --reason "waiting for the owner" >/dev/null 2>&1 || fail "could not hold jg-held"
store=$(tr -d '[:space:]' < "$H/config/beads-dir")
sql() { BEADS_DIR=$store "$ROOT/bin/jg-beads.sh" dolt sql -q "$1"; }
# The writer has no assignee flag and no way to place a decision card; the store's own tables take both.
sql "UPDATE issues SET assignee = 'someone' WHERE id = 'jg-taken';
     INSERT INTO issues (id, title, description, design, acceptance_criteria, notes, issue_type)
       VALUES ('jg-card', 'open decision', '', '', '', '', 'decision');
     INSERT INTO dependencies (id, issue_id, type, created_by, depends_on_issue_id)
       VALUES (UUID(), 'jg-linked', 'blocks', 'test', 'jg-card');" >/dev/null 2>"$T/seed.err" || fail "could not place the card: $(head -c 300 "$T/seed.err")"
printf 'kind=ship\n' > "$H/state/jg-lane.meta"
out=$(spawnable) || fail "the small board did not read: $out"
assert_contains "$out" "jg-go" "the startable ticket is listed"
for id in jg-held jg-taken jg-linked jg-lane jg-other; do assert_not_contains "$out" "$id" "$id is left out"; done

# Grow the store to 60,000 rows: closed history, 3,000 open rows already taken by lanes, and a dependency edge per 10 rows.
# Dolt takes no WITH inside an INSERT, so the numbers 1 to 60,000 come from five digit tables joined.
digit='(SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)'
nums="(SELECT a.n + 10 * b.n + 100 * c.n + 1000 * d.n + 10000 * e.n + 1 AS i FROM $digit a, $digit b, $digit c, $digit d, $digit e) x"
sql "
INSERT INTO issues (id, title, description, design, acceptance_criteria, notes, status, assignee, closed_at)
  SELECT CONCAT('bulk-', i), CONCAT('bulk row ', i), '', '', '', '',
         IF(i % 20 = 0, 'in_progress', 'closed'), IF(i % 20 = 0, 'lane', NULL), IF(i % 20 = 0, NULL, NOW()) FROM $nums WHERE i <= 60000;
INSERT INTO labels (issue_id, label) SELECT id, 'project:demo' FROM issues WHERE id LIKE 'bulk-%' AND status = 'in_progress';
INSERT INTO dependencies (id, issue_id, type, created_by, depends_on_issue_id)
  SELECT UUID(), CONCAT('bulk-', i), 'blocks', 'test', CONCAT('bulk-', i + 1) FROM $nums WHERE i % 10 = 0 AND i < 60000;
" >/dev/null 2>"$T/seed.err" || fail "could not seed 60,000 rows: $(head -c 400 "$T/seed.err")"
rows=$(sql "SELECT COUNT(*) FROM issues" | grep -Eo '[0-9]+' | tail -1)
[ "$rows" -ge 60000 ] || fail "the store holds $rows rows, not 60,000"

out=$(spawnable) || fail "the 60,000-row store did not read: $out"
assert_contains "$out" "count: 1" "at $rows rows exactly one ticket can start"
assert_contains "$out" "jg-go" "the startable ticket is still listed"

# 20 runs in a row: the median under 1 second and the slowest under 2. The bound is a median because the host is shared:
# at a load of 50 to 70, a bare `select 1` through bin/jg-beads.sh (dolt start-up and the pin hash) costs 530 to 650 ms, and
# 3 of 5 sealed runs saw one run in 20 pass 1 s (1023, 1102, 1183 ms). Measured at 60,007 rows: slowest of 20 runs 360 to
# 632 ms when it passed; median about 400 to 500 ms. On the real 5.9k-row store the old two whole-board reads took 2.3 s.
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
