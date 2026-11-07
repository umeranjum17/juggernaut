#!/usr/bin/env bash
# Journey for links as Beads edges: a home's linked-to: and parent: lines become edges at migration and at write, and
# bin/jg-captain-hold.sh's blocking gate answers with the same exit codes on a file home, an edge-only store and a store
# that took its lines by bd alone. The real-store half needs JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT and tasks-axi.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-beads-native-n5)
M=$T/main MIGRATE=$ROOT/bin/jg-beads-migrate.py WRAPPER=$ROOT/bin/jg-beads.sh CLI=$ROOT/bin/jg-tasks-axi.sh jail=()
mkdir -p "$M/data" "$M/config" "$T/board"
printf '%s/board.json\n' "$T/board" >"$M/config/fleet-board"
: >"$T/board/board.tickets.jsonl"
HOLD="(hold: jg-hold-v1:$(printf 'waits on Umer' | base64)) (hold-kind: captain)"
cat >"$M/data/backlog.md" <<ROWS
## In flight
## Queued
- [ ] gate - [feature] Pick one $HOLD
- [ ] work - Waits on the decision
  linked-to: gate
- [ ] back - Named by the design row
- [ ] card - [design-ux] Pick a page
  linked-to: back
- [ ] side - A sibling
  linked-to: work; back
- [ ] kid - A child
  parent: gate
- [ ] stray - Names no row
  linked-to: gone-row, upkeep
- [ ] ring - [feature] Waits on its own work $HOLD blocked-by: mid
- [ ] mid - Between blocked-by: tied
- [ ] tied - Named back
  linked-to: ring
- [ ] free - No line
## Done
ROWS

# Migration: each line is the edge row 36 names, in one pass, before any store exists.
python3 "$MIGRATE" copy --main "$M" --to "$T/copy" || fail "copy failed"
python3 "$MIGRATE" plan --copy "$T/copy" --out "$T/imp" >/dev/null || fail "plan failed"
edges() {  # <jsonl rows on stdin>: each edge as old-name type old-name.
  python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin]
name = {r["id"]: (r.get("metadata") or {}).get("legacy_item") or r["id"] for r in rows}
print("\n".join(sorted("%s %s %s" % (name[r["id"]], d["type"], name[d["depends_on_id"]]) for r in rows for d in r.get("dependencies") or [])))'
}
want=$'back blocks card\nkid parent-child gate\nmid blocks tied\nring blocks mid\nside related back\nside related work\ntied related ring\nwork blocks gate'
[ "$(edges <"$T/imp/main.jsonl")" = "$want" ] || fail "migrated edges: $(edges <"$T/imp/main.jsonl")"
grep -q '"linked_to": \["gone-row"\]' "$T/imp/main.jsonl" || fail "an unresolved name must be recorded"
grep -q '"link-unresolved"' "$T/imp/main.jsonl" || fail "an unresolved name must carry its label"
# Judge the plan as its own export, then take one edge away: a line with no edge stops the cut.
mkdir -p "$T/runs"
cp "$T/imp/main.jsonl" "$T/runs/main.export.jsonl"
for s in open in_progress on_hold closed; do printf '%s %s\n' "$s" "$(grep -c "\"status\": \"$s\"" "$T/imp/main.jsonl")"; done >"$T/runs/main.counts"
judge() { python3 "$MIGRATE" verify --copy "$T/copy" --out "$T/imp" --runs "$T/runs" --home main 2>"$T/err"; }
judge >/dev/null || fail "a matching plan was refused: $(cat "$T/err")"
sed -i -E '/"Waits on the decision"/s/"dependencies": \[[^]]*\]/"dependencies": []/' "$T/runs/main.export.jsonl"
judge >/dev/null && fail "a line with no edge passed"
assert_contains "$(cat "$T/err")" "names gate in a line with no edge" "the refusal must name the lost line"
pass "migration turns body lines into edges and refuses a line with no edge"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ] || ! command -v tasks-axi >/dev/null; then
  printf 'skip: real store: JG_BEADS_TEST_BD, JG_BEADS_TEST_DOLT or tasks-axi missing\n'
  exit 0
