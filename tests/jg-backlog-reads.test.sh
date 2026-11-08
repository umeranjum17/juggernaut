#!/usr/bin/env bash
# Backlog reads stay small: a show fetches one row, a plain list asks bd for open rows only, history stays one flag away,
# and the reads of one cycle share one whole-store read. A stand-in bd serves seeded rows and logs every call.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-backlog-reads)
sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
mkdir -p "$T/bin" "$T/config" "$T/store/.beads/embeddeddolt/jg"
printf '{"dolt_mode": "embedded", "dolt_database": "jg"}\n' > "$T/store/.beads/metadata.json"
printf 'no-git-ops: true\n' > "$T/store/.beads/config.yaml"
cat > "$T/bin/bd" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG"
case "$1" in
  list) case " $* " in *" --all "*) cat "$ROWS" ;; *) python3 -c 'import json,sys; print(json.dumps([r for r in json.load(open(sys.argv[1])) if r["status"]!="closed"]))' "$ROWS" ;; esac ;;
  show) python3 -c 'import json,sys; rows={r["id"]:r for r in json.load(open(sys.argv[1]))}; r=dict(rows[sys.argv[2]]); r["dependencies"]=[{"id":d["depends_on_id"],"status":rows[d["depends_on_id"]]["status"],"dependency_type":d["type"]} for d in r.get("dependencies",[])]; print(json.dumps([r]))' "$ROWS" "$2" ;;
  blocked|ready) echo '[]' ;;
esac
SH
{ cat "$T/bin/bd"; printf '# dolt\n'; } > "$T/bin/dolt"
chmod +x "$T"/bin/*
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
printf 'bd 1.3.4\ndolt 2.6.0\nbd-sha256-%s-%s %s\ndolt-sha256-%s-%s %s\n' \
  "$os" "$arch" "$(sha_of "$T/bin/bd")" "$os" "$arch" "$(sha_of "$T/bin/dolt")" > "$T/pins"
printf '%s\n' "$T/store/.beads" > "$T/config/beads-dir"
cat > "$T/rows.json" <<'JSON'
[{"id":"jg-open","title":"open one","status":"open","created_at":"2026-11-01T00:00:00Z","dependencies":[{"depends_on_id":"jg-gone","type":"blocks"}],"labels":["project:p"]},
 {"id":"jg-gone","title":"finished one","status":"closed","created_at":"2026-10-01T00:00:00Z","closed_at":"2026-10-02T00:00:00Z","labels":["project:p"]}]
JSON
export JG_PIN_FILE_OVERRIDE=$T/pins LOG=$T/call.log ROWS=$T/rows.json JG_BEADS_BD=$T/bin/bd JG_BEADS_DOLT=$T/bin/dolt
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
