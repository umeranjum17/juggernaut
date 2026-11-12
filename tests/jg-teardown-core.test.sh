#!/usr/bin/env bash
# The landed-work test, proved end to end through the dispatcher bin/jg-teardown.sh calls:
# bin/jg-teardown-core.sh builds the Go command on first use and answers "has this worktree's work
# landed?". The expected answers are the shell test's, pinned by the parity replay over the
# forge's recorded pull requests (core/teardown/README.md); this suite keeps the shapes that
# replay found interesting, and tests/jg-teardown.test.sh drives the same test through teardown.
# Usage: tests/jg-teardown-core.test.sh
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lab=$(mktemp -d "${TMPDIR:-/tmp}/jg-teardown-core.XXXXXX")
trap 'rm -rf -- "$lab"' EXIT
export JG_STATE_OVERRIDE=$lab/state TMPDIR=$lab
if ! command -v "${JG_TEARDOWN_CORE_GO:-go}" >/dev/null 2>&1; then
  printf 'skip: no Go toolchain on PATH; install go to build the landed-work check\n'
  exit 0
fi
fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok: %s\n' "$1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
core=$ROOT/bin/jg-teardown-core.sh
g() { git -c user.email=t@t -c user.name=t "$@"; }

# A project whose origin is a local bare repository, a task branch with one commit, and a fake
# forge: `gh` answers from $lab/forge, `gh-axi` reports no PR for any branch.
git init -q --bare -b main "$lab/origin.git"
g clone -q "$lab/origin.git" "$lab/proj" 2>/dev/null
( cd "$lab/proj" && g checkout -q -b main && echo base > f && g add f && g commit -q -m base && g push -q origin main && git remote set-head origin main >/dev/null )
g clone -q "$lab/origin.git" "$lab/wt" 2>/dev/null
( cd "$lab/wt" && g checkout -q -b task && echo work > w && g add w && g commit -q -m work )
head=$(git -C "$lab/wt" rev-parse HEAD)
mkdir -p "$lab/bin"
cat > "$lab/bin/gh" <<'GH'
#!/usr/bin/env bash
[ -f "$FORGE" ] || exit 1
cat "$FORGE"
GH
cat > "$lab/bin/gh-axi" <<'AXI'
#!/usr/bin/env bash
printf 'count: 0\npull_requests: []\n'
AXI
chmod +x "$lab/bin/gh" "$lab/bin/gh-axi"
export PATH=$lab/bin:$PATH FORGE=$lab/forge
land() { "$core" landed --worktree "$lab/wt" --branch task --project "$lab/proj" "$@"; }
tab=$(printf '\t')

check "the default branch is origin's HEAD" "$("$core" default-branch --project "$lab/proj")" main

