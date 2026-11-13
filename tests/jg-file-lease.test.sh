#!/usr/bin/env bash
# A lane takes a lease on the files its ticket names at spawn: a second lane whose files overlap a live
# lease on a hot file is refused with the first lane's id and stays in ready, and starts once the first
# lane's record is gone (cleanup). A shared file that is not hot is never refused. Each case runs the
# real bin/jg-spawn.sh on a real Beads store.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-file-lease)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
mkdir -p "$PROJ/bin"
printf 'v1\n' > "$PROJ/AGENTS.md"; printf 'a\n' > "$PROJ/bin/hot.sh"; printf 'b\n' > "$PROJ/bin/plain.sh"
git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
jg_test_spawn_home "$HOME_DIR"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"
printf '# the hot files of this home\nbin/hot.sh\n' > "$HOME_DIR/config/hot-files"
bd_() { BEADS_DIR=$(tr -d '[:space:]' < "$HOME_DIR/config/beads-dir") "$ROOT/bin/jg-beads.sh" "$@"; }
LEASES="$HOME_DIR/state/file-leases"

# lane <id> <files json>: file a plan-filed row, scaffold its brief, spawn it; sets id, out, rc.
lane() {
  id=$1; local files=$2 wt="$W/wt-$1"
  bd_ show "$id" >/dev/null 2>&1 || jg_test_add "$HOME_DIR" "$id" "[feature] lease $id"
  bd_ update "$id" --remove-label project:demo --add-label project:proj --set-metadata "files=$files" >/dev/null 2>&1 || fail "could not set the plan fields of $id"
  [ -e "$HOME_DIR/data/$id/brief.md" ] || JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" --migration-row none >/dev/null 2>&1 \
    || fail "could not scaffold the brief for $id"
  grep -q '{TASK}' "$HOME_DIR/data/$id/brief.md" && sed -i "s|{TASK}|Lease $id.|;s|{JUGGERNAUT_SPEC}|Exercise the file lease.|" "$HOME_DIR/data/$id/brief.md"
  [ -d "$wt" ] || git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  out=$(jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off); rc=$?
}

lane jg-fl1 '["bin/hot.sh","bin/plain.sh"]'
expect_code 0 "$rc" "the first lane must launch: $out"
assert_contains "$(cat "$LEASES/jg-fl1")" "bin/hot.sh" "the spawn must write the lease of the first lane"
echo "ok - the spawn writes the lane's lease"

# The admission already refuses a file that an in-flight row holds. The lease is the record that does not
# depend on the row: reopen the first lane's row so only the lease can refuse the second lane.
bd_ update jg-fl1 --status open >/dev/null 2>&1 || fail "could not reopen the first lane's row"

lane jg-fl2 '["bin/hot.sh"]'
expect_code 1 "$rc" "a hot file another live lane leases must refuse the start: $out"
assert_contains "$out" "lease-held: bin/hot.sh is leased by the live lane jg-fl1" "the refusal must name the file and the holder"
[ ! -e "$HOME_DIR/state/jg-fl2.meta" ] || fail "a refused lane wrote a task record"
[ ! -e "$LEASES/jg-fl2" ] || fail "a refused lane took a lease"
echo "ok - a second lane on a hot leased file waits in ready and is told the holder's id"

lane jg-fl3 '["bin/plain.sh"]'
expect_code 0 "$rc" "a shared file that is not hot is never refused: $out"
echo "ok - a file that is not hot is not exclusive"

# Cleanup removes the holder's record; the grace that covers a spawn still writing it is spent.
[ -e "$HOME_DIR/state/jg-fl1.meta" ] || fail "setup: the first lane has no task record to clean up"
rm -f -- "$HOME_DIR/state/jg-fl1.meta"
export JG_FILE_LEASE_GRACE_S=0
lane jg-fl2 '["bin/hot.sh"]'
expect_code 0 "$rc" "once the holder is cleaned up the waiting lane must start: $out"
[ ! -e "$LEASES/jg-fl1" ] || fail "the lease of a cleaned-up lane was not removed"
assert_contains "$(cat "$LEASES/jg-fl2")" "bin/hot.sh" "the waiting lane must now hold the lease"
echo "ok - the lease ends at cleanup and the waiting lane starts"
