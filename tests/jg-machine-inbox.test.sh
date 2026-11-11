#!/usr/bin/env bash
# Behavior tests for the task-inbox machine table (core/machines/tables/task-inbox.tsv): every steer has one
# provable state, read through bin/jg-delivery.sh. Delivery files are generated here by seed_msg (no fleet
# record is copied). A message id is <task>:<NNN>. Proves: the table lints; only the four known word paths
# replay clean and a fifth is refused; `read` is derived from the file's place and never written; each ladder
# marker (and the sequence lock) has a row the observer reaches; a worker's claim ends the ladder; and the
# AX walk: `next` names the handle command, running it moves the record to the `to` it listed.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-inbox); H=$T/home; S=$H/state; mkdir -p "$S"; ln -s "$ROOT/bin" "$H/bin"
unset JG_MACHINES_TABLES
export JG_HOME="$H" JG_STATE_OVERRIDE="$S" JG_DELIVERY_BUS_TIMEOUT=1
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
state_of() { jm show task-inbox "$1"; printf '%s\n' "$OUT" | awk -F'\t' '$1=="state"{print $2}'; }

at=1000
seed_msg() {  # <task> <seq> <inbox|handled> <word>...: a record file in its place plus one ledger line per word
  local n=$2 place=$3 w d=$S/$1.inbox; shift 3
  mkdir -p "$d/handled"; if [ "$place" = handled ]; then : > "$d/handled/$n.msg"; else : > "$d/$n.msg"; fi
  for w in "$@"; do at=$((at + 1))
    jq -nc --argjson seq "$((10#$n))" --arg word "$w" --argjson at "$at" '{seq:$seq,word:$word,at:$at}' >> "$d/.delivery.jsonl"; done
}
seed_msg a 001 inbox stored
seed_msg a 002 inbox stored rung
seed_msg a 003 handled stored rung
seed_msg a 004 handled stored rung handled
seed_msg a 005 handled stored rung failed
seed_msg a 006 inbox stored handled
seed_msg a 007 inbox stored rung

jm check task-inbox; expect_code 0 "$RC" "the table lints"; assert_contains "$OUT" "ok task-inbox:" "check reports the table"
pass "the table passes the lint rules"

for c in 001:stored 002:rung 003:read 004:handled 005:failed 006:handled; do
  assert_equals "${c#*:}" "$(state_of "a:${c%%:*}")" "message ${c%%:*} state"
done
assert_equals 0 "$(grep -c '"word":"read"' "$S/a.inbox/.delivery.jsonl")" "no read word is ever written"
jm show task-inbox a:003; assert_contains "$OUT" "derived" "read is a derived state"
pass "each delivery shape reads as one state, and read comes from the file's place only"

# The four known word paths replay clean; a fifth does not. The corpus is built from the seeded ledgers.
ev() { case "$1 $2" in "stored rung") echo ring ;; *" handled") echo handle ;; *" failed") echo fail ;; esac; }
corpus() {
  jq -r -s 'group_by(.seq)[] | map(.word) | join(" ")' "$S/a.inbox/.delivery.jsonl" | while read -r -a ws; do
    for i in $(seq 1 $((${#ws[@]} - 1))); do printf '%s\t%s\t%s\n' "${ws[i-1]}" "$(ev "${ws[i-1]}" "${ws[i]}")" "${ws[i]}"; done
  done
}
corpus > "$T/paths.corpus"
assert_equals 4 "$(awk -F'\t' '{print $1 $3}' "$T/paths.corpus" | sort -u | wc -l)" "the seed holds the paths stored>rung>handled/failed, stored>handled and stored>rung"
jm check task-inbox --corpus "$T/paths.corpus"; expect_code 0 "$RC" "the known paths"; assert_contains "$OUT" "0 findings" "no finding on known paths"
printf 'handled\tring\trung\n' >> "$T/paths.corpus"
jm check task-inbox --corpus "$T/paths.corpus"; expect_code 1 "$RC" "a ring after handled"; assert_contains "$OUT" "handled ring rung is not a move" "the fifth path is named"
pass "only the four known word paths replay clean"

# Ladder markers: one seeded message per marker, a row each, and a claim or a move ends the ladder.
mark() {  # <marker> <content> <state>
  rm -rf "$S/m.inbox"; seed_msg m 001 inbox stored rung; printf '%b' "$2" > "$S/m.inbox/$1"
  assert_equals "$3" "$(state_of m:001)" "marker $1"
}
mark .ring-state '001.msg\t2\t1500\n' ring-counted
mark .busy-state '001.msg\t1\n' busy-deferred
mark .busy-escalated '001.msg\n' busy-reported
mark .held-escalated '001.msg\n' held-reported
mark .escalated '001.msg\n' escalated
mark .retry-ring '001.msg\n' retry-owed
mark .ring-state '002.msg\t2\t1500\n' rung
mv "$S/m.inbox/001.msg" "$S/m.inbox/handled/"; assert_equals read "$(state_of m:001)" "a move ends the ladder"
rm -rf "$S/m.inbox"; seed_msg m 001 inbox stored rung handled; printf '001.msg\n' > "$S/m.inbox/.escalated"
assert_equals handled "$(state_of m:001)" "a claim ends the ladder"
rm -rf "$S/m.inbox"; mkdir -p "$S/m.inbox"; : > "$S/m.inbox/.seq.lock"; assert_equals allocating "$(state_of m:001)" "the sequence lock"
rm -f "$S/m.inbox/.seq.lock"; jm show task-inbox m:001; expect_code 1 "$RC" "a record that does not exist is in no state"
pass "the seven ladder markers each have a row the observer reaches"

# AX: read `next` only, run the handle command it names, and the record lands on the listed `to`.
jm next task-inbox a:002; assert_contains "$OUT" "$(printf 'move\tfail\tfailed')" "next lists the fail move"
want=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="move" && $2=="handle"{print $3}')
cmd=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="move" && $2=="handle"{print $5}')
(cd "$H" && bash -c "${cmd//<kind>:<pointer>/status:proof}") >/dev/null 2>&1
assert_equals "$want" "$(state_of a:002)" "the state moved to the listed to"
pass "AX: next names the command and the move lands on its to"
