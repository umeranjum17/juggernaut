#!/usr/bin/env bash
# The wake library's queue read model is Go: core/wake/cmd/jg-wake-core, reached through
# bin/jg-wake-core.sh, answers what a queued row is, which keys are queued for a kind, which sequence
# numbers are still queued, how many rows an actor could act on, and whether a branch grant's row
# snapshot is well formed. bin/jg-wake-lib.sh keeps the function names its callers use and forwards
# each one, so the shell readers are deleted and one implementation owns the row grammar.
#
# What this suite proves:
#   - the Go answers are the shell answers, row for row, stamp for stamp and exit status for exit
#     status, over every queue row of the 123 events recorded on a real JG_WAKE stream
#     (tests/fixtures/wake-recorded/queue-rows.tsv) and over the shapes that stream lacks
#     (heartbeats with moving keys, a payload holding a tab, a short line, a row whose sequence is
#     not a number);
#   - the shapes no replay reaches are still right on their own, so a regenerated pin could not
#     quietly bless a wrong answer.
#
# The pin in tests/fixtures/wake-recorded/queue-reads.tsv is the shell's own answer, recorded from
# the commit that still held it:
#   tests/jg-wake-core.test.sh --replay <git-ref> --record
# and `--replay <git-ref>` alone replays the shell at that ref against the Go command, requires zero
# differences, and requires a corrupted control run to differ. The deleted shell is in git history,
# so neither mode needs a copy of it in the tree.
#
# stdout and exit status are the contract; stderr is not, which is why a reader that cannot open its
# file may name a different reason than awk did.
# Usage: tests/jg-wake-core.test.sh [--replay <git-ref> [--record]]
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lab=$(mktemp -d "${TMPDIR:-/tmp}/jg-wake-core.XXXXXX")
trap 'rm -rf -- "$lab"' EXIT
export TMPDIR=$lab XDG_CACHE_HOME=$lab/cache
unset JG_WAKE_QUEUE JG_WAKE_CORE_BIN JG_WAKE_CORE_GO JG_WAKE_ROUTING JG_HOME JG_STATE_OVERRIDE

ref='' record=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --replay) ref=${2:-}; shift 2 || shift ;;
    --record) record=1; shift ;;
    -h|--help) sed -n '2,/^# Usage/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'usage: %s [--replay <git-ref> [--record]]\n' "$0" >&2; exit 2 ;;
  esac
done
if [ -n "$ref" ] && ! git -C "$ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
  printf 'jg-wake-core: %s is not a commit in this repository\n' "$ref" >&2
  exit 2
fi
if ! command -v "${JG_WAKE_CORE_GO:-go}" >/dev/null 2>&1; then
  printf 'skip: no Go toolchain on PATH; install go to build the wake core\n'
  exit 0
fi

ROWS=$ROOT/tests/fixtures/wake-recorded/queue-rows.tsv
PIN=$ROOT/tests/fixtures/wake-recorded/queue-reads.tsv
STATE=$lab/state
mkdir -p "$STATE"
JG_WAKE_QUEUE=$ROWS JG_STATE_OVERRIDE=$STATE
export JG_WAKE_QUEUE JG_STATE_OVERRIDE
fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok: %s\n' "$1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }

# The shapes the recorded stream does not hold: one kind and key delivered twice, two heartbeats
# with different keys, a payload carrying a tab, a line too short to be a row, and a row whose
# sequence is not a number.
EDGE=$lab/edge.tsv
printf '%s\n' \
  "$(printf '1793600000\t100\tcheck\ta\tfirst')" \
  "$(printf '1793600001\t101\tcheck\ta\tsecond')" \
  "$(printf '1793600002\t102\theartbeat\tw1\tbeat one')" \
  "$(printf '1793600003\t103\theartbeat\tw2\tbeat two')" \
  "$(printf '1793600004\t104\tsignal\tx.status\tsignal: x.status')" \
  "$(printf '1793600005\t105\tcheck\ttabbed\tpayload\twith a tab')" \
  "$(printf '1793600006\t106\tstale\tcrew:gone\tstale: crew:gone')" \
  "$(printf 'short\tline')" \
  "$(printf '1793600007\tnotanumber\tcheck\tbad\tno sequence')" \
  "$(printf '1793600008\t107\tcheck\ta\tthird')" > "$EDGE"
