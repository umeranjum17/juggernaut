#!/usr/bin/env bash
# Parallel landing batches (slice H29): sourced by bin/jg-trunk.sh, never run.
#
# The line's verify judges every commit landed since the green pin. One run over the whole stack takes as long as its gate, and a red
# then costs a serial halving: one whole run for each step. Here the stack is cut into `verify-width` batches (bin/jg-trunk-policy-lib.sh,
# default 4) that test at once, each against the top of the batch before it, and a red batch is searched for its bad commit with up to
# width-1 probes at a time. Only that commit goes back (the caller reverts it); every other lane of the stack stays.
#   batch_verify <top> <gate> <from>   same answer as full_gate: 0 green, 2 a commit of the stack is charged (BATCH_CULPRIT names it),
#                                      1 failed for a reason no test accounts for (BATCH_TRACED=1 once the search has run). With width 1 or a stack of fewer than twice the width it is one full_gate.
# Every run takes one of the host's heavy slots (core/lane-scale/fleet.sh, the one core budget of H25), so the batches of a busy host
# wait for a free slot instead of adding load. A host with no free slot still runs one at a time, as before.
# Search cost: a stack of m commits needs about log(m) / log(width) rounds, so 100 landed lanes at width 4 are judged in 4 rounds of
# 4 runs in place of 7 serial whole runs.
# Needs from the caller: PROJ PN STATE DATA JG_HOME SCRIPT_DIR, pol, full_gate. Uses only git plumbing and the slot script.

BATCH_CULPRIT=''; BATCH_TRACED=''

batch_width() {
  local w; w=$(pol verify-width 2>/dev/null || true)
  case $w in ''|*[!0-9]*|0) w=4 ;; esac
  printf '%s\n' "$w"
}

batch_slot() {  # take|give <name>: one heavy slot, held under this process (a slot whose run is gone is free again)
  JG_STATE_OVERRIDE="$STATE" JG_CONFIG_OVERRIDE="${CONFIG:-$JG_HOME/config}" \
    "$SCRIPT_DIR/../core/lane-scale/fleet.sh" slot "$1" "$JG_HOME" "verify-$PN-$2" "$$" 2>/dev/null
}

