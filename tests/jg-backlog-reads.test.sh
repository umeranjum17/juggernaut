#!/usr/bin/env bash
# Backlog reads stay small: a show fetches one row, a plain list asks the tables for open rows only, history stays one flag away,
# and the reads of one cycle share one whole-store read. The rows are imported into the tickets tables, and a python3 on PATH logs
# each bd call that reaches bd_compat.py before it runs.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-backlog-reads)
mkdir -p "$T/bin" "$T/config" "$T/state"
py=$(python3 -c 'import sys; print(sys.executable)')   # the real interpreter: a version-manager shim would find this one again
# shellcheck disable=SC2016  # the stand-in expands its own variables when it runs
printf '#!/usr/bin/env bash\ncase "${2:-}" in */bd_compat.py) printf "%%s\\n" "${*:3}" >> "$LOG" ;; esac\nexec %q "$@"\n' "$py" > "$T/bin/python3"
chmod +x "$T/bin/python3"
cat > "$T/rows.jsonl" <<'JSON'
{"id":"jg-open","title":"open one","status":"open","created_at":"2026-11-01T00:00:00Z","dependencies":[{"issue_id":"jg-open","depends_on_id":"jg-gone","type":"blocks"}],"labels":["project:p"]}
{"id":"jg-gone","title":"finished one","status":"closed","created_at":"2026-10-01T00:00:00Z","closed_at":"2026-10-02T00:00:00Z","labels":["project:p"]}
JSON
export JG_HOME=$T JG_STATE_OVERRIDE=$T/state LOG=$T/call.log PATH=$T/bin:$PATH
python3 "$ROOT/core/item-store/adapters/tickets.py" import --home main "$T/rows.jsonl" >/dev/null || fail "the rows did not import"
unset JG_BACKLOG_SNAPSHOT
# shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
. "$ROOT/bin/jg-backlog-lib.sh"
read_backlog() { : > "$LOG"; jg_backlog_beads_read "$T/config" "$@"; }

out=$(read_backlog show jg-open --full)
assert_contains "$out" 'blocked: no' "a closed blocker does not block the shown row"
assert_contains "$out" 'title: open one' "show prints the row"
if [ "$(grep -c '^show ' "$LOG")" != 1 ] || grep -q '^list' "$LOG"; then fail "show read more than its one row: $(cat "$LOG")"; fi

out=$(read_backlog list)
assert_contains "$out" 'jg-open' "the plain list shows the open row"
assert_not_contains "$out" 'jg-gone' "the plain list leaves the closed row out"
grep -q -- '--all' "$LOG" && fail "the plain list read the whole store: $(cat "$LOG")"

assert_contains "$(read_backlog list --state 'done')" 'jg-gone' "--state done reads closed history"
assert_contains "$(read_backlog list --all)" 'jg-gone' "--all reads closed history"
grep -q -- '--all' "$LOG" || fail "explicit history skipped the whole-store read"
assert_contains "$(read_backlog show jg-gone)" 'state: done' "a closed row stays readable by id"

out=$(read_backlog show jg-nope 2>&1); code=$?
expect_code 1 "$code" "an unknown id refuses"
assert_contains "$out" 'not found' "an unknown id says so"

: > "$LOG"
export JG_BACKLOG_SNAPSHOT=$T/snap.json
for verb in "list --state queued" "list --state done" "ready" "markdown"; do read -ra argv <<<"$verb"; jg_backlog_beads_read "$T/config" "${argv[@]}" >/dev/null; done
[ "$(grep -c -- '--all' "$LOG")" = 1 ] || fail "a cycle read the whole store more than once: $(cat "$LOG")"
assert_not_contains "$(jg_backlog_beads_read "$T/config" list)" 'jg-gone' "a snapshot list still leaves closed rows out"
pass "backlog reads: one-row show, open-only list, explicit history, one snapshot read per cycle"
