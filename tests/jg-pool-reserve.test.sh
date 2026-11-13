#!/usr/bin/env bash
# Copies follow the lane limit and two stay free for a red fix, through the real bin/jg-spawn.sh.
# The lane limit is 2, so the copy cap is 4. The worktree tool is a stand-in whose status shows the leased copies.
# T1 two copies leased (the lane limit): an ordinary lane defers with exit 75, no record, and no lease is asked for.
# T2 the same two leased: a red-fix lane passes the check and reaches the lease (the stand-in lease fails with its own cause).
# T3 four copies leased (the cap): the red-fix lane defers too.
# T4 one copy leased: an ordinary lane reaches the lease.
# T5 no lane limit: the check steps aside and the pool's own limit governs.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
jg_git_identity fmtest fmtest@example.com
D=$(jg_test_tmproot jg-pool-reserve)
W=$D/world; H=$W/home; P=$W/project
mkdir -p "$P"
git -C "$P" init -q
git -C "$P" commit -q --allow-empty -m initial
F=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$F"
cat > "$F/treehouse" <<'SH'
#!/usr/bin/env bash
case ${1:-} in
  get) echo "get" >> "$GET_LOG"; echo 'Error: stand-in lease refused' >&2; exit 1 ;;
  status) i=0; while [ "$i" -lt "${LEASED:-0}" ]; do i=$((i + 1)); printf '%s    leased       /fixture/%s  (held by lane-%s)\n' "$i" "$i" "$i"; done ;;
  *) exit 1 ;;
esac
SH
chmod +x "$F/treehouse"
export GET_LOG="$W/get.log"; : > "$GET_LOG"
jg_test_spawn_home "$H"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$H/config/host-memory"
printf 'mode=act\n' > "$H/config/lane-scale"
printf '2\n' > "$H/state/lane-limit"
N=0
spawn() {  # <leased> [spawn args]: spawn a fresh task; sets out, rc
  local leased=$1; shift; N=$((N + 1)); id=jg-res$N
  jg_test_spawn_brief "$H" "$id"
  case " $* " in *" --base-branch "*) printf '\nYou are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.\nBase branch: main\n' >> "$H/data/$id/brief.md" ;; esac
  out=$(LEASED=$leased jg_test_run_spawn "$H" "$P" "$F" "$id" "$P" codex --mode direct-PR --yolo off "$@"); rc=$?
}
spawn 2
expect_code 75 "$rc" "T1 an ordinary lane at the lane limit should defer: $out"
assert_contains "$out" "deferred:" "T1 the deferral line is missing"
assert_contains "$out" "stay free for a red fix" "T1 the deferral does not name the reserve"
[ ! -e "$H/state/$id.meta" ] || fail "T1 the deferred lane wrote a task record"
[ ! -s "$GET_LOG" ] || fail "T1 a deferred lane still asked for a copy"
pass "an ordinary lane at the lane limit defers and asks for no copy"
spawn 2 --base-branch main --red-fix-of main
expect_code 1 "$rc" "T2 a red-fix lane should pass the check and reach the lease: $out"
assert_contains "$out" "stand-in lease refused" "T2 the red-fix lane did not reach the lease"
[ -s "$GET_LOG" ] || fail "T2 the red-fix lane never asked for a copy"
pass "a red-fix lane uses a reserved copy"
: > "$GET_LOG"
spawn 4 --base-branch main --red-fix-of main
expect_code 75 "$rc" "T3 a red-fix lane at the cap should defer: $out"
assert_contains "$out" "cap of 4" "T3 the deferral does not name the cap"
[ ! -s "$GET_LOG" ] || fail "T3 a deferred red-fix lane still asked for a copy"
pass "a red-fix lane defers at the cap"
spawn 1
expect_code 1 "$rc" "T4 an ordinary lane under the limit should reach the lease: $out"
assert_contains "$out" "stand-in lease refused" "T4 the lane did not reach the lease"
pass "an ordinary lane under the lane limit reaches the lease"
rm -f "$H/state/lane-limit" "$H/config/lane-scale"
spawn 9
expect_code 1 "$rc" "T5 with no lane limit the check should step aside: $out"
assert_contains "$out" "stand-in lease refused" "T5 the lane did not reach the lease"
pass "no lane limit leaves the pool's own limit in charge"
