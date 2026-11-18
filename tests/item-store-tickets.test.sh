#!/usr/bin/env bash
# The ticket tables of the one item store: import, ready, the copy written beside Beads by bin/jg-backlog.sh, the daily
# compare, and the one-id-one-home rule. A stand-in bd keeps rows in a file and answers the calls the write verbs make.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FX=$ROOT/tests/fixtures/item-store-tickets
TK=$ROOT/core/item-store/adapters/tickets.py
T=$(jg_test_tmproot item-store-tickets)
sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
mkdir -p "$T/bin" "$T/home/config" "$T/home/data" "$T/home/state" "$T/store/.beads/embeddeddolt/jg"
printf '{"dolt_mode": "embedded", "dolt_database": "jg"}\n' > "$T/store/.beads/metadata.json"
printf 'no-git-ops: true\n' > "$T/store/.beads/config.yaml"
cat > "$T/stub.py" <<'PY'
import json, sys
path = __import__("os").environ["ROWS"]
rows = {r["id"]: r for r in (json.loads(l) for l in open(path) if l.strip())}
a = sys.argv[1:]
def save():
    open(path, "w").write("".join(json.dumps(r) + "\n" for r in rows.values()))
def opt(name, many=False):
    got = [a[i + 1] for i, x in enumerate(a) if x == name and i + 1 < len(a)]
    return got if many else (got[0] if got else None)
cmd = a[0] if a else ""
if cmd == "export":
    sys.stdout.write("".join(json.dumps(r) + "\n" for r in rows.values()))
elif cmd == "list":
    print(json.dumps(list(rows.values())))
elif cmd in ("ready", "blocked"):
    print("[]")
elif cmd == "create":
    t = next(x[8:] for x in a if x.startswith("--title="))
    i = opt("--id")
    r = dict(id=i, title=t, status="open", priority=int(opt("-p") or 2), issue_type="task", created_at="2026-11-12T00:00:00Z",
             labels=opt("-l", True), metadata=json.loads(opt("--metadata") or "{}"), description=next((x[14:] for x in a if x.startswith("--description=")), ""))
    if opt("--external-ref"): r["external_ref"] = opt("--external-ref")
    rows[i] = r; save()
elif cmd == "update":
    r = rows[a[1]]
    if opt("--status"): r["status"] = opt("--status")
    if opt("-a") is not None: r["assignee"] = opt("-a") or None
    if opt("--defer") is not None: r["defer_until"] = opt("--defer") or None
    for x in a:
        if x.startswith("--title="): r["title"] = x[8:]
        if x.startswith("--description="): r["description"] = x[14:]
    for kv in opt("--set-metadata", True):
        k, _, v = kv.partition("="); r.setdefault("metadata", {})[k] = v
    for k in opt("--unset-metadata", True): r.get("metadata", {}).pop(k, None)
    for l in opt("--add-label", True): r.setdefault("labels", []).append(l)
    if opt("-p"): r["priority"] = int(opt("-p"))
    if opt("--external-ref"): r["external_ref"] = opt("--external-ref")
    save()
elif cmd == "dep" and a[1] == "add":
    rows[a[2]].setdefault("dependencies", []).append({"issue_id": a[2], "depends_on_id": a[3], "type": opt("--type") or "blocks"}); save()
elif cmd == "dep" and a[1] == "remove":
    rows[a[2]]["dependencies"] = [d for d in rows[a[2]].get("dependencies", []) if d["depends_on_id"] != a[3]]; save()
