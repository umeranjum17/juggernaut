#!/usr/bin/env bash
# The registry switch (slice 8r): a project's mode and yolo are read from its policy row, not from the registry's words.
# Real callers in temporary homes: bin/jg-project-mode.sh, core/item-store/adapters/policy.py and daily_files.py, on slice 2's fixture
# registry (12 projects: every mode word, yolo on and off).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
AD=$ROOT/core/item-store/adapters
FIX=$ROOT/tests/fixtures/item-store-owner-calls
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT
unset JG_TASK_ID JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_ROOT_OVERRIDE JG_PROJECT_MODE_FROM
export JG_ITEM_TICK_LEASE_S=0
fail=0
ok()  { echo "ok $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }
pol() { JG_HOME=$1 python3 -I "$AD/policy.py" "${@:2}"; }
modes() { local p; while read -r p; do printf '%s %s\n' "$p" "$(JG_HOME=$1 "$ROOT/bin/jg-project-mode.sh" "$p" 2>/dev/null)"; done < <(sed -n 's/^- \([^ ]*\) .*/\1/p' "$1/data/projects.md"); }
sql() { python3 -I -c 'import sqlite3, sys
for r in sqlite3.connect(sys.argv[1] + "/state/item-store/fleet.db").execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$1" "$2"; }

H=$d/main; mkdir -p "$H/data" "$H/state" "$H/config"
cp "$FIX/data/projects.md" "$H/data/projects.md"
before=$(modes "$H")
check "a0 twelve projects answered from the registry's words" 12 "$(printf '%s\n' "$before" | wc -l | tr -d ' ')"
: > "$H/config/item-store"
pol "$H" --import --table "$FIX/rules-main.tsv" >/dev/null || bad a1 "import failed"
check "a1 the same twelve lines after the switch, read from the rows" "$before" "$(modes "$H")"
yolo_row=$(printf '%s\n' "$before" | grep '^f-pr-yolo ')
check "a2 a loose row reads as yolo on" "f-pr-yolo direct-PR on" "$yolo_row"

# a row, not the registry's word, decides: his message moves a project to tight; the registry still says +yolo
pol "$H" --from-message --channel chat --message-id m1 --project f-pr-yolo --level tight >/dev/null || bad a3 "from-message failed"
check "a3 a newer row decides over the registry word" "direct-PR off" "$(JG_HOME=$H "$ROOT/bin/jg-project-mode.sh" f-pr-yolo 2>/dev/null)"
check "a4 JG_PROJECT_MODE_FROM=registry still reads the words" "direct-PR on" "$(JG_PROJECT_MODE_FROM=registry JG_HOME=$H "$ROOT/bin/jg-project-mode.sh" f-pr-yolo 2>/dev/null)"
pol "$H" --from-message --channel chat --message-id m2 --project f-pr-yolo --level loose >/dev/null

# b: the registry check and the rewrite
out=$(pol "$H" --registry-check "$H/data/projects.md"); rc=$?
check "b1 --registry-check exits 1" 1 "$rc"
check "b2 it lists the twelve lines that carry a word" 12 "$(printf '%s\n' "$out" | grep -c 'x$')"
cp "$H/data/projects.md" "$d/orig.md"
pol "$H" --rewrite-registry "$H/data/projects.md" --dry-run >/dev/null
check "b3 --dry-run changes nothing and keeps no copy" "same no" "$(cmp -s "$d/orig.md" "$H/data/projects.md" && echo same) $([ -e "$H/data/projects.md.before-policy" ] && echo yes || echo no)"
pol "$H" --rewrite-registry "$H/data/projects.md" --apply >/dev/null; rc=$?
check "b4 --apply exits 0" 0 "$rc"
check "b5 the copy beside it is the old file" same "$(cmp -s "$d/orig.md" "$H/data/projects.md.before-policy" && echo same)"
pol "$H" --registry-check "$H/data/projects.md" >/dev/null; rc=$?
check "b6 --registry-check exits 0 after the rewrite" 0 "$rc"
check "b7 the registry keeps names and descriptions only" "- a-lt-yolo - x" "$(sed -n 2p "$H/data/projects.md")"
check "b8 the same twelve lines after the rewrite" "$before" "$(modes "$H")"
if pol "$H" --rewrite-registry "$H/data/projects.md" --apply | grep -q 'nothing to rewrite'; then ok "b9 a second apply has nothing to do"; else bad b9 "second apply"; fi

# c: clone facts stay; no row, no rewrite
K=$d/keep; mkdir -p "$K/data" "$K/state" "$K/config"; : > "$K/config/item-store"
printf -- '- z-proj [direct-PR +yolo branch=x/ forge=forgejo mcp=f.json] - d (added 2026-11-01)\n- y-proj [local] - e\n' > "$K/data/projects.md"
out=$(pol "$K" --rewrite-registry "$K/data/projects.md" --apply); rc=$?
case $out in *"no policy row for z-proj, y-proj"*) check "c1 no row: the rewrite is refused (exit 1) and names the projects" 1 "$rc" ;; *) bad c1 "[$out]" ;; esac
check "c2 the refused rewrite changed nothing" "- z-proj [direct-PR +yolo branch=x/ forge=forgejo mcp=f.json] - d (added 2026-11-01)" "$(sed -n 1p "$K/data/projects.md")"
pol "$K" --import >/dev/null; pol "$K" --rewrite-registry "$K/data/projects.md" --apply >/dev/null
check "c3 branch, forge and mcp stay in their order" "- z-proj [branch=x/ forge=forgejo mcp=f.json] - d (added 2026-11-01)" "$(sed -n 1p "$K/data/projects.md")"
check "c4 the row still says yolo on, and the forge binding still reads" "direct-PR on forgejo" "$(JG_HOME=$K "$ROOT/bin/jg-project-mode.sh" z-proj 2>/dev/null) $(JG_HOME=$K "$ROOT/bin/jg-project-mode.sh" --forge z-proj)"

