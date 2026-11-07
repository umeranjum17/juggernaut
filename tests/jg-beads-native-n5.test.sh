#!/usr/bin/env bash
# Journey for links as Beads edges: bin/jg-beads-links.py turns body lines into edges at migration and at write, and bin/jg-captain-hold.sh's
# blocking gate answers alike on a file home, a cut store and a store of body lines. The store half needs JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-beads-native-n5)
M=$T/main MIGRATE=$ROOT/bin/jg-beads-migrate.py WRAPPER=$ROOT/bin/jg-beads.sh jail=()
mkdir -p "$M/data" "$M/config" "$T/board" "$T/runs"
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
## Done
ROWS

# Migration: each line is the edge row 36 names, in one pass, before any store exists.
python3 "$MIGRATE" copy --main "$M" --to "$T/copy" || fail "copy failed"
python3 "$MIGRATE" plan --copy "$T/copy" --out "$T/imp" >/dev/null || fail "plan failed"
edges() {  # <jsonl rows on stdin>: each edge as old-name type old-name.
  python3 -c 'import json, sys; rows = [json.loads(l) for l in sys.stdin]; name = {r["id"]: (r.get("metadata") or {}).get("legacy_item") or r["id"] for r in rows}
print("\n".join(sorted("%s %s %s" % (name[r["id"]], d["type"], name[d["depends_on_id"]]) for r in rows for d in r.get("dependencies") or [])))'
}
want=$'back blocks card\nkid parent-child gate\nmid blocks tied\nring blocks mid\nside related back\nside related work\ntied related ring\nwork blocks gate'
[ "$(edges <"$T/imp/main.jsonl")" = "$want" ] || fail "migrated edges: $(edges <"$T/imp/main.jsonl")"
if ! grep -q '"linked_to": \["gone-row"\]' "$T/imp/main.jsonl" || ! grep -q '"link-unresolved"' "$T/imp/main.jsonl"; then fail "an unresolved name must be recorded"; fi
# Judge the plan as its own export, then take one edge away: a line with no edge stops the cut.
cp "$T/imp/main.jsonl" "$T/runs/main.export.jsonl"
for s in open in_progress on_hold deferred closed; do printf '%s %s\n' "$s" "$(grep -c "\"status\": \"$s\"" "$T/imp/main.jsonl")"; done >"$T/runs/main.counts"
judge() { python3 "$MIGRATE" verify --copy "$T/copy" --out "$T/imp" --runs "$T/runs" --home main 2>"$T/err"; }
judge >/dev/null || fail "a matching plan was refused: $(cat "$T/err")"
sed -i -E '/"Waits on the decision"/s/"dependencies": \[[^]]*\]/"dependencies": []/' "$T/runs/main.export.jsonl"
judge >/dev/null && fail "a line with no edge passed"
assert_contains "$(cat "$T/err")" "names gate in a line with no edge" "the refusal must name the lost line"
pass "migration turns body lines into edges and refuses a line with no edge"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then printf 'skip: real store: JG_BEADS_TEST_BD, JG_BEADS_TEST_DOLT is unset\n'; exit 0; fi
export TZ=UTC JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT TMPDIR=$T
command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --tmpfs /tmp --bind "$T" "$T" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)
home() {  # <name>: a Beads home on its own store.
  mkdir -p "$T/$1/config" "$T/$1/data" "$T/$1/state" "$T/$1/s"
  printf '%s\n' "$T/$1/s/.beads" >"$T/$1/config/beads-dir"
  bd_ "$1" init --prefix n5
}
bd_() { BEADS_DIR=$T/$1/s/.beads "${jail[@]}" "$WRAPPER" "${@:2}" >/dev/null 2>&1 || fail "$1: bd ${*:2}"; }
axi() { JG_HOME=$T/$1 "${jail[@]}" "$ROOT/bin/jg-tasks-axi.sh" "${@:2}"; }
captain() { JG_CAPTAIN_HOLD_NOW=2026-11-07T10:00:00Z JG_HOME=$1 JG_STATE_OVERRIDE=$1/state JG_DATA_OVERRIDE=$1/data JG_CONFIG_OVERRIDE=$1/config "${jail[@]}" "$ROOT/bin/jg-captain-hold.sh" "${@:2}" 2>&1 </dev/null; }
codes() {  # <home folder> <ids...>: each row's blocking exit code.
  local id rc out=
  for id in "${@:2}"; do rc=0; captain "$1" blocking "$id" >/dev/null || rc=$?; out+="$id=$rc "; done
  printf '%s\n' "$out"
}
stored() { BEADS_DIR=$T/$1/s/.beads "${jail[@]}" "$WRAPPER" list --all --limit 0 --json 2>/dev/null | python3 -c 'import json,sys; [print(json.dumps(r)) for r in json.load(sys.stdin)]' | edges; }

