#!/usr/bin/env bash
# Behavior tests for the account machine table (core/machines/tables/account.tsv, observer core/machines/observers/account.sh).
# Every record is generated here in the shape its writer prints (the quota reader's state/<provider>-accounts.json, the picker's rest files and
# assignments); no fleet record is copied. The table is report-only: a fixture record in every state prints the right word, the table lints,
# and a legal move adds no line to the shadow log.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-account)
export JG_HOME="$T/home"; S=$JG_HOME/state; mkdir -p "$S/claude-accounts-rested"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
NOW=$(date +%s)

jm check account; expect_code 0 "$RC" "the account table lints"; assert_equals "ok account: 6 states, 13 edges" "$OUT" "lint golden"
jm enum account; expect_code 0 "$RC" "the enum lints"; assert_contains "$OUT" 6 "six values"
jm coverage account; expect_code 0 "$RC" "every edge names its test"
assert_equals "available in-use limited signed-out on-hold retired" \
  "$(awk -F'\t' '$1=="state"{printf "%s ", $2}' "$ROOT/core/machines/tables/account.tsv" | sed 's/ $//')" "the six states"
pass "the account table lints with 6 states and 13 moves, each with a test"

# The reading the quota reader writes: one entry per account, windows with `left`, and a `problem` that is null or its cause.
cat > "$S/claude-accounts.json" <<JSON
{"schema":1,"generated_at":$NOW,"accounts":[
 {"id":"a-free","name":"free","folder":"/x/1","five_hour":{"left":80,"resets_at":"2026-11-12T20:00:00+00:00"},"seven_day":{"left":60,"resets_at":"2026-11-15T20:00:00+00:00"},"problem":null},
 {"id":"a-busy","name":"busy","folder":"/x/2","five_hour":{"left":50,"resets_at":"2026-11-12T20:00:00+00:00"},"seven_day":{"left":60,"resets_at":"2026-11-15T20:00:00+00:00"},"problem":null},
 {"id":"a-capped","name":"capped","folder":"/x/3","five_hour":{"left":0,"resets_at":"2026-11-12T20:00:00+00:00"},"seven_day":{"left":40,"resets_at":"2026-11-15T20:00:00+00:00"},"problem":null},
 {"id":"a-rested","name":"rested","folder":"/x/4","five_hour":{"left":10,"resets_at":"2026-11-12T20:00:00+00:00"},"seven_day":{"left":40,"resets_at":"2026-11-15T20:00:00+00:00"},"problem":null},
 {"id":"a-out","name":"out","folder":"/x/5","five_hour":null,"seven_day":null,"problem":"claude auth status: not authenticated, please sign in"},
 {"id":"a-held","name":"held","folder":"/x/7","five_hour":{"left":90,"resets_at":"2026-11-12T20:00:00+00:00"},"seven_day":{"left":60,"resets_at":"2026-11-15T20:00:00+00:00"},"problem":null},
 {"id":"a-err","name":"err","folder":"/x/6","five_hour":{"left":70,"resets_at":"2026-11-12T20:00:00+00:00"},"seven_day":null,"problem":"timeout reading the quota"}]}
JSON
mkdir -p "$S/claude-accounts-held"; printf '%s\t/x/7\tbilling error\n' "$NOW" > "$S/claude-accounts-held/a-held"
echo "$((NOW + 3600))" > "$S/claude-accounts-rested/a-rested"; echo "$((NOW - 10))" > "$S/claude-accounts-rested/a-free"
cat > "$S/account-assignments.json" <<JSON
[{"provider":"claude","id":"a-busy","at":$((NOW - 20))},{"provider":"claude","id":"a-busy","at":$((NOW - 5))},
 {"provider":"claude","id":"a-free","at":$((NOW - 4000))},{"provider":"codex","id":"a-free","at":$((NOW - 5))}]
JSON
word_of() {  # the state word `show` found, or the word the observer printed when it found none
  jm show account "$1"
  if [ "$RC" -eq 0 ]; then printf '%s\n' "$OUT" | awk -F'\t' '$1 == "state" { print $2 }'
  else printf '%s\n' "$OUT" | sed -n "s/.*observer printed '\(.*\)'.*/\1/p"; fi
}
: > "$T/states.corpus"
for id in claude.a-free:available claude.a-busy:in-use claude.a-capped:limited claude.a-rested:limited claude.a-out:signed-out \
  claude.a-err:available claude.a-held:on-hold claude.a-gone:retired; do
  echo "show account ${id%:*} -> $(word_of "${id%:*}")"
  assert_equals "${id##*:}" "$(word_of "${id%:*}")" "${id%:*} is ${id##*:}"
  word_of "${id%:*}" >> "$T/states.corpus"
done
for st in available in-use limited signed-out on-hold retired; do grep -qx "$st" "$T/states.corpus" || fail "no fixture is in state $st"; done
jm check account --corpus "$T/states.corpus"; expect_code 0 "$RC" "every word a fixture printed is a state"
pass "a fixture record in every state prints the right word"

# An expired lease and a rest in the past change nothing; a reading that is missing is a finding, and blocks nothing.
assert_equals available "$(word_of claude.a-free)" "a lease past its 300 s and a rest in the past leave the account available"
jm show account codex.a-free; expect_code 1 "$RC" "no reading is a finding"
assert_contains "$OUT" "no state: the observer printed 'no-reading'" "show names no-reading"
jm check account; expect_code 0 "$RC" "a missing reading never fails the table check (report-only)"
pass "a missing reading is reported and blocks nothing"

# Moves: the legal moves replay clean, and a move out of a final state is a finding.
{ tab available lease in-use; tab in-use recount in-use; tab in-use release available; tab in-use hit-limit limited
  tab limited reset available; tab available sign-out signed-out; tab limited sign-out signed-out; tab in-use sign-out signed-out
  tab signed-out sign-in available; tab available retire retired; tab signed-out retire-out retired; tab available hold on-hold; tab in-use hold on-hold; tab limited hold on-hold
  tab on-hold release available; tab on-hold retire-hold retired; } > "$T/moves.corpus"
jm check account --corpus "$T/moves.corpus"; expect_code 0 "$RC" "legal moves replay clean"
tab retired lease in-use > "$T/bad-move.corpus"
jm check account --corpus "$T/bad-move.corpus"; expect_code 1 "$RC" "a move out of retired"
assert_contains "$OUT" "retired lease in-use is not a move" "check names the move"
pass "check replays the legal moves and refuses a move out of a final state"

# The shadow log: a legal move adds no line, an illegal one adds exactly one, and the writer carries on.
LOG=$JG_HOME/data/machine-shadow.log
lines() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }
shadow() { local b; b=$(lines); bash "$ROOT/bin/jg-machine-shadow.sh" account "$1" "$2" || fail "the shadow helper must always exit 0"; echo $(( $(lines) - b )); }
assert_equals 0 "$(shadow claude.a-free in-use)" "available -> in-use is legal: the lease"
assert_equals 0 "$(shadow claude.a-busy limited)" "in-use -> limited is legal: the limit hit"
assert_equals 0 "$(shadow claude.a-capped available)" "limited -> available is legal: the reset"
assert_equals 0 "$(shadow claude.a-out available)" "signed-out -> available is legal: the sign-in"
assert_equals 1 "$(shadow claude.a-free limited)" "available -> limited skips the lease and is illegal"
assert_contains "$(tail -n 1 "$LOG")" account "the shadow line names the machine"
assert_equals 1 "$(shadow claude.a-gone available)" "a retired account has no move"
pass "a legal move adds no shadow line, an illegal move adds one"
