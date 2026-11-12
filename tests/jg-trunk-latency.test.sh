#!/usr/bin/env bash
# Integration test for the registered check core/trunk-latency: every local-trunk landing gets one row with its minutes from
# the done line to the landing row and the stage that held them, and a landing over five minutes raises one slow-delivery alert
# through bin/jg-alert.sh (the check prints no alert text of its own).
# It replays the records of two real landings against a fixture home, at the clock of each landing:
#   fric-s14-release-one-url: done 22:13:27Z, stack started 22:35:53Z, landed 22:45:27Z on 9 Nov, gate 216 s. Table T of the plan's
#     measure.py reads 32 minutes, 28 of them before the gate; nobody was told.
#   fric-gate-shard-timeout: done 00:33:38Z, landed 00:35:37Z on 10 Nov, gate 64 s. Table T reads 2 minutes.
# L1 the first landing gets a row of 32 minutes held by the queue and one alert; the second gets a row of 2 minutes and none;
#    a third tick writes nothing.
# L2 the limit is JG_MERGE_LATENCY_LIMIT_MINUTES, the one core/merge-on-green reads.
# L3 the first run in a home records old landings with one counting line and no alert per landing; a landing with no done line on
#    record (a revert row) gets a row with an empty ready field; a done line still in the lane's status file is read.
# L4 the wiring installs the check, registers it, and the installed shim runs it; the unwiring removes it and keeps the rows.
# L5 the lander (core/trunk-landing/queue-why.sh) records why a lane waited, and the late rows name it: behind <lane>, behind attempt
#    of <lane>, first seen +N s; a late row with no record says `not recorded`, never a bare queue.
# With DONE_DONE_EVIDENCE_ROOT set it writes trunk-latency.log and the rows of L1 as trunk-latency.tsv there.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK=$ROOT/core/trunk-latency/latency.sh
T=$(jg_test_tmproot jg-trunk-latency)
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/trunk-latency.log}
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
ok() { say "ok - $1"; }

export JG_TRUNK_LATENCY_ALERT=$ROOT/bin/jg-alert.sh  # the fixture homes hold no bin of their own
S14=fric-s14-release-one-url S14_HEAD=c51c26ab2fd909dc744a43bc04cb08ac7ccd0917 S14_COMMIT=f19bfb172622c43cacff1f1d30a33720cfb819b4
SHARD=fric-gate-shard-timeout SHARD_HEAD=77c927cfa3ea6a35b907cfda47a3c06079ec5741
REVERT=revert-telegram-intake-stalled

