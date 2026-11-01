#!/usr/bin/env bash
# The watcher's own-queue observation on the bus (core/bus/cmd/jg-bus/watcher.go): the wake-watcher
# service is a durable consumer of this home's JG_WAKE events, and the watcher asks it - never the
# queue file - for the oldest unhandled wake and the newest host-memory wake.
#
# Two proofs:
#
#   replay   Every event recorded on this machine's JG_WAKE stream (tests/fixtures/wake-recorded.jsonl:
#            205 raises and 36 acknowledgements from 30 homes) is folded one event at a time by the
#            Go command and by the shell reader it replaced - the render's jq fold, the sorted read
#            model, squad_lead_oldest_queue_row's awk and the host-memory awk, quoted below - and
#            after every event of a home the rows, the oldest row and the newest host-memory row
#            must be identical. A control run with one Go answer corrupted must fail the same
#            comparison, so a green replay is never vacuous. Needs only jq and a Go toolchain.
#   live     A throwaway accounts server and home: the service creates its durable consumer, a real
#            bin/jg-wake-bus.sh raise makes the consumer's acknowledged counter rise, `watcher
#            oldest` answers from the fold and matches state/.wake-queue, an acknowledgement removes
#            the row, a restart handles what arrived while down, and the real watcher cycle
#            re-delivers a stalled row through the service. It gate-skips without the server and client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v go >/dev/null 2>&1 || [ -n "${JG_BUS_BIN:-}" ] || { echo "skip: no Go toolchain to build the bus command"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq is needed for the shell reference"; exit 0; }
DIR=$(jg_test_tmproot jg-wake-watcher)
CORPUS="$ROOT/tests/fixtures/wake-recorded.jsonl"
TAB=$(printf '\t')