GOOD=$lab/grant-good
DUP=$lab/grant-dup
NONNUM=$lab/grant-nonnum
EMPTY=$lab/grant-empty
printf '100\n101\n102\n' > "$GOOD"
printf '100\n100\n' > "$DUP"
printf '100\none\n' > "$NONNUM"
: > "$EMPTY"
CORPUS_SEQS=$(cut -f2 "$ROWS" | paste -sd' ' -)
EDGE_SEQS="100 101 102 103 104 105 106 107 108"

# The answer set both sides are asked for. It is one function so the shell side and the Go side
# cannot drift apart in what they are asked: whichever library is sourced last answers it.
enc() { base64 | tr -d '\n'; }
q() {  # <label> <command...>
  local label=$1 rc=0 out=$lab/out
  shift
  "$@" > "$out" 2>/dev/null || rc=$?
  printf '%s\t%s\t%s\n' "$label" "$rc" "$(enc < "$out")"
}
answers() {
  local kind
  q 'dedupe corpus' jg_wake_print_deduped "$ROWS"
  q 'dedupe edge' jg_wake_print_deduped "$EDGE"
  for kind in check signal stale heartbeat; do
    q "keys $kind corpus" jg_wake_queued_keys_locked "$kind"
  done
  JG_WAKE_QUEUE=$EDGE
  for kind in check signal stale heartbeat; do
    q "keys $kind edge" jg_wake_queued_keys_locked "$kind"
  done
  # shellcheck disable=SC2086  # a queue's sequence numbers are one per word, as the readers take them
  q 'queued edge' jg_wake_rows_queued $EDGE_SEQS
  # shellcheck disable=SC2086
  q 'count main edge' jg_wake_actor_pending_count main
  JG_WAKE_QUEUE=$ROWS
  # shellcheck disable=SC2086
  q 'queued corpus' jg_wake_rows_queued $CORPUS_SEQS
  q 'queued none' jg_wake_rows_queued
  q 'count main' jg_wake_actor_pending_count main
  q 'grant-valid good' jg_wake_grant_rows_valid "$GOOD"
  q 'grant-valid duplicate' jg_wake_grant_rows_valid "$DUP"
  q 'grant-valid non-number' jg_wake_grant_rows_valid "$NONNUM"
  q 'grant-valid empty' jg_wake_grant_rows_valid "$EMPTY"
  q 'grant-valid absent' jg_wake_grant_rows_valid "$lab/absent"
}

# A live branch grant, so the count that reserves its rows is exercised end to end through the
# forwarding rather than only the reader underneath it.
OWNER=$lab/branch-eligible-owner
GRANT=$lab/branch-eligible-rows
printf '100\n101\n102\n' > "$GRANT"
grant_answers() {
  printf 'jg-branch-eligible-owner-v1\n%s\n%s\ngen-1\n' "$$" "$(jg_pid_identity $$)" > "$OWNER"
  q 'count main grant' jg_wake_actor_pending_count main "$GRANT" "$OWNER"
  q 'count branch grant' jg_wake_actor_pending_count branch "$GRANT" "$OWNER"
  q 'count branch no grant' jg_wake_actor_pending_count branch "$lab/no-such-rows" "$OWNER"
}

# current: the library this checkout ships, whose readers forward to the Go command.
current_answers() {
  # shellcheck source=bin/jg-wake-lib.sh
  . "$ROOT/bin/jg-wake-lib.sh"
  answers
  grant_answers
}

# base: the library at <ref>, whose readers were shell. It runs from a copy with no Go command
# beside it, so the comparison cannot accidentally reach the port.
base_answers() {
  mkdir -p "$lab/base"
  git -C "$ROOT" show "$ref:bin/jg-wake-lib.sh" > "$lab/base/jg-wake-lib.sh" || return 1
  cp "$ROOT/bin/jg-path-lib.sh" "$lab/base/jg-path-lib.sh" || return 1
  # shellcheck source=/dev/null
  . "$lab/base/jg-wake-lib.sh"
  answers
  grant_answers
}

current_answers > "$lab/go.tsv"

# The answers no replay reaches, asserted on their own so the pin is a witness and not the truth.
# This shell sources the shipped library, so these are the calls a producer or the drain makes.
# shellcheck source=bin/jg-wake-lib.sh
. "$ROOT/bin/jg-wake-lib.sh"
queue=$JG_WAKE_QUEUE
check "one heartbeat row survives whatever its key" \
  "$(JG_WAKE_QUEUE=$EDGE jg_wake_print_deduped "$EDGE" | grep -c heartbeat)" 1
