#!/usr/bin/env bash
# Integration test for the registered check core/trunk-latency on a real Beads store: the lander puts a landing's timing (the stage that held
# it, the seconds of each step, the host load) in the payload of the ticket's `land` event, and a landing over five minutes raises one
# slow-delivery alert through bin/jg-alert.sh that names the stage it reads from that payload. No data/trunk-latency.tsv is written.
# It replays the records of two real landings against a fixture home, at the clock of each landing:
#   fric-s14-release-one-url: done 22:13:27Z, stack started 22:35:53Z, landed 22:45:27Z on 9 Nov, gate 216 s: 32 minutes, held by the queue.
#   fric-gate-shard-timeout: done 00:33:38Z, landed 00:35:37Z on 10 Nov, gate 64 s: 2 minutes, held by the gate.
# L1 the 32-minute landing raises one alert that names the queue and its minutes; the 2-minute landing raises none; a third tick adds none;
#    the payload holds the seconds of each step, the load and the reason; no tsv row exists.
# L2 the limit is JG_MERGE_LATENCY_LIMIT_MINUTES, the one core/merge-on-green reads.
# L3 a landing more than an hour old when the check first runs raises no alert; a landing whose ticket has no event yet is read again later.
# L4 the wiring installs the check, registers it, and the installed shim runs it; the unwiring removes it.
# S1 `latency.sh summary` prints the 12-line summary of a latency tsv: tests/fixtures/trunk-latency.tsv holds invented lanes with a stall behind
#    one landing, two lanes done again and a day split; a bad row and a landing outside the window are not counted; a bad option is refused.
# With DONE_DONE_EVIDENCE_ROOT set it writes trunk-latency.log and the payload of L1 as trunk-latency.json there.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# S1 reads a file only, so it runs without a Beads store.
SUMMARY_TSV=$ROOT/tests/fixtures/trunk-latency.tsv
sum_out=$(bash "$ROOT/core/trunk-latency/latency.sh" summary --tsv "$SUMMARY_TSV" --from 1794009600 --to 1794614400) || fail "summary failed: $sum_out"
[ "$sum_out" = "landings 11
ready_to_landed_min median 8.3 p90 100.0
first_done_to_landed_min median 70.0 p90 105.0
redone lanes 3 hours 4.1
redone_day 2026-11-07 lanes 2 hours 3.0 share_pct 73
redone_day 2026-11-08 lanes 1 hours 1.1 share_pct 27
redone_top5 hours 1.9 1.1 1.0 share_pct 100
stall gap_s 1800 stretches 3 lane_hours 5.1 total_lane_hours 5.8 share_pct 87" ] || fail "the summary is: $sum_out"
bash "$ROOT/core/trunk-latency/latency.sh" summary --tsv "$SUMMARY_TSV" --from 1794009600 --to 1794614400 --stall-gap 20000 | tail -n 1 | grep -qx 'stall gap_s 20000 stretches 0 lane_hours 0.0 total_lane_hours 5.8 share_pct 0' || fail "a wider stall gap must find no stretch"
if bash "$ROOT/core/trunk-latency/latency.sh" summary --tsv "$SUMMARY_TSV" --bogus 1 2>/dev/null; then fail "an unknown option must be refused"; fi
printf 'ok - S1 summary prints the 12 lines of the fixture, honours --stall-gap and refuses a bad option\n'

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

CHECK=$ROOT/core/trunk-latency/latency.sh
T=$(jg_test_tmproot jg-trunk-latency)
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/trunk-latency.log}
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
ok() { say "ok - $1"; }
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
export TZ=UTC JG_TRUNK_LATENCY_ALERT=$ROOT/bin/jg-alert.sh JG_TRUNK_LATENCY_BACKLOG=$ROOT/bin/jg-backlog.sh  # the fixture homes hold no bin of their own
# shellcheck source=core/lib/beads-test-env.sh
. "$ROOT/core/lib/beads-test-env.sh"
S14=fric-s14-release-one-url S14_HEAD=c51c26ab2fd909dc744a43bc04cb08ac7ccd0917 S14_COMMIT=f19bfb172622c43cacff1f1d30a33720cfb819b4
SHARD=fric-gate-shard-timeout SHARD_HEAD=77c927cfa3ea6a35b907cfda47a3c06079ec5741