# ---- replay -------------------------------------------------------------------------------
# The shell reader this port deletes, quoted from the commit before it: bin/jg-wake-bus.sh's
# live_render fold and read model, and bin/jg-watch.sh's squad_lead_oldest_queue_row and
# host_memory_surface_queued row pick.
shell_rows() { # <events.jsonl>: the read model, LC_ALL=C sorted by sequence
  jq -c -s 'reduce .[] as $e ({};
        if ($e.ack // false) then (if has($e.id) then .[$e.id].ack = true else . end)
        else .[$e.id] = $e end)
      | [to_entries[].value] | map(select((.ack // false) != true)) | .[]' "$1" \
    | jq -r 'select(.where == "queue") | [.at, (.seq // .rseq), .kind, .key, .payload] | @tsv' \
    | LC_ALL=C sort -t "$TAB" -k2,2n
}
shell_oldest() { # <read-model file>
  awk -F '\t' '
    function declared_external_pause(kind, payload) {
      return kind == "stale" \
        && payload ~ /^stale: .*\(paused [0-9]+s, awaiting external - declared (pause,|paused\))/
    }
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ \
      && !declared_external_pause($3, $5) {
      if (!found || $2 < seq) {
        found = 1
        seq = $2
        row = $0
      }
    }
    END { if (found) print row }
  ' "$1"
}
shell_hostmem() { # <read-model file>
  awk -F '\t' '$3 == "check" && $4 == "host-memory" { row=$0 } END { if (row != "") print row }' "$1"
}

BUS_BIN=$DIR/jg-bus
if [ -n "${JG_BUS_BIN:-}" ]; then BUS_BIN=$JG_BUS_BIN; else
  ( cd "$ROOT/core/bus" && go build -o "$BUS_BIN" ./cmd/jg-bus ) || fail "the bus command did not build"
fi
export JG_BUS_ROOT=$ROOT JG_HOME=$DIR/replay-home JG_STATE_OVERRIDE=$DIR/replay-home/state
mkdir -p "$JG_STATE_OVERRIDE"

# replay <label> [--corrupt]: compare every step of every home; prints the number of steps compared.
replay() {
  local corrupt=${1:-} homes home n i checked=0 diffs=0 goout want got goline
  homes=$(jq -r '.home' "$CORPUS" | sort -u)
  n=$(wc -l < "$CORPUS" | tr -d ' ')
  for home in $homes; do
    goout=$DIR/go.$$.jsonl
    "$BUS_BIN" watcher replay "$CORPUS" --home "$home" > "$goout" || fail "the Go replay failed for $home"
    [ "$(wc -l < "$goout" | tr -d ' ')" = "$n" ] || fail "the Go replay printed a different number of steps for $home"
    for i in $(seq 1 "$n"); do
      [ "$(sed -n "${i}p" "$CORPUS" | jq -r '.home')" = "$home" ] || continue
      head -n "$i" "$CORPUS" | jq -c --arg h "$home" 'select(.home == $h)' > "$DIR/prefix.jsonl"
      shell_rows "$DIR/prefix.jsonl" > "$DIR/model.tsv"
      want=$(jq -n -S -c --rawfile rows "$DIR/model.tsv" --arg oldest "$(shell_oldest "$DIR/model.tsv")" \
        --arg hm "$(shell_hostmem "$DIR/model.tsv")" \
        '{rows: ($rows | split("\n") | map(select(. != ""))), oldest: $oldest, host_memory: $hm}')
      goline=$(sed -n "${i}p" "$goout")
      if [ "$corrupt" = --corrupt ] && [ "$checked" = 3 ]; then
        goline=$(printf '%s' "$goline" | jq -c '.rows |= (if length > 0 then (.[0] |= sub("check"; "chexk")) else [] end) | .oldest = (.oldest + "x")')
      fi
      got=$(printf '%s' "$goline" | jq -S -c '.')
      checked=$((checked + 1))
      [ "$want" = "$got" ] || { diffs=$((diffs + 1)); [ "$diffs" -gt 1 ] || printf 'diff at event %s of %s:\n  shell: %s\n  go:    %s\n' "$i" "$home" "$want" "$got" >&2; }
    done
    rm -f "$goout"
  done
  printf '%s steps, %s differences\n' "$checked" "$diffs"
  [ "$diffs" -eq 0 ]
}

steps=$(replay) || fail "the Go fold differs from the shell reader: $steps"
pass "replay: the Go fold and the shell reader agree after every recorded event ($steps)"
corrupt_out=$(replay --corrupt 2>/dev/null) && fail "a corrupted Go answer was not reported: $corrupt_out"
pass "replay control: a corrupted Go answer fails the same comparison ($corrupt_out)"

# ---- live ---------------------------------------------------------------------------------
SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
JG_NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
if [ -z "$SERVER" ] || [ -z "$JG_NATS_BIN" ]; then echo "skip: live proof needs nats-server and the nats client"; exit 0; fi
export JG_NATS_BIN

HOME_DIR="$DIR/home"
mkdir -p "$HOME_DIR/state/bus" "$HOME_DIR/config/bus" "$HOME_DIR/data"
port=$(( 47100 + RANDOM % 800 ))
sed "s/4222/$port/" "$ROOT/core/bus/nats.conf" > "$HOME_DIR/config/bus/nats.conf"
printf 'set nats-url nats://127.0.0.1:%s\n' "$port" > "$HOME_DIR/config/captain-channel"
printf 'nats-url nats://127.0.0.1:%s\n' "$port" > "$HOME_DIR/config/wake-bus"
printf 'now * * * *\n' > "$HOME_DIR/config/wake-routing"
export JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" JG_WAKE_ROUTING="$HOME_DIR/config/wake-routing"
unset JG_BUS_BIN
"$ROOT/bin/jg-bus.sh" unit nats > "$DIR/unit.txt" 2>"$DIR/unit.err" || fail "the unit and accounts were not generated: $(cat "$DIR/unit.err")"
( cd "$HOME_DIR/state/bus" && exec "$SERVER" -c bus.conf > "$DIR/nats.log" 2>&1 ) &
printf '%s\n' "$!" >> "$JG_TEST_BUS_REGISTRY"
for _ in $(seq 1 200); do grep -q 'Server is ready' "$DIR/nats.log" 2>/dev/null && break; sleep 0.05; done
grep -q 'Server is ready' "$DIR/nats.log" || { echo "skip: the throwaway server never became ready"; exit 0; }
BUS="$ROOT/bin/jg-bus.sh"
WAKE="$ROOT/bin/jg-wake-bus.sh"
WATCHER_PID=''
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  [ -z "$WATCHER_PID" ] || kill "$WATCHER_PID" 2>/dev/null || true
  jg_test_cleanup
}
trap cleanup EXIT

field() { "$BUS" probe wake-watcher 2>/dev/null | tr ' ' '\n' | sed -n "s/^$1=//p"; }
wait_field() { # <name> <want>: bounded, no fixed sleep
  for _ in $(seq 1 600); do [ "$(field "$1")" = "$2" ] && return 0; sleep 0.05; done
  return 1
}
wait_ready() { for _ in $(seq 1 600); do "$BUS" probe wake-watcher >/dev/null 2>&1 && return 0; sleep 0.05; done; return 1; }
start_watcher() { "$BUS" wake-watcher >> "$DIR/watcher.log" 2>&1 & WATCHER_PID=$!; }
rows() { "$BUS" watcher rows 2>/dev/null; }
# wait_rows <count>: the fold holds that many rows; bounded.
wait_rows() { for _ in $(seq 1 600); do [ "$(rows | wc -l | tr -d ' ')" = "$1" ] && return 0; sleep 0.05; done; return 1; }

for _ in $(seq 1 40); do "$BUS" bootstrap >/dev/null 2>&1; "$BUS" stream >/dev/null 2>&1 && break; sleep 0.25; done
"$BUS" stream || fail "the captain stream was not created"

# Before the service runs, the view is the render's own inputs, and says so.
"$WAKE" raise check ready-work "check: ready work waiting (0/4 open): alpha-one" now || fail "the raise did not publish"
msg=$("$BUS" watcher oldest 2>&1 >/dev/null)
case "$msg" in *"wake-watcher service is not running"*) ;; *) fail "a stopped service was not named: $msg" ;; esac
"$BUS" watcher oldest 2>/dev/null | grep -q 'alpha-one' || fail "the degraded view lost the queued wake"
pass "without the service the view is the replica and says so"

