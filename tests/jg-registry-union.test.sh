#!/usr/bin/env bash
# Behavior test for slice H0 of the self-healing plan: registry files merge by union and bin/jg-registry-lint.sh keeps each lane to its own
# block. It runs the real git rebase with this repo's .gitattributes and the real lint, in a throwaway repo.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/jg-registry-lint.sh"
T=$(cd "$(jg_test_tmproot jg-registry-union)" && pwd); R=$T/repo
mkdir -p "$R"; cd "$R" || exit 1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c commit.gpgsign=false "$@"; }
g init -q -b trunk .; mkdir docs
cp "$ROOT/.gitattributes" .gitattributes
printf 'app: x\njourneys:\n  one:\n    tier: local\n    command: bash one.sh\n  two:\n    tier: local\n    command: bash two.sh\n\nsecrets:\n  allow:\n    - a\n' > .done-done.yaml
printf '# Machines\n| Machine | Owner |\n| --- | --- |\n| `alpha` | a.sh |\n' > docs/state-machines.md
g add -A; g commit -qm base
lint() { OUT=$(bash "$LINT" "$@" 2>&1); RC=$?; }

# 1. The attributes name both registry files.
assert_contains "$(g check-attr merge .done-done.yaml docs/state-machines.md)" "union" "registry files carry merge=union"
assert_equals 2 "$(g check-attr merge .done-done.yaml docs/state-machines.md | grep -c 'merge: union')" "both registry files merge by union"

# 2. Two lanes each add one journey and one table row at the same place; they rebase one after the other with no conflict.
add_lane() {  # <branch> <journey> <row>
  g checkout -q -b "$1" trunk
  awk -v j="$2" '/^secrets:/ { printf "  %s:\n    tier: local\n    command: bash %s.sh\n\n", j, j } { print }' .done-done.yaml > y.tmp && mv y.tmp .done-done.yaml
  printf '| `%s` | %s.sh |\n' "$3" "$3" >> docs/state-machines.md
  g commit -qam "lane $1"
}
add_lane lane-a three gamma; add_lane lane-b four delta
g checkout -q lane-a; g checkout -q trunk; g merge -q --ff-only lane-a 2>&1 | tail -1
g checkout -q lane-b; g rebase trunk >/dev/null 2>&1; expect_code 0 $? "the second lane rebases onto the first with no conflict"
for w in '  three:' '  four:' '  one:' '  two:' 'secrets:'; do assert_contains "$(cat .done-done.yaml)" "$w" "merged journey file keeps $w"; done
assert_equals 1 "$(grep -c '^journeys:' .done-done.yaml)" "merged journey file has one journeys key"
assert_contains "$(cat docs/state-machines.md)" '`gamma`' "merged table keeps the first lane's row"
assert_contains "$(cat docs/state-machines.md)" '`delta`' "merged table keeps the second lane's row"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  python3 -I -c 'import sys,yaml; d=yaml.safe_load(open(".done-done.yaml")); assert set(d["journeys"])=={"one","two","three","four"}' ; expect_code 0 $? "the merged journey file still parses"
fi

# 3. The lint passes a lane that only added its own blocks (against its base).
lint --base lane-a; expect_code 0 "$RC" "adding your own journey and row is clean"

# 4. A lane that edits another journey, or another table row, is refused with the entry named.
g checkout -q -b edit-yaml trunk; sed -i 's/bash one.sh/bash one-changed.sh/' .done-done.yaml; g commit -qam edit
lint --base trunk; expect_code 1 "$RC" "editing another journey is refused"; assert_contains "$OUT" "bash one.sh" "the refusal names the changed journey"
g checkout -q -b edit-md trunk; sed -i 's/a.sh/b.sh/' docs/state-machines.md; g commit -qam edit2
lint --base trunk; expect_code 1 "$RC" "editing another table row is refused"; assert_contains "$OUT" "alpha" "the refusal names the changed row"
g checkout -q -b drop trunk; g rm -q docs/state-machines.md; g commit -qm drop
lint --base trunk; expect_code 1 "$RC" "removing a registry file is refused"
lint --base nosuchref; expect_code 2 "$RC" "a bad ref is a usage error"
pass "registry files merge by union and the lint keeps each lane to its own block"
