#!/usr/bin/env bash
# The cleanup adapter of the item store (core/item-store/adapters/cleanup.py) over the real bin/jg-teardown.sh, in scratch git
# repositories. The landed-work test stays the script's: the adapter only runs it and records the answer.
# a: the lander re-cuts a lane's commit (same patch, new hash): the script cleans the copy by itself, and `cleanup.py run` closes
#    cleanup:<home>/<task> done `cleaned:<task>` with no word asked.
# b: a commit made after the landing, and uncommitted work: the script refuses, the item stays open with the refusal's text as a note,
#    and nothing is removed (hard rule 3). The same refusal twice is one note.
# c: `compare` prints nothing after a and b; a finished lane's copy with no cleanup item is listed once.
# d: an update closes `home-at:<HEAD>` when the home has the release under it or a commit with the release's patch id; a lagging home's
#    update stays open. e: each call twice changes nothing the second time. f: `sweep` runs both and prints nothing.
# shellcheck disable=SC2016 # the stand-in commands written below expand their own arguments
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$HERE/lib.sh"
jg_git_identity fmtest fmtest@example.invalid
ITEM=$ROOT/core/item-store
CLEAN=$ITEM/adapters/cleanup.py
TMP_ROOT=$(jg_test_tmproot item-store-cleanup)
unset JG_TASK_ID JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
export JG_ITEM_TICK_LEASE_S=0
want() { [ "$3" = "$2" ] || fail "$1: wanted [$2], got [$3]"; pass "$1"; }

