#!/usr/bin/env bash
# Journey for bin/jg-beads-migrate.py: a fixture main home and one lead go through copy and plan, and the import
# files carry one row per piece of work with its status, hold, parent and blockers. The real home is never written.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-beads-migrate)
M=$T/main L=$T/lead
mkdir -p "$M/data" "$M/config" "$L/data" "$T/board"
sum() { printf '%s' "$1" | sha256sum | cut -c1-32; }
printf '%s/board.json\n' "$T/board" >"$M/config/fleet-board"
printf -- '- lead - a lead (home: %s; x)\n' "$L" >"$M/data/squad_leads.md"
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
} >"$T/board/board.tickets.jsonl"
before=$(find "$M" "$L" -type f -exec sha256sum {} + | sha256sum)

python3 "$ROOT/bin/jg-beads-migrate.py" copy --main "$M" --to "$T/copy" || fail "copy failed"
python3 "$ROOT/bin/jg-beads-migrate.py" plan --copy "$T/copy" --out "$T/imp" || fail "plan failed"
[ "$(find "$M" "$L" -type f -exec sha256sum {} + | sha256sum)" = "$before" ] || fail "a real home changed"

q() { python3 -c "
import json,sys
rows={r['id']:r for f in ('main','lead','unplaced') for r in map(json.loads,open('$T/imp/'+f+'.jsonl'))}
man=json.load(open('$T/imp/manifest.json'))
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
same "rows['fm-$BARE']['status'],rows['fm-$BARE']['metadata']['hold_reason'],sorted(rows['fm-$BARE']['labels'])" "on_hold no reason recorded before migration ['hold-reason-missing', 'home:unplaced', 'parent-dangling']" "held row with no reason not labelled"
same "rows['jg-$HELD']['status'],man['held']['jg-$HELD']['disposition'],rows['jg-$HELD']['closed_at'] != ''" "closed dropped-by-source True" "source close did not account for the hold"
same "sum(len(rows['jg-'+k].get('dependencies',[])) for k in ('$(sum main/loop-a)','$(sum main/loop-b)')),sum('dependency-dropped' in r['labels'] for r in rows.values())" "1 1" "a blocker cycle was not recorded"

# Judge a stand-in export built from the plan, then break it: the dry run must stop on each difference.
mkdir -p "$T/runs"
for h in main lead unplaced; do
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

# The check script refuses a shared server before any bd call; the wrapper refuses an unpinned bd.
CHECK=$ROOT/bin/jg-beads-migrate-check.sh
printf 'fake' >"$T/bd"; chmod +x "$T/bd"
BEADS_DOLT_SHARED_SERVER=1 "$CHECK" --main "$M" --bd "$T/bd" --scratch "$T/s" 2>&1 | grep -q 'banned' || fail "shared server not refused"
if [ -n "${JG_TEST_BD:-}" ]; then # CI has no pinned bd; set this to the pinned build for the full path.
  "$CHECK" --main "$M" --bd "$T/bd" --scratch "$T/s" 2>&1 | grep -q 'not the pinned' || fail "unpinned bd not refused"
  mkdir -p "$T/tree/.git"
  "$CHECK" --main "$M" --bd "$JG_TEST_BD" --scratch "$T/tree/s" 2>&1 | grep -q 'inside the git tree' || fail "scratch in a git tree not refused"
  "$CHECK" --main "$M" --bd "$JG_TEST_BD" --scratch "$T/s" | grep -q 'dry run passed' || fail "fixture dry run failed"
fi
pass "beads migrate plan keeps every row, hold and blocker"
