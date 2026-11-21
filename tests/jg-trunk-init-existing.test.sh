#!/usr/bin/env bash
# Integration test for the trunk-landing init loop and bin/jg-trunk.sh init, through the real lander over a real project
# (tests/jg-trunk-fixture.sh). A trunk branch can exist in a clone while this home has no record of it (another home shares the clone,
# or the record was lost); trunk-landing then asked init for a new trunk on every tick and git answered "cannot lock ref
# 'refs/heads/trunk': reference already exists" (five Squad Lead homes, 19 Nov 2026).
#
# T1 init names the cause in its refusal and leaves the branch and the home's records as they were.
# T2 The landing check reports that refusal once; a second tick with the same cause says nothing.
# T3 Once the home has its record again, the check reports nothing and the memory of the refusal is gone.
# T4 A trunk ref that names a commit the clone does not hold reads as absent to a commit lookup but exists to git: init names that cause,
#    and the tick never shows git's "cannot lock ref" (the muxr, takeone and writeboost homes, 21 Nov 2026).
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

lost_record_world() {  # <name>
  world "$1"
  mv "$HOME_D/state/trunk-tip-proj" "$W/tip.saved"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"   # the check runs the home's own bin
}
tick() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" 2>&1; }

test_init_names_the_existing_branch() {
  lost_record_world names
  local before out rc=0; before=$(tip)
  out=$(trunk init "$PROJ" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "init must refuse an existing trunk branch"
  case $out in *"branch trunk already exists in $PROJ but this home has no record of it"*) ;; *) fail "the refusal must name the cause: $out" ;; esac
  case $out in *"update_ref failed"*|*"cannot lock ref"*) fail "git's own ref error must not reach the owner: $out" ;; esac
  [ "$(tip)" = "$before" ] || fail "the trunk branch must not move"
  [ ! -e "$HOME_D/state/trunk-tip-proj" ] || fail "init must write no record"
  pass 'init names an existing trunk branch with no home record and changes nothing'
}

test_the_tick_reports_once() {
  lost_record_world once
  local first second
  first=$(tick); second=$(tick)
  case $first in *"this home has no record of it"*) ;; *) fail "the first tick must report the refusal: $first" ;; esac
  case $second in *"no record of it"*) fail "the second tick must stay silent: $second" ;; esac
  pass 'the landing check reports the refused init once, not every tick'
}

test_a_restored_record_clears_the_memory() {
  lost_record_world restored
  tick >/dev/null
  [ -s "$HOME_D/data/jg-trunk-landing/.init-refused-proj" ] || fail "the refusal must be remembered"
  mv "$W/tip.saved" "$HOME_D/state/trunk-tip-proj"
  tick | grep -q 'no record of it' && fail "with the record back the tick must not report"
  pass 'a restored record stops the report'
}

# The trunk ref of a clone that lost the commit it names (a pruned or never-fetched object).
unreadable_trunk_world() {  # <name>
  lost_record_world "$1"
  printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$PROJ/.git/refs/heads/trunk"
}

test_a_ref_naming_a_missing_commit_is_named() {
  unreadable_trunk_world unreadable
  local out rc=0 first second; out=$(trunk init "$PROJ" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "init must refuse a trunk ref that exists"
  case $out in *"names a commit that clone does not hold"*) ;; *) fail "the refusal must name the cause: $out" ;; esac
  case $out in *"update_ref failed"*|*"cannot lock ref"*) fail "git's own ref error must not reach the owner: $out" ;; esac
  [ ! -e "$HOME_D/state/trunk-tip-proj" ] || fail "init must write no record"
  first=$(tick); second=$(tick)
  case $first in *"names a commit that clone does not hold"*) ;; *) fail "the first tick must report the cause: $first" ;; esac
  case $first$second in *"cannot lock ref"*) fail "no tick may show git's ref error: $first$second" ;; esac
  [ -z "$second" ] || fail "the second tick must stay silent: $second"
  pass 'a trunk ref naming a missing commit is named once, never as git'"'"'s cannot lock ref'
}

test_init_names_the_existing_branch
test_the_tick_reports_once
test_a_restored_record_clears_the_memory
test_a_ref_naming_a_missing_commit_is_named
