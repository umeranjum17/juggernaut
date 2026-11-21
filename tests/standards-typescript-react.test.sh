#!/usr/bin/env bash
# standards-typescript-react.test.sh - the TypeScript and React standards pack lints two ordinary projects as shipped.
#
# core/standards/typescript-react/ ships an ESLint preset (base.js) and an opt-in useEffect ban (bans/no-use-effect.js).
# This test copies the pack into a throwaway folder, installs the exact versions of its lockfile there (--ignore-scripts,
# a throwaway home, no live home read), then lints core/standards/typescript-react/fixtures/project-a (the preset) and
# project-b (the preset plus the ban) on ordinary project paths:
#   1. every rule R1, R1b, R2, R2b and R3-R7 raises its expected rule id on its fault file, and its allowed use,
#      including the shared api client that may call fetch, raises nothing (extra diagnostics are printed, not counted);
#   2. the lab-only eslint.noresolver.config.js, which lives in the fixture and never in the preset, strips the resolver
#      setting, and the folder rule (R6a, R6b) then reports inert: the control must fail, or the proof is not a proof;
#   3. the preset holds no process.env switch and no fixture or lab file name.
# Needs network for the install; fixtures/score.py is the scorer and owns the pass line.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PACK=core/standards/typescript-react
SRC=$ROOT/$PACK

for f in base.js bans/no-use-effect.js package.json package-lock.json README.md fixtures/score.py fixtures/README.md \
  fixtures/project-a/eslint.config.js fixtures/project-a/eslint.noresolver.config.js fixtures/project-b/eslint.config.js; do
  [ -f "$SRC/$f" ] || fail "$PACK/$f is missing"
done
pass "the pack and its fixtures are in $PACK"

# The preset is the product: no lab switch, no fixture or lab name, and the control config is not part of it.
[ "$(grep -c process.env "$SRC/base.js")" = 0 ] || fail "base.js reads process.env: a lab switch shipped in the preset"
if grep -nEi 'noresolver|lint-lab|LAB_|fixtures|project-[ab]' "$SRC/base.js" "$SRC/bans/no-use-effect.js"; then
  fail "the preset or a ban names a fixture or lab file"
fi
[ ! -e "$SRC/eslint.noresolver.config.js" ] || fail "the lab-only control config sits in the preset folder"
pass "the preset holds no process.env switch and no fixture or lab file name"

work=$(jg_test_tmpdir standards-ts-react)
pack=$work/pack
mkdir -p "$pack" "$work/home" "$work/cache" "$work/raw"
cp -R "$SRC/." "$pack/"
(
  cd "$pack" || exit 2
  HOME=$work/home npm_config_cache=$work/cache npm_config_userconfig=/dev/null \
    npm ci --ignore-scripts --no-audit --no-fund --silent
) >"$work/npm-ci.out" 2>&1 || { cat "$work/npm-ci.out" >&2; fail "npm ci from the lockfile failed"; }
pass "installed the lockfile's exact versions into a throwaway folder (--ignore-scripts)"

eslint=$pack/node_modules/eslint/bin/eslint.js
lint() {  # <project dir> <raw file> [eslint args...]: ESLint exits 1 on findings; only a crash (2) is a failure here
  local dir=$1 out=$2 rc
  shift 2
  (cd "$pack/fixtures/$dir" && HOME=$work/home node "$eslint" "$@" -f json src) >"$work/raw/$out" 2>"$work/raw/$out.err"
  rc=$?
  [ "$rc" -le 1 ] || { cat "$work/raw/$out.err" >&2; fail "eslint crashed on $dir ($out): exit $rc"; }
}
lint project-a a-eslint.json
lint project-a a-eslint-noresolver.json -c eslint.noresolver.config.js
lint project-b b-eslint.json
pass "linted project-a (preset), project-a with the resolver stripped (control) and project-b (preset plus ban)"

report=$(python3 -I "$pack/fixtures/score.py" "$work/raw" --check) || {
  printf '%s\n' "$report" >&2
  fail "the standards pack did not meet its proof (last line above)"
}
printf '%s\n' "$report"
result=$(printf '%s\n' "$report" | tail -n1)
[ "$result" = "faults 10/10, allowed 8/8, inert check ok" ] || fail "unexpected result line: $result"
pass "$result"
