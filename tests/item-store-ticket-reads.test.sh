#!/usr/bin/env bash
# One engine, read phase: with the main home's config/one-engine-read every read verb of bin/jg-backlog.sh answers from the ticket
# tables in the text Beads gives, each read also asks Beads, and a different answer opens one intake item on Main. A stand-in bd
# keeps rows in a file (the same fixture as tests/item-store-tickets.test.sh) and answers ready and blocked as bd does.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FX=$ROOT/tests/fixtures/item-store-tickets
TK=$ROOT/core/item-store/adapters/tickets.py
T=$(jg_test_tmproot item-store-ticket-reads)
sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
mkdir -p "$T/bin" "$T/home/config" "$T/home/data" "$T/home/state" "$T/store/.beads/embeddeddolt/jg"
printf '{"dolt_mode": "embedded", "dolt_database": "jg"}\n' > "$T/store/.beads/metadata.json"
printf 'no-git-ops: true\n' > "$T/store/.beads/config.yaml"
cat > "$T/stub.py" <<'PY'
import json, os, sys
rows = [json.loads(l) for l in open(os.environ["ROWS"]) if l.strip()]
by = {r["id"]: r for r in rows}
a = sys.argv[1:]
def opt(name):
    return next((a[i + 1] for i, x in enumerate(a) if x == name and i + 1 < len(a)), None)
def blockers(r):
    return [d["depends_on_id"] for d in r.get("dependencies", []) if d["type"] == "blocks" and by.get(d["depends_on_id"], {}).get("status") != "closed"]
cmd = a[0] if a else ""
if cmd in ("list", "export"):
    if cmd == "export":      # bd export keeps every row; bd list leaves an ephemeral wisp out unless asked
        sys.stdout.write("".join(json.dumps(r) + "\n" for r in rows))
    else:
        print(json.dumps([r for r in rows if not r.get("ephemeral")]))
elif cmd == "ready":         # bd ready: the ids of the recorded answer, by the label asked for
    want = opt("--label")
    ids = open(os.environ["READY"]).read().split()
    print(json.dumps([{"id": i} for i in ids if want is None or want in by[i].get("labels", [])]))
elif cmd == "blocked":
    print(json.dumps([{"id": r["id"], "blocked_by": blockers(r)} for r in rows if blockers(r) and r.get("status") != "closed"]))
