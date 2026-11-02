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
out=$(JG_TEARDOWN_CORE_BIN=$lab/none/jg-teardown-core JG_TEARDOWN_CORE_GO=$lab/no-such-go "$core" landed --worktree "$lab/wt" --project "$lab/proj" 2>&1); rc=$?
check "no binary and no toolchain exits 2, never 0" "$rc" 2
check "a request with no worktree exits 2" "$("$core" landed --project "$lab/proj" >/dev/null 2>&1; echo $?)" 2
check "an unknown command exits 2" "$("$core" nonsense >/dev/null 2>&1; echo $?)" 2

[ "$fails" -eq 0 ] || { printf '%d check(s) failed\n' "$fails"; exit 1; }
printf 'all jg-teardown-core tests passed\n'