home() {  # <name>: an empty home with a host load of 7.25
  local h=$T/$1
  mkdir -p "$h/state" "$h/data/jg-trunk-landing" "$h/bin"
  printf '7.25 6.10 5.00 3/900 4242\n' > "$h/loadavg"
  printf '%s\n' "$h"
}
row() { printf '%s\n' "$2" >> "$1/data/trunk-landings.tsv"; }
proof() { printf '%s\n' "$2" >> "$1/data/trunk-landing-proofs.tsv"; }
chat() { printf '{"at":%s,"thread":"#fleet","from":"%s","to":"lead","kind":"status","text":"%s","status":null}\n' "$2" "$3" "$4" >> "$1/state/chat.jsonl"; }
run_record() {  # <home> <task> <run id> <commit> <started_at>
  mkdir -p "$1/data/$2/.done-done/runs"
  printf '{"schema":1,"run_id":"%s","commit":"%s","dirty":false,"started_at":"%s","exit":0}\n' "$3" "$4" "$5" > "$1/data/$2/.done-done/runs/$3.json"
}
# The records each landing left in the home, as the landing check, the lane and its worker wrote them.
seed_s14() {
  row "$1" "$S14	juggernaut	$S14_COMMIT	1794264327	full	batch-from=cfc5da612e51dc237ffdacadf6bce898614b4413"
  proof "$1" "$S14	juggernaut	$S14_COMMIT	1794264327	receipt=PASS@c51c26ab2fd9	signature=absent	merge-card=present	gate=ran:68,failed:0,secs:216"
  printf 'landed cleaned up\n' > "$1/data/jg-trunk-landing/$S14.$S14_HEAD.state"
  : > "$1/data/jg-trunk-landing/batch.launch-GZCCxz.log"; jg_touch_epoch 1794263753 "$1/data/jg-trunk-landing/batch.launch-GZCCxz.log"
  : > "$1/data/jg-trunk-landing/batch.launch-Z8qgPh.log"; jg_touch_epoch 1794260094 "$1/data/jg-trunk-landing/batch.launch-Z8qgPh.log"
  chat "$1" 1794259814 "$S14" 'paused [at=1794259801]: own light-gate test run in progress'
  chat "$1" 1794262416 "$S14" 'done [at=1794262407]: ready in branch feature/fric-s14-release-one-url (local-trunk) at c51c26ab2'
  run_record "$1" "$S14" 20261109T220835Z-543566ad-5a20d7 543566ad75f6e2bcf920a4caca53db89a5960320 2026-11-09T22:08:35.140Z
  run_record "$1" "$S14" 20261109T221119Z-c51c26ab-41ae44 "$S14_HEAD" 2026-11-09T22:11:19.170Z
}
seed_shard() {  # <home> [status]: with `status`, the done line is still in the lane's status file and not in the message log
  row "$1" "$SHARD	juggernaut	$SHARD_HEAD	1794270937	full	batch-from=9f5bbb3af0d1350d5f7f4b817c0e9c9192d23825"
  proof "$1" "$SHARD	juggernaut	$SHARD_HEAD	1794270937	receipt=PASS@77c927cfa3ea	signature=absent	merge-card=present	gate=ran:7,failed:0,secs:64"
  printf 'landed cleaned up\n' > "$1/data/jg-trunk-landing/$SHARD.$SHARD_HEAD.state"
  : > "$1/data/jg-trunk-landing/batch.launch-yD3Ueu.log"; jg_touch_epoch 1794270861 "$1/data/jg-trunk-landing/batch.launch-yD3Ueu.log"
  chat "$1" 1794270770 "$SHARD" 'working [at=1794270572]: fix in 67bcc091c'
  if [ "${2:-}" = status ]; then
    printf '%s\n' 'done [at=1794270818]: ready in branch feature/fric-gate-shard-timeout (local-trunk)' > "$1/state/$SHARD.status"
  else
    chat "$1" 1794270911 "$SHARD" 'done [at=1794270818]: ready in branch feature/fric-gate-shard-timeout (local-trunk)'
  fi
  run_record "$1" "$SHARD" 20261110T003220Z-77c927cf-246785 "$SHARD_HEAD" 2026-11-10T00:32:20.241Z
}
tick() {  # <home> <clock> [env...]: one watcher tick of the check at that clock
  local h=$1 now=$2; shift 2
  env JG_TRUNK_LATENCY_NOW="$now" JG_TRUNK_LATENCY_LOADAVG="$h/loadavg" "$@" bash "$CHECK" check "$h"
}
alerts() {  # <home>: the live alert keys of the home, one per line
  JG_HOME=$1 JG_STATE_OVERRIDE=$1/state bash "$ROOT/bin/jg-alert.sh" list
}
wakes() {  # <home>: the wake lines the alerts delivered
  cat "$1/state/.wake-queue" 2>/dev/null
}
field() {  # <home> <task> <field name>: one field of the task's latency row
  awk -F'\t' -v t="$2" -v f="$3" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next } $1 == t { print $c[f] }' "$1/data/trunk-latency.tsv"
}