start_watcher
wait_ready || fail "the wake watcher never created its consumer: $(cat "$DIR/watcher.log")"
before=$("$BUS" probe wake-watcher)
wait_field acked 1 || fail "the consumer did not acknowledge the wake raised before it started: $("$BUS" probe wake-watcher) $(cat "$DIR/watcher.log")"
wait_rows 1 || fail "the fold did not take the recorded raise"
"$WAKE" raise check host-memory "check: host memory ALERT: probe" now || fail "the second raise did not publish"
wait_field acked 2 || fail "the acknowledged counter did not rise on a real event: $("$BUS" probe wake-watcher)"
after=$("$BUS" probe wake-watcher)
[ "$(field pending)" = 0 ] || fail "events are still pending: $after"
pass "the acknowledged counter rises on real events: $before -> $after"

"$BUS" watcher oldest 2>/dev/null | grep -q "^[0-9]*${TAB}[0-9]*${TAB}check${TAB}ready-work${TAB}check: ready work waiting (0/4 open): alpha-one${TAB}[0-9]*\$" \
  || fail "the oldest row is not the first raise: $("$BUS" watcher oldest 2>&1)"
latest=$("$BUS" watcher latest check host-memory 2>/dev/null)
[ "${latest##*"$TAB"}" = "check: host memory ALERT: probe" ] || fail "the newest host-memory row is wrong: $latest"
[ "$(rows)" = "$(cat "$HOME_DIR/state/.wake-queue")" ] || fail "the fold and the read model differ: $(rows) vs $(cat "$HOME_DIR/state/.wake-queue")"
pass "the fold answers oldest and latest, and equals the read model the render writes"

# An acknowledgement settles the row on the bus; the fold drops it.
ids=$("$WAKE" ids check ready-work) || fail "no id for the first raise"
"$WAKE" ack "$ids" || fail "the acknowledgement did not publish"
wait_field acked 3 || fail "the acknowledgement was not consumed: $("$BUS" probe wake-watcher)"
wait_rows 1 || fail "the settled row is still in the fold: $(rows)"
"$BUS" watcher oldest 2>/dev/null | grep -q 'host memory ALERT' || fail "the oldest row is not the remaining one"
pass "an acknowledgement removes its row from the fold"

# A restart handles what arrived while the service was down, and the counters continue.
kill "$WATCHER_PID"; wait "$WATCHER_PID" 2>/dev/null
"$WAKE" raise signal lane.status "signal: lane.status" now || fail "the raise while down did not publish"
start_watcher
wait_ready || fail "the restarted watcher never found its consumer"
wait_field acked 4 || fail "the wake raised while down was not consumed after the restart: $("$BUS" probe wake-watcher)"
wait_rows 2 || fail "the fold lost state across the restart: $(rows)"
[ "$(field failed)" = 0 ] || fail "a handle failed: $(cat "$DIR/watcher.log")"
pass "a restart consumes what arrived while down and keeps the fold"

# A lost fold is rebuilt by replaying the stream.
kill "$WATCHER_PID"; wait "$WATCHER_PID" 2>/dev/null
rm -f "$HOME_DIR/state/bus/wake-watcher.fold.json"
start_watcher
wait_ready || fail "the watcher did not come back without its fold"
wait_rows 2 || fail "the lost fold was not rebuilt from the stream: $(rows)"
pass "a lost fold is rebuilt by replaying the stream"

# The real watcher cycle re-delivers the stalled oldest row through the service, with no read of the queue file.
rm -f "$HOME_DIR/state/bus/wake-watcher.progress"
mkdir -p "$DIR/fakebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DIR/fakebin/tmux"; chmod +x "$DIR/fakebin/tmux"
chmod 000 "$HOME_DIR/state/.wake-queue"
PATH="$DIR/fakebin:$PATH" JG_POLL=0.2 JG_SIGNAL_GRACE=0 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 \
  JG_SQUAD_LEAD_WAKE_STALL_SECS=1 JG_WATCH_HANDLING_SUCCESSOR=1 \
  "$ROOT/bin/jg-watch.sh" > "$DIR/watch.out" 2> "$DIR/watch.err" &
cycle=$!
for _ in $(seq 1 300); do [ ! -s "$DIR/watch.out" ] || break; sleep 0.1; done
kill "$cycle" 2>/dev/null; wait "$cycle" 2>/dev/null
chmod 600 "$HOME_DIR/state/.wake-queue"
grep -q 'host memory ALERT: probe' "$DIR/watch.out" || fail "the watcher did not re-deliver the stalled row: out=$(cat "$DIR/watch.out") err=$(cat "$DIR/watch.err")"
pass "the watcher cycle re-delivers the stalled oldest row with the queue file unreadable: $(head -n 1 "$DIR/watch.out")"
