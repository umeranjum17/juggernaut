#!/usr/bin/env bash
# Copies follow the lane limit and two stay free for a red fix, through the real bin/jg-spawn.sh.
# The lane limit is 2, so the copy cap is 4. The worktree tool is a stand-in whose status shows the leased copies.
# T1 two copies leased (the lane limit): an ordinary lane defers with exit 75, no record, and no lease is asked for.
# T2 the same two leased: a red-fix lane passes the check and reaches the lease (the stand-in lease fails with its own cause).
# T3 four copies leased (the cap): the red-fix lane defers too.
# T4 one copy leased: an ordinary lane reaches the lease.
# T5 no lane limit: the check steps aside and the pool's own limit governs.
# T6 the pool cannot be read (status fails): the start defers with exit 75 and says the count is unknown, asks for no copy, and the next try with a readable pool reaches the lease.
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
  status) [ "${LEASED:-0}" != unreadable ] || { echo 'Error: stand-in pool read failed' >&2; exit 1; }; i=0; while [ "$i" -lt "${LEASED:-0}" ]; do i=$((i + 1)); printf '%s    leased       /fixture/%s  (held by lane-%s)\n' "$i" "$i" "$i"; done ;;
  *) exit 1 ;;
esac
SH
chmod +x "$F/treehouse"
export GET_LOG="$W/get.log"; : > "$GET_LOG"
jg_test_spawn_home "$H"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$H/config/host-memory"
printf 'mode=act\n' > "$H/config/lane-scale"
printf '2\n' > "$H/state/lane-limit"
# The stand-in's leased copies are held by lane-1 to lane-4, live lanes with a task record, so each one counts.
for i in 1 2 3 4; do printf 'kind=ship\n' > "$H/state/lane-$i.meta"; printf 'working [at=1]: x\n' > "$H/state/lane-$i.status"; done
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
: > "$GET_LOG"
spawn unreadable
expect_code 75 "$rc" "T6 an unreadable pool should defer, not pass or fail: $out"
assert_contains "$out" "cannot be counted" "T6 the deferral does not say the count is unknown"
assert_contains "$out" "stand-in pool read failed" "T6 the deferral does not carry the real cause"
assert_contains "$out" "the copy count is unknown, the start retries" "T6 the spawn's last line does not name the retry"
[ ! -e "$H/state/$id.meta" ] || fail "T6 the deferred lane wrote a task record"
[ ! -s "$GET_LOG" ] || fail "T6 an unknown count still asked for a copy"
out=$(LEASED=1 jg_test_run_spawn "$H" "$P" "$F" "$id" "$P" codex --mode direct-PR --yolo off); rc=$?
expect_code 1 "$rc" "T6 the retry with a readable pool should reach the lease: $out"
assert_contains "$out" "stand-in lease refused" "T6 the retry did not reach the lease"
pass "an unreadable pool defers as unknown, and a later try with a readable pool reaches the lease"
rm -f "$H/state/lane-limit" "$H/config/lane-scale"
spawn 9
expect_code 1 "$rc" "T5 with no lane limit the check should step aside: $out"
assert_contains "$out" "stand-in lease refused" "T5 the lane did not reach the lease"
pass "no lane limit leaves the pool's own limit in charge"
# The copy count follows live holders (reserve.sh admit): a copy counts only when its holder has a task record that is not finished.
# The status stand-in prints 5 leased copies held by a to e; the home has a lane limit of 4 and records for a, b and c, c finished.
# T-stale a copy whose holder is finished, or has no record, is not counted: admit passes and names c, d and e on stderr.
# T-full records for a to e, none finished: five copies count, admit defers with exit 75 and today's line.
# T-noname a leased line with no holder name is counted (an unknown holder is never zero).
# T-all JG_POOL_RESERVE_COUNT_ALL=1 counts every copy as before: the T-stale fixture defers.
R=$ROOT/core/pool-reserve/reserve.sh
printf '4\n' > "$H/state/lane-limit"; printf 'mode=act\n' > "$H/config/lane-scale"
cat > "$F/status-holders" <<'SH'
#!/usr/bin/env bash
n=0; for h in a b c d e; do n=$((n + 1)); if [ "$h" = "${NONAME:-}" ]; then printf '%s    leased       /fixture/%s\n' "$n" "$h"; else printf '%s    leased       /fixture/%s  (held by %s)\n' "$n" "$h" "$h"; fi; done
SH
chmod +x "$F/status-holders"
mkmeta() {  # <name> [finished]
  printf 'kind=ship\nproject=%s\n' "$P" > "$H/state/$1.meta"
  if [ "${2:-}" = finished ]; then printf 'working [at=1]: x\ndone [at=2]: ready\n' > "$H/state/$1.status"; printf 'landed=abc\n' >> "$H/state/$1.meta"
  else printf 'working [at=1]: x\n' > "$H/state/$1.status"; fi
}
admit() { out=$(JG_POOL_RESERVE_STATUS=$F/status-holders "$@" "$R" admit "$H" "$P" 2>&1); rc=$?; }
mkmeta a; mkmeta b; mkmeta c finished
admit env
expect_code 0 "$rc" "T-stale admit should pass with 2 live copies of 4: $out"
assert_contains "$out" "pool-reserve: not counted (no live lane): " "T-stale the not-counted line is missing"
assert_contains "$out" "3=c 4=d 5=e" "T-stale the line does not name c, d and e with their slots"
assert_not_contains "$out" "1=a" "T-stale a live copy was named as not counted"
pass "copies of finished and unrecorded holders are not counted, and are named"
admit env JG_POOL_RESERVE_COUNT_ALL=1
expect_code 75 "$rc" "T-all counting every copy should defer as before: $out"
assert_contains "$out" "5 copies of project are leased" "T-all the deferral line changed"
assert_not_contains "$out" "not counted" "T-all printed a not-counted line"
pass "JG_POOL_RESERVE_COUNT_ALL=1 counts every copy"
mkmeta c; mkmeta d; mkmeta e
admit env
expect_code 75 "$rc" "T-full five live copies should defer: $out"
assert_contains "$out" "deferred: 5 copies of project are leased" "T-full the deferral line changed"
assert_not_contains "$out" "not counted" "T-full printed a not-counted line"
pass "five live copies defer with today's line"
rm -f "$H/state/d".* "$H/state/e".*; mkmeta c finished
admit env NONAME=d
expect_code 0 "$rc" "T-noname should pass with 3 counted of 4: $out"
assert_not_contains "$out" "4=" "T-noname the copy with no holder was left uncounted"
assert_contains "$out" "3=c 5=e" "T-noname the line does not name c and e"
pass "a leased copy with no holder name is counted"
# T-flat the cost of admit does not grow with the leased copies: bin/jg-crew-state.sh (a pane read) is asked only for a holder whose status
# file holds a done line. 24 live holders with no done line, one that is done (no landed=) and one whose note only mentions done: two calls.
FR=$W/fakeroot; mkdir -p "$FR/core/pool-reserve" "$FR/bin"
cp "$R" "$FR/core/pool-reserve/reserve.sh"; ln -sn "$ROOT/core/lane-scale" "$FR/core/lane-scale"
cat > "$FR/bin/jg-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$CREW_STATE_LOG"
[ "$1" = dd ] && echo 'state: done · source: status-log · ready' || echo 'state: working · source: pane · busy'
SH
chmod +x "$FR/bin/jg-crew-state.sh"
cat > "$F/status-many" <<'SH'
#!/usr/bin/env bash
n=0; for h in $(seq -f 'w%g' 1 24) dd dn; do n=$((n + 1)); printf '%s    leased       /fixture/%s  (held by %s)\n' "$n" "$h" "$h"; done
SH
chmod +x "$F/status-many"
for i in $(seq 1 24); do printf 'kind=ship\n' > "$H/state/w$i.meta"; printf 'working [at=1]: x\n' > "$H/state/w$i.status"; done
printf 'kind=ship\n' > "$H/state/dd.meta"; printf 'working [at=1]: x\ndone [at=2]: ready\n' > "$H/state/dd.status"
printf 'kind=ship\n' > "$H/state/dn.meta"; printf 'working [at=3]: wrote the done-done receipt\n' > "$H/state/dn.status"
printf '25\n' > "$H/state/lane-limit"
export CREW_STATE_LOG=$W/crew-state.log; : > "$CREW_STATE_LOG"
out=$(JG_POOL_RESERVE_STATUS=$F/status-many "$FR/core/pool-reserve/reserve.sh" admit "$H" "$P" 2>&1); rc=$?
expect_code 75 "$rc" "T-flat 25 live copies of 26 leased, with a limit of 25, should defer: $out"
assert_contains "$out" "deferred: 25 copies" "T-flat the 25 live copies were not counted: $out"
assert_not_contains "$out" "w1=" "T-flat a live holder was named as not counted"
assert_contains "$out" "25=dd" "T-flat the done holder should not count"
assert_equals "dd dn" "$(sort "$CREW_STATE_LOG" | tr '\n' ' ' | sed 's/ $//')" "T-flat crew-state should be asked for the two holders with a done line only"
pass "admit asks for a holder's state only when its status file holds a done line"