# L1: the two landings, each read on the tick after it landed.
H=$(home l1)
seed_s14 "$H"
out=$(tick "$H" 1794264357)
say "$out"
[ -z "$out" ] || fail "the check prints no alert text of its own, got: $out"
[ "$(alerts "$H")" = "slow-delivery--$S14-f19bfb172622" ] || fail "the 32-minute landing must raise exactly one slow-delivery alert, got: $(alerts "$H")"
assert_contains "$(wakes "$H")" "alert-slow-delivery--$S14-f19bfb172622"
assert_contains "$(wakes "$H")" "(P3) at rung 1 for worker"
[ "$(field "$H" "$S14" minutes)" = 32 ] || fail "table T reads 32 minutes for $S14, the row says $(field "$H" "$S14" minutes)"
[ "$(field "$H" "$S14" stage)" = queue ] || fail "the queue held $S14, the row says $(field "$H" "$S14" stage)"
before=$(awk -F'\t' -v t="$S14" '$1 == t { printf "%.0f", ($8 - $5 - $11) / 60 }' "$H/data/trunk-latency.tsv")
[ "$before" = 28 ] || fail "table T reads 28 minutes before the gate for $S14, the row gives $before"
want="$S14	$S14_HEAD	$S14_COMMIT	1794262407	1794262407	1794262279	1794263753	1794264327	32	queue	216	7.25	not recorded"
[ "$(grep "^$S14	" "$H/data/trunk-latency.tsv")" = "$want" ] || fail "the $S14 row is $(grep "^$S14	" "$H/data/trunk-latency.tsv")"
ok "$S14: one row of 32 minutes (28 before the gate, as table T reads), the queue named as the stage that held 22 of them, one alert"
seed_shard "$H"
out=$(tick "$H" 1794270967)
[ -z "$out" ] && [ "$(alerts "$H" | wc -l)" = 1 ] || fail "a 2-minute landing raises no alert, got: $out $(alerts "$H")"
[ "$(field "$H" "$SHARD" minutes)" = 2 ] || fail "table T reads 2 minutes for $SHARD, the row says $(field "$H" "$SHARD" minutes)"
[ "$(field "$H" "$SHARD" stage)" = gate ] || fail "the gate held most of $SHARD, the row says $(field "$H" "$SHARD" stage)"
[ "$(field "$H" "$SHARD" load)" = 7.25 ] || fail "a fresh landing's row holds the one-minute load"
ok "$SHARD: one row of 2 minutes, held by the gate, with the host load, and no alert"
out=$(tick "$H" 1794271000)
[ -z "$out" ] && [ "$(grep -c . "$H/data/trunk-latency.tsv")" = 3 ] || fail "a third tick wrote again: $out"
ok "a tick with no new landing writes nothing and says nothing"
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || cp "$H/data/trunk-latency.tsv" "$DONE_DONE_EVIDENCE_ROOT/trunk-latency.tsv"

# L2: the limit is the one core/merge-on-green reads.
H=$(home l2)
seed_s14 "$H"
out=$(tick "$H" 1794264357 JG_MERGE_LATENCY_LIMIT_MINUTES=40)
[ -z "$out" ] && [ -z "$(alerts "$H")" ] && [ "$(field "$H" "$S14" minutes)" = 32 ] || fail "under a 40-minute limit the row is written and no alert raised: $out"
ok "JG_MERGE_LATENCY_LIMIT_MINUTES sets the limit: under 40 minutes the 32-minute landing is recorded with no alert"

# L3: the first run in a home with history.
H=$(home l3)
row "$H" "$REVERT	juggernaut	7359a02a2120207a807fead3a058150b2f1b12ab	1794192684	reverts-262ce08b5b82"
seed_s14 "$H"
seed_shard "$H" status
out=$(tick "$H" 1794362400)
say "$out"
[ "$out" = "trunk-latency: recorded 3 earlier landings with no alert, 1 of them over the 5-minute target; $H/data/trunk-latency.tsv" ] \
  || fail "the first run must print one counting line, got: $out"
[ "$(grep -c "^$REVERT	" "$H/data/trunk-latency.tsv")" = 1 ] && [ -z "$(field "$H" "$REVERT" ready)$(field "$H" "$REVERT" minutes)" ] \
  || fail "a landing with no done line gets a row with empty ready and minutes"
[ "$(field "$H" "$SHARD" ready)" = 1794270818 ] || fail "the done line in the lane's status file was not read"
[ -z "$(field "$H" "$S14" load)$(field "$H" "$SHARD" load)" ] || fail "an old landing's row must not hold today's load"
ok "the first run records 3 old landings with one counting line; the revert row is counted with an empty ready; a status-file done line is read"

# L4: the wiring, through the installed copy.
H=$(home l4)
seed_s14 "$H"
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
JG_TRUNK_LATENCY_NOW=1794264357 JG_TRUNK_LATENCY_LOADAVG="$H/loadavg" "$H/state/trunk-latency.check.sh" >/dev/null
[ "$(alerts "$H")" = "slow-delivery--$S14-f19bfb172622" ] || fail "the installed shim did not raise the alert: $(alerts "$H")"
bash "$ROOT/core/trunk-latency/unwiring.sh" "$H" >/dev/null || fail "the unwiring failed"
[ ! -e "$H/state/trunk-latency.check.sh" ] && [ ! -e "$T/share/jg-trunk-latency" ] && [ -s "$H/data/trunk-latency.tsv" ] \
  || fail "the unwiring must remove the shim and the install and keep the rows"
