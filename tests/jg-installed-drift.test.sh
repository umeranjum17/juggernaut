#!/usr/bin/env bash
# tests/jg-installed-drift.test.sh - an installed runtime copy is compared with the repo copy it came from.
#
# Silent drift is the failure: the running copy keeps a retired or edited file while the repo is already right.
# The check stays silent when copies match, names both paths on one line per differing file, and the exit stays 0 in
# every case. Runtime files the installer creates and data directories are not drift and print nothing.
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
printf 'runtime\n' >"$share/fm-demo/prev-hooks-path"
mkdir -p "$share/fm-demo/hooks.d/pre-push"
printf 'runtime\n' >"$share/fm-demo/hooks.d/pre-push/guard"
printf 'x\n' >"$share/fm-demo/gh.real"
out=$(drift)
[ -z "$out" ] || fail "runtime files with no repo counterpart are not drift, got: $out"

mkdir -p "$share/jg-orphan"
printf 'x\n' >"$share/jg-orphan/x.sh"
out=$(drift) || fail "a data directory must still exit 0"
[ -z "$out" ] || fail "a directory with no repo origin is data, not drift, got: $out"

# An fm-<x> copy whose jg-<x> twin is installed is legacy: hidden by default, printed by --all; one without a twin stays.
mkdir -p "$repo/core/twin/bin" "$share/fm-twin" "$share/jg-twin" "$share/fm-solo"
printf 'a\n' >"$repo/core/twin/bin/t.sh"; printf 'old\n' >"$share/fm-twin/t.sh"; cp -p "$repo/core/twin/bin/t.sh" "$share/jg-twin/t.sh"
rm -rf "$share/jg-orphan"
printf 'old\n' >"$share/fm-solo/s.sh"
out=$(drift)
case $out in *fm-twin*) fail "a legacy fm- copy with an installed jg- twin must be hidden, got: $out" ;; esac
printf 'edited\n' >"$share/fm-solo/s.sh"; mkdir -p "$repo/core/solo"; printf 'new\n' >"$repo/core/solo/s.sh"
out=$(drift)
assert_contains "$out" "differ $share/fm-solo/s.sh" "an fm- copy with no jg- twin is not legacy and stays visible"
out=$(JG_HOME=$WORK/home "$ROOT/bin/jg-installed-drift.sh" --all --root "$repo" --data-home "$share")
assert_contains "$out" "$share/fm-twin/t.sh" "--all prints the legacy copy"

# Dedupe: an unchanged finding set wakes once, a changed set at once, a cleared drift re-arms, and a reminder is long.
# A home of its own keeps this record apart from the runs above; the same three-line fixture drifts in turn.
rm -rf "$share/fm-twin" "$share/jg-twin" "$share/fm-solo" "$repo/core/solo" "$repo/core/twin"
sweep() { JG_HOME=$WORK/dedupe "$ROOT/bin/jg-installed-drift.sh" --root "$repo" --data-home "$share"; }
printf 'drifted\n' >"$share/fm-demo/bin/tool.sh"
out=$(sweep); one_line "$out"
for n in 1 2 3; do
  out=$(sweep)
  [ -z "$out" ] || fail "sweep $n of an unchanged finding set must stay silent, got: $out"
done
printf 'drifted\n' >"$share/fm-demo/README.md"
out=$(sweep)
[ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ] || fail "a changed finding set must print at once, got: $out"
out=$(sweep); [ -z "$out" ] || fail "the changed set is unchanged on the next sweep, got: $out"
cp -p "$repo/core/demo/bin/tool.sh" "$share/fm-demo/bin/tool.sh"; cp -p "$repo/core/demo/README.md" "$share/fm-demo/README.md"
out=$(sweep); [ -z "$out" ] || fail "a clean pass must print nothing, got: $out"
printf 'drifted\n' >"$share/fm-demo/bin/tool.sh"
out=$(sweep); one_line "$out"
out=$(JG_INSTALLED_DRIFT_REMIND_SECS=0 sweep); one_line "$out"
cp -p "$repo/core/demo/bin/tool.sh" "$share/fm-demo/bin/tool.sh"

# arm is the registration an feature installer performs: it must leave a bound check in a real home.
mkdir -p "$WORK/armed/state"
JG_HOME=$WORK/armed JG_STATE_OVERRIDE=$WORK/armed/state "$ROOT/bin/jg-installed-drift.sh" arm >/dev/null \
  || fail "arm must register the check in a home"
[ -s "$WORK/armed/state/installed-drift.check-trust" ] || fail "arm must leave the check bound"

pass "jg-installed-drift.sh: silent when equal or runtime-only, one line per differing file"