check "the newest line wins a repeated event" \
  "$(JG_WAKE_QUEUE=$EDGE jg_wake_print_deduped "$EDGE" | awk -F '\t' '$3 == "check" && $4 == "a" { print $5 }')" third
check "a payload holding a tab is one row" \
  "$(JG_WAKE_QUEUE=$EDGE jg_wake_print_deduped "$EDGE" | awk -F '\t' '$4 == "tabbed" { print NF }')" 6
check "a line too short to be a row is dropped" \
  "$(JG_WAKE_QUEUE=$EDGE jg_wake_print_deduped "$EDGE" | grep -c '^short')" 0
check "a queued line whose sequence is not a number still names its key" \
  "$(JG_WAKE_QUEUE=$EDGE jg_wake_queued_keys_locked check | paste -sd, -)" "a,tabbed,bad"
check "only numbers answer the queued test" \
  "$(JG_WAKE_QUEUE=$EDGE jg_wake_rows_queued 107 notanumber | paste -sd, -)" 107
check "Main owns the rows nobody can retire" "$(JG_WAKE_QUEUE=$EDGE jg_wake_actor_pending_count main)" 10
check "a duplicate sequence number is not a grant" "$(jg_wake_grant_rows_valid "$DUP" && printf yes || printf no)" no
check "a non-number is not a grant row" "$(jg_wake_grant_rows_valid "$NONNUM" && printf yes || printf no)" no
check "an empty file is not a grant" "$(jg_wake_grant_rows_valid "$EMPTY" && printf yes || printf no)" no
check "a grant is a non-empty list of distinct numbers" "$(jg_wake_grant_rows_valid "$GOOD" && printf yes || printf no)" yes
check "a queue that is absent has no queued rows" "$(JG_WAKE_QUEUE=$lab/absent jg_wake_rows_queued 1; printf 'rc=%s' "$?")" "rc=0"
JG_WAKE_QUEUE=$queue
check "the reader exits 2 when its rows file cannot be read" \
  "$(jg_wake_print_deduped "$lab/absent" >/dev/null 2>&1; printf '%s' "$?")" 2
check "the shim refuses to answer without a toolchain or a binary" \
  "$(JG_WAKE_CORE_BIN=$lab/no-binary JG_WAKE_CORE_GO=$lab/no-go XDG_CACHE_HOME=$lab/none "$ROOT/bin/jg-wake-core.sh" count >/dev/null 2>&1; printf '%s' "$?")" 2

if [ -n "$ref" ]; then
  base_answers > "$lab/base.tsv" || { printf 'FAIL: could not read bin/jg-wake-lib.sh at %s\n' "$ref"; exit 1; }
  if diff -u "$lab/base.tsv" "$lab/go.tsv" > "$lab/parity.diff"; then
    printf 'ok: %s answers are identical to the shell at %s\n' "$(wc -l < "$lab/go.tsv" | tr -d ' ')" "$ref"
    if [ "$record" = 1 ]; then
      cp "$lab/base.tsv" "$PIN"
      printf 'recorded: %s\n' "$PIN"
    fi
  else
    printf 'FAIL: the Go answers differ from the shell at %s\n' "$ref"
    sed -n '1,40p' "$lab/parity.diff"
    fails=$((fails + 1))
  fi
  # The control: a corrupted Go side must be caught, or the replay is not proving anything.
  (
    JG_WAKE_CORE_BIN=/bin/true
    export JG_WAKE_CORE_BIN
    # shellcheck source=bin/jg-wake-lib.sh
    . "$ROOT/bin/jg-wake-lib.sh"
    answers
    grant_answers
  ) > "$lab/control.tsv"
  if diff -q "$lab/go.tsv" "$lab/control.tsv" >/dev/null 2>&1; then
    printf 'FAIL: a corrupted Go reader answered identically, so the replay proves nothing\n'
    fails=$((fails + 1))
  else
    printf 'ok: the corrupted control differs\n'
  fi
elif [ -f "$PIN" ]; then
  if diff -u "$PIN" "$lab/go.tsv" > "$lab/pin.diff"; then
    printf 'ok: the Go answers match the recorded shell answers\n'
  else
    printf 'FAIL: the Go answers differ from the recorded shell answers\n'
    sed -n '1,40p' "$lab/pin.diff"
    fails=$((fails + 1))
  fi
else
  printf 'FAIL: %s is missing; run %s --replay <git-ref> --record\n' "$PIN" "$0"
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  printf '%s check(s) failed\n' "$fails"
  exit 1
fi
printf 'all checks passed\n'
