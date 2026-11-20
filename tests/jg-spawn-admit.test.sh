#!/usr/bin/env bash
# A spawn refuses a plan-filed ticket of another repository, one with an open edge, and one whose file
# another live lane holds; a ticket whose files are here, whose edges are closed and whose files are free
# launches. Each case runs the real bin/jg-spawn.sh on a real Beads store.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-admit)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
mkdir -p "$PROJ/bin"
printf 'v1\n' > "$PROJ/AGENTS.md"; printf 'a\n' > "$PROJ/bin/here.sh"; printf 'b\n' > "$PROJ/bin/other.sh"
git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
jg_test_spawn_home "$HOME_DIR"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"
bd_() { JG_HOME=$HOME_DIR python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" "$@"; }

# lane <id> <label> <files json> [new files json]: file a plan-filed row, scaffold its brief, spawn it; sets out, rc.
lane() {
  local label=$2 files=$3 new=${4:-[]} wt="$W/wt-$1"; id=$1
  jg_test_add "$HOME_DIR" "$id" "[feature] admit $id"
  bd_ update "$id" --remove-label project:demo --add-label "project:$label" --set-metadata "files=$files" \
    --set-metadata "new_files=$new" >/dev/null 2>&1 || fail "could not set the plan fields of $id"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" --migration-row none >/dev/null 2>&1 \
    || fail "could not scaffold the brief for $id"
  sed -i "s|{TASK}|Admit $id.|;s|{JUGGERNAUT_SPEC}|Exercise the admission check.|" "$HOME_DIR/data/$id/brief.md"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  out=$(jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off); rc=$?
}
refused() {  # <word>: the last lane was refused for that reason and wrote no task record
  expect_code 1 "$rc" "$1: the spawn must refuse: $out"
  assert_contains "$out" "$1" "the refusal must name $1"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused ticket wrote a task record"
}

lane jg-ad1 elsewhere '["bin/here.sh"]'
refused "wrong-repo: ticket jg-ad1 belongs to elsewhere, not proj"
echo "ok - a ticket labelled for another repository is refused"

lane jg-ad2 proj '["bin/here.sh","bin/not-in-proj.sh"]'
refused "bin/not-in-proj.sh"
echo "ok - a ticket whose file this repository lacks is refused"

lane jg-ad3 proj '["bin/here.sh"]'
expect_code 0 "$rc" "a ticket whose files are here and free must launch: $out"
echo "ok - a ticket of this repository launches"

bd_ update jg-ad3 --status in_progress >/dev/null 2>&1 || fail "could not mark the live lane"
lane jg-ad4 proj '["bin/other.sh","bin/here.sh"]'
refused "held-file: bin/here.sh is held by the live lane jg-ad3"
echo "ok - a file another live lane holds is refused"

lane jg-ad5 proj '["bin/other.sh","bin/made.sh"]' '["bin/made.sh"]'
expect_code 0 "$rc" "a file the ticket makes needs no copy here: $out"
echo "ok - a new file is not looked for"

jg_test_add "$HOME_DIR" jg-ad6dep "[feature] the dependency"
lane jg-ad6 proj '["bin/new6.sh"]' '["bin/new6.sh"]'
expect_code 0 "$rc" "setup: no edge yet must launch: $out"
jg_test_add "$HOME_DIR" jg-ad7 "[feature] waits"
bd_ update jg-ad7 --add-label project:proj --set-metadata 'files=["bin/new7.sh"]' --set-metadata 'new_files=["bin/new7.sh"]' >/dev/null 2>&1
bd_ dep add jg-ad7 jg-ad6dep >/dev/null 2>&1 || fail "could not add the edge"
JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" jg-ad7 proj --mode direct-PR --project "$PROJ" --migration-row none >/dev/null 2>&1 || fail "brief"
sed -i "s|{TASK}|Admit 7.|;s|{JUGGERNAUT_SPEC}|Exercise the admission check.|" "$HOME_DIR/data/jg-ad7/brief.md"
git -C "$PROJ" worktree add -q --detach "$W/wt-jg-ad7" origin/main >/dev/null 2>&1
id=jg-ad7; out=$(jg_test_run_spawn "$HOME_DIR" "$W/wt-jg-ad7" "$FAKEBIN" jg-ad7 "$PROJ" codex --mode direct-PR --yolo off); rc=$?
refused "open-edge: ticket jg-ad7 waits for jg-ad6dep"
echo "ok - an open edge is refused"

# A project registered local-trunk keeps its clone on the default branch while its lanes start on the trunk tip, so a
# file that exists only on the trunk is looked for there; a file on neither is still refused, and a project that is
# not local-trunk is still judged on its checked-out branch.
TPROJ="$W/tproj"
git clone -q "$W/origin.git" "$TPROJ" 2>/dev/null
git -C "$TPROJ" fetch -q; git -C "$TPROJ" remote set-head origin main >/dev/null 2>&1 || true
git -C "$TPROJ" checkout -q -b release/v12 origin/main
printf 'c\n' > "$TPROJ/bin/trunk-only.sh"; git -C "$TPROJ" add -A; git -C "$TPROJ" commit -qm "trunk-only file"
git -C "$TPROJ" rev-parse release/v12 > "$HOME_DIR/state/trunk-tip-tproj"
printf 'release/v12\n' > "$HOME_DIR/state/trunk-branch-tproj"
git -C "$TPROJ" checkout -q main
# lane_in <id> <project dir> <mode> <files json> <start ref>: like lane, for another project and mode.
lane_in() {
  local dir=$2 name; name=$(basename "$2"); id=$1
  jg_test_add "$HOME_DIR" "$id" "[feature] admit $id"
  bd_ update "$id" --remove-label project:demo --add-label "project:$name" --set-metadata "files=$4" --set-metadata "new_files=[]" >/dev/null 2>&1 \
    || fail "could not set the plan fields of $id"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" "$name" --mode "$3" --project "$dir" --migration-row none >/dev/null 2>&1 \
    || fail "could not scaffold the brief for $id"
  sed -i "s|{TASK}|Admit $id.|;s|{JUGGERNAUT_SPEC}|Exercise the admission check.|" "$HOME_DIR/data/$id/brief.md"
  git -C "$dir" worktree add -q --detach "$W/wt-$id" "$5" >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  out=$(jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" "$dir" codex --mode "$3" --yolo off); rc=$?
}
printf -- '- tproj [local-trunk] - fixture (added 2026-11-07)\n' > "$HOME_DIR/data/projects.md"

lane_in jg-ad8 "$TPROJ" local-trunk '["bin/trunk-only.sh"]' release/v12
expect_code 0 "$rc" "a file only the trunk tip has must pass for a local-trunk project: $out"
echo "ok - a local-trunk project's file that only the trunk has is found"

lane_in jg-ad9 "$TPROJ" local-trunk '["bin/trunk-only.sh","bin/nowhere.sh"]' release/v12
refused "bin/nowhere.sh"
echo "ok - a local-trunk project's file on neither the trunk nor the clone is still refused"

printf -- '- tproj [direct-PR] - fixture (added 2026-11-07)\n' > "$HOME_DIR/data/projects.md"
lane_in jg-ad10 "$TPROJ" direct-PR '["bin/trunk-only.sh"]' origin/main
refused "bin/trunk-only.sh"
echo "ok - a project that is not local-trunk is still judged on its checked-out branch"
