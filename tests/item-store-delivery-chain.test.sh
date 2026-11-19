#!/usr/bin/env bash
# The delivery chain of the item store, end to end, through the adapters of slices 3, 5a, 5b, 5c and 5d (dispatch, lane, trunk, merge,
# cleanup), in one scratch git world: approval, dispatch, work, done with its receipt, land (closed `trunk:<commit>`), the release
# (the scratch project shares its origin URL with the main home, and data/squad_leads.md names one local lead home, so the release
# opens update:main@<head> and update:lead@<head>), the release pull request merged by the real merge-on-green, each update closed by
# `cleanup.py sweep` once that home's HEAD has the release (the lagging lead's stays open until it pulls), and the cleanup of the lane's
# copy by the real bin/jg-teardown.sh. Every step's item closes, and nothing is left open.
# shellcheck disable=SC2016 # the stand-in commands written below expand their own arguments
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$HERE/lib.sh"
jg_git_identity fmtest fmtest@example.invalid
ITEM=$ROOT/core/item-store
AD=$ITEM/adapters
TMP_ROOT=$(jg_test_tmproot item-store-chain)
unset JG_TASK_ID JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
export JG_ITEM_TICK_LEASE_S=0
want() { [ "$3" = "$2" ] || fail "$1: wanted [$2], got [$3]"; pass "$1"; }