ok "the wiring installs and registers the check, its shim raises the alert, and the unwiring removes it and keeps the rows"

# L5: one lane behind another's landing, one behind a refused attempt, one seen late; the lander records, the rows say why.
# shellcheck source=core/trunk-landing/queue-why.sh
. "$ROOT/core/trunk-landing/queue-why.sh"
H=$(home l5)
M=$H/data/jg-trunk-landing
h() { printf '%s%s' "$1" "$(printf '%0*d' $((40 - ${#1})) 0)"; }  # a 40-hex head that starts with the given hex
HA=$(h a1); HB=$(h b2); HC=$(h c3); HD=$(h d4); HE=$(h e5)
state() { printf '%s\n' "$3" > "$M/$1.$2.state"; jg_touch_epoch "$4" "$M/$1.$2.state"; }
# lane-a landed at 2000; lane-b was ready at 1000. lane-x's attempt was refused at 5100; lane-c was ready at 5000. lane-d was ready
# at 9000 with nothing ahead and the lander first saw it at 9300. lane-e was ready at 12000 and the lander saw it at once.
state lane-a "$HA" 'landed cleaned up' 2000
state lane-x "$(h f6)" 'final REFUSED: fm/lane-x conflicts with trunk' 5100
for l in "lane-b $HB 1000 2100" "lane-c $HC 5000 5200" "lane-d $HD 9000 9400" "lane-e $HE 12000 12010"; do
  read -r -a a <<< "$l"; set -- "${a[@]}"
  case $1 in lane-d) printf '9300\n' > "$M/$1.$2.seen" ;; lane-e) printf '12010\n' > "$M/$1.$2.seen" ;; esac
  queue_why_record "$M" "$1" "$2" "$3" "$4" lane-e
  : > "$M/$1.$2.launch-x.log"; jg_touch_epoch "$4" "$M/$1.$2.launch-x.log"
  state "$1" "$2" 'landed cleaned up' "$(( $4 + 100 ))"
  row "$H" "$1	juggernaut	$(h 0"${2:0:1}")	$(( $4 + 100 ))	full"
  proof "$H" "$1	juggernaut	$(h 0"${2:0:1}")	$(( $4 + 100 ))	receipt=PASS@${2:0:12}	gate=ran:1,failed:0,secs:20	done=$3"
done
[ "$(cat "$M/lane-b.$HB.queue-why")" = 'behind lane-a' ] || fail "lane-b waited behind lane-a's landing: $(cat "$M/lane-b.$HB.queue-why")"
[ "$(cat "$M/lane-c.$HC.queue-why")" = 'behind attempt of lane-x' ] || fail "lane-c waited behind a refused attempt: $(cat "$M/lane-c.$HC.queue-why" 2>&1)"
[ "$(cat "$M/lane-d.$HD.queue-why")" = 'first seen +300 s' ] || fail "lane-d was seen late: $(cat "$M/lane-d.$HD.queue-why" 2>&1)"
[ ! -e "$M/lane-e.$HE.queue-why" ] || fail "a lane seen at once with nothing ahead has no why"
out=$(tick "$H" 2300 JG_MERGE_LATENCY_LIMIT_MINUTES=1)
say "$out"
for pair in "lane-b:behind lane-a" "lane-c:behind attempt of lane-x" "lane-d:first seen +300 s"; do
  [ "$(field "$H" "${pair%%:*}" queue_why)" = "${pair#*:}" ] || fail "${pair%%:*}'s row says $(field "$H" "${pair%%:*}" queue_why)"
done
# lane-b waited behind a landing that ran: the row's quiet fact keeps its alert quiet; the other three (over the one-minute limit) raise one each.
[ "$(alerts "$H" | sort | paste -sd' ' -)" = "slow-delivery--lane-c-0c0000000000 slow-delivery--lane-d-0d0000000000 slow-delivery--lane-e-0e0000000000" ] || fail "the alerts are: $(alerts "$H" | paste -sd' ' -)"
! grep -P '\tqueue\t[0-9]*\t[0-9.]*\t$' "$H/data/trunk-latency.tsv" || fail "a queue row has a bare reason"
ok "L5: rows say behind lane-a, behind attempt of lane-x and first seen +300 s; no queue row is bare"
