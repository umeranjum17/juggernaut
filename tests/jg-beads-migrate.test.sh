#!/usr/bin/env bash
# Journey for bin/jg-beads-migrate.py: a fixture main home, one lead and one parked home go through copy and plan, and the
# import files carry one row per piece of work with its status, hold, parent and blockers. Each refusal of a cut leaves the
# home as it was. With pinned builds the check script then rehearses a cut and the way back. The real home is never written.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-beads-migrate)
M=$T/main L=$T/lead P=$T/parked
mkdir -p "$M/data/parked" "$M/config" "$L/data" "$P/data" "$T/board"
sum() { printf '%s' "$1" | sha256sum | cut -c1-32; }
printf '%s/board.json\n' "$T/board" >"$M/config/fleet-board"
{
  printf -- '- lead - a lead (home: %s; x)\n' "$L"
  printf -- '- far - a remote lead (host: box; x)\n'
} >"$M/data/squad_leads.md"
printf 'home=%s\n' "$P" >"$M/data/parked/old.meta"
LONG=$(printf 'x%.0s' $(seq 1 5000))
{
  echo '- [ ] parked-gate - Parked gate'
  echo '- [ ] parked-item - Parked work blocked-by: parked-gate'
  printf '  %s\n' "$LONG"
  echo '- [x] parked-old - Parked and closed (done 2026-09-01)'
} >"$P/data/backlog.md"
{
  echo '## In flight'
  echo '- [ ] twin - Source title blocked-by: gate (kind: ship) (priority: 1) (since 2026-10-01)'
  echo '  parent: upkeep'
  echo '## Queued'
  echo "- [ ] gate - Held work (hold: jg-hold-v1:$(printf 'waits on Umer' | base64)) (hold-kind: external) (hold-until: 2027-01-02)"
  echo '- [ ] loop-a - One blocked-by: loop-b'
  echo '- [ ] loop-b - Two blocked-by: loop-a'
  echo '## Done'
  echo '- [x] was-held - Finished (done 2026-10-02)'
} >"$M/data/backlog.md"
{
  echo '## Done'
  echo '- [x] archived - An old "quoted", finished piece (done 2026-09-02)'
} >"$M/data/done-archive.md"
echo '- [ ] lead-item - Lead work' >"$L/data/backlog.md"
TWIN=$(sum main/twin) HELD=$(sum main/was-held) OLD=aaaa BARE=bbbb BUCKET=cccc
line() { printf '{"id":"%s","title":"%s","at":"%s","progress":0,"state":"%s","hold":%s,"parent":"%s"}\n' "$@"; }
{
  line "fm-$TWIN" 'Feed title' 2026-10-01T00:00:00Z 'done' false ''
  line "jg-$TWIN" 'Feed title' 2026-10-03T00:00:00Z 'on hold' true ''
  line "jg-$HELD" 'Finished' 2026-10-03T00:00:00Z 'on hold' true ''
  line "fm-$OLD" 'Older twin' 2026-10-01T00:00:00Z 'on hold' true ''
  line "jg-$OLD" 'Newer twin' 2026-10-05T00:00:00Z queued false "jg-$BUCKET"
  line "fm-$BARE" 'Held bare' 2026-10-05T00:00:00Z 'on hold' true 'jg-gone'
  line "fm-$BUCKET" 'Not from your asks (fleet upkeep)' 2026-10-05T00:00:00Z '' false ''
  printf '{"id":"jg-dddd","title":"Far work","at":"2026-10-05T00:00:00Z","progress":0,"state":"queued","hold":false,"parent":"","assignee":{"lead":"far"}}\n'
} >"$T/board/board.tickets.jsonl"
# A stopped cut keeps its dated record, data/beads-cut.<at>.back.json, so the sum leaves those out.
tree_sum() { find "$M" "$L" "$P" -type f ! -name 'beads-cut.*.back.json' -exec sha256sum {} + | sort | sha256sum; }
before=$(tree_sum)

python3 "$ROOT/bin/jg-beads-migrate.py" copy --main "$M" --to "$T/copy" || fail "copy failed"
python3 "$ROOT/bin/jg-beads-migrate.py" plan --copy "$T/copy" --out "$T/imp" >"$T/settled" || fail "plan failed"
[ "$(tree_sum)" = "$before" ] || fail "a real home changed"

