#!/usr/bin/env bash
# Parallel red bisection (slice H29d): sourced by bin/jg-trunk.sh, never run.
#
# A red stack is halved until the lane that caused the red stands alone. Judged one half after the other, finding it costs a whole gate
# for every half. Here the two halves gate at the same time, each against the trunk tip it would land on, so a stack of B lanes is
# searched in about log2(B) rounds of one gate time. gate-slots (bin/jg-trunk-policy-lib.sh, default 2) is the switch: 1 keeps the
# halves one after the other, as before.
#   bisect_pair <first count> <idx>...  gate the first <count> lanes and the others at once on B_TIP; each verdict is kept under the
#                                       tip and the lanes' own commits, so it is read again only while the trunk has not moved
#   bisect_replay <tip> <idx>...        the kept verdict for exactly these lanes on this tip: sets LAST_RED, LAST_RED_CLASS, GATE_BAD, GATE_BAD_SIG,
#                                       GATE_KIND and GATE_FIGURES as batch_gate does; returns 0 green, 1 red, 2 none is kept
# A verdict never lands anything: the stack loop of cmd_land_batch lands a green half through land_group, which moves the trunk only if
# it is still where the half was gated. A half is gated as the lander would stack it: when a lane would conflict on the bare tip
# (it needs the lane before it), nothing is gated in parallel and the halves run one after the other.
# Needs from the caller: STATE PN B_C0 B_CUR B_WHY, pol, chain_on, batch_gate, red_seen. Uses only git plumbing through those.

BISECT_DIR=''

bisect_on() { [ "$(pol gate-slots)" -ge 2 ] 2>/dev/null; }

bisect_file() {  # <tip> <idx>...: where the verdict of this stack on this tip is kept
  local k=$1 i; shift
  for i; do k="$k-${B_C0[$i]}"; done
  printf '%s/%s\n' "$BISECT_DIR" "$(printf '%s' "$k" | sha1sum | cut -c1-24)"
}

# Gate one half in this process's own subshell (its own gate mark and clone) and keep its verdict and its output.
bisect_gate() {  # <file> <top> <size>
  local f=$1
  ( rc=0; batch_gate "$2" "$3" 2>"$f.err" || rc=$?
    printf 'LAST_RED=%q LAST_RED_CLASS=%q GATE_BAD=%q GATE_BAD_SIG=%q GATE_KIND=%q GATE_FIGURES=%q BV_RC=%q\n' \
      "${LAST_RED:-}" "${LAST_RED_CLASS:-}" "${GATE_BAD:-}" "${GATE_BAD_SIG:-}" "${GATE_KIND:-}" "${GATE_FIGURES:-}" "$rc" > "$f.tmp" && mv -f "$f.tmp" "$f" ) &
}

bisect_pair() {  # <first count> <idx>...
  local n=$1 i part f clean=1 waiting=()
  local -a all part_idx old_cur old_why
  shift; all=("$@")
  [ -n "$BISECT_DIR" ] || BISECT_DIR=$(mktemp -d) || return 1
  for i in "${all[@]}"; do old_cur[i]=${B_CUR[$i]}; old_why[i]=${B_WHY[$i]:-}; done
  for part in 0 1; do
    if [ "$part" = 0 ]; then part_idx=("${all[@]:0:n}"); else part_idx=("${all[@]:n}"); fi
    chain_on "$B_TIP" "${part_idx[@]}"
    if [ "${#CHAIN[@]}" -ne "${#part_idx[@]}" ]; then clean=0; break; fi
    f=$(bisect_file "$B_TIP" "${CHAIN[@]}")
    # A half the red ledger already holds for this tip is never gated again (H29a): the stack loop returns it from the ledger.
    [ -z "$(red_seen "${CHAIN[@]}")" ] || continue
    if [ ! -e "$f" ]; then bisect_gate "$f" "${B_CUR[${CHAIN[${#CHAIN[@]}-1]}]}" "${#CHAIN[@]}"; waiting+=("$f"); fi
  done
  wait || true
  for i in "${all[@]}"; do B_CUR[i]=${old_cur[$i]}; B_WHY[i]=${old_why[$i]}; [ -n "${B_WHY[$i]}" ] || unset 'B_WHY[i]'; done
  for f in ${waiting[@]+"${waiting[@]}"}; do
    # A half that left no verdict (its gate could not run) is gated again by the stack loop on its own.
    [ ! -e "$f.err" ] || { cat "$f.err" >&2; rm -f -- "$f.err"; }
  done
  [ "$clean" = 1 ]
}

bisect_replay() {  # <tip> <idx>...
  local f
  [ -n "$BISECT_DIR" ] || return 2
  f=$(bisect_file "$@"); [ -e "$f" ] || return 2
  # shellcheck disable=SC1090 # a file this function's own subshell wrote
  . "$f"
  [ "$BV_RC" = 0 ]
}