# One set of rows on three homes: the file, a real cut of it, and the same rows with no edge, as bd alone would hold them.
NAMES=(work kid side card back stray ring tied nope)
said="work=0 kid=0 side=1 card=1 back=0 stray=1 ring=0 tied=0 nope=1 "
"${jail[@]}" python3 "$MIGRATE" cut --home main --dir "$M" --copy "$T/copy" --out "$T/imp" --store "$T/cut/.beads" --order "Umer ordered this cut" >/dev/null 2>"$T/err" || fail "cut: $(cat "$T/err")"
[ "$(codes "$M" "${NAMES[@]}")" = "$said" ] || fail "edge store: $(codes "$M" "${NAMES[@]}")"
home ln
sed -E -e 's/"dependencies": \[[^]]*\]/"dependencies": []/' -e '/"legacy_item": "kid"/s/"description": ""/"description": "parent: gate"/' "$T/imp/main.jsonl" >"$T/lines.jsonl"
bd_ ln import "$T/lines.jsonl"
[ -z "$(stored ln)" ] || fail "the body-line store must start with no edge: $(stored ln)"
assert_contains "$(axi ln relink)" "ok: relink laid 6" "lines must become their edges"
[ "$(codes "$T/ln" "${NAMES[@]}")" = "$said" ] || fail "body-line store: $(codes "$T/ln" "${NAMES[@]}")"
mv "$M/config/beads-dir" "$T/beads-dir"
[ "$(codes "$M" work stray)" = "work=2 stray=2 " ] || fail "an unreadable store must exit 2"
mv "$T/beads-dir" "$M/config/beads-dir"
printf 'short\n' >"$T/said.txt"
for h in "$M" "$T/ln"; do out=$(captain "$h" answer gate --decision-file "$T/said.txt") || fail "$h: answer: $out"; done
said=$(codes "$M" "${NAMES[@]}")
[ "$(codes "$T/ln" "${NAMES[@]}")" = "$said" ] || fail "an answer must free the rows alike"
pass "blocking gives the same exit codes on a cut store and a body-line store"

# Writes: a line lands as its edge, whichever row is filed first, and a body edit or a release moves it.
home wr
w() { axi wr "$@" >/dev/null || fail "wr: $*"; }
w add n5-gate "[feature] Gate" --priority 2 --body why
captain "$T/wr" hold n5-gate --reason "needs a word" >/dev/null || fail "hold the gate"
w add n5-work "[feature] Work" --priority 2 --body $'why\nlinked-to: n5-gate'
w add n5-kid "[feature] Child" --priority 2 --body $'why\nparent: n5-gate'
w add n5-side "[feature] Sibling" --priority 2 --body $'why\nlinked-to: n5-work, n5-late'
w add n5-late "[design-ux] Filed after the line" --priority 2 --body why
w block n5-gate --by n5-side
w update n5-late --body $'why\nlinked-to: n5-gate'
want=$'n5-gate blocks n5-side\nn5-kid parent-child n5-gate\nn5-late related n5-gate\nn5-side blocks n5-late\nn5-side related n5-work\nn5-work blocks n5-gate'
[ "$(stored wr)" = "$want" ] || fail "written edges: $(stored wr)"
[ "$(codes "$T/wr" n5-work n5-kid n5-side)" = "n5-work=0 n5-kid=0 n5-side=0 " ] || fail "written links must stop the work"
w update n5-kid --body why
[ "$(codes "$T/wr" n5-kid)" = "n5-kid=1 " ] || fail "a name the body dropped must free the row"
assert_contains "$(axi wr relink)" "ok: relink laid 0" "a store with every edge must converge"
w unhold n5-gate
assert_contains "$(stored wr)" "n5-work related n5-gate" "a release must ease the line's edge"
assert_contains "$(axi wr ready)" n5-work "released work must be ready"
pass "a write lays each line's edge, keeps a link bd refuses as a cycle, and a body edit or release moves it"
