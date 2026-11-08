#!/usr/bin/env bash
# Scope of the trunk flow: every trunk rule (bin/jg-trunk.sh, core/trunk-landing, the spawn refusal and the brief
# section) applies to a project registered LOCAL-TRUNK only. Projects registered direct-PR, no-mistakes or
# local-only keep their own rules exactly as before, even when a stray trunk record sits beside them.
#
# T1 For each of direct-PR, no-mistakes and local-only: a stray trunk branch and record do not make the project a
#    trunk project - jg-trunk.sh refuses every subcommand naming the registered mode and touches nothing, the
#    landing check lands nothing, and the registry still answers "<mode> off".
# T2 direct-PR still opens its PR: its brief still tells the worker to push and open the PR, with no trunk section.
# T3 no-mistakes still runs its pipeline: its brief still carries the pipeline hand-off, with no trunk section.
# T4 local-only still stops at a ready branch and merges locally: its brief ends at "ready in branch", and
#    bin/jg-merge-local.sh still fast-forwards local main, with no trunk section.
# T5 the converse: the same project registered local-trunk IS a trunk project (the guard against a test that passes
#    because nothing is ever treated as local-trunk).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-trunk-scope)

# world <name> <registered-mode>: a home and a project registered in that mode with a stray trunk beside it.
world() {
  W="$TMP_ROOT/$1"; H="$W/home"; P="$H/projects/proj"
  mkdir -p "$H/state" "$H/data" "$H/config" "$W/fakebin"
  jg_test_beads_home "$H"
  printf -- '- proj [%s] - fixture (added 2026-11-07)\n' "$2" > "$H/data/projects.md"
  jg_git_init_commit "$P"; git -C "$P" branch -M main
  git -C "$P" branch trunk
  git -C "$P" rev-parse trunk > "$H/state/trunk-tip-proj"
}
jgt() { JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" JG_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/jg-trunk.sh" "$@"; }
lane() {  # <id> <mode>: a one-commit lane with a PASS receipt
  git -C "$P" worktree add -q -b "fm/$1" "$W/lane-$1" main
  printf 'x\n' > "$W/lane-$1/work.txt"; git -C "$W/lane-$1" add work.txt
  git -C "$W/lane-$1" -c user.name=t -c user.email=t@example.invalid commit -q -m "ticket $1"
  jg_write_meta "$H/state/$1.meta" "project=$P" "mode=$2" "branch=fm/$1" "worktree=$W/lane-$1" "spawn_gen=g-$1" "kind=ship"
  printf '{"schema":1,"task":"%s","mode":"%s","spawn_gen":"g-%s","head":"%s","pr":"","verdict":"PASS","at":1,"evidence":"ok"}\n' \
    "$1" "$2" "$1" "$(git -C "$P" rev-parse "fm/$1")" > "$H/state/$1.run-receipt.json"
}
brief() {  # <id> <mode> [<extra args>...]
  local id=$1 mode=$2; shift 2
  JG_HOME="$H" JG_DATA_OVERRIDE="$H/data" "$ROOT/bin/jg-brief.sh" "$id" proj --mode "$mode" --project "$P" "$@" >/dev/null 2>&1 || fail "could not scaffold the $mode brief"
  cat "$H/data/$id/brief.md"
}

charter() {  # <id> <project>: a squad lead charter naming the project
  JG_HOME="$H" JG_DATA_OVERRIDE="$H/data" "$ROOT/bin/jg-brief.sh" "$1" --squad-lead "$2" >/dev/null 2>&1 || fail "could not scaffold the squad lead charter"
  cat "$H/data/$1/brief.md"
}