C=$TMP_ROOT/home; P=$C/project; WT=$C/wt; L=$C/lead; FB=$C/fakebin
TASK=task-x1; TICKET=TK-1; PR=7
mkdir -p "$C/state" "$C/config" "$C/data" "$C/bin" "$FB" "$L"
jg_test_beads_home "$C"
jg_test_backlog "$C" add "$TASK" "[feature] chain fixture" --priority 1 --kind ship --repo demo --body "fixture" >/dev/null
jg_test_backlog "$C" start "$TASK" >/dev/null
# the forge and the cleanup's tools: no pull request is found for the lane's branch; the merge commit of any pull request is c0ffee1
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/treehouse"; cp "$FB/treehouse" "$FB/tmux"
printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in\n  "pr list") printf "%%s\\n" "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;\nesac\nexit 1\n' > "$FB/gh-axi"
printf '#!/usr/bin/env bash\ncase " $* " in *mergeCommit*) echo c0ffee1; exit 0 ;; *" state "*) echo MERGED; exit 0 ;; esac\nexit 1\n' > "$FB/gh"
# merge-on-green's stand-ins in the home: the crew state, the pull request state and the merge command
printf '#!/usr/bin/env bash\necho "state: done · source: status-log · ready"\n' > "$C/bin/jg-crew-state.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$C/bin/jg-pr-state.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$C/bin/jg-trunk.sh"
printf '#!/usr/bin/env bash\necho "merged $2"\n' > "$C/bin/jg-pr-merge.sh"
chmod +x "$FB"/* "$C"/bin/*.sh
export PATH=$FB:$PATH

git init -q --bare "$C/origin.git"; git -C "$C/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$C/origin.git" "$C/seed" 2>/dev/null; git -C "$C/seed" commit -q --allow-empty -m baseline; git -C "$C/seed" push -q origin HEAD:main; rm -rf "$C/seed"
git clone -q "$C/origin.git" "$P"; git -C "$P" remote set-head origin main 2>/dev/null || true
git -C "$P" worktree add -q -b "fm/$TASK" "$WT" main
# the main home is a clone of the same origin, as Main's own checkout is; the lead's home is another, and lags
git -C "$C" init -q -b main; git -C "$C" remote add origin "$(git -C "$P" remote get-url origin)"; git -C "$C" fetch -q origin
git -C "$C" reset -q --hard origin/main 2>/dev/null; git -C "$C" branch -q --set-upstream-to=origin/main main
git clone -q "$C/origin.git" "$L/repo"
printf '%s\n' "- lead - fixture Squad Lead (home: $L/repo; scope: x; projects: project; added 2026-11-19)" > "$C/data/squad_leads.md"
printf '%s\n' '- project [local-trunk +yolo] - fixture' > "$C/data/projects.md"
touch "$C/state/.last-watcher-beat"; : > "$C/config/item-store"
JG_HOME="$C" ITEM="$ITEM" python3 -I -c 'import os, sys; sys.path.insert(0, os.environ["ITEM"]); import itemdb
st = itemdb.open_db(os.environ["JG_HOME"], "owner:registry"); at = itemdb.stamp(st)
st.set_policy(at, "project", "loose", st.me, "test:policy", mode="local-trunk")'

sql() { python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1] + "/state/item-store/fleet.db")
for r in c.execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$C" "$1"; }
ad()  { local a=$1; shift; env JG_HOME="$C" JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$C/state" JG_DATA_OVERRIDE="$C/data" \
          JG_CONFIG_OVERRIDE="$C/config" python3 -I "$AD/$a.py" "$@"; }
st_of() { sql "SELECT state||'|'||coalesce(outcome,'') FROM item WHERE key='$1' ORDER BY gen DESC LIMIT 1"; }

# ---------------------------------------------------------------- approval, dispatch
ad dispatch approve main "$TICKET" --source "approval:$TICKET@1"
want "1 an approval opens the dispatch" "open|" "$(st_of "dispatch:main/$TICKET")"
jg_write_meta "$C/state/$TASK.meta" "window=juggernaut:jg-$TASK" "endpoint_task_id=$TASK" "worktree=$WT" "project=$P" "kind=ship" \
  "mode=local-trunk" "spawn_gen=chain-$TASK" "ticket=$TICKET" "yolo=on"
ad dispatch spawned main "$TASK" --source "spawn:$TASK"
want "2 the spawn closes the dispatch with the lane" "done|lane:$TASK" "$(st_of "dispatch:main/$TICKET")"
want "3 and opens the lane's work" "open|" "$(st_of "work:main/$TASK")"

# ---------------------------------------------------------------- work, done with receipt, land
printf 'Umer feature\n' > "$WT/feature.txt"; git -C "$WT" add feature.txt; git -C "$WT" commit -q -m "$TASK: feature"
HEAD_=$(git -C "$WT" rev-parse HEAD)
printf '{"verdict":"PASS","head":"%s","spawn_gen":"chain-%s"}\n' "$HEAD_" "$TASK" > "$C/state/$TASK.run-receipt.json"
printf 'done [at=%s] [head=%s]: ready in branch fm/%s (local-trunk)\n' "$(date +%s)" "$HEAD_" "$TASK" > "$C/state/$TASK.status"
ad lane read "$C/state/$TASK.status" >/dev/null
want "4 the done line closes the work with its receipt" "done|receipt:$TASK.run-receipt.json" "$(st_of "work:main/$TASK")"
want "5 and opens the land and the cleanup" "open|open" "$(st_of "land:main/$TICKET@$HEAD_" | cut -d'|' -f1)|$(st_of "cleanup:main/$TASK" | cut -d'|' -f1)"
# the trunk lander re-cuts the commit (same patch, new hash) and writes its landing row
AT=$(git -C "$WT" show -s --format=%ct HEAD)
REBASED=$(git -C "$P" commit-tree "$HEAD_^{tree}" -p main -m "$TASK: feature (re-cut)")
git -C "$P" branch trunk "$REBASED"
printf 'trunk\n' > "$C/state/trunk-branch-project"; printf '%s\n' "$REBASED" > "$C/state/trunk-tip-project"
printf '%s\t%s\t%s\t%s\tfull\n' "$TASK" project "$REBASED" "$AT" > "$C/data/trunk-landings.tsv"
ad trunk landed main "$TICKET" "$HEAD_" "$REBASED" --source "land:$TASK@$REBASED" >/dev/null
want "6 the landing closes the land item trunk:<commit>" "done|trunk:$REBASED" "$(st_of "land:main/$TICKET@$HEAD_")"

# ---------------------------------------------------------------- release: the push, the release pull request merged by merge-on-green
ad trunk pushed project "$PR" "$REBASED" --source "push:$REBASED" >/dev/null
want "7 the push opens the release step" "open|" "$(st_of "release:project@$PR")"
jg_write_meta "$C/state/release-project-trunk.meta" "kind=release" "project=$P" "yolo=on" "merge=approved" "merge_rule=gated:yolo" \
  "pr=https://github.com/ex/r/pull/$PR" "pr_head=$REBASED" "spawn_gen=g"
printf 'project\tyolo\n' > "$C/data/trunk-gated.tsv"
printf '{"verdict":"PASS","head":"%s","spawn_gen":"g"}\n' "$REBASED" > "$C/state/release-project-trunk.run-receipt.json"
printf '#!/usr/bin/env bash\necho "checks-lint: PASS: 1 evidence file"\n' > "$C/lint.sh"; chmod +x "$C/lint.sh"
out=$(env JG_HOME="$C" JG_MOG_CHECKS_LINT="$C/lint.sh" JG_CHECK_TIMEOUT=60 "$ROOT/core/merge-on-green/merge-on-green.sh" check "$C" 2>&1)
case $out in *"merged release-project-trunk"*) pass "8 merge-on-green merged the release pull request" ;; *) fail "8 merge-on-green did not merge the release: $out" ;; esac
want "9 a release pull request writes no merge item" "0" "$(sql "SELECT count(*) FROM item WHERE kind='merge'")"
git -C "$P" push -q origin "$REBASED:refs/heads/main"            # the merge lands the release on origin's main
ad trunk released project "$PR" "$REBASED" --project-dir "$P" --source "merged:$PR@$REBASED" >/dev/null     # what `jg-trunk.sh rollover` does
want "10 the rollover closes the release step" "done|released:$PR at $REBASED" "$(st_of "release:project@$PR")"
want "11 and opens one update for Main and one for the lead" "update:lead@$REBASED update:main@$REBASED" \
  "$(sql "SELECT key FROM item WHERE kind='update' ORDER BY key" | paste -sd' ')"

# ---------------------------------------------------------------- updates and cleanup through the sweep
ad cleanup sweep >/dev/null 2>&1
want "12 no home has the release yet, so no update closes" "open|open" "$(st_of "update:main@$REBASED" | cut -d'|' -f1)|$(st_of "update:lead@$REBASED" | cut -d'|' -f1)"
want "13 sweep returned the lane's copy: the cleanup closes cleaned:" "done|cleaned:$TASK" "$(st_of "cleanup:main/$TASK")"
[ ! -e "$C/state/$TASK.meta" ] || fail "14 the task record must be gone after the cleanup"
pass "14 the task record is gone"
git -C "$C" fetch -q origin; git -C "$C" merge -q --ff-only origin/main
ad cleanup sweep >/dev/null 2>&1
want "15 once Main's HEAD has the release its update closes home-at:<HEAD>" "done|home-at:$(git -C "$C" rev-parse HEAD)" "$(st_of "update:main@$REBASED")"
want "16 the lagging lead's update stays open" "open" "$(st_of "update:lead@$REBASED" | cut -d'|' -f1)"
git -C "$L/repo" pull -q --ff-only origin main
ad cleanup sweep >/dev/null 2>&1
want "17 once the lead pulls, its update closes" "done|home-at:$(git -C "$L/repo" rev-parse HEAD)" "$(st_of "update:lead@$REBASED")"
want "18 every step's item is done: dispatch work land release update update cleanup" "7" "$(sql "SELECT count(*) FROM item WHERE state='done' AND kind IN ('dispatch','work','land','release','update','cleanup')")"
want "19 nothing is left open" "0" "$(sql "SELECT count(*) FROM item WHERE state='open'")"
out=$(ad cleanup compare "$C"); rc=$?
want "20 compare prints nothing at the end" "0|" "$rc|$out"
printf 'item-store-delivery-chain: ok\n'