rm -f "$FORGE"
out=$(land --pr-url https://github.com/o/r/pull/7); rc=$?
check "an unreadable GitHub forge refuses and names the gap" "$rc|$(printf '%s' "$out" | grep -c 'could not be read for PR')" "1|1"
check "that refusal is not softened by unrelated content on main" "$(printf '%s' "$out" | grep -c "HEAD is not on origin/main")" 1

printf 'OPEN%s%s%shttps://github.com/o/r/pull/7\n' "$tab" "$head" "$tab" > "$FORGE"
out=$(land --pr-url https://github.com/o/r/pull/7); rc=$?
check "an open PR is decisive: no fallback stands in" "$rc|$(printf '%s' "$out" | grep -c 'as OPEN, not merged')|$(printf '%s' "$out" | grep -c 'and this copy')" "1|1|0"

printf 'MERGED%s%s%shttps://github.com/o/r/pull/7\n' "$tab" "$head" "$tab" > "$FORGE"
out=$(land --pr-url https://github.com/o/r/pull/7); rc=$?
check "a merged PR whose head holds this copy's HEAD is landed" "$rc|$out" "0|landed=yes
pr_url=https://github.com/o/r/pull/7"

( cd "$lab/wt" && echo more > w2 && g add w2 && g commit -q -m unlanded )
out=$(land --pr-url https://github.com/o/r/pull/7); rc=$?
check "a commit the merged PR head lacks is not landed" "$rc|$(printf '%s' "$out" | grep -c 'does not contain this copy')" "1|1"

printf 'MERGED%s%s%s\n' "$tab" "$head" "$tab" > "$FORGE"
( cd "$lab/wt" && g reset -q --hard "$head" )
out=$(land); rc=$?
check "a merged PR with no recorded URL and no URL from the forge is not landed" "$rc|$(printf '%s' "$out" | grep -c 'branch task')" "1|1"

# Squash flow: main gains the same content as one new commit, and the branch is never pushed.
( cd "$lab/proj" && echo work > w && g add w && g commit -q -m "squash (#7)" && g push -q origin main )
rm -f "$FORGE"
out=$(land --base-branch main); rc=$?
check "content already on the default branch lands a branch with no PR" "$rc|$out" "0|landed=yes"

# A pull request merged into its own base branch: the release branch carries the merge and the
# default branch does not. The copy sits on the merged release tip, so the merge landed there
# even though main has not caught up, and the notice for this merged pull request must stop.
g init -q --bare -b main "$lab/rel-origin.git"
g clone -q "$lab/rel-origin.git" "$lab/rel-proj" 2>/dev/null
( cd "$lab/rel-proj" && g checkout -q -b main && echo base > f && g add f && g commit -q -m base \
  && git push -q origin main \
  && g checkout -q -b release/c-15 && echo rel > r && g add r && g commit -q -m "release work" \
  && echo work > w && g add w && g commit -q -m "squash (#9)" && git push -q origin release/c-15 \
  && git remote set-head origin main >/dev/null )
g clone -q -b release/c-15 "$lab/rel-origin.git" "$lab/rel-wt" 2>/dev/null
prhead=$(git -C "$lab/rel-wt" rev-parse HEAD~1)
rel_land() { "$core" landed --worktree "$lab/rel-wt" --branch task --project "$lab/rel-proj" --pr-url https://github.com/o/r/pull/9; }
printf 'MERGED%s%s%shttps://github.com/o/r/pull/9%srelease/c-15\n' "$tab" "$prhead" "$tab" "$tab" > "$FORGE"
out=$(rel_land); rc=$?
check "a PR merged into its release base branch lands a copy on it, though main lacks the merge" "$rc|$out" "0|landed=yes
pr_url=https://github.com/o/r/pull/9"
printf 'OPEN%s%s%shttps://github.com/o/r/pull/9%srelease/c-15\n' "$tab" "$prhead" "$tab" "$tab" > "$FORGE"
out=$(rel_land); rc=$?
check "a pull request the forge reports open still refuses, so its notice still fires" "$rc|$(printf '%s' "$out" | grep -c 'as OPEN, not merged')" "1|1"
printf 'MERGED%s%s%s\n' "$tab" "$head" "$tab" > "$FORGE"
out=$(JG_TEARDOWN_CORE_BIN=$lab/none/jg-teardown-core JG_TEARDOWN_CORE_GO=$lab/no-such-go "$core" landed --worktree "$lab/wt" --project "$lab/proj" 2>&1); rc=$?
check "no binary and no toolchain exits 2, never 0" "$rc" 2
check "a request with no worktree exits 2" "$("$core" landed --project "$lab/proj" >/dev/null 2>&1; echo $?)" 2
check "an unknown command exits 2" "$("$core" nonsense >/dev/null 2>&1; echo $?)" 2

# The worktree safety test (`safety`): nothing uncommitted, nothing unpushed that nobody absorbed.
# Refusals print their sentences on stderr; exit 3 means a git index lock stopped a read.
g clone -q "$lab/origin.git" "$lab/wt2" 2>/dev/null
safe() { "$core" safety --worktree "$lab/wt2" --project "$lab/proj" "$@" 2>&1; }
out=$(safe --pr-url https://github.com/o/r/pull/7); rc=$?
check "a clean copy at origin's tip proves nothing is lost" "$rc" 0
echo hand > "$lab/wt2/.jg-kimi-turnend"
out=$(safe); rc=$?
check "the fleet's own turn-end file never blocks a return" "$rc" 0
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo u > "$lab/wt2/u$i"; done
out=$(safe); rc=$?
check "untracked work refuses, naming ten paths and omitting the rest" "$rc|$(printf '%s' "$out" | grep -c '^  u')|$(printf '%s' "$out" | grep -c 'additional untracked paths omitted')|$(printf '%s' "$out" | grep -c 'untracked-only leftovers')" "1|10|1|1"
echo more >> "$lab/wt2/f"
out=$(safe); rc=$?
check "a tracked edit refuses and says so" "$rc|$(printf '%s' "$out" | grep -c 'includes tracked edits')" "1|1"
rm -f "$lab"/wt2/u*; ( cd "$lab/wt2" && git checkout -q -- f && rm -f .jg-kimi-turnend )
( cd "$lab/wt2" && g checkout -q -b local && echo l > l && g add l && g commit -q -m local )
out=$(safe --local); rc=$?
check "a local-only commit on no remote and not on main refuses" "$rc|$(printf '%s' "$out" | grep -c 'not yet merged into main')|$(printf '%s' "$out" | grep -c 'commits not yet on main')" "1|1|1"
out=$(safe); rc=$?
check "a pushed-mode copy with unpushed work needs the forge, and lists the commits" "$rc|$(printf '%s' "$out" | grep -c 'unpushed commits:')" "1|1"
check "a pushed-mode copy reports the branch it asked about" "$("$core" safety --worktree "$lab/wt2" --project "$lab/proj" 2>/dev/null | grep '^branch=')" "branch=local"
check "a cached branch is asked about instead of the current one" "$("$core" safety --worktree "$lab/wt2" --project "$lab/proj" --cached-branch fm/x 2>/dev/null | grep '^branch=')" "branch=fm/x"
: > "$lab/wt2/.git/index.lock"; printf 'garbage' > "$lab/wt2/.git/index"
out=$(safe); rc=$?
check "an unreadable index behind a lock asks the caller to prove the lock stale" "$rc|$(printf '%s' "$out" | grep -c 'checking whether the lock is stale')" "3|1"
rm -f "$lab/wt2/.git/index.lock"
out=$(safe); rc=$?
check "an unreadable index with no lock is a final refusal" "$rc|$(printf '%s' "$out" | grep -c 'cannot inspect worktree')" "1|1"
check "a missing worktree has nothing to protect" "$("$core" safety --worktree "$lab/gone" --project "$lab/proj" >/dev/null 2>&1; echo $?)" 0

# ---- process reaping (needs lsof; the tmux process-group fallback needs none) -------------------
reap() { "$core" reap --label worktree --task-id tid --backend "${BACKEND:-tmux}" --target %7 --caller-pid $$ -- "$@"; }
mkdir -p "$lab/leak"
if command -v lsof >/dev/null 2>&1; then
  ( cd "$lab/leak" && exec perl -e 'sleep 300' ) & leaked=$!; disown
  sleep 0.3
  out=$(reap "$lab/leak" 2>&1); rc=$?
  sleep 0.1
  check "a process left under a directory is ended" "$rc|$(kill -0 "$leaked" 2>/dev/null && echo alive || echo gone)|$(printf '%s' "$out" | grep -c "reaping leaked worktree process(es) for tid: $leaked")" "0|gone|1"
  ( cd "$lab/leak" && exec perl -e '$SIG{TERM}="IGNORE"; sleep 300' ) & leaked=$!; disown
  sleep 0.3
  out=$(reap "$lab/leak" 2>&1); rc=$?
  check "a process that ignores TERM is force-killed" "$rc|$(printf '%s' "$out" | grep -c "force-killing leaked worktree process(es) for tid: $leaked")" "0|1"
  kill -KILL "$leaked" 2>/dev/null
  check "an empty directory and a missing directory reap nothing" "$(reap "$lab/leak" "$lab/none" "" >/dev/null 2>&1; echo $?)" 0
  mkdir -p "$lab/nolsof"
  for c in perl sed tr sort ps; do ln -sf "$(command -v $c)" "$lab/nolsof/$c"; done
  out=$(PATH=$lab/nolsof "$lab/state/bin/jg-teardown-core" reap --label worktree --task-id tid --backend herdr --target x --caller-pid $$ -- "$lab/leak" 2>&1); rc=$?
  check "without lsof the fallback only warns, and never for another backend's group" "$rc|$out" "0|warning: lsof is unavailable; cannot resolve a process-group fallback for herdr task tid"
else
  printf 'skip: no lsof on PATH; the process-reaping checks need it\n'
fi
check "a reap request with a bad caller pid exits 2" "$("$core" reap --caller-pid x -- "$lab/leak" >/dev/null 2>&1; echo $?)" 2

# ---- removal validators ------------------------------------------------------------------------
mkdir -p "$lab/rhome" "$lab/rrepo" "$lab/scratch" "$lab/seeded/data" "$lab/seeded/state"
rem() { "$core" validate-removal --jg-home "$lab/rhome" --jg-root "$lab/rrepo" --label scratch -- "$@"; }
check "a directory outside the home and repo may be removed and is printed canonically" "$(rem "$lab/scratch/")" "$lab/scratch"
check "an empty target and a missing target have nothing to remove" "$(rem ""; rem "$lab/none")|$(rem "" >/dev/null 2>&1; echo $?)" "|0"
out=$(rem "$lab/rhome" 2>&1); rc=$?
check "the active home is never removed" "$rc|$out" "1|REFUSED: unsafe scratch removal target $lab/rhome is the active juggernaut home"
out=$(rem "$lab" 2>&1); rc=$?
check "an ancestor of the home is never removed" "$rc|$(printf '%s' "$out" | grep -c 'is an ancestor of the active juggernaut home')" "1|1"
out=$(rem "$lab/rrepo" 2>&1); rc=$?
check "the repo is never removed" "$rc|$(printf '%s' "$out" | grep -c 'is the juggernaut repo')" "1|1"
check "the filesystem root is never removed" "$(rem / 2>&1 | grep -c 'unsafe scratch removal target /')" 1

home_check() { "$core" validate-home --jg-home "$lab/rhome" --jg-root "$lab/rrepo" --label "squad_lead home" --registry "$lab/registry.md" --marker .marker "$@"; }
out=$(home_check --expected-id sl1 -- "$lab/seeded" 2>&1); rc=$?
check "a directory without the seeded-home marker is not a Squad Lead home" "$rc|$out" "1|REFUSED: unsafe squad_lead home removal target $lab/seeded is not a seeded squad_lead home"
printf 'sl1\n' > "$lab/seeded/.marker"
check "a seeded home with no registry is removable" "$(home_check --expected-id sl1 -- "$lab/seeded" 2>&1)" "$lab/seeded"
out=$(home_check --expected-id sl2 -- "$lab/seeded" 2>&1)
check "a home marked for another Squad Lead is refused" "$out" "REFUSED: unsafe squad_lead home removal target $lab/seeded is marked for squad_lead sl1, expected sl2"
printf -- '- sl1 - lead (home: %s; scope: x; projects: p; added 2026-10-01)\n- kid - child (home: %s/kid; scope: x; projects: p; added 2026-10-01)\n' "$lab/seeded" "$lab/seeded" > "$lab/registry.md"
mkdir -p "$lab/seeded/kid"
out=$(home_check --expected-id sl1 -- "$lab/seeded" 2>&1); rc=$?
check "a home that holds another registered home is refused as overlapping" "$rc|$(printf '%s' "$out" | grep -c 'overlapping squad_lead home assignment')" "1|1"
printf -- '- sl1 - lead (home: %s; scope: x; projects: p; added 2026-10-01)\n' "$lab/seeded" > "$lab/registry.md"
printf -- '- kid - child (home: %s/kid; scope: x; projects: p; added 2026-10-01)\n' "$lab/seeded" > "$lab/seeded/data/squad_leads.md"
out=$(home_check --expected-id sl1 -- "$lab/seeded" 2>&1); rc=$?
check "a child registered in the home's own registry is refused" "$rc|$out" "1|REFUSED: unsafe squad_lead home removal target $lab/seeded contains registered squad_lead home $lab/seeded/kid for kid"
rm "$lab/seeded/data/squad_leads.md"; ln -s "$lab/scratch" "$lab/seeded/config"
out=$(home_check --expected-id sl1 -- "$lab/seeded" 2>&1); rc=$?
check "an operational directory that leaves the home is refused" "$rc|$(printf '%s' "$out" | grep -c 'config directory .* resolves outside the squad_lead home')" "1|1"
rm "$lab/seeded/config"
check "a clean seeded home passes and prints its canonical path" "$(home_check --expected-id sl1 -- "$lab/seeded" 2>&1)" "$lab/seeded"

child_check() { "$core" validate-child --jg-home "$lab/rhome" --jg-root "$lab/rrepo" --project "$lab/proj" -- "$@"; }
( cd "$lab/proj" && g worktree add -q -b childwt "$lab/childwt" )
check "a worktree git lists for the project may be removed" "$(child_check "$lab/childwt" 2>&1)" "$lab/childwt"
out=$(child_check "$lab/scratch" 2>&1); rc=$?
check "a directory git does not list is not a child worktree" "$rc|$out" "1|REFUSED: unsafe child worktree removal target $lab/scratch is not a git worktree for $lab/proj"
check "worktree-registered answers by exit code" "$("$core" worktree-registered --project "$lab/proj" -- "$lab/childwt"; echo $?)$("$core" worktree-registered --project "$lab/proj" -- "$lab/scratch"; echo $?)" "01"
check "a validator with no target exits 2" "$("$core" validate-removal --jg-home x --jg-root y >/dev/null 2>&1; echo $?)" 2

# Local-trunk landing needs no release push; a project not in trunk mode is unchanged. The copy
# is a real worktree of the project, so it sees the project's trunk ref as teardown's copies do.
rm -f "$FORGE"
( cd "$lab/proj" && g fetch -q origin && g worktree add -q -b trunkwork "$lab/twt" origin/main )
( cd "$lab/twt" && echo t > t && g add t && g commit -q -m trunkwork )
trunk_land() { "$core" landed --worktree "$lab/twt" --branch trunkwork --project "$lab/proj" --trunk-branch trunk; }
( cd "$lab/proj" && g branch -q trunk trunkwork )
out=$(trunk_land); rc=$?
check "a trunk commit with no release ref is landed" "$rc|$out" "0|landed=yes"
( cd "$lab/twt" && g push -q origin trunkwork:refs/heads/release/c-2 )
out=$(trunk_land); rc=$?
check "a commit on the trunk and a pushed release branch is landed" "$rc|$out" "0|landed=yes"
out=$("$core" landed --worktree "$lab/twt" --branch trunkwork --project "$lab/proj"); rc=$?
check "the same copy without trunk mode is still refused" "$rc|$(printf '%s' "$out" | grep -c '^landed=no')" "1|1"
( cd "$lab/proj" && g branch -q -D trunk && g branch -q trunk main )
out=$(trunk_land); rc=$?
check "a pushed release commit that is not on the local trunk is not landed" "$rc|$(printf '%s' "$out" | grep -c "is not on the local trunk")" "1|1"

# An empty lane (HEAD is still the commit it started on) is an ancestor of the trunk and of the
# default branch, but nothing landed: both the landed test and the safety test refuse it. A lane with
# one commit of its own, on the trunk, is still landed.
( cd "$lab/proj" && g worktree add -q -b emptywork "$lab/ewt" origin/main )
ebase=$(g -C "$lab/ewt" rev-parse HEAD)
empty_land() { "$core" landed --worktree "$lab/ewt" --branch emptywork --project "$lab/proj" --trunk-branch trunk --lane-base "$ebase"; }
( cd "$lab/proj" && g branch -q -f trunk "$ebase" )
out=$(empty_land); rc=$?
check "an empty lane on the trunk is not landed" "$rc|$(printf '%s' "$out" | grep -c 'holds no work of its own')" "1|1"
out=$("$core" safety --worktree "$lab/ewt" --project "$lab/proj" --local --trunk-branch trunk --lane-base "$ebase" 2>&1); rc=$?
check "teardown's safety test refuses an empty lane" "$rc|$(printf '%s' "$out" | grep -c 'holds no work of its own')" "1|1"
( cd "$lab/ewt" && echo e > e && g add e && g commit -q -m emptywork && g -C "$lab/proj" branch -q -f trunk emptywork )
out=$(empty_land); rc=$?
check "the same lane with one commit on the trunk is landed" "$rc|$out" "0|landed=yes"

[ "$fails" -eq 0 ] || { printf '%d check(s) failed\n' "$fails"; exit 1; }
printf 'all jg-teardown-core tests passed\n'
