#!/usr/bin/env bash
# Behavior tests for the cleanup machine table (core/machines/tables/cleanup.tsv): 5 states, 7 moves, observer core/machines/observers/cleanup.sh.
# Every record is generated here in the shape its writer prints; no fleet record is copied. The table is report-only.
# A fixture record in every state prints the right word through the real jg-machine.sh and the real observer, the table lints,
# and a legal move adds no line to the shadow log while an illegal one adds one.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-cleanup)
export JG_HOME="$T/home"
M=$JG_HOME/data/jg-trunk-landing; S=$JG_HOME/state; TMPR=$T/tmp
mkdir -p "$M" "$S" "$TMPR"; export JG_TMP_ROOT=$TMPR
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
H=$(printf 'a%.0s' $(seq 40))

jm check cleanup; expect_code 0 "$RC" "the cleanup table lints"; assert_equals "ok cleanup: 5 states, 7 edges" "$OUT" "lint golden"
jm enum cleanup; expect_code 0 "$RC" "the enum lints"; assert_contains "$OUT" 5 "five values"
jm coverage cleanup; expect_code 0 "$RC" "every edge names its test"
assert_equals "requested checking refused removing done" \
  "$(awk -F'\t' '$1=="state"{printf "%s ", $2}' "$ROOT/core/machines/tables/cleanup.tsv" | sed 's/ $//')" "the five states"
pass "the cleanup table lints with 5 states and 7 moves, each with a test"

meta() { printf 'project=/p\nbranch=fm/%s\n' "$1" > "$S/$1.meta"; }
land() { printf '%s\n' "$2" > "$M/$1.$H.state"; }  # <task> <line as the lander prints it>
word_of() {
  jm show cleanup "$1"
  if [ "$RC" -eq 0 ]; then printf '%s\n' "$OUT" | awk -F'\t' '$1 == "state" { print $2 }'
  else printf '%s\n' "$OUT" | sed -n "s/.*observer printed '\(.*\)'.*/\1/p"; fi
}
# Lane records.
meta l-req; land l-req "landed"
meta l-chk; land l-chk "landed"; mkdir -p "$S/.meta-l-chk.lock"; sleep 30 & HOLDER=$!; echo "$HOLDER" > "$S/.meta-l-chk.lock/pid"
meta l-ref; land l-ref "landed cleanup refused, nothing was forced: error: unlanded work"
meta l-rechk; land l-rechk "landed cleanup refused, nothing was forced: x"; mkdir -p "$S/.meta-l-rechk.lock"; echo "$HOLDER" > "$S/.meta-l-rechk.lock/pid"
meta l-rem; land l-rem "landed"; printf 'mode=close\n' > "$S/l-rem.backlog-close"
meta l-dead; land l-dead "landed"; mkdir -p "$S/.meta-l-dead.lock"; echo 999999 > "$S/.meta-l-dead.lock/pid"
land l-done "landed cleaned up"
printf 'done [at=1]: ready\n' > "$S/l-gone.status"
meta l-live; printf 'working [at=1]: x\n' > "$S/l-live.status"
# Orphan temp entries: a jg-* folder past the limit, a young one, one a task record names, one a process holds, and a missing one.
mkdir -p "$TMPR/jg-old" "$TMPR/jg-young" "$TMPR/jg-owned" "$TMPR/jg-held"
touch -d '5 hours ago' "$TMPR/jg-old" "$TMPR/jg-owned" "$TMPR/jg-held"
printf 'project=/p\nscratch=%s\n' "$TMPR/jg-owned" > "$S/owner.meta"
( cd "$TMPR/jg-held" && exec sleep 30 ) & HELD=$!
sleep 0.3
: > "$T/states.corpus"
for rec in "l-req:requested" "l-chk:checking" "l-ref:refused" "l-rechk:checking" "l-rem:removing" "l-dead:requested" "l-done:done" "l-gone:done" \
  "l-live:" "l-none:" "tmp:jg-old:requested" "tmp:jg-held:refused" "tmp:jg-gone:done" "tmp:jg-young:" "tmp:jg-owned:" "tmp:other:"; do
  r=${rec%:*}; want=${rec##*:}
  got=$(bash "$ROOT/core/machines/observers/cleanup.sh" "$r")
  echo "cleanup.sh $r -> ${got:-nothing}"
  assert_equals "$want" "$got" "$r is ${want:-no state}"
  [ -z "$want" ] || { assert_equals "$want" "$(word_of "$r")" "show names the same word for $r"; printf '%s\n' "$want" >> "$T/states.corpus"; }
done
for st in requested checking refused removing "done"; do grep -qx "$st" "$T/states.corpus" || fail "no fixture is in state $st"; done
jm check cleanup --corpus "$T/states.corpus"; expect_code 0 "$RC" "every word a fixture printed is a state"
pass "a fixture record in every state prints the right word"

{ tab requested check checking; tab checking pass removing; tab checking refuse refused; tab refused recheck checking
  tab refused discard removing; tab removing removed "done"; } > "$T/moves.corpus"
jm check cleanup --corpus "$T/moves.corpus"; expect_code 0 "$RC" "legal moves replay clean"
tab "done" check checking > "$T/bad.corpus"
jm check cleanup --corpus "$T/bad.corpus"; expect_code 1 "$RC" "a move out of done"
assert_contains "$OUT" "done check checking is not a move" "check names the move"
pass "check replays the six legal moves and refuses a move out of done"

LOG=$JG_HOME/data/machine-shadow.log
lines() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }
shadow() { local b; b=$(lines); bash "$ROOT/bin/jg-machine-shadow.sh" cleanup "$1" "$2" || fail "the shadow helper must always exit 0"; echo $(( $(lines) - b )); }
assert_equals 0 "$(shadow l-req checking)" "requested -> checking is legal"
assert_equals 0 "$(shadow l-ref checking)" "refused -> checking is legal"
assert_equals 0 "$(shadow l-chk removing)" "checking -> removing is legal"
assert_equals 0 "$(shadow l-rem "done")" "removing -> done is legal"
assert_equals 1 "$(shadow l-req removing)" "requested -> removing skips the check and is illegal"
assert_equals 1 "$(shadow l-done checking)" "a done cleanup has no move"
assert_contains "$(tail -n 1 "$LOG")" cleanup "the shadow line names the machine"
pass "a legal move adds no shadow line, an illegal move adds one"
kill "$HOLDER" "$HELD" 2>/dev/null; true
