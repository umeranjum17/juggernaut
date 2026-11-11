#!/usr/bin/env bash
# A full pool defers a queued lane and names the holders.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
jg_git_identity fmtest fmtest@example.com
D=$(jg_test_tmproot jg-pool-full)
W=$D/world; H=$W/home; P=$W/project
mkdir -p "$P"
git -C "$P" init -q
git -C "$P" commit -q --allow-empty -m initial
F=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$F"
cat > "$F/treehouse" <<'SH'
#!/usr/bin/env bash
case ${1:-} in
  get) [ "${BAD_TREEHOUSE:-0}" != 1 ] || { echo 'Error: broken configuration' >&2; exit 1; }; echo "Error: all 2 worktrees are in use or dirty (max_trees = 2). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml" >&2; exit 1 ;;
  status) printf '1    leased       /fixture/1  (held by lane-a)\n2    leased       /fixture/2  (held by lane-b)\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$F/treehouse"
jg_test_spawn_home "$H"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$H/config/host-memory"
jg_test_spawn_brief "$H" jg-pool1
out=$(jg_test_run_spawn "$H" "$P" "$F" jg-pool1 "$P" codex --mode direct-PR --yolo off); rc=$?
expect_code 75 "$rc" "full pool should defer: $out"
assert_contains "$out" deferred: 'deferral missing'
assert_contains "$out" lane-a 'first holder missing'
assert_contains "$out" lane-b 'second holder missing'
[ ! -e "$H/state/jg-pool1.meta" ] || fail 'deferred task has a record'
pass 'a full pool defers the queued task and names its holders'
jg_test_spawn_brief "$H" jg-pool2
out=$(jg_test_run_spawn "$H" "$P" "$F" jg-pool2 "$P" codex --mode direct-PR --yolo off); rc=$?
expect_code 75 "$rc" "second task should defer: $out"
[ "$(find "$H/state/.stops" -name '*.pool-full' | wc -l)" -eq 1 ] || fail 'one pool created multiple stops'
stop=$(printf '%s\n' "$H/state/.stops/"*.pool-full)
subject=${stop##*/pool-}; subject=${subject%.pool-full}
# A landed lane is passed to the real sweep on the delivery tick.
mkdir -p "$H/bin"
printf '%s\n' "$(git -C "$P" rev-parse HEAD)" > "$H/state/trunk-tip-project"
printf 'kind=ship\nproject=%s\nbranch=%s\n' "$P" "$(git -C "$P" branch --show-current)" > "$H/state/lane-a.meta"
printf 'done [at=1]: ready\n' > "$H/state/lane-a.status"
cat > "$W/teardown" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SWEEP_LOG"
SH
chmod +x "$W/teardown"
export SWEEP_LOG="$W/sweep.log" JG_LEAD_SWEEP_TEARDOWN="$W/teardown" PATH="$F:$PATH"
JG_STOPS_TEST_NOW=100 bash "$ROOT/bin/jg-delivery-tick.sh" "$H" >/dev/null 2>&1
[ "$(cat "$SWEEP_LOG")" = lane-a ] || fail 'delivery tick did not ask the sweep to clean the landed lane without force'
grep -q 'lane-a.*lane-b' "$H/state/.wake-bus.outbox.jsonl" || fail 'lead wake does not name both holders'
pass 'delivery tick asks the unforced sweep and reports the holders'
JG_STOPS_TEST_NOW=700 bash "$ROOT/bin/jg-delivery-tick.sh" "$H" >/dev/null 2>&1
mkdir -p "$W/parent/state"
printf 'fixture-lead\n' > "$H/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$W/parent" > "$H/.jg-squad-lead-parent"
JG_STOPS_TEST_NOW=1000 bash "$ROOT/bin/jg-delivery-tick.sh" "$H" >/dev/null 2>&1
grep -q 'pool-full; owner=script next=main' "$H/state/.wake-bus.outbox.jsonl" || fail 'pool stop did not escalate to main'
grep -q 'pool full.*lane-a.*lane-b' "$W/parent/state/fixture-lead.status" || fail 'parent did not receive the escalation and holders'
[ "$(wc -l < "$SWEEP_LOG")" -eq 1 ] || fail 'the first sweep repeated unexpectedly'
JG_HOME="$H" bash "$ROOT/bin/jg-machine.sh" show host "$subject" | grep -q 'pool-full' || fail 'host machine did not report the stop'
pass 'the stop repeats and escalates, and the host machine shows it'
: > "$H/state/.pool-waiters/$subject/.started-jg-pool1"
JG_STOPS_TEST_NOW=1005 bash "$ROOT/bin/jg-delivery-tick.sh" "$H" >/dev/null 2>&1
[ -f "$stop" ] || fail 'pool stop cleared while another task is waiting'
: > "$H/state/.pool-waiters/$subject/.started-jg-pool2"
JG_STOPS_TEST_NOW=1010 bash "$ROOT/bin/jg-delivery-tick.sh" "$H" >/dev/null 2>&1
grep -q '^resolved .*pool stop cleared' "$W/parent/state/fixture-lead.status" || fail 'parent escalation did not resolve'
pass 'clearing the stop resolves its parent escalation'
[ ! -e "$stop" ] || fail 'pool stop remained after both tasks started'
jg_test_spawn_brief "$H" jg-pool3
out=$(BAD_TREEHOUSE=1 jg_test_run_spawn "$H" "$P" "$F" jg-pool3 "$P" codex --mode direct-PR --yolo off); rc=$?
expect_code 1 "$rc" "a non-capacity lease error must remain an error: $out"
assert_contains "$out" 'broken configuration' 'the actual lease error was lost'
[ ! -e "$stop" ] || fail 'a non-capacity error opened a pool stop'
pass 'other lease errors keep their cause and do not defer'
