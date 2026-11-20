#!/usr/bin/env bash
# machine_runs_burst (bin/jg-test-host-lib.sh "Run slots"): when every general run slot is held, a lane run may take
# one of <burst> extra slots after the reserved trunk slot, but only while the machine's cpu pressure (some avg10) is
# under 10 - or, with no pressure file, load1 is under 0.8 x cpus. Each case starts real runners (bash processes that
# source the real library and hold their slot) against a throwaway slot directory and stand-in load files.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-test-host-burst)
CPUS=$(python3 -c 'import os; print(os.cpu_count() or 1)')
HOLDERS=()
trap 'for p in "${HOLDERS[@]:-}"; do [ -z "$p" ] || kill "$p" 2>/dev/null; done; wait 2>/dev/null' EXIT

# new_world <name> <pressure avg10 | none> <load1 as a share of the cpus>: a slot directory and the two load stand-ins.
new_world() {
  W=$TMP_ROOT/$1
  rm -rf "$W"
  mkdir -p "$W/slots"
  if [ "$2" = none ]; then
    PRESSURE_FILE=$W/no-such-pressure
  else
    PRESSURE_FILE=$W/pressure
    printf 'some avg10=%s avg60=0.50 avg300=0.10 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$2" >"$PRESSURE_FILE"
  fi
  LOAD_FILE=$W/loadavg
  awk -v c="$CPUS" -v s="$3" 'BEGIN { printf "%.2f 1.00 1.00 1/100 1\n", c * s }' >"$LOAD_FILE"
  N=0
}

# start_run <max> <burst> [trunk]: one runner that admits itself, writes its slot to $W/out.<n>, and holds it.
# Sets RUN to the run number (no command substitution: it would lose the counter); the runner stays in HOLDERS.
start_run() {
  local max=$1 burst=$2 trunk=${3:-}
  N=$((N + 1))
  # shellcheck disable=SC2016 # the child bash expands its own variables
  env -u JG_TEST_RUN_SLOT -u JG_TRUNK_GATE_OUTPUT ${trunk:+JG_TRUNK_GATE_OUTPUT=$W/trunk-out} \
    JG_TEST_NICE=0 JG_TEST_HOST_SLOTS="$W/slots" JG_TEST_HOST_PRESSURE_FILE="$PRESSURE_FILE" \
    JG_TEST_HOST_LOADAVG_FILE="$LOAD_FILE" LIB="$ROOT/bin/jg-test-host-lib.sh" OUT="$W/out.$N" MAX="$max" BURST="$burst" \
    bash -c 'log() { :; }; now_ms() { date +%s%3N; }; . "$LIB"; jg_test_host_admit "$MAX" "$BURST"
      echo "${JG_TEST_RUN_SLOT##*/}" >"$OUT"; exec sleep 60' >/dev/null 2>&1 &
  HOLDERS+=("$!")
  RUN=$N
}

# slot_of <n> <seconds>: the slot run <n> got within the time, else "waiting".
slot_of() {
  local i
  for ((i = 0; i < $2 * 10; i++)); do
    [ -s "$W/out.$1" ] && { cat "$W/out.$1"; return 0; }
    sleep 0.1
  done
  printf 'waiting'
}

stop_runs() {
  local p
  for p in "${HOLDERS[@]}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  HOLDERS=()
}

burst_events() { grep -c "$(printf '\tadmit-burst\t')" "$W/slots/load.tsv" 2>/dev/null || :; }

test_t1_a_lane_run_takes_a_burst_slot_while_pressure_is_low() {
  local a b c
  new_world t1 1.00 0.625
  start_run 1 1; a=$RUN; [ "$(slot_of "$a" 10)" = slot-1 ] || fail "T1: the first holder must take slot-1, got $(slot_of "$a" 1)"
  start_run 1 1; b=$RUN
  [ "$(slot_of "$b" 5)" = slot-3 ] || fail "T1: the second run must take burst slot-3 at once, got $(slot_of "$b" 1)"
  [ "$(burst_events)" = 1 ] || fail "T1: load.tsv must hold one admit-burst line, got $(burst_events)"
  start_run 1 1; c=$RUN
  [ "$(slot_of "$c" 3)" = waiting ] || fail "T1: a third run must wait, only 1 burst slot exists, got $(slot_of "$c" 1)"
  stop_runs
  pass 'T1: with every slot held and pressure 1.0, the second lane run takes slot-3 and records admit-burst; a third waits'
}