q() { python3 -c "
import json,sys
rows={r['id']:r for f in ('main','lead','far') for r in map(json.loads,open('$T/imp/'+f+'.jsonl'))}
man=json.load(open('$T/imp/manifest.json'))
settle=json.load(open('$T/imp/settle.json'))
ids=lambda g: sorted(r['id'] for r in settle.get(g,[]))
print($1)"; }
same() { local got; got=$(q "$1"); [ "$got" = "$2" ] || fail "$3: got $got"; }
[ "$(wc -l <"$T/imp/lead.jsonl")" = 1 ] || fail "a lead's source row left its home"
same "rows['jg-$TWIN']['status'],rows['jg-$TWIN']['title'],rows['jg-$TWIN']['priority'],rows['jg-$TWIN']['metadata']['legacy_twin']" "in_progress Source title 1 fm-$TWIN" "source row did not win the twin"
same "'fm-$TWIN' in rows, 'jg-$BUCKET' in rows, 'fm-$BUCKET' in rows, man['buckets']" "False False False ['$BUCKET']" "twin or bucket survived"
same "[l for l in rows['jg-$TWIN']['labels'] if 'upkeep' in l or 'hold-' in l]" "['hold-dropped-by-source', 'upkeep']" "twin labels wrong"
same "rows['jg-$OLD']['status'],'upkeep' in rows['jg-$OLD']['labels'],rows['jg-$OLD']['metadata']['past_hold'],man['held']['fm-$OLD']['disposition']" "open True no reason recorded before migration dropped-by-newer-twin" "newest twin did not win"
g=jg-$(sum main/gate)
same "rows['$g']['status'],rows['$g']['metadata']['hold_reason'],rows['$g']['metadata']['hold_kind'],rows['$g']['defer_until']" "on_hold waits on Umer external 2027-01-02T00:00:00Z" "hold not decoded"
same "[(d['depends_on_id'],d['type']) for d in rows['jg-$TWIN']['dependencies']]" "[('$g', 'blocks')]" "blocked-by did not become a dependency"
same "rows['fm-$BARE']['status'],rows['fm-$BARE']['metadata']['hold_reason'],sorted(rows['fm-$BARE']['labels'])" "on_hold no reason recorded before migration ['hold-reason-missing', 'home:main', 'parent-dangling', 'unplaced']" "held row with no home did not park under main"
same "rows['jg-$HELD']['status'],man['held']['jg-$HELD']['disposition'],rows['jg-$HELD']['closed_at'] != ''" "closed dropped-by-source True" "source close did not account for the hold"
same "sum(len(rows['jg-'+k].get('dependencies',[])) for k in ('$(sum main/loop-a)','$(sum main/loop-b)')),sum('dependency-dropped' in r['labels'] for r in rows.values())" "1 1" "a blocker cycle was not recorded"

# Settling: each group a person reads is listed and counted, and no row is left out of a home.
pi=jg-$(sum old/parked-item) pg=jg-$(sum old/parked-gate) po=jg-$(sum old/parked-old)
same "rows['$pi']['metadata']['home'],rows['$pi']['metadata']['parked_from'],[l for l in rows['$pi']['labels'] if l.startswith('parked')]" "main old ['parked-home:old']" "a parked home's row did not park under main"
same "[(d['depends_on_id'],d['type']) for d in rows['$pi']['dependencies']],len(rows['$pi']['description'])" "[('$pg', 'blocks')] 5000" "a parked row lost its blocker or body"
same "ids('unplaced')==sorted(i for i,r in rows.items() if 'unplaced' in r['labels']),'fm-$BARE' in ids('unplaced_held'),'fm-$BARE' in ids('no_reason')" "True True True" "unplaced or no-reason rows not listed"
same "'jg-$HELD' in ids('held_not_in_source'),'fm-$BARE' in ids('held_no_source_row'),ids('parked:old')==sorted(['$pi','$pg','$po']),ids('remote:far')" "True True True ['jg-dddd']" "a settle group is wrong"
same "'$g' in ids('held_not_on_board'),rows['jg-$HELD']['closed_at']" "True 2026-10-02T00:00:00Z" "a held row off the board not listed, or a close date lost"
grep -q 'unplaced=' "$T/settled" || fail "plan printed no settle counts"
[ ! -e "$T/imp/old.jsonl" ] || fail "a parked home got its own import file"

# Judge a stand-in export built from the plan, then break it: the dry run must stop on each difference.
mkdir -p "$T/runs"
for h in main lead far; do
  cp "$T/imp/$h.jsonl" "$T/runs/$h.export.jsonl"
  for s in open in_progress on_hold closed; do
    printf '%s %s\n' "$s" "$(grep -c "\"status\": \"$s\"" "$T/imp/$h.jsonl")"
  done >"$T/runs/$h.counts"
done
judge() { python3 "$ROOT/bin/jg-beads-migrate.py" verify --copy "$T/copy" --out "$T/imp" --runs "$T/runs" 2>"$T/err"; }
judge >"$T/table" || fail "a matching dry run was refused: $(cat "$T/err")"
grep -q '^main ' "$T/table" || fail "no per-home counts printed"
sed -i 's/^open .*/open 99/' "$T/runs/main.counts"
judge >/dev/null && fail "a wrong count passed"
grep -q 'manifest' "$T/err" || fail "a wrong count gave no reason"