fi
export TZ=UTC JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT TMPDIR=$T
command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --tmpfs /tmp --bind "$T" "$T" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)
home() {  # <name>: a Beads home on its own store.
  mkdir -p "$T/$1/config" "$T/$1/data" "$T/$1/state" "$T/$1/s"
  printf 'beads\n' >"$T/$1/config/backlog-backend"
  printf '%s\n' "$T/$1/s/.beads" >"$T/$1/config/beads-dir"
  bd_ "$1" init --prefix n5
}
bd_() { BEADS_DIR=$T/$1/s/.beads "${jail[@]}" "$WRAPPER" "${@:2}" >/dev/null 2>&1 || fail "$1: bd ${*:2}"; }
axi() { JG_HOME=$T/$1 "${jail[@]}" "$CLI" "${@:2}"; }
captain() {  # <home folder> <args...>
  JG_CAPTAIN_HOLD_NOW=2026-11-07T10:00:00Z JG_HOME=$1 JG_STATE_OVERRIDE=$1/state JG_DATA_OVERRIDE=$1/data JG_CONFIG_OVERRIDE=$1/config \
    "${jail[@]}" "$ROOT/bin/jg-captain-hold.sh" "${@:2}" 2>&1 </dev/null
}
codes() {  # <home folder> <ids...>: each row's blocking exit code.
  local id rc out=
  for id in "${@:2}"; do
    rc=0
    captain "$1" blocking "$id" >/dev/null || rc=$?
    out+="$id=$rc "
  done
  printf '%s\n' "$out"
}
stored() { BEADS_DIR=$T/$1/s/.beads "${jail[@]}" "$WRAPPER" list --all --limit 0 --json 2>/dev/null | python3 -c 'import json,sys; [print(json.dumps(r)) for r in json.load(sys.stdin)]' | edges; }

# One fixture on three homes: tasks-axi's file home, a store of edges alone, and a store of lines bd took with no edge.
FIXTURE=("n5-d|[feature] Pick a name|linked-to: n5-e" "n5-a|[feature] Work|linked-to: n5-d" "n5-b|[feature] Child|parent: n5-d"
  "n5-e|[feature] Named by the decision|" "n5-f|[feature] Free|" "n5-g|[captain-ask] Not held|" "n5-h|[feature] After the ask|linked-to: n5-g"
  "n5-i|[design-ux] Pick a page|" "n5-j|[feature] After the page|linked-to: n5-i" "n5-k|[feature] Stray|linked-to: gone-row, upkeep")
IDS=(n5-a n5-b n5-d n5-e n5-f n5-g n5-h n5-i n5-j n5-k nope)
mkdir -p "$T/ta/config" "$T/ta/data" "$T/ta/state"
printf 'tasks-axi\n' >"$T/ta/config/backlog-backend"
: >"$T/ta/data/backlog.md"
home ed
home ln
for spec in "${FIXTURE[@]}"; do
  IFS='|' read -r id title line <<<"$spec"
  axi ta add "$id" "$title" --body "why${line:+$'\n'$line}" >/dev/null || fail "file $id"
  bd_ ed create "$title" --id "$id" --priority 2 --description why
  bd_ ln create "$title" --id "$id" --priority 2 --description "why${line:+$'\n'$line}"
done
bd_ ed dep add n5-a n5-d --type blocks
bd_ ed dep add n5-b n5-d --type parent-child
bd_ ed dep add n5-e n5-d --type blocks
bd_ ed dep add n5-h n5-g --type related
bd_ ed dep add n5-j n5-i --type blocks
for h in ta ed ln; do captain "$T/$h" hold n5-d --reason "needs the name" >/dev/null || fail "$h: hold"; done
said=$(codes "$T/ta" "${IDS[@]}")
[ "$said" = "n5-a=0 n5-b=0 n5-d=0 n5-e=0 n5-f=1 n5-g=1 n5-h=1 n5-i=1 n5-j=0 n5-k=1 nope=1 " ] || fail "the file home says: $said"
[ "$(codes "$T/ed" "${IDS[@]}")" = "$said" ] || fail "edge-only store: $(codes "$T/ed" "${IDS[@]}")"
assert_contains "$(captain "$T/ed" blocking n5-a)" n5-d "an edge must name the decision"
[ "$(codes "$T/ln" "${IDS[@]}")" = "$said" ] || fail "body-line store: $(codes "$T/ln" "${IDS[@]}")"
assert_contains "$(captain "$T/ln" blocking n5-a)" n5-d "a line must name the decision"
for h in ed ln; do
  mv "$T/$h/config/beads-dir" "$T/$h/beads-dir"
  [ "$(codes "$T/$h" n5-a n5-f)" = "n5-a=2 n5-f=2 " ] || fail "$h: an unreadable store must exit 2"
  mv "$T/$h/beads-dir" "$T/$h/config/beads-dir"