for mode in direct-PR no-mistakes local-only; do
  world "stray-$mode" "$mode"
  tip=$(git -C "$P" rev-parse trunk); lane s1 local-only
  for sub in "land s1" "verify $P" "live $P" "release $P" "rollover $P" "init $P"; do
    # shellcheck disable=SC2086
    out=$(jgt $sub 2>&1) && fail "T1 jg-trunk.sh $sub must refuse a $mode project: $out"
    assert_contains "$out" "is registered $mode in data/projects.md, not local-trunk" "T1 jg-trunk.sh $sub must name the registered mode"
  done
  [ "$(git -C "$P" rev-parse trunk)" = "$tip" ] || fail "T1 a $mode project's trunk branch must not move"
  [ ! -e "$(git -C "$P" rev-parse --git-common-dir)/hooks/reference-transaction" ] || fail "T1 no trunk hook may be installed in a $mode project"
  cp -r "$ROOT/bin" "$H/bin"; ln -s "$ROOT/core" "$H/core"; ln -s "$ROOT/policy" "$H/policy"
  out=$(bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$H" 2>&1); sleep 1
  [ -z "$out" ] && [ ! -e "$H/data/jg-trunk-landing/s1.$(git -C "$P" rev-parse fm/s1).state" ] || fail "T1 the landing check must not touch a $mode project: $out"
  [ "$(git -C "$P" rev-parse trunk)" = "$tip" ] || fail "T1 the landing check must not land on a $mode project"
  [ "$(JG_HOME="$H" "$ROOT/bin/jg-project-mode.sh" proj 2>/dev/null)" = "$mode off" ] || fail "T1 the registry must still answer '$mode off'"
  pass "T1 a $mode project is never treated as local-trunk, even with a stray trunk record"
done

world direct-pr direct-PR
b=$(brief d1 direct-PR)
assert_contains "$b" "open a PR with \`gh-axi\`" "T2 direct-PR must still tell the worker to open its PR"
assert_not_contains "$b" "Local trunk lane" "T2 a direct-PR brief must carry no trunk section"
assert_not_contains "$b" "LATEST tip of the local trunk" "T2 a direct-PR brief must carry no trunk rebase rule"
lead=$(charter lead-d proj); assert_not_contains "$lead" "Local trunk projects" "T2 a direct-PR project's squad lead charter must carry no trunk rule"
pass "T2 direct-PR still opens its PR"

world nomistakes no-mistakes
b=$(brief n1 no-mistakes --risk release)
assert_contains "$b" "no-mistakes" "T3 no-mistakes must keep its pipeline contract"
assert_contains "$b" "/no-mistakes" "T3 no-mistakes must still hand off to the pipeline"
assert_not_contains "$b" "Local trunk lane" "T3 a no-mistakes brief must carry no trunk section"
assert_not_contains "$b" "LATEST tip of the local trunk" "T3 a no-mistakes brief must carry no trunk rebase rule"
lead=$(charter lead-n proj); assert_not_contains "$lead" "Local trunk projects" "T3 a no-mistakes project's squad lead charter must carry no trunk rule"
pass "T3 no-mistakes still runs its pipeline"

world localonly local-only
b=$(brief l1 local-only)
assert_contains "$b" "ready in branch" "T4 local-only must still stop at a ready branch"
assert_contains "$b" "guarded fast-forward path" "T4 local-only must still merge locally"
assert_not_contains "$b" "Local trunk lane" "T4 a local-only brief must carry no trunk section"
assert_not_contains "$b" "LATEST tip of the local trunk" "T4 a local-only brief must carry no trunk rebase rule"
lead=$(charter lead-l proj); assert_not_contains "$lead" "Local trunk projects" "T4 a local-only project's squad lead charter must carry no trunk rule"
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: T4 local merge needs a Beads store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
else
  jg_test_beads_home "$H"; jg_test_add "$H" jg-l2 "[feature] local merge"
  lane jg-l2 local-only; before=$(git -C "$P" rev-parse main)
  out=$(JG_HOME="$H" JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" JG_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/jg-merge-local.sh" jg-l2 2>&1) || fail "T4 local-only must still merge locally: $out"
  [ "$(git -C "$P" rev-parse main)" = "$(git -C "$P" rev-parse fm/jg-l2)" ] && [ "$(git -C "$P" rev-parse main)" != "$before" ] || fail "T4 local main must be fast-forwarded to the lane"
fi
pass "T4 local-only still stops at a ready branch and merges locally"

world trunkmode local-trunk
b=$(brief t1 local-only)
assert_contains "$b" "Local trunk lane" "T5 a local-trunk project's lane brief must carry the trunk section"
assert_contains "$b" "rebase it on the LATEST tip of the local trunk" "T5 the lane brief must tell the worker to rebase on the latest trunk tip"
assert_contains "$b" "YOU resolve every conflict" "T5 the lane brief must make the worker resolve conflicts"
assert_contains "$b" "never force a landing" "T5 the lane brief must forbid a forced landing"
lead=$(charter lead-t proj)
assert_contains "$lead" "Local trunk projects" "T5 a local-trunk project's squad lead charter must carry the trunk rule"
assert_contains "$lead" "rebase it on the LATEST tip of the local trunk" "T5 the charter must carry the rebase rule"
assert_contains "$lead" "never force a landing" "T5 the charter must forbid a forced landing"
jgt verify "$P" 2>&1 | grep -q "is registered" && fail "T5 a local-trunk project must not be refused as another mode"
[ "$(JG_HOME="$H" "$ROOT/bin/jg-project-mode.sh" proj 2>/dev/null)" = "local-only off" ] || fail "T5 mechanical callers must see a local-trunk project as local-only"
[ "$(JG_HOME="$H" "$ROOT/bin/jg-project-mode.sh" --raw proj 2>/dev/null)" = "local-trunk off" ] || fail "T5 --raw must say local-trunk"
pass "T5 a project registered local-trunk is a trunk project"
printf 'jg-trunk-scope: ok\n'