# Give back the slot of every probe that has ended.
batch_reap() {  # <dir>
  local f n
  for f in "$1"/*.slot; do
    [ -e "$f" ] || continue; n=$(basename "$f" .slot)
    [ -e "$1/$n.rc" ] || continue
    batch_slot give "$n" || true; rm -f -- "$f"
  done
}

# Run the whole gate of each probe, at most as many at once as there are free heavy slots; the result of probe <n> is <dir>/<n>.rc.
batch_run() {  # <gate> <dir> <name>:<candidate>:<base>...
  local gate=$1 dir=$2 spec n c b
  shift 2; rm -rf -- "$dir"; mkdir -p "$dir"
  for spec; do
    IFS=: read -r n c b <<< "$spec"
    while :; do
      batch_reap "$dir"
      if batch_slot take "$n"; then : > "$dir/$n.slot"; break; fi
      # No slot free: wait for one of this verify's own runs to end, and run alone when it has none.
      if [ "$(jobs -pr | wc -l)" -gt 0 ]; then wait -n 2>/dev/null || true; else break; fi
    done
    (
      rc=0; full_gate "$c" "$gate" "$b" > "$dir/$n.out" 2>&1 || rc=$?
      printf '%s\n' "$rc" > "$dir/$n.rc"
    ) &
  done
  wait || true
  batch_reap "$dir"
}

# The lowest of the commits <cs...> whose whole suite fails against <base>, when the last one is known to fail and <base> passes: an
# n-ary search that tests up to width-1 midpoints at once. Prints nothing when a run ends for a reason no test accounts for.
batch_search() {  # <gate> <base> <width> <commit>...
  local gate=$1 base=$2 w=$3 lo=1 hi step j i p rc dir last
  shift 3; local -a cs=("$@") pts specs
  hi=${#cs[@]}; dir=$DATA/trunk/batch-$PN-$$
  while [ "$lo" -lt "$hi" ]; do
    j=$(( w - 1 )); [ "$j" -le $(( hi - lo )) ] || j=$(( hi - lo )); [ "$j" -ge 1 ] || j=1
    pts=(); step=$(( (hi - lo + j) / (j + 1) )); [ "$step" -ge 1 ] || step=1
    for (( i = 1; i <= j; i++ )); do p=$(( lo + i * step - 1 )); [ "$p" -lt "$hi" ] && pts+=("$p"); done
    [ "${#pts[@]}" -gt 0 ] || pts=("$lo")
    specs=(); for p in "${pts[@]}"; do specs+=("p$p:${cs[p-1]}:$base"); done
    batch_run "$gate" "$dir" "${specs[@]}"
    last=$(( lo - 1 ))
    for p in "${pts[@]}"; do
      rc=$(cat "$dir/p$p.rc" 2>/dev/null || echo 1)
      case $rc in
        0) last=$p ;;
        2) hi=$p; break ;;
        *) rm -rf -- "$dir"; return 0 ;;
      esac
    done
    lo=$(( last + 1 )); [ "$lo" -le "$hi" ] || lo=$hi
  done
  rm -rf -- "$dir"
  printf '%s\n' "${cs[lo-1]}"
}

batch_verify() {  # <top> <gate> <from>
  local top=$1 gate=$2 from=$3 w m size k lo hi rc=0 dir first='' fr=0 name base
  local -a cs specs
  BATCH_CULPRIT=''; BATCH_TRACED=''
  w=$(batch_width)
  mapfile -t cs < <(git -C "$PROJ" rev-list --reverse "$from..$top")
  m=${#cs[@]}
  # A stack under twice the width is cheaper in one run: a split would run about as many gates as it has commits.
  if [ "$w" -lt 2 ] || [ "$m" -lt $(( 2 * w )) ]; then full_gate "$top" "$gate" "$from" || rc=$?; return "$rc"; fi
  size=$(( (m + w - 1) / w )); specs=()
  for (( k = 0; k * size < m; k++ )); do
    lo=$(( k * size )); hi=$(( lo + size )); [ "$hi" -le "$m" ] || hi=$m
    specs+=("b$k:${cs[hi-1]}:$([ "$lo" -eq 0 ] && echo "$from" || echo "${cs[lo-1]}")")
  done
  echo "verify: $m commits since ${from:0:12} in ${#specs[@]} batches of up to $size, tested at once" >&2
  dir=$DATA/trunk/batch-$PN-$$
  batch_run "$gate" "$dir" "${specs[@]}"
  for (( k = 0; k < ${#specs[@]}; k++ )); do
    name=b$k; rc=$(cat "$dir/$name.rc" 2>/dev/null || echo 1)
    [ "$rc" -ne 0 ] || continue
    cat "$dir/$name.out" >&2 2>/dev/null || true
    first=$k; fr=$rc; break
  done
  rm -rf -- "$dir"
  # shellcheck disable=SC2034 # read by cmd_verify
  GATE_KIND=full
  [ -n "$first" ] || return 0
  [ "$fr" -eq 2 ] || return 1
  lo=$(( first * size )); hi=$(( lo + size )); [ "$hi" -le "$m" ] || hi=$m
  base=$([ "$lo" -eq 0 ] && echo "$from" || echo "${cs[lo-1]}")
  BATCH_CULPRIT=$(batch_search "$gate" "$base" "$w" "${cs[@]:lo:hi-lo}")
  # shellcheck disable=SC2034 # read by cmd_verify
  BATCH_TRACED=1
  if [ -n "$BATCH_CULPRIT" ]; then echo "verify: batch $((first + 1)) of ${#specs[@]} is red; the bad commit is ${BATCH_CULPRIT:0:12}, and only it goes back" >&2
  else echo "verify: batch $((first + 1)) of ${#specs[@]} is red and could not be traced to one commit" >&2; fi
  return 2
}