done
printf 'short\n' >"$T/said.txt"
for h in ta ed ln; do out=$(captain "$T/$h" answer n5-d --decision-file "$T/said.txt") || fail "$h: answer: $out"; done
said=$(codes "$T/ta" "${IDS[@]}")
[ "$(codes "$T/ed" "${IDS[@]}")" = "$said" ] && [ "$(codes "$T/ln" "${IDS[@]}")" = "$said" ] || fail "an answer must free the rows alike"
pass "blocking gives the same exit codes on a file home, an edge-only store and a body-line store"

# Writes: a line lands as its edge, whichever row is filed first, and a body edit moves it.
home wr
axi wr add n5-gate "[feature] Gate" --priority 2 --body why >/dev/null || fail "file the gate"
captain "$T/wr" hold n5-gate --reason "needs a word" >/dev/null || fail "hold the gate"
axi wr add n5-work "[feature] Work" --priority 2 --body $'why\nlinked-to: n5-gate' >/dev/null || fail "file linked work"
axi wr add n5-kid "[feature] Child" --priority 2 --body $'why\nparent: n5-gate' >/dev/null || fail "file a child"
axi wr add n5-side "[feature] Sibling" --priority 2 --body $'why\nlinked-to: n5-work, n5-late' >/dev/null || fail "file a sibling"
axi wr add n5-late "[design-ux] Filed after the line" --priority 2 --body why >/dev/null || fail "file the named row"
axi wr add n5-mid "[feature] Between" --priority 2 --body why >/dev/null || fail "file the middle"
axi wr add n5-ring "[feature] Ring" --priority 2 --body why >/dev/null || fail "file the ring"
axi wr block n5-gate --by n5-mid >/dev/null || fail "block the gate"
axi wr block n5-mid --by n5-ring >/dev/null || fail "block the middle"
axi wr update n5-ring --body $'why\nlinked-to: n5-gate' >/dev/null || fail "a line that closes a cycle"
want=$'n5-gate blocks n5-mid\nn5-kid parent-child n5-gate\nn5-mid blocks n5-ring\nn5-ring related n5-gate\nn5-side blocks n5-late\nn5-side related n5-work\nn5-work blocks n5-gate'
[ "$(stored wr)" = "$want" ] || fail "written edges: $(stored wr)"
[ "$(codes "$T/wr" n5-work n5-kid n5-side n5-ring)" = "n5-work=0 n5-kid=0 n5-side=0 n5-ring=0 " ] || fail "written links must stop the work: $(codes "$T/wr" n5-work n5-kid n5-side n5-ring)"
axi wr update n5-side --body $'why\nlinked-to: n5-work' >/dev/null || fail "drop a name"
[ "$(codes "$T/wr" n5-side)" = "n5-side=1 " ] || fail "a name the body dropped must free the row"
assert_contains "$(axi wr relink)" "ok: relink laid 0" "a store with every edge must converge"
assert_not_contains "$(axi wr ready)" n5-work "work on a decision must wait"
axi wr unhold n5-gate >/dev/null || fail "release"
assert_contains "$(stored wr)" "n5-work related n5-gate" "a release must ease the line's edge"
assert_contains "$(axi wr ready)" n5-work "released work must be ready"
pass "a write lays each line's edge, keeps a link bd refuses as a cycle, and a body edit or release moves it"

# A real cut: the gate answers each old name the same on the migrated store as it did on the file.
NAMES=(work kid side card back stray ring tied free)
said=$(codes "$M" "${NAMES[@]}")
[ "$said" = "work=0 kid=0 side=1 card=1 back=0 stray=1 ring=0 tied=0 free=1 " ] || fail "the file home says: $said"
"${jail[@]}" python3 "$MIGRATE" cut --home main --dir "$M" --copy "$T/copy" --out "$T/imp" --store "$T/cut/.beads" --order "Umer ordered this cut" >/dev/null 2>"$T/err" || fail "cut: $(cat "$T/err")"
[ "$(codes "$M" "${NAMES[@]}")" = "$said" ] || fail "after the cut: $(codes "$M" "${NAMES[@]}")"
pass "a real cut keeps every blocking answer"