home() {  # <name>: a home with a real store, an empty set of landing records and a host load of 7.25
  local h=$T/$1
  mkdir -p "$h/state" "$h/data/jg-trunk-landing" "$h/bin"
  core_beads_home "$ROOT" "$h"
  printf '7.25 6.10 5.00 3/900 4242\n' > "$h/loadavg"
  printf '%s\n' "$h"
}
cli() { local h=$1; shift; JG_HOME=$h JG_DATA_OVERRIDE=$h/data BEADS_DIR=$(cat "$h/config/beads-dir") "$ROOT/bin/jg-backlog.sh" "$@"; }
row() { printf '%s\n' "$2" >> "$1/data/trunk-landings.tsv"; }
proof() { printf '%s\n' "$2" >> "$1/data/trunk-landing-proofs.tsv"; }
run_record() {  # <home> <task> <run id> <commit> <started_at>
  mkdir -p "$1/data/$2/.done-done/runs"
  printf '{"schema":1,"run_id":"%s","commit":"%s","dirty":false,"started_at":"%s","exit":0}\n' "$3" "$4" "$5" > "$1/data/$2/.done-done/runs/$3.json"
}
ticket() {  # <home> <task>: a ticket for the lane
  cli "$1" add "$2" "[feature] $2" --priority 2 --body why >/dev/null || fail "file the ticket of $2"
  BEADS_DIR=$(cat "$1/config/beads-dir") "$ROOT/bin/jg-beads.sh" update "$2" --set-metadata "task=$2" >/dev/null || fail "name the task of $2"
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# The records each landing left in the home, as the landing check, the lane and its worker wrote them.
seed_s14() {
  ticket "$1" "$S14"
  row "$1" "$S14	juggernaut	$S14_COMMIT	1794264327	full	batch-from=cfc5da612e51dc237ffdacadf6bce898614b4413"
  proof "$1" "$S14	juggernaut	$S14_COMMIT	1794264327	receipt=PASS@c51c26ab2fd9	signature=absent	merge-card=present	gate=ran:68,failed:0,secs:216	done=1794262407"
  printf 'landed cleaned up\n' > "$1/data/jg-trunk-landing/$S14.$S14_HEAD.state"
  : > "$1/data/jg-trunk-landing/batch.launch-GZCCxz.log"; jg_touch_epoch 1794263753 "$1/data/jg-trunk-landing/batch.launch-GZCCxz.log"
  run_record "$1" "$S14" 20261109T221119Z-c51c26ab-41ae44 "$S14_HEAD" 2026-11-09T22:11:19.170Z
}
seed_shard() {
  ticket "$1" "$SHARD"
  row "$1" "$SHARD	juggernaut	$SHARD_HEAD	1794270937	full	batch-from=9f5bbb3af0d1350d5f7f4b817c0e9c9192d23825"
  proof "$1" "$SHARD	juggernaut	$SHARD_HEAD	1794270937	receipt=PASS@77c927cfa3ea	signature=absent	merge-card=present	gate=ran:7,failed:0,secs:64	done=1794270818"
  printf 'landed cleaned up\n' > "$1/data/jg-trunk-landing/$SHARD.$SHARD_HEAD.state"
  : > "$1/data/jg-trunk-landing/batch.launch-yD3Ueu.log"; jg_touch_epoch 1794270861 "$1/data/jg-trunk-landing/batch.launch-yD3Ueu.log"
}
ready() {  # <home> <task> <epoch>: the delivery tick's record of the lane's done line, on the ticket
  cli "$1" trace record "$2" commit work-id "$2@done-$3" --source jg-done --at "$3" >/dev/null || fail "record the ready time of $2"
}
land() {  # <home> <task> <commit> <epoch> [clock]: the lander's own two steps, the timing and the land event
  local payload
  payload=$(JG_TRUNK_LATENCY_NOW=${5:-$4} JG_TRUNK_LATENCY_LOADAVG="$1/loadavg" bash "$CHECK" measure "$1" "$2" "$3") || fail "measure $2: $payload"
  cli "$1" trace record "$2" land git-sha "$3" --source jg-trunk-land --at "$4" --payload "$payload" >/dev/null || fail "record the landing of $2"
}
payload() {  # <home> <task> <commit>: the land event's payload
  cli "$1" trace landing "$2" "$3" | cut -f3
}
tick() {  # <home> <clock> [env...]: one watcher tick of the check at that clock
  local h=$1 now=$2; shift 2
  env JG_TRUNK_LATENCY_NOW="$now" "$@" bash "$CHECK" check "$h"
}
alerts() { JG_HOME=$1 JG_STATE_OVERRIDE=$1/state bash "$ROOT/bin/jg-alert.sh" list; }
wakes() { cat "$1/state/.wake-queue" 2>/dev/null; }
notsv() { [ ! -e "$1/data/trunk-latency.tsv" ] || fail "no data/trunk-latency.tsv may be written: $(cat "$1/data/trunk-latency.tsv")"; }

# L1: the two landings, each read on the tick after it landed.
H=$(home l1)
seed_s14 "$H"; ready "$H" "$S14" 1794262407; land "$H" "$S14" "$S14_COMMIT" 1794264327
out=$(tick "$H" 1794264357)
say "$out"
[ -z "$out" ] || fail "the check prints no alert text of its own, got: $out"
[ "$(alerts "$H")" = "slow-delivery--$S14-f19bfb172622" ] || fail "the 32-minute landing must raise exactly one slow-delivery alert, got: $(alerts "$H")"
assert_contains "$(wakes "$H")" "alert-slow-delivery--$S14-f19bfb172622"
assert_contains "$(wakes "$H")" "the queue held 22 minutes"
assert_contains "$(wakes "$H")" "landing took 32 minutes"
P=$(payload "$H" "$S14" "$S14_COMMIT")
say "land payload of $S14: $P"
[ "$(jq -c '[.stage, .queue_s, .landing_s, .gate_s, .load, .queue_why]' <<< "$P")" = '["queue",1346,358,216,7.25,"not recorded"]' ] || fail "the $S14 payload is $P"
[ "$(jq -r .head <<< "$P")" = "$S14_HEAD" ] || fail "the payload names the lane head the feeds read, got: $P"
ok "$S14: 32 minutes, one alert naming the queue and its 22 minutes, read from the land payload"
seed_shard "$H"; ready "$H" "$SHARD" 1794270818; land "$H" "$SHARD" "$SHARD_HEAD" 1794270937
out=$(tick "$H" 1794270967)
[ -z "$out" ] && [ "$(alerts "$H" | wc -l)" = 1 ] || fail "a 2-minute landing raises no alert, got: $out $(alerts "$H")"
[ "$(payload "$H" "$SHARD" "$SHARD_HEAD" | jq -r .stage)" = gate ] || fail "the gate held most of $SHARD: $(payload "$H" "$SHARD" "$SHARD_HEAD")"
ok "$SHARD: 2 minutes, held by the gate, no alert"
out=$(tick "$H" 1794271000)
[ -z "$out" ] && [ "$(alerts "$H" | wc -l)" = 1 ] || fail "a third tick raised again: $out $(alerts "$H")"
notsv "$H"
ok "a tick with no new landing says nothing, and no latency tsv is written"
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || printf '%s\n' "$P" > "$DONE_DONE_EVIDENCE_ROOT/trunk-latency.json"

# L2: the limit is the one core/merge-on-green reads.
H=$(home l2)
seed_s14 "$H"; ready "$H" "$S14" 1794262407; land "$H" "$S14" "$S14_COMMIT" 1794264327
out=$(tick "$H" 1794264357 JG_MERGE_LATENCY_LIMIT_MINUTES=40)
[ -z "$out" ] && [ -z "$(alerts "$H")" ] || fail "under a 40-minute limit no alert is raised: $out"
ok "JG_MERGE_LATENCY_LIMIT_MINUTES sets the limit: under 40 minutes the 32-minute landing raises no alert"

# L3: an old landing is not read; a landing with no event yet is read on a later tick.
H=$(home l3)
seed_s14 "$H"; ready "$H" "$S14" 1794262407; land "$H" "$S14" "$S14_COMMIT" 1794264327
out=$(tick "$H" 1794362400)
[ -z "$out" ] && [ -z "$(alerts "$H")" ] || fail "a landing over an hour old raises no alert: $out $(alerts "$H")"
H=$(home l3b)
seed_s14 "$H"; ready "$H" "$S14" 1794262407
out=$(tick "$H" 1794264357)
[ -z "$out" ] && [ -z "$(alerts "$H")" ] || fail "a landing with no event raises nothing: $out"
land "$H" "$S14" "$S14_COMMIT" 1794264327
tick "$H" 1794264400 >/dev/null
[ "$(alerts "$H")" = "slow-delivery--$S14-f19bfb172622" ] || fail "the landing is read once its event exists: $(alerts "$H")"
ok "an old landing raises no alert; a landing whose event is not there yet is read on the next tick"

# L4: the wiring, through the installed copy.
H=$(home l4)
seed_s14 "$H"; ready "$H" "$S14" 1794262407; land "$H" "$S14" "$S14_COMMIT" 1794264327
cat > "$H/bin/jg-check-register.sh" <<'STUB'
#!/usr/bin/env bash
[ -x "$JG_HOME/state/$1.check.sh" ] && printf 'register %s\n' "$1" >> "$JG_HOME/register.log"
STUB
cat > "$H/bin/jg-check-unregister.sh" <<'STUB'
#!/usr/bin/env bash
rm -f -- "$JG_HOME/state/$1.check.sh"; printf 'unregister %s\n' "$1" >> "$JG_HOME/register.log"
STUB
chmod +x "$H/bin/jg-check-register.sh" "$H/bin/jg-check-unregister.sh"
export XDG_DATA_HOME=$T/share
bash "$ROOT/core/trunk-latency/wiring.sh" "$H" >/dev/null || fail "the wiring failed"
[ "$(cat "$H/register.log")" = 'register trunk-latency' ] || fail "the check was not registered: $(cat "$H/register.log")"
cmp -s "$CHECK" "$T/share/jg-trunk-latency/latency.sh" || fail "the installed check differs from the source"
JG_TRUNK_LATENCY_NOW=1794264357 "$H/state/trunk-latency.check.sh" >/dev/null
[ "$(alerts "$H")" = "slow-delivery--$S14-f19bfb172622" ] || fail "the installed shim did not raise the alert: $(alerts "$H")"
bash "$ROOT/core/trunk-latency/unwiring.sh" "$H" >/dev/null || fail "the unwiring failed"
[ ! -e "$H/state/trunk-latency.check.sh" ] && [ ! -e "$T/share/jg-trunk-latency" ] || fail "the unwiring must remove the shim and the install"
ok "the wiring installs and registers the check, its shim raises the alert, and the unwiring removes it"
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || jq -n --arg v "$(git -C "$ROOT" rev-parse HEAD)" '{target: {version: $v}, start: "a fixture home with a real store and two real landings and their records",
  steps: ["Measure each landing and record it as the land event of its ticket", "Run the trunk-latency check at the clock of each landing"],
  result: "The 32-minute landing raises one alert that names the queue; the 2-minute landing raises none; no tsv is written"}' > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
