#!/usr/bin/env bash
# jg-load-journey.sh - one repeatable private-lab load and fault journey: N lab homes at once, each with M fixture
# lanes, every named fault injected into every home, and the recovery timed and checked.
#
# Usage:
#   jg-load-journey.sh run [--homes <n>] [--lanes <n>] [--faults <a,b,...>] [--deadline <seconds>] [--out <dir>]
#   jg-load-journey.sh list
#
# Defaults: 15 homes, 30 lanes in all (lanes are spread over the homes), every fault, a 60 second recovery
# deadline. run prints one JSON line per fault and home, and writes the same lines to <out>/faults.jsonl:
#   {"home":..,"fault":..,"recovered":true|false,"recovery_ms":..,"tokens":..,"repeat":true|false}
# then one summary line. It exits 0 only when every fault recovered inside the deadline with no model turn and
# no second alarm when its recovery ran again on the same state (the alert files and the wake queue are the same
# before and after the second run); otherwise it exits 1 and names each failure.
# Every home is a disposable lab home (bin/jg-lab-home.sh) under one private root; the journey never reads or
# writes a live home. Homes run at the same time, so the host is loaded the way a fleet loads it. A home's
# recovery is the real owner script of that fault, run the way the watcher runs it, never a stub.
# A fault is one file in core/load-journey/faults/<name>.sh that defines fault_inject <home> <lane>,
# fault_recover <home> and fault_recovered <home> <lane>, and may define fault_tokens <home> (model tokens its
# recovery spent; default 0 because the recovery owners run no model). JG_LOAD_JOURNEY_FAULTS names another fault
# directory (a test's own faults).
# Not in this slice: the faults killed watcher, killed worker, oversized check output, full temporary disk, moved
# trunk and missing key; the named Herdr session; the mid-run update; a per-failure ticket number.
set -u
JGL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export JGL_ROOT
FAULT_DIR=${JG_LOAD_JOURNEY_FAULTS:-$JGL_ROOT/core/load-journey/faults}

die() { printf 'jg-load-journey.sh: %s\n' "$*" >&2; exit 2; }
now_ms() { date +%s%3N; }

list_faults() { local f; for f in "$FAULT_DIR"/*.sh; do [ -e "$f" ] && basename "$f" .sh; done; }

# state_fingerprint <home>: what an alarm leaves behind - every alert record and the wake queue.
state_fingerprint() {
  local h=$1
  { cat "$h"/state/alerts/*.rec 2>/dev/null; cat "$h/state/.wake-queue" 2>/dev/null; } | cksum
}

# run_fault <home> <lane> <fault> <deadline>: print the result line of one fault in one home.
run_fault() {
  local home=$1 lane=$2 fault=$3 deadline=$4 t0 t1 recovered=false before after repeat=false tokens=0
  ( # shellcheck source=/dev/null
    . "$FAULT_DIR/$fault.sh"
    fault_inject "$home" "$lane"
    t0=$(now_ms)
    while :; do
      fault_recover "$home"
      if fault_recovered "$home" "$lane"; then recovered=true; break; fi
      [ $(( $(now_ms) - t0 )) -lt $((deadline * 1000)) ] || break
      sleep 0.2
    done
    t1=$(now_ms)
    before=$(state_fingerprint "$home")
    fault_recover "$home"
    after=$(state_fingerprint "$home")
    [ "$before" = "$after" ] || repeat=true
    if declare -F fault_tokens >/dev/null; then tokens=$(fault_tokens "$home"); fi
    jq -cn --arg home "$(basename "$home")" --arg fault "$fault" --argjson recovered "$recovered" \
      --argjson ms "$((t1 - t0))" --argjson tokens "$tokens" --argjson repeat "$repeat" \
      '{home:$home,fault:$fault,recovered:$recovered,recovery_ms:$ms,tokens:$tokens,repeat:$repeat}' )
}

# run_home <root> <index> <lanes> <faults> <deadline>: one lab home, every fault in turn.
run_home() {
  local root=$1 i=$2 lanes=$3 faults=$4 deadline=$5 home fault n=0
  home=$root/home-$i
  "$JGL_ROOT/bin/jg-lab-home.sh" create "$home" >/dev/null || return 1
  ln -s "$JGL_ROOT/bin" "$home/bin"
  for fault in $faults; do
    n=$((n + 1))
    JG_HOME=$home run_fault "$home" "lane-$i-$(( (n - 1) % lanes + 1 ))" "$fault" "$deadline"
  done
}

cmd_run() {
  local homes=15 lanes=30 faults='' deadline=60 out='' root i per
  while [ $# -gt 0 ]; do
    case $1 in
      --homes) homes=${2:?--homes needs a number}; shift 2 ;;
      --lanes) lanes=${2:?--lanes needs a number}; shift 2 ;;
      --faults) faults=$(printf '%s' "${2:?--faults needs a list}" | tr ',' ' '); shift 2 ;;
      --deadline) deadline=${2:?--deadline needs seconds}; shift 2 ;;
      --out) out=${2:?--out needs a directory}; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  case $homes$lanes$deadline in *[!0-9]*) die "--homes, --lanes and --deadline take whole numbers" ;; esac
  [ "$homes" -ge 1 ] && [ "$lanes" -ge "$homes" ] || die "need at least one home and one lane per home"
  [ -n "$faults" ] || faults=$(list_faults)
  for i in $faults; do [ -r "$FAULT_DIR/$i.sh" ] || die "no fault named $i (jg-load-journey.sh list)"; done
  [ -n "$out" ] || out=$(mktemp -d)
  mkdir -p "$out" || die "cannot make $out"
  root=$(mktemp -d) || die "cannot make the lab root"
  # shellcheck disable=SC2064 # the root is fixed now
  trap "rm -rf -- '$root'" EXIT
  per=$((lanes / homes))
  for i in $(seq 1 "$homes"); do
    run_home "$root" "$i" "$per" "$faults" "$deadline" > "$out/home-$i.jsonl" &
  done
  wait
  cat "$out"/home-*.jsonl > "$out/faults.jsonl"
  cat "$out/faults.jsonl"
  # shellcheck disable=SC2086 # the fault names are plain words
  jq -s --argjson homes "$homes" --argjson lanes "$lanes" --argjson expected "$((homes * $(set -- $faults; echo $#)))" '
    {summary:true,homes:$homes,lanes:$lanes,expected:$expected,results:length,
     failed:[.[]|select(.recovered==false or .repeat==true or .tokens>0)|{home,fault}]}' "$out/faults.jsonl" \
    | tee "$out/summary.json" | jq -c .
  jq -e '.failed == [] and .results == .expected' "$out/summary.json" >/dev/null
}

case ${1:-} in
  run) shift; cmd_run "$@" ;;
  list) list_faults ;;
  --help|-h|'') sed -n '2,/^set -u/{ /^set -u/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}" ;;
  *) die "unknown command $1 (--help)" ;;
esac
