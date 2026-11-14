#!/usr/bin/env bash
# Behavior tests for the inbox journey on the message table (core/machines/tables/message.tsv, 5 states): every steer has one
# provable state, read through bin/jg-delivery.sh. Delivery files are generated here by seed_msg (no fleet record is copied).
# A message id is <task>:<NNN>. Proves: the ledger shapes read as the five words; `read` comes from the file's place and is never
# written; each ladder marker (and the sequence lock) is a field that changes no word; a worker's claim and a move end the
# ladder; the ring the inbox library reports to the machine is a legal move; and the AX walk: `next` names the handle command,
# running it moves the record to the `to` it listed.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-inbox); H=$T/home; S=$H/state; mkdir -p "$S"; ln -sn "$ROOT/bin" "$H/bin"
unset JG_MACHINES_TABLES
export JG_HOME="$H" JG_STATE_OVERRIDE="$S" JG_DELIVERY_BUS_TIMEOUT=1
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
state_of() { jm show message "$1"; printf '%s\n' "$OUT" | awk -F'\t' '$1=="state"{print $2}'; }

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

jm check message; expect_code 0 "$RC" "the table lints"; assert_contains "$OUT" "ok message: 5 states" "check reports the 5-state table"
pass "the message table passes the lint rules"

for c in 001:stored 002:rung 003:read 004:handled 005:failed 006:handled; do
  assert_equals "${c#*:}" "$(state_of "a:${c%%:*}")" "message ${c%%:*} state"
done
assert_equals 0 "$(grep -c '"word":"read"' "$S/a.inbox/.delivery.jsonl")" "no read word is ever written"
pass "each delivery shape reads as one of five words, and read comes from the file's place only"

# Ladder markers are fields: one seeded message per marker, and none of them changes the word.
mark() {  # <marker> <content> <state>
  rm -rf "$S/m.inbox"; seed_msg m 001 inbox stored rung; printf '%b' "$2" > "$S/m.inbox/$1"
  assert_equals "$3" "$(state_of m:001)" "marker $1"
}
mark .ring-state '001.msg\t2\t1500\n' rung
mark .busy-state '001.msg\t1\n' rung
mark .busy-escalated '001.msg\n' rung
mark .held-escalated '001.msg\n' rung
mark .escalated '001.msg\n' rung
mark .retry-ring '001.msg\n' rung
mv "$S/m.inbox/001.msg" "$S/m.inbox/handled/"; assert_equals read "$(state_of m:001)" "a move ends the ladder"
rm -rf "$S/m.inbox"; seed_msg m 001 inbox stored rung handled; printf '001.msg\n' > "$S/m.inbox/.escalated"
assert_equals handled "$(state_of m:001)" "a claim ends the ladder"
rm -rf "$S/m.inbox"; mkdir -p "$S/m.inbox"; : > "$S/m.inbox/.seq.lock"; jm show message m:001; expect_code 1 "$RC" "a record that does not exist is in no state"
pass "the six ladder markers are fields: none of them is a state"

# The ring the library reports is a legal move: a stored steer is rung, and the library's shadow report logs nothing.
rm -rf "$S/r.inbox"; seed_msg r 001 inbox stored; mkdir -p "$H/data"
bash -c '. "$1/bin/jg-task-inbox-lib.sh"; jg_task_inbox_record_ring "$2" r "$2/r.inbox/001.msg"' _ "$ROOT" "$S"; expect_code 0 "$?" "the library records the ring"
assert_equals 0 "$([ -s "$H/data/machine-shadow.log" ] && wc -l < "$H/data/machine-shadow.log" || echo 0)" "the ring is a legal move of the message table"
[ -s "$S/r.inbox/.ring-state" ] || fail "the ring count field was not written"
pass "the inbox library reports its ring to the message table as a legal move"

# AX: read `next` only, run the handle command it names, and the record lands on the listed `to`.
jm next message a:002; assert_contains "$OUT" "$(printf 'move\tfail\tfailed')" "next lists the fail move"
want=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="move" && $2=="handle"{print $3}')
cmd=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="move" && $2=="handle"{print $5}')
(cd "$H" && bash -c "${cmd//<kind>:<pointer>/status:proof}") >/dev/null 2>&1
assert_equals "$want" "$(state_of a:002)" "the state moved to the listed to"
pass "AX: next names the command and the move lands on its to"