PY
printf '#!/usr/bin/env bash\nexec python3 "%s" "$@"\n' "$T/stub.py" > "$T/bin/bd"
{ cat "$T/bin/bd"; printf '# dolt\n'; } > "$T/bin/dolt"
chmod +x "$T"/bin/*
os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
printf 'bd 1.3.4\ndolt 2.6.0\nbd-sha256-%s-%s %s\ndolt-sha256-%s-%s %s\n' \
  "$os" "$arch" "$(sha_of "$T/bin/bd")" "$os" "$arch" "$(sha_of "$T/bin/dolt")" > "$T/pins"
printf '%s\n' "$T/store/.beads" > "$T/home/config/beads-dir"
: > "$T/home/config/backlog-intake-loose"
# A version-manager shim of python3 reads the caller's own config and breaks under a throwaway HOME: run the real interpreter.
mkdir -p "$T/py"; for _py in /usr/bin/python3 /usr/local/bin/python3 "$(command -v python3)"; do [ -x "$_py" ] && { ln -sf "$_py" "$T/py/python3"; break; }; done
export PATH=$T/py:$PATH
export JG_PIN_FILE_OVERRIDE=$T/pins ROWS=$T/rows.jsonl JG_BEADS_BD=$T/bin/bd JG_BEADS_DOLT=$T/bin/dolt
export JG_HOME=$T/home JG_DATA_OVERRIDE=$T/home/data JG_STATE_OVERRIDE=$T/home/state BEADS_ACTOR=main
unset JG_TASK_ID JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_ROOT_OVERRIDE
cp "$FX/export.jsonl" "$ROWS"
BL="$ROOT/bin/jg-backlog.sh"
DB=$T/home/state/item-store/fleet.db
sql() { python3 -c 'import sqlite3,sys; [print("|".join(map(str,r))) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])]' "$DB" "$1"; }

# --- import, ready
out=$(python3 "$TK" import --home main "$FX/export.jsonl"); expect_code 0 $? "import loads the fixture"
[ "$(sql 'SELECT count(*) FROM ticket')" = 11 ] || fail "import: 11 tickets expected, got $(sql 'SELECT count(*) FROM ticket')"
[ "$(sql 'SELECT count(*) FROM link')" = 3 ] || fail "import: one link of each type expected"
[ "$(sql "SELECT external_ref FROM ticket WHERE id='jg-pr'")" = https://github.com/o/r/pull/7 ] || fail "import keeps external_ref"
[ "$(python3 "$TK" ready --now 2026-11-20T00:00:00Z)" = "$(cat "$FX/ready.expected")" ] || fail "ready differs from the recorded bd ready ids: $(python3 "$TK" ready --now 2026-11-20T00:00:00Z | tr '\n' ' ')"
pass "import and ready: the past-date deferred row is in; the future one, the gate and the ephemeral row are out"
python3 "$TK" compare "$FX/export.jsonl" >/dev/null; expect_code 0 $? "compare of a fresh import is empty"
[ "$(sql "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('ticket','link','ticket_change')")" = 3 ] || fail "three ticket tables"
pass "import then compare: no difference"

# --- every write verb through jg-backlog.sh leaves compare empty
: > "$T/home/config/one-engine"
step() { local what=$1; shift; out=$("$BL" "$@" 2>&1); expect_code 0 $? "$what: $out"
  case $out in *"one-engine copy"*) fail "$what: the copy failed: $out" ;; esac
  c=$(JG_HOME=$JG_HOME "$BL" compare 2>&1); expect_code 0 $? "$what: compare lists: $c"; }
step add add jg-new "A new ticket" --priority 1 --repo p --kind feature --release later --body "Captain: x"
step update update jg-new --title "A renamed ticket" --body "Captain: y"
step hold hold jg-new --reason "waits on the owner"
step unhold unhold jg-new
step start start jg-new
step reopen reopen jg-new
step block block jg-new --by jg-ready1
step unblock unblock jg-new --by jg-ready1
step task task jg-new
step "done" "done" jg-new --pr https://github.com/o/r/pull/9
[ "$(sql "SELECT count(*) FROM ticket_change WHERE id='jg-new'")" -ge 8 ] || fail "each write is a row of the log"
[ "$(sql "SELECT status FROM ticket WHERE id='jg-new'")" = closed ] || fail "the copy followed the ticket to closed"
pass "each write verb leaves compare empty (add update hold unhold start reopen block unblock task done)"

# --- a difference in one copy only: one line each
cp "$ROWS" "$T/rows.good"
python3 - "$ROWS" <<'PY'
import json, sys
p = sys.argv[1]; rows = [json.loads(l) for l in open(p)]
for r in rows:
    if r["id"] == "jg-ready1": r["title"] = "moved only in beads"; r["labels"].append("upkeep"); r["metadata"]["hold_reason"] = "x"
    if r["id"] == "jg-rel": r["dependencies"] = []
open(p, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
out=$("$BL" compare 2>&1); expect_code 1 $? "compare exits 1 on a difference"
assert_contains "$out" 'jg-ready1 title beads="moved only in beads" copy="row ready1"' "a changed field is listed"
assert_contains "$out" 'jg-ready1 labels beads=["project:p", "upkeep"] copy=["project:p"]' "a changed label set is listed"
assert_contains "$out" 'jg-ready1 metadata.hold_reason beads="x" copy=null' "a changed metadata key is listed"
assert_contains "$out" 'jg-rel link beads=null copy="jg-rel>jg-ready1:related"' "a link in the copy only is listed"
[ "$(printf '%s\n' "$out" | wc -l)" = 4 ] || fail "one line per difference, 4 expected: $out"
cp "$T/rows.good" "$ROWS"
python3 - "$DB" <<'PY'     # the other direction: a change in the copy only
import sqlite3, sys, json, time
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO ticket_change(at,home,id,verb,source,row,links) VALUES(?,?,?,?,?,?,?)",
          (int(time.time()), "main", "jg-gate", "test", "t:1", json.dumps({"title": "owner question", "description": "Captain: x", "priority": 2, "issue_type": "gate", "created_at": "2026-11-07T00:00:00Z", "status": "open", "labels": "[\"project:p\",\"extra\"]", "metadata": "{\"ask_role\": \"owner\"}", "ephemeral": 0}), "[]"))
c.commit()
PY
out=$("$BL" compare 2>&1); expect_code 1 $? "compare sees a copy-only change"
assert_contains "$out" 'jg-gate labels beads=["project:p"] copy=["extra", "project:p"]' "a label in the copy only is listed"
pass "compare lists each field, label, metadata key and link that differs in one copy, one line each"

# --- one id, one home
cp "$FX/export.jsonl" "$T/other.jsonl"
before=$(sql 'SELECT count(*) FROM ticket_change')
out=$(python3 "$TK" import --home crewhouse "$T/other.jsonl"); expect_code 1 $? "a second import under another home exits 1"
assert_contains "$out" 'import: jg-ready1 is in main and crewhouse' "it names each id with both homes"
[ "$(printf '%s\n' "$out" | wc -l)" = 11 ] || fail "one line per shared id"
[ "$(sql 'SELECT count(*) FROM ticket_change')" = "$before" ] || fail "a refused import wrote rows"
python3 "$TK" import --home crewhouse <(sed -n 1p "$T/other.jsonl" | sed 's/jg-ready1/jg-other1/') >/dev/null; expect_code 0 $? "a fresh id imports under another home"
[ "$(sql "SELECT home FROM ticket WHERE id='jg-other1'")" = crewhouse ] || fail "ticket.home records the home"
printf '%s\n' '{"id":"jg-other1","title":"same id","status":"open","priority":2,"issue_type":"task","created_at":"2026-11-12T00:00:00Z"}' >> "$ROWS"
out=$(python3 "$TK" write add jg-other1 --source t:2); expect_code 1 $? "a create of an id another home holds is refused"
assert_contains "$out" 'jg-other1 is in crewhouse, not main' "the refusal names both homes"
pass "one id names one ticket: a shared id stops an import and a create, and writes nothing"

# --- the store's audit: the ticket tables are known, a stray table is not
audit() { python3 - "$ROOT/core/item-store" "$T/home" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import itemdb
st = itemdb.open_db(sys.argv[2], "tick"); print(len(st.audit(itemdb.stamp(st))))
PY
}
[ "$(audit)" = 0 ] || fail "the audit finds the ticket tables a difference"
python3 -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute("CREATE TABLE stray(x)")' "$DB"
[ "$(audit)" = 1 ] || fail "an extra table that neither file defines must fail the audit"
jg_item() { (cd "$T/home" && JG_HOME="$T/home" python3 "$ROOT/core/item-store/jg-item" schema-check >/dev/null 2>&1); }
jg_item; expect_code 1 $? "jg-item schema-check also fails on a stray table"
python3 -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute("DROP TABLE stray")' "$DB"
jg_item; expect_code 0 $? "jg-item schema-check passes with the ticket tables"
pass "audit: the ticket tables pass, a stray table still fails"