# A cut refuses before any bd call, and each refusal leaves the home exactly as it was.
migrate() { python3 "$ROOT/bin/jg-beads-migrate.py" "$@"; }
cutting() { migrate cut --home "$1" --dir "$2" --copy "$T/copy" --out "$T/imp" --store "$T/store/.beads" "${@:3}" 2>"$T/err"; }
refused() { # <what> <grep> <cut args...>
  local what=$1 text=$2
  shift 2
  cutting "$@" >/dev/null && fail "$what ran"
  grep -q "$text" "$T/err" || fail "$what gave no reason: $(cat "$T/err")"
  [ "$(tree_sum)" = "$now" ] || fail "$what changed the home"
  [ ! -e "$T/store" ] || fail "$what made a store"
}
now=$(tree_sum)
files_before=$(find "$M/data/backlog.md" "$M/data/done-archive.md" -exec sha256sum {} + | sort)
refused 'a cut with no order' 'order' main "$M"
refused 'a cut of a remote home' 'remote' far "$M" --order go
refused 'a cut of a parked home' 'parked' old "$P" --order go
refused 'a cut of an unknown home' 'not in this plan' nobody "$M" --order go
printf 'owner\n' >"$M/data/backlog.md.lock"; now=$(tree_sum)
refused 'a cut under a held lock' 'held' main "$M" --order go
rm -f "$M/data/backlog.md.lock"
printf '%s\n' '- [ ] late - Written after the copy' >>"$M/data/backlog.md"; now=$(tree_sum)
refused 'a cut of a home that moved' 'changed since the copy' main "$M" --order go
sed -i '$d' "$M/data/backlog.md"
[ "$(tree_sum)" = "$before" ] || fail "the fixture did not return to its start"
migrate back --dir "$M" | grep -q 'no cut to undo' || fail "back on an uncut home did something"

# The check script refuses a shared server before any bd call; the wrapper refuses an unpinned bd.
CHECK=$ROOT/bin/jg-beads-migrate-check.sh
printf 'fake' >"$T/bd"; chmod +x "$T/bd"
BEADS_DOLT_SHARED_SERVER=1 "$CHECK" --main "$M" --bd "$T/bd" --dolt "$T/bd" --scratch "$T/s" 2>&1 | grep -q 'banned' || fail "shared server not refused"
if [ -n "${JG_TEST_BD:-}" ] && [ -n "${JG_TEST_DOLT:-}" ]; then # CI has no pinned builds; set both for the full path.
  "$CHECK" --main "$M" --bd "$T/bd" --dolt "$JG_TEST_DOLT" --scratch "$T/s" 2>&1 | grep -q 'not the pinned' || fail "unpinned bd not refused"
  mkdir -p "$T/tree/.git"
  "$CHECK" --main "$M" --bd "$JG_TEST_BD" --dolt "$JG_TEST_DOLT" --scratch "$T/tree/s" 2>&1 | grep -q 'inside the git tree' || fail "scratch in a git tree not refused"
  "$CHECK" --main "$M" --bd "$JG_TEST_BD" --dolt "$JG_TEST_DOLT" --scratch "$T/s" --rehearse main >"$T/check" 2>&1 || fail "fixture rehearsal failed: $(tail -3 "$T/check")"
  grep -q 'dry run passed' "$T/check" || fail "the check did not report the dry run"
  grep -q 'rehearsal passed: main' "$T/check" || fail "the check did not report the rehearsal"

  # A store that does not match the manifest stops the cut, and the home goes back on its own.
  cp -r "$T/imp" "$T/bad"
  python3 - "$T/bad/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
next(r for r in m['rows'].values() if r['home'] == 'main')['status'] = 'in_progress'
next(r for r in m['rows'].values() if r['home'] == 'main' and r['status'] == 'closed')['status'] = 'open'
json.dump(m, open(sys.argv[1], 'w'))
PY
  export JG_BEADS_BD=$JG_TEST_BD JG_BEADS_DOLT=$JG_TEST_DOLT
  migrate cut --home main --dir "$M" --copy "$T/copy" --out "$T/bad" --store "$T/s/bad/.beads" --order go >/dev/null 2>"$T/err" && fail "a store that differs from the manifest was cut"
  grep -q 'differs from the manifest' "$T/err" || fail "a failed cut gave no reason: $(cat "$T/err")"
  [ ! -e "$M/data/backlog.md.lock" ] && [ ! -e "$M/data/beads-cut.json" ] && [ ! -e "$M/config/backlog-backend" ] || fail "a failed cut left the home moved"
  [ -d "$(echo "$T"/s/bad.back.*)" ] || fail "a failed cut's store was not kept aside"

  # A killed cut leaves its record: a second cut refuses, and back finishes the undo.
  migrate cut --home main --dir "$M" --copy "$T/copy" --out "$T/imp" --store "$T/s/killed/.beads" --order go >/dev/null || fail "the cut failed"
  python3 - "$M/data/beads-cut.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); r['phase'] = 'switched'
json.dump(r, open(sys.argv[1], 'w'))
PY
  cutting main "$M" --order go >/dev/null && fail "a cut ran over an unfinished one"
  grep -q 'unfinished' "$T/err" || fail "an unfinished cut gave no reason"
  migrate back --dir "$M" >/dev/null || fail "back did not finish an unfinished cut"
  [ ! -e "$M/data/backlog.md.lock" ] && [ -w "$M/data/backlog.md" ] && [ ! -e "$M/config/beads-dir" ] || fail "back left the home moved"
  [ "$(find "$M/data/backlog.md" "$M/data/done-archive.md" -exec sha256sum {} + | sort)" = "$files_before" ] || fail "back changed the old files"
fi
pass "beads migrate keeps every row, hold and blocker, cuts one home and goes back"