test_t2_high_pressure_shuts_the_burst() {
  local a b
  new_world t2 25.00 0.625
  start_run 1 1; a=$RUN; [ "$(slot_of "$a" 10)" = slot-1 ] || fail "T2: the first holder must take slot-1"
  start_run 1 1; b=$RUN
  [ "$(slot_of "$b" 3)" = waiting ] || fail "T2: at pressure 25.0 the second run must wait, got $(slot_of "$b" 1)"
  [ "$(burst_events)" = 0 ] || fail "T2: no admit-burst may be recorded at pressure 25.0"
  # The pressure is read at each try: once it falls the waiting run takes the burst slot.
  printf 'some avg10=2.00 avg60=0.50 avg300=0.10 total=1\n' >"$PRESSURE_FILE"
  [ "$(slot_of "$b" 8)" = slot-3 ] || fail "T2: when the pressure falls the waiting run must take slot-3, got $(slot_of "$b" 1)"
  stop_runs
  pass 'T2: at pressure 25.0 the second run waits and takes slot-3 once the pressure falls'
}

test_t2b_without_a_pressure_file_the_load_decides() {
  local a b
  new_world t2b-busy none 0.9375
  start_run 1 1; a=$RUN; [ "$(slot_of "$a" 10)" = slot-1 ] || fail "T2b: the first holder must take slot-1"
  start_run 1 1; b=$RUN
  [ "$(slot_of "$b" 3)" = waiting ] || fail "T2b: with no pressure file and load 0.94 x cpus the run must wait, got $(slot_of "$b" 1)"
  stop_runs
  new_world t2b-quiet none 0.3125
  start_run 1 1; a=$RUN; [ "$(slot_of "$a" 10)" = slot-1 ] || fail "T2b: the first holder must take slot-1"
  start_run 1 1; b=$RUN
  [ "$(slot_of "$b" 5)" = slot-3 ] || fail "T2b: with no pressure file and load 0.31 x cpus the run must take slot-3, got $(slot_of "$b" 1)"
  stop_runs
  pass 'T2b: with no pressure file, load 0.94 x cpus waits and load 0.31 x cpus takes slot-3'
}

test_t3_burst_zero_is_todays_behaviour() {
  local a b
  new_world t3 1.00 0.625
  start_run 1 0; a=$RUN; [ "$(slot_of "$a" 10)" = slot-1 ] || fail "T3: the first holder must take slot-1"
  start_run 1 0; b=$RUN
  [ "$(slot_of "$b" 3)" = waiting ] || fail "T3: with burst 0 the second run must wait, got $(slot_of "$b" 1)"
  stop_runs
  pass 'T3: with burst 0 the second run waits'
}

test_t4_a_trunk_run_never_takes_a_burst_slot() {
  local a t1 t2
  new_world t4 1.00 0.625
  start_run 1 1; a=$RUN; [ "$(slot_of "$a" 10)" = slot-1 ] || fail "T4: the lane holder must take slot-1"
  start_run 1 1 trunk; t1=$RUN
  [ "$(slot_of "$t1" 5)" = slot-2 ] || fail "T4: the first trunk run must take the reserved slot-2, got $(slot_of "$t1" 1)"
  start_run 1 1 trunk; t2=$RUN
  [ "$(slot_of "$t2" 3)" = waiting ] || fail "T4: a second trunk run must wait, never take burst slot-3, got $(slot_of "$t2" 1)"
  stop_runs
  pass 'T4: a second trunk run waits and never takes the burst slot'
}

test_t1_a_lane_run_takes_a_burst_slot_while_pressure_is_low
test_t2_high_pressure_shuts_the_burst
test_t2b_without_a_pressure_file_the_load_decides
test_t3_burst_zero_is_todays_behaviour
test_t4_a_trunk_run_never_takes_a_burst_slot

printf 'all %s\n' 'jg-test-host-burst tests passed'
