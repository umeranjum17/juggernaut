#!/usr/bin/env bash
# tests/jg-installed-drift.test.sh - an installed runtime copy is compared with the repo copy it came from.
#
# Silent drift is the failure: the running copy keeps a retired or edited file while the repo is already right.
# The check stays silent when copies match, names both paths on one line per finding, and never passes a copy whose
# repo directory it cannot discover, and the exit stays 0 in every case.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK=$(jg_test_tmproot jg-installed-drift)
repo=$WORK/repo
share=$WORK/share
mkdir -p "$repo/core/demo/bin" "$share/fm-demo/bin"
printf 'installed\n' >"$repo/core/demo/bin/tool.sh"
printf 'readme\n' >"$repo/core/demo/README.md"
cp -p "$repo/core/demo/bin/tool.sh" "$share/fm-demo/bin/tool.sh"
cp -p "$repo/core/demo/README.md" "$share/fm-demo/README.md"
drift() { JG_HOME=$WORK/home "$ROOT/bin/jg-installed-drift.sh" --root "$repo" --data-home "$share"; }
one_line() { [ "$(printf '%s\n' "$1" | wc -l)" -eq 1 ] || fail "expected exactly one line, got: $1"; }

out=$(drift) || fail "the check must exit 0"
[ -z "$out" ] || fail "a matching copy must print nothing, got: $out"

printf 'changed\n' >"$share/fm-demo/bin/tool.sh"
out=$(drift) || fail "a drifted copy must still exit 0"
one_line "$out"
assert_contains "$out" "differ $share/fm-demo/bin/tool.sh $repo/core/demo/bin/tool.sh" \
  "one changed byte names the running path, the repo path and differ"

cp -p "$repo/core/demo/bin/tool.sh" "$share/fm-demo/bin/tool.sh"
printf 'retired\n' >"$share/fm-demo/stale.sh"
out=$(drift)
one_line "$out"
assert_contains "$out" "missing $share/fm-demo/stale.sh $repo/core/demo/stale.sh" \
  "an installed file the repo dropped is reported missing"

mkdir -p "$share/jg-orphan"
printf 'x\n' >"$share/jg-orphan/x.sh"
out=$(drift) || fail "an unknown-origin copy must still exit 0"
assert_contains "$out" "unknown origin $share/jg-orphan" "a copy with no discoverable repo directory is reported, never passed"

# arm is the registration an feature installer performs: it must leave a bound check in a real home.
mkdir -p "$WORK/armed/state"
JG_HOME=$WORK/armed JG_STATE_OVERRIDE=$WORK/armed/state "$ROOT/bin/jg-installed-drift.sh" arm >/dev/null \
  || fail "arm must register the check in a home"
[ -s "$WORK/armed/state/installed-drift.check-trust" ] || fail "arm must leave the check bound"

pass "jg-installed-drift.sh: silent when equal, one line per differ, missing or unknown origin"
