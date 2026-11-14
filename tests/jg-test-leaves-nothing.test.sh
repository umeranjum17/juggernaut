#!/usr/bin/env bash
# shellcheck disable=SC2016 # fixture text keeps its dollar signs literal
# jg-7v6uw-s49: a test run leaves no link, file or copy in the tree it ran in.
# Proves the nesting hazard (a plain ln -s into a fixture entry that already links to the real tree writes
# core/core there), the lint that refuses it, and a before/after listing around a real link-building test.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
D=$(jg_test_tmproot jg-test-leaves-nothing)
trap jg_test_cleanup EXIT

# 1. The hazard: the second plain link lands INSIDE the real directory; -n refuses it instead.
mkdir -p "$D/real/core" "$D/home"
ln -s "$D/real/core" "$D/home/core"
ln -s "$D/real/core" "$D/home/core"
[ -L "$D/real/core/core" ] || fail 'fixture did not reproduce the nested stray link'
rm "$D/real/core/core"
ln -sn "$D/real/core" "$D/home/core" 2>/dev/null && fail 'ln -sn replaced or nested an existing link'
[ ! -e "$D/real/core/core" ] || fail 'ln -sn wrote a link inside the real tree'
pass 'ln -sn never writes a link inside the real tree'

# 2. The lint refuses a test with the plain same-name link and passes the -sn one, through the real caller.
mkdir -p "$D/repo/bin" "$D/repo/tests"
cp "$ROOT/bin/jg-lint.sh" "$D/repo/bin/"
bad=$D/repo/tests/bad.test.sh
good=$D/repo/tests/good.test.sh
printf '#!/usr/bin/env bash\nln -s "$ROOT/core" "$H/core"\n' > "$bad"
printf '#!/usr/bin/env bash\nln -sn "$ROOT/core" "$H/core"\n' > "$good"
if (cd "$D/repo" && bash bin/jg-lint.sh --fast tests/bad.test.sh >"$D/bad.out" 2>&1); then fail 'lint passed a plain ln -s of a same-name entry'; fi
grep -q 'ln -sn' "$D/bad.out" || fail 'lint refusal did not name the fix'
(cd "$D/repo" && bash bin/jg-lint.sh --fast tests/good.test.sh >"$D/good.out" 2>&1) || fail "lint refused the -sn form: $(cat "$D/good.out")"
pass 'lint refuses a plain ln -s fixture link and passes ln -sn'

# 3. The tree has no plain same-name link left.
if grep -rHnP '\bln -sf? +"?[^ ]*/([\w.-]+)"? +"?[^ ]*/\1"?(?=[ ;&|)]|$)' "$ROOT/tests" "$ROOT"/core/*/tests 2>/dev/null | grep -v 'jg-test-leaves-nothing.test.sh'; then fail 'a test still links with plain ln -s'; fi
pass 'no test links with plain ln -s'

# 4. Before/after listing of the repo around a real fixture-home test is equal.
list() { (cd "$ROOT" && find . -path ./.git -prune -o -path ./.claude/settings.local.json -prune -o -path '*/__pycache__' -prune -o -print | LC_ALL=C sort); }
list > "$D/before"
bash "$ROOT/tests/jg-stops.test.sh" >/dev/null 2>&1 || fail 'jg-stops.test.sh failed'
list > "$D/after"
cmp -s "$D/before" "$D/after" || fail "the test left something behind: $(diff "$D/before" "$D/after" | head -5)"
pass 'a link-building test leaves the listing equal'