# world <name> [<task>=task-x1]: a main home with the store on, a project clone with the lane's copy on fm/<task>, mocked treehouse and
# tmux, a seeded backlog row (the script closes it), and the lane's open cleanup item. Sets C (the home) and WT.
world() {
  local name=$1 task=${2:-task-x1} fb
  C=$TMP_ROOT/$name; WT=$C/wt; fb=$C/fakebin
  mkdir -p "$C/state" "$C/config" "$C/data" "$fb"
  jg_test_beads_home "$C"
  if [ ! -d "$TMP_ROOT/seeded-store" ]; then
    jg_test_backlog "$C" add "$task" "[feature] cleanup fixture" --priority 1 --kind ship --repo demo --body "fixture" >/dev/null
    jg_test_backlog "$C" start "$task" >/dev/null
    cp -a "$C-store" "$TMP_ROOT/seeded-store"
  else
    rm -rf "$C-store"; cp -a "$TMP_ROOT/seeded-store" "$C-store"
  fi
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/treehouse"; cp "$fb/treehouse" "$fb/tmux"
  printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in\n  "pr list") printf "%%s\\n" "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;\nesac\nexit 1\n' > "$fb/gh-axi"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/gh"
  chmod +x "$fb"/*
  git init -q --bare "$C/origin.git"; git -C "$C/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$C/origin.git" "$C/seed" 2>/dev/null
  git -C "$C/seed" commit -q --allow-empty -m baseline; git -C "$C/seed" push -q origin HEAD:main; rm -rf "$C/seed"
  git clone -q "$C/origin.git" "$C/project"; git -C "$C/project" remote set-head origin main 2>/dev/null || true
  git -C "$C/project" worktree add -q -b "fm/$task" "$WT" main
  jg_write_meta "$C/state/$task.meta" "window=juggernaut:jg-$task" "endpoint_task_id=$task" "worktree=$WT" "project=$C/project" \
    "kind=ship" "mode=local-trunk" "spawn_gen=cleanup-test-$task" "ticket=$task"
  printf '%s\n' '- project [local-trunk] - fixture' > "$C/data/projects.md"
  printf 'done [at=1]: ready in branch fm/%s (local-trunk)\n' "$task" > "$C/state/$task.status"
  touch "$C/state/.last-watcher-beat"
  : > "$C/config/item-store"
}
ji()  { env JG_HOME="$C" "$ITEM/jg-item" "$@"; }
cl()  { env JG_HOME="$C" PATH="$C/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$C/state" JG_DATA_OVERRIDE="$C/data" \
          JG_CONFIG_OVERRIDE="$C/config" python3 -I "$CLEAN" "$@"; }
sql() { python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1] + "/state/item-store/fleet.db")
for r in c.execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$C" "$1"; }
open_cleanup() { ji open "cleanup:main/${1:-task-x1}" --kind cleanup --home main --subject "${1:-task-x1}" --owes "return the lane's copy" --source "done:${1:-task-x1}@1" >/dev/null || fail "the cleanup item must open"; }
commit_file() { printf '%s\n' "$2" > "$WT/$1"; git -C "$WT" add -- "$1"; git -C "$WT" commit -q -m "task-x1: $1"; }
# land_recut: the lane's commit, then the trunk's re-cut of it (same patch, new hash) and its landing row, as the trunk lander writes them.
land_recut() {
  local head at rebased
  commit_file feature.txt 'Umer feature'
  head=$(git -C "$WT" rev-parse HEAD); at=$(git -C "$WT" show -s --format=%ct HEAD)
  rebased=$(git -C "$C/project" commit-tree "$head^{tree}" -p main -m 'task-x1: feature (re-cut)')
  git -C "$C/project" branch trunk "$rebased"
  printf '%s\n' trunk > "$C/state/trunk-branch-project"; printf '%s\n' "$rebased" > "$C/state/trunk-tip-project"
  printf 'task-x1\tproject\t%s\t%s\tfull\n' "$rebased" "$at" > "$C/data/trunk-landings.tsv"
  LANDED_AT=$at
}
state_of() { sql "SELECT state||'|'||coalesce(outcome,'') FROM item WHERE key='cleanup:main/task-x1' ORDER BY gen DESC LIMIT 1"; }
notes() { sql "SELECT count(*) FROM move WHERE key='cleanup:main/task-x1' AND verb='note'"; }
moves() { sql "SELECT count(*) FROM move"; }

# ---------------------------------------------------------------- a: a re-cut landing is cleaned by itself
world recut-direct; land_recut
out=$(env JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$C/state" JG_DATA_OVERRIDE="$C/data" JG_CONFIG_OVERRIDE="$C/config" \
  PATH="$C/fakebin:$PATH" "$ROOT/bin/jg-teardown.sh" task-x1 2>&1); rc=$?
want "a1 jg-teardown.sh's own test passes a re-cut landing" "0" "$rc"
world recut; land_recut; open_cleanup
want "a2 the item is open before the cleanup" "open|" "$(state_of)"
want "a3 cleanup.py run returns the copy" "done" "$(cl run main task-x1 --source cleanup:task-x1)"
want "a4 the item closes done cleaned:task-x1" "done|cleaned:task-x1" "$(state_of)"
[ ! -e "$C/state/task-x1.meta" ] || fail "a5 the task record must be gone"
pass "a5 the task record is gone"
want "a6 the closing move is stamped adapter:cleanup" "adapter:cleanup" "$(sql "SELECT closed_by FROM item WHERE key='cleanup:main/task-x1'")"
n=$(moves); cl run main task-x1 --source cleanup:task-x1 >/dev/null
want "a7 the same call twice changes nothing" "$n" "$(moves)"
out=$(cl compare "$C"); rc=$?
want "c1 compare prints nothing after a clean return" "0|" "$rc|$out"

# ---------------------------------------------------------------- b: refusals keep the item with the lead, and the copy
world later; land_recut; open_cleanup
GIT_COMMITTER_DATE="@$((LANDED_AT + 100))" commit_file later.txt 'unlanded work'
head=$(git -C "$WT" rev-parse HEAD)
cl run main task-x1 --source cleanup:task-x1 >/dev/null
want "b1 a commit made after the landing leaves the item open" "open|" "$(state_of)"
want "b2 the refusal is one note with the script's reason" "1" "$(notes)"
sql "SELECT why FROM move WHERE key='cleanup:main/task-x1' AND verb='note'" | grep -qi 'refus' || fail "b3 the note must carry the refusal text"
pass "b3 the note carries the refusal text"
[ -d "$WT" ] && [ -e "$C/state/task-x1.meta" ] || fail "b4 the refused cleanup removed the copy or its record"
want "b4 nothing is removed: the copy still holds its head" "$head" "$(git -C "$WT" rev-parse HEAD)"
cl run main task-x1 --source cleanup:task-x1 >/dev/null
want "b5 the same refusal again is not a second note" "1" "$(notes)"
out=$(cl compare "$C"); rc=$?
want "c2 compare prints nothing for a finished lane with its open cleanup item" "0|" "$rc|$out"

world dirty; land_recut; open_cleanup
printf 'uncommitted\n' >> "$WT/feature.txt"
cl run main task-x1 --source cleanup:task-x1 >/dev/null
want "b6 uncommitted work leaves the item open" "open|" "$(state_of)"
want "b7 and the uncommitted bytes are kept" "uncommitted" "$(tail -n 1 "$WT/feature.txt")"
want "b8 and it is one refusal note" "1" "$(notes)"

# ---------------------------------------------------------------- c: a finished lane's copy with no cleanup item
world nocleanup; land_recut
out=$(cl compare "$C"); rc=$?
want "c3 a finished lane's copy with no cleanup item is listed once" "1 1" "$(printf '%s\n' "$out" | grep -c 'task-x1') $rc"
open_cleanup; rm -f "$C/state/task-x1.meta"
out=$(cl compare "$C"); rc=$?
want "c4 an open cleanup item with no copy on disk is listed once" "1 1" "$(printf '%s\n' "$out" | grep -c 'cleanup:main/task-x1') $rc"
n=$(moves); cl run main task-x1 --source cleanup:task-x1 >/dev/null
want "c5 a copy already gone closes the item with nothing to return" "done|cleaned:task-x1 (no copy left)" "$(state_of)"
cl run main task-x1 --source cleanup:task-x1 >/dev/null; m=$(moves)
cl run main task-x1 --source cleanup:task-x1 >/dev/null
want "c6 a closed item is never run again" "$m" "$(moves)"

# ---------------------------------------------------------------- d, e: an update closes when the home runs the release
world upd
H=$C/homes; mkdir -p "$H"
git init -q -b main "$H/a"; git -C "$H/a" commit -q --allow-empty -m base
git -C "$H/a" checkout -q -b rel; printf 'v1\n' > "$H/a/f.txt"; git -C "$H/a" add f.txt; git -C "$H/a" commit -q -m 'release v1'
REL=$(git -C "$H/a" rev-parse HEAD)
open_update() { ji open "update:$1@$REL" --kind update --home "$1" --subject "$REL" --owes "run release $REL" --source "release:$REL" >/dev/null || fail "the update item must open"; }
upd_state() { sql "SELECT state||'|'||coalesce(outcome,'') FROM item WHERE key='update:$1@$REL' ORDER BY gen DESC LIMIT 1"; }
open_update main; open_update lagging; open_update recut; open_update ahead
git -C "$H/a" checkout -q main
cp -a "$H/a" "$H/lag"; cp -a "$H/a" "$H/recut"; cp -a "$H/a" "$H/ahead"
want "d1 a lagging home's update stays open" "open" "$(cl update lagging "$H/lag" "$REL" --source "update:lagging@$REL")"
want "d2 and keeps no outcome" "open|" "$(upd_state lagging)"
git -C "$H/ahead" merge -q --ff-only "$REL"
want "d3 a home with the release under HEAD closes its update" "done" "$(cl update ahead "$H/ahead" "$REL" --source "update:ahead@$REL")"
want "d4 the update closes home-at:<HEAD>" "done|home-at:$(git -C "$H/ahead" rev-parse HEAD)" "$(upd_state ahead)"
GIT_COMMITTER_DATE="@$(( $(date +%s) + 60 ))" git -C "$H/recut" -c user.email=t@t -c user.name=t cherry-pick "$REL" >/dev/null 2>&1 || fail "d5 fixture: the re-cut must apply"
[ "$(git -C "$H/recut" rev-parse HEAD)" != "$REL" ] || fail "d5 fixture: the re-cut must have a new hash"
want "d5 a re-cut release (same patch id) closes its update" "done" "$(cl update recut "$H/recut" "$REL" --source "update:recut@$REL")"
want "d6 with the home's HEAD as proof" "done|home-at:$(git -C "$H/recut" rev-parse HEAD)" "$(upd_state recut)"
n=$(moves); cl update ahead "$H/ahead" "$REL" --source "update:ahead@$REL" >/dev/null; cl update lagging "$H/lag" "$REL" --source "update:lagging@$REL" >/dev/null
want "e1 each update call twice changes nothing" "$n" "$(moves)"

# ---------------------------------------------------------------- f: sweep runs both for each open item and prints nothing
world sweep; land_recut; open_cleanup
git -C "$C" init -q -b main; git -C "$C" commit -q --allow-empty -m "the home"
REL=$(git -C "$C" rev-parse HEAD)
ji open "update:main@$REL" --kind update --home main --subject "$REL" --owes "run release $REL" --source "release:$REL" >/dev/null || fail "the update item must open"
out=$(cl sweep 2>&1); rc=$?
want "f1 sweep prints nothing and exits 0" "0|" "$rc|$out"
want "f2 sweep returned the finished lane's copy" "done|cleaned:task-x1" "$(state_of)"
want "f2b and closed the home's update" "done|home-at:$REL" "$(sql "SELECT state||'|'||outcome FROM item WHERE key='update:main@$REL'")"
n=$(moves); out=$(cl sweep 2>&1)
want "f3 sweep twice changes nothing" "$n|" "$(moves)|$out"
printf 'item-store-cleanup-update: ok\n'