# d: an unregistered project, and a registered one with no row
err=$(JG_HOME=$H "$ROOT/bin/jg-project-mode.sh" nope 2>&1 >/dev/null); line=$(JG_HOME=$H "$ROOT/bin/jg-project-mode.sh" nope 2>/dev/null)
check "d1 an unregistered project prints today's fallback" "direct-PR off" "$line"
case $err in *'project "nope" not in registry; defaulting to direct-PR off'*) ok "d2 and today's registration gap line" ;; *) bad d2 "[$err]" ;; esac
printf -- '- late - added after the cut-over\n' >> "$H/data/projects.md"
check "d3 a registered project with no row is direct-PR off" "direct-PR off" "$(JG_HOME=$H "$ROOT/bin/jg-project-mode.sh" late 2>/dev/null)"
case $(JG_HOME=$H "$ROOT/bin/jg-project-mode.sh" late 2>&1 >/dev/null) in *'no policy row'*) ok "d4 and it says there is no row" ;; *) bad d4 "no warning" ;; esac

# f: the row decides only for a project this home's own registry lists (an unlisted clone keeps the fallback, so trunk-landing skips it)
check "f1 listed in the main home: the row decides (local-trunk, yolo on)" "local-trunk on" "$(JG_HOME=$H "$ROOT/bin/jg-project-mode.sh" --raw a-lt-yolo 2>/dev/null)"
L=$d/lead; mkdir -p "$L/data" "$L/state" "$L/config" "$L/projects"; cp -R "$H/state/item-store" "$L/state/"; : > "$L/config/item-store"
printf -- '- other - x\n' > "$L/data/projects.md"
git init -q "$L/projects/a-lt-yolo" && git -C "$L/projects/a-lt-yolo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c && git -C "$L/projects/a-lt-yolo" branch trunk
refs=$(git -C "$L/projects/a-lt-yolo" for-each-ref)
check "f2 a row for a project the home does not list: --raw is the fallback" "direct-PR off" "$(JG_HOME=$L "$ROOT/bin/jg-project-mode.sh" --raw a-lt-yolo 2>/dev/null)"
check "f3 and the plain answer is the fallback" "direct-PR off" "$(JG_HOME=$L "$ROOT/bin/jg-project-mode.sh" a-lt-yolo 2>/dev/null)"
# trunk-landing's own filter: a clone whose mode is not a trunk style is never initialized
. "$ROOT/bin/jg-delivery-style.sh"
jg_delivery_style_is "$(JG_HOME=$L "$ROOT/bin/jg-project-mode.sh" --raw a-lt-yolo 2>/dev/null | cut -d' ' -f1)" trunk && inited=yes || inited=no
check "f4 trunk-landing's filter skips the unlisted clone" no "$inited"
check "f5 the clone's refs are untouched" "$refs" "$(git -C "$L/projects/a-lt-yolo" for-each-ref)"

# e: the daily check of big flat files
B=$d/big; mkdir -p "$B/state/sub"
truncate -s 2M "$B/state/sub/huge.log"; printf small > "$B/state/small.txt"
python3 -I "$AD/daily_files.py" "$B" >/dev/null; python3 -I "$AD/daily_files.py" "$B" >/dev/null
check "e1 one 2 MB file opens one intake item, and run twice still one" "1" "$(sql "$B" "SELECT count(*) FROM item WHERE kind='intake' AND key LIKE 'intake:main/big-files@%'")"
case $(sql "$B" "SELECT why FROM move WHERE verb='open'") in *"state/sub/huge.log 2.0 MB"*) ok "e2 the item names the path and the size" ;; *) bad e2 "$(sql "$B" "SELECT why FROM move")" ;; esac
N=$d/none; mkdir -p "$N/state"; printf small > "$N/state/small.txt"; python3 -I "$AD/daily_files.py" "$N"
check "e3 with no big file nothing is written" no "$([ -e "$N/state/item-store/fleet.db" ] && echo yes || echo no)"
exit "$fail"