PY
printf '#!/usr/bin/env bash\nexec python3 "%s" "$@"\n' "$T/stub.py" > "$T/bin/bd"
{ cat "$T/bin/bd"; printf '# dolt\n'; } > "$T/bin/dolt"
chmod +x "$T"/bin/*
os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
printf 'bd 1.3.4\ndolt 2.6.0\nbd-sha256-%s-%s %s\ndolt-sha256-%s-%s %s\n' \
  "$os" "$arch" "$(sha_of "$T/bin/bd")" "$os" "$arch" "$(sha_of "$T/bin/dolt")" > "$T/pins"
printf '%s\n' "$T/store/.beads" > "$T/home/config/beads-dir"
: > "$T/home/config/backlog-intake-loose"
mkdir -p "$T/py"; for _py in /usr/bin/python3 /usr/local/bin/python3 "$(command -v python3)"; do [ -x "$_py" ] && { ln -sf "$_py" "$T/py/python3"; break; }; done
export PATH=$T/py:$PATH
export JG_PIN_FILE_OVERRIDE=$T/pins ROWS=$T/rows.jsonl READY=$FX/ready.expected JG_BEADS_BD=$T/bin/bd JG_BEADS_DOLT=$T/bin/dolt
export JG_HOME=$T/home JG_DATA_OVERRIDE=$T/home/data JG_STATE_OVERRIDE=$T/home/state BEADS_ACTOR=main
unset JG_TASK_ID JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_ROOT_OVERRIDE JG_BACKLOG_SNAPSHOT
cp "$FX/export.jsonl" "$ROWS"
BL="$ROOT/bin/jg-backlog.sh"
DB=$T/home/state/item-store/fleet.db
sql() { python3 -c 'import sqlite3,sys; [print("|".join(map(str,r))) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])]' "$DB" "$1"; }
intakes() { sql "SELECT key FROM item WHERE key LIKE 'intake:main/tickets-differ-%'" 2>/dev/null; }

python3 "$TK" import --home main "$FX/export.jsonl" >/dev/null; expect_code 0 $? "the fixture imports"
FLAG=$T/home/config/one-engine-read

# Every read verb, with the flags the callers pass: the text from Beads (flag absent), then from the tables (flag present).
READS=("list" "list --all" "list --state held" "list --state queued --repo p" "list --blocked" "list --fields parent,labels,ask,release"
  "show jg-ready1" "show jg-pr --full" "show jg-blk" "show jg-unres" "view jg-child" "show jg-nothere" "ready" "ready --repo p" "ready --repo nowhere"
  "markdown" "questions" "questions --all" "questions --json")
rm -f "$FLAG"
for r in "${READS[@]}"; do
  # shellcheck disable=SC2086
  "$BL" $r > "$T/beads.$(printf '%s' "$r" | tr -c 'a-z0-9' _).out" 2>&1; echo $? >> "$T/beads.$(printf '%s' "$r" | tr -c 'a-z0-9' _).out"
done
[ -z "$(intakes)" ] || fail "a read with the flag absent opened an intake item"
pass "the flag absent: reads come from Beads and open nothing"

: > "$FLAG"
for r in "${READS[@]}"; do
  f=$T/beads.$(printf '%s' "$r" | tr -c 'a-z0-9' _).out
  # shellcheck disable=SC2086
  out=$("$BL" $r 2>&1); rc=$?
  [ "$out"$'\n'"$rc" = "$(cat "$f")" ] || fail "read '$r' differs between the tables and Beads: $(diff <(printf '%s\n%s\n' "$out" "$rc") "$f" | head -6)"
done
[ -z "$(intakes)" ] || fail "equal answers opened an intake item: $(intakes)"
pass "the flag present: all ${#READS[@]} reads print the same text and exit code from the tables as from Beads, and open no intake item"

# --- the tables answer, Beads is asked too: a row moved in Beads only opens one intake item that names both answers
python3 - "$ROWS" <<'PY'
import json, sys
p = sys.argv[1]; rows = [json.loads(l) for l in open(p)]
for r in rows:
    if r["id"] == "jg-ready1": r["title"] = "moved only in beads"
open(p, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
out=$("$BL" list 2>&1); expect_code 0 $? "list with a planted difference: $out"
assert_contains "$out" "row ready1" "the tables' answer is the one printed"
case $out in *"moved only in beads"*) fail "the Beads answer was printed" ;; esac
[ "$(intakes | wc -l | tr -d ' ')" = 1 ] || fail "one intake item expected, got: $(intakes)"
[ "$(sql "SELECT key FROM item WHERE key LIKE 'intake:main/tickets-differ-list-%'" | grep -c '^intake:main/tickets-differ-list-[0-9]*$')" = 1 ] || fail "the key is intake:main/tickets-differ-list-<epoch>"
body=$(sql "SELECT owes FROM item WHERE key LIKE 'intake:main/tickets-differ-list-%'")
assert_contains "$body" "row ready1" "the intake item names the tables' answer"
assert_contains "$body" "moved only in beads" "the intake item names the Beads answer"
"$BL" show jg-ready1 >/dev/null 2>&1
[ "$(intakes | wc -l | tr -d ' ')" = 2 ] || fail "a different verb opens its own intake item: $(intakes)"
pass "a planted difference opens one intake item per verb naming both answers, and the tables' answer is still the one printed"

# --- rollback: removing the flag returns every read to Beads at once
rm -f "$FLAG"
out=$("$BL" list 2>&1)
assert_contains "$out" "moved only in beads" "flag off: the read is Beads' answer again"
pass "the flag off reads Beads"

# --- tree and ready --spawnable
: > "$FLAG"
printf -- '- p\n' > "$T/home/data/projects.md"
out=$("$BL" ready --spawnable 2>&1); expect_code 0 $? "ready --spawnable from the tables: $out"
[ "$out" = "$(printf 'count: 4\njg-ready1\tp\njg-unres\tp\njg-child\tp\njg-rel\tp')" ] || fail "spawnable differs from the startable rows of the fixture: $out"
out=$("$BL" tree --homes 2>&1); expect_code 0 $? "tree from the tables: $out"
[ "$out" = "$(printf 'main:jg-ready1  [open]  row ready1\n  main:jg-child  [open]  row child')" ] || fail "tree differs from the fixture's parent edge: $out"
rm -f "$FLAG"
pass "ready --spawnable and tree read the tables when the flag exists"
